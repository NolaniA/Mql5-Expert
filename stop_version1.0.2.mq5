//+------------------------------------------------------------------+
//|                                   stop_recovery_directional.mq5  |
//|                                  Copyright 2025, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
//
// Logic:
// 1) Initial straddle uses a wider INITIAL dynamic distance.
// 2) Recovery uses a separate, tighter RECOVERY dynamic distance.
// 3) Recovery direction is based on NET exposure + confirmed EMA trend.
//      - NET SELL + UPTREND -> BUY STOP recovery.
//      - NET BUY  + DOWNTREND -> SELL STOP recovery.
//      - NET FLAT -> confirmed trend chooses one recovery side.
//      - Recovery NEVER adds more volume in the direction that is already
//        over-exposed just because that side is currently profitable.
// 4) Recovery L2+ requires price re-arm distance + cooldown.
// 5) Pending orders trail using their own Initial/Recovery distance profile.
// 6) When both BUY and SELL positions exist:
//      - BasketProfit >= BasketTargetProfit -> close all + delete pending.
//      - BasketProfit < 0 and no pending -> evaluate directional Recovery.
// 7) Recovery lot scales softly by RecoveryLotStep.
// 8) Recovery is bounded by MaxRecoveryLevel / MaxTotalLot / loss limits.
// 9) All state is filtered by Symbol + Magic.
//
// IMPORTANT:
// - This EA requires an MT5 HEDGING account.
// - Recovery uses only ONE pending order per level (not a recovery straddle).
// - Test in Strategy Tester / demo before live use.
//+------------------------------------------------------------------+

#property copyright "Copyright 2025, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "2.30"
#property description "Straddle + Directional Basket Recovery + active risk limits"

#include <Trade/Trade.mqh>

CTrade trade;

//==================================================================
// INPUTS
//==================================================================

// Base lot for the initial BUY STOP / SELL STOP.
// Kept at 0.01 from the original file for safety.
// Change to 0.10 manually if that is the intended live/test size.
input double BaseLot = 0.01;

//==================================================================
// INITIAL / RECOVERY DYNAMIC DISTANCE
//==================================================================
//
// Initial orders use a wider distance to wait for a clearer breakout.
// Recovery orders use a separate, tighter distance so the Recovery
// zone does not become unnecessarily wide.
//
// For each profile:
//
// DynamicDistance = MAX(
//    BaseDistance,
//    ATR(points) * ATRMultiplier
//       + Spread(points) * SpreadMultiplier
//       + SlippagePoint * SlippageBufferMultiplier,
//    Broker Stop/Freeze minimum
// )
//
// Max...DistancePoint = 0 means no maximum cap.
//
input int InitialBaseDistancePoint = 2500;
input int RecoveryBaseDistancePoint = 1000;

input int ATRPeriod = 14;
input ENUM_TIMEFRAMES ATRTimeframe = PERIOD_CURRENT;

input double InitialATRMultiplier = 1.0;
input double RecoveryATRMultiplier = 0.40;

input double SpreadMultiplier = 1.0;

input int SlippagePoint = 20;
input double SlippageBufferMultiplier = 2.0;

input int MaxInitialDynamicDistancePoint = 0;
input int MaxRecoveryDynamicDistancePoint = 0;

// Recovery L2+ must satisfy BOTH conditions below after the previous
// Recovery order has been triggered into a position.
input int RecoveryRearmPoint = 1500;
input int RecoveryCooldownSeconds = 900;

// Directional Recovery filter.
// Uses the LAST CLOSED candle on this timeframe.
input ENUM_TIMEFRAMES RecoveryTrendTimeframe = PERIOD_M15;
input int RecoveryFastEMAPeriod = 9;
input int RecoverySlowEMAPeriod = 21;

// true  = UPTREND also requires a bullish closed candle,
//         DOWNTREND also requires a bearish closed candle.
// false = EMA structure + close location only.
input bool RecoveryRequireCandleConfirm = true;

input ulong Magic = 10001;

// Basket target: when BOTH BUY and SELL exist and total basket P/L reaches this.
input double BasketTargetProfit = 1.0;

// Soft lot scaling.
// Recovery level 1 = BaseLot * (1 + 0.50 * 1)
// Recovery level 2 = BaseLot * (1 + 0.50 * 2)
// etc.
input double RecoveryLotStep = 0.50;

// Maximum number of recovery levels per basket.
input int MaxRecoveryLevel = 3;

// Risk limits.
// 0 = disabled.
input double MaxTotalLot = 0.80;
input double MaxBasketLoss = 50.0;
input double MaxBasketDrawdownPercent = 0.50;

// Close a basket that remains open too long. This prevents a hedged
// basket from staying locked for many days and accumulating swap/risk.
// 0 = disabled.
input int MaxBasketHoldingHours = 48;

//==================================================================
// GLOBAL STATE
//==================================================================

int PendingBuy = 0;
int PendingSell = 0;

int PositionBuy = 0;
int PositionSell = 0;

// ATR indicator handle.
// Created once in OnInit() and reused on every tick.
int AtrHandle = INVALID_HANDLE;

// EMA handles used only for directional Recovery confirmation.
int RecoveryFastEMAHandle = INVALID_HANDLE;
int RecoverySlowEMAHandle = INVALID_HANDLE;

// Latest EXECUTED Recovery position.
// Used to stop immediate L1 -> L2 -> L3 re-arming in the same zone.
double LastRecoveryTriggerPrice = 0.0;
datetime LastRecoveryTriggerTime = 0;

//==================================================================
// BASKET STATS
//==================================================================

struct BasketStats
{
   int buyCount;
   int sellCount;

   double buyProfit;
   double sellProfit;
   double totalProfit;

   double buyVolume;
   double sellVolume;
   double totalVolume;
};

//==================================================================
// FUNCTION PROTOTYPES
//==================================================================

void LoadTradeState();

double GetATRPoints();
double GetSpreadPoints();

int GetDynamicDistancePoint(
   int baseDistancePoint,
   double atrMultiplier,
   int maxDistancePoint
);

int GetInitialDistancePoint();
int GetRecoveryDistancePoint();

int GetRecoveryTrend();

bool IsRecoveryComment(string comment);

void RestoreLastRecoveryTriggerState();

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

