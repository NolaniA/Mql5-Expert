// PriceActionPatternsEA v3.00 -- source only; compile and backtest in MT5.
// INSTALL: MQL5/Experts/PriceActionPatternsEA.mq5 -> MetaEditor F7.
// Chart timeframe by default. All detection uses CLOSED candles (s>=1).
// Each pattern has its own Is... function and Enable... input.
// Candle reversal context: close before pattern vs close TrendBars earlier.
// Chart patterns are explicit heuristic approximations, disabled by default.
// No claimed win rates from the supplied posters are used.
// RiskPercent estimates loss at SL, excluding commissions, gaps and slippage.
// Existing positions/orders on this symbol block entry, including other EAs.
// Friday time exit added in v2. No martingale or recovery. V3 adds percentage trailing.
// Pattern timestamps processed once, persisted after accepted orders.
// Restart while flat skips the already-open bar. Use unique Magic per instance.
// Single-candle reversals require the following candle to close beyond high/low.
// Stars: StrictGaps=false permits continuous FX candles; true requires body gaps.
// Three Line Strike here means the FOURTH engulfing candle's reversal direction.
// Three Stars North is a mirrored South heuristic, not a standardized definition.
// Wedge/Flag/Cup/U/V/Demand/Supply and divergence definitions appear below.
#property strict
#property version "3.00"
#property description "PA v3: percentage trailing, swing filters, ATR stops, Friday exit"
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

