// PriceActionPatternsEA v5.00 -- source only; compile and backtest in MT5.
// INSTALL: MQL5/Experts/PriceActionPatternsEA.mq5 -> MetaEditor F7.
// Chart timeframe by default. All detection uses CLOSED candles (s>=1).
// Each pattern has its own Is... function and Enable... input.
// Candle reversal context: close before pattern vs close TrendBars earlier.
// Chart patterns are explicit heuristic approximations, disabled by default.
// No claimed win rates from the supplied posters are used.
// RiskPercent estimates loss at SL, excluding commissions, gaps and slippage.
// V4: own hedging positions allowed; foreign exposure and outstanding orders block entry.
// Friday time exit added in v2. No martingale or recovery. V3 adds percentage trailing.
// Pattern timestamps processed once, persisted after accepted orders.
// Restart while flat skips the already-open bar. Use unique Magic per instance.
// Single-candle reversals require the following candle to close beyond high/low.
// Stars: StrictGaps=false permits continuous FX candles; true requires body gaps.
// Three Line Strike here means the FOURTH engulfing candle's reversal direction.
// Three Stars North is a mirrored South heuristic, not a standardized definition.
// Wedge/Flag/Cup/U/V/Demand/Supply and divergence definitions appear below.
#property strict
#property version "5.00"
#property description "PA v5: original market entry plus Fibonacci add-ons and percentage trailing"
#include <Trade/Trade.mqh>
CTrade trade;
input ENUM_TIMEFRAMES Timeframe=PERIOD_CURRENT;
input ulong Magic=120927;
input double RiskPercent=1.0;
input double RewardRisk=2.0;
input int StopBufferPoints=50;
input int MaxSpreadPoints=300;
input int DeviationPoints=20;
input int TrendBars=5;
input bool UseTrendContext=true;
input bool StrictGaps=false;
input double DojiRatio=0.10;
input double SmallBodyRatio=0.35;
input double LongBodyRatio=0.60;
input double WickBodyRatio=2.0;
input double MatchRangeRatio=0.10;
input bool EnableChartPatterns=false;
input int ChartWindow=24;
input int RSIPeriod=14;

// V2 BACKTEST: reset Inputs; same XAUUSDc/M15/date/deposit as v1.
// Default CORE = Hammer, ShootingStar, Engulfing, Harami, Morning/EveningStar.
// Both buy/sell variants remain enabled; not selected by in-sample profits.
// CUSTOM uses individual switches; SinglePattern exact name overrides mode/switches.
// Chart single-pattern tests additionally require EnableChartPatterns=true.
// BullishPinBar aliases Hammer; BearishPinBar aliases ShootingStar.
// CUSTOM deduplicates aliases; selecting SinglePattern bypasses that suppression.
// Trend=two prior confirmed swing highs AND lows, before the pattern begins.
// Location=pattern extreme near a prior confirmed swing, closing back on its valid side.
// ATR is a simple mean of CLOSED true ranges, not Wilder's iATR smoothing.
// Friday hours are BROKER SERVER time. Defaults fit the supplied report;
// check your symbol session. No tick / closed market can prevent timely exit.
// CSV: local terminal/TESTER AGENT MQL5/Files, unique per run, no FILE_COMMON.
// Match SIGNAL_ACCEPT.order to DEAL.order; DEAL.position links all exits.
// Journal also prints full pattern names. CSV disabled during optimization.
// SOURCE ONLY: requires MetaEditor compile and MT5 real-tick backtest.
enum ENUM_PATTERN_SET { PATTERNS_CORE=0, PATTERNS_CUSTOM=1 };
input ENUM_PATTERN_SET PatternSet=PATTERNS_CORE;
input string SinglePattern="";
input bool UseStructureFilter=true;
input bool UseLevelFilter=true;
input int StructureLookback=100;
input int ATRPeriod=14;
input double LevelToleranceATR=0.50;
input double ATRStopBuffer=0.20;
input double MinStopATR=1.0;
input double MaxStopATR=4.0;
input double MaxSpreadToStop=0.10;
input double MaxEntryDriftATR=0.30;
input bool ConfirmHaramiTweezer=true;
input bool UseWeekendGuard=true;
input int FridayNoEntryHour=18;
input int FridayCloseHour=20;
// V3: keep TP fixed. Progress uses executable Bid (buy) / Ask (sell).
// At 40%: lock entry +/- twice CURRENT spread. This does not cover all costs.
// At 90%: SL = 2*Bid-TP (buy) or 2*Ask-TP (sell).
// Jumping directly past 90% applies the tighter of lock and trailing in one request.
// Only tighten SL; tick-size rounded away from market, broker stops/freeze respected.
// No monetary-profit exit: that would pre-empt this trailing test.
// No fallback fixed SL: initial protection remains the v2 risk-sized ATR stop.
// V5: first entry uses v3 market-entry and pattern-based SL rules while symbol flat.
// On accepted first entry only, clear signal[] and seed Fibonacci ADD-ON levels.
// New patterns while positions remain do not open another primary or rebuild the queue.
// Add-ons keep the INITIAL primary SL, without widening it to a swing extreme.
// A level whose remaining stop distance is invalid is skipped, not widened.
// TP is 2R (RewardRisk) from each entry; trailing manages each ticket independently.
// Disable EnableFiboAddOns for a v3-style entry/exit control run.
// Three candidate levels; maximum TWO accepted add-ons per setup by default.
// MaxOpenPositions includes the primary. Risk capped at MaxTotalRiskPercent.
// All remaining levels clear when basket becomes flat, expires or breaks its swing.
// Queue is memory-only and is lost on restart/recompile; live positions stay managed.
// A touched level is consumed before attempt; errors/skips are not retried.
// At most one add-on attempt per tick; gapped-through extra levels are consumed/skipped.
input bool EnableFiboAddOns=true;
input int MaxAddOnsPerSetup=2;
int addOnsSubmitted=0;
bool primarySubmittedThisTick=false;
input double FiboLevel1=38.2;
input double FiboLevel2=50.0;
input double FiboLevel3=61.8;
input int MaxOpenPositions=3;
input double MaxTotalRiskPercent=3.0;
input int SignalExpiryBars=32;
struct FiboSignal {
 int direction;
 double price,ratio,atr,anchor,high,low;
 datetime created,expires;
 string names;
};
FiboSignal signal[];
double previousAsk=0,previousBid=0;
input bool EnableTrailingStop=true;
input double PercentTrailing=90.0;
input double StartPercentTrailing=40.0;
input double TrailingSpreadMultiplier=2.0;
input int TrailingStepPoints=1;
datetime trailingRetryAfter=0;
input bool WriteAuditCSV=true;
input bool PrintFilterSkips=false;
int auditHandle=INVALID_HANDLE;
long rejectedStructure=0,rejectedLevel=0,rejectedRisk=0,acceptedSignals=0;
datetime lastCloseAttempt=0;

MqlRates r[];
int rsiHandle=INVALID_HANDLE;
datetime lastBar=0;
string persistKey;
struct Signal { int direction; int span; string names; };
double Body(int s){return MathAbs(r[s].close-r[s].open);}
double Range(int s){return MathMax(r[s].high-r[s].low,_Point);}
double Top(int s){return MathMax(r[s].open,r[s].close);}
double Bottom(int s){return MathMin(r[s].open,r[s].close);}
double Upper(int s){return r[s].high-Top(s);}
double Lower(int s){return Bottom(s)-r[s].low;}
bool Bull(int s){return r[s].close>r[s].open;}
bool Bear(int s){return r[s].close<r[s].open;}
bool Small(int s){return Body(s)<=SmallBodyRatio*Range(s);}
bool Long(int s){return Body(s)>=LongBodyRatio*Range(s);}
bool Near(double a,double b,int s){return MathAbs(a-b)<=MatchRangeRatio*Range(s);}
bool PriorDown(int oldest){return !UseTrendContext || r[oldest+1].close<r[oldest+1+TrendBars].close;}
bool PriorUp(int oldest){return !UseTrendContext || r[oldest+1].close>r[oldest+1+TrendBars].close;}
bool LowerPin(int s){return Body(s)>DojiRatio*Range(s) && Small(s) && Lower(s)>=WickBodyRatio*Body(s) && Upper(s)<=0.15*Range(s);}
bool UpperPin(int s){return Body(s)>DojiRatio*Range(s) && Small(s) && Upper(s)>=WickBodyRatio*Body(s) && Lower(s)<=0.15*Range(s);}
bool InsideBody(int inner,int outer){return Top(inner)<=Top(outer) && Bottom(inner)>=Bottom(outer) && Body(inner)<Body(outer);}
bool BullEngulfRaw(int s){return Bull(s)&&Bear(s+1)&&r[s].open<=r[s+1].close&&r[s].close>=r[s+1].open&&Body(s)>Body(s+1);}
bool BearEngulfRaw(int s){return Bear(s)&&Bull(s+1)&&r[s].open>=r[s+1].close&&r[s].close<=r[s+1].open&&Body(s)>Body(s+1);}
bool BullHaramiRaw(int s){return Bull(s)&&Bear(s+1)&&Long(s+1)&&InsideBody(s,s+1);}
bool BearHaramiRaw(int s){return Bear(s)&&Bull(s+1)&&Long(s+1)&&InsideBody(s,s+1);}
bool OpenInside(int s,int older){return r[s].open>=Bottom(older)&&r[s].open<=Top(older);}

