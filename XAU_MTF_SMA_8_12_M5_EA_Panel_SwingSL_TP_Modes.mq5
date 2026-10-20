//+------------------------------------------------------------------+
//|       XAU_MTF_SMA_8_12_M5_EA_Panel_SwingSL_TP_Modes.mq5       |
//|  M5 pullback entries filtered by selected MTF SMA 8/12 trends.   |
//|  Optional swing SL; RR TP or 3 no-SL take-profit exit modes.      |
//+------------------------------------------------------------------+
#property strict
#property version   "2.30"
#property description "MTF SMA M5 pullback; optional Swing SL; RR TP or 3 no-SL exit modes; panel"

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

input group "=== Enable / Disable Each Timeframe Filter ==="
input bool UseTF_M5  = true;
input bool UseTF_M15 = true;
input bool UseTF_M30 = true;
input bool UseTF_H1  = true;
input bool UseTF_H4  = true;

input group "=== Swing Stop Loss (M5 closed bars) ==="
input bool UseSwingSL            = true;  // Attach swing-based Stop Loss to new trades
input int  SwingLookbackBars     = 1;     // 1 = previous M5 candle [1]; N = highest/lowest of [1..N]
input int  SwingSLBufferPoints   = 0;     // Extra points beyond swing Low/High

// These methods apply ONLY when UseSwingSL=false AND UseRRTP=true.
// Method 2 (M5 cross) is the default.
enum ENUM_NO_SL_TP_MODE
{
   TP_FIXED_POINTS          = 1, // 1: broker TP at fixed point distance
   TP_M5_MA_CROSS           = 2, // 2: close on opposite SMA fast/slow cross, M5 [2] -> [1]
   TP_ALL_ACTIVE_TFS_OPPOSE = 3  // 3: close when ALL enabled TF SMA trends reverse
};

input group "=== Take Profit ==="
input bool                UseRRTP          = true; // Existing TP enable switch; retained for .set compatibility
input double              RiskRewardRatio  = 2.0;  // Used ONLY when Swing SL is ON
input ENUM_NO_SL_TP_MODE  NoSLTPMode       = TP_M5_MA_CROSS; // Active when Swing SL OFF, TP ON
input int                 FixedTPPoints    = 500;  // Used by TP_FIXED_POINTS only, in broker points

input group "=== Exits / Display ==="
input bool CloseOnOppositeSignal = true;  // Close BUY on SELL signal and vice versa
input bool ShowIndicatorsOnChart = false;
input bool PrintSignalLog        = false;

input group "=== MTF Status Panel ==="
input bool             ShowStatusPanel     = true;
input ENUM_BASE_CORNER PanelCorner         = CORNER_LEFT_UPPER;
input int              PanelX              = 16;     // Distance from the chosen chart corner
input int              PanelY              = 24;
input int              PanelRefreshSeconds = 2;      // Display refresh only; trades remain M5-based

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
datetime g_last_indicator_exit_bar = 0; // Prevent instant same-M5-bar re-entry after signal exit.
string g_panel_prefix = "";

// Panel dimensions in pixels.
#define PANEL_WIDTH  390
#define PANEL_HEIGHT 515

string g_tf_names[TF_COUNT] = {"M5", "M15", "M30", "H1", "H4"};

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

// Quiet data reads, also safe while higher-timeframe history is loading.
bool TryReadMA(const int handle,const int shift,double &value)
{
   if(handle==INVALID_HANDLE || shift<0 ||
      BarsCalculated(handle)<MathMax(FastMAPeriod,SlowMAPeriod)+shift)
      return false;

   double sample[1];
   if(CopyBuffer(handle,0,shift,1,sample)!=1)
      return false;
   if(!MathIsValidNumber(sample[0]) || sample[0]==EMPTY_VALUE)
      return false;
   value=sample[0];
   return true;
}

// A true CROSS event, not merely fast > slow / fast < slow.
// Compare M5 candles [2] and [1], both fully closed.
bool ReadM5Cross(bool &cross_up,bool &cross_down)
{
   cross_up=false;
   cross_down=false;
   double f1,s1,f2,s2;
   if(!TryReadMA(g_fast_ma_handles[0],1,f1) ||
      !TryReadMA(g_slow_ma_handles[0],1,s1) ||
      !TryReadMA(g_fast_ma_handles[0],2,f2) ||
      !TryReadMA(g_slow_ma_handles[0],2,s2))
      return false;

   cross_up   = (f2<=s2 && f1>s1);
   cross_down = (f2>=s2 && f1<s1);
   return true;
}

