//+------------------------------------------------------------------+
//|                              XAU_MTF_SMA_8_12_M5_EA.mq5         |
//|  Based on XAU_Indicator_Template_EA.mq5                          |
//|  M5 entry: all M5/M15/M30/H1/H4 SMA(8/12) trends agree,          |
//|  then use the opposite-color CLOSED M5 candle as the trigger.    |
//+------------------------------------------------------------------+
#property strict
#property version   "2.00"
#property description "M5 pullback entry with MTF SMA(8,12) agreement on closed bars"

#include <Trade/Trade.mqh>
CTrade trade;

#define TF_COUNT      5
#define OHLCV_HISTORY 20
#define SIGNAL_SHIFT  1  // Closed candle for EVERY timeframe; never use bar 0.

//====================================================================
// INPUTS
//====================================================================
input group "=== Trading ==="
input bool   EnableTrading          = true;
input double LotSize                = 0.01;
input ulong  MagicNumber            = 26092301;
input bool   TradeOnNewBarOnly      = true;
input int    MaxPositionsPerSymbol  = 1;
input int    SlippagePoints         = 30;

input group "=== Multi-Timeframe Moving Averages ==="
input int                 FastMAPeriod = 8;
input int                 SlowMAPeriod = 12;
input ENUM_MA_METHOD      MainMAMethod = MODE_SMA;    // Simple Moving Average
input ENUM_APPLIED_PRICE  MainMAPrice  = PRICE_CLOSE;

input group "=== Exits / Display ==="
input bool CloseOnOppositeSignal = true; // Close BUY on SELL signal and vice versa
input bool ShowIndicatorsOnChart = false;
input bool PrintSignalLog        = false;

//====================================================================
// INDICATOR HANDLES: M5, M15, M30, H1, H4
//====================================================================
ENUM_TIMEFRAMES g_timeframes[TF_COUNT] =
{
   PERIOD_M5, PERIOD_M15, PERIOD_M30, PERIOD_H1, PERIOD_H4
};

int g_fast_ma_handles[TF_COUNT];
int g_slow_ma_handles[TF_COUNT];
datetime g_last_bar_time = 0;

//====================================================================
// DATA STRUCTURE USED BY ENTRY/EXIT LOGIC
//====================================================================
struct IndicatorState
{
   datetime time;
   double open;
   double high;
   double low;
   double close;

   // For compatibility with the original EA's historical OHLCV pattern:
   // [0] = closed M5 bar (shift 1); [1] = M5 bar shift 2; ...
   datetime ohlcv_time[OHLCV_HISTORY];
   double   ohlcv_open[OHLCV_HISTORY];
   double   ohlcv_high[OHLCV_HISTORY];
   double   ohlcv_low[OHLCV_HISTORY];
   double   ohlcv_close[OHLCV_HISTORY];
   long     ohlcv_volume[OHLCV_HISTORY];

   // Index mapping: 0=M5, 1=M15, 2=M30, 3=H1, 4=H4.
   // Values are ALWAYS read at shift 1 of their OWN timeframe.
   double fast_ma[TF_COUNT];
   double slow_ma[TF_COUNT];
};

//====================================================================
// HELPER: Copy a SINGLE MA value at a given candle shift
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
   if(!MathIsValidNumber(value) || value == EMPTY_VALUE)
      return false;

   return true;
}

//====================================================================
// HELPER: Read closed M5 candle and MTF MA values
//====================================================================
bool ReadIndicatorState(IndicatorState &s)
{
   MqlRates rates[OHLCV_HISTORY];
   ResetLastError();
   if(CopyRates(_Symbol,PERIOD_M5,SIGNAL_SHIFT,OHLCV_HISTORY,rates) != OHLCV_HISTORY)
   {
      PrintFormat("CopyRates M5 failed. shift=%d count=%d error=%d",
                  SIGNAL_SHIFT,OHLCV_HISTORY,GetLastError());
      return false;
   }

   // Physical order of CopyRates is oldest -> newest.
   for(int i=0; i<OHLCV_HISTORY; i++)
   {
      int src = OHLCV_HISTORY - 1 - i;
      s.ohlcv_time[i]   = rates[src].time;
      s.ohlcv_open[i]   = rates[src].open;
      s.ohlcv_high[i]   = rates[src].high;
      s.ohlcv_low[i]    = rates[src].low;
      s.ohlcv_close[i]  = rates[src].close;
      s.ohlcv_volume[i] = (long)rates[src].tick_volume;
   }

   s.time  = s.ohlcv_time[0];
   s.open  = s.ohlcv_open[0];
   s.high  = s.ohlcv_high[0];
   s.low   = s.ohlcv_low[0];
   s.close = s.ohlcv_close[0];

   // Higher timeframe values are also from shift 1 (closed candle).
   for(int i=0; i<TF_COUNT; i++)
   {
      if(!CopyOne(g_fast_ma_handles[i],0,SIGNAL_SHIFT,s.fast_ma[i]))
         return false;
      if(!CopyOne(g_slow_ma_handles[i],0,SIGNAL_SHIFT,s.slow_ma[i]))
         return false;
   }
   return true;
}

