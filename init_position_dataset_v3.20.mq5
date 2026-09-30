//+------------------------------------------------------------------+
//|                         init_position_dataset_v3.20.mq5            |
//|                                  Copyright 2025, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
//
// PURE INIT TEST VERSION
//
// Logic:
// 1) NO Recovery.
// 2) NO Stop Loss.
// 3) NO Take Profit.
// 4) Each position is closed independently when its own profit reaches target.
// 5) NO MaxBasketLoss.
// 6) NO Drawdown stop.
// 7) NO Max holding-time close.
// 8) NO MaxTotalLot forced close.
// 9) Existing positions are NEVER used to block new INIT orders.
// 10) If no BUY STOP pending  -> create INIT BUY STOP.
// 11) If no SELL STOP pending -> create INIT SELL STOP.
// 12) Filled side is replenished continuously.
// 13) No basket close. Each profitable position is closed separately.
//
// IMPORTANT:
// - This version closes ONLY positions that individually reach the profit target.
// - It is for isolating/testing INIT behavior only.
// - Requires an MT5 HEDGING account.
//+------------------------------------------------------------------+

#property copyright "Copyright 2025, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "3.20"
#property strict
#property description "Continuous INIT + position profit target + dataset logger"

#include <Trade/Trade.mqh>

CTrade trade;

//==================================================================
// INPUTS
//==================================================================
input double BaseLot = 0.01;

//==================================================================
// INITIAL DYNAMIC DISTANCE
//==================================================================
input int InitialBaseDistancePoint = 2500;

input int ATRPeriod = 14;
input ENUM_TIMEFRAMES ATRTimeframe = PERIOD_CURRENT;
input double InitialATRMultiplier = 1.0;

input double SpreadMultiplier = 1.0;

input int SlippagePoint = 20;
input double SlippageBufferMultiplier = 2.0;

// 0 = no maximum cap.
input int MaxInitialDynamicDistancePoint = 0;

input ulong Magic = 10001;

// Profit target PER POSITION. This is NOT a stop loss.
input double PositionTargetProfit = 1.0;

//==================================================================
// DATA COLLECTION
//==================================================================
input bool EnableDataLogging = true;

// Feature indicators are for logging/research only.
// They do NOT change entry/exit decisions in this version.
input ENUM_TIMEFRAMES FeatureTimeframe = PERIOD_M5;
input int FeatureRSIPeriod = 14;
input int FeatureFastEMAPeriod = 12;
input int FeatureSlowEMAPeriod = 24;
input int FeatureSwingLookbackBars = 20;

// Snapshot once per new bar of this timeframe.
// PERIOD_M1 = more detail / larger file.
// PERIOD_M5 = recommended starting point.
input ENUM_TIMEFRAMES SnapshotTimeframe = PERIOD_M5;

// Files are written to MetaTrader Common\Files.
// Each backtest overwrites the previous dataset with the same prefix.
input string DatasetPrefix = "init_dataset";

//==================================================================
// GLOBAL STATE
//==================================================================
int PendingBuy  = 0;
int PendingSell = 0;

int AtrHandle = INVALID_HANDLE;

// Research-only indicator handles.
int FeatureRsiHandle = INVALID_HANDLE;
int FeatureFastEmaHandle = INVALID_HANDLE;
int FeatureSlowEmaHandle = INVALID_HANDLE;

// Dataset file handles.
int PositionsFileHandle = INVALID_HANDLE;
int SnapshotsFileHandle = INVALID_HANDLE;

datetime LastSnapshotBarTime = 0;
int DatasetWriteCounter = 0;

struct TrackedPosition
{
   ulong ticket;
   long identifier;

   ENUM_POSITION_TYPE type;

   double lot;
   datetime openTime;
   double openPrice;

   // Entry market context.
   double entryAtrPrice;
   double entryAtrPoints;
   double entryRsi;
   double entryEmaFast;
   double entryEmaSlow;
   int entryTrend;
   double entrySpreadPoints;

   double entrySwingHigh;
   double entrySwingLow;

   double entryEmaSlowDistAtr;
   double entrySwingHighDistAtr;
   double entrySwingLowDistAtr;

   // Life-of-position statistics.
   double mfeMoney;
   double maeMoney;

   double mfeAtr;
   double maeAtr;

   double maxPrice;
   double minPrice;
};

TrackedPosition TrackedPositions[];

//==================================================================
// PROTOTYPES
//==================================================================
void LoadPendingState();

double GetATRPoints();
double GetSpreadPoints();
int GetInitialDistancePoint();

double NormalizeBuyPrice(double price);
double NormalizeSellPrice(double price);
double NormalizeVolume(double volume);

bool IsTradeSuccess();

bool PlaceBuyStop(
   double lot,
   string comment,
   ulong &ticket
);

bool PlaceSellStop(
   double lot,
   string comment,
   ulong &ticket
);

void EnsureInitialOrders();

void ModifyBuyStop();
void ModifySellStop();


//==================================================================
// POSITION PROFIT TARGET
//==================================================================
void CloseProfitablePositions();

//==================================================================
// DATA LOGGER PROTOTYPES
//==================================================================
bool InitializeDataLogger();
void ShutdownDataLogger();

double GetIndicatorBufferValue(int handle, int shift = 1);
bool GetSwingLevels(double &swingHigh, double &swingLow);
int GetFeatureTrend(double emaFast, double emaSlow);

void GetExposure(
   int &buyCount,
   int &sellCount,
   double &buyLot,
   double &sellLot,
   double &netLot
);

int FindTrackedPositionByTicket(ulong ticket);
void RegisterNewPositions();
void UpdateTrackedPositions();
void UpdateTrackedPositionByIndex(int index);

void WriteSnapshotByIndex(int index, string eventType);
void WritePeriodicSnapshots();

void WriteFinalPositionRow(
   int index,
   datetime closeTime,
   double closePrice,
   double finalProfit,
   double finalSwap,
   double finalCommission,
   double finalFee,
   double finalNet,
   string status,
   string closeReason
);

void FinalizeTrackedPosition(
   ulong ticket,
   string closeReason
);