bool UsingNoSLTPMode()
{
   return (!UseSwingSL && UseRRTP);
}

string TPModeName()
{
   if(!UseRRTP) return "OFF";
   if(UseSwingSL) return StringFormat("RR %.2f",RiskRewardRatio);
   switch(NoSLTPMode)
   {
      case TP_FIXED_POINTS:          return StringFormat("POINTS %d",FixedTPPoints);
      case TP_M5_MA_CROSS:           return "M5 MA CROSS";
      case TP_ALL_ACTIVE_TFS_OPPOSE: return "ALL TF OPPOSITE";
   }
   return "UNKNOWN";
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

   // Disabled filters are not required to have data for trading.
   // The display independently attempts to read every TF (including OFF).
   for(int i=0; i<TF_COUNT; i++)
   {
      s.fast_ma[i]=0.0;
      s.slow_ma[i]=0.0;
      if(!IsTFEnabled(i)) continue;
      if(!CopyOne(g_fast_ma_handles[i],0,SIGNAL_SHIFT,s.fast_ma[i]))
         return false;
      if(!CopyOne(g_slow_ma_handles[i],0,SIGNAL_SHIFT,s.slow_ma[i]))
         return false;
   }
   return true;
}

//====================================================================
// TIMEFRAME FILTERS / ENTRY CONDITIONS
//====================================================================
bool IsTFEnabled(const int index)
{
   switch(index)
   {
      case 0: return UseTF_M5;
      case 1: return UseTF_M15;
      case 2: return UseTF_M30;
      case 3: return UseTF_H1;
      case 4: return UseTF_H4;
   }
   return false;
}

int EnabledTFCount()
{
   int count=0;
   for(int i=0; i<TF_COUNT; i++)
      if(IsTFEnabled(i)) count++;
   return count;
}

// Compare only enabled MA filters. The M5 opposite-color candle condition
// is ALWAYS required, even when the M5 MA filter is disabled.
bool AllActiveTFsAgree(const IndicatorState &s,const bool want_buy)
{
   if(EnabledTFCount()==0)
      return false;

   for(int i=0; i<TF_COUNT; i++)
   {
      if(!IsTFEnabled(i)) continue;
      if(want_buy && s.fast_ma[i]<=s.slow_ma[i]) return false;
      if(!want_buy && s.fast_ma[i]>=s.slow_ma[i]) return false;
   }
   return true;
}

// BUY: all ENABLED TFs are SMA8 > SMA12 at [1], M5 candle [1] is RED.
bool BuyCondition(const IndicatorState &s)
{
   return (s.close<s.open && AllActiveTFsAgree(s,true));
}

// SELL: all ENABLED TFs are SMA8 < SMA12 at [1], M5 candle [1] is GREEN.
bool SellCondition(const IndicatorState &s)
{
   return (s.close>s.open && AllActiveTFsAgree(s,false));
}

// CloseOnOppositeSignal retains its old meaning for other SL/TP combinations.
// When SL=OFF & TP=ON, ONLY the selected TP mode closes positions.
void CalculateExitSignals(const IndicatorState &s,bool &close_buy,bool &close_sell)
{
   close_buy=false;
   close_sell=false;

   if(UsingNoSLTPMode())
   {
      switch(NoSLTPMode)
      {
         case TP_FIXED_POINTS:
            // The broker holds a fixed-price TP, no indicator-driven exit.
            return;

         case TP_M5_MA_CROSS:
         {
            bool cross_up=false,cross_down=false;
            if(!ReadM5Cross(cross_up,cross_down))
               return; // Missing data: do not trigger an unconfirmed cross.
            close_buy=cross_down; // BUY exits on bearish M5 fast/slow crossing.
            close_sell=cross_up;  // SELL exits on bullish M5 fast/slow crossing.
            return;
         }

         case TP_ALL_ACTIVE_TFS_OPPOSE:
            // Candle color is intentionally not required for exits.
            close_buy=AllActiveTFsAgree(s,false);
            close_sell=AllActiveTFsAgree(s,true);
            return;
      }
      return;
   }

   close_buy=CloseOnOppositeSignal && SellCondition(s);
   close_sell=CloseOnOppositeSignal && BuyCondition(s);
}