bool HasSymbolExposure(){
 for(int i=PositionsTotal()-1;i>=0;i--){ulong t=PositionGetTicket(i);if(t!=0&&PositionGetString(POSITION_SYMBOL)==_Symbol)return true;}
 for(int i=OrdersTotal()-1;i>=0;i--){ulong t=OrderGetTicket(i);if(t!=0&&OrderGetString(ORDER_SYMBOL)==_Symbol)return true;}
 return false;
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
double RiskVolume(ENUM_ORDER_TYPE type,double entry,double stop){
 double minLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN),maxLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX),step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
 if(minLot<=0||step<=0||maxLot<minLot)return 0;
 double profit=0;if(!OrderCalcProfit(type,_Symbol,minLot,entry,stop,profit)||profit>=0)return 0;
 double budget=AccountInfoDouble(ACCOUNT_EQUITY)*RiskPercent/100.0;
 double raw=budget/(-profit)*minLot;
 double limit=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_LIMIT);
 if(limit>0)maxLot=MathMin(maxLot,limit);
 double volume=NormalizeDouble(MathFloor(MathMin(raw,maxLot)/step)*step,8);
 if(volume<minLot)return 0; // Never round UP to broker minimum beyond budget.
 double actual=0;if(!OrderCalcProfit(type,_Symbol,volume,entry,stop,actual)||actual>=0||-actual>budget+0.01)return 0;
 double margin=0;if(!OrderCalcMargin(type,_Symbol,volume,entry,margin)||margin>AccountInfoDouble(ACCOUNT_MARGIN_FREE)*0.95)return 0;
 return volume;
}
void ExecuteSignal(Signal &signal){
 if(WeekendEntryBlocked())return;
 if(HasSymbolExposure()||!TradeAllowed(signal.direction))return;
 MqlTick tick;if(!SymbolInfoTick(_Symbol,tick)||tick.ask<=0||tick.bid<=0||tick.ask<tick.bid)return;
 if((tick.ask-tick.bid)/_Point>MaxSpreadPoints){Print("Skip: spread exceeds limit");return;}
 bool buy=signal.direction>0;
 double entry=buy?tick.ask:tick.bid;
 double atr=MeanATR();if(atr<=0)return;
 if(MathAbs(entry-r[1].close)>MaxEntryDriftATR*atr){rejectedRisk++;return;}
 if(!ContextAllowed(signal,atr))return;
 double tickSize=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);if(tickSize<=0)return;
 double minimum=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL)*_Point+tickSize;
 double buffer=MathMax(StopBufferPoints*_Point,ATRStopBuffer*atr);
 double stop=buy?Lowest(1,signal.span)-buffer:Highest(1,signal.span)+buffer;
 stop=buy?MathMin(stop,entry-MinStopATR*atr):MathMax(stop,entry+MinStopATR*atr);
 stop=buy?MathMin(stop,tick.bid-minimum):MathMax(stop,tick.ask+minimum);
 stop=TickRound(stop,!buy);
 double distance=buy?entry-stop:stop-entry;if(distance<=0||stop<=0)return;
 if(distance>MaxStopATR*atr||(tick.ask-tick.bid)>MaxSpreadToStop*distance){rejectedRisk++;return;}
 double target=buy?entry+RewardRisk*distance:entry-RewardRisk*distance;
 target=buy?MathMax(target,tick.bid+minimum):MathMin(target,tick.ask-minimum);
 target=TickRound(target,buy);if(target<=0)return;
 ENUM_ORDER_TYPE type=buy?ORDER_TYPE_BUY:ORDER_TYPE_SELL;
 double volume=RiskVolume(type,entry,stop);if(volume<=0){Print("Skip: risk volume below minimum, invalid calculation, or insufficient margin");return;}
 string comment=StringSubstr("PA3:"+signal.names,0,31);
 bool sent=buy?trade.Buy(volume,_Symbol,0,stop,target,comment):trade.Sell(volume,_Symbol,0,stop,target,comment);
 uint code=trade.ResultRetcode();
 if(sent&&(code==TRADE_RETCODE_DONE||code==TRADE_RETCODE_DONE_PARTIAL||code==TRADE_RETCODE_PLACED)){
  if(persistKey!=""){GlobalVariableSet(persistKey,(double)r[0].time);GlobalVariablesFlush();}
  acceptedSignals++;
  double estimated=0;OrderCalcProfit(type,_Symbol,volume,entry,stop,estimated);
  Audit("SIGNAL_ACCEPT",trade.ResultOrder(),trade.ResultDeal(),0,signal.names,volume,entry,stop,target,estimated,
        StringFormat("dir=%d;equity=%.2f;ATR=%.5f",signal.direction,AccountInfoDouble(ACCOUNT_EQUITY),atr));
  PrintFormat("Accepted %s volume=%.8f SL=%.*f TP=%.*f patterns=%s retcode=%u",buy?"BUY":"SELL",volume,_Digits,stop,_Digits,target,signal.names,code);
 }else PrintFormat("Order rejected retcode=%u %s",code,trade.ResultRetcodeDescription());
}
int OnInit(){
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
 persistKey=StringFormat("PA3.%I64d.%I64u.%u.%d",AccountInfoInteger(ACCOUNT_LOGIN),Magic,hash,tf);
 // Tester runs must not reuse terminal persistence from other test passes.
 if(MQLInfoInteger(MQL_TESTER))persistKey="";
 lastBar=iTime(_Symbol,Timeframe,0);
 OpenAudit();
 Print("PriceActionPatternsEA v3 ready. Chart heuristics=",EnableChartPatterns,". Source requires broker-specific backtesting.");
 return INIT_SUCCEEDED;
}
void OnDeinit(const int reason){
 PrintFormat("PA3 SUMMARY accepted=%I64d structure_reject=%I64d level_reject=%I64d risk_reject=%I64d",acceptedSignals,rejectedStructure,rejectedLevel,rejectedRisk);
 if(auditHandle!=INVALID_HANDLE){FileFlush(auditHandle);FileClose(auditHandle);auditHandle=INVALID_HANDLE;}
 if(rsiHandle!=INVALID_HANDLE)IndicatorRelease(rsiHandle);Comment("");
}
void OnTick(){
 ManageWeekendExit();
 TrailingStop(); // Must run before weekend-entry and new-bar return gates.
 if(WeekendEntryBlocked())return;
 datetime now=iTime(_Symbol,Timeframe,0);if(now==0||now==lastBar)return;
 int required=ChartWindow+TrendBars+RSIPeriod+StructureLookback+ATRPeriod+40;
 if(CopyRates(_Symbol,Timeframe,0,required,r)!=required)return;
 if(r[0].time!=now)return;
 if(EnableChartPatterns&&(EnableBullishHiddenDivergence||EnableBearishHiddenDivergence)&&BarsCalculated(rsiHandle)<required)return;
 lastBar=now;
 if(persistKey!=""&&GlobalVariableCheck(persistKey)&&(datetime)GlobalVariableGet(persistKey)>=now)return;
 Signal buy,sell;DetectSignals(buy,sell);
 Comment("PA BUY: ",buy.names,"\nPA SELL: ",sell.names,"\nChart patterns: ",EnableChartPatterns?"ON":"OFF");
 if(buy.direction!=0&&sell.direction!=0){Print("Skip conflicting signals: ",buy.names," | ",sell.names);return;}
 if(buy.direction!=0)ExecuteSignal(buy);else if(sell.direction!=0)ExecuteSignal(sell);
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
  if(!trend){rejectedStructure++;if(PrintFilterSkips)Print("PA3 skip: prior swing structure ",signal.names);return false;}
 }
 if(UseLevelFilter&&!nearLevel){rejectedLevel++;if(PrintFilterSkips)Print("PA3 skip: no nearby prior swing level ",signal.names);return false;}
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
  if(!ok||(rc!=TRADE_RETCODE_DONE&&rc!=TRADE_RETCODE_DONE_PARTIAL&&rc!=TRADE_RETCODE_PLACED))Print("PA3 weekend close failed: ",ticket," ",trade.ResultRetcodeDescription());
 }
 for(int i=OrdersTotal()-1;i>=0;i--){
  ulong ticket=OrderGetTicket(i);
  if(ticket==0||OrderGetString(ORDER_SYMBOL)!=_Symbol||(ulong)OrderGetInteger(ORDER_MAGIC)!=Magic)continue;
  ENUM_ORDER_TYPE kind=(ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
  if(kind==ORDER_TYPE_BUY||kind==ORDER_TYPE_SELL)continue;
  if(!trade.OrderDelete(ticket)||trade.ResultRetcode()!=TRADE_RETCODE_DONE)Print("PA3 pending delete failed: ",ticket," ",trade.ResultRetcodeDescription());
 }
}
void OpenAudit(){
 if(!WriteAuditCSV||MQLInfoInteger(MQL_OPTIMIZATION))return;
 string symbol=_Symbol;StringReplace(symbol,"/","_");StringReplace(symbol,"\\","_");StringReplace(symbol,":","_");
 string file=StringFormat("PA3_%s_%I64u_%I64d_%I64u.csv",symbol,Magic,(long)TimeLocal(),GetMicrosecondCount());
 auditHandle=FileOpen(file,FILE_WRITE|FILE_CSV|FILE_ANSI,';');
 if(auditHandle==INVALID_HANDLE){Print("PA3 cannot open CSV; error=",GetLastError());return;}
 FileWrite(auditHandle,"event","server_time","order","deal","position","patterns","volume","price","sl","tp","amount_account_currency","note");FileFlush(auditHandle);
 Print("PA3 audit CSV: ",TerminalInfoString(TERMINAL_DATA_PATH),"\\MQL5\\Files\\",file);
}
void Audit(string event,ulong order,ulong deal,ulong position,string patterns,double volume,double price,double sl,double tp,double amount,string note){
 PrintFormat("PA3 %s order=%I64u deal=%I64u position=%I64u patterns=%s amount=%.2f %s",event,order,deal,position,patterns,amount,note);
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