void RemoveTrackedPositionByIndex(int index);
void WriteOpenPositionsAtEnd();

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   ENUM_ACCOUNT_MARGIN_MODE marginMode =
      (ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(
         ACCOUNT_MARGIN_MODE
      );

   if(marginMode != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
   {
      Print("INIT FAILED | EA requires HEDGING account");
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(Magic);
   trade.SetMarginMode();
   trade.SetDeviationInPoints(SlippagePoint);
   trade.SetTypeFillingBySymbol(_Symbol);

   if(
      ATRPeriod > 0 &&
      InitialATRMultiplier > 0
   )
   {
      AtrHandle = iATR(
         _Symbol,
         ATRTimeframe,
         ATRPeriod
      );

      if(AtrHandle == INVALID_HANDLE)
      {
         Print(
            "WARNING | ATR handle could not be created.",
            " Distance will fall back to Base/Spread/Slippage/Broker minimum."
         );
      }
   }

   //===============================================================
   // RESEARCH INDICATORS
   //===============================================================
   if(EnableDataLogging)
   {
      if(FeatureRSIPeriod > 0)
      {
         FeatureRsiHandle =
            iRSI(
               _Symbol,
               FeatureTimeframe,
               FeatureRSIPeriod,
               PRICE_CLOSE
            );
      }

      if(FeatureFastEMAPeriod > 0)
      {
         FeatureFastEmaHandle =
            iMA(
               _Symbol,
               FeatureTimeframe,
               FeatureFastEMAPeriod,
               0,
               MODE_EMA,
               PRICE_CLOSE
            );
      }

      if(FeatureSlowEMAPeriod > 0)
      {
         FeatureSlowEmaHandle =
            iMA(
               _Symbol,
               FeatureTimeframe,
               FeatureSlowEMAPeriod,
               0,
               MODE_EMA,
               PRICE_CLOSE
            );
      }

      if(!InitializeDataLogger())
      {
         Print(
            "WARNING | Dataset logger could not be initialized.",
            " Trading will continue without dataset output."
         );
      }
   }

   Print(
      "INIT OK",
      " | Mode=PURE_INIT_ONLY",
      " | BaseLot=", BaseLot,
      " | InitialBaseDistance=", InitialBaseDistancePoint,
      " | ATRPeriod=", ATRPeriod,
      " | InitialATRMultiplier=", InitialATRMultiplier,
      " | SpreadMultiplier=", SpreadMultiplier,
      " | SlippagePoint=", SlippagePoint,
      " | PositionTargetProfit=", PositionTargetProfit,
      " | DataLogging=", EnableDataLogging,
      " | SnapshotTF=", EnumToString(SnapshotTimeframe)
   );

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(EnableDataLogging)
   {
      // Preserve unfinished positions as OPEN_AT_END rows.
      UpdateTrackedPositions();
      WriteOpenPositionsAtEnd();
      ShutdownDataLogger();
   }

   if(FeatureRsiHandle != INVALID_HANDLE)
   {
      IndicatorRelease(FeatureRsiHandle);
      FeatureRsiHandle = INVALID_HANDLE;
   }

   if(FeatureFastEmaHandle != INVALID_HANDLE)
   {
      IndicatorRelease(FeatureFastEmaHandle);
      FeatureFastEmaHandle = INVALID_HANDLE;
   }

   if(FeatureSlowEmaHandle != INVALID_HANDLE)
   {
      IndicatorRelease(FeatureSlowEmaHandle);
      FeatureSlowEmaHandle = INVALID_HANDLE;
   }

   if(AtrHandle != INVALID_HANDLE)
   {
      IndicatorRelease(AtrHandle);
      AtrHandle = INVALID_HANDLE;
   }
}

//+------------------------------------------------------------------+
//| Expert tick                                                      |
//+------------------------------------------------------------------+
void OnTick()
{
   //===============================================================
   // 1. DATA COLLECTION
   // Does NOT alter the trading decision.
   //===============================================================
   if(EnableDataLogging)
   {
      RegisterNewPositions();
      UpdateTrackedPositions();
      WritePeriodicSnapshots();
   }

   //===============================================================
   // 2. CLOSE EACH PROFITABLE POSITION SEPARATELY
   //===============================================================
   CloseProfitablePositions();

   //===============================================================
   // 3. LOAD CURRENT PENDING INIT STATE
   //===============================================================
   LoadPendingState();

   //===============================================================
   // 4. CONTINUOUS INIT
   //
   // NO position == 0 check.
   // Pending BUY  == 0 -> new BUY STOP
   // Pending SELL == 0 -> new SELL STOP
   //===============================================================
   EnsureInitialOrders();

   //===============================================================
   // 5. REFRESH AFTER POSSIBLE ORDER CREATION
   //===============================================================
   LoadPendingState();

   //===============================================================
   // 6. TRAIL ONLY THE INIT PENDING ORDERS
   //===============================================================
   ModifyBuyStop();
   ModifySellStop();
}

//+------------------------------------------------------------------+
//| Load Pending State                                               |
//+------------------------------------------------------------------+
void LoadPendingState()
{
   PendingBuy  = 0;
   PendingSell = 0;

   for(int i = 0; i < OrdersTotal(); i++)
   {
      ulong ticket = OrderGetTicket(i);

      if(ticket == 0)
         continue;

      if(OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;

      if((ulong)OrderGetInteger(ORDER_MAGIC) != Magic)
         continue;

      ENUM_ORDER_TYPE type =
         (ENUM_ORDER_TYPE)OrderGetInteger(
            ORDER_TYPE
         );

      if(type == ORDER_TYPE_BUY_STOP)
      {
         PendingBuy++;
      }
      else
      if(type == ORDER_TYPE_SELL_STOP)
      {
         PendingSell++;
      }
   }
}

//+------------------------------------------------------------------+
//| Get ATR in Points                                                |
//| Uses the last CLOSED ATR value (shift = 1).                      |
//+------------------------------------------------------------------+
double GetATRPoints()
{
   if(
      AtrHandle == INVALID_HANDLE ||
      ATRPeriod <= 0
   )
      return 0.0;

   double atrBuffer[1];

   int copied = CopyBuffer(
      AtrHandle,
      0,
      1,
      1,
      atrBuffer
   );

   if(
      copied != 1 ||
      atrBuffer[0] <= 0 ||
      _Point <= 0
   )
      return 0.0;

   return atrBuffer[0] / _Point;
}

//+------------------------------------------------------------------+
//| Get Current Spread in Points                                     |
//+------------------------------------------------------------------+
double GetSpreadPoints()
{
   double ask = SymbolInfoDouble(
      _Symbol,
      SYMBOL_ASK
   );

   double bid = SymbolInfoDouble(
      _Symbol,
      SYMBOL_BID
   );

   if(
      ask <= 0 ||
      bid <= 0 ||
      ask < bid ||
      _Point <= 0
   )
      return 0.0;

   return (ask - bid) / _Point;
}

//+------------------------------------------------------------------+
//| Initial Dynamic Safe Distance                                    |
//+------------------------------------------------------------------+
int GetInitialDistancePoint()
{
   int stopLevel =
      (int)SymbolInfoInteger(
         _Symbol,
         SYMBOL_TRADE_STOPS_LEVEL
      );

   int freezeLevel =
      (int)SymbolInfoInteger(
         _Symbol,
         SYMBOL_TRADE_FREEZE_LEVEL
      );

   int brokerMinimum =
      MathMax(
         stopLevel,
         freezeLevel
      ) + 1;

   int baseDistance =
      MathMax(
         InitialBaseDistancePoint,
         1
      );

   double atrDistance =
      GetATRPoints() *
      MathMax(
         InitialATRMultiplier,
         0.0
      );

   double spreadBuffer =
      GetSpreadPoints() *
      MathMax(
         SpreadMultiplier,
         0.0
      );

   double slippageBuffer =
      MathMax(
         (double)SlippagePoint,
         0.0
      )
      *
      MathMax(
         SlippageBufferMultiplier,
         0.0
      );

   int dynamicDistance =
      (int)MathCeil(
         atrDistance +
         spreadBuffer +
         slippageBuffer
      );

   int minimumRequired =
      MathMax(
         baseDistance,
         brokerMinimum
      );

   int distance =
      MathMax(
         minimumRequired,
         dynamicDistance
      );

   if(
      MaxInitialDynamicDistancePoint > 0 &&
      MaxInitialDynamicDistancePoint >= minimumRequired
   )
   {
      distance =
         MathMin(
            distance,
            MaxInitialDynamicDistancePoint
         );
   }

   return distance;
}

//+------------------------------------------------------------------+
//| Normalize Buy Stop Price                                         |
//+------------------------------------------------------------------+
double NormalizeBuyPrice(double price)
{
   double tickSize =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_TRADE_TICK_SIZE
      );

   if(tickSize <= 0)
      return NormalizeDouble(
         price,
         _Digits
      );

   price =
      MathCeil(
         price / tickSize
      ) * tickSize;

   return NormalizeDouble(
      price,
      _Digits
   );
}

//+------------------------------------------------------------------+
//| Normalize Sell Stop Price                                        |
//+------------------------------------------------------------------+
double NormalizeSellPrice(double price)
{
   double tickSize =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_TRADE_TICK_SIZE
      );

   if(tickSize <= 0)
      return NormalizeDouble(
         price,
         _Digits
      );

   price =
      MathFloor(
         price / tickSize
      ) * tickSize;

   return NormalizeDouble(
      price,
      _Digits
   );
}

//+------------------------------------------------------------------+
//| Normalize Volume                                                 |
//+------------------------------------------------------------------+
double NormalizeVolume(double volume)
{
   double minVolume =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_VOLUME_MIN
      );

   double maxVolume =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_VOLUME_MAX
      );

   double step =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_VOLUME_STEP
      );

   if(minVolume <= 0)
      minVolume = 0.01;

   if(maxVolume <= 0)
      maxVolume = volume;

   if(step <= 0)
      step = minVolume;

   volume =
      MathMax(
         minVolume,
         MathMin(
            maxVolume,
            volume
         )
      );

   double steps =
      MathRound(
         (volume - minVolume) /
         step
      );

   double normalized =
      minVolume +
      (steps * step);

   normalized =
      MathMax(
         minVolume,
         MathMin(
            maxVolume,
            normalized
         )
      );

   return NormalizeDouble(
      normalized,
      8
   );
}