// Individual switches (Doji is neutral and does not open a trade).
input bool EnableDragonflyDoji=true;
input bool EnableGravestoneDoji=true;
input bool EnableHammer=true;
input bool EnableInvertedHammer=true;
input bool EnableHangingMan=true;
input bool EnableShootingStar=true;
input bool EnableBullishPinBar=true;
input bool EnableBearishPinBar=true;
input bool EnableBullishSpinningTop=true;
input bool EnableBearishSpinningTop=true;
input bool EnableBullishMarubozu=true;
input bool EnableBearishMarubozu=true;
input bool EnableBullishEngulfing=true;
input bool EnableBearishEngulfing=true;
input bool EnableBullishHarami=true;
input bool EnableBearishHarami=true;
input bool EnableBullishKicker=true;
input bool EnableBearishKicker=true;
input bool EnablePiercingLine=true;
input bool EnableDarkCloudCover=true;
input bool EnableTweezerBottom=true;
input bool EnableTweezerTop=true;
input bool EnableRisingWindow=true;
input bool EnableFallingWindow=true;
input bool EnableMorningStar=true;
input bool EnableEveningStar=true;
input bool EnableMorningDojiStar=true;
input bool EnableEveningDojiStar=true;
input bool EnableBullishAbandonedBaby=true;
input bool EnableBearishAbandonedBaby=true;
input bool EnableThreeWhiteSoldiers=true;
input bool EnableThreeBlackCrows=true;
input bool EnableIdenticalThreeCrows=true;
input bool EnableThreeInsideUp=true;
input bool EnableThreeInsideDown=true;
input bool EnableThreeOutsideUp=true;
input bool EnableThreeOutsideDown=true;
input bool EnableBullishThreeLineStrike=true;
input bool EnableBearishThreeLineStrike=true;
input bool EnableThreeStarsInSouth=true;
input bool EnableThreeStarsInNorth=true;

// Pattern recognition: s is the last completed candle of the pattern.
bool IsDoji(int s){return Body(s)<=DojiRatio*Range(s);}
bool IsDragonflyDoji(int s){return IsDoji(s)&&Lower(s)>=0.60*Range(s)&&Upper(s)<=0.15*Range(s)&&PriorDown(s);}
bool IsGravestoneDoji(int s){return IsDoji(s)&&Upper(s)>=0.60*Range(s)&&Lower(s)<=0.15*Range(s)&&PriorUp(s);}
bool IsHammer(int s){return LowerPin(s)&&PriorDown(s);}
bool IsInvertedHammer(int s){return UpperPin(s)&&PriorDown(s);}
bool IsHangingMan(int s){return LowerPin(s)&&PriorUp(s);}
bool IsShootingStar(int s){return UpperPin(s)&&PriorUp(s);}
bool IsBullishPinBar(int s){return LowerPin(s)&&PriorDown(s);}
bool IsBearishPinBar(int s){return UpperPin(s)&&PriorUp(s);}
bool IsBullishSpinningTop(int s){return Bull(s)&&Small(s)&&!IsDoji(s)&&Upper(s)>=Body(s)*0.5&&Lower(s)>=Body(s)*0.5&&PriorDown(s);}
bool IsBearishSpinningTop(int s){return Bear(s)&&Small(s)&&!IsDoji(s)&&Upper(s)>=Body(s)*0.5&&Lower(s)>=Body(s)*0.5&&PriorUp(s);}
bool IsBullishMarubozu(int s){return Bull(s)&&Body(s)>=0.90*Range(s);}
bool IsBearishMarubozu(int s){return Bear(s)&&Body(s)>=0.90*Range(s);}
bool IsBullishEngulfing(int s){return BullEngulfRaw(s)&&PriorDown(s+1);}
bool IsBearishEngulfing(int s){return BearEngulfRaw(s)&&PriorUp(s+1);}
bool IsBullishHarami(int s){return BullHaramiRaw(s)&&PriorDown(s+1);}
bool IsBearishHarami(int s){return BearHaramiRaw(s)&&PriorUp(s+1);}
bool IsBullishKicker(int s){return Bear(s+1)&&Long(s+1)&&Bull(s)&&Long(s)&&r[s].open>r[s+1].open;}
bool IsBearishKicker(int s){return Bull(s+1)&&Long(s+1)&&Bear(s)&&Long(s)&&r[s].open<r[s+1].open;}
bool IsPiercingLine(int s){return PriorDown(s+1)&&Bear(s+1)&&Long(s+1)&&Bull(s)&&r[s].open<=r[s+1].close&&r[s].close>(r[s+1].open+r[s+1].close)/2&&r[s].close<r[s+1].open;}
bool IsDarkCloudCover(int s){return PriorUp(s+1)&&Bull(s+1)&&Long(s+1)&&Bear(s)&&r[s].open>=r[s+1].close&&r[s].close<(r[s+1].open+r[s+1].close)/2&&r[s].close>r[s+1].open;}
bool IsTweezerBottom(int s){return PriorDown(s+1)&&Bear(s+1)&&Bull(s)&&Near(r[s].low,r[s+1].low,s+1);}
bool IsTweezerTop(int s){return PriorUp(s+1)&&Bull(s+1)&&Bear(s)&&Near(r[s].high,r[s+1].high,s+1);}
bool IsRisingWindow(int s){return r[s].low>r[s+1].high&&Bull(s);}
bool IsFallingWindow(int s){return r[s].high<r[s+1].low&&Bear(s);}
bool IsMorningStar(int s){return PriorDown(s+2)&&Bear(s+2)&&Long(s+2)&&Small(s+1)&&Bull(s)&&Long(s)&&r[s].close>(r[s+2].open+r[s+2].close)/2&&Bottom(s+1)<Bottom(s+2)&&(!StrictGaps||(Top(s+1)<Bottom(s+2)&&Bottom(s)>Top(s+1)));}
bool IsEveningStar(int s){return PriorUp(s+2)&&Bull(s+2)&&Long(s+2)&&Small(s+1)&&Bear(s)&&Long(s)&&r[s].close<(r[s+2].open+r[s+2].close)/2&&Top(s+1)>Top(s+2)&&(!StrictGaps||(Bottom(s+1)>Top(s+2)&&Top(s)<Bottom(s+1)));}
bool IsMorningDojiStar(int s){return IsMorningStar(s)&&IsDoji(s+1);}
bool IsEveningDojiStar(int s){return IsEveningStar(s)&&IsDoji(s+1);}
bool IsBullishAbandonedBaby(int s){return IsMorningDojiStar(s)&&r[s+1].high<r[s+2].low&&r[s].low>r[s+1].high;}
bool IsBearishAbandonedBaby(int s){return IsEveningDojiStar(s)&&r[s+1].low>r[s+2].high&&r[s].high<r[s+1].low;}
bool IsThreeWhiteSoldiers(int s){return PriorDown(s+2)&&Bull(s+2)&&Bull(s+1)&&Bull(s)&&Long(s+2)&&Long(s+1)&&Long(s)&&r[s].close>r[s+1].close&&r[s+1].close>r[s+2].close&&OpenInside(s,s+1)&&OpenInside(s+1,s+2)&&Upper(s)<0.2*Range(s)&&Upper(s+1)<0.2*Range(s+1)&&Upper(s+2)<0.2*Range(s+2);}
bool IsThreeBlackCrows(int s){return PriorUp(s+2)&&Bear(s+2)&&Bear(s+1)&&Bear(s)&&Long(s+2)&&Long(s+1)&&Long(s)&&r[s].close<r[s+1].close&&r[s+1].close<r[s+2].close&&OpenInside(s,s+1)&&OpenInside(s+1,s+2)&&Lower(s)<0.2*Range(s)&&Lower(s+1)<0.2*Range(s+1)&&Lower(s+2)<0.2*Range(s+2);}
bool IsIdenticalThreeCrows(int s){return IsThreeBlackCrows(s)&&Near(r[s].open,r[s+1].close,s+1)&&Near(r[s+1].open,r[s+2].close,s+2);}
bool IsThreeInsideUp(int s){return BullHaramiRaw(s+1)&&PriorDown(s+2)&&Bull(s)&&r[s].close>r[s+2].open;}
bool IsThreeInsideDown(int s){return BearHaramiRaw(s+1)&&PriorUp(s+2)&&Bear(s)&&r[s].close<r[s+2].open;}
bool IsThreeOutsideUp(int s){return BullEngulfRaw(s+1)&&PriorDown(s+2)&&Bull(s)&&r[s].close>r[s+1].close;}
bool IsThreeOutsideDown(int s){return BearEngulfRaw(s+1)&&PriorUp(s+2)&&Bear(s)&&r[s].close<r[s+1].close;}
bool IsBullishThreeLineStrike(int s){return Bear(s+3)&&Bear(s+2)&&Bear(s+1)&&r[s+1].close<r[s+2].close&&r[s+2].close<r[s+3].close&&Bull(s)&&r[s].open<=r[s+1].close&&r[s].close>r[s+3].open;}
bool IsBearishThreeLineStrike(int s){return Bull(s+3)&&Bull(s+2)&&Bull(s+1)&&r[s+1].close>r[s+2].close&&r[s+2].close>r[s+3].close&&Bear(s)&&r[s].open>=r[s+1].close&&r[s].close<r[s+3].open;}
bool IsThreeStarsInSouth(int s){return PriorDown(s+2)&&Bear(s+2)&&Bear(s+1)&&Bear(s)&&Body(s+2)>Body(s+1)&&Body(s+1)>Body(s)&&Lower(s+2)>Body(s+2)*0.5&&r[s+1].low>r[s+2].low&&r[s].low>r[s+1].low&&r[s].high<r[s+1].high&&Lower(s)<0.15*Range(s)&&Upper(s)<0.15*Range(s);}
bool IsThreeStarsInNorth(int s){return PriorUp(s+2)&&Bull(s+2)&&Bull(s+1)&&Bull(s)&&Body(s+2)>Body(s+1)&&Body(s+1)>Body(s)&&Upper(s+2)>Body(s+2)*0.5&&r[s+1].high<r[s+2].high&&r[s].high<r[s+1].high&&r[s].low>r[s+1].low&&Lower(s)<0.15*Range(s)&&Upper(s)<0.15*Range(s);}

