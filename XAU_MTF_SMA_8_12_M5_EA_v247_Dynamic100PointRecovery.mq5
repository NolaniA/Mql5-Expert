//+------------------------------------------------------------------+
//|       XAU_MTF_SMA_8_12_M5_EA_BASELINE_001.mq5       |
//|  M5 pullback entries filtered by selected MTF SMA 8/12 trends.   |
//|  Optional swing SL, three TP modes, hedging and basket POINTS exit.      |
//+------------------------------------------------------------------+
#property strict
#property version   "2.47"
#property description "MTF SMA majority bias / all-agree entry, same-side basket TP, opposite recovery and scalable UI"

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
input int    MaxPositionsPerSymbol  = 0;  // 0 = UNLIMITED (still max 1 new trade/M5 bar)
input bool   AllowBothDirections    = true; // Hedging account required to hold BUY + SELL
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

// Select how MTF MA(8,12) direction is aggregated for ENTRY ONLY.
// TP_ALL_ACTIVE_TFS_OPPOSE continues to require ALL enabled TFs reversed.
enum ENUM_MTF_ENTRY_BIAS_MODE
{
   MTF_ALL_AGREE = 0, // Old behavior: every enabled TF must point the same way
   MTF_MAJORITY  = 1  // New default: more BUY votes than SELL -> BUY, reverse -> SELL
};

input group "=== Entry Conditions (independently selectable) ==="
input bool UseMTFTrendEntryFilter    = true; // Enable the selected MTF entry bias filter
input ENUM_MTF_ENTRY_BIAS_MODE MTFEntryBiasMode = MTF_MAJORITY; // Default: vote count (ignore disabled TFs)
input bool UseCandleColorEntryFilter = true; // BUY: M5 [1] RED; SELL: M5 [1] GREEN
input bool UseCandleBodyWickEntryFilter = true; // Extra candle body/wick shape on M5 [1]
// BUY: body > upper wick AND upper wick < lower wick
// SELL: body > lower wick AND lower wick < upper wick
// For red candles, upper wick = High - Open (NOT High - Close).

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
input ENUM_NO_SL_TP_MODE  NoSLTPMode       = TP_FIXED_POINTS; // Active when Swing SL OFF, TP ON
input int                 FixedTPPoints    = 500;  // Used by TP_FIXED_POINTS only, in broker points
input group "=== Basket Take Profit (when BOTH BUY and SELL exist) ==="
// Unit: SYMBOL POINTS (not USD), combined across positions.
// A trade at LotSize contributes its full price movement in points.
// Larger/smaller lots are scaled by (position volume / LotSize).
input double BasketProfitTarget    = 500.0; // e.g., 500 combined, lot-weighted broker points

input group "=== Recovery Lot (latch until ALL EA positions close) ==="
input bool   UseRecoveryLot        = true; // Optional: safer default OFF
// 0 = dynamic volume to model a BasketProfitTarget exit after a favorable
// DynamicRecoveryMovePoints move. >=1 = original one-time fixed multiplier.
input double RecoveryLotMultiplier = 2.0;
input int    DynamicRecoveryMovePoints = 100;   // Favorable move AFTER the new entry (broker points)
input double MaxDynamicRecoveryLot = 0.10;    // HARD cap: skip entries requiring more; never silently clamp
input double MaxDynamicMarginPct    = 30.0;   // Reject if projected order margin > this % of free margin

input group "=== Same-Side Basket Take Profit (NO LOT MULTIPLIER) ==="
// Retain original input NAME so existing .set presets still recognize the switch.
// When a NEW same-side entry is signaled while a position on that side is losing,
// open at NORMAL requested lot (subject only to the separate opposite recovery)
// and latch basket TP over ALL EA positions. Reset when all EA positions close.
input bool   UseSameSideRecoveryLot = true;

input group "=== Exits / Display ==="
input bool CloseOnOppositeSignal = true;  // Ignored while AllowBothDirections=true
input bool ShowIndicatorsOnChart = false;
input bool PrintSignalLog        = false;

input group "=== MTF Status Panel ==="
input bool             ShowStatusPanel     = true;
input ENUM_BASE_CORNER PanelCorner         = CORNER_LEFT_UPPER;
input int              PanelX              = 16;     // Distance from the chosen chart corner
input int              PanelY              = 24;
input int              PanelRefreshSeconds = 2;      // Display refresh only; trades remain M5-based
input int              PanelFontScalePercent = 100;    // 60..150, scales fonts AND panel geometry to prevent overlap
input bool             PanelAutoFitToChart   = true;   // Automatically shrink the panel to fit smaller charts

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
datetime g_last_indicator_exit_bar = 0; // Prevent same-bar reentry after basket/indicator exits.
datetime g_last_entry_bar          = 0; // At most one NEW position per M5 candle.
bool     g_basket_closing          = false; // Retry failed basket closes until all are closed.
bool     g_recovery_active         = false; // Latched after first opposite entry until all EA positions are flat.
string   g_recovery_key            = "";    // MT5 terminal GlobalVariable; survives EA/terminal restart.
bool     g_same_recovery_active = false; // Same-side basket TP latched until all EA positions are flat.
string   g_same_recovery_key    = "";    // Persisted boolean in terminal Global Variables.
string g_panel_prefix = "";
double g_panel_scale = 1.0;
int g_panel_user_percent = 100; // May be adjusted using the on-chart A- / A+ buttons.
int g_panel_left = 0;
int g_panel_top = 0;