//+------------------------------------------------------------------+
//| Check Trade Result                                               |
//+------------------------------------------------------------------+
bool IsTradeSuccess()
{
   uint retcode =
      trade.ResultRetcode();

   return(
      retcode == TRADE_RETCODE_DONE ||
      retcode == TRADE_RETCODE_PLACED ||
      retcode == TRADE_RETCODE_DONE_PARTIAL ||
      retcode == TRADE_RETCODE_NO_CHANGES
   );
}

//+------------------------------------------------------------------+
//| Place Buy Stop                                                   |
//| NO SL / NO TP                                                    |
//+------------------------------------------------------------------+
bool PlaceBuyStop(
   double lot,
   string comment,
   ulong &ticket
)
{
   ticket = 0;

   double ask =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_ASK
      );

   if(ask <= 0)
      return false;

   lot =
      NormalizeVolume(
         lot
      );

   int distancePoint =
      GetInitialDistancePoint();

   double price =
      NormalizeBuyPrice(
         ask +
         (
            distancePoint *
            _Point
         )
      );

   bool requestResult =
      trade.BuyStop(
         lot,
         price,
         _Symbol,
         0,                 // SL = none
         0,                 // TP = none
         ORDER_TIME_GTC,
         0,
         comment
      );

   if(
      !requestResult ||
      !IsTradeSuccess()
   )
   {
      Print(
         "BUY STOP FAILED",
         " | Comment=", comment,
         " | Lot=", lot,
         " | Price=", price,
         " | Retcode=", trade.ResultRetcode(),
         " | ", trade.ResultRetcodeDescription()
      );

      return false;
   }

   ticket =
      trade.ResultOrder();

   Print(
      "BUY STOP OPEN",
      " | Ticket=", ticket,
      " | Lot=", lot,
      " | Price=", price,
      " | Ask=", ask,
      " | Distance=", distancePoint
   );

   return true;
}

//+------------------------------------------------------------------+
//| Place Sell Stop                                                  |
//| NO SL / NO TP                                                    |
//+------------------------------------------------------------------+
bool PlaceSellStop(
   double lot,
   string comment,
   ulong &ticket
)
{
   ticket = 0;

   double bid =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_BID
      );

   if(bid <= 0)
      return false;

   lot =
      NormalizeVolume(
         lot
      );

   int distancePoint =
      GetInitialDistancePoint();

   double price =
      NormalizeSellPrice(
         bid -
         (
            distancePoint *
            _Point
         )
      );

   bool requestResult =
      trade.SellStop(
         lot,
         price,
         _Symbol,
         0,                 // SL = none
         0,                 // TP = none
         ORDER_TIME_GTC,
         0,
         comment
      );

   if(
      !requestResult ||
      !IsTradeSuccess()
   )
   {
      Print(
         "SELL STOP FAILED",
         " | Comment=", comment,
         " | Lot=", lot,
         " | Price=", price,
         " | Retcode=", trade.ResultRetcode(),
         " | ", trade.ResultRetcodeDescription()
      );

      return false;
   }

   ticket =
      trade.ResultOrder();

   Print(
      "SELL STOP OPEN",
      " | Ticket=", ticket,
      " | Lot=", lot,
      " | Price=", price,
      " | Bid=", bid,
      " | Distance=", distancePoint
   );

   return true;
}