// CHART HEURISTICS: closed bars only, no centered pivot on unclosed data.
input bool EnableDoubleBottom=true;
input bool EnableDoubleTop=true;
input bool EnableFallingWedge=true;
input bool EnableRisingWedge=true;
input bool EnableBullFlag=true;
input bool EnableBearFlag=true;
input bool EnableCupAndHandle=true;
input bool EnableBullishVTurn=true;
input bool EnableBearishVTurn=true;
input bool EnableBullishUTurn=true;
input bool EnableBearishUTurn=true;
input bool EnableDemandZone=true;
input bool EnableSupplyZone=true;
input bool EnableBullishHiddenDivergence=true;
input bool EnableBearishHiddenDivergence=true;
double Highest(int start,int count){double v=r[start].high;for(int i=start+1;i<start+count;i++)v=MathMax(v,r[i].high);return v;}
double Lowest(int start,int count){double v=r[start].low;for(int i=start+1;i<start+count;i++)v=MathMin(v,r[i].low);return v;}
bool PivotLow(int s){return r[s].low<r[s-1].low&&r[s].low<r[s-2].low&&r[s].low<=r[s+1].low&&r[s].low<=r[s+2].low;}
bool PivotHigh(int s){return r[s].high>r[s-1].high&&r[s].high>r[s-2].high&&r[s].high>=r[s+1].high&&r[s].high>=r[s+2].high;}
bool TwoPivots(int s,bool lows,int &a,int &b){a=-1;b=-1;for(int i=s+3;i<s+ChartWindow-2;i++){if(lows?PivotLow(i):PivotHigh(i)){if(a<0)a=i;else if(i-a>=4){b=i;return true;}}}return false;}
// Two confirmed pivots within 10% of window range; entry on neckline cross.
bool IsDoubleBottom(int s){int a,b;if(!TwoPivots(s,true,a,b))return false;double neck=Highest(a,b-a+1);double tol=(Highest(s+1,ChartWindow)-Lowest(s+1,ChartWindow))*0.10;return MathAbs(r[a].low-r[b].low)<=tol&&neck-MathMax(r[a].low,r[b].low)>2*tol&&r[s].close>neck&&r[s+1].close<=neck;}
bool IsDoubleTop(int s){int a,b;if(!TwoPivots(s,false,a,b))return false;double neck=Lowest(a,b-a+1);double tol=(Highest(s+1,ChartWindow)-Lowest(s+1,ChartWindow))*0.10;return MathAbs(r[a].high-r[b].high)<=tol&&MathMin(r[a].high,r[b].high)-neck>2*tol&&r[s].close<neck&&r[s+1].close>=neck;}
// Regression of candle highs/lows; x increases from oldest to newest.
void Fit(int start,int n,bool highs,double &slope,double &intercept){double sx=0,sy=0,sxx=0,sxy=0;for(int x=0;x<n;x++){int i=start+n-1-x;double y=highs?r[i].high:r[i].low;sx+=x;sy+=y;sxx+=x*x;sxy+=x*y;}slope=(n*sxy-sx*sy)/(n*sxx-sx*sx);intercept=(sy-slope*sx)/n;}
bool Wedge(int s,bool falling){int n=ChartWindow;double h,hi,l,li;Fit(s+1,n,true,h,hi);Fit(s+1,n,false,l,li);double old=hi-li,now=(hi+h*(n-1))-(li+l*(n-1));if(old<=0||now<=0||now>=old*0.75)return false;return falling?(h<l&&l<0&&r[s].close>hi+h*n&&r[s+1].close<=hi+h*(n-1)):(l>h&&h>0&&r[s].close<li+l*n&&r[s+1].close>=li+l*(n-1));}
bool IsFallingWedge(int s){return Wedge(s,true);}
bool IsRisingWedge(int s){return Wedge(s,false);}
// Flag: half-window pole, shallow opposite-slope channel, breakout.
bool Flag(int s,bool up){int n=ChartWindow/2;double h,hi,l,li;Fit(s+1,n,true,h,hi);Fit(s+1,n,false,l,li);double pole=r[s+n+1].close-r[s+2*n].close;double width=Highest(s+1,n)-Lowest(s+1,n);if(width<=0||MathAbs(h-l)*n>width*0.4||MathAbs(pole)<2*width)return false;return up?(pole>0&&h<0&&l<0&&r[s].close>Highest(s+1,n)&&r[s+1].close<=hi+h*(n-1)):(pole<0&&h>0&&l>0&&r[s].close<Lowest(s+1,n)&&r[s+1].close>=li+l*(n-1));}
bool IsBullFlag(int s){return Flag(s,true);}
bool IsBearFlag(int s){return Flag(s,false);}
// Cup: matching rims around a deep central low; right-hand shallow handle.
bool IsCupAndHandle(int s){int n=ChartWindow,q=n/4;double left=Highest(s+3*q,q),right=Highest(s+q,q),base=Lowest(s+2*q,q),depth=MathMin(left,right)-base;if(depth<=0||MathAbs(left-right)>depth*0.25)return false;double handle=Lowest(s+1,q-1);return handle>right-depth*0.40&&handle<right&&r[s].close>MathMax(left,right)&&r[s+1].close<=MathMax(left,right);}
// V: 3 directional closes each side of the turning point, reclaim midpoint.
bool IsBullishVTurn(int s){return r[s+6].close>r[s+5].close&&r[s+5].close>r[s+4].close&&r[s+4].close>r[s+3].close&&r[s+3].close<r[s+2].close&&r[s+2].close<r[s+1].close&&r[s+1].close<r[s].close&&r[s].close>(r[s+6].close+r[s+3].close)/2;}
bool IsBearishVTurn(int s){return r[s+6].close<r[s+5].close&&r[s+5].close<r[s+4].close&&r[s+4].close<r[s+3].close&&r[s+3].close>r[s+2].close&&r[s+2].close>r[s+1].close&&r[s+1].close>r[s].close&&r[s].close<(r[s+6].close+r[s+3].close)/2;}
// U: four-block closing-price averages form rounded base/top; rim cross.
bool UTurn(int s,bool up){int q=ChartWindow/4;double a=0,b=0,c=0,d=0;for(int i=0;i<q;i++){a+=r[s+1+i].close;b+=r[s+1+q+i].close;c+=r[s+1+2*q+i].close;d+=r[s+1+3*q+i].close;}a/=q;b/=q;c/=q;d/=q;double depth=up?MathMin(a,d)-MathMax(b,c):MathMin(b,c)-MathMax(a,d);if(depth<=0||MathAbs(b-c)>depth*0.5)return false;double rim=up?Highest(s+1+3*q,q):Lowest(s+1+3*q,q);return up?(r[s].close>rim&&r[s+1].close<=rim):(r[s].close<rim&&r[s+1].close>=rim);}
bool IsBullishUTurn(int s){return UTurn(s,true);}
bool IsBearishUTurn(int s){return UTurn(s,false);}
// Demand/supply: 1-3 small base candles before strong departure; first retest.
bool Zone(int s,bool demand){for(int dep=s+3;dep<s+ChartWindow-4;dep++){if(!(Long(dep)&&(demand?Bull(dep):Bear(dep))))continue;for(int n=1;n<=3;n++){bool base=true;for(int j=1;j<=n;j++)if(!Small(dep+j))base=false;if(!base)continue;double hi=Highest(dep+1,n),lo=Lowest(dep+1,n);if(demand?r[dep].close<=hi:r[dep].close>=lo)continue;bool fresh=true;for(int j=dep-1;j>s;j++)if(demand?r[j].low<=hi:r[j].high>=lo){fresh=false;break;}if(fresh&&(demand?(r[s].low<=hi&&r[s].low>=lo&&r[s].close>hi&&Bull(s)):(r[s].high>=lo&&r[s].high<=hi&&r[s].close<lo&&Bear(s))))return true;}}return false;}
bool IsDemandZone(int s){return Zone(s,true);}
bool IsSupplyZone(int s){return Zone(s,false);}
// RSI at two confirmed pivots: higher price low/lower RSI low, or mirror.
// Trigger only when the newest pivot has just become confirmed.
bool HiddenDivergence(int s,bool bullish){int a,b;if(!TwoPivots(s,bullish,a,b)||a!=s+3)return false;double va[1],vb[1];if(CopyBuffer(rsiHandle,0,a,1,va)!=1||CopyBuffer(rsiHandle,0,b,1,vb)!=1)return false;if(va[0]==EMPTY_VALUE||vb[0]==EMPTY_VALUE)return false;return bullish?(r[a].low>r[b].low&&va[0]<vb[0]&&Bull(s)):(r[a].high<r[b].high&&va[0]>vb[0]&&Bear(s));}
bool IsBullishHiddenDivergence(int s){return HiddenDivergence(s,true);}
bool IsBearishHiddenDivergence(int s){return HiddenDivergence(s,false);}

void AddSignal(Signal &buy,Signal &sell,int direction,int span,string name){if(direction>0){buy.direction=1;buy.span=MathMax(buy.span,span);if(buy.names!="")buy.names+=",";buy.names+=name;}else{sell.direction=-1;sell.span=MathMax(sell.span,span);if(sell.names!="")sell.names+=",";sell.names+=name;}}
bool NameInList(string list,string name){return StringFind(","+list+",",","+name+",")>=0;}
bool PatternEnabled(string name,bool enabled){
 if(SinglePattern!="")return name==SinglePattern;
 if(!enabled)return false;
 if(PatternSet==PATTERNS_CORE)return NameInList("Hammer,ShootingStar,BullishEngulfing,BearishEngulfing,BullishHarami,BearishHarami,MorningStar,EveningStar",name);
 if(name=="BullishPinBar"&&EnableHammer)return false;
 if(name=="BearishPinBar"&&EnableShootingStar)return false;
 return true;
}

