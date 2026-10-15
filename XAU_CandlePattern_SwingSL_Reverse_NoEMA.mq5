//+------------------------------------------------------------------+
//|                           XAU_CandlePattern_SwingSL_Reverse.mq5   |
//|  Candle pattern: 1-3 bodies + swing stop loss + reverse on signal |
//|  EMA indicators and EMA trend filters removed entirely.          |
//+------------------------------------------------------------------+
#property strict
#property version   "1.03"
#property description "Candle pattern 1-3 bars + Swing SL + optional immediate reverse (no EMA)"

#include <Trade/Trade.mqh>
CTrade trade;

#define MACD_HISTORY 5
#define OHLCV_HISTORY 20

//====================================================================
// INPUTS
//====================================================================
input group "=== Trading ==="
input bool             EnableTrading          = false;      // Enable for Strategy Tester/live trading
input double           LotSize                = 0.01;
input ulong            MagicNumber            = 26092301;
input bool             TradeOnNewBarOnly      = true;
input int              SignalShift            = 1;          // 1 = closed candle, 0 = current candle
input int              MaxPositionsPerSymbol  = 1;
input int              SlippagePoints         = 30;

input group "=== Swing Stop Loss ==="
input bool             EnableSwingStopLoss       = true;  // Initial SL at pattern swing high/low
input int              SwingSLBufferPoints       = 0;     // Extra points below/above pattern swing
input bool             AdjustSLToBrokerMinimum   = true;  // Extend SL if broker minimum requires it
input int              MaxSwingSLPoints          = 0;     // 0 = unlimited; otherwise skip oversized SL

input group "=== Reverse on Opposite Candle Pattern ==="
input bool             ReverseOnOppositePattern = true;   // Close current position and open opposite one

input group "=== MACD Window ==="
input int              MACDFastPeriod         = 12;
input int              MACDSlowPeriod         = 26;
input int              MACDSignalPeriod       = 9;
input ENUM_APPLIED_PRICE MACDPrice             = PRICE_CLOSE;
input int              MACDMAPeriod           = 12;         // MA applied to MACD main line
input ENUM_MA_METHOD   MACDMAMethod           = MODE_SMA;
input int              RSIPeriod              = 14;         // RSI applied to MACD main line

input group "=== Display ==="
input bool             ShowIndicatorsOnChart  = false;

//====================================================================
// INDICATOR HANDLES
//====================================================================
int hMACD    = INVALID_HANDLE;
int hMACDMA  = INVALID_HANDLE;
int hRSI     = INVALID_HANDLE;

int g_macd_window = -1;
datetime g_last_bar_time = 0;

//====================================================================
// DATA STRUCTURE USED BY YOUR ENTRY/EXIT LOGIC
//====================================================================
struct IndicatorState
{
   datetime time;

   double open;
   double high;
   double low;
   double close;

   // OHLCV ย้อนหลัง 20 แท่ง
   // index 0 = แท่งตาม SignalShift, index 19 = แท่งเก่าสุด
   datetime ohlcv_time[OHLCV_HISTORY];
   double   ohlcv_open[OHLCV_HISTORY];
   double   ohlcv_high[OHLCV_HISTORY];
   double   ohlcv_low[OHLCV_HISTORY];
   double   ohlcv_close[OHLCV_HISTORY];
   long     ohlcv_volume[OHLCV_HISTORY];

   double macd_main;
   double macd_signal;
   double macd_ma;
   double rsi;

   // MACD ย้อนหลัง 5 แท่ง
   double macd_main_prev[MACD_HISTORY];
   double macd_signal_prev[MACD_HISTORY];
};

//====================================================================
// HELPER: copy one value from an indicator buffer
//====================================================================
bool CopyOne(const int handle,const int buffer,const int shift,double &value)
{
   double temp[1];
   ResetLastError();

   if(CopyBuffer(handle,buffer,shift,1,temp) != 1)
   {
      PrintFormat("CopyBuffer failed. handle=%d buffer=%d shift=%d error=%d",
                  handle,buffer,shift,GetLastError());
      return false;
   }

   value = temp[0];
   return true;
}