//+------------------------------------------------------------------+
//| Continuous INIT Orders                                           |
//|                                                                  |
//| IMPORTANT: Position state is NOT checked at all.                  |
//+------------------------------------------------------------------+
void EnsureInitialOrders()
{
   ulong ticket = 0;

   // No BUY STOP pending -> new BUY STOP.
   if(PendingBuy == 0)
   {
      PlaceBuyStop(
         BaseLot,
         "INIT BUY",
         ticket
      );
   }

   // No SELL STOP pending -> new SELL STOP.
   if(PendingSell == 0)
   {
      PlaceSellStop(
         BaseLot,
         "INIT SELL",
         ticket
      );
   }
}

//+------------------------------------------------------------------+
//| Modify Buy Stop                                                  |
//| Trail pending entry only; this is NOT a position stop loss.       |
//+------------------------------------------------------------------+
void ModifyBuyStop()
{
   if(PendingBuy == 0)
      return;

   double ask =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_ASK
      );

   if(ask <= 0)
      return;

   int distancePoint =
      GetInitialDistancePoint();

   for(int i = 0; i < OrdersTotal(); i++)
   {
      ulong ticket =
         OrderGetTicket(i);

      if(ticket == 0)
         continue;

      if(OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;

      if((ulong)OrderGetInteger(ORDER_MAGIC) != Magic)
         continue;

      ENUM_ORDER_TYPE type =
         (ENUM_ORDER_TYPE)OrderGetInteger(
            ORDER_TYPE
         );

      if(type != ORDER_TYPE_BUY_STOP)
         continue;

      double oldPrice =
         OrderGetDouble(
            ORDER_PRICE_OPEN
         );

      double distance =
         (oldPrice - ask) /
         _Point;

      if(distance <= distancePoint)
         continue;

      double newPrice =
         NormalizeBuyPrice(
            ask +
            (
               distancePoint *
               _Point
            )
         );

      if(
         MathAbs(
            newPrice - oldPrice
         ) < (_Point / 2.0)
      )
         continue;

      bool requestResult =
         trade.OrderModify(
            ticket,
            newPrice,
            0,
            0,
            ORDER_TIME_GTC,
            0,
            0
         );

      if(
         !requestResult ||
         !IsTradeSuccess()
      )
      {
         Print(
            "MODIFY BUY STOP FAILED",
            " | Ticket=", ticket,
            " | Old=", oldPrice,
            " | New=", newPrice,
            " | Retcode=", trade.ResultRetcode(),
            " | ", trade.ResultRetcodeDescription()
         );

         continue;
      }

      Print(
         "MODIFY BUY STOP",
         " | Ticket=", ticket,
         " | Old=", oldPrice,
         " | New=", newPrice,
         " | Ask=", ask
      );
   }
}

//+------------------------------------------------------------------+
//| Modify Sell Stop                                                 |
//| Trail pending entry only; this is NOT a position stop loss.       |
//+------------------------------------------------------------------+
void ModifySellStop()
{
   if(PendingSell == 0)
      return;

   double bid =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_BID
      );

   if(bid <= 0)
      return;

   int distancePoint =
      GetInitialDistancePoint();

   for(int i = 0; i < OrdersTotal(); i++)
   {
      ulong ticket =
         OrderGetTicket(i);

      if(ticket == 0)
         continue;

      if(OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;

      if((ulong)OrderGetInteger(ORDER_MAGIC) != Magic)
         continue;

      ENUM_ORDER_TYPE type =
         (ENUM_ORDER_TYPE)OrderGetInteger(
            ORDER_TYPE
         );

      if(type != ORDER_TYPE_SELL_STOP)
         continue;

      double oldPrice =
         OrderGetDouble(
            ORDER_PRICE_OPEN
         );

      double distance =
         (bid - oldPrice) /
         _Point;

      if(distance <= distancePoint)
         continue;

      double newPrice =
         NormalizeSellPrice(
            bid -
            (
               distancePoint *
               _Point
            )
         );

      if(
         MathAbs(
            newPrice - oldPrice
         ) < (_Point / 2.0)
      )
         continue;

      bool requestResult =
         trade.OrderModify(
            ticket,
            newPrice,
            0,
            0,
            ORDER_TIME_GTC,
            0,
            0
         );

      if(
         !requestResult ||
         !IsTradeSuccess()
      )
      {
         Print(
            "MODIFY SELL STOP FAILED",
            " | Ticket=", ticket,
            " | Old=", oldPrice,
            " | New=", newPrice,
            " | Retcode=", trade.ResultRetcode(),
            " | ", trade.ResultRetcodeDescription()
         );

         continue;
      }

      Print(
         "MODIFY SELL STOP",
         " | Ticket=", ticket,
         " | Old=", oldPrice,
         " | New=", newPrice,
         " | Bid=", bid
      );
   }
}

//+------------------------------------------------------------------+
//| Close Profitable Positions Individually                          |
//|                                                                  |
//| P/L = POSITION_PROFIT + POSITION_SWAP                            |
//| If P/L >= PositionTargetProfit -> close only that ticket.         |
//| Losing positions are never closed by this function.               |
//+------------------------------------------------------------------+
void CloseProfitablePositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket =
         PositionGetTicket(i);

      if(ticket == 0)
         continue;

      if(
         PositionGetString(
            POSITION_SYMBOL
         ) != _Symbol
      )
         continue;

      if(
         (ulong)PositionGetInteger(
            POSITION_MAGIC
         ) != Magic
      )
         continue;

      double positionProfit =
         PositionGetDouble(
            POSITION_PROFIT
         );

      double positionSwap =
         PositionGetDouble(
            POSITION_SWAP
         );

      double positionPnl =
         positionProfit +
         positionSwap;

      if(
         positionPnl <
         PositionTargetProfit
      )
         continue;

      bool result =
         trade.PositionClose(
            ticket,
            SlippagePoint
         );

      if(
         !result ||
         !IsTradeSuccess()
      )
      {
         Print(
            "POSITION PROFIT CLOSE FAILED",
            " | Ticket=", ticket,
            " | Profit=", positionPnl,
            " | Target=", PositionTargetProfit,
            " | Retcode=", trade.ResultRetcode(),
            " | ", trade.ResultRetcodeDescription()
         );

         continue;
      }

      Print(
         "POSITION PROFIT CLOSED",
         " | Ticket=", ticket,
         " | Profit=", positionPnl,
         " | Target=", PositionTargetProfit
      );

      if(EnableDataLogging)
      {
         FinalizeTrackedPosition(
            ticket,
            "POSITION_TARGET"
         );
      }
   }
}

