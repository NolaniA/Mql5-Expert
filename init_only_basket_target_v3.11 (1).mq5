//+------------------------------------------------------------------+
//|                         init_only_continuous_v3.11.mq5            |
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
// 4) Basket Target is ACTIVE and closes all only when basket profit reaches target.
// 5) NO MaxBasketLoss.
// 6) NO Drawdown stop.
// 7) NO Max holding-time close.
// 8) NO MaxTotalLot forced close.
// 9) Existing positions are NEVER used to block new INIT orders.
// 10) If no BUY STOP pending  -> create INIT BUY STOP.
// 11) If no SELL STOP pending -> create INIT SELL STOP.
// 12) Filled side is replenished continuously.
// 13) When BOTH BUY and SELL positions exist and total basket profit >= target,
//     close all positions and delete pending orders.
//
// IMPORTANT:
// - This version intentionally has NO position-closing logic.
// - It is for isolating/testing INIT behavior only.
// - Requires an MT5 HEDGING account.
//+------------------------------------------------------------------+

#property copyright "Copyright 2025, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "3.11"
#property strict
#property description "Continuous INIT + Basket Profit Target only"

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

// Profit-only basket exit. This is NOT a stop loss.
input double BasketTargetProfit = 1.0;

//==================================================================
// GLOBAL STATE
//==================================================================
int PendingBuy  = 0;
int PendingSell = 0;

int AtrHandle = INVALID_HANDLE;

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
// BASKET STATS
//==================================================================
struct BasketStats
{
   int buyCount;
   int sellCount;
   double totalProfit;
};

//==================================================================
// BASKET TARGET PROTOTYPES
//==================================================================
void GetBasketStats(BasketStats &stats);
void DeleteAllPendingOrders();
void CloseAllPositions();
void CloseBasket(double basketProfit);

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

   Print(
      "INIT OK",
      " | Mode=PURE_INIT_ONLY",
      " | BaseLot=", BaseLot,
      " | InitialBaseDistance=", InitialBaseDistancePoint,
      " | ATRPeriod=", ATRPeriod,
      " | InitialATRMultiplier=", InitialATRMultiplier,
      " | SpreadMultiplier=", SpreadMultiplier,
      " | SlippagePoint=", SlippagePoint,
      " | BasketTargetProfit=", BasketTargetProfit
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
   // 1. LOAD PENDING + POSITION BASKET STATE
   //===============================================================
   LoadPendingState();

   BasketStats stats;
   GetBasketStats(stats);

   //===============================================================
   // 2. PROFIT-ONLY BASKET TARGET
   //
   // This is NOT a loss stop.
   // It closes only when BOTH BUY and SELL positions exist
   // and total basket P/L reaches the positive target.
   //===============================================================
   if(
      stats.buyCount > 0 &&
      stats.sellCount > 0 &&
      stats.totalProfit >= BasketTargetProfit
   )
   {
      CloseBasket(stats.totalProfit);
      return;
   }

   //===============================================================
   // 3. CONTINUOUS INIT
   //
   // NO position == 0 check.
   // Pending BUY  == 0 -> new BUY STOP
   // Pending SELL == 0 -> new SELL STOP
   //===============================================================
   EnsureInitialOrders();

   //===============================================================
   // 4. REFRESH AFTER POSSIBLE ORDER CREATION
   //===============================================================
   LoadPendingState();

   //===============================================================
   // 5. TRAIL ONLY THE INIT PENDING ORDERS
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
//| Basket Stats                                                     |
//+------------------------------------------------------------------+
void GetBasketStats(BasketStats &stats)
{
   stats.buyCount = 0;
   stats.sellCount = 0;
   stats.totalProfit = 0.0;

   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);

      if(ticket == 0)
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if((ulong)PositionGetInteger(POSITION_MAGIC) != Magic)
         continue;

      ENUM_POSITION_TYPE type =
         (ENUM_POSITION_TYPE)PositionGetInteger(
            POSITION_TYPE
         );

      double pnl =
         PositionGetDouble(POSITION_PROFIT) +
         PositionGetDouble(POSITION_SWAP);

      stats.totalProfit += pnl;

      if(type == POSITION_TYPE_BUY)
         stats.buyCount++;
      else
      if(type == POSITION_TYPE_SELL)
         stats.sellCount++;
   }
}

//+------------------------------------------------------------------+
//| Delete All INIT Pending Orders                                   |
//+------------------------------------------------------------------+
void DeleteAllPendingOrders()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
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

      if(
         type != ORDER_TYPE_BUY_STOP &&
         type != ORDER_TYPE_SELL_STOP
      )
         continue;

      bool result = trade.OrderDelete(ticket);

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
      ulong ticket = PositionGetTicket(i);

      if(ticket == 0)
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if((ulong)PositionGetInteger(POSITION_MAGIC) != Magic)
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
   }
}

//+------------------------------------------------------------------+
//| Basket Profit Target                                             |
//+------------------------------------------------------------------+
void CloseBasket(double basketProfit)
{
   Print(
      "CLOSE BASKET",
      " | Reason=BASKET TARGET",
      " | BasketProfit=", basketProfit,
      " | Target=", BasketTargetProfit
   );

   // Delete pending first to prevent a new INIT fill during closing.
   DeleteAllPendingOrders();
   CloseAllPositions();
}

//+------------------------------------------------------------------+