void DetectSignals(Signal &buy,Signal &sell){
 buy.direction=0;buy.span=0;buy.names="";sell.direction=0;sell.span=0;sell.names="";
 if(PatternEnabled("DragonflyDoji",EnableDragonflyDoji)&&IsDragonflyDoji(2)&&Bull(1)&&r[1].close>r[2].high)AddSignal(buy,sell,1,2,"DragonflyDoji");
 if(PatternEnabled("GravestoneDoji",EnableGravestoneDoji)&&IsGravestoneDoji(2)&&Bear(1)&&r[1].close<r[2].low)AddSignal(buy,sell,-1,2,"GravestoneDoji");
 if(PatternEnabled("Hammer",EnableHammer)&&IsHammer(2)&&Bull(1)&&r[1].close>r[2].high)AddSignal(buy,sell,1,2,"Hammer");
 if(PatternEnabled("InvertedHammer",EnableInvertedHammer)&&IsInvertedHammer(2)&&Bull(1)&&r[1].close>r[2].high)AddSignal(buy,sell,1,2,"InvertedHammer");
 if(PatternEnabled("HangingMan",EnableHangingMan)&&IsHangingMan(2)&&Bear(1)&&r[1].close<r[2].low)AddSignal(buy,sell,-1,2,"HangingMan");
 if(PatternEnabled("ShootingStar",EnableShootingStar)&&IsShootingStar(2)&&Bear(1)&&r[1].close<r[2].low)AddSignal(buy,sell,-1,2,"ShootingStar");
 if(PatternEnabled("BullishPinBar",EnableBullishPinBar)&&IsBullishPinBar(2)&&Bull(1)&&r[1].close>r[2].high)AddSignal(buy,sell,1,2,"BullishPinBar");
 if(PatternEnabled("BearishPinBar",EnableBearishPinBar)&&IsBearishPinBar(2)&&Bear(1)&&r[1].close<r[2].low)AddSignal(buy,sell,-1,2,"BearishPinBar");
 if(PatternEnabled("BullishSpinningTop",EnableBullishSpinningTop)&&IsBullishSpinningTop(2)&&Bull(1)&&r[1].close>r[2].high)AddSignal(buy,sell,1,2,"BullishSpinningTop");
 if(PatternEnabled("BearishSpinningTop",EnableBearishSpinningTop)&&IsBearishSpinningTop(2)&&Bear(1)&&r[1].close<r[2].low)AddSignal(buy,sell,-1,2,"BearishSpinningTop");
 if(PatternEnabled("BullishMarubozu",EnableBullishMarubozu)&&IsBullishMarubozu(1))AddSignal(buy,sell,1,1,"BullishMarubozu");
 if(PatternEnabled("BearishMarubozu",EnableBearishMarubozu)&&IsBearishMarubozu(1))AddSignal(buy,sell,-1,1,"BearishMarubozu");
 if(PatternEnabled("BullishEngulfing",EnableBullishEngulfing)&&IsBullishEngulfing(1))AddSignal(buy,sell,1,2,"BullishEngulfing");
 if(PatternEnabled("BearishEngulfing",EnableBearishEngulfing)&&IsBearishEngulfing(1))AddSignal(buy,sell,-1,2,"BearishEngulfing");
 if(PatternEnabled("BullishHarami",EnableBullishHarami)&&(ConfirmHaramiTweezer?(IsBullishHarami(2)&&Bull(1)&&r[1].close>Highest(2,2)):IsBullishHarami(1)))AddSignal(buy,sell,1,ConfirmHaramiTweezer?3:2,"BullishHarami");
 if(PatternEnabled("BearishHarami",EnableBearishHarami)&&(ConfirmHaramiTweezer?(IsBearishHarami(2)&&Bear(1)&&r[1].close<Lowest(2,2)):IsBearishHarami(1)))AddSignal(buy,sell,-1,ConfirmHaramiTweezer?3:2,"BearishHarami");
 if(PatternEnabled("BullishKicker",EnableBullishKicker)&&IsBullishKicker(1))AddSignal(buy,sell,1,2,"BullishKicker");
 if(PatternEnabled("BearishKicker",EnableBearishKicker)&&IsBearishKicker(1))AddSignal(buy,sell,-1,2,"BearishKicker");
 if(PatternEnabled("PiercingLine",EnablePiercingLine)&&IsPiercingLine(1))AddSignal(buy,sell,1,2,"PiercingLine");
 if(PatternEnabled("DarkCloudCover",EnableDarkCloudCover)&&IsDarkCloudCover(1))AddSignal(buy,sell,-1,2,"DarkCloudCover");
 if(PatternEnabled("TweezerBottom",EnableTweezerBottom)&&(ConfirmHaramiTweezer?(IsTweezerBottom(2)&&Bull(1)&&r[1].close>Highest(2,2)):IsTweezerBottom(1)))AddSignal(buy,sell,1,ConfirmHaramiTweezer?3:2,"TweezerBottom");
 if(PatternEnabled("TweezerTop",EnableTweezerTop)&&(ConfirmHaramiTweezer?(IsTweezerTop(2)&&Bear(1)&&r[1].close<Lowest(2,2)):IsTweezerTop(1)))AddSignal(buy,sell,-1,ConfirmHaramiTweezer?3:2,"TweezerTop");
 if(PatternEnabled("RisingWindow",EnableRisingWindow)&&IsRisingWindow(1))AddSignal(buy,sell,1,2,"RisingWindow");
 if(PatternEnabled("FallingWindow",EnableFallingWindow)&&IsFallingWindow(1))AddSignal(buy,sell,-1,2,"FallingWindow");
 if(PatternEnabled("MorningStar",EnableMorningStar)&&IsMorningStar(1))AddSignal(buy,sell,1,3,"MorningStar");
 if(PatternEnabled("EveningStar",EnableEveningStar)&&IsEveningStar(1))AddSignal(buy,sell,-1,3,"EveningStar");
 if(PatternEnabled("MorningDojiStar",EnableMorningDojiStar)&&IsMorningDojiStar(1))AddSignal(buy,sell,1,3,"MorningDojiStar");
 if(PatternEnabled("EveningDojiStar",EnableEveningDojiStar)&&IsEveningDojiStar(1))AddSignal(buy,sell,-1,3,"EveningDojiStar");
 if(PatternEnabled("BullishAbandonedBaby",EnableBullishAbandonedBaby)&&IsBullishAbandonedBaby(1))AddSignal(buy,sell,1,3,"BullishAbandonedBaby");
 if(PatternEnabled("BearishAbandonedBaby",EnableBearishAbandonedBaby)&&IsBearishAbandonedBaby(1))AddSignal(buy,sell,-1,3,"BearishAbandonedBaby");
 if(PatternEnabled("ThreeWhiteSoldiers",EnableThreeWhiteSoldiers)&&IsThreeWhiteSoldiers(1))AddSignal(buy,sell,1,3,"ThreeWhiteSoldiers");
 if(PatternEnabled("ThreeBlackCrows",EnableThreeBlackCrows)&&IsThreeBlackCrows(1))AddSignal(buy,sell,-1,3,"ThreeBlackCrows");
 if(PatternEnabled("IdenticalThreeCrows",EnableIdenticalThreeCrows)&&IsIdenticalThreeCrows(1))AddSignal(buy,sell,-1,3,"IdenticalThreeCrows");
 if(PatternEnabled("ThreeInsideUp",EnableThreeInsideUp)&&IsThreeInsideUp(1))AddSignal(buy,sell,1,3,"ThreeInsideUp");
 if(PatternEnabled("ThreeInsideDown",EnableThreeInsideDown)&&IsThreeInsideDown(1))AddSignal(buy,sell,-1,3,"ThreeInsideDown");
 if(PatternEnabled("ThreeOutsideUp",EnableThreeOutsideUp)&&IsThreeOutsideUp(1))AddSignal(buy,sell,1,3,"ThreeOutsideUp");
 if(PatternEnabled("ThreeOutsideDown",EnableThreeOutsideDown)&&IsThreeOutsideDown(1))AddSignal(buy,sell,-1,3,"ThreeOutsideDown");
 if(PatternEnabled("BullishThreeLineStrike",EnableBullishThreeLineStrike)&&IsBullishThreeLineStrike(1))AddSignal(buy,sell,1,4,"BullishThreeLineStrike");
 if(PatternEnabled("BearishThreeLineStrike",EnableBearishThreeLineStrike)&&IsBearishThreeLineStrike(1))AddSignal(buy,sell,-1,4,"BearishThreeLineStrike");
 if(PatternEnabled("ThreeStarsInSouth",EnableThreeStarsInSouth)&&IsThreeStarsInSouth(1))AddSignal(buy,sell,1,3,"ThreeStarsInSouth");
 if(PatternEnabled("ThreeStarsInNorth",EnableThreeStarsInNorth)&&IsThreeStarsInNorth(1))AddSignal(buy,sell,-1,3,"ThreeStarsInNorth");
 if(EnableChartPatterns){
  if(PatternEnabled("DoubleBottom",EnableDoubleBottom)&&IsDoubleBottom(1))AddSignal(buy,sell,1,ChartWindow+1,"DoubleBottom");
  if(PatternEnabled("DoubleTop",EnableDoubleTop)&&IsDoubleTop(1))AddSignal(buy,sell,-1,ChartWindow+1,"DoubleTop");
  if(PatternEnabled("FallingWedge",EnableFallingWedge)&&IsFallingWedge(1))AddSignal(buy,sell,1,ChartWindow+1,"FallingWedge");
  if(PatternEnabled("RisingWedge",EnableRisingWedge)&&IsRisingWedge(1))AddSignal(buy,sell,-1,ChartWindow+1,"RisingWedge");
  if(PatternEnabled("BullFlag",EnableBullFlag)&&IsBullFlag(1))AddSignal(buy,sell,1,ChartWindow+1,"BullFlag");
  if(PatternEnabled("BearFlag",EnableBearFlag)&&IsBearFlag(1))AddSignal(buy,sell,-1,ChartWindow+1,"BearFlag");
  if(PatternEnabled("CupAndHandle",EnableCupAndHandle)&&IsCupAndHandle(1))AddSignal(buy,sell,1,ChartWindow+1,"CupAndHandle");
  if(PatternEnabled("BullishVTurn",EnableBullishVTurn)&&IsBullishVTurn(1))AddSignal(buy,sell,1,ChartWindow+1,"BullishVTurn");
  if(PatternEnabled("BearishVTurn",EnableBearishVTurn)&&IsBearishVTurn(1))AddSignal(buy,sell,-1,ChartWindow+1,"BearishVTurn");
  if(PatternEnabled("BullishUTurn",EnableBullishUTurn)&&IsBullishUTurn(1))AddSignal(buy,sell,1,ChartWindow+1,"BullishUTurn");
  if(PatternEnabled("BearishUTurn",EnableBearishUTurn)&&IsBearishUTurn(1))AddSignal(buy,sell,-1,ChartWindow+1,"BearishUTurn");
  if(PatternEnabled("DemandZone",EnableDemandZone)&&IsDemandZone(1))AddSignal(buy,sell,1,ChartWindow+1,"DemandZone");
  if(PatternEnabled("SupplyZone",EnableSupplyZone)&&IsSupplyZone(1))AddSignal(buy,sell,-1,ChartWindow+1,"SupplyZone");
  if(PatternEnabled("BullishHiddenDivergence",EnableBullishHiddenDivergence)&&IsBullishHiddenDivergence(1))AddSignal(buy,sell,1,ChartWindow+1,"BullishHiddenDivergence");
  if(PatternEnabled("BearishHiddenDivergence",EnableBearishHiddenDivergence)&&IsBearishHiddenDivergence(1))AddSignal(buy,sell,-1,ChartWindow+1,"BearishHiddenDivergence");
 }
}