//+------------------------------------------------------------------+
//| Initialize Dataset Logger                                        |
//+------------------------------------------------------------------+
bool InitializeDataLogger()
{
   string positionsFile =
      DatasetPrefix +
      "_positions.csv";

   string snapshotsFile =
      DatasetPrefix +
      "_snapshots.csv";

   int fileFlags =
      FILE_WRITE |
      FILE_CSV |
      FILE_ANSI |
      FILE_COMMON |
      FILE_SHARE_READ;

   PositionsFileHandle =
      FileOpen(
         positionsFile,
         fileFlags,
         ','
      );

   SnapshotsFileHandle =
      FileOpen(
         snapshotsFile,
         fileFlags,
         ','
      );

   if(
      PositionsFileHandle == INVALID_HANDLE ||
      SnapshotsFileHandle == INVALID_HANDLE
   )
   {
      if(PositionsFileHandle != INVALID_HANDLE)
      {
         FileClose(PositionsFileHandle);
         PositionsFileHandle = INVALID_HANDLE;
      }

      if(SnapshotsFileHandle != INVALID_HANDLE)
      {
         FileClose(SnapshotsFileHandle);
         SnapshotsFileHandle = INVALID_HANDLE;
      }

      return false;
   }

   // One row per completed/open-at-end position.
   FileWrite(
      PositionsFileHandle,
      "position_id",
      "ticket",
      "type",
      "lot",
      "open_time",
      "close_time",
      "holding_minutes",
      "open_price",
      "close_price",
      "entry_atr_price",
      "entry_atr_points",
      "entry_rsi",
      "entry_ema_fast",
      "entry_ema_slow",
      "entry_trend",
      "entry_spread_points",
      "entry_swing_high",
      "entry_swing_low",
      "entry_ema_slow_dist_atr",
      "entry_swing_high_dist_atr",
      "entry_swing_low_dist_atr",
      "mfe_money",
      "mae_money",
      "mfe_atr",
      "mae_atr",
      "max_price",
      "min_price",
      "final_profit",
      "final_swap",
      "final_commission",
      "final_fee",
      "final_net",
      "status",
      "close_reason"
   );

   // Multiple rows per position: ENTRY + periodic market state.
   FileWrite(
      SnapshotsFileHandle,
      "position_id",
      "ticket",
      "event",
      "time",
      "type",
      "lot",
      "open_price",
      "current_price",
      "current_profit",
      "holding_minutes",
      "mfe_money",
      "mae_money",
      "mfe_atr",
      "mae_atr",
      "atr_price",
      "rsi",
      "ema_fast",
      "ema_slow",
      "trend",
      "ema_slow_dist_atr",
      "swing_high",
      "swing_low",
      "swing_high_dist_atr",
      "swing_low_dist_atr",
      "break_high",
      "break_low",
      "buy_count",
      "sell_count",
      "buy_lot",
      "sell_lot",
      "net_lot"
   );

   FileFlush(PositionsFileHandle);
   FileFlush(SnapshotsFileHandle);

   Print(
      "DATA LOGGER READY",
      " | Folder=",
      TerminalInfoString(TERMINAL_COMMONDATA_PATH),
      "\\Files",
      " | Positions=", positionsFile,
      " | Snapshots=", snapshotsFile
   );

   return true;
}

//+------------------------------------------------------------------+
//| Shutdown Dataset Logger                                          |
//+------------------------------------------------------------------+
void ShutdownDataLogger()
{
   if(PositionsFileHandle != INVALID_HANDLE)
   {
      FileFlush(PositionsFileHandle);
      FileClose(PositionsFileHandle);
      PositionsFileHandle = INVALID_HANDLE;
   }

   if(SnapshotsFileHandle != INVALID_HANDLE)
   {
      FileFlush(SnapshotsFileHandle);
      FileClose(SnapshotsFileHandle);
      SnapshotsFileHandle = INVALID_HANDLE;
   }
}

//+------------------------------------------------------------------+
//| Indicator Value                                                  |
//+------------------------------------------------------------------+
double GetIndicatorBufferValue(
   int handle,
   int shift
)
{
   if(handle == INVALID_HANDLE)
      return 0.0;

   double values[1];

   int copied =
      CopyBuffer(
         handle,
         0,
         shift,
         1,
         values
      );

   if(copied != 1)
      return 0.0;

   return values[0];
}

//+------------------------------------------------------------------+
//| Swing Levels                                                     |
//| Uses closed bars only.                                           |
//+------------------------------------------------------------------+
bool GetSwingLevels(
   double &swingHigh,
   double &swingLow
)
{
   swingHigh = 0.0;
   swingLow = 0.0;

   if(FeatureSwingLookbackBars <= 0)
      return false;

   double highs[];
   double lows[];

   int copiedHigh =
      CopyHigh(
         _Symbol,
         FeatureTimeframe,
         1,
         FeatureSwingLookbackBars,
         highs
      );

   int copiedLow =
      CopyLow(
         _Symbol,
         FeatureTimeframe,
         1,
         FeatureSwingLookbackBars,
         lows
      );

   if(
      copiedHigh <= 0 ||
      copiedLow <= 0
   )
      return false;

   int highIndex =
      ArrayMaximum(
         highs,
         0,
         copiedHigh
      );

   int lowIndex =
      ArrayMinimum(
         lows,
         0,
         copiedLow
      );

   if(
      highIndex < 0 ||
      lowIndex < 0
   )
      return false;

   swingHigh = highs[highIndex];
   swingLow = lows[lowIndex];

   return true;
}

//+------------------------------------------------------------------+
//| Feature Trend                                                    |
//+------------------------------------------------------------------+
int GetFeatureTrend(
   double emaFast,
   double emaSlow
)
{
   if(
      emaFast <= 0 ||
      emaSlow <= 0
   )
      return 0;

   if(emaFast > emaSlow)
      return 1;

   if(emaFast < emaSlow)
      return -1;

   return 0;
}

//+------------------------------------------------------------------+
//| Current Exposure                                                 |
//+------------------------------------------------------------------+
void GetExposure(
   int &buyCount,
   int &sellCount,
   double &buyLot,
   double &sellLot,
   double &netLot
)
{
   buyCount = 0;
   sellCount = 0;
   buyLot = 0.0;
   sellLot = 0.0;
   netLot = 0.0;

   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket =
         PositionGetTicket(i);

      if(ticket == 0)
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if(
         (ulong)PositionGetInteger(
            POSITION_MAGIC
         ) != Magic
      )
         continue;

      ENUM_POSITION_TYPE type =
         (ENUM_POSITION_TYPE)PositionGetInteger(
            POSITION_TYPE
         );

      double volume =
         PositionGetDouble(
            POSITION_VOLUME
         );

      if(type == POSITION_TYPE_BUY)
      {
         buyCount++;
         buyLot += volume;
      }
      else
      if(type == POSITION_TYPE_SELL)
      {
         sellCount++;
         sellLot += volume;
      }
   }

   netLot =
      buyLot -
      sellLot;
}