void GetBasketStats(BasketStats &stats);

void CloseAllPositions();
void DeleteAllPendingOrders();

bool DeleteOrderTicket(ulong ticket);

void CloseBasket(
   string reason,
   double basketProfit
);

int ParseRecoveryLevel(string comment);

int GetHighestRecoveryLevel();

double GetRecoveryLot(int recoveryLevel);

bool PlaceRecoveryStraddle(
   int recoveryLevel,
   double recoveryLot
);

bool HasRecoveryPosition(
   int recoveryLevel,
   ENUM_POSITION_TYPE positionType
);

void DeleteRecoveryPendingByType(
   int recoveryLevel,
   ENUM_ORDER_TYPE orderType
);

void ManageRecoveryOCOFallback();

bool HandleRiskLimits(
   BasketStats &stats
);

datetime GetOldestPositionTime();

void ManageRecovery(
   BasketStats &stats
);

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   //===============================================================
   // HEDGING ACCOUNT REQUIRED
   //===============================================================
   ENUM_ACCOUNT_MARGIN_MODE marginMode =
      (ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(
         ACCOUNT_MARGIN_MODE
      );

   if(marginMode != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
   {
      Print(
         "INIT FAILED | EA requires HEDGING account"
      );

      return INIT_FAILED;
   }

   //===============================================================
   // TRADE SETTINGS
   //===============================================================
   trade.SetExpertMagicNumber(Magic);

   trade.SetMarginMode();

   trade.SetDeviationInPoints(
      SlippagePoint
   );

   trade.SetTypeFillingBySymbol(
      _Symbol
   );

   //===============================================================
   // ATR HANDLE
   //===============================================================
   if(
      ATRPeriod > 0 &&
      (
         InitialATRMultiplier > 0 ||
         RecoveryATRMultiplier > 0
      )
   )
   {
      AtrHandle =
         iATR(
            _Symbol,
            ATRTimeframe,
            ATRPeriod
         );

      if(AtrHandle == INVALID_HANDLE)
      {
         Print(
            "WARNING | ATR handle could not be created.",
            " Dynamic distance will fall back to Base/Spread/Slippage/Broker minimum."
         );
      }
   }

   //===============================================================
   // DIRECTIONAL RECOVERY EMA HANDLES
   //===============================================================
   if(
      RecoveryFastEMAPeriod <= 0 ||
      RecoverySlowEMAPeriod <= 0 ||
      RecoveryFastEMAPeriod >= RecoverySlowEMAPeriod
   )
   {
      Print(
         "INIT FAILED | Invalid Recovery EMA periods",
         " | Fast=", RecoveryFastEMAPeriod,
         " | Slow=", RecoverySlowEMAPeriod
      );

      return INIT_PARAMETERS_INCORRECT;
   }

   RecoveryFastEMAHandle =
      iMA(
         _Symbol,
         RecoveryTrendTimeframe,
         RecoveryFastEMAPeriod,
         0,
         MODE_EMA,
         PRICE_CLOSE
      );

   RecoverySlowEMAHandle =
      iMA(
         _Symbol,
         RecoveryTrendTimeframe,
         RecoverySlowEMAPeriod,
         0,
         MODE_EMA,
         PRICE_CLOSE
      );

   if(
      RecoveryFastEMAHandle == INVALID_HANDLE ||
      RecoverySlowEMAHandle == INVALID_HANDLE
   )
   {
      Print(
         "INIT FAILED | Recovery EMA handle could not be created"
      );

      if(RecoveryFastEMAHandle != INVALID_HANDLE)
      {
         IndicatorRelease(RecoveryFastEMAHandle);
         RecoveryFastEMAHandle = INVALID_HANDLE;
      }

      if(RecoverySlowEMAHandle != INVALID_HANDLE)
      {
         IndicatorRelease(RecoverySlowEMAHandle);
         RecoverySlowEMAHandle = INVALID_HANDLE;
      }

      return INIT_FAILED;
   }

   Print(
      "INIT OK",
      " | InitialBaseDistance=", InitialBaseDistancePoint,
      " | RecoveryBaseDistance=", RecoveryBaseDistancePoint,
      " | ATRPeriod=", ATRPeriod,
      " | InitialATRMultiplier=", InitialATRMultiplier,
      " | RecoveryATRMultiplier=", RecoveryATRMultiplier,
      " | SpreadMultiplier=", SpreadMultiplier,
      " | SlippagePoint=", SlippagePoint,
      " | SlippageBufferMultiplier=", SlippageBufferMultiplier,
      " | RecoveryRearmPoint=", RecoveryRearmPoint,
      " | RecoveryCooldownSeconds=", RecoveryCooldownSeconds,
      " | RecoveryTrendTF=", EnumToString(RecoveryTrendTimeframe),
      " | RecoveryFastEMA=", RecoveryFastEMAPeriod,
      " | RecoverySlowEMA=", RecoverySlowEMAPeriod,
      " | CandleConfirm=", RecoveryRequireCandleConfirm
   );

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(AtrHandle != INVALID_HANDLE)
   {
      IndicatorRelease(
         AtrHandle
      );

      AtrHandle = INVALID_HANDLE;
   }

   if(RecoveryFastEMAHandle != INVALID_HANDLE)
   {
      IndicatorRelease(
         RecoveryFastEMAHandle
      );

      RecoveryFastEMAHandle = INVALID_HANDLE;
   }

   if(RecoverySlowEMAHandle != INVALID_HANDLE)
   {
      IndicatorRelease(
         RecoverySlowEMAHandle
      );

      RecoverySlowEMAHandle = INVALID_HANDLE;
   }
}

//+------------------------------------------------------------------+
//| Trade transaction                                                |
//|                                                                  |
//| Saves the latest executed Recovery trigger price/time.            |
//| Directional Recovery uses only one pending order per level.       |
//+------------------------------------------------------------------+
void OnTradeTransaction(
   const MqlTradeTransaction &trans,
   const MqlTradeRequest &request,
   const MqlTradeResult &result
)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;

   if(trans.deal == 0)
      return;

   if(!HistoryDealSelect(trans.deal))
      return;

   if(
      HistoryDealGetString(
         trans.deal,
         DEAL_SYMBOL
      ) != _Symbol
   )
      return;

   if(
      (ulong)HistoryDealGetInteger(
         trans.deal,
         DEAL_MAGIC
      ) != Magic
   )
      return;

   ENUM_DEAL_ENTRY entry =
      (ENUM_DEAL_ENTRY)HistoryDealGetInteger(
         trans.deal,
         DEAL_ENTRY
      );

   if(entry != DEAL_ENTRY_IN)
      return;

   ulong sourceOrder =
      (ulong)HistoryDealGetInteger(
         trans.deal,
         DEAL_ORDER
      );

   if(sourceOrder == 0)
      return;

   string orderComment =
      HistoryOrderGetString(
         sourceOrder,
         ORDER_COMMENT
      );

   int recoveryLevel =
      ParseRecoveryLevel(
         orderComment
      );

   if(recoveryLevel <= 0)
      return;

   //===============================================================
   // SAVE LATEST EXECUTED RECOVERY TRIGGER
   //===============================================================
   LastRecoveryTriggerPrice =
      HistoryDealGetDouble(
         trans.deal,
         DEAL_PRICE
      );

   LastRecoveryTriggerTime =
      (datetime)HistoryDealGetInteger(
         trans.deal,
         DEAL_TIME
      );

   ENUM_DEAL_TYPE dealType =
      (ENUM_DEAL_TYPE)HistoryDealGetInteger(
         trans.deal,
         DEAL_TYPE
      );

   Print(
      "RECOVERY TRIGGERED",
      " | Side=",
      (
         dealType == DEAL_TYPE_BUY
         ? "BUY"
         : "SELL"
      ),
      " | Level=", recoveryLevel,
      " | Price=", LastRecoveryTriggerPrice
   );
}