// Unscaled design dimensions. All chart objects are transformed at draw time.
#define PANEL_WIDTH  390
#define PANEL_HEIGHT 785

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

   // MA data is mandatory only if it is used for entry filtering or
   // ALL-ACTIVE-TFS-Opposite TP. Other entry filters can operate alone.
   bool require_mtfs=(UseMTFTrendEntryFilter ||
                      (UsingNoSLTPMode() && NoSLTPMode==TP_ALL_ACTIVE_TFS_OPPOSE));
   for(int i=0; i<TF_COUNT; i++)
   {
      s.fast_ma[i]=0.0;
      s.slow_ma[i]=0.0;
      if(!IsTFEnabled(i)) continue;
      if(require_mtfs)
      {
         if(!CopyOne(g_fast_ma_handles[i],0,SIGNAL_SHIFT,s.fast_ma[i]))
            return false;
         if(!CopyOne(g_slow_ma_handles[i],0,SIGNAL_SHIFT,s.slow_ma[i]))
            return false;
      }
      else
      {
         // Optional data for status/exits; unavailable values never block
         // candle-only entry because MA filtering is switched OFF.
         TryReadMA(g_fast_ma_handles[i],SIGNAL_SHIFT,s.fast_ma[i]);
         TryReadMA(g_slow_ma_handles[i],SIGNAL_SHIFT,s.slow_ma[i]);
      }
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

// TF selection remains separate from the master ENTRY switch.
// Also used by TP mode 3; the TP logic does NOT consult the entry switch.
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

// Sum votes from enabled timeframes, always using CLOSED candle index [1].
// SMA8 > SMA12 = BUY vote; SMA8 < SMA12 = SELL vote; equal = neutral.
// OFF timeframes are not counted. All 5 TFs have equal vote weight.
void CountMTFEntryVotes(const IndicatorState &s,
                        int &buy_votes,int &sell_votes,int &flat_votes)
{
   buy_votes=0;
   sell_votes=0;
   flat_votes=0;
   for(int i=0;i<TF_COUNT;i++)
   {
      if(!IsTFEnabled(i)) continue;
      if(s.fast_ma[i]>s.slow_ma[i]) buy_votes++;
      else if(s.fast_ma[i]<s.slow_ma[i]) sell_votes++;
      else flat_votes++;
   }
}

// +1 = BUY bias, -1 = SELL bias, 0 = tie/flat/no valid majority.
// Called ONLY after required enabled-TF indicators have been loaded.
int MTFEntryBiasDirection(const IndicatorState &s)
{
   if(EnabledTFCount()==0) return 0;
   if(MTFEntryBiasMode==MTF_ALL_AGREE)
   {
      if(AllActiveTFsAgree(s,true)) return 1;
      if(AllActiveTFsAgree(s,false)) return -1;
      return 0;
   }

   int buys=0,sells=0,flats=0;
   CountMTFEntryVotes(s,buys,sells,flats);
   if(buys>sells && buys>0) return 1;
   if(sells>buys && sells>0) return -1;
   return 0; // Ties do NOT open trades (also no trade for all-flat).
}

// FILTER 1: the selected SMA bias is required only when this switch is ON.
bool PassEntryTrendFilter(const IndicatorState &s,const bool want_buy)
{
   if(!UseMTFTrendEntryFilter) return true;
   int bias=MTFEntryBiasDirection(s);
   return (want_buy ? bias==1 : bias==-1);
}

// FILTER 2: the existing M5 pullback color condition (closed candle [1]).
bool PassEntryCandleColorFilter(const IndicatorState &s,const bool want_buy)
{
   if(!UseCandleColorEntryFilter) return true;
   return (want_buy ? (s.close<s.open) : (s.close>s.open));
}

// FILTER 3: independently selectable body/wick shape on closed M5 [1].
// Body:  abs(Close-Open)
// Upper: High-max(Open,Close)    (works on both red and green candles)
// Lower: min(Open,Close)-Low     (works on both red and green candles)
// This normalization is necessary: on a RED BUY candle High-Close
// includes the entire candle body, so Body > High-Close is impossible.
bool CandleBodyWickPattern(const double o,const double h,
                           const double l,const double c,const bool want_buy)
{
   if(!MathIsValidNumber(o) || !MathIsValidNumber(h) ||
      !MathIsValidNumber(l) || !MathIsValidNumber(c) ||
      h<MathMax(o,c) || l>MathMin(o,c))
      return false;

   double body=MathAbs(c-o);
   double upper=h-MathMax(o,c);
   double lower=MathMin(o,c)-l;
   if(body<=0.0) return false; // Doji cannot confirm either pattern.
   if(want_buy)
      return (body>upper && upper<lower);
   return (body>lower && lower<upper); // Mirror of BUY.
}

bool PassEntryBodyWickFilter(const IndicatorState &s,const bool want_buy)
{
   if(!UseCandleBodyWickEntryFilter) return true;
   return CandleBodyWickPattern(s.open,s.high,s.low,s.close,want_buy);
}

bool EntryCondition(const IndicatorState &s,const bool want_buy)
{
   // All enabled conditions must pass; turning one off bypasses ONLY it.
   return (PassEntryTrendFilter(s,want_buy) &&
           PassEntryCandleColorFilter(s,want_buy) &&
           PassEntryBodyWickFilter(s,want_buy));
}

bool BuyCondition(const IndicatorState &s)
{
   return EntryCondition(s,true);
}

bool SellCondition(const IndicatorState &s)
{
   return EntryCondition(s,false);
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
                       const MqlTick &tick,double &sl,double &tp,
                       const bool basket_entry=false)
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
      if(NoSLTPMode==TP_FIXED_POINTS && !basket_entry)
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
                     (tp>0.0 ? DoubleToString(tp,_Digits) : "NONE (EA-managed/basket)"));
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

   if(UseRRTP && !basket_entry)
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
// HEDGE/BASKET POSITION HELPERS
// Always operate ONLY on positions matching symbol and MagicNumber.
// Floating basket P/L includes POSITION_PROFIT and POSITION_SWAP;
// broker commissions booked separately are not included.
//====================================================================
void ScanMyBasket(int &buy_count,int &sell_count,double &floating_profit)
{
   buy_count=0;
   sell_count=0;
   floating_profit=0.0;
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC)!=MagicNumber) continue;
      ENUM_POSITION_TYPE side=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if(side==POSITION_TYPE_BUY) buy_count++;
      if(side==POSITION_TYPE_SELL) sell_count++;
      floating_profit+=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
   }
}

bool HasMyHedge()
{
   int buys,sells;
   double pl;
   ScanMyBasket(buys,sells,pl);
   return (buys>0 && sells>0);
}

//====================================================================
// RECOVERY LOT (ONE-TIME STEP, NOT A MARTINGALE ON EACH FLIP)
//
// The first position in a fresh basket uses LotSize. If a later entry
// is in the OPPOSITE direction to ANY existing EA position, that entry
// uses LotSize * RecoveryLotMultiplier when multiplier >=1. When 0,
// each new recovery entry is SIZED DYNAMICALLY from all currently open EA
// positions and the 100-point favorable move model, until FLAT.
// The latch is stored in MT5 Terminal Global Variables, so restarting
// the EA does not silently reset risk while an unfinished basket exists.
// Only positions matching THIS SYMBOL and MagicNumber count.
//====================================================================
void SetRecoveryActive()
{
   if(!UseRecoveryLot || g_recovery_active)
      return;
   g_recovery_active=true;
   if(g_recovery_key!="" && GlobalVariableSet(g_recovery_key,1.0)==0)
      PrintFormat("WARNING: recovery latch could not be persisted. Error=%d",GetLastError());
   if(RecoveryLotMultiplier==0.0)
      PrintFormat("DYNAMIC RECOVERY ACTIVE: target %.1f basket points after favorable %d-point move; re-size each new recovery entry until FLAT.",
                  BasketProfitTarget,DynamicRecoveryMovePoints);
   else
      PrintFormat("RECOVERY LOT ACTIVATED: future entries use LotSize %.3f x %.2f until all positions are closed.",
                  LotSize,RecoveryLotMultiplier);
}

void RefreshRecoveryState()
{
   int position_count=CountMyPositions();
   if(position_count==0)
   {
      // Reset ONLY when the entire basket has cleared. A single remaining
      // side does NOT reset recovery, even if the hedge is no longer active.
      if(g_recovery_active)
         Print("RECOVERY LOT RESET: all EA positions closed; next basket starts at LotSize.");
      g_recovery_active=false;
      if(g_recovery_key!="" && GlobalVariableCheck(g_recovery_key))
         GlobalVariableDel(g_recovery_key);
      return;
   }

   if(!UseRecoveryLot) return;

   // Recover the latch after EA restart, parameter reload, or terminal crash.
   if(!g_recovery_active && g_recovery_key!="" &&
      GlobalVariableCheck(g_recovery_key) && GlobalVariableGet(g_recovery_key)>0.5)
      g_recovery_active=true;

   // If an existing basket is hedged when first attaching this EA,
   // activate recovery even if the persisted latch did not yet exist.
   if(!g_recovery_active && HasMyHedge())
      SetRecoveryActive();
}

// Does an existing EA position in the SAME direction have floating loss?
// New same-side signals are evaluated independently by the existing M5 entry
// filters; this function NEVER opens an order on its own.
// Only POSITION_PROFIT < 0 qualifies; swap does not change eligibility.
bool HasLosingSameSidePosition(const bool is_buy)
{
   ENUM_POSITION_TYPE wanted=(is_buy ? POSITION_TYPE_BUY : POSITION_TYPE_SELL);
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC)!=MagicNumber) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE)!=wanted) continue;
      if(PositionGetDouble(POSITION_PROFIT)<0.0) return true;
   }
   return false;
}

void RefreshSameSideRecoveryState()
{
   // The basket latch is reset ONLY when all matching positions are flat.
   if(CountMyPositions()==0)
   {
      if(g_same_recovery_active)
         Print("SAME-SIDE BASKET RESET: all positions closed; next cycle uses normal lot and TP.");
      g_same_recovery_active=false;
      if(g_same_recovery_key!="" && GlobalVariableCheck(g_same_recovery_key))
         GlobalVariableDel(g_same_recovery_key);
      return;
   }

   if(!UseSameSideRecoveryLot) return;
   if(!g_same_recovery_active && g_same_recovery_key!="" &&
      GlobalVariableCheck(g_same_recovery_key) &&
      GlobalVariableGet(g_same_recovery_key)>0.5)
      g_same_recovery_active=true;
}