//+------------------------------------------------------------------+
//| Find Tracked Position                                            |
//+------------------------------------------------------------------+
int FindTrackedPositionByTicket(
   ulong ticket
)
{
   for(
      int i = 0;
      i < ArraySize(TrackedPositions);
      i++
   )
   {
      if(TrackedPositions[i].ticket == ticket)
         return i;
   }

   return -1;
}

//+------------------------------------------------------------------+
//| Register New Positions                                           |
//+------------------------------------------------------------------+
void RegisterNewPositions()
{
   if(
      !EnableDataLogging ||
      PositionsFileHandle == INVALID_HANDLE ||
      SnapshotsFileHandle == INVALID_HANDLE
   )
      return;

   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket =
         PositionGetTicket(i);

      if(ticket == 0)
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if(
         (ulong)PositionGetInteger(
            POSITION_MAGIC
         ) != Magic
      )
         continue;

      if(FindTrackedPositionByTicket(ticket) >= 0)
         continue;

      int newIndex =
         ArraySize(
            TrackedPositions
         );

      ArrayResize(
         TrackedPositions,
         newIndex + 1
      );

      TrackedPositions[newIndex].ticket =
         ticket;

      TrackedPositions[newIndex].identifier =
         (long)PositionGetInteger(
            POSITION_IDENTIFIER
         );

      TrackedPositions[newIndex].type =
         (ENUM_POSITION_TYPE)PositionGetInteger(
            POSITION_TYPE
         );

      TrackedPositions[newIndex].lot =
         PositionGetDouble(
            POSITION_VOLUME
         );

      TrackedPositions[newIndex].openTime =
         (datetime)PositionGetInteger(
            POSITION_TIME
         );

      TrackedPositions[newIndex].openPrice =
         PositionGetDouble(
            POSITION_PRICE_OPEN
         );

      double atrPoints =
         GetATRPoints();

      double atrPrice =
         atrPoints *
         _Point;

      double rsi =
         GetIndicatorBufferValue(
            FeatureRsiHandle,
            1
         );

      double emaFast =
         GetIndicatorBufferValue(
            FeatureFastEmaHandle,
            1
         );

      double emaSlow =
         GetIndicatorBufferValue(
            FeatureSlowEmaHandle,
            1
         );

      double swingHigh = 0.0;
      double swingLow = 0.0;

      GetSwingLevels(
         swingHigh,
         swingLow
      );

      double openPrice =
         TrackedPositions[newIndex].openPrice;

      TrackedPositions[newIndex].entryAtrPrice =
         atrPrice;

      TrackedPositions[newIndex].entryAtrPoints =
         atrPoints;

      TrackedPositions[newIndex].entryRsi =
         rsi;

      TrackedPositions[newIndex].entryEmaFast =
         emaFast;

      TrackedPositions[newIndex].entryEmaSlow =
         emaSlow;

      TrackedPositions[newIndex].entryTrend =
         GetFeatureTrend(
            emaFast,
            emaSlow
         );

      TrackedPositions[newIndex].entrySpreadPoints =
         GetSpreadPoints();

      TrackedPositions[newIndex].entrySwingHigh =
         swingHigh;

      TrackedPositions[newIndex].entrySwingLow =
         swingLow;

      if(atrPrice > 0)
      {
         TrackedPositions[newIndex].entryEmaSlowDistAtr =
            (openPrice - emaSlow) /
            atrPrice;

         TrackedPositions[newIndex].entrySwingHighDistAtr =
            (swingHigh - openPrice) /
            atrPrice;

         TrackedPositions[newIndex].entrySwingLowDistAtr =
            (openPrice - swingLow) /
            atrPrice;
      }
      else
      {
         TrackedPositions[newIndex].entryEmaSlowDistAtr = 0.0;
         TrackedPositions[newIndex].entrySwingHighDistAtr = 0.0;
         TrackedPositions[newIndex].entrySwingLowDistAtr = 0.0;
      }

      double currentPrice =
         PositionGetDouble(
            POSITION_PRICE_CURRENT
         );

      double currentPnl =
         PositionGetDouble(
            POSITION_PROFIT
         ) +
         PositionGetDouble(
            POSITION_SWAP
         );

      TrackedPositions[newIndex].mfeMoney =
         currentPnl;

      TrackedPositions[newIndex].maeMoney =
         currentPnl;

      TrackedPositions[newIndex].mfeAtr = 0.0;
      TrackedPositions[newIndex].maeAtr = 0.0;

      TrackedPositions[newIndex].maxPrice =
         MathMax(
            openPrice,
            currentPrice
         );

      TrackedPositions[newIndex].minPrice =
         MathMin(
            openPrice,
            currentPrice
         );

      UpdateTrackedPositionByIndex(
         newIndex
      );

      // Immediate entry-state snapshot.
      WriteSnapshotByIndex(
         newIndex,
         "ENTRY"
      );
   }
}

//+------------------------------------------------------------------+
//| Update All Tracked Positions                                     |
//+------------------------------------------------------------------+
void UpdateTrackedPositions()
{
   for(
      int i = 0;
      i < ArraySize(TrackedPositions);
      i++
   )
   {
      UpdateTrackedPositionByIndex(i);
   }
}

//+------------------------------------------------------------------+
//| Update One Tracked Position                                      |
//+------------------------------------------------------------------+
void UpdateTrackedPositionByIndex(
   int index
)
{
   if(
      index < 0 ||
      index >= ArraySize(TrackedPositions)
   )
      return;

   ulong ticket =
      TrackedPositions[index].ticket;

   if(!PositionSelectByTicket(ticket))
      return;

   double currentPrice =
      PositionGetDouble(
         POSITION_PRICE_CURRENT
      );

   double currentPnl =
      PositionGetDouble(
         POSITION_PROFIT
      ) +
      PositionGetDouble(
         POSITION_SWAP
      );

   TrackedPositions[index].mfeMoney =
      MathMax(
         TrackedPositions[index].mfeMoney,
         currentPnl
      );

   TrackedPositions[index].maeMoney =
      MathMin(
         TrackedPositions[index].maeMoney,
         currentPnl
      );

   TrackedPositions[index].maxPrice =
      MathMax(
         TrackedPositions[index].maxPrice,
         currentPrice
      );

   TrackedPositions[index].minPrice =
      MathMin(
         TrackedPositions[index].minPrice,
         currentPrice
      );

   double atrPrice =
      TrackedPositions[index].entryAtrPrice;

   if(atrPrice <= 0)
      return;

   double directionalMove = 0.0;

   if(
      TrackedPositions[index].type ==
      POSITION_TYPE_BUY
   )
   {
      directionalMove =
         (
            currentPrice -
            TrackedPositions[index].openPrice
         ) /
         atrPrice;
   }
   else
   if(
      TrackedPositions[index].type ==
      POSITION_TYPE_SELL
   )
   {
      directionalMove =
         (
            TrackedPositions[index].openPrice -
            currentPrice
         ) /
         atrPrice;
   }

   TrackedPositions[index].mfeAtr =
      MathMax(
         TrackedPositions[index].mfeAtr,
         directionalMove
      );

   TrackedPositions[index].maeAtr =
      MathMin(
         TrackedPositions[index].maeAtr,
         directionalMove
      );
}