//====================================================================
// HELPER: read OHLC + all indicator values
//====================================================================
bool ReadIndicatorState(const int shift, IndicatorState &s)
{
   MqlRates rates[OHLCV_HISTORY];

   ResetLastError();
   if(CopyRates(_Symbol,_Period,shift,OHLCV_HISTORY,rates) != OHLCV_HISTORY)
   {
      PrintFormat("CopyRates OHLCV failed. shift=%d count=%d error=%d",
                  shift,OHLCV_HISTORY,GetLastError());
      return false;
   }

   // CopyRates จะคืนข้อมูลเรียงจากเก่า -> ใหม่ใน physical array
   // เรากลับ index ให้ [0] = แท่งล่าสุดตาม shift, [19] = แท่งเก่าสุด
   for(int i = 0; i < OHLCV_HISTORY; i++)
   {
      int src = OHLCV_HISTORY - 1 - i;

      s.ohlcv_time[i]   = rates[src].time;
      s.ohlcv_open[i]   = rates[src].open;
      s.ohlcv_high[i]   = rates[src].high;
      s.ohlcv_low[i]    = rates[src].low;
      s.ohlcv_close[i]  = rates[src].close;
      s.ohlcv_volume[i] = (long)rates[src].tick_volume;
   }

   // ค่าเดิมสำหรับ logic ที่อ้าง s.open / s.high / s.low / s.close
   s.time  = s.ohlcv_time[0];
   s.open  = s.ohlcv_open[0];
   s.high  = s.ohlcv_high[0];
   s.low   = s.ohlcv_low[0];
   s.close = s.ohlcv_close[0];

   if(!CopyOne(hMACD,0,shift,s.macd_main))
      return false;

   if(!CopyOne(hMACD,1,shift,s.macd_signal))
      return false;

   if(!CopyOne(hMACDMA,0,shift,s.macd_ma))
      return false;

   if(!CopyOne(hRSI,0,shift,s.rsi))
      return false;

   //==============================================================
   // MACD HISTORY
   //==============================================================
   for(int i = 0; i < MACD_HISTORY; i++)
   {
      int history_shift = shift + i;

      if(!CopyOne(
            hMACD,
            0,
            history_shift,
            s.macd_main_prev[i]
         ))
         return false;

      if(!CopyOne(
            hMACD,
            1,
            history_shift,
            s.macd_signal_prev[i]
         ))
         return false;
   }

   return true;
}

//====================================================================
// ENTRY / EXIT CONDITIONS
// Direction is determined exclusively by candle patterns.
//====================================================================

// Green 1-3 consecutive candles, sum of green bodies > preceding red body
// All candles must have their body larger than each individual wick.
bool FindBullishPattern(const IndicatorState &s,int &matchedGreenCount)
{
   matchedGreenCount = 0;
   for(int greenCount = 1; greenCount <= 3; greenCount++)
   {
      double totalGreenBody = 0.0;
      bool validGreen = true;

      for(int i = 0; i < greenCount; i++)
      {
         double open  = s.ohlcv_open[i];
         double close = s.ohlcv_close[i];
         double high  = s.ohlcv_high[i];
         double low   = s.ohlcv_low[i];

         double body      = MathAbs(close - open);
         double upperWick = MathAbs(high - close);
         double lowerWick = MathAbs(open - low);

         if(close <= open || body <= upperWick || body <= lowerWick)
         {
            validGreen = false;
            break;
         }

         totalGreenBody += body;
      }

      if(!validGreen)
         continue;

      int redIndex = greenCount;
      double redOpen  = s.ohlcv_open[redIndex];
      double redClose = s.ohlcv_close[redIndex];
      double redHigh  = s.ohlcv_high[redIndex];
      double redLow   = s.ohlcv_low[redIndex];

      double redBody      = MathAbs(redClose - redOpen);
      double redUpperWick = MathAbs(redHigh - redOpen);
      double redLowerWick = MathAbs(redClose - redLow);

      if(redClose >= redOpen ||
         redBody <= redUpperWick ||
         redBody <= redLowerWick)
         continue;

      if(totalGreenBody > redBody)
      {
         matchedGreenCount = greenCount;
         return true;
      }
   }

   return false;
}