//====================================================================
// ENTRY CONDITIONS
//====================================================================
// BUY: SMA8 > SMA12 at M5/M15/M30/H1/H4 [1],
//      while the most recently CLOSED M5 candle [1] is BEARISH.
bool BuyCondition(const IndicatorState &s)
{
   if(s.close >= s.open) // A red candle must have Close < Open.
      return false;

   for(int i=0; i<TF_COUNT; i++)
   {
      if(s.fast_ma[i] <= s.slow_ma[i])
         return false;
   }
   return true;
}

// SELL: SMA8 < SMA12 at M5/M15/M30/H1/H4 [1],
//       while the most recently CLOSED M5 candle [1] is BULLISH.
bool SellCondition(const IndicatorState &s)
{
   if(s.close <= s.open) // A green candle must have Close > Open.
      return false;

   for(int i=0; i<TF_COUNT; i++)
   {
      if(s.fast_ma[i] >= s.slow_ma[i])
         return false;
   }
   return true;
}

// Opposite ENTRY signal is the default exit rule.
bool CloseBuyCondition(const IndicatorState &s)
{
   return CloseOnOppositeSignal && SellCondition(s);
}

bool CloseSellCondition(const IndicatorState &s)
{
   return CloseOnOppositeSignal && BuyCondition(s);
}

//====================================================================
// POSITION HELPERS (symbol + magic filtered, from the base EA)
//====================================================================
int CountMyPositions()
{
   int count=0;
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol)
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC)!=MagicNumber)
         continue;
      count++;
   }
   return count;
}

int CountMyPositionsByType(const ENUM_POSITION_TYPE desired_type)
{
   int count=0;
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol)
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC)!=MagicNumber)
         continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE)==desired_type)
         count++;
   }
   return count;
}

void ClosePositionsByType(const ENUM_POSITION_TYPE type_to_close)
{
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol)
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC)!=MagicNumber)
         continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE)!=type_to_close)
         continue;

      bool closed=trade.PositionClose(ticket);
      uint retcode=trade.ResultRetcode();
      if(!closed || (retcode!=TRADE_RETCODE_DONE &&
                     retcode!=TRADE_RETCODE_DONE_PARTIAL))
      {
         PrintFormat("Close failed. ticket=%I64u retcode=%u %s",
                     ticket,retcode,trade.ResultRetcodeDescription());
      }
   }
}

//====================================================================
// NEW M5 BAR CHECK
//====================================================================
bool IsNewBar()
{
   datetime current_bar_time=iTime(_Symbol,PERIOD_M5,0);
   if(current_bar_time==0)
      return false;

   if(current_bar_time!=g_last_bar_time)
   {
      g_last_bar_time=current_bar_time;
      return true;
   }
   return false;
}

//====================================================================
// ADD M5 MOVING AVERAGES TO MAIN CHART (optional)
//====================================================================
void AddIndicatorsToChart()
{
   if(!ShowIndicatorsOnChart)
      return;

   if(!ChartIndicatorAdd(0,0,g_fast_ma_handles[0]))
      PrintFormat("Cannot add M5 SMA Fast to chart. Error=%d",GetLastError());
   if(!ChartIndicatorAdd(0,0,g_slow_ma_handles[0]))
      PrintFormat("Cannot add M5 SMA Slow to chart. Error=%d",GetLastError());
   ChartRedraw(0);
}