//+------------------------------------------------------------------+
//| Expert tick                                                      |
//+------------------------------------------------------------------+
void OnTick()
{
   //===============================================================
   // LOAD CURRENT STATE
   //===============================================================
   LoadTradeState();

   BasketStats stats;
   GetBasketStats(stats);

   // Fully closed basket -> clean state for next cycle.
   if(
      stats.buyCount == 0 &&
      stats.sellCount == 0
   )
   {
      LastRecoveryTriggerPrice = 0.0;
      LastRecoveryTriggerTime = 0;
   }

   //===============================================================
   // RISK LIMITS
   // Applied whenever this EA has at least one open position.
   //===============================================================
   if(
      stats.buyCount > 0 ||
      stats.sellCount > 0
   )
   {
      if(HandleRiskLimits(stats))
         return;
   }

   //===============================================================
   // BASKET MANAGEMENT
   // User logic: only manage basket target/recovery when BOTH sides
   // already exist.
   //===============================================================
   if(
      stats.buyCount > 0 &&
      stats.sellCount > 0
   )
   {
      //============================================================
      // TARGET PROFIT -> CLOSE EVERYTHING
      //============================================================
      if(
         stats.totalProfit >= BasketTargetProfit
      )
      {
         CloseBasket(
            "BASKET TARGET",
            stats.totalProfit
         );

         return;
      }

      //============================================================
      // RECOVERY CONDITION
      //
      // PositionBuy  != 0
      // PositionSell != 0
      // TotalProfit  < 0
      // PendingBuy   == 0
      // PendingSell  == 0
      //============================================================
      if(
         stats.totalProfit < 0 &&
         PendingBuy == 0 &&
         PendingSell == 0
      )
      {
         ManageRecovery(stats);
      }
   }
   else
   {
      //============================================================
      // INITIAL / MISSING-SIDE STRADDLE
      //============================================================
      EnsureInitialOrders();
   }

   //===============================================================
   // REFRESH AFTER OPEN / DELETE
   //===============================================================
   LoadTradeState();

   //===============================================================
   // TRAIL PENDING ORDERS
   // Works for both INITIAL and RECOVERY stops.
   //===============================================================
   ModifyBuyStop();
   ModifySellStop();
}

//+------------------------------------------------------------------+
//| Load Trade State                                                 |
//+------------------------------------------------------------------+
void LoadTradeState()
{
   PendingBuy = 0;
   PendingSell = 0;

   PositionBuy = 0;
   PositionSell = 0;

   //===============================================================
   // PENDING ORDERS
   //===============================================================
   for(int i = 0; i < OrdersTotal(); i++)
   {
      ulong ticket =
         OrderGetTicket(i);

      if(ticket == 0)
         continue;

      if(
         OrderGetString(
            ORDER_SYMBOL
         ) != _Symbol
      )
         continue;

      if(
         (ulong)OrderGetInteger(
            ORDER_MAGIC
         ) != Magic
      )
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

   //===============================================================
   // POSITIONS
   //===============================================================
   for(int i = 0; i < PositionsTotal(); i++)
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

      ENUM_POSITION_TYPE type =
         (ENUM_POSITION_TYPE)PositionGetInteger(
            POSITION_TYPE
         );

      if(type == POSITION_TYPE_BUY)
      {
         PositionBuy++;
      }
      else
      if(type == POSITION_TYPE_SELL)
      {
         PositionSell++;
      }
   }
}