//====================================================================
// SWING SL / OPTIONAL RR TP
//====================================================================
// Swing reference always uses FINISHED M5 candles. Lookback=1 means:
// BUY reference = Low of M5 [1], SELL reference = High of M5 [1].
// Lookback=N means lowest/highest among M5 [1] through [N].
// Used only when Swing SL is ON. With Swing SL OFF, the selected
// fixed-points/MA-cross/MTF-reversal TP method is used instead.
double SwingReferencePrice(const IndicatorState &s,const bool is_buy)
{
   double swing=(is_buy ? s.ohlcv_low[0] : s.ohlcv_high[0]);
   for(int i=1; i<SwingLookbackBars; i++)
   {
      if(is_buy) swing=MathMin(swing,s.ohlcv_low[i]);
      else       swing=MathMax(swing,s.ohlcv_high[i]);
   }
   double buffer=SwingSLBufferPoints*_Point;
   return (is_buy ? swing-buffer : swing+buffer);
}

// Round outward to a tradable tick size, not only to _Digits.
double NormalizeTickPrice(const double price,const bool round_up)
{
   double tick=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   if(tick<=0.0) tick=_Point;
   double steps=price/tick;
   double rounded=(round_up ? MathCeil(steps-1e-10) : MathFloor(steps+1e-10));
   return NormalizeDouble(rounded*tick,_Digits);
}

