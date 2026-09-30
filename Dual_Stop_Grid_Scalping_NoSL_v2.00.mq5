//+------------------------------------------------------------------+
//|                           Dual_Stop_Grid_Scalping_NoSL_v2.00.mq5 |
//| Buy Stop 10 levels + Sell Stop 10 levels, close all on basket TP |
//+------------------------------------------------------------------+
#property strict
#property version   "2.00"

#include <Trade/Trade.mqh>
CTrade trade;

//-------------------------------------------------------------------
// Inputs
//-------------------------------------------------------------------
input group "=== Grid ==="
input int      GridLevels            = 10;      // Pending orders per side
input int      GridStepPoints        = 300;     // Distance between each grid level
input int      FirstStopDistancePts  = 300;     // Distance from current price to first stop
input double   FixedLot              = 0.01;    // Fixed lot for every pending order

input group "=== Basket Profit ==="
input double   CloseAllProfitMoney   = 1.00;    // Close all positions when floating profit >= this
input int      RestartDelaySeconds   = 3;       // Delay before creating a new grid round

input group "=== Trade ==="
input ulong    MagicNumber           = 2609231010;
input int      SlippagePoints        = 30;
input bool     DebugLog              = true;
input string   TradeComment          = "DUAL_STOP_GRID";

//-------------------------------------------------------------------
// Globals
//-------------------------------------------------------------------
datetime g_lastCloseTime = 0;
bool     g_gridSeeded    = false;

//-------------------------------------------------------------------
// Utility
//-------------------------------------------------------------------
double NormalizeVolume(double volume)
{
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(step <= 0.0)
      step = minLot;

   volume = MathMax(minLot, MathMin(maxLot, volume));

   double steps = MathFloor((volume - minLot) / step + 0.5);
   double result = minLot + steps * step;

   int digits = 2;
   if(step >= 1.0)        digits = 0;
   else if(step >= 0.1)   digits = 1;
   else if(step >= 0.01)  digits = 2;
   else if(step >= 0.001) digits = 3;
   else                   digits = 4;

   return NormalizeDouble(result, digits);
}

double NormalizePrice(double price)
{
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tickSize <= 0.0)
      return NormalizeDouble(price, _Digits);

   price = MathRound(price / tickSize) * tickSize;
   return NormalizeDouble(price, _Digits);
}

int CountOurPositions()
{
   int count = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);

      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;

      count++;
   }

   return count;
}

int CountOurPending(ENUM_ORDER_TYPE wantedType)
{
   int count = 0;

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);

      if(ticket == 0)
         continue;

      if(OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;

      if((ulong)OrderGetInteger(ORDER_MAGIC) != MagicNumber)
         continue;

      ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);

      if(type == wantedType)
         count++;
   }

   return count;
}

int CountAllOurPending()
{
   int count = 0;

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);

      if(ticket == 0)
         continue;

      if(OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;

      if((ulong)OrderGetInteger(ORDER_MAGIC) != MagicNumber)
         continue;

      ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);

      if(type == ORDER_TYPE_BUY_STOP ||
         type == ORDER_TYPE_SELL_STOP ||
         type == ORDER_TYPE_BUY_LIMIT ||
         type == ORDER_TYPE_SELL_LIMIT ||
         type == ORDER_TYPE_BUY_STOP_LIMIT ||
         type == ORDER_TYPE_SELL_STOP_LIMIT)
      {
         count++;
      }
   }

   return count;
}

double BasketFloatingProfit()
{
   double profit = 0.0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);

      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;

      profit += PositionGetDouble(POSITION_PROFIT);
      profit += PositionGetDouble(POSITION_SWAP);
   }

   return profit;
}

//-------------------------------------------------------------------
// Close/delete everything belonging to this EA
//-------------------------------------------------------------------
bool DeleteAllPending()
{
   bool allOK = true;

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);

      if(ticket == 0)
         continue;

      if(OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;

      if((ulong)OrderGetInteger(ORDER_MAGIC) != MagicNumber)
         continue;

      ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);

      bool isPending =
         (type == ORDER_TYPE_BUY_STOP ||
          type == ORDER_TYPE_SELL_STOP ||
          type == ORDER_TYPE_BUY_LIMIT ||
          type == ORDER_TYPE_SELL_LIMIT ||
          type == ORDER_TYPE_BUY_STOP_LIMIT ||
          type == ORDER_TYPE_SELL_STOP_LIMIT);

      if(!isPending)
         continue;

      if(!trade.OrderDelete(ticket))
      {
         allOK = false;

         if(DebugLog)
            Print("DELETE FAILED | ticket=", ticket,
                  " retcode=", trade.ResultRetcode(),
                  " desc=", trade.ResultRetcodeDescription());
      }
   }

   return allOK;
}

bool CloseAllPositions()
{
   bool allOK = true;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);

      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;

      if(!trade.PositionClose(ticket))
      {
         allOK = false;

         if(DebugLog)
            Print("CLOSE FAILED | ticket=", ticket,
                  " retcode=", trade.ResultRetcode(),
                  " desc=", trade.ResultRetcodeDescription());
      }
   }

   return allOK;
}

void CloseEverything()
{
   // Cancel pending first so no new order can trigger while closing.
   DeleteAllPending();
   CloseAllPositions();

   // One extra cleanup pass in case the trade pool changed while closing.
   DeleteAllPending();

   g_gridSeeded = false;
   g_lastCloseTime = TimeCurrent();
}

