//+------------------------------------------------------------------+
//|                                      XAU_Indicator_Template_EA.mq5|
//|  Template EA: EMA Fast/Slow + MACD(12,26,9) + MA(12) + RSI(14)  |
//|  Entry/Exit conditions are intentionally left for the user.      |
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"
#property description "EA template with EMA Fast/Slow, MACD, MA-on-MACD and RSI-on-MACD"

#include <Trade/Trade.mqh>
CTrade trade;

#define MACD_HISTORY 5
#define OHLCV_HISTORY 20

//====================================================================
// INPUTS
//====================================================================
input group "=== Trading ==="
input bool             EnableTrading          = false;      // Safety: enable after writing conditions
input double           LotSize                = 0.01;
input ulong            MagicNumber            = 26092301;
input bool             TradeOnNewBarOnly      = true;
input int              SignalShift            = 1;          // 1 = closed candle, 0 = current candle
input int              MaxPositionsPerSymbol  = 1;
input int              SlippagePoints         = 30;

input group "=== Main Chart Moving Averages ==="
input int              FastMAPeriod           = 8;
input int              SlowMAPeriod           = 12;
input ENUM_MA_METHOD   MainMAMethod           = MODE_EMA;
input ENUM_APPLIED_PRICE MainMAPrice           = PRICE_CLOSE;

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
int hFastMA  = INVALID_HANDLE;
int hSlowMA  = INVALID_HANDLE;
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

   double fast_ma;
   double slow_ma;

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

   if(!CopyOne(hFastMA,0,shift,s.fast_ma))
      return false;

   if(!CopyOne(hSlowMA,0,shift,s.slow_ma))
      return false;

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
// >>> WRITE YOUR ENTRY / EXIT CONDITIONS HERE <<<
// Return true when you want the EA to perform that action.
//====================================================================
// =====================================
// BUY: Green 1-3 candles > Red 1 candle
// =====================================
bool BuyCondition(const IndicatorState &s)
{
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

         if(close <= open ||
            body <= upperWick ||
            body <= lowerWick)
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
         return true;
   }

   return false;
}


// =====================================
// SELL: Red 1-3 candles > Green 1 candle
// =====================================
bool SellCondition(const IndicatorState &s)
{
   return CloseBuyCondition(s);
}


// =====================================
// CLOSE BUY: Red 1-3 > Green 1
// =====================================
bool CloseBuyCondition(const IndicatorState &s)
{
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

         if(close >= open ||
            body <= upperWick ||
            body <= lowerWick)
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
         return true;
   }

   return false;
}


// =====================================
// CLOSE SELL: Green 1-3 > Red 1
// =====================================
bool CloseSellCondition(const IndicatorState &s)
{
   return BuyCondition(s);
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

void ClosePositionsByType(const ENUM_POSITION_TYPE type_to_close)
{
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;

      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if(type != type_to_close)
         continue;

      if(!trade.PositionClose(ticket))
      {
         PrintFormat("Close failed. ticket=%I64u retcode=%u %s",
                     ticket,trade.ResultRetcode(),trade.ResultRetcodeDescription());
      }
   }
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

   // Main price window
   if(!ChartIndicatorAdd(0,0,hFastMA))
      PrintFormat("Cannot add Fast MA to chart. Error=%d",GetLastError());

   if(!ChartIndicatorAdd(0,0,hSlowMA))
      PrintFormat("Cannot add Slow MA to chart. Error=%d",GetLastError());

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
   if(FastMAPeriod <= 0 || SlowMAPeriod <= 0 ||
      MACDFastPeriod <= 0 || MACDSlowPeriod <= 0 || MACDSignalPeriod <= 0 ||
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

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   // Main-chart EMAs
   hFastMA = iMA(_Symbol,_Period,FastMAPeriod,0,MainMAMethod,MainMAPrice);
   hSlowMA = iMA(_Symbol,_Period,SlowMAPeriod,0,MainMAMethod,MainMAPrice);

   // MACD
   hMACD = iMACD(_Symbol,_Period,
                 MACDFastPeriod,MACDSlowPeriod,MACDSignalPeriod,MACDPrice);

   if(hFastMA == INVALID_HANDLE ||
      hSlowMA == INVALID_HANDLE ||
      hMACD   == INVALID_HANDLE)
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
         ". Write your logic in BuyCondition/SellCondition/CloseBuyCondition/CloseSellCondition.");

   return INIT_SUCCEEDED;
}

//====================================================================
// DEINITIALIZATION
//====================================================================
void OnDeinit(const int reason)
{
   if(hFastMA != INVALID_HANDLE) IndicatorRelease(hFastMA);
   if(hSlowMA != INVALID_HANDLE) IndicatorRelease(hSlowMA);
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

   // Conditions can be developed/tested while trading is disabled.
   bool buy_signal        = BuyCondition(s);
   bool sell_signal       = SellCondition(s);
   bool close_buy_signal  = CloseBuyCondition(s);
   bool close_sell_signal = CloseSellCondition(s);

   if(!EnableTrading)
      return;

   // Exit first
   if(close_buy_signal)
      ClosePositionsByType(POSITION_TYPE_BUY);

   if(close_sell_signal)
      ClosePositionsByType(POSITION_TYPE_SELL);

   // Entry limit
   if(CountMyPositions() >= MaxPositionsPerSymbol)
      return;

   // If both are true at the same time, do nothing to avoid conflicting orders.
   if(buy_signal == sell_signal)
      return;

   if(buy_signal)
   {
      if(!trade.Buy(LotSize,_Symbol,0.0,0.0,0.0,"Custom BUY"))
      {
         PrintFormat("BUY failed. retcode=%u %s",
                     trade.ResultRetcode(),trade.ResultRetcodeDescription());
      }
   }
   else if(sell_signal)
   {
      if(!trade.Sell(LotSize,_Symbol,0.0,0.0,0.0,"Custom SELL"))
      {
         PrintFormat("SELL failed. retcode=%u %s",
                     trade.ResultRetcode(),trade.ResultRetcodeDescription());
      }
   }
}
//+------------------------------------------------------------------+