//+------------------------------------------------------------------+
//| Get ATR in Points                                                |
//|                                                                  |
//| Uses the last CLOSED ATR value (shift = 1), not the live candle. |
//| Returns 0 when ATR is unavailable so the EA can safely fall back |
//| to BaseDistance + market/broker buffers.                          |
//+------------------------------------------------------------------+
double GetATRPoints()
{
   if(
      AtrHandle == INVALID_HANDLE ||
      ATRPeriod <= 0
   )
      return 0.0;

   double atrBuffer[1];

   int copied =
      CopyBuffer(
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

   return(
      atrBuffer[0] /
      _Point
   );
}

//+------------------------------------------------------------------+
//| Get Current Spread in Points                                     |
//+------------------------------------------------------------------+
double GetSpreadPoints()
{
   double ask =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_ASK
      );

   double bid =
      SymbolInfoDouble(
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

   return(
      (ask - bid) /
      _Point
   );
}

//+------------------------------------------------------------------+
//| Get Dynamic Safe Distance Point                                  |
//|                                                                  |
//| Initial and Recovery use separate distance profiles.             |
//+------------------------------------------------------------------+
int GetDynamicDistancePoint(
   int baseDistancePoint,
   double atrMultiplier,
   int maxDistancePoint
)
{
   //===============================================================
   // BROKER MINIMUM
   //===============================================================
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

   //===============================================================
   // BASE
   //===============================================================
   int baseDistance =
      MathMax(
         baseDistancePoint,
         1
      );

   //===============================================================
   // ATR + SPREAD + SLIPPAGE
   //===============================================================
   double atrDistance =
      GetATRPoints()
      *
      MathMax(
         atrMultiplier,
         0.0
      );

   double spreadBuffer =
      GetSpreadPoints()
      *
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

   //===============================================================
   // FINAL
   //===============================================================
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

   // Optional cap. Never force below Base/Broker minimum.
   if(
      maxDistancePoint > 0 &&
      maxDistancePoint >= minimumRequired
   )
   {
      distance =
         MathMin(
            distance,
            maxDistancePoint
         );
   }

   return distance;
}

//+------------------------------------------------------------------+
//| Initial Distance                                                 |
//+------------------------------------------------------------------+
int GetInitialDistancePoint()
{
   return GetDynamicDistancePoint(
      InitialBaseDistancePoint,
      InitialATRMultiplier,
      MaxInitialDynamicDistancePoint
   );
}

//+------------------------------------------------------------------+
//| Recovery Distance                                                |
//+------------------------------------------------------------------+
int GetRecoveryDistancePoint()
{
   return GetDynamicDistancePoint(
      RecoveryBaseDistancePoint,
      RecoveryATRMultiplier,
      MaxRecoveryDynamicDistancePoint
   );
}

//+------------------------------------------------------------------+
//| Directional Recovery Trend                                       |
//|                                                                  |
//| Returns:                                                         |
//|   1 = confirmed uptrend                                          |
//|  -1 = confirmed downtrend                                        |
//|   0 = no confirmation / insufficient data                        |
//|                                                                  |
//| Uses the last CLOSED candle (shift=1), not the live candle.       |
//+------------------------------------------------------------------+
int GetRecoveryTrend()
{
   if(
      RecoveryFastEMAHandle == INVALID_HANDLE ||
      RecoverySlowEMAHandle == INVALID_HANDLE
   )
      return 0;

   double fastBuffer[1];
   double slowBuffer[1];

   int fastCopied =
      CopyBuffer(
         RecoveryFastEMAHandle,
         0,
         1,
         1,
         fastBuffer
      );

   int slowCopied =
      CopyBuffer(
         RecoverySlowEMAHandle,
         0,
         1,
         1,
         slowBuffer
      );

   if(
      fastCopied != 1 ||
      slowCopied != 1
   )
      return 0;

   double open1 =
      iOpen(
         _Symbol,
         RecoveryTrendTimeframe,
         1
      );

   double close1 =
      iClose(
         _Symbol,
         RecoveryTrendTimeframe,
         1
      );

   if(
      open1 <= 0 ||
      close1 <= 0 ||
      fastBuffer[0] <= 0 ||
      slowBuffer[0] <= 0
   )
      return 0;

   bool upTrend =
      (
         fastBuffer[0] > slowBuffer[0] &&
         close1 > fastBuffer[0]
      );

   bool downTrend =
      (
         fastBuffer[0] < slowBuffer[0] &&
         close1 < fastBuffer[0]
      );

   if(RecoveryRequireCandleConfirm)
   {
      upTrend =
         (
            upTrend &&
            close1 > open1
         );

      downTrend =
         (
            downTrend &&
            close1 < open1
         );
   }

   if(upTrend)
      return 1;

   if(downTrend)
      return -1;

   return 0;
}

//+------------------------------------------------------------------+
//| Recovery Comment                                                 |
//+------------------------------------------------------------------+
bool IsRecoveryComment(string comment)
{
   return(
      StringFind(
         comment,
         "REC_BUY_L"
      ) >= 0
      ||
      StringFind(
         comment,
         "REC_SELL_L"
      ) >= 0
   );
}

//+------------------------------------------------------------------+
//| Restore Last Recovery Trigger State                              |
//|                                                                  |
//| Allows cooldown/re-arm logic to survive an EA/terminal restart.  |
//+------------------------------------------------------------------+
void RestoreLastRecoveryTriggerState()
{
   long latestTime = 0;
   double latestPrice = 0.0;

   for(int i = 0; i < PositionsTotal(); i++)
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

      string comment =
         PositionGetString(
            POSITION_COMMENT
         );

      if(!IsRecoveryComment(comment))
         continue;

      long positionTime =
         PositionGetInteger(
            POSITION_TIME
         );

      if(positionTime >= latestTime)
      {
         latestTime = positionTime;

         latestPrice =
            PositionGetDouble(
               POSITION_PRICE_OPEN
            );
      }
   }

   if(latestTime > 0)
   {
      LastRecoveryTriggerTime =
         (datetime)latestTime;

      LastRecoveryTriggerPrice =
         latestPrice;
   }
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
         (volume - minVolume) / step
      );

   double normalized =
      minVolume +
      (
         steps *
         step
      );

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
      IsRecoveryComment(comment)
      ?
      GetRecoveryDistancePoint()
      :
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
         0,
         0,
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
      " | Comment=", comment,
      " | Lot=", lot,
      " | Price=", price,
      " | Ask=", ask,
      " | Distance=", distancePoint
   );

   return true;
}

//+------------------------------------------------------------------+
//| Place Sell Stop                                                  |
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
      IsRecoveryComment(comment)
      ?
      GetRecoveryDistancePoint()
      :
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
         0,
         0,
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
      " | Comment=", comment,
      " | Lot=", lot,
      " | Price=", price,
      " | Bid=", bid,
      " | Distance=", distancePoint
   );

   return true;
}