double TickRound(double price,bool upwards){double step=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);if(step<=0)return 0;return NormalizeDouble((upwards?MathCeil(price/step):MathFloor(price/step))*step,_Digits);}
bool TradeAllowed(int dir){
 if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)||!MQLInfoInteger(MQL_TRADE_ALLOWED)||!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED)||!AccountInfoInteger(ACCOUNT_TRADE_EXPERT))return false;
 long mode=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_MODE);
 if(mode==SYMBOL_TRADE_MODE_DISABLED||mode==SYMBOL_TRADE_MODE_CLOSEONLY)return false;
 if(dir>0&&mode==SYMBOL_TRADE_MODE_SHORTONLY)return false;
 if(dir<0&&mode==SYMBOL_TRADE_MODE_LONGONLY)return false;
 long flags=SymbolInfoInteger(_Symbol,SYMBOL_ORDER_MODE);
 return (flags&SYMBOL_ORDER_MARKET)!=0&&(flags&SYMBOL_ORDER_SL)!=0&&(flags&SYMBOL_ORDER_TP)!=0;
}
double RiskVolume(ENUM_ORDER_TYPE type,double entry,double stop,double budgetPercent,double remainingVolume){
 double minLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN),maxLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX),step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
 if(minLot<=0||step<=0||maxLot<minLot)return 0;
 double profit=0;if(!OrderCalcProfit(type,_Symbol,minLot,entry,stop,profit)||profit>=0)return 0;
 double budget=AccountInfoDouble(ACCOUNT_EQUITY)*budgetPercent/100.0;
 double raw=budget/(-profit)*minLot;
 maxLot=MathMin(maxLot,remainingVolume);
 double limit=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_LIMIT);
 if(limit>0)maxLot=MathMin(maxLot,limit);
 double volume=NormalizeDouble(MathFloor(MathMin(raw,maxLot)/step)*step,8);
 if(volume<minLot)return 0; // Never round UP to broker minimum beyond budget.
 double actual=0;if(!OrderCalcProfit(type,_Symbol,volume,entry,stop,actual)||actual>=0||-actual>budget+0.01)return 0;
 double margin=0;if(!OrderCalcMargin(type,_Symbol,volume,entry,margin)||margin>AccountInfoDouble(ACCOUNT_MARGIN_FREE)*0.95)return 0;
 return volume;
}
bool HasSymbolExposure(){
 for(int i=PositionsTotal()-1;i>=0;i--){ulong t=PositionGetTicket(i);if(t!=0&&PositionGetString(POSITION_SYMBOL)==_Symbol)return true;}
 for(int i=OrdersTotal()-1;i>=0;i--){ulong t=OrderGetTicket(i);if(t!=0&&OrderGetString(ORDER_SYMBOL)==_Symbol)return true;}
 return false;
}
bool ExecutePrimary(Signal &setup,double &initialSL){
 initialSL=0;
 if(WeekendEntryBlocked())return false;
 if(HasSymbolExposure()||!TradeAllowed(setup.direction))return false;
 MqlTick tick;if(!SymbolInfoTick(_Symbol,tick)||tick.ask<=0||tick.bid<=0||tick.ask<tick.bid)return false;
 if((tick.ask-tick.bid)/_Point>MaxSpreadPoints){Print("Skip: spread exceeds limit");return false;}
 bool buy=setup.direction>0;
 double entry=buy?tick.ask:tick.bid;
 double atr=MeanATR();if(atr<=0)return false;
 if(MathAbs(entry-r[1].close)>MaxEntryDriftATR*atr){rejectedRisk++;return false;}
 if(!ContextAllowed(setup,atr))return false;
 double tickSize=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);if(tickSize<=0)return false;
 double minimum=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL)*_Point+tickSize;
 double buffer=MathMax(StopBufferPoints*_Point,ATRStopBuffer*atr);
 double stop=buy?Lowest(1,setup.span)-buffer:Highest(1,setup.span)+buffer;
 stop=buy?MathMin(stop,entry-MinStopATR*atr):MathMax(stop,entry+MinStopATR*atr);
 stop=buy?MathMin(stop,tick.bid-minimum):MathMax(stop,tick.ask+minimum);
 stop=TickRound(stop,!buy);
 double distance=buy?entry-stop:stop-entry;if(distance<=0||stop<=0)return false;
 if(distance>MaxStopATR*atr||(tick.ask-tick.bid)>MaxSpreadToStop*distance){rejectedRisk++;return false;}
 double target=buy?entry+RewardRisk*distance:entry-RewardRisk*distance;
 target=buy?MathMax(target,tick.bid+minimum):MathMin(target,tick.ask-minimum);
 target=TickRound(target,buy);if(target<=0)return false;
 ENUM_ORDER_TYPE type=buy?ORDER_TYPE_BUY:ORDER_TYPE_SELL;
 double volume=RiskVolume(type,entry,stop,MathMin(RiskPercent,MaxTotalRiskPercent),SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX));if(volume<=0){Print("Skip: risk volume below minimum, invalid calculation, or insufficient margin");return false;}
 string comment=StringSubstr("PA5:M:"+setup.names,0,31);
 bool sent=buy?trade.Buy(volume,_Symbol,0,stop,target,comment):trade.Sell(volume,_Symbol,0,stop,target,comment);
 uint code=trade.ResultRetcode();
 if(sent&&(code==TRADE_RETCODE_DONE||code==TRADE_RETCODE_DONE_PARTIAL||code==TRADE_RETCODE_PLACED)){
  if(persistKey!=""){GlobalVariableSet(persistKey,(double)r[0].time);GlobalVariablesFlush();}
  initialSL=stop;primarySubmittedThisTick=true;acceptedSignals++;
  double estimated=0;OrderCalcProfit(type,_Symbol,volume,entry,stop,estimated);
  Audit("SIGNAL_ACCEPT",trade.ResultOrder(),trade.ResultDeal(),0,setup.names,volume,entry,stop,target,estimated,
        StringFormat("dir=%d;equity=%.2f;ATR=%.5f",setup.direction,AccountInfoDouble(ACCOUNT_EQUITY),atr));
  PrintFormat("Accepted %s volume=%.8f SL=%.*f TP=%.*f patterns=%s retcode=%u",buy?"BUY":"SELL",volume,_Digits,stop,_Digits,target,setup.names,code);
  return true;
 }else PrintFormat("Order rejected retcode=%u %s",code,trade.ResultRetcodeDescription());
 return false;
}
void HandlePrimarySetup(Signal &setup,const MqlTick &tick){
 double initialSL=0;
 if(ExecutePrimary(setup,initialSL)){
  ClearSignals("new primary accepted");addOnsSubmitted=0;
  if(EnableFiboAddOns)BuildFiboSignals(setup,tick,initialSL);
 }
}
int OnInit(){
 if(MaxAddOnsPerSetup<0||MaxAddOnsPerSetup>99)return INIT_PARAMETERS_INCORRECT;

 if(AccountInfoInteger(ACCOUNT_MARGIN_MODE)!=ACCOUNT_MARGIN_MODE_RETAIL_HEDGING){Print("PA5 requires a HEDGING account for separate multiple positions.");return INIT_FAILED;}
 if(FiboLevel1<=0||FiboLevel1>=100||FiboLevel2<=0||FiboLevel2>=100||FiboLevel3<=0||FiboLevel3>=100||MaxOpenPositions<1||MaxOpenPositions>100||MaxTotalRiskPercent<=0||MaxTotalRiskPercent>100||SignalExpiryBars<1||SignalExpiryBars>10000)return INIT_PARAMETERS_INCORRECT;
 ArrayResize(signal,0);previousAsk=0;previousBid=0;

 if(StartPercentTrailing<=0||StartPercentTrailing>=100||PercentTrailing<StartPercentTrailing||PercentTrailing>=100||TrailingSpreadMultiplier<0||TrailingStepPoints<1)return INIT_PARAMETERS_INCORRECT;
 if(StructureLookback<20||StructureLookback>1000||ATRPeriod<2||ATRPeriod>200||LevelToleranceATR<=0||ATRStopBuffer<0||MinStopATR<=0||MaxStopATR<MinStopATR||MaxSpreadToStop<=0||MaxSpreadToStop>1||MaxEntryDriftATR<=0||FridayNoEntryHour<0||FridayNoEntryHour>23||FridayCloseHour<FridayNoEntryHour||FridayCloseHour>23)return INIT_PARAMETERS_INCORRECT;
 if(SinglePattern!=""&&!NameInList("DragonflyDoji,GravestoneDoji,Hammer,InvertedHammer,HangingMan,ShootingStar,BullishPinBar,BearishPinBar,BullishSpinningTop,BearishSpinningTop,BullishMarubozu,BearishMarubozu,BullishEngulfing,BearishEngulfing,BullishHarami,BearishHarami,BullishKicker,BearishKicker,PiercingLine,DarkCloudCover,TweezerBottom,TweezerTop,RisingWindow,FallingWindow,MorningStar,EveningStar,MorningDojiStar,EveningDojiStar,BullishAbandonedBaby,BearishAbandonedBaby,ThreeWhiteSoldiers,ThreeBlackCrows,IdenticalThreeCrows,ThreeInsideUp,ThreeInsideDown,ThreeOutsideUp,ThreeOutsideDown,BullishThreeLineStrike,BearishThreeLineStrike,ThreeStarsInSouth,ThreeStarsInNorth,DoubleBottom,DoubleTop,FallingWedge,RisingWedge,BullFlag,BearFlag,CupAndHandle,BullishVTurn,BearishVTurn,BullishUTurn,BearishUTurn,DemandZone,SupplyZone,BullishHiddenDivergence,BearishHiddenDivergence",SinglePattern)){Print("Unknown SinglePattern: ",SinglePattern);return INIT_PARAMETERS_INCORRECT;}
 if(SinglePattern!=""&&NameInList("DoubleBottom,DoubleTop,FallingWedge,RisingWedge,BullFlag,BearFlag,CupAndHandle,BullishVTurn,BearishVTurn,BullishUTurn,BearishUTurn,DemandZone,SupplyZone,BullishHiddenDivergence,BearishHiddenDivergence",SinglePattern)&&!EnableChartPatterns){Print("Single chart pattern requires EnableChartPatterns=true");return INIT_PARAMETERS_INCORRECT;}

 if(RiskPercent<=0||RiskPercent>100||RewardRisk<=0||StopBufferPoints<0||MaxSpreadPoints<0||DeviationPoints<0||TrendBars<2||TrendBars>500||ChartWindow<16||ChartWindow>200||RSIPeriod<2||RSIPeriod>100||DojiRatio<=0||DojiRatio>=SmallBodyRatio||SmallBodyRatio>=LongBodyRatio||LongBodyRatio>=1||WickBodyRatio<1||MatchRangeRatio<=0||MatchRangeRatio>0.5)return INIT_PARAMETERS_INCORRECT;
 ArraySetAsSeries(r,true);
 trade.SetExpertMagicNumber(Magic);trade.SetDeviationInPoints(DeviationPoints);trade.SetAsyncMode(false);trade.SetMarginMode();
 if(!trade.SetTypeFillingBySymbol(_Symbol))return INIT_FAILED;
 rsiHandle=iRSI(_Symbol,Timeframe,RSIPeriod,PRICE_CLOSE);if(rsiHandle==INVALID_HANDLE)return INIT_FAILED;
 // Hash symbol/server keeps terminal-global name under the 63-char limit.
 uint hash=2166136261;string id=_Symbol+AccountInfoString(ACCOUNT_SERVER);
 for(int i=0;i<StringLen(id);i++){hash^=(uint)StringGetCharacter(id,i);hash*=16777619;}
 int tf=(Timeframe==PERIOD_CURRENT)?(int)_Period:(int)Timeframe;
 persistKey=StringFormat("PA5.%I64d.%I64u.%u.%d",AccountInfoInteger(ACCOUNT_LOGIN),Magic,hash,tf);
 // Tester runs must not reuse terminal persistence from other test passes.
 if(MQLInfoInteger(MQL_TESTER))persistKey="";
 lastBar=iTime(_Symbol,Timeframe,0);
 OpenAudit();
 Print("PriceActionPatternsEA v5 ready. Chart heuristics=",EnableChartPatterns,". Source requires broker-specific backtesting.");
 return INIT_SUCCEEDED;
}
void OnDeinit(const int reason){
 PrintFormat("PA5 SUMMARY accepted=%I64d structure_reject=%I64d level_reject=%I64d risk_reject=%I64d",acceptedSignals,rejectedStructure,rejectedLevel,rejectedRisk);
 if(auditHandle!=INVALID_HANDLE){FileFlush(auditHandle);FileClose(auditHandle);auditHandle=INVALID_HANDLE;}
 if(rsiHandle!=INVALID_HANDLE)IndicatorRelease(rsiHandle);Comment("");
}
void OnTick(){
 primarySubmittedThisTick=false;
 ManageWeekendExit();TrailingStop();
 MqlTick tick;if(!SymbolInfoTick(_Symbol,tick)||tick.bid<=0||tick.ask<tick.bid)return;
 if(WeekendEntryBlocked()){
  ClearSignals("weekend");previousAsk=tick.ask;previousBid=tick.bid;return;
 }
 datetime now=iTime(_Symbol,Timeframe,0);
 if(now!=0&&now!=lastBar){
  int required=ChartWindow+TrendBars+RSIPeriod+StructureLookback+ATRPeriod+40;
  if(CopyRates(_Symbol,Timeframe,0,required,r)==required&&r[0].time==now){
   bool ready=!EnableChartPatterns||(!EnableBullishHiddenDivergence&&!EnableBearishHiddenDivergence)||BarsCalculated(rsiHandle)>=required;
   if(ready){
    lastBar=now;
    Signal buy,sell;DetectSignals(buy,sell);
    if(buy.direction!=0&&sell.direction!=0)ClearSignals("conflicting new setup");
    else if(buy.direction!=0)HandlePrimarySetup(buy,tick);
    else if(sell.direction!=0)HandlePrimarySetup(sell,tick);
   }
  }
 }
 if(!primarySubmittedThisTick)ProcessFiboSignals(tick);
 previousAsk=tick.ask;previousBid=tick.bid;
 Comment("PA5 waiting Fibo levels: ",ArraySize(signal)," / max positions: ",MaxOpenPositions);
}

