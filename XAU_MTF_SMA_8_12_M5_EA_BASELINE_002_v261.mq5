//+------------------------------------------------------------------+
//| XAU_MTF_SMA_8_12_M5_EA_BASELINE_002.mq5                          |
//| M5 SMA(8,12) multi-timeframe entry, basket and recovery management |
//| Responsive status UI: grouped cards, maximum two columns.          |
//+------------------------------------------------------------------+
#property strict
#property version   "2.61"
#property description "MTF SMA(8/12) M5 Expert Advisor with majority/all-agree bias."
#property description "Entry: MTF and Slow-SMA gates; Color requires Body[1] < Body[2]."
#property description "Swing SL, independent hedged-basket switch, RR/MA exits and recovery."
#property description "Responsive 1/2-column panel with realized today/yesterday/month P/L."

#include <Trade/Trade.mqh>
CTrade trade;

#define TF_COUNT      5
#define OHLCV_HISTORY 20
// MTF SMA bias and entry triggers read fully closed candles at shift [1].
#define SIGNAL_SHIFT  1

//====================================================================
// USER INPUTS - organized by trading workflow
//====================================================================
input group "01 | Trading and Order Limits"
// Master switch for opening positions and processing live exits.
input bool EnableTrading = true;
// Starting position volume in lots.
input double LotSize = 0.01;
// Isolates this EA's orders from other strategies.
input ulong MagicNumber = 26092301;
// Evaluate indicator entries on a newly opened M5 bar.
input bool TradeOnNewBarOnly = true;
// Zero allows unlimited positions; still at most one entry per M5 bar.
input int MaxPositionsPerSymbol = 0;
// Requires a hedging account to hold BUY and SELL simultaneously.
input bool AllowBothDirections = true;
// Maximum requested order deviation in broker points.
input int SlippagePoints = 30;

input group "02 | SMA Indicator Settings"
// Period of the faster moving average.
input int FastMAPeriod = 8;
// Period of the slower moving average.
input int SlowMAPeriod = 12;
// SMA is the default averaging method.
input ENUM_MA_METHOD MainMAMethod = MODE_SMA;
// Input price used by both moving averages.
input ENUM_APPLIED_PRICE MainMAPrice = PRICE_CLOSE;

input group "03 | Timeframes Used for SMA Bias"
// Only enabled timeframes cast votes for MTF trend selection.
input bool UseTF_M5 = true;
input bool UseTF_M15 = true;
input bool UseTF_M30 = true;
input bool UseTF_H1 = true;
input bool UseTF_H4 = true;

// Chooses whether enabled timeframe trends must all match, or just win a vote.
enum ENUM_MTF_ENTRY_BIAS_MODE
{
   // Every enabled timeframe must have the requested SMA direction.
   MTF_ALL_AGREE = 0,
   // More enabled timeframe votes for BUY/SELL sets the entry direction.
   MTF_MAJORITY = 1
};

input group "04.1 | Entry - MTF Trend Gate"
// Master gate: enabled SMA trend filters must support the requested direction.
input bool UseMTFTrendEntryFilter = true;
// A tie in majority mode produces no entry bias.
input ENUM_MTF_ENTRY_BIAS_MODE MTFEntryBiasMode = MTF_MAJORITY;

input group "04.2 | Entry - Slow SMA Distance Gate"
// Global ENTRY-only distance gate; applies to all four alternative OR triggers.
input bool UseSlowSMADistanceEntryFilter = true;
// Distance can be capped by M5 ATR(14) or fixed broker points.
enum ENUM_SLOW_SMA_DISTANCE_MODE
{
   SLOW_SMA_DISTANCE_ATR = 0,
   SLOW_SMA_DISTANCE_POINTS = 1
};
// Default: measure price-to-Slow-SMA distance against M5 ATR(14) [1].
input ENUM_SLOW_SMA_DISTANCE_MODE SlowSMADistanceMode = SLOW_SMA_DISTANCE_ATR;
// ATR calculated on closed M5 bar [1].
input int SlowSMAATRPeriod = 14;
// Maximum allowed absolute distance to Slow SMA = ATR * multiplier.
input double SlowSMAMaxDistanceATR = 1.0;
// Alternative maximum when selecting fixed POINTS (price units = points * _Point).
input int SlowSMAMaxDistancePoints = 1500;

input group "04.3 | Entry - OR Candle Triggers"
// OR #1: red closed M5 candle permits BUY; green permits SELL.
input bool UseCandleColorEntryFilter = true;

// Built into Candle Color: Buy uses red [1], Sell uses green [1].
// In both cases the closed candle BODY[1] must be strictly smaller
// than BODY[2], using MathAbs(Close-Open). No extra switches or ATR.

// OR #2: body/upper/lower wick pattern on closed M5 candle [1].
input bool UseCandleBodyWickEntryFilter = false;

input group "04.4 | Entry - OR SMA Cross"
// OR #3: fresh, strict SMA cross from M5 candle [2] to candle [1].
input bool UseSMACrossEntryFilter = false;

input group "04.5 | Entry - OR Momentum Breakout"
// OR #4: strong directional M5 candle breaks a prior high/low.
// OFF by default, so it does not change existing Entry signals unless enabled.
input bool UseMomentumBreakoutEntryFilter = false;
// The signal candle body must be at least this fraction of the entire High-Low.
input double MomentumMinBodyRatio = 0.60;
// Break the prior N completed M5 candle highs/lows (signal bar [1] excluded).
input int MomentumBreakoutLookbackBars = 3;
// Entry = (optional MTF bias) AND (optional Slow SMA distance gate)
//         AND (COLOR OR BODY/WICK OR SMA CROSS OR MOMENTUM).

input group "05 | Swing Stop Loss"
// Attach a swing-based Stop Loss to each new trade.
input bool UseSwingSL = true;
// One means previous closed M5 bar [1]; N means bars [1..N].
input int SwingLookbackBars = 1;
// Optional extra broker points beyond swing High/Low.
input int SwingSLBufferPoints = 0;

// Exit mode is selected only when Swing SL is disabled and TP is enabled.
enum ENUM_NO_SL_TP_MODE
{
   // Broker-side price TP at a fixed point distance.
   TP_FIXED_POINTS = 1,
   // EA-managed exit on opposite M5 SMA crossing [2] -> [1].
   TP_M5_MA_CROSS = 2,
   // EA-managed exit when all enabled SMA timeframes reverse.
   TP_ALL_ACTIVE_TFS_OPPOSE = 3
};

input group "06 | Take Profit and Exit Behavior"
// Existing TP master switch; name retained for compatibility with old .set files.
input bool UseRRTP = true;
// RR multiple is applied only when the Swing SL mode is active.
input double RiskRewardRatio = 2.0;
// Use points, SMA cross, or all opposite timeframes when no Swing SL.
input ENUM_NO_SL_TP_MODE NoSLTPMode = TP_FIXED_POINTS;
// Physical TP distance, measured in broker symbol points.
input int FixedTPPoints = 500;
// Bypass opposite-signal close when hedging is enabled.
input bool CloseOnOppositeSignal = true;

input group "07 | Combined Basket Target"
// Enable basket TP automatically when BUY and SELL coexist.
// If false, allow hedging with individual TP/indicator exits unless an independent recovery basket activates.
input bool UseHedgeBasketTP = false;
// Sum of position point results, weighted by their lot size divided by LotSize.
// This is not USD profit, and excludes commissions, fees and swaps.
input double BasketProfitTarget = 500.0;

input group "08 | Opposite-Side Recovery"
// Enables the existing recovery multiplier or dynamic lot sizing.
input bool UseRecoveryLot = true;
// Zero = dynamic lot; a value >=1 applies a fixed, one-time multiplier.
input double RecoveryLotMultiplier = 2.0;
// Hypothetical favorable price move for dynamic lot sizing (broker points).
input int DynamicRecoveryMovePoints = 100;
// Hard upper bound; reject oversized dynamic recovery orders.
input double MaxDynamicRecoveryLot = 0.10;
// Maximum projected order margin as a percent of free margin.
input double MaxDynamicMarginPct = 30.0;

input group "09 | Same-Side Basket Exit"
// Despite legacy naming, this feature NEVER multiplies same-side lots.
// An additional entry into a losing side activates basket-level TP.
input bool UseSameSideRecoveryLot = true;

input group "10 | Indicator and Diagnostic Display"
// Add the two M5 SMA lines to the price chart.
input bool ShowIndicatorsOnChart = false;
// Write detailed trading decisions to the Experts log.
input bool PrintSignalLog = false;