// Red 1-3 consecutive candles, sum of red bodies > preceding green body
// All candles must have their body larger than each individual wick.
bool FindBearishPattern(const IndicatorState &s,int &matchedRedCount)
{
   matchedRedCount = 0;
   for(int redCount = 1; redCount <= 3; redCount++)
   {
      double totalRedBody = 0.0;
      bool validRed = true;

      for(int i = 0; i < redCount; i++)
      {
         double open  = s.ohlcv_open[i];
         double close = s.ohlcv_close[i];
         double high  = s.ohlcv_high[i];
         double low   = s.ohlcv_low[i];

         double body      = MathAbs(close - open);
         double upperWick = MathAbs(high - open);
         double lowerWick = MathAbs(close - low);

         if(close >= open || body <= upperWick || body <= lowerWick)
         {
            validRed = false;
            break;
         }

         totalRedBody += body;
      }

      if(!validRed)
         continue;

      int greenIndex = redCount;
      double greenOpen  = s.ohlcv_open[greenIndex];
      double greenClose = s.ohlcv_close[greenIndex];
      double greenHigh  = s.ohlcv_high[greenIndex];
      double greenLow   = s.ohlcv_low[greenIndex];

      double greenBody      = MathAbs(greenClose - greenOpen);
      double greenUpperWick = MathAbs(greenHigh - greenClose);
      double greenLowerWick = MathAbs(greenOpen - greenLow);

      if(greenClose <= greenOpen ||
         greenBody <= greenUpperWick ||
         greenBody <= greenLowerWick)
         continue;

      if(totalRedBody > greenBody)
      {
         matchedRedCount = redCount;
         return true;
      }
   }

   return false;
}

// Keep entry/exit candle patterns linked to the exact same pattern matcher
// used for the SL. The first valid pattern (1, then 2, then 3) is selected.
bool BullishCandlePattern(const IndicatorState &s)
{
   int matchedGreenCount = 0;
   return FindBullishPattern(s, matchedGreenCount);
}

bool BearishCandlePattern(const IndicatorState &s)
{
   int matchedRedCount = 0;
   return FindBearishPattern(s, matchedRedCount);
}