//+------------------------------------------------------------------+
//| Initial / Missing-side Orders                                    |
//|                                                                  |
//| Original behavior retained:                                      |
//| - No BUY position and no BUY STOP  -> create BUY STOP            |
//| - No SELL position and no SELL STOP -> create SELL STOP          |
//|                                                                  |
//| This lets the first side trigger while the opposite stop remains |
//| available to create the initial hedge.                           |
//+------------------------------------------------------------------+
void EnsureInitialOrders()
{
   ulong ticket = 0;

   if(
      PositionBuy == 0 &&
      PendingBuy == 0
   )
   {
      PlaceBuyStop(
         BaseLot,
         "INIT BUY",
         ticket
      );
   }

   if(
      PositionSell == 0 &&
      PendingSell == 0
   )
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
//|                                                                  |
//| If market falls away from a BUY STOP by more than the current   |
//| dynamic distance, pull it down to Ask + dynamic distance.        |
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

   for(int i = 0; i < OrdersTotal(); i++)
   {
      ulong ticket =
         OrderGetTicket(i);

      if(ticket == 0)
         continue;

      if(
         OrderGetString(
            ORDER_SYMBOL
         ) != _Symbol
      )
         continue;

      if(
         (ulong)OrderGetInteger(
            ORDER_MAGIC
         ) != Magic
      )
         continue;

      ENUM_ORDER_TYPE type =
         (ENUM_ORDER_TYPE)OrderGetInteger(
            ORDER_TYPE
         );

      if(type != ORDER_TYPE_BUY_STOP)
         continue;

      string comment =
         OrderGetString(
            ORDER_COMMENT
         );

      bool isRecovery =
         IsRecoveryComment(
            comment
         );

      int distancePoint =
         isRecovery
         ?
         GetRecoveryDistancePoint()
         :
         GetInitialDistancePoint();

      double oldPrice =
         OrderGetDouble(
            ORDER_PRICE_OPEN
         );

      double distance =
         (oldPrice - ask)
         /
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
            " | Distance=", distance,
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
         " | Ask=", ask,
         " | Distance=", distance
      );
   }
}

//+------------------------------------------------------------------+
//| Modify Sell Stop                                                 |
//|                                                                  |
//| If market rises away from a SELL STOP by more than the current  |
//| dynamic distance, pull it up to Bid - dynamic distance.          |
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

   for(int i = 0; i < OrdersTotal(); i++)
   {
      ulong ticket =
         OrderGetTicket(i);

      if(ticket == 0)
         continue;

      if(
         OrderGetString(
            ORDER_SYMBOL
         ) != _Symbol
      )
         continue;

      if(
         (ulong)OrderGetInteger(
            ORDER_MAGIC
         ) != Magic
      )
         continue;

      ENUM_ORDER_TYPE type =
         (ENUM_ORDER_TYPE)OrderGetInteger(
            ORDER_TYPE
         );

      if(type != ORDER_TYPE_SELL_STOP)
         continue;

      string comment =
         OrderGetString(
            ORDER_COMMENT
         );

      bool isRecovery =
         IsRecoveryComment(
            comment
         );

      int distancePoint =
         isRecovery
         ?
         GetRecoveryDistancePoint()
         :
         GetInitialDistancePoint();

      double oldPrice =
         OrderGetDouble(
            ORDER_PRICE_OPEN
         );

      double distance =
         (bid - oldPrice)
         /
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
            " | Distance=", distance,
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
         " | Bid=", bid,
         " | Distance=", distance
      );
   }
}

//+------------------------------------------------------------------+
//| Get Basket Stats                                                 |
//+------------------------------------------------------------------+
void GetBasketStats(BasketStats &stats)
{
   stats.buyCount = 0;
   stats.sellCount = 0;

   stats.buyProfit = 0;
   stats.sellProfit = 0;
   stats.totalProfit = 0;

   stats.buyVolume = 0;
   stats.sellVolume = 0;
   stats.totalVolume = 0;

   for(int i = 0; i < PositionsTotal(); i++)
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

      ENUM_POSITION_TYPE type =
         (ENUM_POSITION_TYPE)PositionGetInteger(
            POSITION_TYPE
         );

      double profit =
         PositionGetDouble(
            POSITION_PROFIT
         );

      double swap =
         PositionGetDouble(
            POSITION_SWAP
         );

      double volume =
         PositionGetDouble(
            POSITION_VOLUME
         );

      double positionPnl =
         profit +
         swap;

      stats.totalProfit += positionPnl;
      stats.totalVolume += volume;

      if(type == POSITION_TYPE_BUY)
      {
         stats.buyCount++;
         stats.buyProfit += positionPnl;
         stats.buyVolume += volume;
      }
      else
      if(type == POSITION_TYPE_SELL)
      {
         stats.sellCount++;
         stats.sellProfit += positionPnl;
         stats.sellVolume += volume;
      }
   }
}

//+------------------------------------------------------------------+
//| Close All Positions                                              |
//+------------------------------------------------------------------+
void CloseAllPositions()
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
            "CLOSE FAILED",
            " | Ticket=", ticket,
            " | Retcode=", trade.ResultRetcode(),
            " | ", trade.ResultRetcodeDescription()
         );
      }
      else
      {
         Print(
            "POSITION CLOSED",
            " | Ticket=", ticket
         );
      }
   }
}

//+------------------------------------------------------------------+
//| Delete One Pending Order                                         |
//+------------------------------------------------------------------+
bool DeleteOrderTicket(ulong ticket)
{
   if(ticket == 0)
      return false;

   bool result =
      trade.OrderDelete(
         ticket
      );

   if(
      !result ||
      !IsTradeSuccess()
   )
   {
      Print(
         "ORDER DELETE FAILED",
         " | Ticket=", ticket,
         " | Retcode=", trade.ResultRetcode(),
         " | ", trade.ResultRetcodeDescription()
      );

      return false;
   }

   Print(
      "ORDER DELETED",
      " | Ticket=", ticket
   );

   return true;
}

//+------------------------------------------------------------------+
//| Delete All Pending Orders                                        |
//+------------------------------------------------------------------+
void DeleteAllPendingOrders()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket =
         OrderGetTicket(i);

      if(ticket == 0)
         continue;

      if(
         OrderGetString(
            ORDER_SYMBOL
         ) != _Symbol
      )
         continue;

      if(
         (ulong)OrderGetInteger(
            ORDER_MAGIC
         ) != Magic
      )
         continue;

      ENUM_ORDER_TYPE type =
         (ENUM_ORDER_TYPE)OrderGetInteger(
            ORDER_TYPE
         );

      if(
         type != ORDER_TYPE_BUY_STOP &&
         type != ORDER_TYPE_SELL_STOP
      )
         continue;

      DeleteOrderTicket(
         ticket
      );
   }
}