input group "11 | Responsive Status Panel"
// Enable the on-chart information panel.
input bool ShowStatusPanel = true;
// Anchor corner for the panel's outer rectangle.
input ENUM_BASE_CORNER PanelCorner = CORNER_LEFT_UPPER;
// Horizontal offset in chart pixels.
input int PanelX = 16;
// Vertical offset in chart pixels.
input int PanelY = 24;
// Seconds between display-only updates.
input int PanelRefreshSeconds = 2;
// Font scale is configured in Inputs only; there are no on-chart font buttons.
input int PanelFontScalePercent = 100;
// Shrink the entire panel when there is insufficient chart space.
input bool PanelAutoFitToChart = true;
// Maximum horizontal column count: 1 or 2; narrow charts show pages.
input int PanelMaxColumns = 2;

//====================================================================
// INDICATOR HANDLES: M5, M15, M30, H1, H4
//====================================================================
ENUM_TIMEFRAMES g_timeframes[TF_COUNT] =
{
   PERIOD_M5, PERIOD_M15, PERIOD_M30, PERIOD_H1, PERIOD_H4
};

int g_fast_ma_handles[TF_COUNT];
int g_slow_ma_handles[TF_COUNT];
// ATR handle is needed only in the selectable ATR distance mode.
int g_slow_distance_atr_handle = INVALID_HANDLE;
datetime g_last_bar_time = 0;
// Prevent same-bar reentry after basket/indicator exits.
datetime g_last_indicator_exit_bar = 0;
// At most one NEW position per M5 candle.
datetime g_last_entry_bar          = 0;
// Retry failed basket closes until all are closed.
bool     g_basket_closing          = false;
// Latched after first opposite entry until all EA positions are flat.
bool     g_recovery_active         = false;
// MT5 terminal GlobalVariable; survives EA/terminal restart.
string   g_recovery_key            = "";
// Same-side basket TP latched until all EA positions are flat.
bool     g_same_recovery_active = false;
// Persisted boolean in terminal Global Variables.
string   g_same_recovery_key    = "";
string g_panel_prefix = "";
double g_panel_scale = 1.0;
// Current scale copied from the PanelFontScalePercent input on initialization.
int g_panel_user_percent = 100;
int g_panel_left = 0;
int g_panel_top = 0;

// Unscaled card geometry, shared by wide and narrow chart presentations.
#define PANEL_COL_WIDTH 390
#define PANEL_GAP 12
#define PANEL_DESIGN_HEIGHT 790
// Computed width, height and layout for the current chart dimensions.
int g_panel_design_width = 414;
int g_panel_design_height = PANEL_DESIGN_HEIGHT;
int g_panel_columns = 1;
int g_panel_last_columns = 0;
int g_panel_page = 0;

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
// Function: CopyOne - Read and validate one indicator buffer value, logging data failures.
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
// Function: TryReadMA - Read an SMA sample without log spam while history is still loading.
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
// Function: ReadM5Cross - Detect a completed M5 MA cross for indicator-based exits.
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

// Independent ENTRY cross filter, deliberately STRICT (< and >), unlike the
// existing EXIT MA cross which accepts equality on the previous bar.
// BUY: SMA8[1] > SMA12[1] AND SMA12[2] > SMA8[2].
// SELL: SMA8[1] < SMA12[1] AND SMA8[2] > SMA12[2].
// M5 indexes [1] and [2] are both CLOSED candles. The new crossover is only
// true for the M5 bar right after the crossover, not for an ongoing trend.
// Function: ReadM5EntryCross - Detect a strict closed-candle M5 SMA cross for new entries.
bool ReadM5EntryCross(bool &buy_cross, bool &sell_cross)
{
   buy_cross=false;
   sell_cross=false;
   double f1=0.0,s1=0.0,f2=0.0,s2=0.0;
   if(!TryReadMA(g_fast_ma_handles[0],1,f1) ||
      !TryReadMA(g_slow_ma_handles[0],1,s1) ||
      !TryReadMA(g_fast_ma_handles[0],2,f2) ||
      !TryReadMA(g_slow_ma_handles[0],2,s2))
      return false;

   buy_cross  = (f1>s1 && s2>f2);
   sell_cross = (f1<s1 && f2>s2);
   return true;
}

// Function: UsingNoSLTPMode - Check whether the three selectable no-SL take-profit modes apply.
bool UsingNoSLTPMode()
{
   return (!UseSwingSL && UseRRTP);
}

// Function: TPModeName - Convert active take-profit settings into a short panel label.
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
// Function: ReadIndicatorState - Populate M5 OHLCV and selected SMA values from completed bars.
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
// Function: IsTFEnabled - Check whether the selected timeframe can vote for MTF bias.
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

// Function: EnabledTFCount - Count the timeframe filters that are currently enabled.
int EnabledTFCount()
{
   int count=0;
   for(int i=0; i<TF_COUNT; i++)
      if(IsTFEnabled(i)) count++;
   return count;
}

// TF selection remains separate from the master ENTRY switch.
// Also used by TP mode 3; the TP logic does NOT consult the entry switch.
// Function: AllActiveTFsAgree - Test unanimous enabled-timeframe agreement on a direction.
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
// Function: CountMTFEntryVotes - Count bullish, bearish and neutral votes across enabled timeframes.
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
// Function: MTFEntryBiasDirection - Return bullish/bearish bias using majority or unanimity.
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
   // Ties do NOT open trades (also no trade for all-flat).
   return 0;
}

// Function: PassEntryTrendFilter - Apply the optional SMA bias gate before evaluating entry triggers.
bool PassEntryTrendFilter(const IndicatorState &s,const bool want_buy)
{
   if(!UseMTFTrendEntryFilter) return true;
   int bias=MTFEntryBiasDirection(s);
   return (want_buy ? bias==1 : bias==-1);
}

// Function: ReadSlowSMADistance - Calculate proposed BUY Ask / SELL Bid
// distance to the CLOSED M5 Slow SMA [1]. In ATR mode, the ATR is likewise
// taken from closed bar [1]. Returns false on missing indicator or quote data.
// Prices are compared in absolute symbol price units, not account currency.
bool ReadSlowSMADistance(const bool want_buy,
                         double &distance,double &maximum,double &atr_value)
{
   distance=0.0;
   maximum=0.0;
   atr_value=0.0;
   double slow=0.0;
   if(!TryReadMA(g_slow_ma_handles[0],SIGNAL_SHIFT,slow))
      return false;

   MqlTick quote;
   if(!SymbolInfoTick(_Symbol,quote) || quote.ask<=0.0 || quote.bid<=0.0)
      return false;
   double entry_price=(want_buy ? quote.ask : quote.bid);
   distance=MathAbs(entry_price-slow);

   if(SlowSMADistanceMode==SLOW_SMA_DISTANCE_ATR)
   {
      if(g_slow_distance_atr_handle==INVALID_HANDLE ||
         BarsCalculated(g_slow_distance_atr_handle)<SlowSMAATRPeriod+SIGNAL_SHIFT)
         return false;
      double atr_buffer[1];
      if(CopyBuffer(g_slow_distance_atr_handle,0,SIGNAL_SHIFT,1,atr_buffer)!=1 ||
         !MathIsValidNumber(atr_buffer[0]) || atr_buffer[0]<=0.0)
         return false;
      atr_value=atr_buffer[0];
      maximum=atr_value*SlowSMAMaxDistanceATR;
   }
   else
      maximum=SlowSMAMaxDistancePoints*_Point;

   return (MathIsValidNumber(distance) && MathIsValidNumber(maximum) && maximum>0.0);
}

// Function: PassEntrySlowSMADistanceFilter - Reject overextended entry prices
// across all enabled OR triggers. Never blocks indicator-based exits.
bool PassEntrySlowSMADistanceFilter(const bool want_buy)
{
   if(!UseSlowSMADistanceEntryFilter)
      return true;
   double distance=0.0,maximum=0.0,atr=0.0;
   if(!ReadSlowSMADistance(want_buy,distance,maximum,atr))
      return false;
   return (distance<=maximum+_Point*1e-6);
}

// TRIGGER 1: M5 pullback color on closed candle [1].
// BUY requires a RED candle; SELL requires a GREEN candle.
// For ENTRIES only, require strictly smaller candle body than closed [2]:
//    MathAbs(Close[1]-Open[1]) < MathAbs(Close[2]-Open[2]).
// For opposite-signal EXIT checks, check_body_quality=false preserves
// the original color-only exit condition.
// Function: PassEntryCandleColorFilter - Check directional color and body contraction.
bool PassEntryCandleColorFilter(const IndicatorState &s,const bool want_buy,
                                const bool check_body_quality=true)
{
   bool correct_color=(want_buy ? (s.close<s.open) : (s.close>s.open));
   if(!correct_color)
      return false;

   if(!check_body_quality)
      return true;

   double body1=MathAbs(s.close-s.open);
   if(!MathIsValidNumber(body1) || body1<=0.0)
      return false;

   // Shift 2 is the completed candle immediately before signal candle [1].
   MqlRates previous[1];
   if(CopyRates(_Symbol,PERIOD_M5,2,1,previous)!=1)
      return false;

   double body2=MathAbs(previous[0].close-previous[0].open);
   if(!MathIsValidNumber(body2) || body2<=0.0)
      return false;

   return (body1<body2);
}