// Prepare physical order stops. Indicator exits (no-SL methods 2/3)
// intentionally attach NO TP: they require a running terminal/EA.
bool PrepareOrderStops(const IndicatorState &s,const bool is_buy,
                       const MqlTick &tick,double &sl,double &tp)
{
   sl=0.0;
   tp=0.0;
   if(!UseSwingSL && !UseRRTP)
      return true;

   double entry=(is_buy ? tick.ask : tick.bid);
   if(entry<=0.0 || tick.ask<=0.0 || tick.bid<=0.0)
   {
      Print("Cannot calculate SL/TP: invalid market quote.");
      return false;
   }

   // Market-position stops are compared with Bid for BUY and Ask for SELL.
   long stop_level=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   double min_distance=stop_level*_Point;
   double price_to_check=(is_buy ? tick.bid : tick.ask);

   // Case: Swing SL OFF + TP ON -> 3 selectable methods.
   if(UsingNoSLTPMode())
   {
      if(NoSLTPMode==TP_FIXED_POINTS)
      {
         double raw_tp=(is_buy ? entry+FixedTPPoints*_Point
                                 : entry-FixedTPPoints*_Point);
         tp=NormalizeTickPrice(raw_tp,is_buy);
         if(tp<=0.0 ||
            (is_buy && tp<=price_to_check+min_distance) ||
            (!is_buy && tp>=price_to_check-min_distance))
         {
            PrintFormat("Skip %s: fixed TP (%d points) violates broker stop limits.",
                        (is_buy ? "BUY" : "SELL"),FixedTPPoints);
            tp=0.0;
            return false;
         }
      }
      // MA-CROSS / ALL-OPPOSITE: TP remains zero; EA exits at market on signal.
      if(PrintSignalLog)
         PrintFormat("%s | SL=OFF | TP method=%s | physical TP=%s",
                     (is_buy ? "BUY" : "SELL"),TPModeName(),
                     (NoSLTPMode==TP_FIXED_POINTS ? DoubleToString(tp,_Digits) : "NONE (EA-managed)"));
      return true;
   }

   // Case: Swing SL ON -> optional broker-side RR TP, unchanged logic.
   double raw_ref=SwingReferencePrice(s,is_buy);
   double reference=NormalizeTickPrice(raw_ref,!is_buy);
   double risk=(is_buy ? entry-reference : reference-entry);
   if(risk<=0.0 || !MathIsValidNumber(risk))
   {
      PrintFormat("Skip %s: swing reference %.*f is not beyond entry %.*f.",
                  (is_buy ? "BUY" : "SELL"),_Digits,reference,_Digits,entry);
      return false;
   }

   if((is_buy && reference>=price_to_check-min_distance) ||
      (!is_buy && reference<=price_to_check+min_distance))
   {
      PrintFormat("Skip %s: swing SL %.*f too close to market. StopsLevel=%d points.",
                  (is_buy ? "BUY" : "SELL"),_Digits,reference,(int)stop_level);
      return false;
   }
   sl=reference;

   if(UseRRTP)
   {
      double raw_tp=(is_buy ? entry+RiskRewardRatio*risk
                            : entry-RiskRewardRatio*risk);
      tp=NormalizeTickPrice(raw_tp,is_buy);
      if(tp<=0.0 ||
         (is_buy && tp<=price_to_check+min_distance) ||
         (!is_buy && tp>=price_to_check-min_distance))
      {
         PrintFormat("Skip %s: calculated RR TP %.*f violates broker stop limits.",
                     (is_buy ? "BUY" : "SELL"),_Digits,tp);
         sl=0.0;
         tp=0.0;
         return false;
      }
   }

   if(PrintSignalLog)
      PrintFormat("%s | entry=%.*f swing=%.*f risk=%.*f SL=%s TP=%s",
                  (is_buy ? "BUY" : "SELL"),_Digits,entry,
                  _Digits,reference,_Digits,risk,
                  DoubleToString(sl,_Digits),
                  (UseRRTP ? DoubleToString(tp,_Digits) : "OFF"));
   return true;
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

int ClosePositionsByType(const ENUM_POSITION_TYPE type_to_close)
{
   int closed_count=0;
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
      else
         closed_count++;
   }
   return closed_count;
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
// STATUS PANEL (chart objects, no external indicators or DLL needed)
// Every MA shown on the panel is from shift 1 of ITS OWN timeframe.
// The panel updates on a timer; no order is sent by panel refresh.
//====================================================================
color PanelColorBg()        { return C'15,23,36'; }
color PanelColorRow()       { return C'25,35,51'; }
color PanelColorRowAlt()    { return C'21,30,44'; }
color PanelColorBorder()    { return C'63,77,97'; }
color PanelColorText()      { return C'234,241,248'; }
color PanelColorMuted()     { return C'151,169,190'; }
color PanelColorBuy()       { return C'79,224,157'; }
color PanelColorSell()      { return C'255,118,133'; }
color PanelColorWait()      { return C'243,193,103'; }
color PanelColorChipBuy()   { return C'23,72,63'; }
color PanelColorChipSell()  { return C'94,39,54'; }
color PanelColorChipWait()  { return C'85,67,40'; }

void GetPanelOrigin(int &left,int &top)
{
   // Use the same top-left coordinate system for every object. This keeps
   // labels and rectangles aligned regardless of the selected corner.
   int width = (int)ChartGetInteger(0,CHART_WIDTH_IN_PIXELS);
   int height = (int)ChartGetInteger(0,CHART_HEIGHT_IN_PIXELS);

   left = PanelX;
   top  = PanelY;
   if(PanelCorner==CORNER_RIGHT_UPPER || PanelCorner==CORNER_RIGHT_LOWER)
      left = width - PANEL_WIDTH - PanelX;
   if(PanelCorner==CORNER_LEFT_LOWER || PanelCorner==CORNER_RIGHT_LOWER)
      top = height - PANEL_HEIGHT - PanelY;
   if(left < 0) left = 0;
   if(top < 0) top = 0;
}

void PanelRectangle(const string suffix,const int x,const int y,
                    const int width,const int height,
                    const color background,const color border)
{
   string name = g_panel_prefix + suffix;
   if(ObjectFind(0,name)<0)
   {
      if(!ObjectCreate(0,name,OBJ_RECTANGLE_LABEL,0,0,0))
         return;
      ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
      ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,name,OBJPROP_SELECTED,false);
      ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
      ObjectSetInteger(0,name,OBJPROP_BACK,false);
      ObjectSetInteger(0,name,OBJPROP_BORDER_TYPE,BORDER_FLAT);
   }

   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,name,OBJPROP_XSIZE,width);
   ObjectSetInteger(0,name,OBJPROP_YSIZE,height);
   ObjectSetInteger(0,name,OBJPROP_BGCOLOR,background);
   ObjectSetInteger(0,name,OBJPROP_COLOR,border);
}

void PanelLabel(const string suffix,const string value,
                const int x,const int y,const color clr,
                const int size=10,const string font="Consolas")
{
   string name = g_panel_prefix + suffix;
   if(ObjectFind(0,name)<0)
   {
      if(!ObjectCreate(0,name,OBJ_LABEL,0,0,0))
         return;
      ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
      ObjectSetInteger(0,name,OBJPROP_ANCHOR,ANCHOR_LEFT_UPPER);
      ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,name,OBJPROP_SELECTED,false);
      ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
      ObjectSetInteger(0,name,OBJPROP_BACK,false);
      ObjectSetString(0,name,OBJPROP_FONT,font);
      ObjectSetInteger(0,name,OBJPROP_FONTSIZE,size);
   }

   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,name,OBJPROP_COLOR,clr);
   ObjectSetString(0,name,OBJPROP_TEXT,value);
}