//+------------------------------------------------------------------+
//| Close Basket                                                     |
//+------------------------------------------------------------------+
void CloseBasket(
   string reason,
   double basketProfit
)
{
   Print(
      "CLOSE BASKET",
      " | Reason=", reason,
      " | BasketProfit=", basketProfit
   );

   // Delete pending first so a stop cannot trigger while positions
   // are being closed one by one.
   DeleteAllPendingOrders();

   CloseAllPositions();

   LastRecoveryTriggerPrice = 0.0;
   LastRecoveryTriggerTime = 0;
}

//+------------------------------------------------------------------+
//| Parse Recovery Level from comment                                |
//|                                                                  |
//| REC_BUY_L1  -> 1                                                 |
//| REC_SELL_L1 -> 1                                                 |
//| INIT BUY     -> 0                                                 |
//+------------------------------------------------------------------+
int ParseRecoveryLevel(string comment)
{
   string buyPrefix =
      "REC_BUY_L";

   string sellPrefix =
      "REC_SELL_L";

   int position =
      StringFind(
         comment,
         buyPrefix
      );

   if(position >= 0)
   {
      string levelText =
         StringSubstr(
            comment,
            position +
            StringLen(
               buyPrefix
            )
         );

      return (int)StringToInteger(
         levelText
      );
   }

   position =
      StringFind(
         comment,
         sellPrefix
      );

   if(position >= 0)
   {
      string levelText =
         StringSubstr(
            comment,
            position +
            StringLen(
               sellPrefix
            )
         );

      return (int)StringToInteger(
         levelText
      );
   }

   return 0;
}

//+------------------------------------------------------------------+
//| Highest Recovery Level                                           |
//|                                                                  |
//| Scans BOTH positions and pending orders so state can be restored |
//| after EA / terminal restart.                                     |
//+------------------------------------------------------------------+
int GetHighestRecoveryLevel()
{
   int highestLevel = 0;

   //===============================================================
   // POSITIONS
   //===============================================================
   for(int i = 0; i < PositionsTotal(); i++)
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

      string comment =
         PositionGetString(
            POSITION_COMMENT
         );

      int level =
         ParseRecoveryLevel(
            comment
         );

      if(level > highestLevel)
         highestLevel = level;
   }

   //===============================================================
   // PENDING ORDERS
   //===============================================================
   for(int i = 0; i < OrdersTotal(); i++)
   {
      ulong ticket =
         OrderGetTicket(i);

      if(ticket == 0)
         continue;

      if(
         OrderGetString(
            ORDER_SYMBOL
         ) != _Symbol
      )
         continue;

      if(
         (ulong)OrderGetInteger(
            ORDER_MAGIC
         ) != Magic
      )
         continue;

      string comment =
         OrderGetString(
            ORDER_COMMENT
         );

      int level =
         ParseRecoveryLevel(
            comment
         );

      if(level > highestLevel)
         highestLevel = level;
   }

   return highestLevel;
}

//+------------------------------------------------------------------+
//| Recovery Lot                                                     |
//|                                                                  |
//| Example BaseLot=0.10 and RecoveryLotStep=0.50:                   |
//| L1=0.15, L2=0.20, L3=0.25 ...                                   |
//+------------------------------------------------------------------+
double GetRecoveryLot(int recoveryLevel)
{
   double lot =
      BaseLot *
      (
         1.0 +
         (
            RecoveryLotStep *
            recoveryLevel
         )
      );

   return NormalizeVolume(
      lot
   );
}

//+------------------------------------------------------------------+
//| Place Recovery Straddle                                          |
//|                                                                  |
//| Both stops are created at the SAME recovery level.               |
//| Market chooses which side triggers.                              |
//+------------------------------------------------------------------+
bool PlaceRecoveryStraddle(
   int recoveryLevel,
   double recoveryLot
)
{
   string buyComment =
      "REC_BUY_L" +
      IntegerToString(
         recoveryLevel
      );

   string sellComment =
      "REC_SELL_L" +
      IntegerToString(
         recoveryLevel
      );

   ulong buyTicket = 0;
   ulong sellTicket = 0;

   //===============================================================
   // BUY RECOVERY STOP
   //===============================================================
   if(
      !PlaceBuyStop(
         recoveryLot,
         buyComment,
         buyTicket
      )
   )
   {
      return false;
   }

   //===============================================================
   // SELL RECOVERY STOP
   //===============================================================
   if(
      !PlaceSellStop(
         recoveryLot,
         sellComment,
         sellTicket
      )
   )
   {
      // Roll back BUY leg if SELL leg could not be created.
      DeleteOrderTicket(
         buyTicket
      );

      return false;
   }

   Print(
      "RECOVERY STRADDLE OPEN",
      " | Level=", recoveryLevel,
      " | Lot=", recoveryLot,
      " | BuyTicket=", buyTicket,
      " | SellTicket=", sellTicket
   );

   return true;
}

//+------------------------------------------------------------------+
//| Has Recovery Position                                            |
//+------------------------------------------------------------------+
bool HasRecoveryPosition(
   int recoveryLevel,
   ENUM_POSITION_TYPE positionType
)
{
   for(int i = 0; i < PositionsTotal(); i++)
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

      ENUM_POSITION_TYPE type =
         (ENUM_POSITION_TYPE)PositionGetInteger(
            POSITION_TYPE
         );

      if(type != positionType)
         continue;

      string comment =
         PositionGetString(
            POSITION_COMMENT
         );

      int level =
         ParseRecoveryLevel(
            comment
         );

      if(level == recoveryLevel)
         return true;
   }

   return false;
}

//+------------------------------------------------------------------+
//| Delete Recovery Pending by Level + Type                          |
//+------------------------------------------------------------------+
void DeleteRecoveryPendingByType(
   int recoveryLevel,
   ENUM_ORDER_TYPE orderType
)
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket =
         OrderGetTicket(i);

      if(ticket == 0)
         continue;

      if(
         OrderGetString(
            ORDER_SYMBOL
         ) != _Symbol
      )
         continue;

      if(
         (ulong)OrderGetInteger(
            ORDER_MAGIC
         ) != Magic
      )
         continue;

      ENUM_ORDER_TYPE type =
         (ENUM_ORDER_TYPE)OrderGetInteger(
            ORDER_TYPE
         );

      if(type != orderType)
         continue;

      string comment =
         OrderGetString(
            ORDER_COMMENT
         );

      int level =
         ParseRecoveryLevel(
            comment
         );

      if(level != recoveryLevel)
         continue;

      DeleteOrderTicket(
         ticket
      );
   }
}

