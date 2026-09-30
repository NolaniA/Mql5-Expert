//+------------------------------------------------------------------+
//|                                       EMA_Grid_Scalping_8_12.mq5 |
//|                 Grid Scalping using EMA 8 / EMA 12 for MT5      |
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"

#include <Trade/Trade.mqh>
CTrade trade;

//-------------------------------------------------------------------
// Inputs
//-------------------------------------------------------------------
input group "=== Signal ==="
input ENUM_TIMEFRAMES SignalTimeframe      = PERIOD_M1;
input int             FastEMAPeriod        = 8;
input int             SlowEMAPeriod        = 12;
input bool            RequireCrossFirst    = false;   // false = enter with current EMA trend
input bool            CloseOnReverse       = true;    // close basket when EMA direction reverses

input group "=== Grid ==="
input double          StartLot             = 0.01;
input double          LotMultiplier        = 1.00;    // 1.00 = fixed lot
input int             GridStepPoints       = 300;     // XAUUSD 2 digits: 300 points = $3.00
input int             MaxGridLevels        = 5;       // includes first position
input int             MinSecondsBetweenAdd = 10;

input group "=== Basket Exit ==="
input double          BasketTakeProfitMoney = 3.00;   // account currency; 0 = disable
input double          BasketStopLossMoney   = 0.00;   // 0 = disable
input int             BasketTakeProfitPoints= 0;      // weighted-average target; 0 = disable

input group "=== Safety ==="
input int             MaxSpreadPoints       = 80;     // 0 = disable
input double          MaxEquityDrawdownPct  = 10.0;   // close EA positions; 0 = disable
input bool            OneBasketOnly         = true;

input group "=== Trade ==="
input ulong           MagicNumber           = 2609230812;
input int             SlippagePoints        = 30;
input string          TradeComment          = "EMA8_12_GRID";

//-------------------------------------------------------------------
// Globals
//-------------------------------------------------------------------
int      fastHandle = INVALID_HANDLE;
int      slowHandle = INVALID_HANDLE;
datetime lastEntryTime = 0;
datetime lastSignalBar = 0;

//-------------------------------------------------------------------
// Helpers
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
   if(step >= 1.0)       digits = 0;
   else if(step >= 0.1)  digits = 1;
   else if(step >= 0.01) digits = 2;
   else if(step >= 0.001)digits = 3;
   else                  digits = 4;

   return NormalizeDouble(result, digits);
}

// Return:
//  1 = BUY trend
// -1 = SELL trend
//  0 = neutral/error
int GetTrend()
{
   double fast[];
   double slow[];

   ArrayResize(fast, 3);
   ArrayResize(slow, 3);
   ArraySetAsSeries(fast, true);
   ArraySetAsSeries(slow, true);

   // Use completed candles: shift 1 and 2
   if(CopyBuffer(fastHandle, 0, 1, 3, fast) < 3)
      return 0;

   if(CopyBuffer(slowHandle, 0, 1, 3, slow) < 3)
      return 0;

   if(fast[0] > slow[0])
      return 1;

   if(fast[0] < slow[0])
      return -1;

   return 0;
}

bool HasFreshCross(int direction)
{
   double fast[];
   double slow[];

   ArrayResize(fast, 3);
   ArrayResize(slow, 3);
   ArraySetAsSeries(fast, true);
   ArraySetAsSeries(slow, true);

   if(CopyBuffer(fastHandle, 0, 1, 3, fast) < 3)
      return false;

   if(CopyBuffer(slowHandle, 0, 1, 3, slow) < 3)
      return false;

   if(direction == 1)
      return (fast[0] > slow[0] && fast[1] <= slow[1]);

   if(direction == -1)
      return (fast[0] < slow[0] && fast[1] >= slow[1]);

   return false;
}

int CountPositions(int direction = 0)
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

      ENUM_POSITION_TYPE type =
         (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      if(direction == 1 && type != POSITION_TYPE_BUY)
         continue;

      if(direction == -1 && type != POSITION_TYPE_SELL)
         continue;

      count++;
   }

   return count;
}

double GetBasketProfit()
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

double GetTotalVolume(int direction)
{
   double volume = 0.0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;

      ENUM_POSITION_TYPE type =
         (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      if(direction == 1 && type != POSITION_TYPE_BUY)
         continue;

      if(direction == -1 && type != POSITION_TYPE_SELL)
         continue;

      volume += PositionGetDouble(POSITION_VOLUME);
   }

   return volume;
}