//-------------------------------------------------------------------
// Pending grid
//-------------------------------------------------------------------
bool PlaceBuyStop(double lot, double price, int level)
{
   price = NormalizePrice(price);

   bool ok = trade.BuyStop(
      lot,
      price,
      _Symbol,
      0.0,                    // NO STOP LOSS
      0.0,                    // NO per-order TP
      ORDER_TIME_GTC,
      0,
      TradeComment + "_BS_" + IntegerToString(level)
   );

   if(!ok && DebugLog)
   {
      Print("BUY STOP FAILED | level=", level,
            " price=", DoubleToString(price, _Digits),
            " retcode=", trade.ResultRetcode(),
            " desc=", trade.ResultRetcodeDescription());
   }

   return ok;
}

bool PlaceSellStop(double lot, double price, int level)
{
   price = NormalizePrice(price);

   bool ok = trade.SellStop(
      lot,
      price,
      _Symbol,
      0.0,                    // NO STOP LOSS
      0.0,                    // NO per-order TP
      ORDER_TIME_GTC,
      0,
      TradeComment + "_SS_" + IntegerToString(level)
   );

   if(!ok && DebugLog)
   {
      Print("SELL STOP FAILED | level=", level,
            " price=", DoubleToString(price, _Digits),
            " retcode=", trade.ResultRetcode(),
            " desc=", trade.ResultRetcodeDescription());
   }

   return ok;
}

bool SeedNewGrid()
{
   if(GridLevels <= 0 ||
      GridStepPoints <= 0 ||
      FirstStopDistancePts <= 0 ||
      FixedLot <= 0.0)
   {
      Print("INVALID GRID SETTINGS");
      return false;
   }

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return false;

   // Broker minimum pending-order distance.
   int brokerStopsLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);

   int firstDistance = MathMax(FirstStopDistancePts, brokerStopsLevel + 1);
   int stepDistance  = MathMax(GridStepPoints, 1);

   double lot = NormalizeVolume(FixedLot);

   int buyCreated  = 0;
   int sellCreated = 0;

   // Snapshot current price for this grid round.
   double baseAsk = tick.ask;
   double baseBid = tick.bid;

   for(int level = 1; level <= GridLevels; level++)
   {
      int distancePts = firstDistance + (level - 1) * stepDistance;

      double buyPrice  = baseAsk + distancePts * _Point;
      double sellPrice = baseBid - distancePts * _Point;

      if(PlaceBuyStop(lot, buyPrice, level))
         buyCreated++;

      if(PlaceSellStop(lot, sellPrice, level))
         sellCreated++;
   }

   if(DebugLog)
   {
      Print("GRID SEEDED | BuyStop=", buyCreated,
            "/", GridLevels,
            " SellStop=", sellCreated,
            "/", GridLevels,
            " lot=", DoubleToString(lot, 2),
            " firstDistancePts=", firstDistance,
            " stepPts=", stepDistance);
   }

   // Mark as seeded if at least one side has orders.
   g_gridSeeded = (buyCreated > 0 || sellCreated > 0);

   return g_gridSeeded;
}

//-------------------------------------------------------------------
// Main management
//-------------------------------------------------------------------
void ManageBasketProfit()
{
   int positions = CountOurPositions();

   if(positions <= 0)
      return;

   double profit = BasketFloatingProfit();

   if(DebugLog)
   {
      static datetime lastLog = 0;
      datetime now = TimeCurrent();

      if(now - lastLog >= 5)
      {
         lastLog = now;
         Print("BASKET | positions=", positions,
               " floatingProfit=", DoubleToString(profit, 2),
               " target=", DoubleToString(CloseAllProfitMoney, 2));
      }
   }

   if(CloseAllProfitMoney > 0.0 &&
      profit >= CloseAllProfitMoney)
   {
      Print("BASKET PROFIT TARGET HIT | profit=",
            DoubleToString(profit, 2),
            " -> CLOSE ALL + DELETE PENDING");

      CloseEverything();
   }
}

void EnsureGrid()
{
   int positions   = CountOurPositions();
   int pendingAll  = CountAllOurPending();

   // During an active basket, keep the remaining original pending grid.
   // Do NOT rebuild consumed levels.
   if(positions > 0)
      return;

   // Existing pending orders mean the current grid is already active.
   if(pendingAll > 0)
   {
      g_gridSeeded = true;
      return;
   }

   // No positions and no pending orders = start a new round.
   if(g_lastCloseTime > 0 &&
      (TimeCurrent() - g_lastCloseTime) < RestartDelaySeconds)
      return;

   SeedNewGrid();
}

//-------------------------------------------------------------------
// Expert lifecycle
//-------------------------------------------------------------------
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);
   trade.SetAsyncMode(false);

   ENUM_ACCOUNT_MARGIN_MODE marginMode =
      (ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE);

   if(marginMode != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
   {
      Print("WARNING: This EA is designed for a HEDGING account. ",
            "On a NETTING account, BUY and SELL positions cannot remain independently hedged.");
   }

   Print("Dual Stop Grid NoSL v2.00 initialized",
         " | symbol=", _Symbol,
         " | BuyStop=", GridLevels,
         " | SellStop=", GridLevels,
         " | No SL",
         " | BasketTarget=", DoubleToString(CloseAllProfitMoney, 2));

   return INIT_SUCCEEDED;
}

void OnTick()
{
   // 1) Profit check has priority.
   ManageBasketProfit();

   // 2) If the previous step closed everything, wait/reseed.
   EnsureGrid();
}
//+------------------------------------------------------------------+