// FILTER 3: independently selectable body/wick shape on closed M5 [1].
// Body:  abs(Close-Open)
// Upper: High-max(Open,Close)    (works on both red and green candles)
// Lower: min(Open,Close)-Low     (works on both red and green candles)
// This normalization is necessary: on a RED BUY candle High-Close
// includes the entire candle body, so Body > High-Close is impossible.
// Function: CandleBodyWickPattern - Measure candle body and upper/lower wicks for BUY or SELL.
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
   // Doji cannot confirm either pattern.
   if(body<=0.0) return false;
   if(want_buy)
      return (body>upper && upper<lower);
   // Mirror of BUY.
   return (body>lower && lower<upper);
}

// Function: PassEntryBodyWickFilter - Evaluate the M5 body-and-wick OR trigger.
bool PassEntryBodyWickFilter(const IndicatorState &s,const bool want_buy)
{
   return CandleBodyWickPattern(s.open,s.high,s.low,s.close,want_buy);
}

// TRIGGER 3: strict M5 SMA crossover on closed bars [2] -> [1].
// The M5 MA handles exist even when the M5 trend voting filter is disabled.
// Function: PassEntrySMACrossFilter - Evaluate the M5 SMA crossing OR trigger.
bool PassEntrySMACrossFilter(const bool want_buy)
{
   bool buy_cross=false,sell_cross=false;
   if(!ReadM5EntryCross(buy_cross,sell_cross)) return false;
   return (want_buy ? buy_cross : sell_cross);
}

// Function: ReadMomentumBreakout - Detect a strong M5 trend-continuation candle.
// The signal bar is the latest completed bar [1]. Earlier closed bars [2..N+1]
// define the breakout level. BUY: green body, body/range >= minimum, close
// above the highest prior high, and M5 Fast MA[1] > Slow MA[1].
// SELL uses the mirrored conditions. This reads M5 SMA independently of the
// UseTF_M5 MTF voting switch, so turning off the M5 vote will not disable
// this optional momentum signal. False means missing data or invalid input.
bool ReadMomentumBreakout(bool &buy_breakout,bool &sell_breakout)
{
   buy_breakout=false;
   sell_breakout=false;

   const int count=MomentumBreakoutLookbackBars+1;
   if(count<2 || count>OHLCV_HISTORY)
      return false;

   MqlRates rates[];
   if(ArrayResize(rates,count)!=count)
      return false;
   // CopyRates copies from oldest to newest physical array element.
   // The last element is the signal bar [1]; earlier elements are [2..N+1].
   if(CopyRates(_Symbol,PERIOD_M5,SIGNAL_SHIFT,count,rates)!=count)
      return false;

   MqlRates signal=rates[count-1];
   double range=signal.high-signal.low;
   double body=MathAbs(signal.close-signal.open);
   if(!MathIsValidNumber(range) || !MathIsValidNumber(body) || range<=0.0)
      return false;

   double highest=rates[0].high;
   double lowest=rates[0].low;
   for(int i=1;i<count-1;i++)
   {
      highest=MathMax(highest,rates[i].high);
      lowest=MathMin(lowest,rates[i].low);
   }

   if(body/range+1e-12<MomentumMinBodyRatio)
      return true; // Valid data, but no breakout-strength signal.

   double fast=0.0,slow=0.0;
   if(!TryReadMA(g_fast_ma_handles[0],SIGNAL_SHIFT,fast) ||
      !TryReadMA(g_slow_ma_handles[0],SIGNAL_SHIFT,slow))
      return false;

   buy_breakout=(signal.close>signal.open &&
                 signal.close>highest && fast>slow);
   sell_breakout=(signal.close<signal.open &&
                  signal.close<lowest && fast<slow);
   return true;
}

// Function: PassEntryMomentumBreakoutFilter - Return the matching momentum OR trigger.
// It is checked only if its independent UseMomentumBreakoutEntryFilter switch is ON.
bool PassEntryMomentumBreakoutFilter(const bool want_buy)
{
   bool buy_breakout=false,sell_breakout=false;
   if(!ReadMomentumBreakout(buy_breakout,sell_breakout))
      return false;
   return (want_buy ? buy_breakout : sell_breakout);
}

// NEW ENTRY FORMULA:
// (optional MTF gate) AND (optional Slow SMA distance gate) AND
// (COLOR OR WICK OR SMA CROSS OR MOMENTUM).
// Exits call with check_entry_gates=false to preserve prior exit signals:
// distance AND new candle-body checks apply only when opening a position.
// Function: EntryCondition - Apply ENTRY gates before the OR triggers.
bool EntryCondition(const IndicatorState &s,const bool want_buy,
                    const bool check_entry_gates=true)
{
   if(!PassEntryTrendFilter(s,want_buy))
      return false;
   if(check_entry_gates && !PassEntrySlowSMADistanceFilter(want_buy))
      return false;

   if(!UseCandleColorEntryFilter && !UseCandleBodyWickEntryFilter &&
      !UseSMACrossEntryFilter && !UseMomentumBreakoutEntryFilter)
      return false;

   return ((UseCandleColorEntryFilter &&
             PassEntryCandleColorFilter(s,want_buy,check_entry_gates)) ||
           (UseCandleBodyWickEntryFilter && PassEntryBodyWickFilter(s,want_buy)) ||
           (UseSMACrossEntryFilter && PassEntrySMACrossFilter(want_buy)) ||
           (UseMomentumBreakoutEntryFilter && PassEntryMomentumBreakoutFilter(want_buy)));
}

// Function: BuyCondition - Return whether all requirements for a BUY entry are satisfied.
bool BuyCondition(const IndicatorState &s)
{
   return EntryCondition(s,true);
}

// Function: SellCondition - Return whether all requirements for a SELL entry are satisfied.
bool SellCondition(const IndicatorState &s)
{
   return EntryCondition(s,false);
}

// CloseOnOppositeSignal retains its old meaning for other SL/TP combinations.
// When SL=OFF & TP=ON, ONLY the selected TP mode closes positions.
// Function: CalculateExitSignals - Determine indicator-driven exits by TP mode and active bias.
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
               // Missing data: do not trigger an unconfirmed cross.
               return;
            // BUY exits on bearish M5 fast/slow crossing.
            close_buy=cross_down;
            // SELL exits on bullish M5 fast/slow crossing.
            close_sell=cross_up;
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

   // Distance filter is ENTRY-only: do not suppress opposite-signal exits.
   close_buy=CloseOnOppositeSignal && EntryCondition(s,false,false);
   close_sell=CloseOnOppositeSignal && EntryCondition(s,true,false);
}

//====================================================================
// SWING SL / OPTIONAL RR TP
//====================================================================
// Swing reference always uses FINISHED M5 candles. Lookback=1 means:
// BUY reference = Low of M5 [1], SELL reference = High of M5 [1].
// Lookback=N means lowest/highest among M5 [1] through [N].
// Used only when Swing SL is ON. With Swing SL OFF, the selected
// fixed-points/MA-cross/MTF-reversal TP method is used instead.
// Function: SwingReferencePrice - Compute entry swing High/Low, including configured point buffer.
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
// Function: NormalizeTickPrice - Snap price outward to the symbol tradable tick size.
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
// Function: PrepareOrderStops - Validate and calculate broker-side SL and TP for an entry.
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
// Function: CountMyPositions - Count open positions matching the EA symbol and Magic Number.
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

// Function: CountMyPositionsByType - Count this EA's BUY or SELL positions.
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

// Function: ClosePositionsByType - Close this EA's positions on one specified side.
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
// Function: ScanMyBasket - Accumulate BUY/SELL counts and total floating monetary P/L.
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

// Function: HasMyHedge - Check whether the EA currently holds both directions.
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
// Function: SetRecoveryActive - Latch opposite-side recovery until every EA position closes.
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

// Function: RefreshRecoveryState - Restore or reset the persistent opposite-side recovery state.
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
// Function: HasLosingSameSidePosition - Find whether the signaled direction has an open losing trade.
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

// Function: RefreshSameSideRecoveryState - Restore or reset persistent same-side basket mode.
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