// V2 FILTERS AND AUDIT -------------------------------------------------
double MeanATR(){
 double sum=0;
 for(int i=1;i<=ATRPeriod;i++)sum+=MathMax(r[i].high-r[i].low,MathMax(MathAbs(r[i].high-r[i+1].close),MathAbs(r[i].low-r[i+1].close)));
 return sum/ATRPeriod;
}
// All pivot confirmation candles precede the ENTIRE signal window.
// The latest allowed confirmation index is span+1 (pivot at span+3).
bool ContextAllowed(Signal &signal,double atr){
 if(!UseStructureFilter&&!UseLevelFilter)return true;
 int highs[2],lows[2];highs[0]=-1;highs[1]=-1;lows[0]=-1;lows[1]=-1;
 int nh=0,nl=0;bool nearLevel=false;
 double extreme=signal.direction>0?Lowest(1,signal.span):Highest(1,signal.span);
 for(int i=signal.span+3;i<signal.span+3+StructureLookback;i++){
  bool ph=PivotHigh(i),pl=PivotLow(i);
  if(ph&&nh<2){highs[nh]=i;nh++;}
  if(pl&&nl<2){lows[nl]=i;nl++;}
  if(signal.direction>0&&pl&&r[1].close>r[i].low&&MathAbs(extreme-r[i].low)<=LevelToleranceATR*atr)nearLevel=true;
  if(signal.direction<0&&ph&&r[1].close<r[i].high&&MathAbs(extreme-r[i].high)<=LevelToleranceATR*atr)nearLevel=true;
 }
 if(UseStructureFilter){
  bool trend=false;
  if(nh==2&&nl==2)trend=signal.direction>0?
   (r[highs[0]].high>r[highs[1]].high&&r[lows[0]].low>r[lows[1]].low):
   (r[highs[0]].high<r[highs[1]].high&&r[lows[0]].low<r[lows[1]].low);
  if(!trend){rejectedStructure++;if(PrintFilterSkips)Print("PA5 skip: prior swing structure ",signal.names);return false;}
 }
 if(UseLevelFilter&&!nearLevel){rejectedLevel++;if(PrintFilterSkips)Print("PA5 skip: no nearby prior swing level ",signal.names);return false;}
 return true;
}
bool WeekendEntryBlocked(){
 if(!UseWeekendGuard)return false;
 MqlDateTime dt;TimeToStruct(TimeCurrent(),dt);
 return dt.day_of_week==0||dt.day_of_week==6||(dt.day_of_week==5&&dt.hour>=FridayNoEntryHour);
}
void ManageWeekendExit(){
 if(!UseWeekendGuard)return;
 MqlDateTime dt;datetime now=TimeCurrent();TimeToStruct(now,dt);
 bool due=dt.day_of_week==0||dt.day_of_week==6||(dt.day_of_week==5&&dt.hour>=FridayCloseHour);
 if(!due||now-lastCloseAttempt<30)return;
 if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)||!MQLInfoInteger(MQL_TRADE_ALLOWED)||!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED)||!AccountInfoInteger(ACCOUNT_TRADE_EXPERT))return;
 lastCloseAttempt=now;
 // Ticket overload closes exactly the selected own position on hedging accounts.
 for(int i=PositionsTotal()-1;i>=0;i--){
  ulong ticket=PositionGetTicket(i);
  if(ticket==0||PositionGetString(POSITION_SYMBOL)!=_Symbol||(ulong)PositionGetInteger(POSITION_MAGIC)!=Magic)continue;
  ulong positionID=(ulong)PositionGetInteger(POSITION_IDENTIFIER);
  bool ok=trade.PositionClose(ticket);uint rc=trade.ResultRetcode();
  Audit("WEEKEND_CLOSE",trade.ResultOrder(),trade.ResultDeal(),positionID,"",0,0,0,0,0,StringFormat("ticket=%I64u;ok=%d;retcode=%u",ticket,(int)ok,rc));
  if(!ok||(rc!=TRADE_RETCODE_DONE&&rc!=TRADE_RETCODE_DONE_PARTIAL&&rc!=TRADE_RETCODE_PLACED))Print("PA5 weekend close failed: ",ticket," ",trade.ResultRetcodeDescription());
 }
 for(int i=OrdersTotal()-1;i>=0;i--){
  ulong ticket=OrderGetTicket(i);
  if(ticket==0||OrderGetString(ORDER_SYMBOL)!=_Symbol||(ulong)OrderGetInteger(ORDER_MAGIC)!=Magic)continue;
  ENUM_ORDER_TYPE kind=(ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
  if(kind==ORDER_TYPE_BUY||kind==ORDER_TYPE_SELL)continue;
  if(!trade.OrderDelete(ticket)||trade.ResultRetcode()!=TRADE_RETCODE_DONE)Print("PA5 pending delete failed: ",ticket," ",trade.ResultRetcodeDescription());
 }
}
void OpenAudit(){
 if(!WriteAuditCSV||MQLInfoInteger(MQL_OPTIMIZATION))return;
 string symbol=_Symbol;StringReplace(symbol,"/","_");StringReplace(symbol,"\\","_");StringReplace(symbol,":","_");
 string file=StringFormat("PA5_%s_%I64u_%I64d_%I64u.csv",symbol,Magic,(long)TimeLocal(),GetMicrosecondCount());
 auditHandle=FileOpen(file,FILE_WRITE|FILE_CSV|FILE_ANSI,';');
 if(auditHandle==INVALID_HANDLE){Print("PA5 cannot open CSV; error=",GetLastError());return;}
 FileWrite(auditHandle,"event","server_time","order","deal","position","patterns","volume","price","sl","tp","amount_account_currency","note");FileFlush(auditHandle);
 Print("PA5 audit CSV: ",TerminalInfoString(TERMINAL_DATA_PATH),"\\MQL5\\Files\\",file);
}
void Audit(string event,ulong order,ulong deal,ulong position,string patterns,double volume,double price,double sl,double tp,double amount,string note){
 PrintFormat("PA5 %s order=%I64u deal=%I64u position=%I64u patterns=%s amount=%.2f %s",event,order,deal,position,patterns,amount,note);
 if(auditHandle==INVALID_HANDLE)return;
 FileWrite(auditHandle,event,TimeToString(TimeCurrent(),TIME_DATE|TIME_SECONDS),order,deal,position,patterns,DoubleToString(volume,8),DoubleToString(price,_Digits),DoubleToString(sl,_Digits),DoubleToString(tp,_Digits),DoubleToString(amount,2),note);FileFlush(auditHandle);
}
void OnTradeTransaction(const MqlTradeTransaction &trans,const MqlTradeRequest &request,const MqlTradeResult &result){
 if(trans.type!=TRADE_TRANSACTION_DEAL_ADD||trans.deal==0||!HistoryDealSelect(trans.deal))return;
 if(HistoryDealGetString(trans.deal,DEAL_SYMBOL)!=_Symbol||(ulong)HistoryDealGetInteger(trans.deal,DEAL_MAGIC)!=Magic)return;
 ulong order=(ulong)HistoryDealGetInteger(trans.deal,DEAL_ORDER),position=(ulong)HistoryDealGetInteger(trans.deal,DEAL_POSITION_ID);
 double net=HistoryDealGetDouble(trans.deal,DEAL_PROFIT)+HistoryDealGetDouble(trans.deal,DEAL_COMMISSION)+HistoryDealGetDouble(trans.deal,DEAL_SWAP)+HistoryDealGetDouble(trans.deal,DEAL_FEE);
 // Each deal appears once: includes partial fills, entry costs and exit costs.
 // Recover planned SL/TP from the order when available; full names are in SIGNAL_ACCEPT.
 double sl=0,tp=0;if(HistoryOrderSelect(order)){sl=HistoryOrderGetDouble(order,ORDER_SL);tp=HistoryOrderGetDouble(order,ORDER_TP);}
 string note=StringFormat("entry=%d;reason=%d;comment=%s",(int)HistoryDealGetInteger(trans.deal,DEAL_ENTRY),(int)HistoryDealGetInteger(trans.deal,DEAL_REASON),HistoryDealGetString(trans.deal,DEAL_COMMENT));
 if(HistoryDealGetInteger(trans.deal,DEAL_ENTRY)==DEAL_ENTRY_IN&&sl>0){
  ENUM_ORDER_TYPE type=HistoryDealGetInteger(trans.deal,DEAL_TYPE)==DEAL_TYPE_BUY?ORDER_TYPE_BUY:ORDER_TYPE_SELL;
  double stopRisk=0;
  if(OrderCalcProfit(type,_Symbol,HistoryDealGetDouble(trans.deal,DEAL_VOLUME),HistoryDealGetDouble(trans.deal,DEAL_PRICE),sl,stopRisk))note+=StringFormat(";fill_to_SL_estimate=%.2f",stopRisk);
 }
 Audit("DEAL",order,trans.deal,position,"",HistoryDealGetDouble(trans.deal,DEAL_VOLUME),HistoryDealGetDouble(trans.deal,DEAL_PRICE),sl,tp,net,note);
}

