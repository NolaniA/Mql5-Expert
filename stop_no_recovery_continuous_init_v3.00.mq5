//+------------------------------------------------------------------+
//|                    stop_no_recovery_continuous_init_v3.00.mq5   |
//|                                  Copyright 2025, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
//
// Logic:
// 1) RECOVERY removed completely.
// 2) INIT BUY STOP / SELL STOP use the normal dynamic distance.
// 3) Position count is NOT used to decide whether a new INIT order may open.
// 4) If there is no BUY STOP pending -> create INIT BUY STOP.
// 5) If there is no SELL STOP pending -> create INIT SELL STOP.
// 6) Therefore a filled side can be replenished continuously while old
//    positions remain open.
// 7) If BOTH BUY and SELL positions exist and BasketProfit >= target,
//    close all positions and delete all pending orders.
// 8) Existing risk limits remain active.
//
// IMPORTANT:
// - This EA requires an MT5 HEDGING account.
// - No Recovery / EMA Recovery / LIMIT Recovery / Recovery levels exist.
// - Test in Strategy Tester / demo before live use.
//+------------------------------------------------------------------+

#property copyright "Copyright 2025, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "3.00"
#property strict
#property description "Continuous INIT straddle without Recovery"

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

// Basket target is evaluated when BOTH BUY and SELL positions exist.
input double BasketTargetProfit = 1.0;

//==================================================================
// RISK LIMITS
// 0 = disabled.
//==================================================================
input double MaxTotalLot = 0.80;
input double MaxBasketLoss = 50.0;
input double MaxBasketDrawdownPercent = 0.50;
input int MaxBasketHoldingHours = 48;

//==================================================================
// GLOBAL STATE
//==================================================================
int PendingBuy = 0;
int PendingSell = 0;

int PositionBuy = 0;
int PositionSell = 0;

int AtrHandle = INVALID_HANDLE;

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
// PROTOTYPES
//==================================================================
void LoadTradeState();

double GetATRPoints();
double GetSpreadPoints();
int GetInitialDistancePoint();

double NormalizeBuyPrice(double price);
double NormalizeSellPrice(double price);
double NormalizeVolume(double volume);

bool IsTradeSuccess();

bool PlaceBuyStop(double lot, string comment, ulong &ticket);
bool PlaceSellStop(double lot, string comment, ulong &ticket);

void EnsureInitialOrders();

void ModifyBuyStop();
void ModifySellStop();

void GetBasketStats(BasketStats &stats);

void CloseAllPositions();
void DeleteAllPendingOrders();
bool DeleteOrderTicket(ulong ticket);

void CloseBasket(string reason, double basketProfit);