void LatchSameSideBasket()
{
   if(!UseSameSideRecoveryLot || g_same_recovery_active) return;
   g_same_recovery_active=true;
   if(g_same_recovery_key!="" && GlobalVariableSet(g_same_recovery_key,1.0)==0)
      PrintFormat("WARNING: cannot persist same-side basket state, error=%d",GetLastError());
   PrintFormat("SAME-SIDE BASKET ACTIVE: NO lot multiplier; close ALL at %.1f combined points (lot-weighted).",
               BasketProfitTarget);
}

// The opposite-direction Recovery Lot option is intentionally independent.
// Enabling same-side basket TP does NOT change entry volume at all.
double RequestedEntryLot(const bool opening_hedge)
{
   double requested=LotSize;
   if(UseRecoveryLot && RecoveryLotMultiplier>0.0 &&
      (g_recovery_active || opening_hedge))
      requested=MathMax(requested,LotSize*RecoveryLotMultiplier);
   return requested;
}

// Normalize volume DOWN to the broker's step. The same-side basket feature
// never requires rounding UP because it never increases lot size.
bool PrepareEntryVolume(const double requested,double &volume,const bool round_up=false,
                        const bool report=true)
{
   volume=0.0;
   double min_vol=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double max_vol=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   if(requested<=0.0 || !MathIsValidNumber(requested) ||
      min_vol<=0.0 || max_vol<min_vol || step<=0.0)
   {
      Print("Cannot prepare entry volume: invalid lot size or broker volume specification.");
      return false;
   }

   double steps=requested/step;
   volume=NormalizeDouble((round_up ? MathCeil(steps-1e-8) : MathFloor(steps+1e-8))*step,8);
   if(volume<min_vol-1e-8 || volume>max_vol+1e-8)
   {
      PrintFormat("Skip entry: requested lot=%.8f, rounded=%.8f, broker range=%.8f..%.8f",
                  requested,volume,min_vol,max_vol);
      return false;
   }
   if(report && MathAbs(volume-requested)>1e-8)
      PrintFormat("Lot rounded %s to broker step: requested=%.8f actual=%.8f step=%.8f",
                  (round_up ? "UP" : "DOWN"),requested,volume,step);
   return true;
}

//====================================================================
// COMBINED BASKET PROFIT IN BROKER POINTS, NOT IN ACCOUNT CURRENCY.
// Lot-weighted SUM relative to the configured EA entry LotSize.
//
// For a BUY:  (Bid - entry) / _Point = tradable floating points.
// For a SELL: (entry - Ask) / _Point = tradable floating points.
//
// Example with LotSize=0.01:
//   BUY 0.01:  +400 points, SELL 0.01: -100 points
//   basket points = +400 * (0.01/0.01) - 100 * (0.01/0.01)
//                 = +300 points.
// Position lots differing from LotSize are weighted proportionally.
// Includes bid/ask spread through exit quotes, but excludes swaps,
// commissions, fees, and slippage; these have no fixed point equivalent.
// Works only for the current _Symbol and MagicNumber.
//====================================================================
bool CalculateBasketProfitPoints(double &basket_points)
{
   basket_points=0.0;
   if(_Point<=0.0 || LotSize<=0.0)
      return false;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick) || tick.bid<=0.0 || tick.ask<=0.0)
      return false;

   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC)!=MagicNumber) continue;

      ENUM_POSITION_TYPE side=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if(side!=POSITION_TYPE_BUY && side!=POSITION_TYPE_SELL)
         continue;

      double entry=PositionGetDouble(POSITION_PRICE_OPEN);
      double volume=PositionGetDouble(POSITION_VOLUME);
      if(entry<=0.0 || volume<=0.0)
         return false;

      double points=(side==POSITION_TYPE_BUY ? (tick.bid-entry)/_Point
                                                   : (entry-tick.ask)/_Point);
      basket_points+=points*(volume/LotSize);
   }

   return MathIsValidNumber(basket_points);
}

//====================================================================
// DYNAMIC OPPOSITE/RECOVERY LOT (RecoveryLotMultiplier = 0)
//====================================================================
// Price-movement model for the next DynamicRecoveryMovePoints in the
// NEW ORDER's favorable direction, assuming constant spread and no changes
// to other positions. Points are weighted by lots / configured LotSize.
//
//   futureBasket = currentBasket + D*direction*netExistingLots/LotSize
//                  + (D-currentSpreadPoints)*newLot/LotSize
//
// Solve futureBasket >= BasketProfitTarget for newLot, then ROUND UP to the
// broker step (subject to hard volume & margin caps). This is a projection,
// NOT a guaranteed close price or an estimate of cash profit. It excludes
// future spread changes, slippage, swap, commissions, and broker execution.
// No entry is sent if a viable capped volume cannot meet the projection.
// The normal first entry in a flat basket always uses LotSize.
bool CalculateDynamicRecoveryVolume(const bool is_buy,
                                    double &volume,double &projected_points,
                                    const bool report=true)
{
   volume=0.0;
   projected_points=0.0;
   if(CountMyPositions()==0 || _Point<=0.0 || LotSize<=0.0 ||
      DynamicRecoveryMovePoints<=0)
      return false;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick) || tick.bid<=0 || tick.ask<=0 || tick.ask<tick.bid)
      return false;
   double current_points=0.0;
   if(!CalculateBasketProfitPoints(current_points)) return false;

   double buy_lots=0.0,sell_lots=0.0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC)!=MagicNumber) continue;
      ENUM_POSITION_TYPE side=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if(side==POSITION_TYPE_BUY) buy_lots+=PositionGetDouble(POSITION_VOLUME);
      else if(side==POSITION_TYPE_SELL) sell_lots+=PositionGetDouble(POSITION_VOLUME);
   }

   double D=(double)DynamicRecoveryMovePoints;
   double spread_pts=(tick.ask-tick.bid)/_Point;
   double new_effective_gain=D-spread_pts;
   if(new_effective_gain<=0.0)
   {
      if(report)
         PrintFormat("DYNAMIC RECOVERY SKIPPED: spread %.1f pts >= intended move %.1f pts.",spread_pts,D);
      return false;
   }
   double direction=(is_buy ? 1.0 : -1.0);
   double net_lots=buy_lots-sell_lots;
   double projected_old=current_points+D*direction*net_lots/LotSize;
   double points_needed=BasketProfitTarget-projected_old;
   if(points_needed<=0.0)
   {
      // No extra recovery volume is necessary to meet the forecast.
      // Do not add exposure merely to force an entry.
      if(report)
         PrintFormat("DYNAMIC RECOVERY SKIPPED: existing net %.3f lot already projects %.1f pts (target %.1f).",
                     net_lots,projected_old,BasketProfitTarget);
      return false;
   }
   double requested=MathMax(LotSize, LotSize*points_needed/new_effective_gain);
   if(!MathIsValidNumber(requested) || requested<=0.0 ||
      requested>MaxDynamicRecoveryLot+1e-9)
   {
      if(report)
         PrintFormat("DYNAMIC RECOVERY SKIPPED: required %.5f lot exceeds cap %.5f lot (basket %.1f pts, net lot %.3f).",
                     requested,MaxDynamicRecoveryLot,current_points,net_lots);
      return false;
   }

   // Round UP so broker volume steps never invalidate the target projection.
   if(!PrepareEntryVolume(requested,volume,true,report)) return false;
   if(volume>MaxDynamicRecoveryLot+1e-9)
   {
      if(report)
         PrintFormat("DYNAMIC RECOVERY SKIPPED: rounded %.5f lot exceeds cap %.5f lot.",volume,MaxDynamicRecoveryLot);
      volume=0.0;
      return false;
   }

   double entry_price=(is_buy ? tick.ask : tick.bid);
   double margin=0.0;
   if(!OrderCalcMargin((is_buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL),_Symbol,
                       volume,entry_price,margin) || !MathIsValidNumber(margin))
   {
      if(report) PrintFormat("DYNAMIC RECOVERY SKIPPED: margin estimate failed (error=%d).",GetLastError());
      volume=0.0;
      return false;
   }
   double margin_cap=AccountInfoDouble(ACCOUNT_MARGIN_FREE)*MaxDynamicMarginPct/100.0;
   if(margin>margin_cap || margin_cap<=0.0)
   {
      if(report)
         PrintFormat("DYNAMIC RECOVERY SKIPPED: required margin %.2f exceeds allowed %.2f (%.1f%% free margin).",
                     margin,margin_cap,MaxDynamicMarginPct);
      volume=0.0;
      return false;
   }

   projected_points=projected_old+new_effective_gain*volume/LotSize;
   if(projected_points+1e-5<BasketProfitTarget)
   {
      if(report) Print("DYNAMIC RECOVERY SKIPPED: rounded volume does not reach target projection.");
      volume=0.0;
      return false;
   }
   if(report)
      PrintFormat("DYNAMIC RECOVERY: existing B %.3f / S %.3f; basket %.1f pts; spread %.1f pts; %s %.5f lot => projected %.1f pts after %d favorable points (target %.1f).",
                  buy_lots,sell_lots,current_points,spread_pts,
                  (is_buy ? "BUY" : "SELL"),volume,projected_points,
                  DynamicRecoveryMovePoints,BasketProfitTarget);
   return true;
}