// Pure calculation separated from terminal access for deterministic testing.
bool CalculateTrailingSL(bool buy,double open,double sl,double tp,double bid,double ask,
                         double tickSize,double stopsDistance,double freezeDistance,
                         double &nextSL,int &stage){
 nextSL=sl;stage=0;
 if(open<=0||tp<=0||bid<=0||ask<bid||tickSize<=0)return false;
 double total=buy?tp-open:open-tp;
 double current=buy?bid:ask;
 if(total<=0)return false; // Missing or incorrectly directed TP.
 double progress=(buy?current-open:open-current)/total;
 if(progress<StartPercentTrailing/100.0||progress>=1.0)return false;
 // Conservatively skip modification when existing SL or TP is frozen.
 if(freezeDistance>0){
  if(MathAbs(tp-current)<=freezeDistance)return false;
  if(sl>0&&MathAbs(current-sl)<=freezeDistance)return false;
 }
 double lock=buy?open+(ask-bid)*TrailingSpreadMultiplier:open-(ask-bid)*TrailingSpreadMultiplier;
 double candidate=lock;stage=1;
 if(progress>=PercentTrailing/100.0){
  double follow=2.0*current-tp;
  candidate=buy?MathMax(lock,follow):MathMin(lock,follow);stage=2;
 }
 double distance=MathMax(stopsDistance,freezeDistance)+tickSize;
 // If the intended lock itself is not legal yet, wait; never lock a loss instead.
 if(buy){
  if(lock>bid-distance)return false;
  candidate=MathMin(candidate,bid-distance);
  candidate=MathFloor(candidate/tickSize+1e-9)*tickSize;
 }else{
  if(lock<ask+distance)return false;
  candidate=MathMax(candidate,ask+distance);
  candidate=MathCeil(candidate/tickSize-1e-9)*tickSize;
 }
 if(candidate<=0||(buy?candidate<open:candidate>open))return false;
 double minStep=MathMax(tickSize,TrailingStepPoints*_Point);
 if(sl>0&&(buy?candidate-sl:sl-candidate)<minStep-tickSize*1e-6)return false;
 // Final directional validation after tick rounding.
 if(buy?(bid-candidate<stopsDistance||candidate>=bid):(candidate-ask<stopsDistance||candidate<=ask))return false;
 nextSL=candidate;return true;
}
void TrailingStop(){
 if(!EnableTrailingStop||TimeCurrent()<trailingRetryAfter)return;
 if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)||!MQLInfoInteger(MQL_TRADE_ALLOWED)||
    !AccountInfoInteger(ACCOUNT_TRADE_ALLOWED)||!AccountInfoInteger(ACCOUNT_TRADE_EXPERT))return;
 for(int i=PositionsTotal()-1;i>=0;i--){
  ulong ticket=PositionGetTicket(i);
  if(ticket==0||!PositionSelectByTicket(ticket))continue;
  if(PositionGetString(POSITION_SYMBOL)!=_Symbol||(ulong)PositionGetInteger(POSITION_MAGIC)!=Magic)continue;
  MqlTick tick;if(!SymbolInfoTick(_Symbol,tick))continue;
  double step=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
  double stops=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL)*_Point;
  double freeze=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_FREEZE_LEVEL)*_Point;
  double open=PositionGetDouble(POSITION_PRICE_OPEN),sl=PositionGetDouble(POSITION_SL),tp=PositionGetDouble(POSITION_TP);
  double volume=PositionGetDouble(POSITION_VOLUME);
  ulong positionID=(ulong)PositionGetInteger(POSITION_IDENTIFIER);
  bool buy=PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY;
  double nextSL=0;int stage=0;
  if(!CalculateTrailingSL(buy,open,sl,tp,tick.bid,tick.ask,step,stops,freeze,nextSL,stage))continue;
  nextSL=NormalizeDouble(nextSL,_Digits);
  bool ok=trade.PositionModify(ticket,nextSL,tp);uint code=trade.ResultRetcode();
  if(ok&&code==TRADE_RETCODE_DONE){
   Audit(stage==1?"TRAIL_LOCK":"TRAIL_FOLLOW",0,0,positionID,"",volume,buy?tick.bid:tick.ask,nextSL,tp,0,
         StringFormat("ticket=%I64u;old_SL=%.*f",ticket,_Digits,sl));
  }else if(code!=TRADE_RETCODE_NO_CHANGES){
   trailingRetryAfter=TimeCurrent()+2;
   Audit("TRAIL_REJECT",0,0,positionID,"",volume,buy?tick.bid:tick.ask,nextSL,tp,0,
         StringFormat("ticket=%I64u;retcode=%u;%s",ticket,code,trade.ResultRetcodeDescription()));
   return;
  }
 }
}