// Function: LatchSameSideBasket - Activate basket exits for same-side losing entries without lot boosting.
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
// Function: RequestedEntryLot - Determine the requested volume for a normal/fixed recovery order.
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
// Function: PrepareEntryVolume - Normalize lots to broker size/step limits; optionally round upward.
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
// Function: CalculateBasketProfitPoints - Sum bid/ask-based broker points weighted by position volume.
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
// Function: CalculateDynamicRecoveryVolume - Project a safe capped entry lot for the configured favorable move.
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
// Function: PhysicalTPForSelectedPosition - Find the physical TP price for a selected one-sided position.
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
// Function: SynchronizeTakeProfits - Remove broker TPs in basket mode or restore them outside it.
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
// Function: CloseMyBasket - Close all positions for this EA, retrying failed orders later.
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
// Function: IsNewBar - Detect a newly started M5 bar for optional new-bar-only trading.
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
// Function: AddIndicatorsToChart - Optionally overlay M5 SMA8 and SMA12 on the price chart.
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
// Function: PanelColorBg - Return color for main panel background.
color PanelColorBg()        { return C'15,23,36'; }
// Function: PanelColorRow - Return color for section header.
color PanelColorRow()       { return C'25,35,51'; }
// Function: PanelColorRowAlt - Return color for alternating chart rows.
color PanelColorRowAlt()    { return C'21,30,44'; }
// Function: PanelColorBorder - Return color for card outlines.
color PanelColorBorder()    { return C'63,77,97'; }
// Function: PanelColorText - Return color for primary panel text.
color PanelColorText()      { return C'234,241,248'; }
// Function: PanelColorMuted - Return color for secondary panel text.
color PanelColorMuted()     { return C'151,169,190'; }
// Function: PanelColorBuy - Return color for BUY indicators.
color PanelColorBuy()       { return C'79,224,157'; }
// Function: PanelColorSell - Return color for SELL indicators.
color PanelColorSell()      { return C'255,118,133'; }
// Function: PanelColorWait - Return color for WAIT indicators.
color PanelColorWait()      { return C'243,193,103'; }
// Function: PanelColorChipBuy - Return color for BUY chip backgrounds.
color PanelColorChipBuy()   { return C'23,72,63'; }
// Function: PanelColorChipSell - Return color for SELL chip backgrounds.
color PanelColorChipSell()  { return C'94,39,54'; }
// Function: PanelColorChipWait - Return color for WAIT chip backgrounds.
color PanelColorChipWait()  { return C'85,67,40'; }

// Auto-fit and user font scaling operate together so shrinking the fonts
// also shrinks row spacing/rectangles instead of causing overlapping labels.
// Function: PanelPixels - Convert one design pixel unit to scaled chart pixels.
int PanelPixels(const int value)
{
   return (int)MathMax(1.0,MathRound((double)value*g_panel_scale));
}

// Resolve one or two columns according to chart width, then scale the panel.
// On a narrow chart, the single column is split into two readable pages.
// Function: GetPanelOrigin - Choose responsive panel layout, scale and anchor coordinates.
void GetPanelOrigin(int &left,int &top)
{
   int chart_width=(int)ChartGetInteger(0,CHART_WIDTH_IN_PIXELS);
   int chart_height=(int)ChartGetInteger(0,CHART_HEIGHT_IN_PIXELS);
   double preferred_scale=(double)g_panel_user_percent/100.0;
   int double_width=PANEL_COL_WIDTH*2+PANEL_GAP*3;

   g_panel_columns=1;
   if(PanelMaxColumns==2 && chart_width>0 &&
      chart_width>=PanelX+8+(int)MathCeil(double_width*preferred_scale))
      g_panel_columns=2;

   g_panel_design_width=(g_panel_columns==2 ?
                         double_width : PANEL_COL_WIDTH+PANEL_GAP*2);
   g_panel_design_height=PANEL_DESIGN_HEIGHT;
   g_panel_scale=preferred_scale;

   if(PanelAutoFitToChart && chart_width>0 && chart_height>0)
   {
      double fit_w=(double)MathMax(1,chart_width-PanelX-8)/g_panel_design_width;
      double fit_h=(double)MathMax(1,chart_height-PanelY-8)/g_panel_design_height;
      g_panel_scale=MathMin(g_panel_scale,MathMin(fit_w,fit_h));
   }

   g_panel_scale=MathMax(0.35,g_panel_scale);
   int width=PanelPixels(g_panel_design_width);
   int height=PanelPixels(g_panel_design_height);
   left=PanelX;
   top=PanelY;

   if(PanelCorner==CORNER_RIGHT_UPPER || PanelCorner==CORNER_RIGHT_LOWER)
      left=chart_width-width-PanelX;
   if(PanelCorner==CORNER_LEFT_LOWER || PanelCorner==CORNER_RIGHT_LOWER)
      top=chart_height-height-PanelY;

   left=MathMax(0,left);
   top=MathMax(0,top);
   g_panel_left=left;
   g_panel_top=top;
}

// Function: PanelRectangle - Create or update a chart rectangle used for UI cards and backgrounds.
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

// Function: PanelLabel - Create or update an on-chart text label with font-size scaling.
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
// Function: PanelButton - Create or update a clickable panel navigation/zoom button.
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

//====================================================================
// REALIZED EA PROFIT BY BROKER-SERVER CALENDAR PERIOD
//====================================================================
// Function: ReadClosedProfitPeriods - Sum realized deal profit, swap,
// commission and fee for this Symbol and MagicNumber, including entry fees.
// TODAY and YESTERDAY are separate broker-server calendar days;
// MONTH covers the current broker-server calendar month.
// Floating position profit is intentionally excluded from these totals.
// "Yesterday" is the previous calendar day, not the prior trading day.
// Returns false if the terminal could not select the required deal history.
bool ReadClosedProfitPeriods(double &today_profit,
                             double &yesterday_profit,
                             double &month_profit)
{
   today_profit=0.0;
   yesterday_profit=0.0;
   month_profit=0.0;

   // TimeCurrent is deterministic inside the Strategy Tester.
   datetime now=TimeCurrent();
   if(!MQLInfoInteger(MQL_TESTER))
   {
      datetime live_server=TimeTradeServer();
      if(live_server>0) now=live_server;
   }
   if(now<=0) return false;

   MqlDateTime calendar;
   TimeToStruct(now,calendar);
   calendar.hour=0;
   calendar.min=0;
   calendar.sec=0;
   datetime today_start=StructToTime(calendar);
   datetime yesterday_start=today_start-86400;
   calendar.day=1;
   datetime month_start=StructToTime(calendar);
   datetime earliest=(yesterday_start<month_start ? yesterday_start : month_start);

   ResetLastError();
   if(!HistorySelect(earliest,now))
   {
      if(PrintSignalLog)
         PrintFormat("Performance history unavailable, error=%d",GetLastError());
      return false;
   }

   int deals=HistoryDealsTotal();
   for(int i=0;i<deals;i++)
   {
      ulong ticket=HistoryDealGetTicket(i);
      if(ticket==0) continue;
      if(HistoryDealGetString(ticket,DEAL_SYMBOL)!=_Symbol) continue;
      if((ulong)HistoryDealGetInteger(ticket,DEAL_MAGIC)!=MagicNumber) continue;

      // Exclude cash transfers, balance adjustments and other non-trade deals.
      ENUM_DEAL_TYPE kind=(ENUM_DEAL_TYPE)HistoryDealGetInteger(ticket,DEAL_TYPE);
      if(kind!=DEAL_TYPE_BUY && kind!=DEAL_TYPE_SELL) continue;

      datetime when=(datetime)HistoryDealGetInteger(ticket,DEAL_TIME);
      double net=HistoryDealGetDouble(ticket,DEAL_PROFIT)
                +HistoryDealGetDouble(ticket,DEAL_SWAP)
                +HistoryDealGetDouble(ticket,DEAL_COMMISSION)
                +HistoryDealGetDouble(ticket,DEAL_FEE);

      // Entry commissions are charged on actual entry deals and included.
      // Exit deal profit is reflected on the server day the position closes.
      if(when>=today_start && when<=now)
         today_profit+=net;
      else if(when>=yesterday_start && when<today_start)
         yesterday_profit+=net;
      if(when>=month_start && when<=now)
         month_profit+=net;
   }
   return true;
}

// Forward declarations for grouped layout drawing helpers.
void PanelSection(const string key,const string title,const int x,const int y,
                  const int width,const int height);
void PanelKV(const string key,const string caption,const string value,
             const int x,const int y,const color value_color);
void DeleteStatusPanel();