//+------------------------------------------------------------------+
//| Write One Snapshot                                               |
//+------------------------------------------------------------------+
void WriteSnapshotByIndex(
   int index,
   string eventType
)
{
   if(
      SnapshotsFileHandle == INVALID_HANDLE ||
      index < 0 ||
      index >= ArraySize(TrackedPositions)
   )
      return;

   ulong ticket =
      TrackedPositions[index].ticket;

   if(!PositionSelectByTicket(ticket))
      return;

   datetime now =
      TimeCurrent();

   double currentPrice =
      PositionGetDouble(
         POSITION_PRICE_CURRENT
      );

   double currentProfit =
      PositionGetDouble(
         POSITION_PROFIT
      ) +
      PositionGetDouble(
         POSITION_SWAP
      );

   double holdingMinutes =
      (
         (double)(
            now -
            TrackedPositions[index].openTime
         )
      ) / 60.0;

   double atrPrice =
      GetATRPoints() *
      _Point;

   double rsi =
      GetIndicatorBufferValue(
         FeatureRsiHandle,
         1
      );

   double emaFast =
      GetIndicatorBufferValue(
         FeatureFastEmaHandle,
         1
      );

   double emaSlow =
      GetIndicatorBufferValue(
         FeatureSlowEmaHandle,
         1
      );

   int trend =
      GetFeatureTrend(
         emaFast,
         emaSlow
      );

   double swingHigh = 0.0;
   double swingLow = 0.0;

   GetSwingLevels(
      swingHigh,
      swingLow
   );

   double emaSlowDistAtr = 0.0;
   double swingHighDistAtr = 0.0;
   double swingLowDistAtr = 0.0;

   if(atrPrice > 0)
   {
      emaSlowDistAtr =
         (currentPrice - emaSlow) /
         atrPrice;

      swingHighDistAtr =
         (swingHigh - currentPrice) /
         atrPrice;

      swingLowDistAtr =
         (currentPrice - swingLow) /
         atrPrice;
   }

   int breakHigh = 0;
   int breakLow = 0;

   if(
      swingHigh > 0 &&
      currentPrice > swingHigh
   )
      breakHigh = 1;

   if(
      swingLow > 0 &&
      currentPrice < swingLow
   )
      breakLow = 1;

   int buyCount = 0;
   int sellCount = 0;

   double buyLot = 0.0;
   double sellLot = 0.0;
   double netLot = 0.0;

   GetExposure(
      buyCount,
      sellCount,
      buyLot,
      sellLot,
      netLot
   );

   string typeText =
      (
         TrackedPositions[index].type ==
         POSITION_TYPE_BUY
      )
      ? "BUY"
      : "SELL";

   FileWrite(
      SnapshotsFileHandle,
      TrackedPositions[index].identifier,
      TrackedPositions[index].ticket,
      eventType,
      TimeToString(
         now,
         TIME_DATE | TIME_SECONDS
      ),
      typeText,
      DoubleToString(
         TrackedPositions[index].lot,
         4
      ),
      DoubleToString(
         TrackedPositions[index].openPrice,
         _Digits
      ),
      DoubleToString(
         currentPrice,
         _Digits
      ),
      DoubleToString(
         currentProfit,
         4
      ),
      DoubleToString(
         holdingMinutes,
         2
      ),
      DoubleToString(
         TrackedPositions[index].mfeMoney,
         4
      ),
      DoubleToString(
         TrackedPositions[index].maeMoney,
         4
      ),
      DoubleToString(
         TrackedPositions[index].mfeAtr,
         6
      ),
      DoubleToString(
         TrackedPositions[index].maeAtr,
         6
      ),
      DoubleToString(
         atrPrice,
         _Digits
      ),
      DoubleToString(
         rsi,
         4
      ),
      DoubleToString(
         emaFast,
         _Digits
      ),
      DoubleToString(
         emaSlow,
         _Digits
      ),
      trend,
      DoubleToString(
         emaSlowDistAtr,
         6
      ),
      DoubleToString(
         swingHigh,
         _Digits
      ),
      DoubleToString(
         swingLow,
         _Digits
      ),
      DoubleToString(
         swingHighDistAtr,
         6
      ),
      DoubleToString(
         swingLowDistAtr,
         6
      ),
      breakHigh,
      breakLow,
      buyCount,
      sellCount,
      DoubleToString(
         buyLot,
         4
      ),
      DoubleToString(
         sellLot,
         4
      ),
      DoubleToString(
         netLot,
         4
      )
   );

   DatasetWriteCounter++;

   // Avoid flushing on every row because that slows Strategy Tester.
   if(DatasetWriteCounter >= 500)
   {
      FileFlush(SnapshotsFileHandle);
      FileFlush(PositionsFileHandle);
      DatasetWriteCounter = 0;
   }
}

//+------------------------------------------------------------------+
//| Periodic Snapshot                                                |
//+------------------------------------------------------------------+
void WritePeriodicSnapshots()
{
   if(
      SnapshotsFileHandle == INVALID_HANDLE ||
      ArraySize(TrackedPositions) == 0
   )
      return;

   datetime currentBarTime =
      iTime(
         _Symbol,
         SnapshotTimeframe,
         0
      );

   if(currentBarTime <= 0)
      return;

   if(currentBarTime == LastSnapshotBarTime)
      return;

   LastSnapshotBarTime =
      currentBarTime;

   for(
      int i = 0;
      i < ArraySize(TrackedPositions);
      i++
   )
   {
      WriteSnapshotByIndex(
         i,
         "SNAPSHOT"
      );
   }
}