// V4 FIBONACCI QUEUE --------------------------------------------------
void ClearSignals(string reason){
 if(ArraySize(signal)>0)Print("PA5 QUEUE_CLEAR ",reason," count=",ArraySize(signal));
 ArrayResize(signal,0);
}
void RemoveSignal(int index){
 int n=ArraySize(signal);if(index<0||index>=n)return;
 for(int j=index;j<n-1;j++)signal[j]=signal[j+1];
 ArrayResize(signal,n-1);
}
double FiboPrice(int direction,double high,double low,double percent){
 return direction>0?high-(high-low)*percent/100.0:low+(high-low)*percent/100.0;
}
bool FindLatestLeg(int direction,double &high,double &low){
 int tip=-1;
 // Pivot at shift 3 has both confirming bars closed (shifts 2 and 1).
 for(int i=3;i<StructureLookback+3;i++){
  if(tip<0){if(direction>0?PivotHigh(i):PivotLow(i))tip=i;}
  else if(direction>0?PivotLow(i):PivotHigh(i)){
   high=direction>0?r[tip].high:r[i].high;
   low=direction>0?r[i].low:r[tip].low;
   return high>low;
  }
 }
 return false;
}
void BuildFiboSignals(Signal &setup,const MqlTick &tick,double initialSL){
 double atr=MeanATR();if(atr<=0||!ContextAllowed(setup,atr))return;
 // A qualified setup replaces the previous queue, even if no usable leg exists.
 ClearSignals("qualified new setup");
 double high=0,low=0;if(!FindLatestLeg(setup.direction,high,low))return;
 double ratios[3];ratios[0]=FiboLevel1;ratios[1]=FiboLevel2;ratios[2]=FiboLevel3;
 // Shallow retracement first, independent of input ordering.
 for(int i=0;i<2;i++)for(int j=i+1;j<3;j++)if(ratios[j]<ratios[i]){double tmp=ratios[i];ratios[i]=ratios[j];ratios[j]=tmp;}
 double step=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);if(step<=0)return;
 for(int i=0;i<3;i++){
  double price=TickRound(FiboPrice(setup.direction,high,low,ratios[i]),setup.direction<0);
  double current=setup.direction>0?tick.ask:tick.bid;
  // Do not backfill levels already crossed before this setup was created.
  if(setup.direction>0?current<price-step*0.5:current>price+step*0.5)continue;
  bool duplicate=false;for(int j=0;j<ArraySize(signal);j++)if(MathAbs(signal[j].price-price)<step*0.5)duplicate=true;
  if(duplicate)continue;
  int n=ArraySize(signal);if(ArrayResize(signal,n+1)!=n+1)break;
  signal[n].direction=setup.direction;signal[n].price=price;signal[n].ratio=ratios[i];
  signal[n].atr=atr;signal[n].high=high;signal[n].low=low;
  signal[n].anchor=initialSL; // Original primary SL, fixed for queued add-ons.
  signal[n].created=TimeCurrent();signal[n].expires=TimeCurrent()+(long)SignalExpiryBars*PeriodSeconds(Timeframe);
  signal[n].names=setup.names;
  Audit("QUEUE_ADD",0,0,0,setup.names,0,price,0,0,0,StringFormat("dir=%d;fibo=%.1f;high=%.*f;low=%.*f",setup.direction,ratios[i],_Digits,high,_Digits,low));
 }
 // Reset cross baseline so old ticks cannot trigger newly-created levels.
 previousAsk=tick.ask;previousBid=tick.bid;
}
bool FiboTouched(int direction,double level,double previous,double current,double tolerance){
 if(MathAbs(current-level)<=tolerance)return true;
 if(previous<=0)return false;
 return direction>0?(previous>level&&current<=level):(previous<level&&current>=level);
}
// Returns capacity for this symbol/magic, accounting for all own positions.
// Block foreign positions to avoid competing strategies; outstanding orders wait.
bool EntryCapacity(int direction,double &budgetPercent,double &remainingVolume){
 double equity=AccountInfoDouble(ACCOUNT_EQUITY);if(equity<=0)return false;
 double usedRisk=0,usedVolume=0;int count=0;
 for(int i=OrdersTotal()-1;i>=0;i--){if(OrderGetTicket(i)!=0&&OrderGetString(ORDER_SYMBOL)==_Symbol)return false;}
 for(int i=PositionsTotal()-1;i>=0;i--){
  if(PositionGetTicket(i)==0||PositionGetString(POSITION_SYMBOL)!=_Symbol)continue;
  if((ulong)PositionGetInteger(POSITION_MAGIC)!=Magic)return false;
  count++;
  bool buy=PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY;
  if((direction>0)==buy)usedVolume+=PositionGetDouble(POSITION_VOLUME);
  double sl=PositionGetDouble(POSITION_SL),profit=0;if(sl<=0)return false;
  if(!OrderCalcProfit(buy?ORDER_TYPE_BUY:ORDER_TYPE_SELL,_Symbol,PositionGetDouble(POSITION_VOLUME),PositionGetDouble(POSITION_PRICE_OPEN),sl,profit))return false;
  usedRisk+=MathMax(0.0,-profit);
 }
 if(count>=MaxOpenPositions)return false;
 budgetPercent=MathMin(RiskPercent,MaxTotalRiskPercent-usedRisk/equity*100.0);
 double limit=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_LIMIT);
 remainingVolume=limit>0?MathMax(0.0,limit-usedVolume):SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
 return budgetPercent>0&&remainingVolume>0;
}
void ExecuteFiboSignal(FiboSignal &item){
 double budget=0,volumeLeft=0;
 if(!TradeAllowed(item.direction)||!EntryCapacity(item.direction,budget,volumeLeft)){
  Print("PA5 QUEUE_SKIP capacity/trade permission at ",item.price);return;
 }
 MqlTick tick;if(!SymbolInfoTick(_Symbol,tick))return;
 bool buy=item.direction>0;double entry=buy?tick.ask:tick.bid;
 double step=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
 if(step<=0||tick.bid<=0||tick.ask<tick.bid)return;
 if((tick.ask-tick.bid)/_Point>MaxSpreadPoints||MathAbs(entry-item.price)>MaxEntryDriftATR*item.atr){Print("PA5 QUEUE_SKIP spread/drift");return;}
 // Reject a broken leg instead of opening beyond the protective swing.
 if(buy?tick.bid<=item.low:tick.ask>=item.high){Print("PA5 QUEUE_SKIP broken swing");return;}
 // Keep the initial primary SL; no widening for add-ons.
 double minimum=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL)*_Point+step;
 double sl=item.anchor;
 if(buy?sl>tick.bid-minimum:sl<tick.ask+minimum){Print("PA5 QUEUE_SKIP original SL too close/invalid");return;}
 double distance=buy?entry-sl:sl-entry;
 if(sl<=0||distance<MinStopATR*item.atr||distance>MaxStopATR*item.atr||(tick.ask-tick.bid)>MaxSpreadToStop*distance){Print("PA5 QUEUE_SKIP stop distance");return;}
 double tp=buy?entry+RewardRisk*distance:entry-RewardRisk*distance;
 tp=buy?MathMax(tp,tick.bid+minimum):MathMin(tp,tick.ask-minimum);tp=TickRound(tp,buy);if(tp<=0)return;
 ENUM_ORDER_TYPE type=buy?ORDER_TYPE_BUY:ORDER_TYPE_SELL;
 double volume=RiskVolume(type,entry,sl,budget,volumeLeft);
 if(volume<=0){Print("PA5 QUEUE_SKIP volume/margin/risk");return;}
 string comment=StringSubstr(StringFormat("PA5:F%.1f:",item.ratio)+item.names,0,31);
 bool ok=buy?trade.Buy(volume,_Symbol,0,sl,tp,comment):trade.Sell(volume,_Symbol,0,sl,tp,comment);
 uint code=trade.ResultRetcode();double risk=0;OrderCalcProfit(type,_Symbol,volume,entry,sl,risk);
 if(ok&&(code==TRADE_RETCODE_DONE||code==TRADE_RETCODE_DONE_PARTIAL||code==TRADE_RETCODE_PLACED)){
  acceptedSignals++;addOnsSubmitted++;
  Audit("SIGNAL_ACCEPT",trade.ResultOrder(),trade.ResultDeal(),0,item.names,volume,entry,sl,tp,risk,StringFormat("fibo=%.1f;level=%.*f;budget_pct=%.3f",item.ratio,_Digits,item.price,budget));
 }else Audit("QUEUE_ORDER_REJECT",trade.ResultOrder(),trade.ResultDeal(),0,item.names,volume,entry,sl,tp,risk,trade.ResultRetcodeDescription());
}
void ProcessFiboSignals(const MqlTick &tick){
 if(!EnableFiboAddOns||addOnsSubmitted>=MaxAddOnsPerSetup){ClearSignals("add-ons disabled or setup limit");return;}
 bool ownPosition=false;
 for(int p=PositionsTotal()-1;p>=0;p--)if(PositionGetTicket(p)!=0&&PositionGetString(POSITION_SYMBOL)==_Symbol&&(ulong)PositionGetInteger(POSITION_MAGIC)==Magic){ownPosition=true;break;}
 if(!ownPosition){ClearSignals("basket flat");return;}

 double step=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);if(step<=0)return;
 bool attempted=false;int i=0;
 while(i<ArraySize(signal)){
  FiboSignal item=signal[i];
  if(TimeCurrent()>=item.expires||(item.direction>0?tick.bid<=item.low:tick.ask>=item.high)){
   Print("PA5 QUEUE_REMOVE expired/broken swing level=",item.price);RemoveSignal(i);continue;
  }
  double current=item.direction>0?tick.ask:tick.bid,previous=item.direction>0?previousAsk:previousBid;
  if(!FiboTouched(item.direction,item.price,previous,current,step*0.5)){i++;continue;}
  // Consume first: server rejection or a price gap must not cause repeated entry.
  RemoveSignal(i);
  Audit("QUEUE_TOUCH",0,0,0,item.names,0,current,0,0,0,StringFormat("fibo=%.1f;level=%.*f",item.ratio,_Digits,item.price));
  if(!attempted){attempted=true;ExecuteFiboSignal(item);}
  else Print("PA5 QUEUE_SKIP additional level crossed in same tick: ",item.price);
 }
}