// Update all grouped status cards using precisely the same entry rules as OnTick.
// Two columns show all sections, while one-column layout uses two pages.
// Function: UpdateStatusPanel - Refresh grouped panel state without placing any trades.
void UpdateStatusPanel()
{
   if(!ShowStatusPanel || g_panel_prefix=="")
      return;

   int x=0,y=0;
   GetPanelOrigin(x,y);
   if(g_panel_last_columns!=g_panel_columns)
   {
      DeleteStatusPanel();
      g_panel_last_columns=g_panel_columns;
      g_panel_page=0;
   }

   double fast[TF_COUNT],slow[TF_COUNT];
   bool valid[TF_COUNT];
   int direction[TF_COUNT];
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
      if(valid[i] && fast[i]>slow[i]) direction[i]=1;
      else if(valid[i] && fast[i]<slow[i]) direction[i]=-1;

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
   if(enabled_count==0) all_valid=all_buy=all_sell=false;

   MqlRates candle[1];
   bool candle_valid=(CopyRates(_Symbol,PERIOD_M5,SIGNAL_SHIFT,1,candle)==1);
   int candle_direction=0;
   if(candle_valid)
   {
      if(candle[0].close>candle[0].open) candle_direction=1;
      if(candle[0].close<candle[0].open) candle_direction=-1;
   }

   bool cross_buy=false,cross_sell=false;
   bool cross_valid=(!UseSMACrossEntryFilter || ReadM5EntryCross(cross_buy,cross_sell));

   // The panel uses the same MTF bias definition as EntryCondition.
   // Enabled TF votes and Momentum Breakout both use closed M5 [1] data.
   int mtf_bias=0;
   if(all_valid && enabled_count>0)
   {
      if(MTFEntryBiasMode==MTF_ALL_AGREE)
      {
         if(all_buy) mtf_bias=1;
         else if(all_sell) mtf_bias=-1;
      }
      else
      {
         if(buy_votes>sell_votes) mtf_bias=1;
         else if(sell_votes>buy_votes) mtf_bias=-1;
      }
   }
   bool can_check_entry=(candle_valid && (!UseMTFTrendEntryFilter || all_valid));
   bool buy_signal=false,sell_signal=false;
   bool wick_buy=false,wick_sell=false;
   if(candle_valid)
   {
      wick_buy=CandleBodyWickPattern(candle[0].open,candle[0].high,candle[0].low,candle[0].close,true);
      wick_sell=CandleBodyWickPattern(candle[0].open,candle[0].high,candle[0].low,candle[0].close,false);
   }
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

   string bias_text="MIXED";
   color bias_color=PanelColorWait();
   if(!UseMTFTrendEntryFilter)
   {
      bias_text="GATE OFF";
      bias_color=PanelColorMuted();
   }
   else if(enabled_count==0) bias_text="NO TF ENABLED";
   else if(!all_valid) bias_text="WAIT DATA";
   else if(MTFEntryBiasMode==MTF_MAJORITY)
   {
      if(buy_votes>sell_votes) { bias_text="BUY BIAS"; bias_color=PanelColorBuy(); }
      else if(sell_votes>buy_votes) { bias_text="SELL BIAS"; bias_color=PanelColorSell(); }
      else bias_text="TIE / NO ENTRY";
   }
   else if(all_buy) { bias_text="ALL BUY"; bias_color=PanelColorBuy(); }
   else if(all_sell) { bias_text="ALL SELL"; bias_color=PanelColorSell(); }

   string candle_text="WAIT DATA";
   color candle_color=PanelColorWait();
   if(candle_valid)
   {
      if(candle_direction==-1) { candle_text="RED"; candle_color=PanelColorSell(); }
      else if(candle_direction==1) { candle_text="GREEN"; candle_color=PanelColorBuy(); }
      else { candle_text="DOJI"; candle_color=PanelColorMuted(); }
   }

   string signal_text="WAIT ENTRY FILTERS";
   color signal_color=PanelColorMuted();
   // No OR input enabled means ENTRY is OFF, even if MA data is available.
   bool any_entry_trigger=(UseCandleColorEntryFilter ||
                           UseCandleBodyWickEntryFilter ||
                           UseSMACrossEntryFilter ||
                           UseMomentumBreakoutEntryFilter);
   if(!any_entry_trigger) signal_text="OFF";
   else if(!can_check_entry) { signal_text="WAIT DATA"; signal_color=PanelColorWait(); }
   else if(buy_signal && sell_signal) { signal_text="CONFLICT / NO ENTRY"; signal_color=PanelColorWait(); }
   else if(buy_signal) { signal_text="BUY SIGNAL"; signal_color=PanelColorBuy(); }
   else if(sell_signal) { signal_text="SELL SIGNAL"; signal_color=PanelColorSell(); }

   int basket_buys=0,basket_sells=0;
   double basket_profit=0.0;
   ScanMyBasket(basket_buys,basket_sells,basket_profit);
   int total=basket_buys+basket_sells;
   double basket_points=0.0;
   bool basket_points_valid=CalculateBasketProfitPoints(basket_points);
   bool basket_active=((basket_buys>0 && basket_sells>0 && UseRRTP && UseHedgeBasketTP) ||
                       (UseSameSideRecoveryLot && g_same_recovery_active && total>0) ||
                       (UseRecoveryLot && RecoveryLotMultiplier==0.0 &&
                        g_recovery_active && total>0));
   string positions_limit=(MaxPositionsPerSymbol==0 ? "INF" : IntegerToString(MaxPositionsPerSymbol));

   string exit_text="--";
   color exit_color=PanelColorMuted();
   if(g_basket_closing) { exit_text="CLOSING BASKET"; exit_color=PanelColorWait(); }
   else if(basket_active)
   {
      if(!basket_points_valid) { exit_text="WAIT BASKET QUOTE"; exit_color=PanelColorWait(); }
      else
      {
         exit_text=(basket_points>=BasketProfitTarget ? "BASKET TARGET HIT" : "WAIT BASKET POINTS");
         exit_color=(basket_points>=BasketProfitTarget ? PanelColorBuy() : PanelColorWait());
      }
   }
   else if(UsingNoSLTPMode() && NoSLTPMode==TP_FIXED_POINTS)
      exit_text=StringFormat("BROKER TP %d PT",FixedTPPoints);
   else if(UsingNoSLTPMode() && NoSLTPMode==TP_M5_MA_CROSS)
   {
      bool up=false,down=false;
      if(!ReadM5Cross(up,down)) { exit_text="WAIT M5 SMA"; exit_color=PanelColorWait(); }
      else if(down) { exit_text="CLOSE BUY (DOWN)"; exit_color=PanelColorSell(); }
      else if(up) { exit_text="CLOSE SELL (UP)"; exit_color=PanelColorBuy(); }
      else exit_text="WAIT M5 CROSS";
   }
   else if(UsingNoSLTPMode() && NoSLTPMode==TP_ALL_ACTIVE_TFS_OPPOSE)
   {
      if(!all_valid) { exit_text="WAIT MTF DATA"; exit_color=PanelColorWait(); }
      else if(all_sell) { exit_text="CLOSE BUY (ALL SELL)"; exit_color=PanelColorSell(); }
      else if(all_buy) { exit_text="CLOSE SELL (ALL BUY)"; exit_color=PanelColorBuy(); }
      else exit_text="WAIT TF REVERSAL";
   }
   else if(UseSwingSL && UseRRTP) exit_text="BROKER RR TP";
   else if(!UseRRTP) exit_text="TP DISABLED";

   string recovery_text="OFF";
   color recovery_color=PanelColorMuted();
   if(UseRecoveryLot)
   {
      if(RecoveryLotMultiplier==0.0)
         recovery_text=(g_recovery_active ? "DYNAMIC ACTIVE" : "DYNAMIC ARMED");
      else
         recovery_text=(g_recovery_active ? StringFormat("ACTIVE x%.2f",RecoveryLotMultiplier) :
                         StringFormat("ARMED x%.2f",RecoveryLotMultiplier));
      recovery_color=(g_recovery_active ? PanelColorWait() : PanelColorBuy());
   }

   string next_lot=DoubleToString(LotSize,3);
   if(buy_signal!=sell_signal)
   {
      bool opening_hedge=(buy_signal ? basket_sells>0 : basket_buys>0);
      double normalized=0.0;
      if(UseRecoveryLot && RecoveryLotMultiplier==0.0 &&
         (g_recovery_active || opening_hedge))
      {
         double projection=0.0;
         if(CalculateDynamicRecoveryVolume(buy_signal,normalized,projection,false))
            next_lot=DoubleToString(normalized,3)+" DYN";
         else next_lot="DYN: NO SAFE LOT";
      }
      else if(PrepareEntryVolume(RequestedEntryLot(opening_hedge),normalized,false,false))
         next_lot=DoubleToString(normalized,3);
      else next_lot="INVALID LOT";
   }
   else next_lot=DoubleToString(RequestedEntryLot(false),3);

   string same_text="OFF";
   color same_color=PanelColorMuted();
   if(UseSameSideRecoveryLot)
   {
      same_text=(g_same_recovery_active ? "ACTIVE BASKET" : "ARMED NO BOOST");
      same_color=(g_same_recovery_active ? PanelColorWait() : PanelColorBuy());
   }

   string cross_text="OFF";
   color cross_color=PanelColorMuted();
   if(UseSMACrossEntryFilter)
   {
      cross_text="NO CROSS";
      if(!cross_valid) { cross_text="WAIT MA DATA"; cross_color=PanelColorWait(); }
      else if(cross_buy) { cross_text="BUY CROSS"; cross_color=PanelColorBuy(); }
      else if(cross_sell) { cross_text="SELL CROSS"; cross_color=PanelColorSell(); }
   }

   string momentum_text="OFF";
   color momentum_color=PanelColorMuted();
   if(UseMomentumBreakoutEntryFilter)
   {
      bool momentum_buy=false,momentum_sell=false;
      if(!ReadMomentumBreakout(momentum_buy,momentum_sell))
      {
         momentum_text="WAIT M5 DATA";
         momentum_color=PanelColorWait();
      }
      else if(momentum_buy)
      {
         momentum_text="BUY TRIGGER";
         momentum_color=PanelColorBuy();
      }
      else if(momentum_sell)
      {
         momentum_text="SELL TRIGGER";
         momentum_color=PanelColorSell();
      }
      else
         momentum_text="NO BREAKOUT";
   }

   string color_trigger="OFF";
   color color_trigger_color=PanelColorMuted();
   if(UseCandleColorEntryFilter)
   {
      if(!candle_valid)
      {
         color_trigger="WAIT DATA";
         color_trigger_color=PanelColorWait();
      }
      else if(candle_direction==0)
      {
         color_trigger="NO COLOR";
      }
      else
      {
         IndicatorState color_state;
         color_state.open=candle[0].open;
         color_state.close=candle[0].close;
         bool color_pass=PassEntryCandleColorFilter(color_state,candle_direction==-1);
         if(color_pass)
         {
            color_trigger=(candle_direction==-1 ? "BUY TRIGGER" : "SELL TRIGGER");
            color_trigger_color=(candle_direction==-1 ? PanelColorBuy() : PanelColorSell());
         }
         else
         {
            color_trigger="BODY BLOCK / WAIT";
            color_trigger_color=PanelColorWait();
         }
      }
   }

   string wick_trigger="OFF";
   color wick_trigger_color=PanelColorMuted();
   if(UseCandleBodyWickEntryFilter)
   {
      wick_trigger=(!candle_valid ? "WAIT DATA" :
                    (wick_buy && wick_sell ? "BOTH" :
                    (wick_buy ? "BUY TRIGGER" : (wick_sell ? "SELL TRIGGER" : "NO PATTERN"))));
      wick_trigger_color=(wick_buy ? PanelColorBuy() :
                          (wick_sell ? PanelColorSell() : PanelColorMuted()));
   }

   string slow_distance_text="OFF";
   color slow_distance_color=PanelColorMuted();
   if(UseSlowSMADistanceEntryFilter)
   {
      // Match the trade direction selected by MTF, when one is available.
      bool display_buy=(mtf_bias>=0);
      double distance=0.0,limit=0.0,atr=0.0;
      if(!ReadSlowSMADistance(display_buy,distance,limit,atr))
      {
         slow_distance_text="WAIT MA/ATR DATA";
         slow_distance_color=PanelColorWait();
      }
      else
      {
         bool pass=(distance<=limit+_Point*1e-6);
         double shown=(SlowSMADistanceMode==SLOW_SMA_DISTANCE_ATR ?
                       distance/atr : distance/_Point);
         double allowed=(SlowSMADistanceMode==SLOW_SMA_DISTANCE_ATR ?
                         SlowSMAMaxDistanceATR : (double)SlowSMAMaxDistancePoints);
         slow_distance_text=StringFormat("%s %.2f/%.2f %s",
                              (SlowSMADistanceMode==SLOW_SMA_DISTANCE_ATR ? "ATR" : "PT"),
                              shown,allowed,(pass ? "PASS" : "BLOCK"));
         slow_distance_color=(pass ? PanelColorBuy() : PanelColorSell());
      }
   }

   // Realized results are independent from the floating Basket P/L above.
   // "Yesterday" is the prior calendar date in MT5 broker-server time.
   double today_closed=0.0,yesterday_closed=0.0,month_closed=0.0;
   bool history_ok=ReadClosedProfitPeriods(today_closed,yesterday_closed,month_closed);
   string currency=AccountInfoString(ACCOUNT_CURRENCY);

   // Draw the outer card first so internal cards and labels stay readable.
   PanelRectangle("background",x,y,g_panel_design_width,g_panel_design_height,
                  PanelColorBg(),PanelColorBorder());
   PanelRectangle("top_accent",x+1,y+1,g_panel_design_width-2,4,
                  C'48,139,223',C'48,139,223');
   PanelLabel("title",(g_panel_columns==2 ? "MTF SMA | BASELINE 002" : "MTF SMA | 002"),
              x+16,y+14,PanelColorText(),13,"Arial");

   // On one-column charts, navigation occupies the first header row.
   // Trade status remains visible in section 02, with no separate card.
   if(g_panel_columns==2)
      PanelLabel("trading",(EnableTrading ? "TRADE ON" : "TRADE OFF"),
                 x+g_panel_design_width-112,y+17,
                 (EnableTrading ? PanelColorBuy() : PanelColorWait()),9);
   else
   {
      PanelButton("page_prev","<",x+g_panel_design_width-98,y+11,38,22);
      PanelButton("page_next",">",x+g_panel_design_width-54,y+11,38,22);
   }

   PanelLabel("subtitle",StringFormat("%s | M5 | SMA(%d,%d) | CLOSED [1]",
              _Symbol,FastMAPeriod,SlowMAPeriod),
              x+16,y+39,PanelColorMuted(),9);
   // Requested TEXT % is now a small header info item separated by pipes.
   PanelLabel("header_info",StringFormat("TEXT %d%% | REFRESH %ds | %d COL",
              g_panel_user_percent,PanelRefreshSeconds,g_panel_columns),
              x+16,y+63,PanelColorMuted(),9);

   bool left_page=(g_panel_columns==2 || g_panel_page==0);
   bool right_page=(g_panel_columns==2 || g_panel_page==1);
   int left_x=x+PANEL_GAP;
   int right_x=(g_panel_columns==2 ? left_x+PANEL_COL_WIDTH+PANEL_GAP : left_x);
   int top_y=y+88;

   if(left_page)
   {
      PanelSection("trend","01  MTF SMA TREND",left_x,top_y,PANEL_COL_WIDTH,258);
      PanelLabel("col_tf","TF",left_x+13,top_y+39,PanelColorMuted(),9);
      PanelLabel("col_fast",StringFormat("FAST %d",FastMAPeriod),left_x+58,top_y+39,PanelColorMuted(),9);
      PanelLabel("col_slow",StringFormat("SLOW %d",SlowMAPeriod),left_x+158,top_y+39,PanelColorMuted(),9);
      PanelLabel("col_trend","TREND",left_x+290,top_y+39,PanelColorMuted(),9);
      for(int i=0;i<TF_COUNT;i++)
      {
         int yy=top_y+66+i*24;
         string key=StringFormat("tf_%d_",i);
         color row_color=(i%2==0 ? PanelColorRowAlt() : PanelColorRow());
         PanelRectangle(key+"row",left_x+7,yy-4,PANEL_COL_WIDTH-14,22,row_color,row_color);
         PanelLabel(key+"name",g_tf_names[i],left_x+13,yy,PanelColorText(),10);
         PanelLabel(key+"fast",(valid[i] ? DoubleToString(fast[i],_Digits) : "--"),
                    left_x+58,yy,(valid[i] ? PanelColorText() : PanelColorMuted()),10);
         PanelLabel(key+"slow",(valid[i] ? DoubleToString(slow[i],_Digits) : "--"),
                    left_x+158,yy,(valid[i] ? PanelColorText() : PanelColorMuted()),10);
         string status="WAIT";
         color status_color=PanelColorWait();
         color badge_color=PanelColorChipWait();
         if(!IsTFEnabled(i))
         {
            status="OFF";
            status_color=PanelColorMuted();
            badge_color=PanelColorRow();
         }
         else if(valid[i] && direction[i]==1)
         {
            status="BUY";
            status_color=PanelColorBuy();
            badge_color=PanelColorChipBuy();
         }
         else if(valid[i] && direction[i]==-1)
         {
            status="SELL";
            status_color=PanelColorSell();
            badge_color=PanelColorChipSell();
         }
         else if(valid[i])
         {
            status="FLAT";
            status_color=PanelColorMuted();
         }

         // Color-fill only the direction badge; values remain neutral/legible.
         PanelRectangle(key+"trend_chip",left_x+281,yy-3,100,20,badge_color,badge_color);
         PanelLabel(key+"trend",status,left_x+296,yy,status_color,10);
      }
      PanelRectangle("trend_divider",left_x+12,top_y+197,PANEL_COL_WIDTH-24,1,
                     PanelColorBorder(),PanelColorBorder());
      PanelKV("trend_bias","MTF BIAS",bias_text,left_x,top_y+207,bias_color);
      PanelKV("trend_votes","TF VOTES",StringFormat("BUY:%d SELL:%d FLAT:%d",
              buy_votes,sell_votes,flat_votes),left_x,top_y+230,PanelColorText());

      // Execution is merged into Entry instead of being a separate card.
      int ey=top_y+270;
      PanelSection("entry","02  ENTRY FILTERS  |  GATE + OR",left_x,ey,PANEL_COL_WIDTH,316);
      PanelKV("entry_gate","MTF GATE",(UseMTFTrendEntryFilter ?
              (MTFEntryBiasMode==MTF_MAJORITY ? "ON MAJORITY" : "ON ALL AGREE") : "OFF"),
              left_x,ey+38,(UseMTFTrendEntryFilter ? PanelColorBuy() : PanelColorMuted()));
      PanelKV("entry_candle","M5 CANDLE [1]",candle_text,left_x,ey+62,candle_color);
      PanelKV("entry_color","COLOR (OR)",color_trigger,left_x,ey+86,color_trigger_color);
      PanelKV("entry_wick","BODY/WICK (OR)",wick_trigger,left_x,ey+110,wick_trigger_color);
      PanelKV("entry_cross","SMA CROSS (OR)",cross_text,left_x,ey+134,cross_color);
      PanelKV("entry_momentum","MOMENTUM (OR)",momentum_text,left_x,ey+158,momentum_color);
      PanelKV("entry_distance","SLOW SMA DIST",slow_distance_text,left_x,ey+184,slow_distance_color);
      PanelKV("entry_signal","ENTRY SIGNAL",signal_text,left_x,ey+210,signal_color);
      PanelKV("exec_mode","ORDER EVAL",(TradeOnNewBarOnly ? "M5 NEW BAR" : "EVERY TICK"),
              left_x,ey+237,PanelColorText());
      PanelKV("exec_status","TRADING",(EnableTrading ? "ENABLED" : "DISABLED"),
              left_x,ey+262,(EnableTrading ? PanelColorBuy() : PanelColorMuted()));
      PanelLabel("or_hint","MTF + Slow SMA distance gates AND enabled OR triggers.",
                 left_x+12,ey+289,PanelColorMuted(),8);
   }

   if(right_page)
   {
      PanelSection("positions","03  POSITIONS & EXIT",right_x,top_y,PANEL_COL_WIDTH,190);
      PanelKV("position_count","EA POSITIONS",StringFormat("%d/%s  B:%d S:%d",
              total,positions_limit,basket_buys,basket_sells),right_x,top_y+38,PanelColorText());
      PanelKV("position_hedge","HEDGE",(basket_buys>0 && basket_sells>0 ?
              "BOTH SIDES" : (AllowBothDirections ? "READY" : "OFF")),
              right_x,top_y+63,(basket_buys>0 && basket_sells>0 ? PanelColorWait() : PanelColorMuted()));
      PanelKV("position_sl","SWING SL",(UseSwingSL ? StringFormat("ON M5 [%d]",SwingLookbackBars) : "OFF"),
              right_x,top_y+88,(UseSwingSL ? PanelColorBuy() : PanelColorMuted()));
      PanelKV("position_tp","TP MODE",(basket_active ? "BASKET POINTS" : TPModeName()),
              right_x,top_y+113,(basket_active || UseRRTP ? PanelColorBuy() : PanelColorMuted()));
      PanelKV("position_exit","TP STATUS",exit_text,right_x,top_y+140,exit_color);
      PanelKV("position_limit","MAX POSITIONS",positions_limit,right_x,top_y+168,PanelColorText());

      int by=top_y+202;
      PanelSection("basket","04  COMBINED BASKET",right_x,by,PANEL_COL_WIDTH,156);
      PanelKV("basket_mode","BASKET MODE",(basket_active ? "ACTIVE" :
                        (!UseHedgeBasketTP && !UseSameSideRecoveryLot &&
                         !(UseRecoveryLot && RecoveryLotMultiplier==0.0) ? "OFF" : "STANDBY")),
              right_x,by+36,(basket_active ? PanelColorWait() : PanelColorMuted()));
      PanelKV("basket_pts","BASKET POINTS",(basket_points_valid ?
              StringFormat("%.1f pts",basket_points) : "WAIT QUOTE"),right_x,by+61,
              (!basket_points_valid ? PanelColorWait() :
               (basket_points>=0.0 ? PanelColorBuy() : PanelColorSell())));
      PanelKV("basket_target","TARGET",StringFormat("%.1f pts",BasketProfitTarget),
              right_x,by+86,PanelColorText());
      PanelKV("basket_pl","FLOATING P/L",StringFormat("%.2f %s",basket_profit,
              currency),right_x,by+111,
              (basket_profit>=0.0 ? PanelColorBuy() : PanelColorSell()));
      PanelLabel("basket_disclaimer","Points exclude fees, swap and execution slippage.",
                 right_x+12,by+138,PanelColorMuted(),8);

      int ry=by+168;
      PanelSection("recovery","05  RECOVERY CONTROL",right_x,ry,PANEL_COL_WIDTH,162);
      PanelKV("rec_status","OPPOSITE LOT",recovery_text,right_x,ry+35,recovery_color);
      PanelKV("rec_lot","NEXT ENTRY LOT",next_lot,right_x,ry+60,PanelColorText());
      PanelKV("rec_same","SAME-SIDE TP",same_text,right_x,ry+85,same_color);
      PanelKV("rec_move","DYNAMIC MOVE",(UseRecoveryLot && RecoveryLotMultiplier==0.0 ?
              StringFormat("%d pts",DynamicRecoveryMovePoints) : "N/A"),
              right_x,ry+110,PanelColorText());
      PanelKV("rec_cap","DYNAMIC MAX LOT",(UseRecoveryLot && RecoveryLotMultiplier==0.0 ?
              DoubleToString(MaxDynamicRecoveryLot,3) : "N/A"),right_x,ry+135,PanelColorText());

      // Realized trade profit periods exclude currently open positions.
      int py=ry+174;
      PanelSection("profit","06  CLOSED PROFIT",right_x,py,PANEL_COL_WIDTH,125);
      PanelKV("profit_today","TODAY",(history_ok ? StringFormat("%+.2f %s",today_closed,currency) : "WAIT HISTORY"),
              right_x,py+36,(history_ok ? (today_closed>=0.0 ? PanelColorBuy() : PanelColorSell()) : PanelColorWait()));
      PanelKV("profit_yesterday","YESTERDAY",(history_ok ? StringFormat("%+.2f %s",yesterday_closed,currency) : "WAIT HISTORY"),
              right_x,py+61,(history_ok ? (yesterday_closed>=0.0 ? PanelColorBuy() : PanelColorSell()) : PanelColorWait()));
      PanelKV("profit_month","THIS MONTH",(history_ok ? StringFormat("%+.2f %s",month_closed,currency) : "WAIT HISTORY"),
              right_x,py+86,(history_ok ? (month_closed>=0.0 ? PanelColorBuy() : PanelColorSell()) : PanelColorWait()));
   }

   datetime closed_bar=iTime(_Symbol,PERIOD_M5,SIGNAL_SHIFT);
   string closed_time=(closed_bar>0 ? TimeToString(closed_bar,TIME_DATE|TIME_MINUTES) : "--");
   PanelLabel("footer",StringFormat("M5 CLOSED %s | SERVER DAYS | VIEW %d/%d",
              closed_time,(g_panel_columns==1 ? g_panel_page+1 : 1),
              (g_panel_columns==1 ? 2 : 1)),x+16,y+768,PanelColorMuted(),9);
   ChartRedraw(0);
}