//+------------------------------------------------------------------+
//| OCO Fallback                                                     |
//|                                                                  |
//| Backup for restart / transaction-event timing.                   |
//+------------------------------------------------------------------+
void ManageRecoveryOCOFallback()
{
   int highestLevel =
      GetHighestRecoveryLevel();

   if(highestLevel <= 0)
      return;

   for(
      int level = 1;
      level <= highestLevel;
      level++
   )
   {
      bool hasRecoveryBuy =
         HasRecoveryPosition(
            level,
            POSITION_TYPE_BUY
         );

      bool hasRecoverySell =
         HasRecoveryPosition(
            level,
            POSITION_TYPE_SELL
         );

      if(hasRecoveryBuy)
      {
         DeleteRecoveryPendingByType(
            level,
            ORDER_TYPE_SELL_STOP
         );
      }

      if(hasRecoverySell)
      {
         DeleteRecoveryPendingByType(
            level,
            ORDER_TYPE_BUY_STOP
         );
      }
   }
}

//+------------------------------------------------------------------+
//| Risk Limits                                                      |
//|                                                                  |
//| Returns true when basket was closed due to a risk limit.         |
//+------------------------------------------------------------------+
bool HandleRiskLimits(
   BasketStats &stats
)
{
   //===============================================================
   // MAX BASKET HOLDING TIME
   //===============================================================
   if(MaxBasketHoldingHours > 0)
   {
      datetime oldestPositionTime = GetOldestPositionTime();

      if(oldestPositionTime > 0)
      {
         long holdingSeconds =
            (long)TimeCurrent() -
            (long)oldestPositionTime;

         long maximumSeconds =
            (long)MaxBasketHoldingHours * 60 * 60;

         if(holdingSeconds >= maximumSeconds)
         {
            CloseBasket(
               "MAX BASKET HOLDING TIME",
               stats.totalProfit
            );

            return true;
         }
      }
   }

   //===============================================================
   // MAX BASKET LOSS
   //===============================================================
   if(
      MaxBasketLoss > 0 &&
      stats.totalProfit <= -MaxBasketLoss
   )
   {
      CloseBasket(
         "MAX BASKET LOSS",
         stats.totalProfit
      );

      return true;
   }

   //===============================================================
   // MAX BASKET DRAWDOWN % OF ACCOUNT BALANCE
   //===============================================================
   if(
      MaxBasketDrawdownPercent > 0 &&
      stats.totalProfit < 0
   )
   {
      double balance =
         AccountInfoDouble(
            ACCOUNT_BALANCE
         );

      if(balance > 0)
      {
         double basketDrawdownPercent =
            (
               -stats.totalProfit /
               balance
            ) * 100.0;

         if(
            basketDrawdownPercent >=
            MaxBasketDrawdownPercent
         )
         {
            CloseBasket(
               "MAX BASKET DRAWDOWN %",
               stats.totalProfit
            );

            return true;
         }
      }
   }

   //===============================================================
   // MAX CURRENT OPEN LOT
   //===============================================================
   if(
      MaxTotalLot > 0 &&
      stats.totalVolume >
      (
         MaxTotalLot +
         0.0000001
      )
   )
   {
      CloseBasket(
         "MAX TOTAL LOT",
         stats.totalProfit
      );

      return true;
   }

   return false;
}

//+------------------------------------------------------------------+
//| Oldest position time for this Symbol + Magic                     |
//+------------------------------------------------------------------+
datetime GetOldestPositionTime()
{
   datetime oldestTime = 0;

   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);

      if(ticket == 0)
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if((ulong)PositionGetInteger(POSITION_MAGIC) != Magic)
         continue;

      datetime positionTime =
         (datetime)PositionGetInteger(POSITION_TIME);

      if(
         positionTime > 0 &&
         (
            oldestTime == 0 ||
            positionTime < oldestTime
         )
      )
      {
         oldestTime = positionTime;
      }
   }

   return oldestTime;
}