void UpdateStatusPanel()
{
   if(!ShowStatusPanel || g_panel_prefix=="")
      return;

   int x,y;
   GetPanelOrigin(x,y);

   double fast[TF_COUNT],slow[TF_COUNT];
   bool valid[TF_COUNT];
   int direction[TF_COUNT]; // +1 buy, -1 sell, 0 flat/unavailable
   bool all_valid=true,all_buy=true,all_sell=true;
   int enabled_count=EnabledTFCount();

   for(int i=0;i<TF_COUNT;i++)
   {
      fast[i]=0.0;
      slow[i]=0.0;
      valid[i]=(TryReadMA(g_fast_ma_handles[i],SIGNAL_SHIFT,fast[i]) &&
                TryReadMA(g_slow_ma_handles[i],SIGNAL_SHIFT,slow[i]));
      direction[i]=0;
      if(valid[i] && fast[i]>slow[i])
         direction[i]=1;
      else if(valid[i] && fast[i]<slow[i])
         direction[i]=-1;

      // OFF filters never block trend alignment or entry.
      if(!IsTFEnabled(i)) continue;
      if(!valid[i]) all_valid=false;
      if(direction[i]!=1) all_buy=false;
      if(direction[i]!=-1) all_sell=false;
   }

   MqlRates candle[1];
   bool candle_valid=(CopyRates(_Symbol,PERIOD_M5,SIGNAL_SHIFT,1,candle)==1);
   int candle_direction=0; // -1 red, +1 green, 0 doji/unknown
   if(candle_valid)
   {
      if(candle[0].close>candle[0].open) candle_direction=1;
      if(candle[0].close<candle[0].open) candle_direction=-1;
   }

   if(enabled_count==0)
      all_valid=all_buy=all_sell=false;
   bool buy_signal=(all_valid && all_buy && candle_direction==-1);
   bool sell_signal=(all_valid && all_sell && candle_direction==1);

   // Build rectangle objects first, then labels, to keep text on top.
   PanelRectangle("background",x,y,PANEL_WIDTH,PANEL_HEIGHT,
                  PanelColorBg(),PanelColorBorder());
   PanelRectangle("top_accent",x+1,y+1,PANEL_WIDTH-2,4,
                  C'48,139,223',C'48,139,223');

   for(int i=0;i<TF_COUNT;i++)
   {
      int yy=y+99+i*30;
      PanelRectangle(StringFormat("row_%d",i),x+12,yy-3,
                     PANEL_WIDTH-24,27,
                     (i%2==0 ? PanelColorRow() : PanelColorRowAlt()),
                     (i%2==0 ? PanelColorRow() : PanelColorRowAlt()));

      color badge_bg=PanelColorChipWait();
      if(direction[i]==1) badge_bg=PanelColorChipBuy();
      if(direction[i]==-1) badge_bg=PanelColorChipSell();
      if(!IsTFEnabled(i)) badge_bg=PanelColorRowAlt();
      PanelRectangle(StringFormat("chip_%d",i),x+281,yy,
                     96,21,badge_bg,badge_bg);
   }

   PanelRectangle("divider",x+13,y+258,PANEL_WIDTH-26,1,
                  PanelColorBorder(),PanelColorBorder());

   color global_color=PanelColorWait();
   string global_text="MIXED";
   if(enabled_count==0) global_text="NO FILTER";
   else if(!all_valid) global_text="WAIT DATA";
   else if(all_buy) { global_color=PanelColorBuy(); global_text="ALL BUY"; }
   else if(all_sell) { global_color=PanelColorSell(); global_text="ALL SELL"; }
   global_text+=StringFormat(" (%d/%d)",enabled_count,TF_COUNT);

   string candle_text="WAIT DATA";
   color candle_color=PanelColorWait();
   if(candle_valid)
   {
      if(candle_direction==-1) { candle_text="RED (BEARISH)"; candle_color=PanelColorSell(); }
      else if(candle_direction==1) { candle_text="GREEN (BULLISH)"; candle_color=PanelColorBuy(); }
      else { candle_text="DOJI"; candle_color=PanelColorMuted(); }
   }

   string signal_text="WAIT / NO ENTRY";
   color signal_color=PanelColorMuted();
   if(!all_valid || !candle_valid)
   {
      signal_text="WAIT DATA";
      signal_color=PanelColorWait();
   }
   else if(buy_signal) { signal_text="BUY SIGNAL"; signal_color=PanelColorBuy(); }
   else if(sell_signal) { signal_text="SELL SIGNAL"; signal_color=PanelColorSell(); }
   else if(all_buy || all_sell) signal_text="WAIT PULLBACK";

   PanelLabel("title","MULTI-TF MA STATUS",x+15,y+14,PanelColorText(),13,"Arial");
   PanelLabel("trading",(EnableTrading ? "TRADE ON" : "TRADE OFF"),
              x+287,y+17,(EnableTrading ? PanelColorBuy() : PanelColorWait()),9);
   PanelLabel("subtitle",
              StringFormat("%s  M5 ENTRY  |  MA(%d,%d)  %s  |  CLOSED [1]",
                           _Symbol,FastMAPeriod,SlowMAPeriod,
                           (MainMAMethod==MODE_SMA ? "SMA" : EnumToString(MainMAMethod))),
              x+15,y+44,PanelColorMuted(),9);

   PanelLabel("col_tf","TF",x+21,y+76,PanelColorMuted(),9);
   PanelLabel("col_fast",StringFormat("FAST %d",FastMAPeriod),
              x+66,y+76,PanelColorMuted(),9);
   PanelLabel("col_slow",StringFormat("SLOW %d",SlowMAPeriod),
              x+171,y+76,PanelColorMuted(),9);
   PanelLabel("col_dir","TREND",x+298,y+76,PanelColorMuted(),9);

   for(int i=0;i<TF_COUNT;i++)
   {
      int yy=y+101+i*30;
      string key=StringFormat("tf_%d_",i);
      PanelLabel(key+"name",g_tf_names[i],x+21,yy,PanelColorText(),10);
      PanelLabel(key+"fast",(valid[i] ? DoubleToString(fast[i],_Digits) : "--"),
                 x+66,yy,(valid[i] ? PanelColorText() : PanelColorMuted()),10);
      PanelLabel(key+"slow",(valid[i] ? DoubleToString(slow[i],_Digits) : "--"),
                 x+171,yy,(valid[i] ? PanelColorText() : PanelColorMuted()),10);

      string dir_text="WAIT DATA";
      color dir_color=PanelColorWait();
      if(!IsTFEnabled(i)) { dir_text="OFF"; dir_color=PanelColorMuted(); }
      else if(valid[i] && direction[i]==1) { dir_text="BUY"; dir_color=PanelColorBuy(); }
      else if(valid[i] && direction[i]==-1) { dir_text="SELL"; dir_color=PanelColorSell(); }
      else if(valid[i]) { dir_text="FLAT"; dir_color=PanelColorMuted(); }
      PanelLabel(key+"trend",dir_text,x+291,yy+1,dir_color,9);
   }

   PanelLabel("all_lbl","MTF ALIGN",x+17,y+270,PanelColorMuted(),10);
   PanelLabel("all_val",global_text,x+169,y+270,global_color,10);
   PanelLabel("candle_lbl","M5 CANDLE [1]",x+17,y+297,PanelColorMuted(),10);
   PanelLabel("candle_val",candle_text,x+169,y+297,candle_color,10);
   PanelLabel("signal_lbl","ENTRY SIGNAL",x+17,y+324,PanelColorMuted(),10);
   PanelLabel("signal_val",signal_text,x+169,y+324,signal_color,10);
   PanelLabel("pos_lbl","EA POSITIONS",x+17,y+351,PanelColorMuted(),10);
   PanelLabel("pos_val",StringFormat("%d / %d",CountMyPositions(),MaxPositionsPerSymbol),
              x+169,y+351,PanelColorText(),10);

   PanelRectangle("divider_risk",x+13,y+378,PANEL_WIDTH-26,1,
                  PanelColorBorder(),PanelColorBorder());
   PanelLabel("risk_sl_lbl","SWING SL",x+17,y+389,PanelColorMuted(),9);
   PanelLabel("risk_sl_val",(UseSwingSL ? StringFormat("ON  M5 [%d]",SwingLookbackBars) : "OFF"),
              x+169,y+389,(UseSwingSL ? PanelColorBuy() : PanelColorMuted()),9);
   PanelLabel("risk_tp_lbl","TP MODE",x+17,y+416,PanelColorMuted(),9);
   PanelLabel("risk_tp_val",TPModeName(),x+169,y+416,
              (UseRRTP ? PanelColorBuy() : PanelColorMuted()),9);

   string exit_text="--";
   color exit_color=PanelColorMuted();
   if(UsingNoSLTPMode() && NoSLTPMode==TP_FIXED_POINTS)
      exit_text=StringFormat("BROKER TP %d POINTS",FixedTPPoints);
   else if(UsingNoSLTPMode() && NoSLTPMode==TP_M5_MA_CROSS)
   {
      bool cross_up=false,cross_down=false;
      if(!ReadM5Cross(cross_up,cross_down))
      {
         exit_text="WAIT M5 MA DATA";
         exit_color=PanelColorWait();
      }
      else if(cross_down) { exit_text="CLOSE BUY (CROSS DOWN)"; exit_color=PanelColorSell(); }
      else if(cross_up) { exit_text="CLOSE SELL (CROSS UP)"; exit_color=PanelColorBuy(); }
      else exit_text="WAIT FOR M5 CROSS";
   }
   else if(UsingNoSLTPMode() && NoSLTPMode==TP_ALL_ACTIVE_TFS_OPPOSE)
   {
      if(!all_valid) { exit_text="WAIT MTF DATA"; exit_color=PanelColorWait(); }
      else if(all_sell) { exit_text="CLOSE BUY (ALL SELL)"; exit_color=PanelColorSell(); }
      else if(all_buy) { exit_text="CLOSE SELL (ALL BUY)"; exit_color=PanelColorBuy(); }
      else exit_text="WAIT FOR MTF REVERSAL";
   }
   else if(UseSwingSL && UseRRTP)
      exit_text="BROKER RR TP";
   else if(!UseRRTP)
      exit_text="TP DISABLED";

   PanelLabel("exit_lbl","TP STATUS",x+17,y+443,PanelColorMuted(),9);
   PanelLabel("exit_val",exit_text,x+169,y+443,exit_color,9);

   datetime closed_bar=iTime(_Symbol,PERIOD_M5,SIGNAL_SHIFT);
   string closed_time=(closed_bar>0 ? TimeToString(closed_bar,TIME_DATE|TIME_MINUTES) : "--");
   PanelLabel("footer",StringFormat("Last M5 closed: %s   |   Refresh %ds",
                                     closed_time,PanelRefreshSeconds),
              x+17,y+483,PanelColorMuted(),9);
   ChartRedraw(0);
}