// Draw a separate bordered card with a title, without overlapping other cards.
// Function: PanelSection - Draw the background and header of a grouped panel section.
void PanelSection(const string key,const string title,const int x,const int y,
                  const int width,const int height)
{
   PanelRectangle(key+"_background",x,y,width,height,PanelColorRowAlt(),PanelColorBorder());
   PanelRectangle(key+"_header",x+1,y+1,width-2,27,PanelColorRow(),PanelColorRow());
   PanelLabel(key+"_title",title,x+12,y+7,PanelColorText(),10,"Arial");
}

// Print one aligned label/value row inside a grouped panel section.
// Function: PanelKV - Draw a label/value pair aligned within one section.
void PanelKV(const string key,const string caption,const string value,
             const int x,const int y,const color value_color)
{
   PanelLabel(key+"_label",caption,x+12,y,PanelColorMuted(),9);
   PanelLabel(key+"_value",value,x+157,y,value_color,9);
}

// Function: DeleteStatusPanel - Remove every on-chart object created by this EA panel.
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

// Function: OnTimer - Refresh persistent state and the read-only panel on each timer event.
void OnTimer()
{
   RefreshRecoveryState();
   RefreshSameSideRecoveryState();
   UpdateStatusPanel();
}

// Route compact-page navigation clicks and chart resize events only.
// Function: OnChartEvent - Process page switching and chart resizing.
void OnChartEvent(const int id,const long &lparam,
                  const double &dparam,const string &sparam)
{
   if(id==CHARTEVENT_OBJECT_CLICK && ShowStatusPanel)
   {
      bool handled=true;
      if(g_panel_columns==1 && sparam==g_panel_prefix+"page_prev")
         g_panel_page=0;
      else if(g_panel_columns==1 && sparam==g_panel_prefix+"page_next")
         g_panel_page=1;
      else
         handled=false;

      if(handled)
      {
         ObjectSetInteger(0,sparam,OBJPROP_STATE,false);
         DeleteStatusPanel();
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
// Function: OnInit - Validate inputs, create SMA handles, restore state and start panel timer.
int OnInit()
{
   // Safe handle cleanup even if a parameter check fails immediately.
   for(int i=0; i<TF_COUNT; i++)
   {
      g_fast_ma_handles[i]=INVALID_HANDLE;
      g_slow_ma_handles[i]=INVALID_HANDLE;
   }
   g_slow_distance_atr_handle=INVALID_HANDLE;

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

   if(SlowSMADistanceMode!=SLOW_SMA_DISTANCE_ATR &&
      SlowSMADistanceMode!=SLOW_SMA_DISTANCE_POINTS)
   {
      Print("Invalid SlowSMADistanceMode; choose ATR or POINTS.");
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
       (UseSlowSMADistanceEntryFilter &&
        (SlowSMAATRPeriod<1 ||
         !MathIsValidNumber(SlowSMAMaxDistanceATR) ||
         SlowSMAMaxDistanceATR<=0.0 ||
         SlowSMAMaxDistancePoints<=0)) ||
      (UseMomentumBreakoutEntryFilter &&
       (!MathIsValidNumber(MomentumMinBodyRatio) ||
        MomentumMinBodyRatio<=0.0 || MomentumMinBodyRatio>1.0 ||
        MomentumBreakoutLookbackBars<1 ||
        MomentumBreakoutLookbackBars>=OHLCV_HISTORY)) ||
       PanelX<0 || PanelY<0 || PanelRefreshSeconds<1 ||
       PanelFontScalePercent<60 || PanelFontScalePercent>150 ||
       PanelMaxColumns<1 || PanelMaxColumns>2)
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

   if(!UseCandleColorEntryFilter && !UseCandleBodyWickEntryFilter &&
      !UseSMACrossEntryFilter && !UseMomentumBreakoutEntryFilter)
   {
      Print("Entry OR group is empty: enable CandleColor, BodyWick, SMACross, or MomentumBreakout.");
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
      Print("NOTE: CloseOnOppositeSignal is bypassed when an opposite entry must coexist with open positions.");
   if(AllowBothDirections && !UseHedgeBasketTP)
      Print("HEDGE BASKET OFF: holding BUY and SELL together does not activate combined Basket TP. Per-position TP remains active unless recovery basket is separately enabled.");
   if(AllowBothDirections && UseRRTP && UseHedgeBasketTP)
      PrintFormat("When BOTH BUY and SELL exist, per-position TPs switch to basket target %.1f points (sum weighted by volume / configured LotSize %.2f).",
                  BasketProfitTarget,LotSize);
   if(MaxPositionsPerSymbol==0)
       Print("NOTE: MaxPositionsPerSymbol=0 means unlimited; entries are limited to one new position per M5 bar.");
   if(UseRecoveryLot && RecoveryLotMultiplier==0.0)
       Print("WARNING: dynamic recovery sizes exposure for an assumed favorable price move, not a guaranteed TP. Basket closes on actual target points and is active even when UseRRTP=false. High margin/drawdown risk.");
   if(UseSameSideRecoveryLot)
       Print("NOTE: Same-side losing entry enables combined Basket TP with NO same-side lot increase. Swing SL remains active if configured.");
   if(UseSlowSMADistanceEntryFilter)
      PrintFormat("GLOBAL ENTRY Slow SMA distance enabled: mode=%s, ATR period=%d, multiplier=%.2f, max points=%d. All OR entry triggers are gated.",
                  (SlowSMADistanceMode==SLOW_SMA_DISTANCE_ATR ? "ATR" : "POINTS"),
                  SlowSMAATRPeriod,SlowSMAMaxDistanceATR,SlowSMAMaxDistancePoints);
   if(UseCandleColorEntryFilter)
      Print("COLOR BODY: require Body[1] < Body[2] on each matching candle-color entry.");
   if(UseMomentumBreakoutEntryFilter)
      PrintFormat("M5 MOMENTUM BREAKOUT enabled: body/range >= %.2f, break %d prior closed bars, SMA(%d)>/<SMA(%d) confirms direction.",
                  MomentumMinBodyRatio,MomentumBreakoutLookbackBars,FastMAPeriod,SlowMAPeriod);

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

   // Create ATR only when the optional ATR distance gate is enabled.
   if(UseSlowSMADistanceEntryFilter && SlowSMADistanceMode==SLOW_SMA_DISTANCE_ATR)
   {
      g_slow_distance_atr_handle=iATR(_Symbol,PERIOD_M5,SlowSMAATRPeriod);
      if(g_slow_distance_atr_handle==INVALID_HANDLE)
      {
         PrintFormat("Cannot create M5 ATR(%d) indicator, error=%d",
                     SlowSMAATRPeriod,GetLastError());
         return INIT_FAILED;
      }
   }

   AddIndicatorsToChart();
   g_last_bar_time=iTime(_Symbol,PERIOD_M5,0);

   g_panel_prefix=StringFormat("MTFSMA002_%I64u_",MagicNumber);
   g_panel_user_percent=PanelFontScalePercent;
   if(ShowStatusPanel)
   {
      UpdateStatusPanel();
      if(!EventSetTimer(PanelRefreshSeconds))
         PrintFormat("Panel timer setup failed. Error=%d",GetLastError());
   }

   PrintFormat("MTF SMA EA BASELINE 002 v2.61 | TF=M5 | Fast=%d Slow=%d | ActiveTF=%d/5 | MTF Bias=%s | Entry=MTF_GATE AND (COLOR OR WICK OR CROSS OR MOMENTUM) | MA:%s COLOR:%s WICK:%s CROSS:%s MOMENTUM:%s | SwingSL=%s Lookback=%d | TP=%s | Trading=%s",
               FastMAPeriod,SlowMAPeriod,EnabledTFCount(),
               (MTFEntryBiasMode==MTF_MAJORITY ? "MAJORITY" : "ALL AGREE"),
               (UseMTFTrendEntryFilter ? "ON" : "OFF"),
               (UseCandleColorEntryFilter ? "ON" : "OFF"),
               (UseCandleBodyWickEntryFilter ? "ON" : "OFF"),
               (UseSMACrossEntryFilter ? "ON" : "OFF"),
               (UseMomentumBreakoutEntryFilter ? "ON" : "OFF"),
               (UseSwingSL ? "ON" : "OFF"),SwingLookbackBars,
               TPModeName(),(EnableTrading ? "ON" : "OFF"));
   return INIT_SUCCEEDED;
}

//====================================================================
// DEINITIALIZATION
//====================================================================
// Function: OnDeinit - Stop chart timer, release indicator handles and delete panel objects.
void OnDeinit(const int reason)
{
   EventKillTimer();
   DeleteStatusPanel();
   if(g_slow_distance_atr_handle!=INVALID_HANDLE)
   {
      IndicatorRelease(g_slow_distance_atr_handle);
      g_slow_distance_atr_handle=INVALID_HANDLE;
   }
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
// Function: OnTick - Manage basket/individual exits first, then evaluate at most one new entry.
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
      bool basket_mode=((hedged && UseRRTP && UseHedgeBasketTP) || same_basket || dynamic_basket);

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
      // some higher-timeframe history hasn't downloaded. Suspend only when
      // a basket is ACTUALLY active; hedging by itself is not a basket.
      if(EnableTrading && !(hedge_active && UseRRTP && UseHedgeBasketTP) &&
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

   // Suspend individual indicator exits only when a basket is actually active.
   // Hedging alone no longer forces basket TP when UseHedgeBasketTP=false.
   if((hedge_active && UseRRTP && UseHedgeBasketTP) ||
      (UseSameSideRecoveryLot && g_same_recovery_active) ||
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
   // Safety with unlimited positions
   if(current_bar==g_last_entry_bar)
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
         // No fallback to fixed lot: must honor the projected target and cap.
         return;
   }
   else if(!PrepareEntryVolume(requested_lot,entry_lot))
      return;

   bool currently_in_basket=((HasMyHedge() && UseRRTP && UseHedgeBasketTP) ||
                             (UseSameSideRecoveryLot && g_same_recovery_active) ||
                             (UseRecoveryLot && RecoveryLotMultiplier==0.0 && g_recovery_active));
   bool entry_needs_basket=((opening_hedge && UseRRTP && UseHedgeBasketTP) ||
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
      // Commit latch only AFTER a confirmed successful order.
      SetRecoveryActive();
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
