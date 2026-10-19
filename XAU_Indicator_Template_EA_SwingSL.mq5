//+------------------------------------------------------------------+
//|          XAU_CandlePattern_Breakout_SwingSL_Reverse_NoEMA.mq5    |
//| Candle pattern (1-3 bars) + Structure Breakout + Swing SL        |
//| Close & reverse on opposite filtered signal. No EMA used.       |
//+------------------------------------------------------------------+
#property strict
#property version "1.10"
#property description "No EMA: candle pattern + breakout + swing stop loss + reverse"

#include <Trade/Trade.mqh>
CTrade trade;

#define OHLCV_HISTORY 20

//====================================================================
// INPUTS
//====================================================================
input group "=== Trading ==="
input bool   EnableTrading             = false; // set true when ready
input double LotSize                   = 0.01;
input ulong  MagicNumber               = 26092301;
input bool   TradeOnNewBarOnly         = true;
input int    SignalShift               = 1;     // 1 = closed candle
input int    MaxPositionsPerSymbol     = 1;
input int    SlippagePoints            = 30;
input bool   DebugSignals              = false;

input group "=== Candle Structure Breakout ==="
input bool   EnableBreakoutFilter      = true;
input int    BreakoutLookbackBars      = 6;     // prior candles, index 1..N
input int    BreakoutBufferPoints      = 0;     // 0 = no buffer

input group "=== Swing Stop Loss ==="
input bool   EnableSwingStopLoss       = true;
input int    SwingSLBufferPoints       = 0;
input bool   AdjustSLToBrokerMinimum   = true;
input int    MaxSwingSLPoints          = 0;     // 0 = no limit

input group "=== Exit / Reversal ==="
input bool   ExitRequiresBreakout      = true;  // true: close only on filtered signal
input bool   ReverseOnOppositePattern  = true;  // reverse after successful close

//====================================================================
// OHLCV DATA; [0] IS THE SIGNAL CANDLE (SignalShift)
//====================================================================
struct IndicatorState
{
   datetime ohlcv_time[OHLCV_HISTORY];
   double   ohlcv_open[OHLCV_HISTORY];
   double   ohlcv_high[OHLCV_HISTORY];
   double   ohlcv_low[OHLCV_HISTORY];
   double   ohlcv_close[OHLCV_HISTORY];
   long     ohlcv_volume[OHLCV_HISTORY];
};

datetime g_lastBarTime = 0;

bool ReadIndicatorState(const int shift, IndicatorState &s)
{
   MqlRates rates[OHLCV_HISTORY];
   ResetLastError();
   int got = CopyRates(_Symbol, _Period, shift, OHLCV_HISTORY, rates);
   if(got != OHLCV_HISTORY)
   {
      PrintFormat("CopyRates failed: got=%d error=%d", got, GetLastError());
      return false;
   }

   // CopyRates physical order: oldest -> newest; flip it for [0] newest.
   for(int i = 0; i < OHLCV_HISTORY; i++)
   {
      int j = OHLCV_HISTORY - 1 - i;
      s.ohlcv_time[i]   = rates[j].time;
      s.ohlcv_open[i]   = rates[j].open;
      s.ohlcv_high[i]   = rates[j].high;
      s.ohlcv_low[i]    = rates[j].low;
      s.ohlcv_close[i]  = rates[j].close;
      s.ohlcv_volume[i] = (long)rates[j].tick_volume;
   }
   return true;
}

//====================================================================
// CANDLE PATTERN
// BUY: 1-3 consecutive bullish bodies > previous 1 bearish body.
// SELL: inverse. All bodies must exceed each individual wick.
// Returns number of same-direction candles matched (1..3).
//====================================================================
bool FindCandlePattern(const IndicatorState &s,
                       const bool forBuy,
                       int &matchedCount)
{
   matchedCount = 0;

   for(int count = 1; count <= 3; count++)
   {
      double totalBody = 0.0;
      bool valid = true;

      for(int i = 0; i < count; i++)
      {
         double o = s.ohlcv_open[i];
         double c = s.ohlcv_close[i];
         double h = s.ohlcv_high[i];
         double l = s.ohlcv_low[i];

         bool correctColor = forBuy ? (c > o) : (c < o);
         double body      = MathAbs(c - o);
         double upperWick = h - MathMax(o, c);
         double lowerWick = MathMin(o, c) - l;

         if(!correctColor || body <= upperWick || body <= lowerWick)
         {
            valid = false;
            break;
         }
         totalBody += body;
      }
      if(!valid)
         continue;

      // The immediately preceding candle must be the opposite color.
      int i = count;
      double o = s.ohlcv_open[i];
      double c = s.ohlcv_close[i];
      double h = s.ohlcv_high[i];
      double l = s.ohlcv_low[i];
      bool oppositeColor = forBuy ? (c < o) : (c > o);
      double body      = MathAbs(c - o);
      double upperWick = h - MathMax(o, c);
      double lowerWick = MathMin(o, c) - l;

      if(!oppositeColor || body <= upperWick || body <= lowerWick)
         continue;

      if(totalBody > body)
      {
         matchedCount = count;
         return true;
      }
   }
   return false;
}