void DeleteStatusPanel()
{
   if(g_panel_prefix=="") return;
   for(int i=ObjectsTotal(0,-1,-1)-1;i>=0;i--)
   {
      string name=ObjectName(0,i,-1,-1);
      if(StringFind(name,g_panel_prefix)==0)
         ObjectDelete(0,name);
   }
   ChartRedraw(0);
}

void OnTimer()
{
   UpdateStatusPanel();
}

void OnChartEvent(const int id,const long &lparam,
                  const double &dparam,const string &sparam)
{
   if(id==CHARTEVENT_CHART_CHANGE)
      UpdateStatusPanel();
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

   if(UsingNoSLTPMode() &&
      NoSLTPMode!=TP_FIXED_POINTS &&
      NoSLTPMode!=TP_M5_MA_CROSS &&
      NoSLTPMode!=TP_ALL_ACTIVE_TFS_OPPOSE)
   {
      Print("Invalid NoSLTPMode; choose 1, 2, or 3.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(FastMAPeriod<=0 || SlowMAPeriod<=0 || LotSize<=0.0 ||
      MaxPositionsPerSymbol<=0 || SlippagePoints<0 ||
      SwingLookbackBars<1 || SwingLookbackBars>OHLCV_HISTORY ||
      SwingSLBufferPoints<0 ||
      (UseSwingSL && UseRRTP &&
       (RiskRewardRatio<=0.0 || !MathIsValidNumber(RiskRewardRatio))) ||
      (UsingNoSLTPMode() && NoSLTPMode==TP_FIXED_POINTS && FixedTPPoints<=0) ||
      PanelX<0 || PanelY<0 || PanelRefreshSeconds<1)
   {
      Print("Invalid input parameters.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(EnabledTFCount()==0)
   {
      Print("All timeframe filters are OFF. Enable at least one TF to trade.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(!UseSwingSL && !UseRRTP)
      Print("WARNING: both SL and TP are OFF. New positions have no fixed protective exits.");
   else if(UsingNoSLTPMode())
   {
      PrintFormat("WARNING: no physical Stop Loss. TP method=%s",TPModeName());
      if(NoSLTPMode!=TP_FIXED_POINTS)
         Print("NOTE: Indicator-based exit needs the terminal and EA to remain online. It may close at a loss.");
      if(CloseOnOppositeSignal)
         Print("NOTE: CloseOnOppositeSignal is ignored while SL=OFF and TP=ON. Selected TP method controls exits.");
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

   g_panel_prefix=StringFormat("MTFSMA_%I64u_",MagicNumber);
   if(ShowStatusPanel)
   {
      UpdateStatusPanel();
      if(!EventSetTimer(PanelRefreshSeconds))
         PrintFormat("Panel timer setup failed. Error=%d",GetLastError());
   }

   PrintFormat("MTF SMA EA v2.30 | TF=M5 | Fast=%d Slow=%d | Filters=%d/5 | SwingSL=%s Lookback=%d | TP=%s | Trading=%s",
               FastMAPeriod,SlowMAPeriod,EnabledTFCount(),
               (UseSwingSL ? "ON" : "OFF"),SwingLookbackBars,
               TPModeName(),(EnableTrading ? "ON" : "OFF"));
   return INIT_SUCCEEDED;
}

//====================================================================
// DEINITIALIZATION
//====================================================================
void OnDeinit(const int reason)
{
   EventKillTimer();
   DeleteStatusPanel();
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
   {
      // Safety: M5 cross exits should not depend on all enabled H1/H4
      // history being available, particularly when there is NO real SL.
      if(EnableTrading && UsingNoSLTPMode() && NoSLTPMode==TP_M5_MA_CROSS)
      {
         bool cross_up=false,cross_down=false;
         if(ReadM5Cross(cross_up,cross_down))
         {
            int closed=0;
            if(cross_down) closed+=ClosePositionsByType(POSITION_TYPE_BUY);
            if(cross_up)   closed+=ClosePositionsByType(POSITION_TYPE_SELL);
            if(closed>0)
               g_last_indicator_exit_bar=iTime(_Symbol,PERIOD_M5,0);
         }
      }
      return;
   }

   bool buy_signal  = BuyCondition(s);
   bool sell_signal = SellCondition(s);
   bool close_buy_signal=false,close_sell_signal=false;
   CalculateExitSignals(s,close_buy_signal,close_sell_signal);

   // Update immediately when the M5 entry bar changes.
   UpdateStatusPanel();

   if(PrintSignalLog)
   {
      PrintFormat("M5 closed candle: O=%.*f C=%.*f | EnabledTF=%d | All BUY=%s All SELL=%s | BUY=%s SELL=%s",
                  _Digits,s.open,_Digits,s.close,EnabledTFCount(),
                  (AllActiveTFsAgree(s,true) ? "YES" : "NO"),
                  (AllActiveTFsAgree(s,false) ? "YES" : "NO"),
                  (buy_signal ? "YES" : "NO"),
                  (sell_signal ? "YES" : "NO"));
   }

   if(!EnableTrading)
      return;

   // Exit first. In no-SL TP modes, ignore the legacy opposite-entry exit.
   int exited_buy=0,exited_sell=0;
   if(close_buy_signal)
      exited_buy=ClosePositionsByType(POSITION_TYPE_BUY);
   if(close_sell_signal)
      exited_sell=ClosePositionsByType(POSITION_TYPE_SELL);

   // Prevent immediate re-entry from a still-valid same-bar signal after
   // a TP-by-MA closure, including when TradeOnNewBarOnly=false.
   if(UsingNoSLTPMode() && NoSLTPMode!=TP_FIXED_POINTS &&
      (exited_buy>0 || exited_sell>0))
      g_last_indicator_exit_bar=iTime(_Symbol,PERIOD_M5,0);
   if(g_last_indicator_exit_bar>0 &&
      g_last_indicator_exit_bar==iTime(_Symbol,PERIOD_M5,0))
      return;

   if(CountMyPositions()>=MaxPositionsPerSymbol)
      return;

   if(buy_signal==sell_signal) // No signal, or both conflicting.
      return;

   if(buy_signal)
   {
      // Do not open a BUY while an opposite EA position remains open.
      if(CountMyPositionsByType(POSITION_TYPE_SELL)>0)
         return;

      MqlTick tick;
      if(!SymbolInfoTick(_Symbol,tick))
         return;
      double sl=0.0,tp=0.0;
      if(!PrepareOrderStops(s,true,tick,sl,tp))
         return;
      bool sent=trade.Buy(LotSize,_Symbol,0.0,sl,tp,"MTF SMA BUY");
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

      MqlTick tick;
      if(!SymbolInfoTick(_Symbol,tick))
         return;
      double sl=0.0,tp=0.0;
      if(!PrepareOrderStops(s,false,tick,sl,tp))
         return;
      bool sent=trade.Sell(LotSize,_Symbol,0.0,sl,tp,"MTF SMA SELL");
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