// Determine initial SL from *all* candles of the validated setup:
// BUY: min(low of preceding RED + 1..3 GREEN)
// SELL: max(high of preceding GREEN + 1..3 RED)
// Applies buffer and handles broker's SYMBOL_TRADE_STOPS_LEVEL.
bool BuildSwingStopLoss(const IndicatorState &s,
                        const bool forBuy,
                        const MqlTick &tick,
                        double &outSL)
{
   int matchedCount = 0;
   if(forBuy)
   {
      if(!FindBullishPattern(s, matchedCount))
         return false;
   }
   else
   {
      if(!FindBearishPattern(s, matchedCount))
         return false;
   }

   // The opposite candle is at index = matchedCount.
   double swing = (forBuy ? DBL_MAX : -DBL_MAX);
   for(int i = 0; i <= matchedCount; i++)
   {
      if(forBuy)
         swing = MathMin(swing, s.ohlcv_low[i]);
      else
         swing = MathMax(swing, s.ohlcv_high[i]);
   }

   double sl = (forBuy ? swing - SwingSLBufferPoints * _Point
                       : swing + SwingSLBufferPoints * _Point);

   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize <= 0.0)
      tickSize = _Point;

   long brokerStopsPoints = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minimumDistance = (double)brokerStopsPoints * _Point;
   bool adjusted = false;

   // For market BUY, stops are checked against Bid; for SELL, against Ask.
   // Allow one tick of extra room to avoid a boundary rounding rejection.
   if(forBuy)
   {
      double highestAllowedSL = tick.bid - minimumDistance - tickSize;
      if(sl > highestAllowedSL)
      {
         if(!AdjustSLToBrokerMinimum)
         {
            PrintFormat("BUY skipped: swing SL %.5f too close to Bid %.5f (broker stop level=%d points)",
                        sl, tick.bid, (int)brokerStopsPoints);
            return false;
         }
         sl = highestAllowedSL;
         adjusted = true;
      }
      sl = MathFloor(sl / tickSize + 1e-10) * tickSize; // never round SL toward price
      outSL = NormalizeDouble(sl, _Digits);
      if(outSL <= 0.0 || outSL >= tick.bid)
         return false;
   }
   else
   {
      double lowestAllowedSL = tick.ask + minimumDistance + tickSize;
      if(sl < lowestAllowedSL)
      {
         if(!AdjustSLToBrokerMinimum)
         {
            PrintFormat("SELL skipped: swing SL %.5f too close to Ask %.5f (broker stop level=%d points)",
                        sl, tick.ask, (int)brokerStopsPoints);
            return false;
         }
         sl = lowestAllowedSL;
         adjusted = true;
      }
      sl = MathCeil(sl / tickSize - 1e-10) * tickSize; // never round SL toward price
      outSL = NormalizeDouble(sl, _Digits);
      if(outSL <= tick.ask)
         return false;
   }

   double entryPrice = forBuy ? tick.ask : tick.bid;
   double slDistancePoints = MathAbs(entryPrice - outSL) / _Point;
   if(MaxSwingSLPoints > 0 && slDistancePoints > MaxSwingSLPoints)
   {
      PrintFormat("%s skipped: swing SL distance %.1f points exceeds MaxSwingSLPoints=%d",
                  forBuy ? "BUY" : "SELL", slDistancePoints, MaxSwingSLPoints);
      return false;
   }

   if(adjusted)
      PrintFormat("%s swing SL extended to meet broker minimum: setup swing=%.5f SL=%.5f",
                  forBuy ? "BUY" : "SELL", swing, outSL);

   return true;
}

bool BuyCondition(const IndicatorState &s)
{
   return BullishCandlePattern(s);
}

bool SellCondition(const IndicatorState &s)
{
   return BearishCandlePattern(s);
}

// The opposite pattern closes the current position.
bool CloseBuyCondition(const IndicatorState &s)
{
   return BearishCandlePattern(s);
}

bool CloseSellCondition(const IndicatorState &s)
{
   return BullishCandlePattern(s);
}