//+------------------------------------------------------------------+
//| Manage Recovery                                                  |
//|                                                                  |
//| Directional recovery rules:                                      |
//| BUY + SELL positions exist and Basket P/L < 0 and no pending.    |
//|                                                                  |
//| NET SELL (sellVolume > buyVolume):                               |
//|    Only BUY recovery is allowed, and only when trend = UP.        |
//| NET BUY (buyVolume > sellVolume):                                |
//|    Only SELL recovery is allowed, and only when trend = DOWN.     |
//| NET FLAT:                                                        |
//|    Confirmed trend chooses the single recovery side.              |
//|                                                                  |
//| This prevents the old behavior from adding even more SELL while   |
//| already net-short, or even more BUY while already net-long.       |
//+------------------------------------------------------------------+
void ManageRecovery(
   BasketStats &stats
)
{
   if(
      stats.buyCount == 0 ||
      stats.sellCount == 0
   )
      return;

   if(stats.totalProfit >= 0)
      return;

   if(
      PendingBuy != 0 ||
      PendingSell != 0
   )
      return;

   int currentLevel =
      GetHighestRecoveryLevel();

   //===============================================================
   // RECOVERY RE-ARM FILTER
   //
   // L1 can be created immediately.
   // L2+ requires BOTH cooldown + distance from latest executed
   // Recovery position.
   //===============================================================
   if(currentLevel > 0)
   {
      RestoreLastRecoveryTriggerState();

      if(
         RecoveryCooldownSeconds > 0 &&
         LastRecoveryTriggerTime > 0
      )
      {
         int elapsedSeconds =
            (int)(
               TimeCurrent() -
               LastRecoveryTriggerTime
            );

         if(
            elapsedSeconds <
            RecoveryCooldownSeconds
         )
         {
            Print(
               "RECOVERY WAIT",
               " | Reason=COOLDOWN",
               " | CurrentLevel=", currentLevel,
               " | Elapsed=", elapsedSeconds,
               " | Required=", RecoveryCooldownSeconds
            );

            return;
         }
      }

      if(
         RecoveryRearmPoint > 0 &&
         LastRecoveryTriggerPrice > 0
      )
      {
         double ask =
            SymbolInfoDouble(
               _Symbol,
               SYMBOL_ASK
            );

         double bid =
            SymbolInfoDouble(
               _Symbol,
               SYMBOL_BID
            );

         if(
            ask > 0 &&
            bid > 0
         )
         {
            double currentMid =
               (
                  ask +
                  bid
               )
               /
               2.0;

            double movedPoint =
               MathAbs(
                  currentMid -
                  LastRecoveryTriggerPrice
               )
               /
               _Point;

            if(
               movedPoint <
               RecoveryRearmPoint
            )
            {
               Print(
                  "RECOVERY WAIT",
                  " | Reason=REARM_DISTANCE",
                  " | CurrentLevel=", currentLevel,
                  " | LastTriggerPrice=", LastRecoveryTriggerPrice,
                  " | CurrentMid=", currentMid,
                  " | MovedPoint=", movedPoint,
                  " | Required=", RecoveryRearmPoint
               );

               return;
            }
         }
      }
   }

   int nextLevel =
      currentLevel + 1;

   //===============================================================
   // RECOVERY LEVEL LIMIT
   //===============================================================
   if(
      MaxRecoveryLevel > 0 &&
      nextLevel > MaxRecoveryLevel
   )
   {
      CloseBasket(
         "MAX RECOVERY LEVEL",
         stats.totalProfit
      );

      return;
   }

   //===============================================================
   // TREND CONFIRMATION
   //===============================================================
   int trend =
      GetRecoveryTrend();

   if(trend == 0)
   {
      Print(
         "RECOVERY WAIT",
         " | Reason=NO_TREND_CONFIRMATION",
         " | BuyVolume=", stats.buyVolume,
         " | SellVolume=", stats.sellVolume,
         " | Basket=", stats.totalProfit
      );

      return;
   }

   //===============================================================
   // NET EXPOSURE
   //
   // netVolume > 0 = NET BUY
   // netVolume < 0 = NET SELL
   //===============================================================
   double netVolume =
      stats.buyVolume -
      stats.sellVolume;

   double volumeStep =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_VOLUME_STEP
      );

   if(volumeStep <= 0)
      volumeStep = 0.01;

   double volumeTolerance =
      MathMax(
         volumeStep / 2.0,
         0.0000001
      );

   // recoveryDirection:
   //  1 = BUY
   // -1 = SELL
   int recoveryDirection = 0;

   //===============================================================
   // NET SELL -> ONLY BUY RECOVERY WHEN TREND CONFIRMS UP
   //===============================================================
   if(netVolume < -volumeTolerance)
   {
      if(trend != 1)
      {
         Print(
            "RECOVERY WAIT",
            " | Reason=NET_SELL_WAIT_UPTREND",
            " | NetVolume=", netVolume,
            " | Trend=", trend,
            " | Basket=", stats.totalProfit
         );

         return;
      }

      recoveryDirection = 1;
   }
   else
   //===============================================================
   // NET BUY -> ONLY SELL RECOVERY WHEN TREND CONFIRMS DOWN
   //===============================================================
   if(netVolume > volumeTolerance)
   {
      if(trend != -1)
      {
         Print(
            "RECOVERY WAIT",
            " | Reason=NET_BUY_WAIT_DOWNTREND",
            " | NetVolume=", netVolume,
            " | Trend=", trend,
            " | Basket=", stats.totalProfit
         );

         return;
      }

      recoveryDirection = -1;
   }
   else
   {
      //============================================================
      // NET FLAT -> TREND CHOOSES ONE SIDE
      //============================================================
      recoveryDirection = trend;
   }

   if(recoveryDirection == 0)
      return;

   double recoveryLot =
      GetRecoveryLot(
         nextLevel
      );

   //===============================================================
   // POTENTIAL TOTAL LOT LIMIT
   // Only ONE directional recovery order is created.
   //===============================================================
   if(
      MaxTotalLot > 0 &&
      (
         stats.totalVolume +
         recoveryLot
      ) > MaxTotalLot
   )
   {
      CloseBasket(
         "NEXT RECOVERY EXCEEDS MAX TOTAL LOT",
         stats.totalProfit
      );

      return;
   }

   string sideText =
      (
         recoveryDirection > 0
         ? "BUY"
         : "SELL"
      );

   Print(
      "RECOVERY DIRECTIONAL CONDITION",
      " | Side=", sideText,
      " | Basket=", stats.totalProfit,
      " | BuyProfit=", stats.buyProfit,
      " | SellProfit=", stats.sellProfit,
      " | BuyVolume=", stats.buyVolume,
      " | SellVolume=", stats.sellVolume,
      " | NetVolume=", netVolume,
      " | Trend=", trend,
      " | CurrentLevel=", currentLevel,
      " | NextLevel=", nextLevel,
      " | RecoveryLot=", recoveryLot,
      " | RecoveryDistance=", GetRecoveryDistancePoint(),
      " | LastTriggerPrice=", LastRecoveryTriggerPrice,
      " | LastTriggerTime=", TimeToString(
         LastRecoveryTriggerTime,
         TIME_DATE | TIME_SECONDS
      )
   );

   ulong ticket = 0;
   bool placed = false;

   if(recoveryDirection > 0)
   {
      string comment =
         "REC_BUY_L" +
         IntegerToString(
            nextLevel
         );

      placed =
         PlaceBuyStop(
            recoveryLot,
            comment,
            ticket
         );
   }
   else
   {
      string comment =
         "REC_SELL_L" +
         IntegerToString(
            nextLevel
         );

      placed =
         PlaceSellStop(
            recoveryLot,
            comment,
            ticket
         );
   }

   if(placed)
   {
      Print(
         "RECOVERY DIRECTIONAL OPEN",
         " | Side=", sideText,
         " | Level=", nextLevel,
         " | Lot=", recoveryLot,
         " | Ticket=", ticket,
         " | NetBefore=", netVolume
      );
   }
}
//+------------------------------------------------------------------+