// Returns requested broker-side TP, or 0 when current mode is EA-managed.
// Recalculate from ORIGINAL entry and unchanged position SL so targets can
// be restored if one side of a hedge disappears (SL/manual close/restart).
double PhysicalTPForSelectedPosition()
{
   if(!UseRRTP) return 0.0;
   ENUM_POSITION_TYPE side=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   bool is_buy=(side==POSITION_TYPE_BUY);
   double entry=PositionGetDouble(POSITION_PRICE_OPEN);
   if(entry<=0.0) return 0.0;

   if(UseSwingSL)
   {
      double sl=PositionGetDouble(POSITION_SL);
      if(sl<=0.0) return 0.0;
      double risk=(is_buy ? entry-sl : sl-entry);
      if(risk<=0.0) return 0.0;
      double raw=(is_buy ? entry+RiskRewardRatio*risk : entry-RiskRewardRatio*risk);
      return NormalizeTickPrice(raw,is_buy);
   }
   if(NoSLTPMode==TP_FIXED_POINTS)
   {
      double raw=(is_buy ? entry+FixedTPPoints*_Point : entry-FixedTPPoints*_Point);
      return NormalizeTickPrice(raw,is_buy);
   }
   return 0.0;
}

// When BOTH sides exist, physical TPs must be stripped so that an individual
// TP cannot close the order before the basket reaches its combined target.
// On return to one-sided trading, restore price-based TP if practicable.
// Returns false if a required position modification failed.
bool SynchronizeTakeProfits(const bool basket_mode)
{
   if(!UseRRTP && !basket_mode) return true;
   bool all_ok=true;
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick)) return false;
   long stop_points=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   long freeze_points=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_FREEZE_LEVEL);
   double min_distance=(double)MathMax(stop_points,freeze_points)*_Point;
   double tolerance=MathMax(_Point*0.1,SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE)*0.1);

   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC)!=MagicNumber) continue;

      double current_tp=PositionGetDouble(POSITION_TP);
      double sl=PositionGetDouble(POSITION_SL);
      if(basket_mode)
      {
         if(current_tp==0.0) continue;
         bool modified=trade.PositionModify(ticket,sl,0.0);
         uint code=trade.ResultRetcode();
         if(!modified || code!=TRADE_RETCODE_DONE)
         {
            PrintFormat("BASKET TP removal FAILED ticket=%I64u, code=%u %s",
                        ticket,code,trade.ResultRetcodeDescription());
            all_ok=false;
         }
         continue;
      }

      double desired=PhysicalTPForSelectedPosition();
      // MA-managed TP does not create a broker-side physical TP.
      if(desired<=0.0 || MathAbs(current_tp-desired)<=tolerance) continue;
      bool buy=(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY);
      double close_price=(buy ? tick.bid : tick.ask);

      // If the original target has ALREADY been reached, close that
      // individual position instead of trying to reattach an invalid TP.
      if((buy && close_price>=desired) || (!buy && close_price<=desired))
      {
         bool closed=trade.PositionClose(ticket);
         uint code=trade.ResultRetcode();
         if(!closed || (code!=TRADE_RETCODE_DONE && code!=TRADE_RETCODE_DONE_PARTIAL))
         {
            PrintFormat("Restore TP close FAILED ticket=%I64u code=%u",ticket,code);
            all_ok=false;
         }
         else
            g_last_indicator_exit_bar=iTime(_Symbol,PERIOD_M5,0);
         continue;
      }
      if((buy && desired<=close_price+min_distance) ||
         (!buy && desired>=close_price-min_distance))
      {
         // Inside broker freeze/stops zone: retry later; never move TP outward.
         all_ok=false;
         continue;
      }
      bool modified=trade.PositionModify(ticket,sl,desired);
      uint code=trade.ResultRetcode();
      if(!modified || code!=TRADE_RETCODE_DONE)
      {
         if(PrintSignalLog)
            PrintFormat("TP restore failed ticket=%I64u code=%u %s",ticket,code,
                        trade.ResultRetcodeDescription());
         all_ok=false;
      }
   }
   return all_ok;
}

// Close all EA positions as a single basket. If any close fails,
// g_basket_closing keeps the retry running on subsequent ticks.
void CloseMyBasket()
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC)!=MagicNumber) continue;
      bool closed=trade.PositionClose(ticket);
      uint code=trade.ResultRetcode();
      if(!closed || (code!=TRADE_RETCODE_DONE && code!=TRADE_RETCODE_DONE_PARTIAL))
         PrintFormat("BASKET CLOSE FAILED ticket=%I64u retcode=%u %s",
                     ticket,code,trade.ResultRetcodeDescription());
   }
   if(CountMyPositions()==0)
   {
       g_basket_closing=false;
       RefreshRecoveryState();
       RefreshSameSideRecoveryState();
       Print("BASKET CLOSED: all EA positions closed. Recovery states reset.");
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

// Auto-fit and user font scaling operate together so shrinking the fonts
// also shrinks row spacing/rectangles instead of causing overlapping labels.
int PanelPixels(const int value)
{
   return (int)MathMax(1.0,MathRound((double)value*g_panel_scale));
}

void GetPanelOrigin(int &left,int &top)
{
   int width=(int)ChartGetInteger(0,CHART_WIDTH_IN_PIXELS);
   int height=(int)ChartGetInteger(0,CHART_HEIGHT_IN_PIXELS);
   g_panel_scale=(double)g_panel_user_percent/100.0;
   if(PanelAutoFitToChart && width>0 && height>0)
   {
      double fit_w=(double)MathMax(1,width-PanelX-8)/(double)PANEL_WIDTH;
      double fit_h=(double)MathMax(1,height-PanelY-8)/(double)PANEL_HEIGHT;
      g_panel_scale=MathMin(g_panel_scale,MathMin(fit_w,fit_h));
   }
   // Some fonts cannot render smaller than 6px on MT5.
   g_panel_scale=MathMax(0.35,g_panel_scale);
   int scaled_width=PanelPixels(PANEL_WIDTH);
   int scaled_height=PanelPixels(PANEL_HEIGHT);

   left=PanelX;
   top=PanelY;
   if(PanelCorner==CORNER_RIGHT_UPPER || PanelCorner==CORNER_RIGHT_LOWER)
      left=width-scaled_width-PanelX;
   if(PanelCorner==CORNER_LEFT_LOWER || PanelCorner==CORNER_RIGHT_LOWER)
      top=height-scaled_height-PanelY;
   if(left<0) left=0;
   if(top<0) top=0;
   g_panel_left=left;
   g_panel_top=top;
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

   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,g_panel_left+PanelPixels(x-g_panel_left));
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,g_panel_top+PanelPixels(y-g_panel_top));
   ObjectSetInteger(0,name,OBJPROP_XSIZE,PanelPixels(width));
   ObjectSetInteger(0,name,OBJPROP_YSIZE,PanelPixels(height));
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
   }

   // Font and coordinate properties are refreshed even for existing labels.
   ObjectSetInteger(0,name,OBJPROP_FONTSIZE,(int)MathMax(6.0,MathRound(size*g_panel_scale)));
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,g_panel_left+PanelPixels(x-g_panel_left));
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,g_panel_top+PanelPixels(y-g_panel_top));
   ObjectSetInteger(0,name,OBJPROP_COLOR,clr);
   ObjectSetString(0,name,OBJPROP_TEXT,value);
}