//====================================================================
// POSITION HELPERS
//====================================================================
int CountMyPositions()
{
   int count = 0;

   for(int i=PositionsTotal()-1; i>=0; i--)
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

bool HasMyPositionType(const ENUM_POSITION_TYPE desiredType)
{
   for(int i=PositionsTotal()-1; i>=0; i--)
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

// Return false if any closing request was not fully executed.
// Do not reverse into a new position if closing the old position failed.
bool ClosePositionsByType(const ENUM_POSITION_TYPE type_to_close)
{
   bool allClosed = true;

   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol ||
         (ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;

      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if(type != type_to_close)
         continue;

      bool sent = trade.PositionClose(ticket);
      uint retcode = trade.ResultRetcode();
      if(!sent || retcode != TRADE_RETCODE_DONE)
      {
         allClosed = false;
         PrintFormat("Close failed/not complete. ticket=%I64u retcode=%u %s",
                     ticket,retcode,trade.ResultRetcodeDescription());
      }
   }

   if(HasMyPositionType(type_to_close))
   {
      Print("Close incomplete: a matching position is still open; reversal cancelled.");
      allClosed = false;
   }

   return allClosed;
}

//====================================================================
// NEW BAR CHECK
//====================================================================
bool IsNewBar()
{
   datetime current_bar_time = iTime(_Symbol,_Period,0);
   if(current_bar_time == 0)
      return false;

   if(current_bar_time != g_last_bar_time)
   {
      g_last_bar_time = current_bar_time;
      return true;
   }

   return false;
}

//====================================================================
// ADD INDICATORS TO CHART
//====================================================================
bool AddIndicatorsToChart()
{
   if(!ShowIndicatorsOnChart)
      return true;

   // Create a new subwindow for MACD.
   int windows_total = (int)ChartGetInteger(0,CHART_WINDOWS_TOTAL);
   g_macd_window = windows_total;

   if(!ChartIndicatorAdd(0,g_macd_window,hMACD))
   {
      PrintFormat("Cannot add MACD to chart. Error=%d",GetLastError());
      return false;
   }

   // Add MA-on-MACD and RSI-on-MACD into the same subwindow.
   if(!ChartIndicatorAdd(0,g_macd_window,hMACDMA))
      PrintFormat("Cannot add MACD MA to chart. Error=%d",GetLastError());

   if(!ChartIndicatorAdd(0,g_macd_window,hRSI))
      PrintFormat("Cannot add RSI to chart. Error=%d",GetLastError());

   ChartRedraw(0);
   return true;
}

//====================================================================
// INITIALIZATION
//====================================================================
int OnInit()
{
   if(MACDFastPeriod <= 0 || MACDSlowPeriod <= 0 || MACDSignalPeriod <= 0 ||
      MACDMAPeriod <= 0 || RSIPeriod <= 0)
   {
      Print("Invalid indicator period.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(SignalShift < 0)
   {
      Print("SignalShift must be >= 0");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(SwingSLBufferPoints < 0 || MaxSwingSLPoints < 0)
   {
      Print("SwingSLBufferPoints and MaxSwingSLPoints must be >= 0");
      return INIT_PARAMETERS_INCORRECT;
   }

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   // MACD
   hMACD = iMACD(_Symbol,_Period,
                 MACDFastPeriod,MACDSlowPeriod,MACDSignalPeriod,MACDPrice);

   if(hMACD == INVALID_HANDLE)
   {
      PrintFormat("Cannot create base indicator handles. Error=%d",GetLastError());
      return INIT_FAILED;
   }

   // MQL5 allows an indicator handle to be supplied as applied_price.
   // Here MA(12) and RSI(14) are calculated from MACD's main data,
   // matching the overlay style shown in the reference chart.
   hMACDMA = iMA(_Symbol,_Period,MACDMAPeriod,0,MACDMAMethod,(ENUM_APPLIED_PRICE)hMACD);
   hRSI    = iRSI(_Symbol,_Period,RSIPeriod,(ENUM_APPLIED_PRICE)hMACD);

   if(hMACDMA == INVALID_HANDLE || hRSI == INVALID_HANDLE)
   {
      PrintFormat("Cannot create chained indicator handles. Error=%d",GetLastError());
      return INIT_FAILED;
   }

   AddIndicatorsToChart();

   // Initialize bar tracker so the EA does not treat attach-time as a new bar.
   g_last_bar_time = iTime(_Symbol,_Period,0);

   Print("EA initialized. Trading is ", (EnableTrading ? "ENABLED" : "DISABLED"),
         ". Signal = candle pattern only; reversal is ",
         (ReverseOnOppositePattern ? "ON" : "OFF"), ".");

   return INIT_SUCCEEDED;
}

//====================================================================
// DEINITIALIZATION
//====================================================================
void OnDeinit(const int reason)
{
   if(hMACDMA != INVALID_HANDLE) IndicatorRelease(hMACDMA);
   if(hRSI    != INVALID_HANDLE) IndicatorRelease(hRSI);
   if(hMACD   != INVALID_HANDLE) IndicatorRelease(hMACD);
}

//====================================================================
// MAIN LOOP
//====================================================================
void OnTick()
{
   if(TradeOnNewBarOnly && !IsNewBar())
      return;

   IndicatorState s;
   if(!ReadIndicatorState(SignalShift,s))
      return;

   // Candle patterns drive entries, exits, and optional immediate reversals.
   bool bullishPattern = BuyCondition(s);
   bool bearishPattern = SellCondition(s);

   if(!EnableTrading)
      return;

   // Snapshot BEFORE closing: determines whether we are reversing an old trade.
   bool hadBuy = HasMyPositionType(POSITION_TYPE_BUY);
   bool hadSell = HasMyPositionType(POSITION_TYPE_SELL);

   bool closeOk = true;
   if(hadBuy && bearishPattern)
      closeOk = ClosePositionsByType(POSITION_TYPE_BUY) && closeOk;

   if(hadSell && bullishPattern)
      closeOk = ClosePositionsByType(POSITION_TYPE_SELL) && closeOk;

   if(!closeOk)
   {
      Print("New entry skipped: close of opposite position did not complete.");
      return;
   }

   bool reverseToSell = ReverseOnOppositePattern && hadBuy && bearishPattern;
   bool reverseToBuy  = ReverseOnOppositePattern && hadSell && bullishPattern;

   int remaining = CountMyPositions();

   // Reversal requires ALL old EA positions to be closed; never hedge by mistake.
   if((reverseToBuy || reverseToSell) && remaining != 0)
   {
      PrintFormat("Reversal skipped: %d EA position(s) still open.", remaining);
      return;
   }

   if(remaining >= MaxPositionsPerSymbol)
      return;

   bool buy_signal = false;
   bool sell_signal = false;

   if(reverseToBuy || reverseToSell)
   {
      // Close completed; open the opposite direction using candle pattern only.
      buy_signal = reverseToBuy;
      sell_signal = reverseToSell;
   }
   else if((hadBuy && bearishPattern) || (hadSell && bullishPattern))
   {
      // Reversal switch is OFF: close old position and stay flat this bar.
      // The next new-bar signal can still open a fresh position.
      return;
   }
   else
   {
      // Flat-state entry is based only on the candle pattern.
      buy_signal = bullishPattern;
      sell_signal = bearishPattern;
   }

   // Avoid conflicting buy/sell orders.
   if(buy_signal == sell_signal)
      return;

   bool forBuy = buy_signal;
   double sl = 0.0;
   if(EnableSwingStopLoss)
   {
      MqlTick tick;
      if(!SymbolInfoTick(_Symbol, tick))
      {
         PrintFormat("SymbolInfoTick failed. error=%d", GetLastError());
         return;
      }

      if(!BuildSwingStopLoss(s, forBuy, tick, sl))
      {
         PrintFormat("%s skipped: could not build a valid swing SL",
                     forBuy ? "BUY" : "SELL");
         return;
      }
   }

   bool sent = false;
   if(forBuy)
      sent = trade.Buy(LotSize, _Symbol, 0.0, sl, 0.0,
                       reverseToBuy ? "Reverse BUY" : "Swing SL BUY");
   else
      sent = trade.Sell(LotSize, _Symbol, 0.0, sl, 0.0,
                        reverseToSell ? "Reverse SELL" : "Swing SL SELL");

   if(!sent || (trade.ResultRetcode() != TRADE_RETCODE_DONE &&
                trade.ResultRetcode() != TRADE_RETCODE_DONE_PARTIAL))
   {
      PrintFormat("%s failed: SL=%.5f retcode=%u %s",
                  forBuy ? "BUY" : "SELL", sl,
                  trade.ResultRetcode(), trade.ResultRetcodeDescription());
   }
   else
   {
      PrintFormat("%s opened: SL=%.5f, reversal=%s",
                  forBuy ? "BUY" : "SELL", sl,
                  (reverseToBuy || reverseToSell) ? "true" : "false");
   }
}
//+------------------------------------------------------------------+