//+------------------------------------------------------------------+
//| Final Position Row                                               |
//+------------------------------------------------------------------+
void WriteFinalPositionRow(
   int index,
   datetime closeTime,
   double closePrice,
   double finalProfit,
   double finalSwap,
   double finalCommission,
   double finalFee,
   double finalNet,
   string status,
   string closeReason
)
{
   if(
      PositionsFileHandle == INVALID_HANDLE ||
      index < 0 ||
      index >= ArraySize(TrackedPositions)
   )
      return;

   double holdingMinutes =
      (
         (double)(
            closeTime -
            TrackedPositions[index].openTime
         )
      ) / 60.0;

   if(holdingMinutes < 0)
      holdingMinutes = 0;

   string typeText =
      (
         TrackedPositions[index].type ==
         POSITION_TYPE_BUY
      )
      ? "BUY"
      : "SELL";

   FileWrite(
      PositionsFileHandle,
      TrackedPositions[index].identifier,
      TrackedPositions[index].ticket,
      typeText,
      DoubleToString(
         TrackedPositions[index].lot,
         4
      ),
      TimeToString(
         TrackedPositions[index].openTime,
         TIME_DATE | TIME_SECONDS
      ),
      TimeToString(
         closeTime,
         TIME_DATE | TIME_SECONDS
      ),
      DoubleToString(
         holdingMinutes,
         2
      ),
      DoubleToString(
         TrackedPositions[index].openPrice,
         _Digits
      ),
      DoubleToString(
         closePrice,
         _Digits
      ),
      DoubleToString(
         TrackedPositions[index].entryAtrPrice,
         _Digits
      ),
      DoubleToString(
         TrackedPositions[index].entryAtrPoints,
         2
      ),
      DoubleToString(
         TrackedPositions[index].entryRsi,
         4
      ),
      DoubleToString(
         TrackedPositions[index].entryEmaFast,
         _Digits
      ),
      DoubleToString(
         TrackedPositions[index].entryEmaSlow,
         _Digits
      ),
      TrackedPositions[index].entryTrend,
      DoubleToString(
         TrackedPositions[index].entrySpreadPoints,
         2
      ),
      DoubleToString(
         TrackedPositions[index].entrySwingHigh,
         _Digits
      ),
      DoubleToString(
         TrackedPositions[index].entrySwingLow,
         _Digits
      ),
      DoubleToString(
         TrackedPositions[index].entryEmaSlowDistAtr,
         6
      ),
      DoubleToString(
         TrackedPositions[index].entrySwingHighDistAtr,
         6
      ),
      DoubleToString(
         TrackedPositions[index].entrySwingLowDistAtr,
         6
      ),
      DoubleToString(
         TrackedPositions[index].mfeMoney,
         4
      ),
      DoubleToString(
         TrackedPositions[index].maeMoney,
         4
      ),
      DoubleToString(
         TrackedPositions[index].mfeAtr,
         6
      ),
      DoubleToString(
         TrackedPositions[index].maeAtr,
         6
      ),
      DoubleToString(
         TrackedPositions[index].maxPrice,
         _Digits
      ),
      DoubleToString(
         TrackedPositions[index].minPrice,
         _Digits
      ),
      DoubleToString(
         finalProfit,
         4
      ),
      DoubleToString(
         finalSwap,
         4
      ),
      DoubleToString(
         finalCommission,
         4
      ),
      DoubleToString(
         finalFee,
         4
      ),
      DoubleToString(
         finalNet,
         4
      ),
      status,
      closeReason
   );

   DatasetWriteCounter++;
}

//+------------------------------------------------------------------+
//| Finalize Tracked Position after EA Close                         |
//+------------------------------------------------------------------+
void FinalizeTrackedPosition(
   ulong ticket,
   string closeReason
)
{
   int index =
      FindTrackedPositionByTicket(
         ticket
      );

   if(index < 0)
      return;

   datetime closeTime =
      TimeCurrent();

   double closePrice = 0.0;
   double finalProfit = 0.0;
   double finalSwap = 0.0;
   double finalCommission = 0.0;
   double finalFee = 0.0;

   ulong dealTicket =
      trade.ResultDeal();

   if(
      dealTicket > 0 &&
      HistoryDealSelect(dealTicket)
   )
   {
      closeTime =
         (datetime)HistoryDealGetInteger(
            dealTicket,
            DEAL_TIME
         );

      closePrice =
         HistoryDealGetDouble(
            dealTicket,
            DEAL_PRICE
         );

      finalProfit =
         HistoryDealGetDouble(
            dealTicket,
            DEAL_PROFIT
         );

      finalSwap =
         HistoryDealGetDouble(
            dealTicket,
            DEAL_SWAP
         );

      finalCommission =
         HistoryDealGetDouble(
            dealTicket,
            DEAL_COMMISSION
         );

      finalFee =
         HistoryDealGetDouble(
            dealTicket,
            DEAL_FEE
         );
   }

   // Note: commission here is the close deal's commission.
   // Entry commission remains visible in MT5 report/history.
   double finalNet =
      finalProfit +
      finalSwap +
      finalCommission +
      finalFee;

   WriteFinalPositionRow(
      index,
      closeTime,
      closePrice,
      finalProfit,
      finalSwap,
      finalCommission,
      finalFee,
      finalNet,
      "CLOSED",
      closeReason
   );

   RemoveTrackedPositionByIndex(
      index
   );
}

//+------------------------------------------------------------------+
//| Remove Tracked Position                                          |
//+------------------------------------------------------------------+
void RemoveTrackedPositionByIndex(
   int index
)
{
   int size =
      ArraySize(
         TrackedPositions
      );

   if(
      index < 0 ||
      index >= size
   )
      return;

   for(
      int i = index;
      i < size - 1;
      i++
   )
   {
      TrackedPositions[i] =
         TrackedPositions[i + 1];
   }

   ArrayResize(
      TrackedPositions,
      size - 1
   );
}

//+------------------------------------------------------------------+
//| Write unfinished positions when test/EA stops                    |
//+------------------------------------------------------------------+
void WriteOpenPositionsAtEnd()
{
   datetime now =
      TimeCurrent();

   for(
      int i = 0;
      i < ArraySize(TrackedPositions);
      i++
   )
   {
      ulong ticket =
         TrackedPositions[i].ticket;

      double currentPrice =
         TrackedPositions[i].openPrice;

      double currentProfit = 0.0;
      double currentSwap = 0.0;

      if(PositionSelectByTicket(ticket))
      {
         currentPrice =
            PositionGetDouble(
               POSITION_PRICE_CURRENT
            );

         currentProfit =
            PositionGetDouble(
               POSITION_PROFIT
            );

         currentSwap =
            PositionGetDouble(
               POSITION_SWAP
            );
      }

      WriteFinalPositionRow(
         i,
         now,
         currentPrice,
         currentProfit,
         currentSwap,
         0.0,
         0.0,
         currentProfit + currentSwap,
         "OPEN_AT_END",
         "TEST_END_OR_EA_STOP"
      );
   }

   ArrayResize(
      TrackedPositions,
      0
   );
}

//+------------------------------------------------------------------+