// Interactive panel controls. Buttons are repositioned on every render so
// they follow chart resize, PanelCorner and user scaling consistently.
void PanelButton(const string suffix,const string label,const int x,const int y,
                 const int width,const int height)
{
   string name=g_panel_prefix+suffix;
   if(ObjectFind(0,name)<0)
   {
      if(!ObjectCreate(0,name,OBJ_BUTTON,0,0,0)) return;
      ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
      ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
      ObjectSetInteger(0,name,OBJPROP_BACK,false);
      ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
      ObjectSetString(0,name,OBJPROP_FONT,"Arial");
   }
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,g_panel_left+PanelPixels(x-g_panel_left));
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,g_panel_top+PanelPixels(y-g_panel_top));
   ObjectSetInteger(0,name,OBJPROP_XSIZE,PanelPixels(width));
   ObjectSetInteger(0,name,OBJPROP_YSIZE,PanelPixels(height));
   ObjectSetInteger(0,name,OBJPROP_COLOR,PanelColorText());
   ObjectSetInteger(0,name,OBJPROP_BGCOLOR,PanelColorRow());
   ObjectSetInteger(0,name,OBJPROP_BORDER_COLOR,PanelColorBorder());
   ObjectSetInteger(0,name,OBJPROP_FONTSIZE,(int)MathMax(6.0,MathRound(10*g_panel_scale)));
   ObjectSetString(0,name,OBJPROP_TEXT,label);
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
   int buy_votes=0,sell_votes=0,flat_votes=0;

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
      if(valid[i])
      {
         if(direction[i]==1) buy_votes++;
         else if(direction[i]==-1) sell_votes++;
         else flat_votes++;
      }
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
   // Use the same functions as OnTick so Panel and actual entry cannot
   // disagree when color, wick/body or MTF entry filters are disabled.
   bool can_check_entry=(candle_valid && (!UseMTFTrendEntryFilter || all_valid));
   bool buy_signal=false;
   bool sell_signal=false;
   if(can_check_entry)
   {
      IndicatorState panel_state;
      panel_state.open=candle[0].open;
      panel_state.high=candle[0].high;
      panel_state.low=candle[0].low;
      panel_state.close=candle[0].close;
      for(int i=0;i<TF_COUNT;i++)
      {
         panel_state.fast_ma[i]=fast[i];
         panel_state.slow_ma[i]=slow[i];
      }
      buy_signal=BuyCondition(panel_state);
      sell_signal=SellCondition(panel_state);
   }

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
   if(!UseMTFTrendEntryFilter)
   {
      global_text="ENTRY FILTER OFF";
      global_color=PanelColorMuted();
   }
   else if(enabled_count==0) global_text="NO FILTER";
   else if(!all_valid) global_text="WAIT DATA";
   else if(MTFEntryBiasMode==MTF_MAJORITY)
   {
      string votes=StringFormat("B:%d S:%d F:%d",buy_votes,sell_votes,flat_votes);
      if(buy_votes>sell_votes)
      {
         global_color=PanelColorBuy();
         global_text="BUY "+votes;
      }
      else if(sell_votes>buy_votes)
      {
         global_color=PanelColorSell();
         global_text="SELL "+votes;
      }
      else
      {
         global_text="TIE "+votes;
         global_color=PanelColorWait();
      }
   }
   else if(all_buy) { global_color=PanelColorBuy(); global_text="ALL BUY"; }
   else if(all_sell) { global_color=PanelColorSell(); global_text="ALL SELL"; }
   if(UseMTFTrendEntryFilter && MTFEntryBiasMode==MTF_ALL_AGREE)
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
   if(!can_check_entry)
   {
      signal_text="WAIT DATA";
      signal_color=PanelColorWait();
   }
   else if(buy_signal && sell_signal)
   {
      signal_text="CONFLICT / NO ENTRY";
      signal_color=PanelColorWait();
   }
   else if(buy_signal) { signal_text="BUY SIGNAL"; signal_color=PanelColorBuy(); }
   else if(sell_signal) { signal_text="SELL SIGNAL"; signal_color=PanelColorSell(); }
   else signal_text="WAIT ENTRY FILTERS";

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

   PanelLabel("all_lbl",(UseMTFTrendEntryFilter && MTFEntryBiasMode==MTF_MAJORITY ?
             "MTF MAJORITY" : "MTF ALIGN"),x+17,y+270,PanelColorMuted(),10);
   PanelLabel("all_val",global_text,x+169,y+270,global_color,10);
   PanelLabel("candle_lbl","M5 CANDLE [1]",x+17,y+297,PanelColorMuted(),10);
   PanelLabel("candle_val",candle_text,x+169,y+297,candle_color,10);
   PanelLabel("signal_lbl","ENTRY SIGNAL",x+17,y+324,PanelColorMuted(),10);
   PanelLabel("signal_val",signal_text,x+169,y+324,signal_color,10);
   PanelLabel("pos_lbl","EA POSITIONS",x+17,y+351,PanelColorMuted(),10);
   int basket_buys=0,basket_sells=0;
   double basket_profit=0.0;
   ScanMyBasket(basket_buys,basket_sells,basket_profit);
   double basket_points=0.0;
   bool basket_points_valid=CalculateBasketProfitPoints(basket_points);
   bool basket_active=((basket_buys>0 && basket_sells>0 && UseRRTP) ||
                       (UseSameSideRecoveryLot && g_same_recovery_active &&
                        (basket_buys+basket_sells)>0) ||
                       (UseRecoveryLot && RecoveryLotMultiplier==0.0 &&
                        g_recovery_active && (basket_buys+basket_sells)>0));
   string positions_limit=(MaxPositionsPerSymbol==0 ? "INF" : IntegerToString(MaxPositionsPerSymbol));
   PanelLabel("pos_val",StringFormat("%d / %s  (B:%d S:%d)",
                                 basket_buys+basket_sells,positions_limit,basket_buys,basket_sells),
              x+169,y+351,PanelColorText(),10);

   PanelRectangle("divider_risk",x+13,y+378,PANEL_WIDTH-26,1,
                  PanelColorBorder(),PanelColorBorder());
   PanelLabel("risk_sl_lbl","SWING SL",x+17,y+389,PanelColorMuted(),9);
   PanelLabel("risk_sl_val",(UseSwingSL ? StringFormat("ON  M5 [%d]",SwingLookbackBars) : "OFF"),
              x+169,y+389,(UseSwingSL ? PanelColorBuy() : PanelColorMuted()),9);
   PanelLabel("risk_tp_lbl","TP MODE",x+17,y+416,PanelColorMuted(),9);
    PanelLabel("risk_tp_val",(basket_active ? "BASKET POINTS" : TPModeName()),x+169,y+416,
               (basket_active || UseRRTP ? PanelColorBuy() : PanelColorMuted()),9);

   string exit_text="--";
   color exit_color=PanelColorMuted();
   if(g_basket_closing)
   {
      exit_text="CLOSING BASKET";
      exit_color=PanelColorWait();
   }
    else if(basket_active)
   {
      if(!basket_points_valid)
      {
         exit_text="WAIT BASKET QUOTE";
         exit_color=PanelColorWait();
      }
      else
      {
         exit_text=(basket_points>=BasketProfitTarget ? "BASKET TARGET HIT" : "WAIT BASKET POINTS");
         exit_color=(basket_points>=BasketProfitTarget ? PanelColorBuy() : PanelColorWait());
      }
   }
   else if(UsingNoSLTPMode() && NoSLTPMode==TP_FIXED_POINTS)
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

   PanelRectangle("divider_basket",x+13,y+465,PANEL_WIDTH-26,1,
                  PanelColorBorder(),PanelColorBorder());
   PanelLabel("hedge_lbl","HEDGE STATUS",x+17,y+475,PanelColorMuted(),9);
   string hedge_text=((basket_buys>0 && basket_sells>0) ? "BOTH SIDES ACTIVE" :
                      (AllowBothDirections ? "READY (HEDGING)" : "OFF"));
   PanelLabel("hedge_val",hedge_text,x+169,y+475,
              (basket_active ? PanelColorWait() : PanelColorMuted()),9);
   PanelLabel("basket_pts_lbl","BASKET POINTS",x+17,y+502,PanelColorMuted(),9);
   PanelLabel("basket_pts_val",(basket_points_valid ?
              StringFormat("%.1f pts",basket_points) : "WAIT QUOTE"),
              x+169,y+502,(!basket_points_valid ? PanelColorWait() :
                             (basket_points>=0.0 ? PanelColorBuy() : PanelColorSell())),9);
   PanelLabel("basket_goal_lbl","BASKET TARGET",x+17,y+529,PanelColorMuted(),9);
    PanelLabel("basket_goal_val",(basket_active || UseRRTP ?
               StringFormat("%.1f pts",BasketProfitTarget) : "TP OFF"),
               x+169,y+529,(basket_active || UseRRTP ? PanelColorBuy() : PanelColorMuted()),9);
   PanelLabel("basket_money_lbl","FLOATING P/L",x+17,y+556,PanelColorMuted(),9);
   PanelLabel("basket_money_val",StringFormat("%.2f %s",basket_profit,AccountInfoString(ACCOUNT_CURRENCY)),
              x+169,y+556,(basket_profit>=0.0 ? PanelColorBuy() : PanelColorSell()),9);

   // Recovery is activated by the FIRST opposite-direction entry, and is
   // latched until zero EA positions remain (not merely until one side closes).
   PanelRectangle("divider_recovery",x+13,y+585,PANEL_WIDTH-26,1,
                  PanelColorBorder(),PanelColorBorder());
   string recovery_text="OFF";
   color recovery_color=PanelColorMuted();
   if(UseRecoveryLot)
   {
      if(RecoveryLotMultiplier==0.0)
         recovery_text=(g_recovery_active ? "DYNAMIC ACTIVE" : "DYNAMIC ARMED");
      else
         recovery_text=(g_recovery_active ?
                        StringFormat("ACTIVE x%.2f",RecoveryLotMultiplier) :
                        StringFormat("ARMED x%.2f",RecoveryLotMultiplier));
      recovery_color=(g_recovery_active ? PanelColorWait() : PanelColorBuy());
   }
   PanelLabel("recovery_lbl","RECOVERY LOT",x+17,y+596,PanelColorMuted(),9);
   PanelLabel("recovery_val",recovery_text,x+169,y+596,recovery_color,9);

    // Same-side basket handling never affects lot sizes. The only optional
    // multiplier displayed here belongs to the OPPOSITE-direction system.
    string next_lot=DoubleToString(LotSize,3);
    if(buy_signal != sell_signal)
    {
       bool opening_hedge=(buy_signal ? basket_sells>0 : basket_buys>0);
       double normalized=0.0;
       if(UseRecoveryLot && RecoveryLotMultiplier==0.0 &&
          (g_recovery_active || opening_hedge))
       {
          double projected=0.0;
          if(CalculateDynamicRecoveryVolume(buy_signal,normalized,projected,false))
             next_lot=DoubleToString(normalized,3)+" DYN";
          else
             next_lot="DYN: NO SAFE LOT";
       }
       else if(PrepareEntryVolume(RequestedEntryLot(opening_hedge),normalized,false,false))
          next_lot=DoubleToString(normalized,3);
       else
          next_lot="INVALID LOT";
    }
    else
    {
       double planned=RequestedEntryLot(false);
       next_lot=DoubleToString(planned,3);
    }
    PanelLabel("recovery_next_lbl","ENTRY LOT",x+17,y+623,PanelColorMuted(),9);
    PanelLabel("recovery_next_val",next_lot,x+169,y+623,PanelColorText(),9);

    string same_text="OFF";
    color same_color=PanelColorMuted();
    if(UseSameSideRecoveryLot)
    {
       same_text=(g_same_recovery_active ? "ACTIVE - BASKET" : "ARMED - NO BOOST");
       same_color=(g_same_recovery_active ? PanelColorWait() : PanelColorBuy());
    }
    PanelLabel("same_recovery_lbl","SAME-SIDE TP",x+17,y+650,PanelColorMuted(),9);
    PanelLabel("same_recovery_val",same_text,x+169,y+650,same_color,9);
    PanelLabel("same_lot_lbl",(UseRecoveryLot && RecoveryLotMultiplier==0.0 ?
               "DYNAMIC GOAL" : "SAME TP GOAL"),x+17,y+677,PanelColorMuted(),9);
    PanelLabel("same_lot_val",(UseRecoveryLot && RecoveryLotMultiplier==0.0 ?
               StringFormat("%d pts / cap %.2f",DynamicRecoveryMovePoints,MaxDynamicRecoveryLot) :
               (UseSameSideRecoveryLot ? StringFormat("%.1f pts",BasketProfitTarget) : "OFF")),
               x+169,y+677,PanelColorText(),9);

    // Entry-filter indicators (OFF means bypass, not failure).
    PanelLabel("filters_lbl","ENTRY FILTERS",x+17,y+698,PanelColorMuted(),9);
    PanelLabel("filters_val",StringFormat("MA:%s COLOR:%s WICK:%s",
               (UseMTFTrendEntryFilter ? "ON" : "OFF"),
               (UseCandleColorEntryFilter ? "ON" : "OFF"),
               (UseCandleBodyWickEntryFilter ? "ON" : "OFF")),
               x+169,y+698,PanelColorText(),9);

    datetime closed_bar=iTime(_Symbol,PERIOD_M5,SIGNAL_SHIFT);
    string closed_time=(closed_bar>0 ? TimeToString(closed_bar,TIME_DATE|TIME_MINUTES) : "--");
    PanelLabel("font_scale_lbl",StringFormat("PANEL FONT %d%%",g_panel_user_percent),
               x+17,y+725,PanelColorMuted(),9);
    PanelButton("font_minus","A-",x+269,y+719,42,24);
    PanelButton("font_plus","A+",x+320,y+719,42,24);
    PanelLabel("footer",StringFormat("Last M5 closed: %s   |   Refresh %ds",
                                      closed_time,PanelRefreshSeconds),
               x+17,y+751,PanelColorMuted(),9);
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
   RefreshRecoveryState();
   RefreshSameSideRecoveryState();
   UpdateStatusPanel();
}

