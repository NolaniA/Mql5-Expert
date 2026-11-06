//+------------------------------------------------------------------+
//|        XAU_SMA8_9_M15_M5_Recovery_Basket_SlopeCrossFilter_v112.mq5    |
//| M15 closed-candle SMA 8/9 bias; evaluate M5 closed candle [1].  |
//| Every M5 bar: base lot or last same-side lot x 1.5 if adverse. |
//| Block entries on recent M15 SMA crosses; narrow gap blocks adds. |
//+------------------------------------------------------------------+
#property strict
#property version   "1.12"
#property description "M15 SMA8/9 cross lookback and gap filter, M5 entries, basket close"

#include <Trade/Trade.mqh>
CTrade trade;

//====================================================================
// INPUTS
//====================================================================
input group "=== General ==="
input bool   EnableTrading          = false;      // Set true after testing
input ulong  MagicNumber            = 26103101;
input int    SlippagePoints         = 30;

input group "=== M15 Trend (SMA) ==="
input int    FastSMAPeriod          = 8;
input int    SlowSMAPeriod          = 9;
input bool   UseSMASlopeNarrowingFilter = true; // Block extra orders when the M15 SMA8/9 gap shrinks
input bool   UseRecentSMACrossFilter = true; // Block ALL new entries if SMA8/9 crossed in lookback
input int    SMACrossLookbackBars    = 10;   // Last 10 closed M15 bars: compare [1]/[2] ... [10]/[11]

input group "=== Position sizing / recovery ==="
input double InitialLot             = 0.01;
input double LotMultiplier          = 1.5;
input int    MaxPositionsPerSide    = 0;          // 0 = unlimited
input double MaxLotPerPosition      = 0.0;        // 0 = broker maximum

input group "=== BUY + SELL basket exit ==="
input bool   CloseBothSides         = true;
input bool   CloseBasketAtProfit    = false;      // false = close immediately when both sides exist
input double BasketProfitTarget    = 0.0;        // account currency; 0 = any positive floating P/L

//====================================================================
// STATE
//====================================================================
int      g_fast_sma      = INVALID_HANDLE;
int      g_slow_sma      = INVALID_HANDLE;
datetime g_last_m5_bar   = 0;
bool     g_closingBasket = false;

struct SideState
{
   int    count;
   ulong  latestTicket;
   long   latestTimeMsc;
   double latestOpenPrice;
   double latestVolume;
};

void ResetSide(SideState &s)
{
   s.count           = 0;
   s.latestTicket    = 0;
   s.latestTimeMsc   = -1;
   s.latestOpenPrice = 0.0;
   s.latestVolume    = 0.0;
}

// Track the most recently opened position on a given side.
void UpdateSideState(SideState &side, const ulong ticket)
{
   ++side.count;
   long posTime = PositionGetInteger(POSITION_TIME_MSC);
   if(posTime > side.latestTimeMsc ||
      (posTime == side.latestTimeMsc && ticket > side.latestTicket))
   {
      side.latestTimeMsc   = posTime;
      side.latestTicket    = ticket;
      side.latestOpenPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      side.latestVolume    = PositionGetDouble(POSITION_VOLUME);
   }
}

// Only work on this chart symbol + this EA's MagicNumber.
void ReadMyPositions(SideState &buys, SideState &sells,
                     double &basketProfit, int &totalCount)
{
   ResetSide(buys);
   ResetSide(sells);
   basketProfit = 0.0;
   totalCount   = 0;

   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;

      ++totalCount;
      basketProfit += PositionGetDouble(POSITION_PROFIT);
      basketProfit += PositionGetDouble(POSITION_SWAP);

      ENUM_POSITION_TYPE type =
         (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if(type == POSITION_TYPE_BUY)
         UpdateSideState(buys, ticket);
      else if(type == POSITION_TYPE_SELL)
         UpdateSideState(sells, ticket);
   }
}