//====================================================================
// STRUCTURE BREAKOUT FILTER
// BUY: signal close > highest High from earlier N bars (+buffer).
// SELL: signal close < lowest Low from earlier N bars (-buffer).
//====================================================================
bool PassBreakoutFilter(const IndicatorState &s, const bool forBuy)
{
   if(!EnableBreakoutFilter)
      return true;

   double highest = s.ohlcv_high[1];
   double lowest  = s.ohlcv_low[1];
   for(int i = 2; i <= BreakoutLookbackBars; i++)
   {
      highest = MathMax(highest, s.ohlcv_high[i]);
      lowest  = MathMin(lowest,  s.ohlcv_low[i]);
   }

   double buffer = (double)BreakoutBufferPoints * _Point;
   if(forBuy)
      return s.ohlcv_close[0] > highest + buffer;
   return s.ohlcv_close[0] < lowest - buffer;
}

bool BuyCondition(const IndicatorState &s)
{
   int count = 0;
   return FindCandlePattern(s, true, count) && PassBreakoutFilter(s, true);
}

bool SellCondition(const IndicatorState &s)
{
   int count = 0;
   return FindCandlePattern(s, false, count) && PassBreakoutFilter(s, false);
}

bool CloseBuyCondition(const IndicatorState &s)
{
   int count = 0;
   if(!FindCandlePattern(s, false, count))
      return false;
   return !ExitRequiresBreakout || PassBreakoutFilter(s, false);
}

bool CloseSellCondition(const IndicatorState &s)
{
   int count = 0;
   if(!FindCandlePattern(s, true, count))
      return false;
   return !ExitRequiresBreakout || PassBreakoutFilter(s, true);
}

//====================================================================
// SWING STOP LOSS FROM THE EXACT MATCHED SETUP
// BUY: min Low of red + green candles.
// SELL: max High of green + red candles.
//====================================================================
bool BuildSwingStopLoss(const IndicatorState &s,
                        const bool forBuy,
                        const MqlTick &tick,
                        double &outSL)
{
   outSL = 0.0;
   int count = 0;
   if(!FindCandlePattern(s, forBuy, count))
      return false;

   double swing = forBuy ? DBL_MAX : -DBL_MAX;
   for(int i = 0; i <= count; i++)
   {
      if(forBuy)
         swing = MathMin(swing, s.ohlcv_low[i]);
      else
         swing = MathMax(swing, s.ohlcv_high[i]);
   }

   double sl = forBuy ? swing - SwingSLBufferPoints * _Point
                      : swing + SwingSLBufferPoints * _Point;

   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize <= 0.0)
      tickSize = _Point;

   long stopLevelPoints = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDistance = (double)stopLevelPoints * _Point;

   // Initial BUY SL is checked relative to Bid; SELL relative to Ask.
   if(forBuy)
   {
      double maxAllowedSL = tick.bid - minDistance - tickSize;
      if(sl > maxAllowedSL)
      {
         if(!AdjustSLToBrokerMinimum)
         {
            Print("BUY skipped: swing SL closer than broker stop level.");
            return false;
         }
         sl = maxAllowedSL;
      }
      sl = MathFloor(sl / tickSize) * tickSize;
      outSL = NormalizeDouble(sl, _Digits);
      if(outSL <= 0.0 || outSL >= tick.bid)
         return false;
   }
   else
   {
      double minAllowedSL = tick.ask + minDistance + tickSize;
      if(sl < minAllowedSL)
      {
         if(!AdjustSLToBrokerMinimum)
         {
            Print("SELL skipped: swing SL closer than broker stop level.");
            return false;
         }
         sl = minAllowedSL;
      }
      sl = MathCeil(sl / tickSize) * tickSize;
      outSL = NormalizeDouble(sl, _Digits);
      if(outSL <= tick.ask)
         return false;
   }

   double entryPrice = forBuy ? tick.ask : tick.bid;
   double distancePoints = MathAbs(entryPrice - outSL) / _Point;
   if(MaxSwingSLPoints > 0 && distancePoints > MaxSwingSLPoints)
   {
      PrintFormat("%s skipped: Swing SL distance %.1f > max %d points",
                  forBuy ? "BUY" : "SELL", distancePoints, MaxSwingSLPoints);
      return false;
   }
   return true;
}

//====================================================================
// POSITION HELPERS (ONLY THIS SYMBOL + MAGIC NUMBER)
//====================================================================
int CountMyPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         (ulong)PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         count++;
   }
   return count;
}

bool HasMyPositionType(const ENUM_POSITION_TYPE desiredType)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol ||
         (ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == desiredType)
         return true;
   }
   return false;
}

bool ClosePositionsByType(const ENUM_POSITION_TYPE typeToClose)
{
   bool okay = true;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol ||
         (ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber ||
         (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != typeToClose)
         continue;

      bool sent = trade.PositionClose(ticket);
      uint rc = trade.ResultRetcode();
      if(!sent || rc != TRADE_RETCODE_DONE)
      {
         okay = false;
         PrintFormat("Close failed: ticket=%I64u retcode=%u %s",
                     ticket, rc, trade.ResultRetcodeDescription());
      }
   }
   if(HasMyPositionType(typeToClose))
      okay = false;
   return okay;
}