bool HandleRiskLimits(BasketStats &stats);
datetime GetOldestPositionTime();

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
            " Dynamic distance will fall back to Base/Spread/Slippage/Broker minimum."
         );
      }
   }

   Print(
      "INIT OK",
      " | Recovery=DISABLED",
      " | BaseLot=", BaseLot,
      " | InitialBaseDistance=", InitialBaseDistancePoint,
      " | ATRPeriod=", ATRPeriod,
      " | InitialATRMultiplier=", InitialATRMultiplier,
      " | SpreadMultiplier=", SpreadMultiplier,
      " | SlippagePoint=", SlippagePoint,
      " | MaxTotalLot=", MaxTotalLot
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
   LoadTradeState();

   BasketStats stats;
   GetBasketStats(stats);

   //===============================================================
   // RISK LIMITS
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
   // BASKET TARGET
   // Keep the existing behavior: close basket only when BOTH sides
   // already have at least one open position.
   //===============================================================
   if(
      stats.buyCount > 0 &&
      stats.sellCount > 0 &&
      stats.totalProfit >= BasketTargetProfit
   )
   {
      CloseBasket(
         "BASKET TARGET",
         stats.totalProfit
      );

      return;
   }

   //===============================================================
   // CONTINUOUS INIT
   // IMPORTANT: NO PositionBuy == 0 / PositionSell == 0 check.
   // Only pending-order state controls new INIT orders.
   //===============================================================
   EnsureInitialOrders();

   // Refresh state after possible order creation.
   LoadTradeState();

   // Trail current INIT pending orders.
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
   // Only INIT STOP orders are used in this version.
   //===============================================================
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
         (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);

      if(type == ORDER_TYPE_BUY_STOP)
         PendingBuy++;
      else
      if(type == ORDER_TYPE_SELL_STOP)
         PendingSell++;
   }

   //===============================================================
   // POSITIONS
   // Position counts are kept only for basket/risk statistics.
   // They are NOT used by EnsureInitialOrders().
   //===============================================================
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
         (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      if(type == POSITION_TYPE_BUY)
         PositionBuy++;
      else
      if(type == POSITION_TYPE_SELL)
         PositionSell++;
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
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

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
      MathMax(stopLevel, freezeLevel) + 1;

   int baseDistance =
      MathMax(InitialBaseDistancePoint, 1);

   double atrDistance =
      GetATRPoints() *
      MathMax(InitialATRMultiplier, 0.0);

   double spreadBuffer =
      GetSpreadPoints() *
      MathMax(SpreadMultiplier, 0.0);

   double slippageBuffer =
      MathMax((double)SlippagePoint, 0.0) *
      MathMax(SlippageBufferMultiplier, 0.0);

   int dynamicDistance =
      (int)MathCeil(
         atrDistance +
         spreadBuffer +
         slippageBuffer
      );

   int minimumRequired =
      MathMax(baseDistance, brokerMinimum);

   int distance =
      MathMax(minimumRequired, dynamicDistance);

   if(
      MaxInitialDynamicDistancePoint > 0 &&
      MaxInitialDynamicDistancePoint >= minimumRequired
   )
   {
      distance = MathMin(
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
      return NormalizeDouble(price, _Digits);

   price =
      MathCeil(price / tickSize) * tickSize;

   return NormalizeDouble(price, _Digits);
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
      return NormalizeDouble(price, _Digits);

   price =
      MathFloor(price / tickSize) * tickSize;

   return NormalizeDouble(price, _Digits);
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

   volume = MathMax(
      minVolume,
      MathMin(maxVolume, volume)
   );

   double steps =
      MathRound(
         (volume - minVolume) /
         step
      );

   double normalized =
      minVolume +
      (steps * step);

   normalized = MathMax(
      minVolume,
      MathMin(maxVolume, normalized)
   );

   return NormalizeDouble(normalized, 8);
}

//+------------------------------------------------------------------+
//| Check Trade Result                                               |
//+------------------------------------------------------------------+
bool IsTradeSuccess()
{
   uint retcode = trade.ResultRetcode();

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

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(ask <= 0)
      return false;

   lot = NormalizeVolume(lot);

   int distancePoint = GetInitialDistancePoint();

   double price =
      NormalizeBuyPrice(
         ask +
         (distancePoint * _Point)
      );

   bool requestResult = trade.BuyStop(
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

   ticket = trade.ResultOrder();

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

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(bid <= 0)
      return false;

   lot = NormalizeVolume(lot);

   int distancePoint = GetInitialDistancePoint();

   double price =
      NormalizeSellPrice(
         bid -
         (distancePoint * _Point)
      );

   bool requestResult = trade.SellStop(
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

   ticket = trade.ResultOrder();

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
//| Continuous INIT Orders                                           |
//|                                                                  |
//| IMPORTANT: PositionBuy / PositionSell are deliberately NOT used. |
//| Only the existence of pending orders controls order creation.    |
//+------------------------------------------------------------------+
void EnsureInitialOrders()
{
   ulong ticket = 0;

   // No BUY STOP pending -> create a new BUY STOP.
   // Existing BUY positions do NOT block this.
   if(PendingBuy == 0)
   {
      PlaceBuyStop(
         BaseLot,
         "INIT BUY",
         ticket
      );
   }

   // No SELL STOP pending -> create a new SELL STOP.
   // Existing SELL positions do NOT block this.
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
//+------------------------------------------------------------------+
void ModifyBuyStop()
{
   if(PendingBuy == 0)
      return;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(ask <= 0)
      return;

   int distancePoint = GetInitialDistancePoint();

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
         (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);

      if(type != ORDER_TYPE_BUY_STOP)
         continue;

      double oldPrice =
         OrderGetDouble(ORDER_PRICE_OPEN);

      double distance =
         (oldPrice - ask) /
         _Point;

      if(distance <= distancePoint)
         continue;

      double newPrice =
         NormalizeBuyPrice(
            ask +
            (distancePoint * _Point)
         );

      if(
         MathAbs(newPrice - oldPrice) <
         (_Point / 2.0)
      )
         continue;

      bool requestResult = trade.OrderModify(
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
//+------------------------------------------------------------------+
void ModifySellStop()
{
   if(PendingSell == 0)
      return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(bid <= 0)
      return;

   int distancePoint = GetInitialDistancePoint();

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
         (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);

      if(type != ORDER_TYPE_SELL_STOP)
         continue;

      double oldPrice =
         OrderGetDouble(ORDER_PRICE_OPEN);

      double distance =
         (bid - oldPrice) /
         _Point;

      if(distance <= distancePoint)
         continue;

      double newPrice =
         NormalizeSellPrice(
            bid -
            (distancePoint * _Point)
         );

      if(
         MathAbs(newPrice - oldPrice) <
         (_Point / 2.0)
      )
         continue;

      bool requestResult = trade.OrderModify(
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
      ulong ticket = PositionGetTicket(i);

      if(ticket == 0)
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if((ulong)PositionGetInteger(POSITION_MAGIC) != Magic)
         continue;

      ENUM_POSITION_TYPE type =
         (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      double profit =
         PositionGetDouble(POSITION_PROFIT);

      double swap =
         PositionGetDouble(POSITION_SWAP);

      double volume =
         PositionGetDouble(POSITION_VOLUME);

      double positionPnl =
         profit + swap;

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
      ulong ticket = PositionGetTicket(i);

      if(ticket == 0)
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if((ulong)PositionGetInteger(POSITION_MAGIC) != Magic)
         continue;

      bool result = trade.PositionClose(
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
//| Deletes every pending type for this Symbol+Magic, including old  |
//| LIMIT orders that may have been left by an older Recovery build. |
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
         (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);

      if(
         type != ORDER_TYPE_BUY_STOP &&
         type != ORDER_TYPE_SELL_STOP &&
         type != ORDER_TYPE_BUY_LIMIT &&
         type != ORDER_TYPE_SELL_LIMIT &&
         type != ORDER_TYPE_BUY_STOP_LIMIT &&
         type != ORDER_TYPE_SELL_STOP_LIMIT
      )
         continue;

      DeleteOrderTicket(ticket);
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

   // Delete pending first so a new stop cannot trigger while positions
   // are being closed one by one.
   DeleteAllPendingOrders();
   CloseAllPositions();
}

//+------------------------------------------------------------------+
//| Risk Limits                                                      |
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
         AccountInfoDouble(ACCOUNT_BALANCE);

      if(balance > 0)
      {
         double basketDrawdownPercent =
            (-stats.totalProfit / balance) * 100.0;

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