// Exchange/broker lot steps may not allow exact 0.015 lots.
// Round UP to the next permitted step, never down.
double NormalizeLotUp(const double requested)
{
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(minLot <= 0.0 || maxLot <= 0.0 || step <= 0.0)
      return 0.0;

   double cap = maxLot;
   if(MaxLotPerPosition > 0.0)
      cap = MathMin(cap, MaxLotPerPosition);

   // A cap below minimum broker volume means no valid order can be sent.
   if(cap + 1e-9 < minLot)
      return 0.0;

   double wanted = MathMax(requested, minLot);
   double steps = MathCeil((wanted - minLot) / step - 1e-8);
   double volume = NormalizeDouble(minLot + MathMax(steps, 0.0) * step, 8);
   if(volume > cap + 1e-8)
      return 0.0;
   return volume;
}

bool ReadOne(const int handle, const int shift, double &outValue)
{
   double buffer[1];
   if(CopyBuffer(handle, 0, shift, 1, buffer) != 1)
      return false;
   outValue = buffer[0];
   return MathIsValidNumber(outValue) && outValue != EMPTY_VALUE;
}

// M15 SMA[1] is the most recent CLOSED M15 candle.
//  1=BUY, -1=SELL, 0=equal/no signal, 2=data unavailable.
int TrendDirection()
{
   double fast, slow;
   if(!ReadOne(g_fast_sma, 1, fast) || !ReadOne(g_slow_sma, 1, slow))
      return 2;
   if(fast > slow) return 1;
   if(fast < slow) return -1;
   return 0;
}

// Relative SMA slope = (SMA8[1] - SMA9[1]) - (SMA8[2] - SMA9[2]).
// Compare the ABSOLUTE gap on two CLOSED M15 candles so BUY and SELL
// are treated symmetrically. Narrowing = recent gap < previous gap.
// This gate applies ONLY when adding to an existing same-side position.
// Fail closed for additions if either SMA history value cannot be read.
bool AllowAddBySMASlope(const int existingSidePositions)
{
   if(!UseSMASlopeNarrowingFilter || existingSidePositions == 0)
      return true;

   double fast1, fast2, slow1, slow2;
   if(!ReadOne(g_fast_sma, 1, fast1) ||
      !ReadOne(g_fast_sma, 2, fast2) ||
      !ReadOne(g_slow_sma, 1, slow1) ||
      !ReadOne(g_slow_sma, 2, slow2))
   {
      Print("Additional entry blocked: M15 SMA slope data unavailable.");
      return false;
   }

   double gapNow  = MathAbs(fast1 - slow1);
   double gapPrev = MathAbs(fast2 - slow2);
   if(gapNow < gapPrev)
   {
      PrintFormat("Additional entry blocked: M15 SMA8/9 gap narrowing: "
                  "[2]=%.5f -> [1]=%.5f", gapPrev, gapNow);
      return false;
   }
   return true; // Wider or equal spread: allow the normal lot/entry rules.
}

// No SMA8/SMA9 crossing within the last N CLOSED M15 candles.
// Each bar [shift] is compared with the preceding closed bar [shift+1].
// A crossing on bar [10] is included by comparing [10] with [11].
// An exact SMA touch is also rejected to keep the gate conservative.
// This gate applies to BOTH initial entries and additional positions.
// Missing indicator data blocks entries (fail closed).
bool AllowEntryByRecentSMACross()
{
   if(!UseRecentSMACrossFilter)
      return true;

   double fastPrev, slowPrev;
   int oldestShift = SMACrossLookbackBars + 1;
   if(!ReadOne(g_fast_sma, oldestShift, fastPrev) ||
      !ReadOne(g_slow_sma, oldestShift, slowPrev))
   {
      Print("Entry blocked: M15 SMA cross lookback history unavailable.");
      return false;
   }

   double gapPrev = fastPrev - slowPrev;
   for(int shift = SMACrossLookbackBars; shift >= 1; --shift)
   {
      double fastNow, slowNow;
      if(!ReadOne(g_fast_sma, shift, fastNow) ||
         !ReadOne(g_slow_sma, shift, slowNow))
      {
         PrintFormat("Entry blocked: M15 SMA history unavailable at bar [%d].", shift);
         return false;
      }

      double gapNow = fastNow - slowNow;
      bool crossedOrTouched =
         (gapPrev <= 0.0 && gapNow >= 0.0) ||
         (gapPrev >= 0.0 && gapNow <= 0.0);
      if(crossedOrTouched)
      {
         PrintFormat("Entry blocked: M15 SMA8/9 crossed or touched at bar [%d] "
                     "(compared with [%d]); lookback=%d.",
                     shift, shift+1, SMACrossLookbackBars);
         return false;
      }
      gapPrev = gapNow;
   }
   return true;
}