bool IsNewBar()
{
   datetime current = iTime(_Symbol, _Period, 0);
   if(current == 0)
      return false;
   if(current == g_lastBarTime)
      return false;
   g_lastBarTime = current;
   return true;
}

//====================================================================
// INITIALIZATION
//====================================================================
int OnInit()
{
   if(LotSize <= 0.0 || MaxPositionsPerSymbol < 1 || SignalShift < 0 ||
      SlippagePoints < 0 || SwingSLBufferPoints < 0 ||
      MaxSwingSLPoints < 0 || BreakoutBufferPoints < 0 ||
      BreakoutLookbackBars < 1 || BreakoutLookbackBars >= OHLCV_HISTORY)
   {
      Print("Invalid EA inputs.");
      return INIT_PARAMETERS_INCORRECT;
   }

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetAsyncMode(false);
   g_lastBarTime = iTime(_Symbol, _Period, 0);

   PrintFormat("EA started: Trading=%s, Breakout=%s, Lookback=%d, SwingSL=%s, Reverse=%s",
               EnableTrading ? "ON" : "OFF",
               EnableBreakoutFilter ? "ON" : "OFF",
               BreakoutLookbackBars,
               EnableSwingStopLoss ? "ON" : "OFF",
               ReverseOnOppositePattern ? "ON" : "OFF");
   return INIT_SUCCEEDED;
}

//====================================================================
// MAIN LOOP
//====================================================================
void OnTick()
{
   if(TradeOnNewBarOnly && !IsNewBar())
      return;

   IndicatorState s;
   if(!ReadIndicatorState(SignalShift, s))
      return;

   bool buySignal       = BuyCondition(s);
   bool sellSignal      = SellCondition(s);
   bool closeBuySignal  = CloseBuyCondition(s);
   bool closeSellSignal = CloseSellCondition(s);

   if(DebugSignals)
      PrintFormat("signal=%s BUY=%s SELL=%s CLOSE_BUY=%s CLOSE_SELL=%s",
                  TimeToString(s.ohlcv_time[0]),
                  buySignal ? "1" : "0", sellSignal ? "1" : "0",
                  closeBuySignal ? "1" : "0", closeSellSignal ? "1" : "0");

   if(!EnableTrading)
      return;

   bool hadBuy  = HasMyPositionType(POSITION_TYPE_BUY);
   bool hadSell = HasMyPositionType(POSITION_TYPE_SELL);

   // Exits always processed before new entries.
   bool closeOkay = true;
   if(hadBuy && closeBuySignal)
      closeOkay = ClosePositionsByType(POSITION_TYPE_BUY) && closeOkay;
   if(hadSell && closeSellSignal)
      closeOkay = ClosePositionsByType(POSITION_TYPE_SELL) && closeOkay;
   if(!closeOkay)
      return;

   bool closedBuy  = hadBuy && closeBuySignal;
   bool closedSell = hadSell && closeSellSignal;

   // If opposite exit signal is not an entry breakout, close only.
   // Reversal requires the opposite ENTRY signal as well.
   bool reverseBuy  = ReverseOnOppositePattern && closedSell && buySignal;
   bool reverseSell = ReverseOnOppositePattern && closedBuy && sellSignal;

   if((closedBuy || closedSell) && !reverseBuy && !reverseSell)
      return;

   int remaining = CountMyPositions();
   if((reverseBuy || reverseSell) && remaining != 0)
   {
      Print("Reversal skipped: an old EA position remains open.");
      return;
   }
   if(remaining >= MaxPositionsPerSymbol)
      return;

   bool openBuy  = reverseBuy || (!closedBuy && !closedSell && buySignal);
   bool openSell = reverseSell || (!closedBuy && !closedSell && sellSignal);
   if(openBuy == openSell)
      return;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick) || tick.bid <= 0 || tick.ask <= 0)
   {
      Print("Entry skipped: invalid tick.");
      return;
   }

   double sl = 0.0;
   if(EnableSwingStopLoss && !BuildSwingStopLoss(s, openBuy, tick, sl))
   {
      PrintFormat("%s skipped: invalid Swing SL", openBuy ? "BUY" : "SELL");
      return;
   }

   bool sent = openBuy ? trade.Buy(LotSize, _Symbol, 0.0, sl, 0.0, "Pattern Break BUY")
                       : trade.Sell(LotSize, _Symbol, 0.0, sl, 0.0, "Pattern Break SELL");
   uint rc = trade.ResultRetcode();
   if(!sent || (rc != TRADE_RETCODE_DONE && rc != TRADE_RETCODE_DONE_PARTIAL))
      PrintFormat("%s failed: retcode=%u %s SL=%.5f",
                  openBuy ? "BUY" : "SELL", rc, trade.ResultRetcodeDescription(), sl);
   else
      PrintFormat("%s opened: SL=%.5f, reverse=%s",
                  openBuy ? "BUY" : "SELL", sl,
                  (reverseBuy || reverseSell) ? "yes" : "no");
}
//+------------------------------------------------------------------+