//====================================================================
// INITIALIZATION
//====================================================================
int OnInit()
{
   // Safe handle cleanup even if a parameter check fails immediately.
   for(int i=0; i<TF_COUNT; i++)
   {
      g_fast_ma_handles[i]=INVALID_HANDLE;
      g_slow_ma_handles[i]=INVALID_HANDLE;
   }

   if(_Period!=PERIOD_M5)
   {
      Print("Please attach the EA to an M5 chart.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(FastMAPeriod<=0 || SlowMAPeriod<=0 || LotSize<=0.0 ||
      MaxPositionsPerSymbol<=0 || SlippagePoints<0)
   {
      Print("Invalid input parameters.");
      return INIT_PARAMETERS_INCORRECT;
   }

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   for(int i=0; i<TF_COUNT; i++)
   {
      g_fast_ma_handles[i]=iMA(_Symbol,g_timeframes[i],FastMAPeriod,
                               0,MainMAMethod,MainMAPrice);
      g_slow_ma_handles[i]=iMA(_Symbol,g_timeframes[i],SlowMAPeriod,
                               0,MainMAMethod,MainMAPrice);
      if(g_fast_ma_handles[i]==INVALID_HANDLE ||
         g_slow_ma_handles[i]==INVALID_HANDLE)
      {
         PrintFormat("Cannot create MA handles for timeframe %s. Error=%d",
                     EnumToString(g_timeframes[i]),GetLastError());
         return INIT_FAILED;
      }
   }

   AddIndicatorsToChart();
   g_last_bar_time=iTime(_Symbol,PERIOD_M5,0);

   PrintFormat("MTF SMA EA initialized | TF=M5 | Fast=%d Slow=%d | Method=%s | Trading=%s",
               FastMAPeriod,SlowMAPeriod,EnumToString(MainMAMethod),
               (EnableTrading ? "ON" : "OFF"));
   return INIT_SUCCEEDED;
}

//====================================================================
// DEINITIALIZATION
//====================================================================
void OnDeinit(const int reason)
{
   for(int i=0; i<TF_COUNT; i++)
   {
      if(g_fast_ma_handles[i]!=INVALID_HANDLE)
         IndicatorRelease(g_fast_ma_handles[i]);
      if(g_slow_ma_handles[i]!=INVALID_HANDLE)
         IndicatorRelease(g_slow_ma_handles[i]);
   }
}

//====================================================================
// MAIN LOOP
//====================================================================
void OnTick()
{
   if(TradeOnNewBarOnly && !IsNewBar())
      return;

   IndicatorState s;
   if(!ReadIndicatorState(s))
      return;

   bool buy_signal       = BuyCondition(s);
   bool sell_signal      = SellCondition(s);
   bool close_buy_signal = CloseBuyCondition(s);
   bool close_sell_signal= CloseSellCondition(s);

   if(PrintSignalLog)
   {
      PrintFormat("M5 closed candle: O=%.*f C=%.*f | MTF all BUY=%s all SELL=%s | BUY=%s SELL=%s",
                  _Digits,s.open,_Digits,s.close,
                  ((s.fast_ma[0]>s.slow_ma[0] &&
                    s.fast_ma[1]>s.slow_ma[1] &&
                    s.fast_ma[2]>s.slow_ma[2] &&
                    s.fast_ma[3]>s.slow_ma[3] &&
                    s.fast_ma[4]>s.slow_ma[4]) ? "YES" : "NO"),
                  ((s.fast_ma[0]<s.slow_ma[0] &&
                    s.fast_ma[1]<s.slow_ma[1] &&
                    s.fast_ma[2]<s.slow_ma[2] &&
                    s.fast_ma[3]<s.slow_ma[3] &&
                    s.fast_ma[4]<s.slow_ma[4]) ? "YES" : "NO"),
                  (buy_signal ? "YES" : "NO"),
                  (sell_signal ? "YES" : "NO"));
   }

   if(!EnableTrading)
      return;

   // Exit first, as in the original template.
   if(close_buy_signal)
      ClosePositionsByType(POSITION_TYPE_BUY);
   if(close_sell_signal)
      ClosePositionsByType(POSITION_TYPE_SELL);

   if(CountMyPositions()>=MaxPositionsPerSymbol)
      return;

   if(buy_signal==sell_signal) // No signal, or both conflicting.
      return;

   if(buy_signal)
   {
      // Do not open a BUY while an opposite EA position remains open.
      if(CountMyPositionsByType(POSITION_TYPE_SELL)>0)
         return;

      bool sent=trade.Buy(LotSize,_Symbol,0.0,0.0,0.0,"MTF SMA BUY");
      uint code=trade.ResultRetcode();
      if(!sent || (code!=TRADE_RETCODE_DONE &&
                   code!=TRADE_RETCODE_DONE_PARTIAL &&
                   code!=TRADE_RETCODE_PLACED))
      {
         PrintFormat("BUY failed. retcode=%u %s",code,
                     trade.ResultRetcodeDescription());
      }
   }
   else if(sell_signal)
   {
      // Do not open a SELL while an opposite EA position remains open.
      if(CountMyPositionsByType(POSITION_TYPE_BUY)>0)
         return;

      bool sent=trade.Sell(LotSize,_Symbol,0.0,0.0,0.0,"MTF SMA SELL");
      uint code=trade.ResultRetcode();
      if(!sent || (code!=TRADE_RETCODE_DONE &&
                   code!=TRADE_RETCODE_DONE_PARTIAL &&
                   code!=TRADE_RETCODE_PLACED))
      {
         PrintFormat("SELL failed. retcode=%u %s",code,
                     trade.ResultRetcodeDescription());
      }
   }
}
//+------------------------------------------------------------------+