bool OpenPosition(const ENUM_ORDER_TYPE type, const double volume,
                  const string comment)
{
   if(volume <= 0.0)
   {
      Print("Order skipped: requested lot exceeds allowed size or broker rules.");
      return false;
   }

   bool submitted = false;
   if(type == ORDER_TYPE_BUY)
      submitted = trade.Buy(volume, _Symbol, 0.0, 0.0, 0.0, comment);
   else if(type == ORDER_TYPE_SELL)
      submitted = trade.Sell(volume, _Symbol, 0.0, 0.0, 0.0, comment);

   uint rc = trade.ResultRetcode();
   if(!submitted || (rc != TRADE_RETCODE_DONE && rc != TRADE_RETCODE_DONE_PARTIAL))
   {
      PrintFormat("Open %s %.8f failed: retcode=%u %s",
                  EnumToString(type), volume, rc, trade.ResultRetcodeDescription());
      return false;
   }

   PrintFormat("Opened %s lot=%.8f (%s)", EnumToString(type), volume, comment);
   return true;
}

bool BasketTargetHit(const double profit)
{
   if(!CloseBasketAtProfit)
      return true;
   if(BasketProfitTarget <= 0.0)
      return profit > 0.0; // avoid closing exactly at zero
   return profit >= BasketProfitTarget;
}

// Once closing starts, keep trying remaining tickets, including if one
// side has already disappeared. Never add new orders during a close cycle.
void CloseAllMyPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; --i)
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
         PrintFormat("Close failed ticket=%I64u: retcode=%u %s",
                     ticket, trade.ResultRetcode(), trade.ResultRetcodeDescription());
      }
      else
      {
         uint rc = trade.ResultRetcode();
         if(rc != TRADE_RETCODE_DONE && rc != TRADE_RETCODE_DONE_PARTIAL)
            PrintFormat("Close not completed ticket=%I64u: retcode=%u %s",
                        ticket, rc, trade.ResultRetcodeDescription());
      }
   }
}

bool CheckAndCloseBasket()
{
   SideState buys, sells;
   double profit;
   int total;
   ReadMyPositions(buys, sells, profit, total);

   if(g_closingBasket)
   {
      if(total == 0)
      {
         g_closingBasket = false;
         return true;
      }
      CloseAllMyPositions();
      return true;
   }

   if(CloseBothSides && buys.count > 0 && sells.count > 0 &&
      BasketTargetHit(profit))
   {
      PrintFormat("Basket exit triggered: BUY=%d SELL=%d float=%.2f %s",
                  buys.count, sells.count, profit, AccountInfoString(ACCOUNT_CURRENCY));
      g_closingBasket = true;
      // Finish the basket before allowing another new M5 entry.
      g_last_m5_bar = iTime(_Symbol, PERIOD_M5, 0);
      CloseAllMyPositions();
      return true;
   }
   return false;
}