double GetWeightedAveragePrice(int direction)
{
   double weighted = 0.0;
   double volume   = 0.0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;

      ENUM_POSITION_TYPE type =
         (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      if(direction == 1 && type != POSITION_TYPE_BUY)
         continue;

      if(direction == -1 && type != POSITION_TYPE_SELL)
         continue;

      double lot   = PositionGetDouble(POSITION_VOLUME);
      double price = PositionGetDouble(POSITION_PRICE_OPEN);

      weighted += price * lot;
      volume   += lot;
   }

   if(volume <= 0.0)
      return 0.0;

   return weighted / volume;
}

bool GetLatestEntry(int direction, double &price, long &timeMsc)
{
   bool found = false;
   price   = 0.0;
   timeMsc = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;

      ENUM_POSITION_TYPE type =
         (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      if(direction == 1 && type != POSITION_TYPE_BUY)
         continue;

      if(direction == -1 && type != POSITION_TYPE_SELL)
         continue;

      long posTime = (long)PositionGetInteger(POSITION_TIME_MSC);

      if(!found || posTime > timeMsc)
      {
         timeMsc = posTime;
         price   = PositionGetDouble(POSITION_PRICE_OPEN);
         found   = true;
      }
   }

   return found;
}

bool CloseAllPositions()
{
   bool result = true;

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
         Print("Close failed. ticket=", ticket,
               " retcode=", trade.ResultRetcode(),
               " ", trade.ResultRetcodeDescription());
         result = false;
      }
   }

   return result;
}

bool SpreadOK()
{
   if(MaxSpreadPoints <= 0)
      return true;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return false;

   double spreadPoints = (tick.ask - tick.bid) / _Point;
   return spreadPoints <= MaxSpreadPoints;
}

bool OpenPosition(int direction, int level)
{
   if(!SpreadOK())
      return false;

   double lot = StartLot * MathPow(LotMultiplier, level);
   lot = NormalizeVolume(lot);

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);

   bool sent = false;

   if(direction == 1)
      sent = trade.Buy(lot, _Symbol, 0.0, 0.0, 0.0, TradeComment);
   else if(direction == -1)
      sent = trade.Sell(lot, _Symbol, 0.0, 0.0, 0.0, TradeComment);

   if(sent)
   {
      lastEntryTime = TimeCurrent();
      Print("OPEN ", direction == 1 ? "BUY" : "SELL",
            " level=", level + 1,
            " lot=", DoubleToString(lot, 2));
      return true;
   }

   Print("Open failed. retcode=", trade.ResultRetcode(),
         " ", trade.ResultRetcodeDescription());
   return false;
}

bool BasketPointTargetHit()
{
   if(BasketTakeProfitPoints <= 0)
      return false;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return false;

   int buys  = CountPositions(1);
   int sells = CountPositions(-1);

   if(buys > 0 && sells == 0)
   {
      double avg = GetWeightedAveragePrice(1);
      if(avg > 0.0 && tick.bid >= avg + BasketTakeProfitPoints * _Point)
         return true;
   }

   if(sells > 0 && buys == 0)
   {
      double avg = GetWeightedAveragePrice(-1);
      if(avg > 0.0 && tick.ask <= avg - BasketTakeProfitPoints * _Point)
         return true;
   }

   return false;
}

bool EquityProtectionTriggered()
{
   if(MaxEquityDrawdownPct <= 0.0)
      return false;

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);

   if(balance <= 0.0)
      return false;

   double ddPct = (balance - equity) / balance * 100.0;
   return ddPct >= MaxEquityDrawdownPct;
}