void OnChartEvent(const int id,const long &lparam,
                  const double &dparam,const string &sparam)
{
   if(id==CHARTEVENT_OBJECT_CLICK && ShowStatusPanel)
   {
      if(sparam==g_panel_prefix+"font_minus" || sparam==g_panel_prefix+"font_plus")
      {
         int step=(sparam==g_panel_prefix+"font_plus" ? 10 : -10);
         g_panel_user_percent=(int)MathMax(60,MathMin(150,g_panel_user_percent+step));
         ObjectSetInteger(0,sparam,OBJPROP_STATE,false);
         UpdateStatusPanel();
         return;
      }
   }
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

   if(MTFEntryBiasMode!=MTF_ALL_AGREE && MTFEntryBiasMode!=MTF_MAJORITY)
   {
      Print("Invalid MTFEntryBiasMode; choose MTF_ALL_AGREE or MTF_MAJORITY.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(FastMAPeriod<=0 || SlowMAPeriod<=0 || LotSize<=0.0 ||
      MaxPositionsPerSymbol<0 || SlippagePoints<0 ||
      SwingLookbackBars<1 || SwingLookbackBars>OHLCV_HISTORY ||
      SwingSLBufferPoints<0 ||
      BasketProfitTarget<=0.0 || !MathIsValidNumber(BasketProfitTarget) ||
       (UseRecoveryLot && (!MathIsValidNumber(RecoveryLotMultiplier) ||
          (RecoveryLotMultiplier!=0.0 && RecoveryLotMultiplier<1.0))) ||
       (UseRecoveryLot && RecoveryLotMultiplier==0.0 &&
          (DynamicRecoveryMovePoints<=0 || MaxDynamicRecoveryLot<LotSize ||
           !MathIsValidNumber(MaxDynamicRecoveryLot) ||
           MaxDynamicMarginPct<=0.0 || MaxDynamicMarginPct>100.0 ||
           !MathIsValidNumber(MaxDynamicMarginPct))) ||
      (UseSwingSL && UseRRTP &&
       (RiskRewardRatio<=0.0 || !MathIsValidNumber(RiskRewardRatio))) ||
      (UsingNoSLTPMode() && NoSLTPMode==TP_FIXED_POINTS && FixedTPPoints<=0) ||
       PanelX<0 || PanelY<0 || PanelRefreshSeconds<1 ||
       PanelFontScalePercent<60 || PanelFontScalePercent>150)
   {
      Print("Invalid input parameters.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(AllowBothDirections &&
      (ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE)!=ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
   {
      Print("AllowBothDirections=true requires a MT5 HEDGING account. Netting accounts cannot hold BUY and SELL simultaneously.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(!UseMTFTrendEntryFilter && !UseCandleColorEntryFilter &&
      !UseCandleBodyWickEntryFilter)
   {
      Print("All entry filters are OFF: BUY and SELL would conflict. Enable at least one.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(EnabledTFCount()==0 &&
      (UseMTFTrendEntryFilter ||
       (UsingNoSLTPMode() && NoSLTPMode==TP_ALL_ACTIVE_TFS_OPPOSE)))
   {
      Print("Enable at least one TF for SMA entry filtering or ALL-TF-OPPOSITE TP mode.");
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

   if(AllowBothDirections && CloseOnOppositeSignal)
      Print("NOTE: CloseOnOppositeSignal will be ignored while hedging is allowed.");
   if(AllowBothDirections && UseRRTP)
      PrintFormat("When BOTH BUY and SELL exist, per-position TPs switch to basket target %.1f points (sum weighted by volume / configured LotSize %.2f).",
                  BasketProfitTarget,LotSize);
   if(MaxPositionsPerSymbol==0)
       Print("NOTE: MaxPositionsPerSymbol=0 means unlimited; entries are limited to one new position per M5 bar.");
   if(UseRecoveryLot && RecoveryLotMultiplier==0.0)
       Print("WARNING: dynamic recovery sizes exposure for an assumed favorable price move, not a guaranteed TP. Basket closes on actual target points and is active even when UseRRTP=false. High margin/drawdown risk.");
   if(UseSameSideRecoveryLot)
       Print("NOTE: Same-side losing entry enables combined Basket TP with NO same-side lot increase. Swing SL remains active if configured.");

   // Persistent recovery state is scoped by ACCOUNT + SYMBOL + MAGIC.
   // Never share this Symbol/MagicNumber combination across multiple EAs.
   g_recovery_key=StringFormat("SMAREC_%I64d_%s_%I64u",
                               AccountInfoInteger(ACCOUNT_LOGIN),_Symbol,MagicNumber);
   g_recovery_active=(GlobalVariableCheck(g_recovery_key) &&
                      GlobalVariableGet(g_recovery_key)>0.5);
   RefreshRecoveryState();
   if(UseRecoveryLot)
   {
      if(RecoveryLotMultiplier==0.0)
         PrintFormat("DYNAMIC RECOVERY MODE: target %.1f basket points after %d favorable points; max lot %.3f and max margin %.1f%% of free margin. State=%s.",
                     BasketProfitTarget,DynamicRecoveryMovePoints,MaxDynamicRecoveryLot,
                     MaxDynamicMarginPct,(g_recovery_active ? "ACTIVE" : "ARMED"));
      else
         PrintFormat("RECOVERY LOT: enabled, multiplier=%.2f, state=%s, base lot=%.3f.",
                     RecoveryLotMultiplier,(g_recovery_active ? "ACTIVE" : "ARMED"),LotSize);
   }

   // Versioned key: do not interpret old v2.44 saved LOT as a basket ON flag.
   g_same_recovery_key=StringFormat("SMABASK_SS2_%I64d_%s_%I64u",
                                    AccountInfoInteger(ACCOUNT_LOGIN),_Symbol,MagicNumber);
   if(UseSameSideRecoveryLot && GlobalVariableCheck(g_same_recovery_key))
      g_same_recovery_active=(GlobalVariableGet(g_same_recovery_key)>0.5);
   RefreshSameSideRecoveryState();
   if(UseSameSideRecoveryLot)
      PrintFormat("SAME-SIDE BASKET: %s, no lot multiplier, target %.1f combined points",
                  (g_same_recovery_active ? "ACTIVE" : "ARMED"),BasketProfitTarget);

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
   g_panel_user_percent=PanelFontScalePercent;
   if(ShowStatusPanel)
   {
      UpdateStatusPanel();
      if(!EventSetTimer(PanelRefreshSeconds))
         PrintFormat("Panel timer setup failed. Error=%d",GetLastError());
   }

   PrintFormat("MTF SMA EA v2.46 | TF=M5 | Fast=%d Slow=%d | ActiveTF=%d/5 | MTF Bias=%s | Entry MA:%s COLOR:%s WICK:%s | SwingSL=%s Lookback=%d | TP=%s | Trading=%s",
               FastMAPeriod,SlowMAPeriod,EnabledTFCount(),
               (MTFEntryBiasMode==MTF_MAJORITY ? "MAJORITY" : "ALL AGREE"),
               (UseMTFTrendEntryFilter ? "ON" : "OFF"),
               (UseCandleColorEntryFilter ? "ON" : "OFF"),
               (UseCandleBodyWickEntryFilter ? "ON" : "OFF"),
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
   // Synchronize the recovery latch even if entry trading is disabled.
   // The state resets ONLY after the final EA position has been closed.
   RefreshRecoveryState();
   RefreshSameSideRecoveryState();

   // Basket TP and physical TP reconciliation always run on every market
   // tick: TradeOnNewBarOnly only limits ENTRY / indicator-based exits.
   if(EnableTrading)
   {
      if(g_basket_closing)
      {
         CloseMyBasket();
         return;
      }

      int buys=0,sells=0;
      double floating=0.0;
      ScanMyBasket(buys,sells,floating);
      bool hedged=(buys>0 && sells>0);
      // Same-side basket TP applies even with only BUYs or only SELLs;
      // it is independent of UseRRTP and never changes volume.
      bool same_basket=(UseSameSideRecoveryLot && g_same_recovery_active && (buys+sells)>0);
      bool dynamic_basket=(UseRecoveryLot && RecoveryLotMultiplier==0.0 &&
                           g_recovery_active && (buys+sells)>0);
      bool basket_mode=((hedged && UseRRTP) || same_basket || dynamic_basket);

      if(basket_mode)
      {
         // Remove per-position TPs. Existing Swing SL remains unchanged.
         // We still evaluate basket targets if an individual TP removal fails.
         SynchronizeTakeProfits(true);
         double basket_points=0.0;
         if(CalculateBasketProfitPoints(basket_points) &&
            basket_points>=BasketProfitTarget)
         {
            g_basket_closing=true;
            g_last_indicator_exit_bar=iTime(_Symbol,PERIOD_M5,0);
            PrintFormat("BASKET TARGET reached: %.1f >= %.1f POINTS. Floating P/L=%.2f %s. Closing ALL positions.",
                        basket_points,BasketProfitTarget,floating,AccountInfoString(ACCOUNT_CURRENCY));
            CloseMyBasket();
            UpdateStatusPanel();
            return;
         }
      }
      else if((buys+sells)>0)
      {
         // Restore removed broker-side TPs only when no basket is active.
         SynchronizeTakeProfits(false);
      }
   }

   bool new_bar=IsNewBar();
   if(TradeOnNewBarOnly && !new_bar)
      return;

   // No M5 indicator signal exit should fire while the basket is active.
   bool hedge_active=HasMyHedge();
   IndicatorState s;
   if(!ReadIndicatorState(s))
   {
      // Keep the original fail-safe: M5-cross exits still work even if
      // some higher-timeframe history hasn't downloaded. Not in a hedge.
      if(EnableTrading && !hedge_active &&
         !(UseSameSideRecoveryLot && g_same_recovery_active) &&
         !(UseRecoveryLot && RecoveryLotMultiplier==0.0 && g_recovery_active) &&
         UsingNoSLTPMode() &&
         NoSLTPMode==TP_M5_MA_CROSS)
      {
         bool cross_up=false,cross_down=false;
         if(ReadM5Cross(cross_up,cross_down))
         {
            int closed=0;
            if(cross_down) closed+=ClosePositionsByType(POSITION_TYPE_BUY);
            if(cross_up) closed+=ClosePositionsByType(POSITION_TYPE_SELL);
            if(closed>0)
               g_last_indicator_exit_bar=iTime(_Symbol,PERIOD_M5,0);
         }
      }
      return;
   }

   bool buy_signal=BuyCondition(s);
   bool sell_signal=SellCondition(s);
   bool close_buy=false,close_sell=false;
   CalculateExitSignals(s,close_buy,close_sell);

   UpdateStatusPanel();
   if(PrintSignalLog)
   {
      PrintFormat("M5 O=%.*f C=%.*f | enabled=%d | BUY=%s SELL=%s | Hedge=%s",
                  _Digits,s.open,_Digits,s.close,EnabledTFCount(),
                  (buy_signal ? "YES" : "NO"),(sell_signal ? "YES" : "NO"),
                  (hedge_active ? "YES" : "NO"));
   }
   if(!EnableTrading)
      return;

   // Per-position exit rules are suspended whenever BOTH sides are open.
   // With hedging enabled, CloseOnOppositeSignal is bypassed so that
   // a new opposite entry can coexist with the older trade.
   if(hedge_active || (UseSameSideRecoveryLot && g_same_recovery_active) ||
      (UseRecoveryLot && RecoveryLotMultiplier==0.0 && g_recovery_active))
   {
      // Basket TP exclusively controls exits during active recovery.
      // Existing broker-side Swing SL orders remain in effect.
      close_buy=false;
      close_sell=false;
   }
   else if(AllowBothDirections)
   {
      if(!UsingNoSLTPMode())
      {
         close_buy=false;
         close_sell=false;
      }
      // Entry opposite to a held trade has PRIORITY over an MA exit
      // occurring in the same M5 bar; this allows the hedge to form.
      if(buy_signal && CountMyPositionsByType(POSITION_TYPE_SELL)>0)
         close_sell=false;
      if(sell_signal && CountMyPositionsByType(POSITION_TYPE_BUY)>0)
         close_buy=false;
   }

   // Same-side basket entry has priority over per-position MA exits even
   // if AllowBothDirections is OFF; this mode does not require hedging.
   if(UseSameSideRecoveryLot && !g_same_recovery_active)
   {
      if(buy_signal && HasLosingSameSidePosition(true))
         close_buy=false;
      if(sell_signal && HasLosingSameSidePosition(false))
         close_sell=false;
   }

   int exited=0;
   if(close_buy)  exited+=ClosePositionsByType(POSITION_TYPE_BUY);
   if(close_sell) exited+=ClosePositionsByType(POSITION_TYPE_SELL);
   if(UsingNoSLTPMode() && NoSLTPMode!=TP_FIXED_POINTS && exited>0)
      g_last_indicator_exit_bar=iTime(_Symbol,PERIOD_M5,0);

   datetime current_bar=iTime(_Symbol,PERIOD_M5,0);
   if(current_bar==0 || current_bar==g_last_indicator_exit_bar)
      return;
   if(current_bar==g_last_entry_bar) // Safety with unlimited positions
      return;
   if(MaxPositionsPerSymbol>0 && CountMyPositions()>=MaxPositionsPerSymbol)
      return;
   if(buy_signal==sell_signal)
      return;

   bool is_buy=buy_signal;
   ENUM_POSITION_TYPE other_type=(is_buy ? POSITION_TYPE_SELL : POSITION_TYPE_BUY);
   bool opening_hedge=(CountMyPositionsByType(other_type)>0);
   if(opening_hedge && !AllowBothDirections)
      return;

   // SAME-SIDE: a fresh entry signal with existing same-side floating loss
   // enables basket TP, but does NOT change the entry lot. Opposite-side
   // recovery lot (fixed multiplier or dynamic size) is controlled by its own input.
   bool same_side_trigger=(UseSameSideRecoveryLot &&
                           HasLosingSameSidePosition(is_buy));
   bool use_recovery_entry=(UseRecoveryLot && (g_recovery_active || opening_hedge));
   bool use_dynamic_entry=(use_recovery_entry && RecoveryLotMultiplier==0.0);
   double requested_lot=RequestedEntryLot(opening_hedge);
   double entry_lot=0.0;
   if(use_dynamic_entry)
   {
      double predicted=0.0;
      if(!CalculateDynamicRecoveryVolume(is_buy,entry_lot,predicted,true))
         return; // No fallback to fixed lot: must honor the projected target and cap.
   }
   else if(!PrepareEntryVolume(requested_lot,entry_lot))
      return;

   bool currently_in_basket=((HasMyHedge() && UseRRTP) ||
                             (UseSameSideRecoveryLot && g_same_recovery_active) ||
                             (UseRecoveryLot && RecoveryLotMultiplier==0.0 && g_recovery_active));
   bool entry_needs_basket=((opening_hedge && UseRRTP) ||
                            (UseSameSideRecoveryLot &&
                             (same_side_trigger || g_same_recovery_active)) ||
                            use_dynamic_entry);
   bool newly_switching_to_basket=(entry_needs_basket && !currently_in_basket);

   // Remove every existing broker TP BEFORE switching to basket management.
   // If it fails, do not enter recovery while any individual TP might fire.
   if(newly_switching_to_basket && !SynchronizeTakeProfits(true))
   {
      Print("Basket entry postponed because some individual TPs could not be removed.");
      SynchronizeTakeProfits(false);
      return;
   }

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick))
   {
      if(newly_switching_to_basket) SynchronizeTakeProfits(false);
      return;
   }
   double sl=0.0,tp=0.0;
   if(!PrepareOrderStops(s,is_buy,tick,sl,tp,entry_needs_basket))
   {
      if(newly_switching_to_basket) SynchronizeTakeProfits(false);
      return;
   }

   bool sent=(is_buy ? trade.Buy(entry_lot,_Symbol,0.0,sl,tp,"MTF SMA BUY") :
                       trade.Sell(entry_lot,_Symbol,0.0,sl,tp,"MTF SMA SELL"));
   uint code=trade.ResultRetcode();
   if(!sent || (code!=TRADE_RETCODE_DONE && code!=TRADE_RETCODE_DONE_PARTIAL &&
                 code!=TRADE_RETCODE_PLACED))
   {
      PrintFormat("%s failed. retcode=%u %s",(is_buy ? "BUY" : "SELL"),
                  code,trade.ResultRetcodeDescription());
      if(newly_switching_to_basket) SynchronizeTakeProfits(false);
      return;
   }

   g_last_entry_bar=current_bar;
   if(use_recovery_entry)
      SetRecoveryActive(); // Commit latch only AFTER a confirmed successful order.
   if(same_side_trigger)
      LatchSameSideBasket();
   if(entry_needs_basket)
      SynchronizeTakeProfits(true);
   if(PrintSignalLog)
      PrintFormat("Opened %s lot=%.5f opposite_recovery=%s same_side_basket=%s, position limit=%s, basket=%s",
                  (is_buy ? "BUY" : "SELL"),entry_lot,
                  (UseRecoveryLot ? (g_recovery_active ? "ACTIVE" : "ARMED") : "OFF"),
                  (UseSameSideRecoveryLot ? (g_same_recovery_active ? "ACTIVE" : "ARMED") : "OFF"),
                  (MaxPositionsPerSymbol==0 ? "UNLIMITED" : IntegerToString(MaxPositionsPerSymbol)),
                  (entry_needs_basket ? "ON" : "OFF"));
   UpdateStatusPanel();
}
//+------------------------------------------------------------------+