//====================================================================
// MQL5 LIFECYCLE
//====================================================================
int OnInit()
{
   if(FastSMAPeriod <= 0 || SlowSMAPeriod <= 0 ||
      InitialLot <= 0.0 || LotMultiplier <= 1.0 ||
      MaxPositionsPerSide < 0 || MaxLotPerPosition < 0.0 ||
      BasketProfitTarget < 0.0 || SlippagePoints < 0 ||
      SMACrossLookbackBars < 1 || SMACrossLookbackBars > 500)
   {
      Print("Invalid EA inputs.");
      return INIT_PARAMETERS_INCORRECT;
   }

   // Netting accounts cannot hold separate BUY and SELL on one symbol.
   if(AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
   {
      Print("This strategy requires an MT5 HEDGING account (not NETTING).");
      return INIT_FAILED;
   }

   g_fast_sma = iMA(_Symbol, PERIOD_M15, FastSMAPeriod, 0, MODE_SMA, PRICE_CLOSE);
   g_slow_sma = iMA(_Symbol, PERIOD_M15, SlowSMAPeriod, 0, MODE_SMA, PRICE_CLOSE);
   if(g_fast_sma == INVALID_HANDLE || g_slow_sma == INVALID_HANDLE)
   {
      PrintFormat("Cannot create M15 SMA handles: %d", GetLastError());
      return INIT_FAILED;
   }

   double baseLot = NormalizeLotUp(InitialLot);
   if(baseLot <= 0.0)
   {
      Print("InitialLot cannot be represented under broker lot rules and MaxLotPerPosition.");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(MathAbs(baseLot - InitialLot) > 1e-8)
      PrintFormat("WARNING: InitialLot %.8f rounded UP to %.8f for broker volume step.",
                  InitialLot, baseLot);

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetAsyncMode(false);

   g_last_m5_bar = iTime(_Symbol, PERIOD_M5, 0);
   PrintFormat("EA started: M15 SMA(%d/%d), M5 close[1], initial lot=%.2f, multiplier=%.2f, trading=%s",
               FastSMAPeriod, SlowSMAPeriod, InitialLot, LotMultiplier,
               EnableTrading ? "ON" : "OFF");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(g_fast_sma != INVALID_HANDLE) IndicatorRelease(g_fast_sma);
   if(g_slow_sma != INVALID_HANDLE) IndicatorRelease(g_slow_sma);
}

void OnTick()
{
   if(!EnableTrading)
      return;

   // Monitor basket profit every tick, not only on M5 candle close.
   if(CheckAndCloseBasket())
      return;

   datetime currentM5Bar = iTime(_Symbol, PERIOD_M5, 0);
   if(currentM5Bar == 0 || currentM5Bar == g_last_m5_bar)
      return;

   // Consider one entry per newly opened M5 bar, using the previous [1] bar.
   g_last_m5_bar = currentM5Bar;

   int direction = TrendDirection();
   if(direction == 2 || direction == 0)
      return;

   // Apply to ALL new orders, including first entries and recoveries.
   // Basket closing above remains active regardless of this entry filter.
   if(!AllowEntryByRecentSMACross())
      return;

   double lastM5Close = iClose(_Symbol, PERIOD_M5, 1);
   if(lastM5Close <= 0.0)
      return;

   SideState buys, sells;
   double basketProfit;
   int total;
   ReadMyPositions(buys, sells, basketProfit, total);

   if(direction == 1)
   {
      if(MaxPositionsPerSide > 0 && buys.count >= MaxPositionsPerSide)
         return;
      if(!AllowAddBySMASlope(buys.count))
         return;

      // Open once EVERY M5 closed candle while M15 SMA8 > SMA9.
      // An adverse close increases the lot relative to the latest BUY;
      // otherwise reset the newly opened lot to InitialLot.
      bool adverse = (buys.count > 0 && lastM5Close < buys.latestOpenPrice);
      double requested = adverse ? buys.latestVolume * LotMultiplier : InitialLot;
      OpenPosition(ORDER_TYPE_BUY, NormalizeLotUp(requested),
                   adverse ? "M5 BUY recovery" : "M5 BUY base");
   }
   else if(direction == -1)
   {
      if(MaxPositionsPerSide > 0 && sells.count >= MaxPositionsPerSide)
         return;
      if(!AllowAddBySMASlope(sells.count))
         return;

      // Mirrored SELL: an adverse M5 close is ABOVE the last SELL entry.
      bool adverse = (sells.count > 0 && lastM5Close > sells.latestOpenPrice);
      double requested = adverse ? sells.latestVolume * LotMultiplier : InitialLot;
      OpenPosition(ORDER_TYPE_SELL, NormalizeLotUp(requested),
                   adverse ? "M5 SELL recovery" : "M5 SELL base");
   }

   // Handle the same tick that a new opposite-direction order created a hedge.
   CheckAndCloseBasket();
}
//+------------------------------------------------------------------+