bool ManageBasketExit()
{
   int total = CountPositions();
   if(total <= 0)
      return false;

   double basketProfit = GetBasketProfit();

   if(BasketTakeProfitMoney > 0.0 &&
      basketProfit >= BasketTakeProfitMoney)
   {
      Print("Basket TP money hit: ", basketProfit);
      CloseAllPositions();
      lastSignalBar = iTime(_Symbol, SignalTimeframe, 0);
      return true;
   }

   if(BasketStopLossMoney > 0.0 &&
      basketProfit <= -BasketStopLossMoney)
   {
      Print("Basket SL money hit: ", basketProfit);
      CloseAllPositions();
      lastSignalBar = iTime(_Symbol, SignalTimeframe, 0);
      return true;
   }

   if(BasketPointTargetHit())
   {
      Print("Basket TP points hit.");
      CloseAllPositions();
      lastSignalBar = iTime(_Symbol, SignalTimeframe, 0);
      return true;
   }

   if(EquityProtectionTriggered())
   {
      Print("Equity protection triggered.");
      CloseAllPositions();
      lastSignalBar = iTime(_Symbol, SignalTimeframe, 0);
      return true;
   }

   return false;
}

void ManageReverse(int trend)
{
   if(!CloseOnReverse || trend == 0)
      return;

   int buys  = CountPositions(1);
   int sells = CountPositions(-1);

   if(trend == 1 && sells > 0)
   {
      Print("EMA reversed to BUY -> close SELL basket.");
      CloseAllPositions();
   }
   else if(trend == -1 && buys > 0)
   {
      Print("EMA reversed to SELL -> close BUY basket.");
      CloseAllPositions();
   }
}

void ManageGrid(int trend)
{
   if(trend == 0)
      return;

   int total = CountPositions();

   // First entry
   if(total == 0)
   {
      if(RequireCrossFirst && !HasFreshCross(trend))
         return;

      datetime currentBar = iTime(_Symbol, SignalTimeframe, 0);
      if(currentBar == 0)
         return;

      // prevents repeated first-entry attempts in the same bar
      if(currentBar == lastSignalBar)
         return;

      if(OpenPosition(trend, 0))
         lastSignalBar = currentBar;

      return;
   }

   // Do not mix BUY and SELL baskets
   int sameSide = CountPositions(trend);
   int otherSide = CountPositions(-trend);

   if(otherSide > 0)
      return;

   if(OneBasketOnly && sameSide <= 0)
      return;

   if(sameSide >= MaxGridLevels)
      return;

   if((TimeCurrent() - lastEntryTime) < MinSecondsBetweenAdd)
      return;

   double latestPrice;
   long   latestTime;

   if(!GetLatestEntry(trend, latestPrice, latestTime))
      return;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return;

   double step = GridStepPoints * _Point;

   // Grid averaging:
   // BUY adds when price falls from latest BUY.
   // SELL adds when price rises from latest SELL.
   if(trend == 1 && tick.bid <= latestPrice - step)
      OpenPosition(1, sameSide);

   if(trend == -1 && tick.ask >= latestPrice + step)
      OpenPosition(-1, sameSide);
}

//-------------------------------------------------------------------
// Expert lifecycle
//-------------------------------------------------------------------
int OnInit()
{
   if(FastEMAPeriod <= 0 ||
      SlowEMAPeriod <= 0 ||
      FastEMAPeriod >= SlowEMAPeriod)
   {
      Print("Invalid EMA settings.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(StartLot <= 0.0 ||
      GridStepPoints <= 0 ||
      MaxGridLevels <= 0 ||
      LotMultiplier <= 0.0)
   {
      Print("Invalid grid settings.");
      return INIT_PARAMETERS_INCORRECT;
   }

   fastHandle = iMA(_Symbol,
                    SignalTimeframe,
                    FastEMAPeriod,
                    0,
                    MODE_EMA,
                    PRICE_CLOSE);

   slowHandle = iMA(_Symbol,
                    SignalTimeframe,
                    SlowEMAPeriod,
                    0,
                    MODE_EMA,
                    PRICE_CLOSE);

   if(fastHandle == INVALID_HANDLE ||
      slowHandle == INVALID_HANDLE)
   {
      Print("Failed to create EMA handles.");
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);

   Print("EMA Grid Scalping 8/12 initialized.");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(fastHandle != INVALID_HANDLE)
      IndicatorRelease(fastHandle);

   if(slowHandle != INVALID_HANDLE)
      IndicatorRelease(slowHandle);
}

void OnTick()
{
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
      return;

   // Manage exits first. Do not reopen in the same tick after a basket exit.
   if(ManageBasketExit())
      return;

   int trend = GetTrend();
   if(trend == 0)
      return;

   ManageReverse(trend);

   // If reverse handling closed positions, ManageGrid can start new basket.
   ManageGrid(trend);
}
//+------------------------------------------------------------------+
