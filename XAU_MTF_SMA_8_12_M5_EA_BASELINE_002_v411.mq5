//+------------------------------------------------------------------+
//| XAU_MTF_SMA_8_12_M5_EA_BASELINE_002.mq5                          |
//| M5 SMA(8,12) multi-timeframe entry, basket and recovery management |
//| Responsive status UI: grouped cards, maximum two columns.          |
//+------------------------------------------------------------------+
#property strict
#property version   "4.11"
#property description "M5 MTF SMA(8/12) EA with optional Entry OR triggers and trend filters."
#property description "Supports Pullback, confirmed SMA Cross, Momentum and SMA pullback entry, SL, TP, trailing and recovery."
#property description "Daily closed-profit target and on-chart status panel."

#include <Trade/Trade.mqh>
CTrade trade;

#define TF_COUNT      5
#define OHLCV_HISTORY 20
// MTF SMA bias and entry triggers read fully closed candles at shift [1].
#define SIGNAL_SHIFT  1
// Momentum entry: do not allow an SMA8/12 cross or touch on [1]..[5].
// The older [6] is required to detect a cross occurring at [5].
// Fixed quiet history of the confirmed Cross+1Bar entry (previous SET value=10).
#define CONFIRMED_CROSS_QUIET_BARS 10

//====================================================================
// USER INPUTS - organized by trading workflow
//====================================================================
input group "01 | Trading and Order Limits"
// Master switch for opening positions and processing live exits.
input bool EnableTrading = true;
// Starting position volume in lots.
input double LotSize = 10;
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

input group "01.1 | Daily Realized Profit Target"
// Target in ACCOUNT CURRENCY, for closed deals matching this Symbol + MagicNumber.
// Zero disables daily targeting entirely. Open positions are NOT force-closed.
input double TargetDailyProfit = 0.0;

input group "01.2 | New Entry Cutoff Before Broker Market Close"
// Stop ALL NEW BUY/SELL entries during the final N minutes of a broker
// trading session for this symbol. Existing positions and all exits continue.
// Uses the broker's trade-session schedule in SERVER time, including Fridays.
// If the MT5 Strategy Tester supplies no session schedule, allow backtesting
// and log a warning; cutoff timing cannot be tested in that fallback.
input bool UsePreMarketCloseEntryFilter = false;
input int PreMarketCloseMinutes = 30;

input group "02 | SMA Indicator Settings"
// Period of the faster moving average.
input int FastMAPeriod = 8;
// Period of the slower moving average.
input int SlowMAPeriod = 12;
// SMA is the default averaging method.
input ENUM_MA_METHOD MainMAMethod = MODE_SMA;
// Input price used by both moving averages.
input ENUM_APPLIED_PRICE MainMAPrice = PRICE_CLOSE;
// Shared M5 ATR period used by other individual OR entry strategies.
input int EntryQualityATRPeriod = 14;

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
input bool UseMTFTrendEntryFilter = false;
// A tie in majority mode produces no entry bias.
input ENUM_MTF_ENTRY_BIAS_MODE MTFEntryBiasMode = MTF_MAJORITY;

input group "04.3 | Entry - OR Pullback Continuation"
// One switch for the merged three-candle PULLBACK setup:
// BUY: [3] GREEN, [2] RED, [1] GREEN, Close[1] > High[2],
//      M5 Fast[1]>Slow[1] and Fast[2]>Slow[2], Close[1]>Fast[1]>Low[1].
// SELL: [3] RED, [2] GREEN, [1] RED, Close[1] < Low[2],
//       M5 Fast[1]<Slow[1] and Fast[2]<Slow[2], Close[1]<Fast[1]<High[1].
// [3] wick quality: BUY Body[3]>UpperWick[3]; SELL Body[3]>LowerWick[3].
// Body[1] > Body[2] and max(Body[1], Body[2]) / min(...) <= 3.0.
// SMA8/SMA12 directional distance must not narrow on closed M5 [5]->[1].
// No retest / delayed setup: entry may occur after candle [1] closes.
// Keep the original input name for compatibility with previous .set files.
input bool UseCandleColorEntryFilter = true;
// 04.3 entry-only: closed M15 SMA8 slope and minimum signal energy.
input bool UsePullbackShortHoldQualityFilter = true;
input double PullbackMinSignalRangeATR = 0.8;

input group "04.4 | Entry - OR Two Green/Red Continuation"
// Independent M5 entry: two consecutive same-color CLOSED candles.
// BUY: SMA8[1]>SMA12[1], SMA12[1]>SMA12[2]>SMA12[3]>SMA12[4]>SMA12[5],
//      GREEN [1] and GREEN [2], Close[1]>High[2], Close[1]>HighestHigh[3..8].
// SELL: SMA8[1]<SMA12[1], SMA12[1]<SMA12[2]<SMA12[3]<SMA12[4]<SMA12[5],
//       RED [1] and RED [2], Close[1]<Low[2], Close[1]<LowestLow[3..8].
// Swing candle at highest High[3..8] (BUY): UpperWick <= Body.
// Swing candle at lowest Low[3..8] (SELL): LowerWick <= Body.
// Signal candle [1]: BUY Body[1]>UpperWick[1]; SELL Body[1]>LowerWick[1].
// Separate OR; no extra 04.3 body, wick or gap requirements.
input bool UseTwoCandleSMAContinuationEntryFilter = true;
// 04.4 entry-only: closed M30 trend/slope and a bounded end wick.
input bool UseTwoCandleShortHoldQualityFilter = true;
input double TwoCandleMaxEndWickFraction = 0.30;
// 04.4 ONLY: independently switchable original mandatory conditions.
// Master OFF disables all 04.4 subfilters regardless of their values.
// All default ON to reproduce v3.55 entry decisions.
input bool UseTwoCandleSMA8SMA12DirectionFilter = true;
// BUY SMA8[1]>SMA12[1]; SELL SMA8[1]<SMA12[1].
input bool UseTwoCandleSMA12Slope15Filter = true;
// BUY SMA12[1]>[2]>[3]>[4]>[5]; SELL reversed (strict).
input bool UseTwoCandleSameColor12Filter = true;
// BUY both [1],[2] green; SELL both red.
input bool UseTwoCandleBreakout2Filter = true;
// BUY Close[1]>High[2]; SELL Close[1]<Low[2].
input bool UseTwoCandleSwingBreakout38Filter = true;
// BUY Close[1]>HighestHigh[3..8]; SELL Close[1]<LowestLow[3..8].
input bool UseTwoCandleSignalWick1Filter = true;
// BUY Body[1]>UpperWick[1]; SELL Body[1]>LowerWick[1].
input bool UseTwoCandleSwingWick38Filter = true;
// At prior swing extreme: BUY UpperWick<=Body; SELL LowerWick<=Body.
// 04.4 ONLY: signal [1] extended range position versus SMA8[1].
// BUY: Low[1] - (High[1]-Low[1]) <= SMA8[1].
// SELL: High[1] + (High[1]-Low[1]) >= SMA8[1].
// OFF skips this additional check. Default ON for isolated testing.
input bool UseTwoCandleSignalRangeSMA8Filter = true;
// 04.4 ONLY: reject if ANY closed M5 candle [2..8] (any color, including doji)
// has BOTH Open and Close within its own SMA8/SMA12 band (inclusive).
// The check applies identically to BUY and SELL.
input bool UseTwoCandleBodyInsideSMABandFilter = true;
// 04.4 ONLY: SMA8 must slope continuously in entry direction on closed [2..5].
// BUY: SMA8[2]>SMA8[3]>SMA8[4]>SMA8[5]; SELL: strictly reversed.
// OFF leaves existing SMA12 slope [1..5] unchanged.
input bool UseTwoCandleSMA8Slope25Filter = true;
// 04.4 ONLY: among the five closed M5 candles [1..5], reject a BUY if
// a RED candle has a strictly larger body than the immediately prior GREEN
// candle. SELL mirrors: GREEN body > immediately prior RED body.
// Both candles must be inside [1..5]; equal-size bodies are allowed.
input bool UseTwoCandleOppositeBody5Filter = true;
// 04.4 ONLY: maximum absolute distance from signal Close[1] to SMA8[1],
// measured in ATR(EntryQualityATRPeriod) on CLOSED M5 [1].
// BUY and SELL: abs(Close[1]-SMA8[1]) <= ATR[1] * multiplier.
input bool UseTwoCandleCloseSMA8ATRFilter = true;
input double TwoCandleMaxCloseSMA8ATR = 1.1;
// 04.4 ONLY: reject a large opening gap between CLOSED [2] Close
// and CLOSED [1] Open (absolute difference, BUY/SELL identical).
// GapPoints = abs(Open[1]-Close[2])/_Point; equality with cap passes.
input bool UseTwoCandleOpenGap12Filter = true;
input int TwoCandleMaxOpenGap12Points = 200;

input group "04.5 | Entry - OR Momentum Breakout"
// OR #3: strong directional M5 candle breaks a prior high/low.
// Enabled by the tested default preset; its master switch remains adjustable.
input bool UseMomentumBreakoutEntryFilter = true;
// 04.5 ONLY: independently switchable CORE entry checks.
// Master OFF disables all Momentum entry checks; new switches default ON
// to retain the exact v3.58 ENTRY behavior when all are enabled.
// BUY green [1], SELL red [1].
input bool UseMomentumSignalColor1Filter = true;
// BUY SMA8[1]>SMA12[1], SELL SMA8[1]<SMA12[1].
input bool UseMomentumSMA8SMA12DirectionFilter = true;
// Legacy opposite-signal EXIT minimum signal Body/Range.
input double MomentumMinBodyRatio = 0.6;
// Closed-bar lookback retained for initial quality and legacy EXIT breakout.
input int MomentumBreakoutLookbackBars = 3;
input double MomentumMaxRangeATR = 1.8;
// Optional MOMENTUM-ONLY slope confirmation; does not affect other Entry ORs.
// Both SMA8 and SMA12 must move monotonically across CLOSED M5 [3]->[2]->[1].
// BUY: SMA8[1]>SMA8[2]>SMA8[3] AND SMA12[1]>SMA12[2]>SMA12[3].
// SELL: SMA8[1]<SMA8[2]<SMA8[3] AND SMA12[1]<SMA12[2]<SMA12[3].
// ALSO require increasing SMA8/SMA12 separation from closed [2] to [1]:
// BUY: SMA8[1]-SMA12[1] > SMA8[2]-SMA12[2].
// SELL: SMA12[1]-SMA8[1] > SMA12[2]-SMA8[2].
// Flat MA steps OR a narrowing/flat separation are BLOCKED.
// false restores the original Momentum behavior.
input bool UseMomentumSlopeEntryFilter = true;
// 04.5 ENTRY ONLY: independent SMA8 slope across fully closed M5 [1..3].
// BUY: SMA8[1] > SMA8[2] > SMA8[3].
// SELL: SMA8[1] < SMA8[2] < SMA8[3].
// OFF skips only this SMA8 slope filter; independent of combined SMA slope+gap.
input bool UseMomentumSMA8Slope13Filter = true;
// 04.5 ENTRY ONLY: compare adjacent candles inside the fully CLOSED M5 [2..5].
// BUY blocks if a RED candle has a strictly LARGER body than the immediately
// preceding GREEN candle. SELL mirrors: a GREEN candle bigger than the prior RED.
// Both bars must be inside [2..5]; [1] and [0] are excluded.
// Equal body sizes pass; same-color and Doji pairs are ignored.
// One switch handles both BUY and SELL. Other Entry ORs and exits are unchanged.
input bool UseMomentumOppositeBody25Filter = true;
// 04.5 ENTRY ONLY: when CLOSED [2] is opposite to signal [1], require
// signal Close[1] to break the FULL [2] candle extreme (not just its body).
// BUY: [2] RED, [1] GREEN -> Close[1] > High[2].
// SELL: [2] GREEN, [1] RED -> Close[1] < Low[2].
// If [2] is not the opposite color, this filter passes without any breakout
// requirement. Equal Close-to-High/Low blocks; Doji does not trigger the pair.
// Independent of the main Momentum Price Breakout switch; ENTRY ONLY.
input bool UseMomentumOppositeColorBreakout12Filter = true;
// 04.5 ENTRY ONLY: the CLOSED M5 signal candle [1] must have a body
// at least as large as EACH wick considered separately (not their sum).
// Body[1] >= UpperWick[1] AND Body[1] >= LowerWick[1].
// Equal sizes pass; a zero-sized doji does not pass.
// Applies to both BUY and SELL, irrespective of candle direction.
input bool UseMomentumBodyVsBothWicks1Filter = true;
// 04.5 ENTRY ONLY: require the fully CLOSED M5 signal Close[1] not to
// exceed the directional Bollinger Band at the SAME bar [1].
// BUY: Close[1] <= UpperBand[1]. SELL: Close[1] >= LowerBand[1].
// Equality passes. Standard iBands period=20, deviation=2, PRICE_CLOSE,
// bands_shift=0. No check on live [0]; no effect on exits or other ORs.
input bool UseMomentumBollingerCloseFilter = true;
input int MomentumBollingerPeriod = 20;
input double MomentumBollingerDeviation = 2.0;
// 04.5 ENTRY ONLY: require a fresh bounded breakout and ATR cap only while flat.
// Existing symbol+magic positions bypass ONLY this added quality gate so the
// configured legacy Momentum entry rules remain available for recovery/stacking.
input bool UseMomentumInitialEntryQualityFilter = true;
input group "04.6 | Entry - OR SMA Pullback Rejection"
// OR #4: two fully closed M5 candles: [2] touches SMA8, [1] resumes trend.
// BUY: SMA8[1]>SMA12[1], Low[2]<=SMA8[2], Close[2]>SMA12[2],
//      [2] RED, [1] GREEN, Body[1]>UpperWick[1], Close[1]>HighestHigh[2..5].
// SELL: [2] GREEN, [1] RED, Close[1]<LowestLow[2..5]; mirrored checks.
// [3] full candle body on SMA12 trend side: BUY Open/Close > SMA12[3]; SELL <.
// Optional [2] wick check: SELL lower wick <= upper wick; BUY upper wick <= lower wick.
// Doji on [2] never qualifies as an opposite-color pullback.
// Proposed BUY Ask / SELL Bid must be within N * M5 ATR[2] of SMA8[1].
// ATR[2] precedes confirmation bar [1]. ENTRY-ONLY; not an exit trigger.
input bool UseSMAPullbackRejectionEntryFilter = true;
input double SMAPullbackMaxDistanceATR = 1.0;
// Entry-only check of the PULLBACK candle [2] wicks; equality is allowed.
// BUY: UpperWick[2] <= LowerWick[2]; SELL: LowerWick[2] <= UpperWick[2].
// Does not change signal candle [1], other OR entries, or exits.
input bool UseSMAPullbackCandle2WickFilter = true;
// 04.6 ENTRY ONLY: absolute opening gap between M5 [1] Open and [2] Close.
// Default ON; 100 broker points. OFF skips only this gap check.
input bool UseSMAPullbackOpenGapFilter = true;
input int SMAPullbackMaxOpenGapPoints = 200;
// Entry 04.6 ONLY: opening gap between [2] Open and [3] Close.
// OFF skips only this check; default ON with a 200 broker-point limit.
input bool UseSMAPullbackOpenGap23Filter = true;
input int SMAPullbackMaxOpenGap23Points = 150;
// 04.6 ENTRY ONLY: Short-hold quality filter to reject weak/exhaustion signals
input bool UseSMAPullbackShortHoldQualityFilter = true;
input double SMAPullbackMinSignalRangeATR = 0.5;
input double SMAPullbackMaxEndWickFraction = 0.25;
input double SMAPullbackMinBodyFraction = 0.6;
input bool UseSMAPullbackM15TrendFilter = false;
input bool UseSMAPullbackH1TrendFilter = true;

input group "04.7 | Entry - OR SMA Cross + 1-Bar Confirmation"
// Confirmed SMA Cross is the only SMA Cross ENTRY; indicator exits remain independent.
// Cross occurs on CLOSED M5 [2], comparing SMA[3] -> SMA[2].
// Default subfilters: [2] directional color/body-wicks, [1] direction,
// directional color/body-wicks and breakout beyond [2]. All can be toggled.
// Quiet-history lookback is fixed at 10 when its switch is ON.
// The obsolete shared 04.4 input has been removed.
input bool UseSMACrossConfirmedEntryFilter = true;
// 04.7 entry-only: avoid stretched signals and weak post-cross separation.
input bool UseCrossShortHoldQualityFilter = true;
input double CrossMaxSignalRangeATR = 1.2;
input double CrossMinDirectionalGapATR = 0.2;
// 04.7 ONLY: the SMA8/SMA12 crossover at [2] is the defining trigger
// and always remains mandatory while the master is ON.
// All existing mandatory checks below default ON, preserving v3.56 behavior.
input bool UseCrossQuietHistory10Filter = true;
// Require the 10 earlier closed bars [3..13] to remain on pre-cross side.
input bool UseCrossCandle2ColorFilter = true;
// BUY [2] green / SELL [2] red.
input bool UseCrossCandle2BodyWickFilter = true;
// [2] Body > upper wick AND Body > lower wick.
input bool UseCrossSMA1DirectionFilter = true;
// BUY SMA8[1]>SMA12[1]; SELL opposite.
input bool UseCrossConfirm1ColorFilter = true;
// BUY [1] green / SELL [1] red.
input bool UseCrossConfirm1BreakoutFilter = true;
// BUY Close[1]>High[2]; SELL Close[1]<Low[2].
input bool UseCrossConfirm1BodyWickFilter = true;
// [1] Body > both individual wicks.
input bool UseCrossSMA12Slope13Filter = true;
// BUY SMA12[1]>SMA12[2]>SMA12[3]; SELL strictly reverse.
// 04.7 ONLY: SMA8 must slope continuously across five closed M5 bars [1..5].
// BUY: SMA8[1]>[2]>[3]>[4]>[5]; SELL strictly reversed.
// OFF skips only this slope check, independent from SMA12 slope.
input bool UseCrossSMA8Slope15Filter = true;
// ENTRY-ONLY range-position filter on the completed confirmation bar [1].
// BUY: Low[1] - (High[1]-Low[1]) >= SMA12[1].
// SELL: High[1] + (High[1]-Low[1]) <= SMA12[1].
// This REQUIRES at least one full [1] candle range between SMA12 and
// the nearest candle extremum; it is NOT a maximum-distance/anti-chase cap.
// No ATR or adjustable multiplier; OFF disables only this extra filter.
// Default ON for the integrated Cross+1Bar Range setup.
input bool UseSMACrossConfirmedRangeDistanceFilter = true;
// Entry = optional MTF/QUALITY/SPREAD/SLOW-SMA gates AND
//         (PULLBACK OR MOMENTUM OR SMA PULLBACK REJECTION OR CROSS CONFIRM).

// BEGIN NEW OR 04.8 INPUTS
input group "04.8 | Entry - OR Range Sweep Reclaim"
// Closed [1] sweeps a prior range, then closes back inside it and beyond
// the opposite-color [2] body midpoint. This is a failed-breakout trigger.
// Initial entries only; existing positions and all exit/recovery rules stay intact.
input bool UseRangeSweepReclaimEntryFilter = true;
input int RangeSweepLookbackBars = 6;
// Require closed M15/M30/H1/H4 SMA direction to agree with the trade.
input bool UseRangeSweepMTFTrendFilter = true;
// Independent closed M30 SMA8 and SMA12 slopes [2] -> [1].
input bool UseRangeSweepM30SlopeFilter = true;
input bool UseRangeSweepSignalQualityFilter = true;
input double RangeSweepMinRangeATR = 0.8;
input double RangeSweepMaxRangeATR = 1.8;
input double RangeSweepMaxEndWickFraction = 0.25;
// END NEW OR 04.8 INPUTS

// BEGIN FIVE NEW OR INPUTS
input group "04.9 | Entry - OR Inside Bar Release"
// 0=normal OR routing; 3/4/7 or 9..34 isolate an entry without changing exit routing.
input int NewORIsolatedEntry = 0;
input bool UseInsideBarReleaseEntryFilter = true;
input double InsideReleaseMinRangeATR = 0.8;
input double InsideReleaseMaxRangeATR = 1.8;
input double InsideReleaseMaxEndWickFraction = 0.25;
input double InsideReleaseMaxCloseFastATR = 1.25;

input group "04.10 | Entry - OR Break Retest Hold"
input bool UseBreakRetestHoldEntryFilter = true;
input double BreakRetestMinRangeATR = 0.8;
input double BreakRetestMaxRangeATR = 1.8;
input double BreakRetestMaxEndWickFraction = 0.25;
input double BreakRetestMaxCloseFastATR = 1.25;

input group "04.11 | Entry - OR Price Imbalance Retest"
input bool UseImbalanceRetestEntryFilter = true;
input double ImbalanceRetestMinRangeATR = 0.8;
input double ImbalanceRetestMaxRangeATR = 1.8;
input double ImbalanceRetestMaxEndWickFraction = 0.25;

input group "04.12 | Entry - OR Outside Bar Trap Reclaim"
input bool UseOutsideBarTrapEntryFilter = true;
input double OutsideTrapMinRangeATR = 0.8;
input double OutsideTrapMaxRangeATR = 1.8;
input double OutsideTrapMaxEndWickFraction = 0.25;

input group "04.13 | Entry - OR SMA Gap Compression Release"
input bool UseSMAGapReleaseEntryFilter = true;
input double SMAGapReleaseMinRangeATR = 0.8;
input double SMAGapReleaseMaxRangeATR = 1.8;
input double SMAGapReleaseMaxEndWickFraction = 0.15;

// END FIVE NEW OR INPUTS

// BEGIN NEW OR 04.14 INPUTS
input group "04.14 | Entry - OR Trend Staircase Continuation"
// A fresh CLOSED signal may re-enter on a later M5 bar after the prior trade closes.
// Flat-only: this OR never adds to any held EA position or changes recovery.
input bool UseTrendRunEntryFilter = true;
input double TrendRunMinRangeATR = 0.4;
input double TrendRunMaxRangeATR = 1.4;
input double TrendRunMaxEndWickFraction = 0.25;
input double TrendRunMaxCloseFastATR = 0.9;
input bool TrendRunRequireHigherTF = true;
// END NEW OR 04.14 INPUTS

// BEGIN NEW CONTINUATION OR INPUTS
input group "04.15 | Entry - OR Fast SMA Tap Reclaim"
input bool UseFastTapResumeEntryFilter = true;
input double FastTapMinRangeATR = 0.6;
input double FastTapMaxRangeATR = 1.4;
input double FastTapMaxEndWickFraction = 0.15;
input double FastTapMaxCloseFastATR = 0.8;

input group "04.16 | Entry - OR One Bar Pause Resume"
input bool UsePauseResumeEntryFilter = true;
input double PauseResumeMinRangeATR = 0.4;
input double PauseResumeMaxRangeATR = 1.4;
input double PauseResumeMaxEndWickFraction = 0.15;
input double PauseResumeMaxCloseFastATR = 0.9;
input double PauseResumeMaxPauseBodyATR = 0.4;

input group "04.17 | Entry - OR Trend Body Engulf Resume"
input bool UseBodyEngulfResumeEntryFilter = true;
input double BodyEngulfMinRangeATR = 0.4;
input double BodyEngulfMaxRangeATR = 1.4;
input double BodyEngulfMaxEndWickFraction = 0.15;
input double BodyEngulfMaxCloseFastATR = 0.9;
input bool BodyEngulfRequireHigherTF = true;

input group "04.18 | Entry - OR Volume Ignition Continuation"
input bool UseVolumeIgnitionEntryFilter = true;
input double VolumeIgnitionMinRangeATR = 0.4;
input double VolumeIgnitionMaxRangeATR = 1.4;
input double VolumeIgnitionMaxEndWickFraction = 0.25;
input double VolumeIgnitionMaxCloseFastATR = 0.9;
input double VolumeIgnitionMinVolumeRatio = 1.6;
input double VolumeIgnitionMinBodyFraction = 0.55;

input group "04.19 | Entry - OR SMA Slope Acceleration"
input bool UseSlopeAccelerationEntryFilter = true;
input double SlopeAccelMinRangeATR = 0.4;
input double SlopeAccelMaxRangeATR = 1.4;
input double SlopeAccelMaxEndWickFraction = 0.15;
input double SlopeAccelMaxCloseFastATR = 0.9;
input bool SlopeAccelRequireHigherTF = true;
input double SlopeAccelMinAccelerationATR = 0.02;

input group "04.20 | Entry - OR Micro Channel Continuation"
input bool UseMicroChannelEntryFilter = true;
input double MicroChannelMinRangeATR = 0.4;
input double MicroChannelMaxRangeATR = 1.4;
input double MicroChannelMaxEndWickFraction = 0.25;
input double MicroChannelMaxCloseFastATR = 0.9;
input bool MicroChannelRequireHigherTF = true;
// END NEW CONTINUATION OR INPUTS

// BEGIN RESEARCH OR04.21..04.32 INPUTS
input group "04.21-04.32 | New OR execution quality"
input int ResearchORMaxSpreadPoints = 350;
input double ResearchORMaxEntryGapATR = 0.25;
input int ResearchORSessionCutoffMinutes = 30;

input group "04.21 | Entry - OR Broker-day VWAP Deviation Re-entry"
// Enabled by the tested all-OR default profile; the master remains adjustable.
input bool UseSessionVWAPReentryEntryFilter = true;
input double R21MinRangeATR = 0.4;
input double R21MaxRangeATR = 1.8;
input double R21MinBodyFraction = 0.5;
input double R21MaxEndWickFraction = 0.25;
// Bit mask:1=M15,2=M30,4=H1,8=H4 agreement;16/32/64=M30/M15/M5 slopes;128=past-gap runway.
input int R21TrendMask = 17;
input double VWAPReentryDeviation = 1.0;
input int VWAPReentryMinDayBars = 12;
input double VWAPReentryMaxSlopeATR = 0.10;
input double VWAPReentryMinMeanRoom = 0.75;

input group "04.22 | Entry - OR RSI2 Trend Reset"
// Enabled by the tested all-OR default profile; the master remains adjustable.
input bool UseRSIResetEntryFilter = true;
input double R22MinRangeATR = 0.4;
input double R22MaxRangeATR = 1.5;
input double R22MinBodyFraction = 0.7;
input double R22MaxEndWickFraction = 0.15;
// Bit mask:1=M15,2=M30,4=H1,8=H4 agreement;16/32/64=M30/M15/M5 slopes;128=past-gap runway.
input int R22TrendMask = 0;
input double RSI2ResetExtreme = 10.0;
input double RSI2ResetMinRecovery = 60.0;
input double RSI2ResetMaxRecovery = 65.0;
input double RSI2ResetMinCloseFastATR = -0.2;

input group "04.23 | Entry - OR Opening Range Failed Auction"
// Enabled by the tested all-OR default profile; the master remains adjustable.
input bool UseOpeningRangeFailureEntryFilter = true;
input double R23MinRangeATR = 0.4;
input double R23MaxRangeATR = 1.8;
input double R23MinBodyFraction = 0.6;
input double R23MaxEndWickFraction = 0.25;
// Bit mask:1=M15,2=M30,4=H1,8=H4 agreement;16/32/64=M30/M15/M5 slopes;128=past-gap runway.
input int R23TrendMask = 15;
input double OpeningFailMinWidthATR = 1.5;
input double OpeningFailMaxWidthATR = 6.0;
input double OpeningFailMaxOutsideATR = 1.0;
input double OpeningFailMinMidRoom = 0.75;

input group "04.24 | Entry - OR DMI Strength Transition"
// Enabled by the tested all-OR default profile; the master remains adjustable.
input bool UseADXTransitionEntryFilter = true;
input double R24MinRangeATR = 0.8;
input double R24MaxRangeATR = 1.8;
input double R24MinBodyFraction = 0.7;
input double R24MaxEndWickFraction = 0.15;
// Bit mask:1=M15,2=M30,4=H1,8=H4 agreement;16/32/64=M30/M15/M5 slopes;128=past-gap runway.
input int R24TrendMask = 3;
input double DMITurnMinADX = 18.0;
input double DMITurnMaxADX = 40.0;
input double DMITurnMinADXDelta = 0.5;
input double DMITurnMaxCloseFastATR = 1.5;

input group "04.25 | Entry - OR Bollinger Band Re-entry"
// Enabled by the tested all-OR default profile; the master remains adjustable.
input bool UseBollingerReentryEntryFilter = true;
input double R25MinRangeATR = 0.8;
input double R25MaxRangeATR = 1.2;
input double R25MinBodyFraction = 0.6;
input double R25MaxEndWickFraction = 0.2;
// Bit mask:1=M15,2=M30,4=H1,8=H4 agreement;16/32/64=M30/M15/M5 slopes;128=past-gap runway.
input int R25TrendMask = 15;

input group "04.26 | Entry - OR MACD Histogram Turn"
// Enabled by the tested all-OR default profile; the master remains adjustable.
input bool UseMACDTurnEntryFilter = true;
input double R26MinRangeATR = 1.0;
input double R26MaxRangeATR = 1.5;
input double R26MinBodyFraction = 0.5;
input double R26MaxEndWickFraction = 0.2;
// Bit mask:1=M15,2=M30,4=H1,8=H4 agreement;16/32/64=M30/M15/M5 slopes;128=past-gap runway.
input int R26TrendMask = 31;

input group "04.27 | Entry - OR CCI Extreme Recovery"
// Enabled by the tested all-OR default profile; the master remains adjustable.
input bool UseCCIRecoveryEntryFilter = true;
input double R27MinRangeATR = 0.4;
input double R27MaxRangeATR = 1.2;
input double R27MinBodyFraction = 0.5;
input double R27MaxEndWickFraction = 0.25;
// Bit mask:1=M15,2=M30,4=H1,8=H4 agreement;16/32/64=M30/M15/M5 slopes;128=past-gap runway.
input int R27TrendMask = 31;

input group "04.28 | Entry - OR Stochastic Extreme Turn"
// Enabled by the tested all-OR default profile; the master remains adjustable.
input bool UseStochasticResetEntryFilter = true;
input double R28MinRangeATR = 0.8;
input double R28MaxRangeATR = 1.2;
input double R28MinBodyFraction = 0.6;
input double R28MaxEndWickFraction = 0.15;
// Bit mask:1=M15,2=M30,4=H1,8=H4 agreement;16/32/64=M30/M15/M5 slopes;128=past-gap runway.
input int R28TrendMask = 15;

input group "04.29 | Entry - OR Regression Channel Re-entry"
// Enabled by the tested all-OR default profile; the master remains adjustable.
input bool UseRegressionChannelEntryFilter = true;
input double R29MinRangeATR = 0.4;
input double R29MaxRangeATR = 1.2;
input double R29MinBodyFraction = 0.7;
input double R29MaxEndWickFraction = 0.15;
// Bit mask:1=M15,2=M30,4=H1,8=H4 agreement;16/32/64=M30/M15/M5 slopes;128=past-gap runway.
input int R29TrendMask = 207;

input group "04.30 | Entry - OR Aroon Fresh Direction"
// Enabled by the tested all-OR default profile; the master remains adjustable.
input bool UseAroonTurnEntryFilter = true;
input double R30MinRangeATR = 0.4;
input double R30MaxRangeATR = 1.2;
input double R30MinBodyFraction = 0.5;
input double R30MaxEndWickFraction = 0.25;
// Bit mask:1=M15,2=M30,4=H1,8=H4 agreement;16/32/64=M30/M15/M5 slopes;128=past-gap runway.
input int R30TrendMask = 16;

input group "04.31 | Entry - OR Dual ROC + 1-Bar Confirmation"
// Enabled by the tested all-OR default profile; the master remains adjustable.
input bool UseDualROCTurnEntryFilter = true;
input double R31MinRangeATR = 0.6;
input double R31MaxRangeATR = 1.2;
input double R31MinBodyFraction = 0.5;
input double R31MaxEndWickFraction = 0.15;
// Bit mask:1=M15,2=M30,4=H1,8=H4 agreement;16/32/64=M30/M15/M5 slopes;128=past-gap runway.
input int R31TrendMask = 3;

input group "04.32 | Entry - OR Confirmed Fractal 1-2-3 Reversal"
// Enabled by the tested all-OR default profile; the master remains adjustable.
input bool UseFractal123EntryFilter = true;
input double R32MinRangeATR = 0.6;
input double R32MaxRangeATR = 1.8;
input double R32MinBodyFraction = 0.6;
input double R32MaxEndWickFraction = 0.25;
// Bit mask:1=M15,2=M30,4=H1,8=H4 agreement;16/32/64=M30/M15/M5 slopes;128=past-gap runway.
input int R32TrendMask = 15;
// END RESEARCH OR INPUTS

// BEGIN SMA TREND CONTINUATION OR04.33 INPUTS
input group "04.33 | Entry - OR SMA Trend Continuation"
// Baseline: closed M5 Fast MA above/below Slow MA; enter only while FLAT.
// Defaults reproduce the selected STC R3 research profile.
input bool UseSMATrendContinuationEntryFilter = true;
// Number of consecutive CLOSED M5 bars with the same MA ordering (1=baseline).
input int STCTrendBars = 10;
// Bit mask: 1=M15, 2=M30, 4=H1, 8=H4 CLOSED MA ordering agreement.
input int STCTrendMask = 15;
// Bit mask: 1=M5, 2=M15, 4=M30; BOTH MA slopes [2] -> [1].
input int STCSlopeMask = 1;
input bool UseSTCCandleColorFilter = true;
input bool UseSTCCloseFastFilter = true;
input bool UseSTCRangeATRFilter = true;
input double STCMinRangeATR = 0.9;
input double STCMaxRangeATR = 1.8;
input bool UseSTCBodyFractionFilter = true;
input double STCMinBodyFraction = 0.7;
input bool UseSTCEndWickFilter = true;
input double STCMaxEndWickFraction = 0.15;
input bool UseSTCCloseFastATRFilter = true;
input double STCMaxCloseFastATR = 1;
// Optional old/earlier OR duplicate veto; OFF in the unfiltered control.
input bool UseSTCPriorORVeto = false;
// Require the current opening time and prior N closed bars to be contiguous M5.
input bool UseSTCFreshnessFilter = true;
input int STCFreshBars = 1;
// Compare the ACTUAL current Ask-Bid spread, not the historical bar minimum.
input bool UseSTCSpreadFilter = false;
input int STCMaxSpreadPoints = 200;
// END SMA TREND CONTINUATION OR04.33 INPUTS

// BEGIN INSIDE BAR BREAKOUT OR04.34 INPUTS
input group "04.34 | Entry - OR Inside Bar Breakout"
// Exact baseline: closed [3]=Mother, [2]=strict Inside, [1]=close Breakout.
// Mother/Inside candle colours are ignored. Defaults use the selected IBB R7 filters.
input bool UseInsideBarBreakoutEntryFilter = true;
// 1 preserves the baseline SMA check on [1]; >1 adds ordering persistence.
input int IBBTrendBars = 1;
// Bit mask: 1=M15, 2=M30, 4=H1, 8=H4 CLOSED MA ordering agreement.
input int IBBTrendMask = 0;
// Bit mask: 1=M5, 2=M15, 4=M30; BOTH MA slopes [2] -> [1].
input int IBBSlopeMask = 0;
input bool UseIBBCloseFastFilter = false;
input bool UseIBBRangeATRFilter = false;
input double IBBMinRangeATR = 0.4;
input double IBBMaxRangeATR = 1.8;
input bool UseIBBBodyFractionFilter = true;
input double IBBMinBodyFraction = 0.7;
input bool UseIBBEndWickFilter = true;
input double IBBMaxEndWickFraction = 0.2;
// Absolute Close[1]-SMA8[1] distance; side is a separate optional gate.
input bool UseIBBCloseFastATRFilter = false;
input double IBBMaxCloseFastATR = 1.25;
input bool UseIBBFreshnessFilter = false;
input int IBBFreshBars = 3;
input bool UseIBBSpreadFilter = false;
input int IBBMaxSpreadPoints = 200;
// Actual executable Ask/ Bid versus signal Close[1], normalized by ATR[2].
input bool UseIBBEntryGapATRFilter = false;
input double IBBMaxEntryGapATR = 0.2;
// Optional three-closed-bar-only impulse gate: Breakout range / Mother range.
input bool UseIBBRangeMotherFilter = true;
input double IBBMinRangeMotherRatio = 1.3;
// Optional three-closed-bar-only compression: Inside range / Mother range.
input bool UseIBBCompressionFilter = true;
input double IBBMaxInsideMotherRatio = 0.6;
// Minimum MA separation uses only the provided closed MA[1] and Mother[3].
input bool UseIBBMinMAGapMotherFilter = true;
input double IBBMinMAGapMotherRatio = 0.1;
// END INSIDE BAR BREAKOUT OR04.34 INPUTS

input group "05 | Swing Stop Loss"
// Attach a swing-based Stop Loss to each new trade.
input bool UseSwingSL = false;
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

input group "06.1 | Swing SL - TP Progress Trailing"
// Applies ONLY when a position has a real swing SL and a broker-side TP.
// Default OFF so prior strategy tester results remain comparable.
input bool UseTrailingStopWithSL = false;
// Start trailing once profitable price movement reaches this percent of
// the original price distance from position entry to its TP.
input double TrailingStartTPPercent = 40.0;
// At activation, place SL to protect this percent of the profit movement.
// Example: start 40% of TP and protect 70% => SL locks 28% of TP.
input double TrailingProtectMovePercent = 70.0;
// After activation, keep a CONSTANT gap of (100-Protect)% of the price
// movement at the activation level: (100-70)% * 40% = 12% of TP.
// SL is tightened on every tick and NEVER moved backwards.

input group "07 | Combined Basket Target"
// Enable basket TP automatically when BUY and SELL coexist.
// If false, allow hedging with individual TP/indicator exits unless an independent recovery basket activates.
input bool UseHedgeBasketTP = true;
// Sum of position point results, weighted by their lot size divided by LotSize.
// This is not USD profit, and excludes commissions, fees and swaps.
input double BasketProfitTarget = 500.0;
// Plot the EA-owned shared/virtual Basket TP level on the main chart.
input bool ShowBasketTPLine = true;

input group "08 | Opposite-Side Recovery"
// Enables the existing recovery multiplier or dynamic lot sizing.
input bool UseRecoveryLot = true;
// Zero = dynamic lot; a value >=1 applies a fixed, one-time multiplier.
input double RecoveryLotMultiplier = 2.0;
// Hypothetical favorable price move for dynamic lot sizing (broker points).
input int DynamicRecoveryMovePoints = 100;
// Hard upper bound; reject oversized dynamic recovery orders.
input double MaxDynamicRecoveryLot = 0.1;
// Maximum projected order margin as a percent of free margin.
input double MaxDynamicMarginPct = 30.0;

input group "09 | Same-Side Basket Exit"
// Despite legacy naming, this feature NEVER multiplies same-side lots.
// An additional entry into a losing side activates basket-level TP.
input bool UseSameSideRecoveryLot = true;

input group "10 | Indicator and Diagnostic Display"
// TRUE = hide EA-added SMA8/SMA12 lines; FALSE = display them on the chart.
// This controls display only. SMA calculations and trading rules always run.
// User-added chart indicators are not changed.
input bool HideIndicatorsOnChart = true;
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
// Shared ATR handle for M5 MA strength and Momentum spike caps.
int g_entry_quality_atr_handle = INVALID_HANDLE;
// Diagnostic details only; never used to admit or reject a trade.
string g_research_reentry_diagnostic="";
string g_research_session_diagnostic="";
int g_momentum_bbands_handle = INVALID_HANDLE;
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
bool g_show_chart_indicators=false;
bool g_chart_fast_added=false,g_chart_slow_added=false;
string g_chart_fast_name="",g_chart_slow_name="";
datetime g_panel_ready_bar=0;
bool g_panel_ready_buy=false,g_panel_ready_sell=false;
string g_panel_ready_source="";
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

// Persist initial broker TP per hedging position ticket across restarts.
// A trailed SL must NEVER be used to recalculate and move the original RR TP.
// Terminal global records are cleaned when a ticket is no longer open.

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

// Function: UsingNoSLTPMode - Check whether the three selectable no-SL take-profit modes apply.
bool UsingNoSLTPMode()
{
   return (!UseSwingSL && UseRRTP);
}

// Function: InputPointSize - Auto-scale 3-decimal calibrated point inputs (1 pt = 0.001)
// so the exact same input values work identically on both 2-digit (_Point=0.01)
// and 3-digit (_Point=0.001) symbols without modifying inputs.
double InputPointSize()
{
   if(_Point<=0.0) return 0.0;
   if(_Digits==2) return _Point*0.1;
   return _Point;
}

// Function: NativeBrokerPointsFromInput - Convert 3-decimal calibrated input points
// to native broker _Point count for CTrade::SetDeviationInPoints().
ulong NativeBrokerPointsFromInput(const int input_points)
{
   if(input_points<=0) return 0;
   if(_Digits==2) return (ulong)MathMax(1,(int)MathRound(input_points*0.1));
   return (ulong)input_points;
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
   bool require_mtfs=((UseMTFTrendEntryFilter && NewORIsolatedEntry!=33 && NewORIsolatedEntry!=34) ||
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

// Function: ReadEntryQualityATR - Read ATR from a completed M5 candle.
// Momentum uses shift [2] to prevent the signal candle raising its own threshold.
bool ReadEntryQualityATR(const int shift,double &atr)
{
   atr=0.0;
   if(g_entry_quality_atr_handle==INVALID_HANDLE || shift<1 ||
      BarsCalculated(g_entry_quality_atr_handle)<EntryQualityATRPeriod+shift)
      return false;
   double values[1];
   if(CopyBuffer(g_entry_quality_atr_handle,0,shift,1,values)!=1 ||
      !MathIsValidNumber(values[0]) || values[0]<=0.0)
      return false;
   atr=values[0];
   return true;
}

// BEGIN LEGACY SHORT-HOLD ENTRY QUALITY (04.3/04.4/04.7 ONLY)
// Existing pattern, TP, recovery, lot sizing and opposite-signal exits stay intact.
// Flat-only admission prevents these entries from adding to an unfinished cycle.
// All price/MA/ATR samples are closed; shift zero supplies the current bar TIME only.
bool PassLegacyShortHoldEntryQuality(const bool want_buy,const int entry_id)
{
   const bool enabled=(entry_id==3 ? UsePullbackShortHoldQualityFilter :
                       entry_id==4 ? UseTwoCandleShortHoldQualityFilter :
                       entry_id==7 ? UseCrossShortHoldQualityFilter : false);
   if(!enabled) return true;
   if(CountMyPositions()>0) return false;
   MqlRates bars[3]; // physical order [3], [2], [1]
   if(CopyRates(_Symbol,PERIOD_M5,1,3,bars)!=3) return false;
   const int seconds=PeriodSeconds(PERIOD_M5);
   if(iTime(_Symbol,PERIOD_M5,0)-bars[2].time!=seconds ||
      bars[2].time-bars[1].time!=seconds || bars[1].time-bars[0].time!=seconds)
      return false;
   const MqlRates signal=bars[2];
   const double range=signal.high-signal.low;
   if(!MathIsValidNumber(range) || range<=0.0) return false;
   if(entry_id==3)
   {
      double atr2=0.0,fast1=0.0,fast2=0.0;
      if(!ReadEntryQualityATR(2,atr2) || range<PullbackMinSignalRangeATR*atr2 ||
         !TryReadMA(g_fast_ma_handles[1],1,fast1) ||
         !TryReadMA(g_fast_ma_handles[1],2,fast2)) return false;
      return want_buy ? fast1>fast2 : fast1<fast2;
   }
   if(entry_id==4)
   {
      const double end_wick=(want_buy ? signal.high-signal.close : signal.close-signal.low);
      if(end_wick>TwoCandleMaxEndWickFraction*range) return false;
      double fast1=0.0,fast2=0.0,slow1=0.0;
      if(!TryReadMA(g_fast_ma_handles[2],1,fast1) ||
         !TryReadMA(g_fast_ma_handles[2],2,fast2) ||
         !TryReadMA(g_slow_ma_handles[2],1,slow1)) return false;
      return want_buy ? (fast1>slow1 && fast1>fast2) : (fast1<slow1 && fast1<fast2);
   }
   if(entry_id==7)
   {
      double atr2=0.0,fast1=0.0,slow1=0.0;
      if(!ReadEntryQualityATR(2,atr2) || range>CrossMaxSignalRangeATR*atr2 ||
         !TryReadMA(g_fast_ma_handles[0],1,fast1) ||
         !TryReadMA(g_slow_ma_handles[0],1,slow1)) return false;
      const double gap=(want_buy ? fast1-slow1 : slow1-fast1);
      return gap>=CrossMinDirectionalGapATR*atr2;
   }
   return false;
}
// END LEGACY SHORT-HOLD ENTRY QUALITY

//====================================================================
// SINGLE PULLBACK CONTINUATION ENTRY - fixed verified test settings
//====================================================================
// All THREE candles are fully closed M5 bars: [3], [2], and [1].
// The signal must clear the reference candle, candle-quality checks and
// M5 SMA trend agreement on closed [1]/[2] and Close/Fast/Low-High checks.
// No delayed retest mode and no separate ratio/3-candle inputs remain.
// Panel and order entry share this exact evaluator.
// Result: -1=missing data, 0=no breakout, 1=ratio block,
//          2=three-candle block, 3=qualified pattern, 4=M5 SMA block,
//          5=[3] directional wick block, 6=M5 SMA [2] mismatch,
//          7=M5 SMA separation narrows on [1]..[7] when no recent cross,
//          8=SMA12 slope [3]->[2]->[1] is not strictly directional.
int EvaluatePullbackPattern(const bool want_buy)
{
   MqlRates bars[3];
   // CopyRates places oldest bar first: bars[0]=[3], [1]=[2], [2]=[1].
   if(CopyRates(_Symbol,PERIOD_M5,1,3,bars)!=3)
      return -1;

   const double third_open=bars[0].open;
   const double third_close=bars[0].close;
   const double prior_open=bars[1].open;
   const double prior_close=bars[1].close;
   const double signal_open=bars[2].open;
   const double signal_close=bars[2].close;

   if(!MathIsValidNumber(third_open) || !MathIsValidNumber(third_close) ||
      !MathIsValidNumber(prior_open) || !MathIsValidNumber(prior_close) ||
      !MathIsValidNumber(signal_open) || !MathIsValidNumber(signal_close) ||
      !MathIsValidNumber(bars[0].high) || !MathIsValidNumber(bars[0].low) ||
      bars[0].high<MathMax(third_open,third_close) ||
      bars[0].low>MathMin(third_open,third_close) ||
      !MathIsValidNumber(bars[1].high) || !MathIsValidNumber(bars[1].low) ||
      bars[1].high<MathMax(prior_open,prior_close) ||
      bars[1].low>MathMin(prior_open,prior_close) ||
      bars[2].high<MathMax(signal_open,signal_close) ||
      bars[2].low>MathMin(signal_open,signal_close))
      return -1;

   bool breakout=(want_buy ?
      (prior_close<prior_open && signal_close>signal_open &&
       signal_close>bars[1].high) :
      (prior_close>prior_open && signal_close<signal_open &&
       signal_close<bars[1].low));
   if(!breakout) return 0;

   double body1=MathAbs(signal_close-signal_open);
   double body2=MathAbs(prior_close-prior_open);
   if(body1<=0.0 || body2<=0.0)
      return 0;

   // Selected best-test configuration: maximum body ratio fixed at 3x.
   double ratio=MathMax(body1,body2)/MathMin(body1,body2);
   if(!MathIsValidNumber(ratio) || ratio>3.0+1e-10)
      return 1;

   // Continuation after a pullback, with [1] stronger than pullback [2].
   bool third_matches=(want_buy ? third_close>third_open : third_close<third_open);
   if(!third_matches || body1<=body2)
      return 2;

   // ENTRY ONLY: [3] must have a strong body relative to its directional wick.
   // BUY: Body[3] > UpperWick[3]; SELL: Body[3] > LowerWick[3].
   // The strict > rejects equal body/wick. [3] is a fully closed M5 bar.
   const double body3=MathAbs(third_close-third_open);
   const double directional_wick3=(want_buy ?
      bars[0].high-MathMax(third_open,third_close) :
      MathMin(third_open,third_close)-bars[0].low);
   if(body3<=directional_wick3)
      return 5;

   // ENTRY ONLY: require M5 SMA direction on BOTH closed bars [1] and [2].
   // BUY: Fast[1]>Slow[1] AND Fast[2]>Slow[2], Close[1]>Fast[1]>Low[1].
   // SELL: Fast[1]<Slow[1] AND Fast[2]<Slow[2], Close[1]<Fast[1]<High[1].
   // This local check applies even if the optional MTF Trend Gate is disabled.
   // Opposite-signal exits use check_entry_pattern=false and remain unchanged.
   double fast_m5_1=0.0,slow_m5_1=0.0;
   double fast_m5_2=0.0,slow_m5_2=0.0;
   if(!TryReadMA(g_fast_ma_handles[0],1,fast_m5_1) ||
      !TryReadMA(g_slow_ma_handles[0],1,slow_m5_1) ||
      !TryReadMA(g_fast_ma_handles[0],2,fast_m5_2) ||
      !TryReadMA(g_slow_ma_handles[0],2,slow_m5_2))
      return -1;

   // Keep the pre-existing closed [1] SMA/price relation unchanged.
   const bool sma_ok=(want_buy ?
      (fast_m5_1>slow_m5_1 && signal_close>fast_m5_1 && fast_m5_1>bars[2].low) :
      (fast_m5_1<slow_m5_1 && signal_close<fast_m5_1 && fast_m5_1<bars[2].high));
   if(!sma_ok)
      return 4;

   // New: [2] must have the SAME SMA8/SMA12 direction as [1].
   // Equality is neutral and does not pass either BUY or SELL.
   const bool same_direction_2=(want_buy ? fast_m5_2>slow_m5_2 : fast_m5_2<slow_m5_2);
   if(!same_direction_2)
      return 6;

   // ENTRY 04.3 ONLY: SMA12 must slope continuously in the trade
   // direction across fully CLOSED M5 candles [3] -> [2] -> [1].
   // This check applies whether or not a recent SMA8/12 cross occurred.
   double slow_m5_3=0.0;
   if(!TryReadMA(g_slow_ma_handles[0],3,slow_m5_3))
      return -1;
   const bool slow_slope_ok=(want_buy ?
      (slow_m5_1>slow_m5_2 && slow_m5_2>slow_m5_3) :
      (slow_m5_1<slow_m5_2 && slow_m5_2<slow_m5_3));
   if(!slow_slope_ok)
      return 8;

   // ENTRY 04.3 ONLY: if SMA8/SMA12 cross (or touch) on any CLOSED
   // bar [1]..[5], skip SMA gap-expansion check entirely.
   // Read [6] as the previous reference to detect a cross occurring at [5].
   // Without a cross/touch, require positive non-narrowing gap [7] -> [1].
   double sma_gap[7];  // index 0 = shift [1], index 6 = shift [7]
   for(int shift=1; shift<=7; shift++)
   {
      double fast=0.0,slow=0.0;
      if(!TryReadMA(g_fast_ma_handles[0],shift,fast) ||
         !TryReadMA(g_slow_ma_handles[0],shift,slow))
         return -1;
      sma_gap[shift-1]=fast-slow;
      if(!MathIsValidNumber(sma_gap[shift-1])) return -1;
   }

   bool recent_cross=false;
   for(int shift=1; shift<=5; shift++)
   {
      const double newer=sma_gap[shift-1];
      const double older=sma_gap[shift];
      if(newer==0.0 || older==0.0 ||
         (newer>0.0 && older<0.0) ||
         (newer<0.0 && older>0.0))
      {
         recent_cross=true;
         break;
      }
   }

   if(!recent_cross)
   {
      double previous_gap=0.0;
      for(int shift=7; shift>=1; shift--)
      {
         const double gap=(want_buy ? sma_gap[shift-1] : -sma_gap[shift-1]);
         if(gap<=0.0 || (shift<7 && gap<previous_gap)) return 7;
         previous_gap=gap;
      }
   }

   return 3;
}

// check_entry_pattern=false intentionally preserves the existing opposite-
// signal exit behavior: exits use only the most recent candle's color.
bool PassEntryCandleColorFilter(const IndicatorState &s,const bool want_buy,
                                const bool check_entry_pattern=true)
{
   if(!check_entry_pattern)
      return (want_buy ? s.close<s.open : s.close>s.open);
   return (EvaluatePullbackPattern(want_buy)==3 && PassLegacyShortHoldEntryQuality(want_buy,3));
}

// Independent ENTRY 04.4: SMA12 slope + two same-color breakout candles.
// Additional previous swing check: Close[1] strictly breaks [3]..[8].
// SMA12 slope uses fully CLOSED M5 bars [1] through [5].
// This entry does not modify other OR setups or indicator-driven exits.
bool PassTwoCandleSMAContinuationEntryFilter(const bool want_buy)
{
   // Master switch always overrides all 04.4 subfilters.
   if(!UseTwoCandleSMAContinuationEntryFilter || !PassLegacyShortHoldEntryQuality(want_buy,4))
      return false;

   MqlRates candles[2];
   // Static CopyRates physical layout: candles[0]=[2], candles[1]=[1].
   if(CopyRates(_Symbol,PERIOD_M5,1,2,candles)!=2)
      return false;

   const MqlRates prior=candles[0];
   const MqlRates signal=candles[1];
   if(!MathIsValidNumber(prior.open) || !MathIsValidNumber(prior.close) ||
      !MathIsValidNumber(prior.high) || !MathIsValidNumber(prior.low) ||
      !MathIsValidNumber(signal.open) || !MathIsValidNumber(signal.close) ||
      !MathIsValidNumber(signal.high) || !MathIsValidNumber(signal.low) ||
      prior.high<MathMax(prior.open,prior.close) ||
      prior.low>MathMin(prior.open,prior.close) ||
      signal.high<MathMax(signal.open,signal.close) ||
      signal.low>MathMin(signal.open,signal.close))
      return false;

   // Read only the MA samples required by enabled subfilters.
   double fast1=0.0;
   const bool need_fast1=(UseTwoCandleSMA8SMA12DirectionFilter ||
                          UseTwoCandleCloseSMA8ATRFilter ||
                          UseTwoCandleSignalRangeSMA8Filter);
   if(need_fast1 && !TryReadMA(g_fast_ma_handles[0],1,fast1))
      return false;

   const bool need_slow1=UseTwoCandleSMA8SMA12DirectionFilter;
   double slow[5]; // index 0=[1], ... index 4=[5]
   int slow_count=(UseTwoCandleSMA12Slope15Filter ? 5 :
                   (need_slow1 ? 1 : 0));
   for(int shift=1;shift<=slow_count;shift++)
      if(!TryReadMA(g_slow_ma_handles[0],shift,slow[shift-1]))
         return false;

   if(UseTwoCandleSMA8SMA12DirectionFilter &&
      (want_buy ? fast1<=slow[0] : fast1>=slow[0]))
      return false;
   if(UseTwoCandleSMA12Slope15Filter)
      for(int i=0;i<4;i++)
         if(want_buy ? slow[i]<=slow[i+1] : slow[i]>=slow[i+1])
            return false;

   // ENTRY 04.4 ONLY: optional SMA8 slope using closed bars [2]..[5].
   // Strict inequality: flat values or one opposing move block the entry.
   if(UseTwoCandleSMA8Slope25Filter)
   {
      double fast_slope[4]; // index 0=[2], 1=[3], 2=[4], 3=[5]
      for(int shift=2;shift<=5;shift++)
         if(!TryReadMA(g_fast_ma_handles[0],shift,fast_slope[shift-2]))
            return false;
      for(int i=0;i<3;i++)
         if(want_buy ? fast_slope[i]<=fast_slope[i+1] :
                       fast_slope[i]>=fast_slope[i+1])
            return false;
   }

   // ENTRY 04.4 ONLY: reject an oversized opposite-color candle in
   // the last five CLOSED M5 bars [1..5]. Compare adjacent candles only;
   // both candles must lie inside the window. Oldest -> newest CopyRates.
   if(UseTwoCandleOppositeBody5Filter)
   {
      MqlRates recent[5]; // recent[0]=[5], ... recent[4]=[1]
      if(CopyRates(_Symbol,PERIOD_M5,1,5,recent)!=5)
         return false;
      for(int i=1;i<5;i++)
      {
         const MqlRates previous=recent[i-1];
         const MqlRates current=recent[i];
         if(!MathIsValidNumber(previous.open) || !MathIsValidNumber(previous.close) ||
            !MathIsValidNumber(current.open) || !MathIsValidNumber(current.close))
            return false;
         const double previous_body=MathAbs(previous.close-previous.open);
         const double current_body=MathAbs(current.close-current.open);
         if(want_buy)
         {
            if(previous.close>previous.open && current.close<current.open &&
               current_body>previous_body)
               return false;
         }
         else
         {
            if(previous.close<previous.open && current.close>current.open &&
               current_body>previous_body)
               return false;
         }
      }
   }

   // ENTRY 04.4 ONLY: optional distance of Close[1] from SMA8[1],
   // normalized by the M5 ATR on the same fully closed candle [1].
   if(UseTwoCandleCloseSMA8ATRFilter)
   {
      double atr1=0.0;
      if(!ReadEntryQualityATR(1,atr1) ||
         MathAbs(signal.close-fast1)>atr1*TwoCandleMaxCloseSMA8ATR)
         return false;
   }

   // ENTRY 04.4 ONLY: opening gap between [2] Close and [1] Open.
   // Same absolute-distance rule for BUY and SELL; no live [0] data.
   if(UseTwoCandleOpenGap12Filter)
   {
      const double pt=InputPointSize();
      if(pt<=0.0)
         return false;
      const double gap_points=MathAbs(signal.open-prior.close)/pt;
      if(!MathIsValidNumber(gap_points) ||
         gap_points>(double)TwoCandleMaxOpenGap12Points+1e-6)
         return false;
   }

   // ENTRY 04.4 ONLY: optional signal [1] range-position check.
   if(UseTwoCandleSignalRangeSMA8Filter)
   {
      const double range1=signal.high-signal.low;
      const double level=(want_buy ? signal.low-range1 : signal.high+range1);
      if(!MathIsValidNumber(range1) || range1<=0.0 ||
         !MathIsValidNumber(level) ||
         (want_buy ? level>fast1 : level<fast1))
         return false;
   }

   // Entry 04.4 ONLY: reject ANY candle (green, red or doji) whose
   // Open and Close are both inside its own SMA8-SMA12 band in [2..8].
   // Equal-to-band-edge counts as inside; [1] and live [0] are excluded.
   if(UseTwoCandleBodyInsideSMABandFilter)
   {
      MqlRates band_bars[7];
      // Static CopyRates order: band_bars[0]=[8], ... [6]=[2].
      if(CopyRates(_Symbol,PERIOD_M5,2,7,band_bars)!=7)
         return false;
      for(int i=0;i<7;i++)
      {
         const MqlRates bar=band_bars[i];
         if(!MathIsValidNumber(bar.open) || !MathIsValidNumber(bar.close) ||
            !MathIsValidNumber(bar.high) || !MathIsValidNumber(bar.low) ||
            bar.high<bar.low ||
            bar.high<MathMax(bar.open,bar.close) ||
            bar.low>MathMin(bar.open,bar.close))
            return false;
         const int shift=8-i;
         double fast=0.0, slow_value=0.0;
         if(!TryReadMA(g_fast_ma_handles[0],shift,fast) ||
            !TryReadMA(g_slow_ma_handles[0],shift,slow_value))
            return false;
         const double band_low=MathMin(fast,slow_value);
         const double band_high=MathMax(fast,slow_value);
         if(bar.open>=band_low && bar.open<=band_high &&
            bar.close>=band_low && bar.close<=band_high)
            return false;
      }
   }

   // Entry 04.4 ONLY: swing breakout and swing wick quality are
   // independent; skip loading [3..8] when both switches are OFF.
   if(UseTwoCandleSwingBreakout38Filter || UseTwoCandleSwingWick38Filter)
   {
      MqlRates swing_bars[6]; // oldest [8] -> newest [3]
      if(CopyRates(_Symbol,PERIOD_M5,3,6,swing_bars)!=6)
         return false;
      double highest_high=-DBL_MAX;
      double lowest_low=DBL_MAX;
      int highest_index=-1,lowest_index=-1;
      for(int i=0;i<6;i++)
      {
         const MqlRates bar=swing_bars[i];
         if(!MathIsValidNumber(bar.open) || !MathIsValidNumber(bar.close) ||
            !MathIsValidNumber(bar.high) || !MathIsValidNumber(bar.low) ||
            bar.high<bar.low || bar.high<MathMax(bar.open,bar.close) ||
            bar.low>MathMin(bar.open,bar.close))
            return false;
         if(bar.high>highest_high)
         {
            highest_high=bar.high;
            highest_index=i;
         }
         if(bar.low<lowest_low)
         {
            lowest_low=bar.low;
            lowest_index=i;
         }
      }
      if(UseTwoCandleSwingBreakout38Filter &&
         (want_buy ? signal.close<=highest_high : signal.close>=lowest_low))
         return false;

      if(UseTwoCandleSwingWick38Filter)
      {
         // On equal extrema the oldest candle is evaluated, as in v3.55.
         const MqlRates swing_candle=swing_bars[want_buy ? highest_index : lowest_index];
         const double swing_body=MathAbs(swing_candle.close-swing_candle.open);
         const double swing_wick=(want_buy ?
            swing_candle.high-MathMax(swing_candle.open,swing_candle.close) :
            MathMin(swing_candle.open,swing_candle.close)-swing_candle.low);
         if(!MathIsValidNumber(swing_body) || !MathIsValidNumber(swing_wick) ||
            swing_wick<0.0 || swing_wick>swing_body)
            return false;
      }
   }

   if(UseTwoCandleSignalWick1Filter)
   {
      const double signal_body=MathAbs(signal.close-signal.open);
      const double signal_wick=(want_buy ?
         signal.high-MathMax(signal.open,signal.close) :
         MathMin(signal.open,signal.close)-signal.low);
      if(!MathIsValidNumber(signal_body) || !MathIsValidNumber(signal_wick) ||
         signal_body<=0.0 || signal_wick<0.0 || signal_body<=signal_wick)
         return false;
   }

   if(UseTwoCandleSameColor12Filter &&
      (want_buy ? !(prior.close>prior.open && signal.close>signal.open) :
                  !(prior.close<prior.open && signal.close<signal.open)))
      return false;
   if(UseTwoCandleBreakout2Filter &&
      (want_buy ? signal.close<=prior.high : signal.close>=prior.low))
      return false;
   return true;
}

// Candle quality for confirmed SMA Cross, used on closed candles [2] and [1].
// Body must exceed EACH wick individually (not their sum).
// When check_color=false, direction is handled by its separate 04.7 switch.
// Function: PassSMACrossCandleBodyWick - Confirm directional candle and body>wicks.
bool PassSMACrossCandleBodyWick(const double candle_open,
                                const double candle_high,
                                const double candle_low,
                                const double candle_close,
                                const bool want_buy,
                                const bool check_color=true)
{
   if(!MathIsValidNumber(candle_open) || !MathIsValidNumber(candle_high) ||
      !MathIsValidNumber(candle_low)  || !MathIsValidNumber(candle_close))
      return false;

   if(candle_high<MathMax(candle_open,candle_close) ||
      candle_low>MathMin(candle_open,candle_close) ||
      candle_high<candle_low)
      return false;

   if(check_color && (want_buy ? (candle_close<=candle_open) : (candle_close>=candle_open)))
      return false;

   double body=MathAbs(candle_close-candle_open);
   double upper_wick=candle_high-MathMax(candle_open,candle_close);
   double lower_wick=MathMin(candle_open,candle_close)-candle_low;
   return (body>upper_wick && body>lower_wick);
}

// Dedicated ENTRY OR: cross candle [2], then ONE full M5 confirmation candle [1].
// This is the sole SMA Cross Entry (original one-bar cross Entry removed).
// Result: -1=missing history, 0=no new cross on [2],
//         1=recent earlier cross/touch, 2=cross [2] candle quality rejected,
//         3=confirmation [1] failed color/price breakout, 4=SMA reversed on [1],
//         5=entry qualified, 6=SMA12-to-[1] wick range-gap block,
//         8=confirmation [1] body vs upper/lower wick block,
//         9=three-closed-bar SMA12 slope block,
//         10=[2] candle color block, 11=[1] candle color block,
//         12=five-closed-bar SMA8 slope block.
// All other pattern filters are independently switchable.
// A genuine SMA8/12 cross on [2] is always required.
// No change to other Entry OR choices or indicator-driven exits.
// No current/future bar [0] is used.
int EvaluateSMACrossOneBarConfirmation(const bool want_buy)
{
   double f1=0.0,s1=0.0,f2=0.0,s2=0.0,f3=0.0,s3=0.0;
   if(!TryReadMA(g_fast_ma_handles[0],1,f1) ||
      !TryReadMA(g_slow_ma_handles[0],1,s1) ||
      !TryReadMA(g_fast_ma_handles[0],2,f2) ||
      !TryReadMA(g_slow_ma_handles[0],2,s2) ||
      !TryReadMA(g_fast_ma_handles[0],3,f3) ||
      !TryReadMA(g_slow_ma_handles[0],3,s3))
      return -1;

   // Strict cross on the completed candle [2], NOT the confirmation [1].
   const bool crossed=(want_buy ? (f3<s3 && f2>s2) : (f3>s3 && f2<s2));
   if(!crossed) return 0;

   // Shift the existing quiet-history rule by one bar: [3]..[N+3].
   // Equal SMA values are not accepted, consistent with 04.4.
   if(UseCrossQuietHistory10Filter && CONFIRMED_CROSS_QUIET_BARS>0)
   {
      for(int shift=3;shift<=CONFIRMED_CROSS_QUIET_BARS+3;shift++)
      {
         double fast=0.0,slow=0.0;
         if(!TryReadMA(g_fast_ma_handles[0],shift,fast) ||
            !TryReadMA(g_slow_ma_handles[0],shift,slow))
            return -1;
         if(want_buy ? (fast>=slow) : (fast<=slow))
            return 1;
      }
   }

   MqlRates bars[2];
   // CopyRates with a fixed-size array is oldest -> newest: [2], then [1].
   if(CopyRates(_Symbol,PERIOD_M5,1,2,bars)!=2)
      return -1;
   const MqlRates cross_bar=bars[0];  // [2]
   const MqlRates confirm_bar=bars[1]; // [1]

   // 04.7 filters are independent: each OFF bypasses only its own check.
   if(UseCrossCandle2ColorFilter &&
      (want_buy ? cross_bar.close<=cross_bar.open : cross_bar.close>=cross_bar.open))
      return 10;

   // Validate body-vs-each-wick independently of candle color.
   if(UseCrossCandle2BodyWickFilter &&
      !PassSMACrossCandleBodyWick(cross_bar.open,cross_bar.high,
                                  cross_bar.low,cross_bar.close,want_buy,false))
      return 2;

   if(UseCrossSMA1DirectionFilter &&
      (want_buy ? f1<=s1 : f1>=s1))
      return 4;

   if(UseCrossConfirm1ColorFilter &&
      (want_buy ? confirm_bar.close<=confirm_bar.open : confirm_bar.close>=confirm_bar.open))
      return 11;

   if(UseCrossConfirm1BreakoutFilter &&
      (want_buy ? confirm_bar.close<=cross_bar.high : confirm_bar.close>=cross_bar.low))
      return 3;

   if(UseCrossConfirm1BodyWickFilter &&
      !PassSMACrossCandleBodyWick(confirm_bar.open,confirm_bar.high,
                                  confirm_bar.low,confirm_bar.close,want_buy,false))
      return 8;

   // NEW 04.7 slope: both steps must move strictly toward entry direction.
   // This reads only completed M5 [3], [2], [1], never live candle [0].
   if(UseCrossSMA12Slope13Filter &&
      (want_buy ? !(s1>s2 && s2>s3) : !(s1<s2 && s2<s3)))
      return 9;

   // 04.7 ONLY: continuous SMA8 slope across closed bars [5] -> [1].
   // Preserve the [2] crossover trigger regardless of this switch.
   if(UseCrossSMA8Slope15Filter)
   {
      double fast_slope[5]; // index 0=[1], ..., index 4=[5]
      fast_slope[0]=f1;
      fast_slope[1]=f2;
      fast_slope[2]=f3;
      for(int shift=4;shift<=5;shift++)
         if(!TryReadMA(g_fast_ma_handles[0],shift,fast_slope[shift-1]))
            return -1;
      for(int i=0;i<4;i++)
         if(want_buy ? fast_slope[i]<=fast_slope[i+1] :
                       fast_slope[i]>=fast_slope[i+1])
            return 12;
   }

   // Optional ENTRY-only [1] candle position relative to SMA12[1].
   // BUY requires Low[1] - Range[1] >= SMA12[1].
   // SELL requires High[1] + Range[1] <= SMA12[1].
   // This is a MINIMUM gap of one Range[1], NOT a maximum-distance cap.
   if(UseSMACrossConfirmedRangeDistanceFilter)
   {
      const double range1=confirm_bar.high-confirm_bar.low;
      const double level=(want_buy ?
         confirm_bar.low-range1 : confirm_bar.high+range1);
      if(!MathIsValidNumber(range1) || !MathIsValidNumber(level) ||
         !MathIsValidNumber(s1) || range1<=0.0 ||
         (want_buy ? level<s1 : level>s1))
         return 6;
   }


   return 5;
}

bool PassEntrySMACrossConfirmedFilter(const bool want_buy)
{
   return (EvaluateSMACrossOneBarConfirmation(want_buy)==5 && PassLegacyShortHoldEntryQuality(want_buy,7));
}

// Function: ReadMomentumBreakout - Detect a strong M5 trend-continuation candle.
// The signal bar is the latest completed bar [1]. Earlier closed bars [2..N+1]
// define the breakout level. New ENTRY requires body/range >= minimum
// on ALL [1], [2], [3], regardless of their candle directions.
// BUY: green [1], close above highest prior high, M5 Fast MA[1]>Slow MA[1].
// SELL uses the mirrored conditions. This reads M5 SMA independently of the
// UseTF_M5 MTF voting switch, so turning off the M5 vote will not disable
// this optional momentum signal. False means missing data or invalid input.
bool ReadMomentumBreakout(bool &buy_breakout,bool &sell_breakout,
                          const bool check_entry_window=true)
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

   // Validate signal shape for all calls; body strength below applies only to legacy EXIT.
   MqlRates signal=rates[count-1];
   const double range=signal.high-signal.low;
   const double body=MathAbs(signal.close-signal.open);
   if(!MathIsValidNumber(range) || !MathIsValidNumber(body) || range<=0.0)
      return false;
   // Keep the original candle-strength rule for legacy indicator EXIT calls.
   // Core switches are entry-only and never change opposite-signal exits.
   if((!check_entry_window && body/range+1e-12<MomentumMinBodyRatio))
      return true;

   double highest=rates[0].high;
   double lowest=rates[0].low;
   for(int i=1;i<count-1;i++)
   {
      highest=MathMax(highest,rates[i].high);
      lowest=MathMin(lowest,rates[i].low);
   }

   double fast=0.0,slow=0.0;
   if(!check_entry_window || UseMomentumSMA8SMA12DirectionFilter)
      if(!TryReadMA(g_fast_ma_handles[0],SIGNAL_SHIFT,fast) ||
         !TryReadMA(g_slow_ma_handles[0],SIGNAL_SHIFT,slow))
         return false;

   // For exit calls (check_entry_window=false), keep ALL original core rules.
   // For entries, OFF switches bypass only their corresponding rule.
   const bool check_color=(!check_entry_window || UseMomentumSignalColor1Filter);
   const bool check_breakout=(!check_entry_window);
   const bool check_sma=(!check_entry_window || UseMomentumSMA8SMA12DirectionFilter);
   buy_breakout=(!check_color || signal.close>signal.open) &&
                (!check_breakout || signal.close>highest) &&
                (!check_sma || fast>slow);
   sell_breakout=(!check_color || signal.close<signal.open) &&
                 (!check_breakout || signal.close<lowest) &&
                 (!check_sma || fast<slow);
   return true;
}

// MOMENTUM ENTRY-ONLY slope: demand both M5 SMAs trend consistently
// across the previous three FULLY CLOSED candles [3], [2], [1].
// SMA separation must also EXPAND from [2] to [1], never narrow/flatten.
// No live [0] MA values; slope check is independent of the global M5 slope gate.
bool PassMomentumSlopeEntryFilter(const bool want_buy)
{
   if(!UseMomentumSlopeEntryFilter)
      return true;

   double f1=0.0,f2=0.0,f3=0.0,s1=0.0,s2=0.0,s3=0.0;
   if(!TryReadMA(g_fast_ma_handles[0],1,f1) ||
      !TryReadMA(g_fast_ma_handles[0],2,f2) ||
      !TryReadMA(g_fast_ma_handles[0],3,f3) ||
      !TryReadMA(g_slow_ma_handles[0],1,s1) ||
      !TryReadMA(g_slow_ma_handles[0],2,s2) ||
      !TryReadMA(g_slow_ma_handles[0],3,s3))
      return false;

   const double gap1=(want_buy ? f1-s1 : s1-f1);
   const double gap2=(want_buy ? f2-s2 : s2-f2);
   const bool gap_expanding=(gap1>gap2);

   return (want_buy ?
      (f1>f2 && f2>f3 && s1>s2 && s2>s3 && gap_expanding) :
      (f1<f2 && f2<f3 && s1<s2 && s2<s3 && gap_expanding));
}

// 04.5 ENTRY ONLY: independent, strict SMA8 slope on closed M5 [1..3].
// No live [0] data; independent from the existing SMA8/SMA12 + gap filter.
bool PassMomentumSMA8Slope13Filter(const bool want_buy)
{
   if(!UseMomentumSMA8Slope13Filter)
      return true;

   double f1=0.0,f2=0.0,f3=0.0;
   if(!TryReadMA(g_fast_ma_handles[0],1,f1) ||
      !TryReadMA(g_fast_ma_handles[0],2,f2) ||
      !TryReadMA(g_fast_ma_handles[0],3,f3))
      return false;

   return (want_buy ? (f1>f2 && f2>f3) : (f1<f2 && f2<f3));
}

// 04.5 ENTRY ONLY: reject an oversized reversal-color candle in M5 [2..5].
// The physical CopyRates array is oldest -> newest: [5],[4],[3],[2].
// Only IMMEDIATELY ADJACENT pairs entirely within the window are compared.
// BUY: previous GREEN + current RED with RED Body > GREEN Body => BLOCK.
// SELL: previous RED + current GREEN with GREEN Body > RED Body => BLOCK.
// Doji, same-color, and equally-sized opposite candles do not trigger a block.
bool PassMomentumOppositeBody25Filter(const bool want_buy)
{
   if(!UseMomentumOppositeBody25Filter)
      return true;

   MqlRates bars[4]; // [5] [4] [3] [2] (oldest to newest)
   if(CopyRates(_Symbol,PERIOD_M5,2,4,bars)!=4)
      return false;

   for(int i=1; i<4; i++)
   {
      const MqlRates older=bars[i-1];
      const MqlRates newer=bars[i];
      if(!MathIsValidNumber(older.open) || !MathIsValidNumber(older.close) ||
         !MathIsValidNumber(newer.open) || !MathIsValidNumber(newer.close))
         return false;

      const double older_body=MathAbs(older.close-older.open);
      const double newer_body=MathAbs(newer.close-newer.open);
      const bool opposite_larger=(want_buy ?
         (older.close>older.open && newer.close<newer.open && newer_body>older_body) :
         (older.close<older.open && newer.close>newer.open && newer_body>older_body));
      if(opposite_larger)
      {
         if(PrintSignalLog)
            PrintFormat("MOMENTUM %s OPPOSITE BODY [2..5] BLOCK: bar[%d] body=%.*f > preceding bar[%d] body=%.*f",
                        (want_buy ? "BUY" : "SELL"),5-i,_Digits,newer_body,
                        6-i,_Digits,older_body);
         return false;
      }
   }
   return true;
}

// 04.5 ENTRY ONLY: validate a two-candle reversal-color breakout.
// Static CopyRates order: bars[0]=closed [2], bars[1]=closed [1].
// Only a direction-matching opposite-color pair activates this filter.
// Same-color candles, wrong signal color and Doji pairs are handled by other
// independent Momentum filters, and are NOT rejected here.
bool PassMomentumOppositeColorBreakout12Filter(const bool want_buy)
{
   if(!UseMomentumOppositeColorBreakout12Filter)
      return true;

   MqlRates bars[2];
   if(CopyRates(_Symbol,PERIOD_M5,1,2,bars)!=2)
      return false;
   const MqlRates previous=bars[0]; // [2]
   const MqlRates signal=bars[1];   // [1]
   if(!MathIsValidNumber(previous.open) || !MathIsValidNumber(previous.close) ||
      !MathIsValidNumber(previous.high) || !MathIsValidNumber(previous.low) ||
      !MathIsValidNumber(signal.open) || !MathIsValidNumber(signal.close) ||
      !MathIsValidNumber(signal.high) || !MathIsValidNumber(signal.low) ||
      previous.high<previous.low || signal.high<signal.low ||
      previous.high<MathMax(previous.open,previous.close) ||
      previous.low>MathMin(previous.open,previous.close) ||
      signal.high<MathMax(signal.open,signal.close) ||
      signal.low>MathMin(signal.open,signal.close))
      return false;

   const bool reversal_pair=(want_buy ?
      (previous.close<previous.open && signal.close>signal.open) :
      (previous.close>previous.open && signal.close<signal.open));
   if(!reversal_pair)
      return true;

   const bool pass=(want_buy ? signal.close>previous.high : signal.close<previous.low);
   if(PrintSignalLog && !pass)
      PrintFormat("MOMENTUM %s OPP COLOR BREAKOUT [1-2] BLOCK: [2]=%s [1]=%s, Close[1]=%.*f %s %s[2]=%.*f (strict)",
                  (want_buy ? "BUY" : "SELL"),(want_buy ? "RED" : "GREEN"),
                  (want_buy ? "GREEN" : "RED"),_Digits,signal.close,
                  (want_buy ? "<=" : ">="),(want_buy ? "High" : "Low"),
                  _Digits,(want_buy ? previous.high : previous.low));
   return pass;
}

// 04.5 ENTRY ONLY: signal M5 [1] body must not be smaller than either
// individual wick. This is independent of the directional wick/SMA8 test.
bool PassMomentumBodyVsBothWicks1Filter()
{
   if(!UseMomentumBodyVsBothWicks1Filter)
      return true;

   MqlRates candle[1];
   if(CopyRates(_Symbol,PERIOD_M5,1,1,candle)!=1)
      return false;
   const MqlRates bar=candle[0];
   if(!MathIsValidNumber(bar.open) || !MathIsValidNumber(bar.high) ||
      !MathIsValidNumber(bar.low) || !MathIsValidNumber(bar.close) ||
      bar.high<bar.low || bar.high<MathMax(bar.open,bar.close) ||
      bar.low>MathMin(bar.open,bar.close))
      return false;

   const double body=MathAbs(bar.close-bar.open);
   const double upper_wick=bar.high-MathMax(bar.open,bar.close);
   const double lower_wick=MathMin(bar.open,bar.close)-bar.low;
   const bool pass=(body>0.0 && body>=upper_wick && body>=lower_wick);
   if(PrintSignalLog && !pass)
      PrintFormat("MOMENTUM BODY/WICKS [1] BLOCK: body=%.*f upper=%.*f lower=%.*f (require Body >= each wick)",
                  _Digits,body,_Digits,upper_wick,_Digits,lower_wick);
   return pass;
}

// 04.5 ENTRY ONLY: directional Bollinger Band close boundary on CLOSED M5 [1].
// iBands buffers: 1=upper, 2=lower (0=middle). A missing sample blocks entry.
bool PassMomentumBollingerCloseFilter(const bool want_buy)
{
   if(!UseMomentumBollingerCloseFilter)
      return true;

   if(g_momentum_bbands_handle==INVALID_HANDLE ||
      BarsCalculated(g_momentum_bbands_handle)<MomentumBollingerPeriod+SIGNAL_SHIFT)
      return false;

   MqlRates signal[1];
   if(CopyRates(_Symbol,PERIOD_M5,SIGNAL_SHIFT,1,signal)!=1 ||
      !MathIsValidNumber(signal[0].close) || signal[0].close<=0.0)
      return false;

   double band[1];
   if(CopyBuffer(g_momentum_bbands_handle,(want_buy ? 1 : 2),SIGNAL_SHIFT,1,band)!=1 ||
      !MathIsValidNumber(band[0]) || band[0]==EMPTY_VALUE || band[0]<=0.0)
      return false;

   const double close1=signal[0].close;
   const bool pass=(want_buy ? close1<=band[0] : close1>=band[0]);
   if(PrintSignalLog && !pass)
      PrintFormat("MOMENTUM %s BOLLINGER [1] BLOCK: Close[1]=%.*f %s %s[1]=%.*f (BB(%d,%.2f), CLOSE)",
                  (want_buy ? "BUY" : "SELL"),_Digits,close1,
                  (want_buy ? ">" : "<"),(want_buy ? "UPPER" : "LOWER"),
                  _Digits,band[0],MomentumBollingerPeriod,MomentumBollingerDeviation);
   return pass;
}

// 04.5 ENTRY ONLY: qualify the initial entry without tightening legacy recovery.
// No live [0] prices and no changes to opposite-signal exit evaluation.
bool PassMomentumInitialEntryQualityFilter(const bool want_buy)
{
   if(!UseMomentumInitialEntryQualityFilter || CountMyPositions()>0)
      return true;

   // ADAPTIVE 04.5 QUALITY: the initial breakout must agree with the
   // fully CLOSED M15 direction before the existing higher-frame checks.
   double initial_m15_fast=0.0,initial_m15_slow=0.0;
   if(!TryReadMA(g_fast_ma_handles[1],SIGNAL_SHIFT,initial_m15_fast) ||
      !TryReadMA(g_slow_ma_handles[1],SIGNAL_SHIFT,initial_m15_slow))
      return false;
   if(want_buy ? initial_m15_fast<=initial_m15_slow : initial_m15_fast>=initial_m15_slow)
      return false;

   // ADAPTIVE 04.5 QUALITY: confirm the CLOSED M30 direction and both
   // MA slopes before seeding a new basket; no effect on held recovery.
   double initial_m30_fast1=0.0,initial_m30_slow1=0.0;
   double initial_m30_fast2=0.0,initial_m30_slow2=0.0;
   if(!TryReadMA(g_fast_ma_handles[2],1,initial_m30_fast1) ||
      !TryReadMA(g_slow_ma_handles[2],1,initial_m30_slow1) ||
      !TryReadMA(g_fast_ma_handles[2],2,initial_m30_fast2) ||
      !TryReadMA(g_slow_ma_handles[2],2,initial_m30_slow2))
      return false;
   if(want_buy ?
      !(initial_m30_fast1>initial_m30_slow1 &&
        initial_m30_fast1>initial_m30_fast2 && initial_m30_slow1>initial_m30_slow2) :
      !(initial_m30_fast1<initial_m30_slow1 &&
        initial_m30_fast1<initial_m30_fast2 && initial_m30_slow1<initial_m30_slow2))
      return false;

   // 04.5 INITIAL ENTRY ONLY: do not seed a basket from stale H4 context
   // across a missing trading interval. Use the CLOSED H4 bar time and
   // historical server tick time, never a live H4 price or a calendar date.
   const datetime h4_open=iTime(_Symbol,PERIOD_H4,SIGNAL_SHIFT);
   const int h4_seconds=PeriodSeconds(PERIOD_H4);
   if(h4_open<=0 || h4_seconds<=0)
      return false;
   const datetime h4_close=h4_open+h4_seconds;
   const datetime evaluation_time=TimeCurrent();
   if(evaluation_time<h4_close || evaluation_time-h4_close>=h4_seconds)
      return false;

   // 04.5 INITIAL ENTRY ONLY: require closed H1 AND H4 trend agreement.
   // MA handles for H1 index 3 and H4 index 4 already exist unconditionally.
   // SIGNAL_SHIFT=1 reads completed higher-timeframe bars, never live [0].
   // Existing positions bypass this gate above, preserving legacy recovery.
   for(int tf_index=3;tf_index<=4;tf_index++)
   {
      double higher_fast=0.0,higher_slow=0.0;
      if(!TryReadMA(g_fast_ma_handles[tf_index],SIGNAL_SHIFT,higher_fast) ||
         !TryReadMA(g_slow_ma_handles[tf_index],SIGNAL_SHIFT,higher_slow))
         return false;
      if(want_buy ? higher_fast<=higher_slow : higher_fast>=higher_slow)
         return false;
   }

   // N+2 CLOSED bars: current breakout uses [2..N+1], prior uses [3..N+2].
   // Preserve the existing supported lookback range N=1..OHLCV_HISTORY-1.
   const int count=MomentumBreakoutLookbackBars+2;
   if(count<3 || count>OHLCV_HISTORY+1)
      return false;
   MqlRates bars[];
   if(ArrayResize(bars,count)!=count ||
      CopyRates(_Symbol,PERIOD_M5,SIGNAL_SHIFT,count,bars)!=count)
      return false;
   for(int i=0;i<count;i++)
   {
      if(!MathIsValidNumber(bars[i].open) || !MathIsValidNumber(bars[i].close) ||
         !MathIsValidNumber(bars[i].high) || !MathIsValidNumber(bars[i].low) ||
         bars[i].high<MathMax(bars[i].open,bars[i].close) ||
         bars[i].low>MathMin(bars[i].open,bars[i].close))
         return false;
   }

   const MqlRates signal=bars[count-1]; // [1]
   const MqlRates previous=bars[count-2]; // [2]
   const double body1=MathAbs(signal.close-signal.open);
   const double range1=signal.high-signal.low;
   if(!MathIsValidNumber(body1) || !MathIsValidNumber(range1) ||
      body1<=0.0 || range1<=0.0)
      return false;

   // ADAPTIVE 04.5 QUALITY: initial close must remain in the outer
   // directional quarter of its CLOSED signal candle, limiting rejection.
   const double initial_end_wick=(want_buy ? signal.high-signal.close : signal.close-signal.low);
   if(initial_end_wick>range1*0.25)
      return false;

   double previous_atr=0.0;
   if(!ReadEntryQualityATR(2,previous_atr) ||
      range1>MomentumMaxRangeATR*previous_atr)
      return false;

   // ADAPTIVE 04.5 QUALITY: an initial momentum signal must span at least
   // half of the pre-signal ATR. Both range[1] and ATR[2] are closed data.
   // Keep this local to the flat-entry quality gate, not legacy recovery.
   if(range1<previous_atr*0.50)
      return false;

   // ADAPTIVE 04.5 QUALITY: strengthen the initial impulse requirement.
   // Existing rules remain intact; signal[1] must span 0.8 of ATR[2].
   if(range1<previous_atr*0.80)
      return false;

   // ADAPTIVE 04.5 QUALITY: avoid chasing an initial breakout too far
   // from its CLOSED M5 SMA8, normalized by the pre-signal ATR[2].
   double initial_fast_m5=0.0;
   if(!TryReadMA(g_fast_ma_handles[0],SIGNAL_SHIFT,initial_fast_m5))
      return false;
   const double initial_fast_distance=MathAbs(signal.close-initial_fast_m5);
   if(initial_fast_distance>previous_atr*1.25)
      return false;

   double highest=bars[1].high;
   double lowest=bars[1].low;
   for(int i=2;i<count-1;i++)
   {
      highest=MathMax(highest,bars[i].high);
      lowest=MathMin(lowest,bars[i].low);
   }
   const double extension=(want_buy ? signal.close-highest : lowest-signal.close);
   if(!MathIsValidNumber(extension) || extension<=0.0 ||
      extension>body1*0.50+_Point*1e-8)
      return false;

   // ADAPTIVE 04.5 QUALITY: reject a merely marginal initial breakout.
   // CLOSED signal[1] must penetrate the old range by at least 10% of body.
   if(extension<body1*0.10)
      return false;

   double previous_highest=bars[0].high;
   double previous_lowest=bars[0].low;
   for(int i=1;i<count-2;i++)
   {
      previous_highest=MathMax(previous_highest,bars[i].high);
      previous_lowest=MathMin(previous_lowest,bars[i].low);
   }
   return (want_buy ? previous.close<=previous_highest : previous.close>=previous_lowest);
}

// Function: PassEntryMomentumBreakoutFilter - Return the matching momentum OR trigger.
// All optional Momentum gates are ENTRY ONLY; old opposite-signal exits
// still skip them with check_entry_ratio=false.
bool PassEntryMomentumBreakoutFilter(const bool want_buy,
                                    const bool check_entry_ratio=true)
{
   bool buy_breakout=false,sell_breakout=false;
   if(!ReadMomentumBreakout(buy_breakout,sell_breakout,check_entry_ratio))
      return false;
   if(!(want_buy ? buy_breakout : sell_breakout))
      return false;
   if(!check_entry_ratio)
      return true;
   if(!PassMomentumInitialEntryQualityFilter(want_buy))
      return false;
   if(!PassMomentumSlopeEntryFilter(want_buy))
      return false;
   if(!PassMomentumSMA8Slope13Filter(want_buy))
      return false;
   if(!PassMomentumOppositeBody25Filter(want_buy))
      return false;
   if(!PassMomentumOppositeColorBreakout12Filter(want_buy))
      return false;
   if(!PassMomentumBodyVsBothWicks1Filter())
      return false;
   return PassMomentumBollingerCloseFilter(want_buy);
}

// OR #4: SMA pullback and rejection, evaluated on closed M5 [2] and [1].
// Return -1 on unavailable data; 0 when pattern absent; 1 for signal wick
// rejection; 2 for entry price too far from SMA8; 3 when fully qualified;
// 4 when [2] is not the opposite non-Doji candle color to [1];
// 5 when the optional [2] upper/lower wick relationship is rejected;
// 6 when the optional [2] Close to [1] Open gap exceeds the allowed points;
// 7 when [1] fails breakout beyond the extreme of [2]..[5];
// 8 when [3] Open or Close is not on the trend side of SMA12[3];
// 9 when SMA8/SMA12 distance narrows across [3]->[2]->[1];
// 11 when the optional [3] Close to [2] Open gap exceeds the allowed points.
// The independent global entry gates are NOT modified by this local filter.
bool PassSMAPullbackShortHoldQuality(const bool want_buy,const MqlRates &signal,const double atr2)
{
   if(UseSMAPullbackShortHoldQualityFilter)
   {
      const double range=signal.high-signal.low;
      if(!MathIsValidNumber(range) || range<=0.0) return false;
      if(range<SMAPullbackMinSignalRangeATR*atr2) return false;

      const double body=MathAbs(signal.close-signal.open);
      if(body<SMAPullbackMinBodyFraction*range) return false;

      const double end_wick=(want_buy ? signal.high-signal.close : signal.close-signal.low);
      if(end_wick>SMAPullbackMaxEndWickFraction*range) return false;
   }

   if(UseSMAPullbackM15TrendFilter)
   {
      double m15_fast=0.0,m15_slow=0.0;
      if(!TryReadMA(g_fast_ma_handles[1],1,m15_fast) ||
         !TryReadMA(g_slow_ma_handles[1],1,m15_slow))
         return false;
      if(want_buy ? (m15_fast<=m15_slow) : (m15_fast>=m15_slow))
         return false;
   }
   if(UseSMAPullbackH1TrendFilter)
   {
      double h1_fast=0.0,h1_slow=0.0;
      if(!TryReadMA(g_fast_ma_handles[3],1,h1_fast) ||
         !TryReadMA(g_slow_ma_handles[3],1,h1_slow))
         return false;
      if(want_buy ? (h1_fast<=h1_slow) : (h1_fast>=h1_slow))
         return false;
   }
   return true;
}

int EvaluateSMAPullbackRejection(const bool want_buy)
{
   MqlRates bars[2];
   // Static CopyRates output is in chronological order: [2], then [1].
   if(CopyRates(_Symbol,PERIOD_M5,SIGNAL_SHIFT,2,bars)!=2)
      return -1;

   MqlRates pullback=bars[0];   // Closed M5 [2]
   MqlRates signal=bars[1];     // Closed M5 [1]
   if(!MathIsValidNumber(pullback.open) || !MathIsValidNumber(pullback.close) ||
      !MathIsValidNumber(pullback.high) || !MathIsValidNumber(pullback.low) ||
      !MathIsValidNumber(signal.open) || !MathIsValidNumber(signal.close) ||
      !MathIsValidNumber(signal.high) || !MathIsValidNumber(signal.low) ||
      pullback.high<pullback.low || signal.high<signal.low ||
      pullback.high<MathMax(pullback.open,pullback.close) ||
      pullback.low>MathMin(pullback.open,pullback.close) ||
      signal.high<MathMax(signal.open,signal.close) ||
      signal.low>MathMin(signal.open,signal.close))
      return -1;

   double fast1=0.0,slow1=0.0,fast2=0.0,slow2=0.0;
   if(!TryReadMA(g_fast_ma_handles[0],1,fast1) ||
      !TryReadMA(g_slow_ma_handles[0],1,slow1) ||
      !TryReadMA(g_fast_ma_handles[0],2,fast2) ||
      !TryReadMA(g_slow_ma_handles[0],2,slow2))
      return -1;

   // [2] must touch SMA8 and close on the trend side of SMA8; [1] breaks [2].
   const bool setup=(want_buy ?
      (fast1>slow1 && pullback.low<=fast2 && pullback.close>fast2 && pullback.close>slow2 &&
       signal.close>signal.open && signal.close>pullback.high) :
      (fast1<slow1 && pullback.high>=fast2 && pullback.close<fast2 && pullback.close<slow2 &&
       signal.close<signal.open && signal.close<pullback.low));
   if(!setup) return 0;

   // 04.6 ONLY: close [1] must break the extreme of four CLOSED M5
   // candles [2]..[5]. Strict inequality; equality does not pass.
   // CopyRates fixed array is oldest -> newest: range_bars[0]=[5], [3]=[2].
   MqlRates range_bars[4];
   if(CopyRates(_Symbol,PERIOD_M5,2,4,range_bars)!=4)
      return -1;
   double highest_high=-DBL_MAX;
   double lowest_low=DBL_MAX;
   for(int i=0;i<4;i++)
   {
      if(!MathIsValidNumber(range_bars[i].high) ||
         !MathIsValidNumber(range_bars[i].low) ||
         range_bars[i].high<range_bars[i].low)
         return -1;
      highest_high=MathMax(highest_high,range_bars[i].high);
      lowest_low=MathMin(lowest_low,range_bars[i].low);
   }
   if(want_buy ? (signal.close<=highest_high) : (signal.close>=lowest_low))
      return 7;

   // Retain the pre-existing [3] SMA12 check unchanged.
   MqlRates third[1];
   if(CopyRates(_Symbol,PERIOD_M5,3,1,third)!=1 ||
      !MathIsValidNumber(third[0].high) || !MathIsValidNumber(third[0].low) ||
      third[0].high<third[0].low)
      return -1;

   // 04.6 ONLY: both Open[3] and Close[3] must lie on the same
   // trend-side of the closed SMA12[3]. No live [0] values are used.
   double slow3=0.0;
   if(!TryReadMA(g_slow_ma_handles[0],3,slow3) ||
      !MathIsValidNumber(third[0].open) || !MathIsValidNumber(third[0].close) ||
      third[0].high<MathMax(third[0].open,third[0].close) ||
      third[0].low>MathMin(third[0].open,third[0].close))
      return -1;
   const bool candle3_above_below_sma12=(want_buy ?
      (third[0].open>slow3 && third[0].close>slow3) :
      (third[0].open<slow3 && third[0].close<slow3));
   if(!candle3_above_below_sma12) return 8;

   // 04.6 ONLY: SMA8/SMA12 separation must not narrow from [3] to [2]
   // or from [2] to [1]. A flat (equal) separation is allowed.
   // The trend direction must remain valid on ALL three closed bars.
   double fast3=0.0;
   if(!TryReadMA(g_fast_ma_handles[0],3,fast3)) return -1;
   const double gap1=(want_buy ? fast1-slow1 : slow1-fast1);
   const double gap2=(want_buy ? fast2-slow2 : slow2-fast2);
   const double gap3=(want_buy ? fast3-slow3 : slow3-fast3);
   if(gap1<=0.0 || gap2<=0.0 || gap3<=0.0 ||
      gap1<gap2 || gap2<gap3)
      return 9;

   // A genuine one-candle pullback must be opposite to the [1] signal.
   // [1] direction is already confirmed by setup. Equal Open/Close = Doji,
   // so it is deliberately rejected on the pullback candle [2].
   const bool opposite_pullback=(want_buy ?
      (pullback.close<pullback.open) :
      (pullback.close>pullback.open));
   if(!opposite_pullback) return 4;

   // Optional ENTRY-only wick shape on the fully closed pullback bar [2].
   // BUY [2] is red: upper wick must NOT exceed the lower wick.
   // SELL [2] is green: lower wick must NOT exceed the upper wick.
   // CopyRates static array bars[0] == M5 shift [2] (never [3]).
   if(UseSMAPullbackCandle2WickFilter)
   {
      const double upper_wick2=pullback.high-MathMax(pullback.open,pullback.close);
      const double lower_wick2=MathMin(pullback.open,pullback.close)-pullback.low;
      if(!MathIsValidNumber(upper_wick2) || !MathIsValidNumber(lower_wick2) ||
         upper_wick2<0.0 || lower_wick2<0.0)
         return -1;
      if(want_buy ? (upper_wick2>lower_wick2) : (lower_wick2>upper_wick2))
         return 5;
   }

   // 04.6 ONLY: check the earlier consecutive-candle opening gap.
   // BUY and SELL use the same absolute distance: Open[2] vs Close[3].
   // The [3] candle was already loaded above; [2] is `pullback`.
   if(UseSMAPullbackOpenGap23Filter)
   {
      const double pt=InputPointSize();
      if(pt<=0.0) return -1;
      const double gap23_points=MathAbs(pullback.open-third[0].close)/pt;
      if(!MathIsValidNumber(gap23_points)) return -1;
      if(gap23_points>(double)SMAPullbackMaxOpenGap23Points+1e-6) return 11;
   }

   // Check closed [2] Close against the already closed [1] Open.
   // Absolute gap blocks both upward and downward discontinuities equally.
   if(UseSMAPullbackOpenGapFilter)
   {
      const double pt=InputPointSize();
      if(pt<=0.0) return -1;
      const double open_gap_points=MathAbs(signal.open-pullback.close)/pt;
      if(!MathIsValidNumber(open_gap_points)) return -1;
      if(open_gap_points>(double)SMAPullbackMaxOpenGapPoints+1e-6) return 6;
   }

   const double body=MathAbs(signal.close-signal.open);
   const double directional_wick=(want_buy ?
      signal.high-MathMax(signal.open,signal.close) :
      MathMin(signal.open,signal.close)-signal.low);
   if(body<=directional_wick) return 1;

   // The limit uses ATR[2], before the confirmation candle can inflate ATR.
   double atr2=0.0;
   if(!ReadEntryQualityATR(2,atr2)) return -1;
   if(!PassSMAPullbackShortHoldQuality(want_buy,signal,atr2)) return 12;
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick) || _Point<=0.0 ||
      tick.ask<=0.0 || tick.bid<=0.0 || tick.ask<tick.bid)
      return -1;
   const double entry=(want_buy ? tick.ask : tick.bid);
   const double distance=MathAbs(entry-fast1);
   if(!MathIsValidNumber(distance)) return -1;
   if(distance>SMAPullbackMaxDistanceATR*atr2+_Point*1e-6) return 2;
   return 3;
}

bool PassEntrySMAPullbackRejectionFilter(const bool want_buy)
{
   return (EvaluateSMAPullbackRejection(want_buy)==3);
}

// BEGIN NEW OR 04.8 FUNCTIONS
// Reject this NEW source when any enabled legacy OR already matches either
// side of this bar. Calling the old predicates never changes their switches.
bool RangeSweepLegacyORAlreadyMatches(const IndicatorState &s)
{
   for(int side=0;side<2;side++)
   {
      const bool want_buy=(side==0);
      if((UseCandleColorEntryFilter && PassEntryCandleColorFilter(s,want_buy,true)) ||
         (UseTwoCandleSMAContinuationEntryFilter && PassTwoCandleSMAContinuationEntryFilter(want_buy)) ||
         (UseMomentumBreakoutEntryFilter && PassEntryMomentumBreakoutFilter(want_buy)) ||
         (UseSMAPullbackRejectionEntryFilter && PassEntrySMAPullbackRejectionFilter(want_buy)) ||
         (UseSMACrossConfirmedEntryFilter && PassEntrySMACrossConfirmedFilter(want_buy)))
         return true;
   }
   return false;
}

bool PassRangeSweepReclaimEntryFilter(const IndicatorState &s,const bool want_buy)
{
   if(!UseRangeSweepReclaimEntryFilter || CountMyPositions()>0)
      return false;
   if(RangeSweepLookbackBars<2 || RangeSweepLookbackBars>=OHLCV_HISTORY)
      return false;
   // Only the new bar TIME is read at shift zero, never its changing price.
   // Require a fresh signal after a normal M5 interval rather than a session gap.
   const datetime entry_bar_time=iTime(_Symbol,PERIOD_M5,0);
   if(entry_bar_time<=0 || entry_bar_time-s.ohlcv_time[0]!=PeriodSeconds(PERIOD_M5))
      return false;
   double range_high=s.ohlcv_high[1],range_low=s.ohlcv_low[1];
   for(int i=1;i<=RangeSweepLookbackBars;i++)
   {
      if(!MathIsValidNumber(s.ohlcv_high[i]) || !MathIsValidNumber(s.ohlcv_low[i]) ||
         s.ohlcv_high[i]<s.ohlcv_low[i])
         return false;
      range_high=MathMax(range_high,s.ohlcv_high[i]);
      range_low=MathMin(range_low,s.ohlcv_low[i]);
   }
   const double signal_open=s.ohlcv_open[0],signal_close=s.ohlcv_close[0];
   const double signal_high=s.ohlcv_high[0],signal_low=s.ohlcv_low[0];
   const double body=MathAbs(signal_close-signal_open);
   const double signal_range=signal_high-signal_low;
   if(!MathIsValidNumber(body) || !MathIsValidNumber(signal_range) || body<=0.0 || signal_range<=0.0)
      return false;
   const double prior_midpoint=(s.ohlcv_open[1]+s.ohlcv_close[1])*0.5;
   if(want_buy)
   {
      if(!(s.ohlcv_close[1]<s.ohlcv_open[1] && signal_close>signal_open &&
           signal_low<range_low && signal_close>range_low && signal_close<range_high &&
           signal_high<=range_high && signal_close<=s.ohlcv_high[1] && signal_close>prior_midpoint))
         return false;
   }
   else
   {
      if(!(s.ohlcv_close[1]>s.ohlcv_open[1] && signal_close<signal_open &&
           signal_high>range_high && signal_close>range_low && signal_close<range_high &&
           signal_low>=range_low && signal_close>=s.ohlcv_low[1] && signal_close<prior_midpoint))
         return false;
   }
   // A rejection wick at least as large as its body, rather than the old
   // continuation/breakout confirmation beyond [2]. No double-sided sweep.
   const double rejection_wick=(want_buy ? MathMin(signal_open,signal_close)-signal_low :
                                                   signal_high-MathMax(signal_open,signal_close));
   if(rejection_wick<body)
      return false;
   // SMA direction is established on three CLOSED M5 bars, excluding the
   // crossover at [2] that defines the existing Cross+1Bar OR.
   for(int shift=1;shift<=3;shift++)
   {
      double fast=0.0,slow=0.0;
      if(!TryReadMA(g_fast_ma_handles[0],shift,fast) || !TryReadMA(g_slow_ma_handles[0],shift,slow))
         return false;
      if(want_buy ? fast<=slow : fast>=slow)
         return false;
   }
   if(UseRangeSweepMTFTrendFilter)
   {
      for(int tf=1;tf<TF_COUNT;tf++)
      {
         double fast=0.0,slow=0.0;
         if(!TryReadMA(g_fast_ma_handles[tf],SIGNAL_SHIFT,fast) ||
            !TryReadMA(g_slow_ma_handles[tf],SIGNAL_SHIFT,slow))
            return false;
         if(want_buy ? fast<=slow : fast>=slow)
            return false;
      }
   }
   if(UseRangeSweepM30SlopeFilter)
   {
      double fast1=0.0,fast2=0.0,slow1=0.0,slow2=0.0;
      if(!TryReadMA(g_fast_ma_handles[2],1,fast1) || !TryReadMA(g_fast_ma_handles[2],2,fast2) ||
         !TryReadMA(g_slow_ma_handles[2],1,slow1) || !TryReadMA(g_slow_ma_handles[2],2,slow2))
         return false;
      if(want_buy ? !(fast1>fast2 && slow1>slow2) : !(fast1<fast2 && slow1<slow2))
         return false;
   }
   if(UseRangeSweepSignalQualityFilter)
   {
      double atr2=0.0;
      if(!ReadEntryQualityATR(2,atr2) || signal_range<RangeSweepMinRangeATR*atr2 ||
         signal_range>RangeSweepMaxRangeATR*atr2)
         return false;
      const double end_wick=(want_buy ? signal_high-signal_close : signal_close-signal_low);
      if(end_wick>RangeSweepMaxEndWickFraction*signal_range)
         return false;
   }
   return !RangeSweepLegacyORAlreadyMatches(s);
}
// END NEW OR 04.8 FUNCTIONS

// BEGIN FIVE NEW OR FUNCTIONS (04.9 through 04.13)
bool NewORIsEnabled(const int entry_id)
{
   switch(entry_id)
   {
      case 9: return UseInsideBarReleaseEntryFilter;
      case 10: return UseBreakRetestHoldEntryFilter;
      case 11: return UseImbalanceRetestEntryFilter;
      case 12: return UseOutsideBarTrapEntryFilter;
      case 13: return UseSMAGapReleaseEntryFilter;
   }
   return false;
}

bool NewORAnyEnabled()
{
   for(int id=9;id<=13;id++) if(NewORIsEnabled(id)) return true;
   return false;
}

string NewORTag(const int entry_id)
{
   switch(entry_id)
   {
      case 9: return "IN_REL";
      case 10: return "BR_RET";
      case 11: return "FVG_RET";
      case 12: return "OUT_TRAP";
      case 13: return "GAP_REL";
   }
   return "UNKNOWN";
}

void NewORQualityParameters(const int entry_id,double &min_range,double &max_range,
                            double &end_wick,double &fast_distance)
{
   min_range=0.8; max_range=1.8; end_wick=0.25; fast_distance=0.0;
   switch(entry_id)
   {
      case 9: min_range=InsideReleaseMinRangeATR; max_range=InsideReleaseMaxRangeATR; end_wick=InsideReleaseMaxEndWickFraction; fast_distance=InsideReleaseMaxCloseFastATR; break;
      case 10: min_range=BreakRetestMinRangeATR; max_range=BreakRetestMaxRangeATR; end_wick=BreakRetestMaxEndWickFraction; fast_distance=BreakRetestMaxCloseFastATR; break;
      case 11: min_range=ImbalanceRetestMinRangeATR; max_range=ImbalanceRetestMaxRangeATR; end_wick=ImbalanceRetestMaxEndWickFraction; fast_distance=0.0; break;
      case 12: min_range=OutsideTrapMinRangeATR; max_range=OutsideTrapMaxRangeATR; end_wick=OutsideTrapMaxEndWickFraction; fast_distance=0.0; break;
      case 13: min_range=SMAGapReleaseMinRangeATR; max_range=SMAGapReleaseMaxRangeATR; end_wick=SMAGapReleaseMaxEndWickFraction; fast_distance=0.0; break;
   }
}

// Uses only closed price/indicator shifts. Shift zero is a bar TIME only.
bool NewORQuality(const IndicatorState &s,const bool want_buy,const int entry_id)
{
   const int closed_count=(entry_id==13 ? 5 : 4);
   const int seconds=PeriodSeconds(PERIOD_M5);
   if(iTime(_Symbol,PERIOD_M5,0)-s.ohlcv_time[0]!=seconds)
      return false;
   for(int i=0;i<closed_count-1;i++)
      if(s.ohlcv_time[i]-s.ohlcv_time[i+1]!=seconds) return false;
   const double candle_range=s.high-s.low;
   if(!MathIsValidNumber(candle_range) || candle_range<=0.0 ||
      (want_buy ? s.close<=s.open : s.close>=s.open)) return false;
   double min_range,max_range,end_wick,fast_distance,atr2=0.0;
   NewORQualityParameters(entry_id,min_range,max_range,end_wick,fast_distance);
   if(!ReadEntryQualityATR(2,atr2) || candle_range<min_range*atr2 || candle_range>max_range*atr2)
      return false;
   if((want_buy ? s.high-s.close : s.close-s.low)>end_wick*candle_range) return false;
   double fast1=0.0;
   for(int shift=1;shift<=3;shift++)
   {
      double fast=0.0,slow=0.0;
      if(!TryReadMA(g_fast_ma_handles[0],shift,fast) || !TryReadMA(g_slow_ma_handles[0],shift,slow)) return false;
      if(want_buy ? fast<=slow : fast>=slow) return false;
      if(shift==1) fast1=fast;
   }
   if(fast_distance>0.0 && MathAbs(s.close-fast1)>fast_distance*atr2) return false;
   for(int tf=1;tf<TF_COUNT;tf++)
   {
      double fast=0.0,slow=0.0;
      if(!TryReadMA(g_fast_ma_handles[tf],1,fast) || !TryReadMA(g_slow_ma_handles[tf],1,slow)) return false;
      if(want_buy ? fast<=slow : fast>=slow) return false;
   }
   double f1=0.0,f2=0.0,s1=0.0,s2=0.0;
   if(!TryReadMA(g_fast_ma_handles[2],1,f1) || !TryReadMA(g_fast_ma_handles[2],2,f2) ||
      !TryReadMA(g_slow_ma_handles[2],1,s1) || !TryReadMA(g_slow_ma_handles[2],2,s2)) return false;
   return want_buy ? (f1>f2 && s1>s2) : (f1<f2 && s1<s2);
}

bool NewORPricePattern(const IndicatorState &s,const bool want_buy,const int entry_id)
{
   // Physical history index zero is the latest fully CLOSED candle [1].
   if(entry_id==9)
   {
      if(!(s.ohlcv_high[1]<s.ohlcv_high[2] && s.ohlcv_low[1]>s.ohlcv_low[2])) return false;
      return want_buy ? (s.ohlcv_close[1]>s.ohlcv_open[1] && s.close>s.ohlcv_high[2] && s.close<=s.ohlcv_high[3]) :
                        (s.ohlcv_close[1]<s.ohlcv_open[1] && s.close<s.ohlcv_low[2] && s.close>=s.ohlcv_low[3]);
   }
   if(entry_id==10)
   {
      double level=(want_buy ? s.ohlcv_high[3] : s.ohlcv_low[3]);
      for(int i=4;i<=8;i++) level=want_buy ? MathMax(level,s.ohlcv_high[i]) : MathMin(level,s.ohlcv_low[i]);
      double fast1=0.0;
      if(!TryReadMA(g_fast_ma_handles[0],1,fast1)) return false;
      return want_buy ?
         (s.ohlcv_close[2]>s.ohlcv_open[2] && s.ohlcv_close[2]>level &&
          s.ohlcv_close[1]<s.ohlcv_open[1] && s.ohlcv_low[1]<=level && s.ohlcv_close[1]>=level &&
          s.close>s.ohlcv_close[1] && s.close>level && s.high<=s.ohlcv_high[2] && s.low>=s.ohlcv_low[1] && s.low>fast1) :
         (s.ohlcv_close[2]<s.ohlcv_open[2] && s.ohlcv_close[2]<level &&
          s.ohlcv_close[1]>s.ohlcv_open[1] && s.ohlcv_high[1]>=level && s.ohlcv_close[1]<=level &&
          s.close<s.ohlcv_close[1] && s.close<level && s.low>=s.ohlcv_low[2] && s.high<=s.ohlcv_high[1] && s.high<fast1);
   }
   if(entry_id==11)
   {
      const double displacement_range=s.ohlcv_high[2]-s.ohlcv_low[2];
      if(displacement_range<=0.0 || MathAbs(s.ohlcv_close[2]-s.ohlcv_open[2])<0.60*displacement_range) return false;
      return want_buy ?
         (s.ohlcv_high[3]<s.ohlcv_low[1] && s.ohlcv_close[2]>s.ohlcv_open[2] &&
          s.ohlcv_close[1]>s.ohlcv_open[1] && s.low>s.ohlcv_high[3] && s.low<=s.ohlcv_low[1] &&
          s.close>s.ohlcv_low[1] && s.close<=s.ohlcv_high[1]) :
         (s.ohlcv_low[3]>s.ohlcv_high[1] && s.ohlcv_close[2]<s.ohlcv_open[2] &&
          s.ohlcv_close[1]<s.ohlcv_open[1] && s.high<s.ohlcv_low[3] && s.high>=s.ohlcv_high[1] &&
          s.close<s.ohlcv_high[1] && s.close>=s.ohlcv_low[1]);
   }
   if(entry_id==12)
   {
      if(!(s.ohlcv_high[1]>s.ohlcv_high[2] && s.ohlcv_low[1]<s.ohlcv_low[2] &&
           s.high<=s.ohlcv_high[1] && s.low>=s.ohlcv_low[1])) return false;
      return want_buy ? (s.ohlcv_close[1]<s.ohlcv_open[1] && s.close>s.ohlcv_open[1]) :
                        (s.ohlcv_close[1]>s.ohlcv_open[1] && s.close<s.ohlcv_open[1]);
   }
   if(entry_id==13)
   {
      double gap[5];
      double fast1=0.0;
      for(int shift=1;shift<=5;shift++)
      {
         double fast=0.0,slow=0.0;
         if(!TryReadMA(g_fast_ma_handles[0],shift,fast) || !TryReadMA(g_slow_ma_handles[0],shift,slow)) return false;
         gap[shift-1]=(want_buy ? fast-slow : slow-fast);
         if(shift==1) fast1=fast;
      }
      return gap[4]>gap[3] && gap[3]>gap[2] && gap[2]>gap[1] && gap[1]>0.0 && gap[0]>gap[1] &&
             s.close>s.ohlcv_low[1] && s.close<s.ohlcv_high[1] &&
             (want_buy ? s.close>fast1 : s.close<fast1);
   }
   return false;
}

// Reference legacy switches remain ON in isolated new tests, so their actual
// original predicates veto duplicate bars without changing any old helper.
bool NewORLegacyAlreadyMatches(const IndicatorState &s)
{
   if(RangeSweepLegacyORAlreadyMatches(s)) return true;
   return UseRangeSweepReclaimEntryFilter &&
          (PassRangeSweepReclaimEntryFilter(s,true) || PassRangeSweepReclaimEntryFilter(s,false));
}

bool PassFiveNewOREntry(const IndicatorState &s,const bool want_buy,const int entry_id)
{
   if(!NewORIsEnabled(entry_id) || CountMyPositions()>0) return false;
   if(!NewORPricePattern(s,want_buy,entry_id) || !NewORQuality(s,want_buy,entry_id)) return false;
   // Canonical priority is independent of master switches. The same eligible
   // bar cannot become a second new setup merely because it is tested alone.
   for(int earlier=9;earlier<entry_id;earlier++)
      if(NewORPricePattern(s,want_buy,earlier) && NewORQuality(s,want_buy,earlier)) return false;
   return !NewORLegacyAlreadyMatches(s);
}

bool PassAnyFiveNewOREntry(const IndicatorState &s,const bool want_buy)
{
   for(int id=9;id<=13;id++) if(PassFiveNewOREntry(s,want_buy,id)) return true;
   return false;
}
// END FIVE NEW OR FUNCTIONS

// BEGIN NEW OR 04.14 FUNCTIONS
// Physical history index zero is the latest fully CLOSED candle [1].
// All price/indicator observations are closed. Shift zero is bar TIME only.
bool PassTrendRunEntryFilter(const IndicatorState &s,const bool want_buy)
{
   if(!UseTrendRunEntryFilter || CountMyPositions()>0) return false;
   const int seconds=PeriodSeconds(PERIOD_M5);
   if(iTime(_Symbol,PERIOD_M5,0)-s.ohlcv_time[0]!=seconds) return false;
   for(int i=0;i<4;i++)
      if(s.ohlcv_time[i]-s.ohlcv_time[i+1]!=seconds) return false;
   double fast[5],slow[5];
   for(int i=0;i<5;i++)
   {
      if(!TryReadMA(g_fast_ma_handles[0],i+1,fast[i]) ||
         !TryReadMA(g_slow_ma_handles[0],i+1,slow[i])) return false;
      if(want_buy ? fast[i]<=slow[i] : fast[i]>=slow[i]) return false;
   }
   for(int i=0;i<2;i++)
   {
      if(want_buy ? !(fast[i]>fast[i+1] && slow[i]>slow[i+1]) :
                    !(fast[i]<fast[i+1] && slow[i]<slow[i+1])) return false;
      if(want_buy ? !(s.ohlcv_close[i]>s.ohlcv_open[i] && s.ohlcv_close[i]>fast[i]) :
                    !(s.ohlcv_close[i]<s.ohlcv_open[i] && s.ohlcv_close[i]<fast[i])) return false;
      if(want_buy ? !(s.ohlcv_close[i]>s.ohlcv_close[i+1] && s.ohlcv_low[i]>s.ohlcv_low[i+1]) :
                    !(s.ohlcv_close[i]<s.ohlcv_close[i+1] && s.ohlcv_high[i]<s.ohlcv_high[i+1])) return false;
   }
   double atr2=0.0;
   const double signal_range=s.high-s.low;
   if(!ReadEntryQualityATR(2,atr2) || !MathIsValidNumber(signal_range) || signal_range<=0.0 ||
      signal_range<TrendRunMinRangeATR*atr2 || signal_range>TrendRunMaxRangeATR*atr2) return false;
   const double end_wick=(want_buy ? s.high-s.close : s.close-s.low);
   if(end_wick>TrendRunMaxEndWickFraction*signal_range ||
      MathAbs(s.close-fast[0])>TrendRunMaxCloseFastATR*atr2) return false;
   // M15/M30 confirm the local run; optional H1/H4 direction reduces fading runs.
   // The older ORs keep their own original TF gates.
   const int last_tf=(TrendRunRequireHigherTF ? TF_COUNT-1 : 2);
   for(int tf=1;tf<=last_tf;tf++)
   {
      double f1=0.0,s1=0.0;
      if(!TryReadMA(g_fast_ma_handles[tf],1,f1) || !TryReadMA(g_slow_ma_handles[tf],1,s1)) return false;
      if(want_buy ? f1<=s1 : f1>=s1) return false;
      if(tf==2)
      {
         double f2=0.0,s2=0.0;
         if(!TryReadMA(g_fast_ma_handles[tf],2,f2) || !TryReadMA(g_slow_ma_handles[tf],2,s2)) return false;
         if(want_buy ? !(f1>f2 && s1>s2) : !(f1<f2 && s1<s2)) return false;
      }
   }
   // Preserve actual legacy predicates and canonical 04.9..04.13 eligibility.
   if(NewORLegacyAlreadyMatches(s)) return false;
   for(int id=9;id<=13;id++)
      if(NewORPricePattern(s,want_buy,id) && NewORQuality(s,want_buy,id)) return false;
   return true;
}
// END NEW OR 04.14 FUNCTIONS

// BEGIN NEW CONTINUATION OR FUNCTIONS (04.15 through 04.20)
bool ContinuationORIsEnabled(const int entry_id)
{
   switch(entry_id)
   {
      case 15: return UseFastTapResumeEntryFilter;
      case 16: return UsePauseResumeEntryFilter;
      case 17: return UseBodyEngulfResumeEntryFilter;
      case 18: return UseVolumeIgnitionEntryFilter;
      case 19: return UseSlopeAccelerationEntryFilter;
      case 20: return UseMicroChannelEntryFilter;
   }
   return false;
}

bool ContinuationORAnyEnabled()
{
   for(int id=15;id<=20;id++) if(ContinuationORIsEnabled(id)) return true;
   return false;
}

string ContinuationORTag(const int entry_id)
{
   switch(entry_id)
   {
      case 15: return "TAP_RUN";
      case 16: return "PAUSE_RUN";
      case 17: return "BODY_RUN";
      case 18: return "VOL_RUN";
      case 19: return "SLOPE_RUN";
      case 20: return "CHANNEL_RUN";
   }
   return "UNKNOWN";
}

void ContinuationORQualityParameters(const int entry_id,double &min_range,double &max_range,
                                     double &end_wick,double &fast_distance,bool &higher_tf)
{
   min_range=0.4; max_range=1.4; end_wick=0.25; fast_distance=0.9; higher_tf=true;
   switch(entry_id)
   {
      case 15: min_range=FastTapMinRangeATR; max_range=FastTapMaxRangeATR; end_wick=FastTapMaxEndWickFraction; fast_distance=FastTapMaxCloseFastATR; higher_tf=false; break;
      case 16: min_range=PauseResumeMinRangeATR; max_range=PauseResumeMaxRangeATR; end_wick=PauseResumeMaxEndWickFraction; fast_distance=PauseResumeMaxCloseFastATR; higher_tf=false; break;
      case 17: min_range=BodyEngulfMinRangeATR; max_range=BodyEngulfMaxRangeATR; end_wick=BodyEngulfMaxEndWickFraction; fast_distance=BodyEngulfMaxCloseFastATR; higher_tf=BodyEngulfRequireHigherTF; break;
      case 18: min_range=VolumeIgnitionMinRangeATR; max_range=VolumeIgnitionMaxRangeATR; end_wick=VolumeIgnitionMaxEndWickFraction; fast_distance=VolumeIgnitionMaxCloseFastATR; higher_tf=false; break;
      case 19: min_range=SlopeAccelMinRangeATR; max_range=SlopeAccelMaxRangeATR; end_wick=SlopeAccelMaxEndWickFraction; fast_distance=SlopeAccelMaxCloseFastATR; higher_tf=SlopeAccelRequireHigherTF; break;
      case 20: min_range=MicroChannelMinRangeATR; max_range=MicroChannelMaxRangeATR; end_wick=MicroChannelMaxEndWickFraction; fast_distance=MicroChannelMaxCloseFastATR; higher_tf=MicroChannelRequireHigherTF; break;
   }
}

// Closed prices/indicators only. Shift zero below is used for bar TIME only.
bool ContinuationORQuality(const IndicatorState &s,const bool want_buy,const int entry_id)
{
   const int seconds=PeriodSeconds(PERIOD_M5);
   const int closed_count=(entry_id==18 ? 9 : 5);
   if(iTime(_Symbol,PERIOD_M5,0)-s.ohlcv_time[0]!=seconds) return false;
   for(int i=0;i<closed_count-1;i++)
      if(s.ohlcv_time[i]-s.ohlcv_time[i+1]!=seconds) return false;
   const double signal_range=s.high-s.low;
   if(!MathIsValidNumber(signal_range) || signal_range<=0.0 ||
      (want_buy ? s.close<=s.open : s.close>=s.open)) return false;
   double min_range,max_range,end_wick,fast_distance,atr2=0.0;
   bool higher_tf=false;
   ContinuationORQualityParameters(entry_id,min_range,max_range,end_wick,fast_distance,higher_tf);
   if(!ReadEntryQualityATR(2,atr2) || signal_range<min_range*atr2 || signal_range>max_range*atr2) return false;
   if((want_buy ? s.high-s.close : s.close-s.low)>end_wick*signal_range) return false;
   double fast[5],slow[5];
   for(int i=0;i<5;i++)
   {
      if(!TryReadMA(g_fast_ma_handles[0],i+1,fast[i]) || !TryReadMA(g_slow_ma_handles[0],i+1,slow[i])) return false;
      if(want_buy ? fast[i]<=slow[i] : fast[i]>=slow[i]) return false;
   }
   for(int i=0;i<2;i++)
      if(want_buy ? !(fast[i]>fast[i+1] && slow[i]>slow[i+1]) :
                    !(fast[i]<fast[i+1] && slow[i]<slow[i+1])) return false;
   if((want_buy ? s.close<=fast[0] : s.close>=fast[0]) ||
      MathAbs(s.close-fast[0])>fast_distance*atr2) return false;
   const int last_tf=(higher_tf ? TF_COUNT-1 : 2);
   for(int tf=1;tf<=last_tf;tf++)
   {
      double f1=0.0,s1=0.0;
      if(!TryReadMA(g_fast_ma_handles[tf],1,f1) || !TryReadMA(g_slow_ma_handles[tf],1,s1)) return false;
      if(want_buy ? f1<=s1 : f1>=s1) return false;
      if(tf==2)
      {
         double f2=0.0,s2=0.0;
         if(!TryReadMA(g_fast_ma_handles[tf],2,f2) || !TryReadMA(g_slow_ma_handles[tf],2,s2)) return false;
         if(want_buy ? !(f1>f2 && s1>s2) : !(f1<f2 && s1<s2)) return false;
      }
   }
   return true;
}

bool ContinuationORPricePattern(const IndicatorState &s,const bool want_buy,const int entry_id)
{
   // Physical history index zero is the latest fully CLOSED candle [1].
   double fast1=0.0,fast2=0.0,slow1=0.0;
   if(!TryReadMA(g_fast_ma_handles[0],1,fast1) || !TryReadMA(g_fast_ma_handles[0],2,fast2) ||
      !TryReadMA(g_slow_ma_handles[0],1,slow1)) return false;
   if(entry_id==15)
      return want_buy ?
         (s.ohlcv_close[1]>s.ohlcv_open[1] && s.close>s.open && s.low<=fast1 &&
          fast1<MathMin(s.open,s.close) && s.low>slow1 && s.close<=s.ohlcv_high[1]) :
         (s.ohlcv_close[1]<s.ohlcv_open[1] && s.close<s.open && s.high>=fast1 &&
          fast1>MathMax(s.open,s.close) && s.high<slow1 && s.close>=s.ohlcv_low[1]);
   if(entry_id==16)
   {
      double atr3=0.0;
      const double pause_body=MathAbs(s.ohlcv_close[1]-s.ohlcv_open[1]);
      if(!ReadEntryQualityATR(3,atr3) || pause_body<=0.0 || pause_body>PauseResumeMaxPauseBodyATR*atr3) return false;
      return want_buy ?
         (s.ohlcv_close[2]>s.ohlcv_open[2] && s.ohlcv_close[1]<s.ohlcv_open[1] &&
          s.ohlcv_low[1]>fast2 && s.close>s.open && s.low>fast1 &&
          s.close>s.ohlcv_open[1] && s.close<=s.ohlcv_high[1]) :
         (s.ohlcv_close[2]<s.ohlcv_open[2] && s.ohlcv_close[1]>s.ohlcv_open[1] &&
          s.ohlcv_high[1]<fast2 && s.close<s.open && s.high<fast1 &&
          s.close<s.ohlcv_open[1] && s.close>=s.ohlcv_low[1]);
   }
   if(entry_id==17)
      return want_buy ?
         (s.ohlcv_close[1]<s.ohlcv_open[1] && s.close>s.open &&
          s.open<=s.ohlcv_close[1] && s.close>=s.ohlcv_open[1] &&
          (s.open<s.ohlcv_close[1] || s.close>s.ohlcv_open[1]) && MathMin(s.open,s.close)>fast1) :
         (s.ohlcv_close[1]>s.ohlcv_open[1] && s.close<s.open &&
          s.open>=s.ohlcv_close[1] && s.close<=s.ohlcv_open[1] &&
          (s.open>s.ohlcv_close[1] || s.close<s.ohlcv_open[1]) && MathMax(s.open,s.close)<fast1);
   if(entry_id==18)
   {
      double mean_volume=0.0;
      for(int i=1;i<=8;i++) mean_volume+=(double)s.ohlcv_volume[i];
      mean_volume/=8.0;
      const double signal_range=s.high-s.low;
      if(mean_volume<=0.0 || signal_range<=0.0 ||
         (double)s.ohlcv_volume[0]<VolumeIgnitionMinVolumeRatio*mean_volume ||
         MathAbs(s.close-s.open)<VolumeIgnitionMinBodyFraction*signal_range) return false;
      return want_buy ? (s.close>s.open && s.close>s.ohlcv_close[1]) :
                        (s.close<s.open && s.close<s.ohlcv_close[1]);
   }
   if(entry_id==19)
   {
      double fast3=0.0,fast4=0.0;
      if(!TryReadMA(g_fast_ma_handles[0],3,fast3) || !TryReadMA(g_fast_ma_handles[0],4,fast4)) return false;
      const double sign=(want_buy ? 1.0 : -1.0);
      const double d1=sign*(fast1-fast2),d2=sign*(fast2-fast3),d3=sign*(fast3-fast4);
      double atr2=0.0;
      if(!ReadEntryQualityATR(2,atr2) || !(d1>d2 && d2>0.0 && d2<=d3) ||
         d1-d2<SlopeAccelMinAccelerationATR*atr2) return false;
      return want_buy ? (s.close>s.open && MathMin(s.open,s.close)>fast1) :
                        (s.close<s.open && MathMax(s.open,s.close)<fast1);
   }
   if(entry_id==20)
   {
      double atr2=0.0;
      if(!ReadEntryQualityATR(2,atr2)) return false;
      double slope_close=0.0,slope_high=0.0,slope_low=0.0,mean_close=0.0;
      double upper=s.ohlcv_high[1],lower=s.ohlcv_low[1];
      double max_close=s.ohlcv_close[1],min_close=s.ohlcv_close[1];
      int overlaps=0;
      for(int j=0;j<4;j++)
      {
         const int i=4-j;
         const double x=(double)j-1.5;
         slope_close+=x*s.ohlcv_close[i]; slope_high+=x*s.ohlcv_high[i]; slope_low+=x*s.ohlcv_low[i];
         mean_close+=s.ohlcv_close[i];
         upper=MathMax(upper,s.ohlcv_high[i]); lower=MathMin(lower,s.ohlcv_low[i]);
         max_close=MathMax(max_close,s.ohlcv_close[i]); min_close=MathMin(min_close,s.ohlcv_close[i]);
         if(j>0 && MathMin(s.ohlcv_high[i],s.ohlcv_high[i+1])>MathMax(s.ohlcv_low[i],s.ohlcv_low[i+1])) overlaps++;
      }
      slope_close/=5.0; slope_high/=5.0; slope_low/=5.0; mean_close/=4.0;
      double variation=0.0;
      for(int i=1;i<=4;i++) variation+=MathPow(s.ohlcv_close[i]-mean_close,2.0);
      const double width=upper-lower;
      const double sign=(want_buy ? 1.0 : -1.0);
      if(variation<=0.0 || sign*slope_close<0.03*atr2 || sign*slope_high<=0.0 || sign*slope_low<=0.0 ||
         5.0*slope_close*slope_close/variation<0.60 || width<0.6*atr2 || width>2.0*atr2 || overlaps<2) return false;
      return want_buy ? (s.close>max_close && s.close<=upper && s.close>=upper-0.20*width && s.low>=lower) :
                        (s.close<min_close && s.close>=lower && s.close<=lower+0.20*width && s.high<=upper);
   }
   return false;
}

bool PassContinuationOREntry(const IndicatorState &s,const bool want_buy,const int entry_id)
{
   if(!ContinuationORIsEnabled(entry_id) || CountMyPositions()>0) return false;
   if(!ContinuationORPricePattern(s,want_buy,entry_id) || !ContinuationORQuality(s,want_buy,entry_id)) return false;
   if(NewORLegacyAlreadyMatches(s)) return false;
   for(int id=9;id<=13;id++)
      if(NewORPricePattern(s,want_buy,id) && NewORQuality(s,want_buy,id)) return false;
   if(PassTrendRunEntryFilter(s,want_buy)) return false;
   for(int id=15;id<entry_id;id++)
      if(ContinuationORPricePattern(s,want_buy,id) && ContinuationORQuality(s,want_buy,id)) return false;
   return true;
}

bool PassAnyContinuationOREntry(const IndicatorState &s,const bool want_buy)
{
   for(int id=15;id<=20;id++) if(PassContinuationOREntry(s,want_buy,id)) return true;
   return false;
}
// END NEW CONTINUATION OR FUNCTIONS


// BEGIN TWELVE RESEARCH OR FUNCTIONS
// Research prototypes21..24. All prices/indicators use closed M5 data.
// Common quality, isolation, no-position admission and old-OR duplicate veto
// belong to the caller. This file never sends orders or changes any exit.
// b[0]=closed[1], b[79]=closed[80]; atr2 is the closed pre-signal ATR14.

// The broker's actual D1 anchor determines membership. No GMT/session-hour
// assumptions are made; CopyRates stops at the closed signal's OPEN time.
bool Family2124BrokerDay(const MqlRates &b[],int &count,
                        double &vwap1,double &sd1,double &vwap2,double &sd2,
                        double &opening_high,double &opening_low)
{
   count=0;vwap1=0.0;sd1=0.0;vwap2=0.0;sd2=0.0;
   opening_high=-DBL_MAX;opening_low=DBL_MAX;
   if(ArraySize(b)<2 || iBarShift(_Symbol,PERIOD_D1,b[0].time,false)!=0)
      return false;
   const datetime day_open=iTime(_Symbol,PERIOD_D1,0);
   if(day_open<=0 || b[0].time<day_open) return false;
   MqlRates day[];
   ArraySetAsSeries(day,false);
   count=CopyRates(_Symbol,PERIOD_M5,day_open,b[0].time,day);
   if(count<8 || day[count-1].time!=b[0].time || day[count-2].time!=b[1].time)
      return false;
   double sw=0.0,swp=0.0,swp2=0.0;
   for(int i=0;i<count;i++)
   {
      const MqlRates bar=day[i];
      if(!MathIsValidNumber(bar.high) || !MathIsValidNumber(bar.low) ||
         !MathIsValidNumber(bar.close) || bar.high<bar.low) return false;
      const double price=(bar.high+bar.low+bar.close)/3.0;
      const double weight=MathMax(1.0,(double)bar.tick_volume);
      sw+=weight;swp+=weight*price;swp2+=weight*price*price;
      if(i<6)
      {
         opening_high=MathMax(opening_high,bar.high);
         opening_low=MathMin(opening_low,bar.low);
      }
      if(i==count-2)
      {
         vwap2=swp/sw;
         sd2=MathSqrt(MathMax(0.0,swp2/sw-vwap2*vwap2));
      }
   }
   if(sw<=0.0) return false;
   vwap1=swp/sw;
   sd1=MathSqrt(MathMax(0.0,swp2/sw-vwap1*vwap1));
   return MathIsValidNumber(vwap1) && MathIsValidNumber(sd1) &&
          MathIsValidNumber(vwap2) && MathIsValidNumber(sd2);
}

// Fixed80-bar Wilder RSI2. The current and prior values share the same seed.
double Family2124RSIValue(const double gain,const double loss)
{
   return gain+loss>0.0 ? 100.0*gain/(gain+loss) : 50.0;
}
bool Family2124RSI2(const MqlRates &b[],double &now,double &prior)
{
   now=50.0;prior=50.0;
   if(ArraySize(b)<80) return false;
   double gain=0.0,loss=0.0;
   for(int j=78;j>=77;j--)
   {
      const double delta=b[j].close-b[j+1].close;
      if(!MathIsValidNumber(delta)) return false;
      gain+=MathMax(delta,0.0)/2.0;
      loss+=MathMax(-delta,0.0)/2.0;
   }
   for(int j=76;j>=0;j--)
   {
      const double delta=b[j].close-b[j+1].close;
      if(!MathIsValidNumber(delta)) return false;
      gain=(gain+MathMax(delta,0.0))/2.0;
      loss=(loss+MathMax(-delta,0.0))/2.0;
      if(j==1) prior=Family2124RSIValue(gain,loss);
      if(j==0) now=Family2124RSIValue(gain,loss);
   }
   return MathIsValidNumber(now) && MathIsValidNumber(prior);
}

// Fixed80-bar Wilder14 DMI:14 TR/DM samples seed the averages;14 DX
// samples seed ADX. Current/prior/prior2 all use this single causal seed.
bool Family2124DMI14(const MqlRates &b[],
                    double &plus1,double &minus1,double &adx1,
                    double &plus2,double &minus2,double &adx2,double &adx3)
{
   plus1=0.0;minus1=0.0;adx1=0.0;plus2=0.0;minus2=0.0;adx2=0.0;adx3=0.0;
   if(ArraySize(b)<80) return false;
   double tr=0.0,plus=0.0,minus=0.0,adx_seed=0.0,adx=0.0;
   for(int chronological=1;chronological<80;chronological++)
   {
      const int j=79-chronological;
      const MqlRates current=b[j],previous=b[j+1];
      const double up=current.high-previous.high;
      const double down=previous.low-current.low;
      const double dm_plus=(up>down && up>0.0 ? up : 0.0);
      const double dm_minus=(down>up && down>0.0 ? down : 0.0);
      const double range=MathMax(current.high-current.low,
                           MathMax(MathAbs(current.high-previous.close),
                                   MathAbs(current.low-previous.close)));
      if(!MathIsValidNumber(range) || range<0.0 ||
         !MathIsValidNumber(dm_plus) || !MathIsValidNumber(dm_minus)) return false;
      if(chronological<=14)
      {
         tr+=range/14.0;plus+=dm_plus/14.0;minus+=dm_minus/14.0;
      }
      else
      {
         tr=(13.0*tr+range)/14.0;
         plus=(13.0*plus+dm_plus)/14.0;
         minus=(13.0*minus+dm_minus)/14.0;
      }
      if(chronological<14) continue;
      const double p=(tr>0.0 ? 100.0*plus/tr : 0.0);
      const double m=(tr>0.0 ? 100.0*minus/tr : 0.0);
      const double dx=(p+m>0.0 ? 100.0*MathAbs(p-m)/(p+m) : 0.0);
      if(chronological<=27)
      {
         adx_seed+=dx/14.0;
         if(chronological==27) adx=adx_seed;
      }
      else adx=(13.0*adx+dx)/14.0;
      if(chronological==77) adx3=adx;
      if(chronological==78){plus2=p;minus2=m;adx2=adx;}
      if(chronological==79){plus1=p;minus1=m;adx1=adx;}
   }
   return MathIsValidNumber(adx1) && MathIsValidNumber(adx2) && MathIsValidNumber(adx3);
}

bool ResearchFamily2124(const MqlRates &b[],const double atr2,
                       const bool want_buy,const int id)
{
   if(ArraySize(b)<80 || !MathIsValidNumber(atr2) || atr2<=0.0) return false;
   const double direction=(want_buy ? 1.0 : -1.0);
   if(id==21 || id==23)
   {
      int count=0;double v1=0.0,s1=0.0,v2=0.0,s2=0.0,hi=0.0,lo=0.0;
      if(!Family2124BrokerDay(b,count,v1,s1,v2,s2,hi,lo)) return false;
      if(id==21)
      {
         if(count<VWAPReentryMinDayBars || s1<0.35*atr2 || s1>3.0*atr2 ||
            MathAbs(v1-v2)>VWAPReentryMaxSlopeATR*atr2) return false;
         const double boundary1=v1-direction*VWAPReentryDeviation*s1;
         const double boundary2=v2-direction*VWAPReentryDeviation*s2;
         return direction*(b[1].close-boundary2)<0.0 &&
                direction*(b[0].close-boundary1)>=0.0 &&
                direction*(v1-b[0].close)>=VWAPReentryMinMeanRoom;
      }
      const double width=hi-lo;
      const double boundary=(want_buy ? lo : hi);
      const double middle=(hi+lo)/2.0;
      return width>=OpeningFailMinWidthATR*atr2 && width<=OpeningFailMaxWidthATR*atr2 &&
             direction*(b[1].close-boundary)<0.0 &&
             direction*(b[0].close-boundary)>0.0 &&
             direction*(middle-b[0].close)>=OpeningFailMinMidRoom &&
             direction*(boundary-b[1].close)<=OpeningFailMaxOutsideATR*atr2;
   }
   if(id==22)
   {
      double now=0.0,prior=0.0;
      if(!Family2124RSI2(b,now,prior)) return false;
      if(!want_buy){now=100.0-now;prior=100.0-prior;}
      if(prior>RSI2ResetExtreme || now<RSI2ResetMinRecovery || now>RSI2ResetMaxRecovery)
         return false;
      double fast1=0.0,slow1=0.0,fast2=0.0,fast_m5=0.0;
      if(!TryReadMA(g_fast_ma_handles[1],1,fast1) ||
         !TryReadMA(g_slow_ma_handles[1],1,slow1) ||
         !TryReadMA(g_fast_ma_handles[1],2,fast2) ||
         !TryReadMA(g_fast_ma_handles[0],1,fast_m5)) return false;
      return direction*(fast1-slow1)>0.0 && direction*(fast1-fast2)>0.0 &&
             direction*(b[0].close-fast_m5)>=RSI2ResetMinCloseFastATR*atr2;
   }
   if(id==24)
   {
      double p1=0.0,m1=0.0,a1=0.0,p2=0.0,m2=0.0,a2=0.0,a3=0.0,fast=0.0;
      if(!Family2124DMI14(b,p1,m1,a1,p2,m2,a2,a3) ||
         !TryReadMA(g_fast_ma_handles[0],1,fast)) return false;
      const double spread1=direction*(p1-m1),spread2=direction*(p2-m2);
      return spread1>0.0 && spread1>spread2 && a1>=DMITurnMinADX && a1<=DMITurnMaxADX &&
             a1>a2 && a2<=a3 && a1-a2>=DMITurnMinADXDelta &&
             direction*(b[0].close-fast)<=DMITurnMaxCloseFastATR*atr2;
   }
   return false;
}

// Prototype only: root integrates routing/flat-only/profit re-entry separately.
// r[0] is the fully CLOSED M5 signal[1]; r[1]=[2], ..., at least80 rows.
// No new indicator handles. MACD current/previous samples share the same explicit
//80-bar EMA seed b[79].close; this finite-window definition matches Python exactly.

void Family2528Bands(const MqlRates &r[],const int shift,double &mid,double &lower,double &upper)
{
   mid=0.0;
   for(int j=shift;j<shift+20;j++) mid+=r[j].close;
   mid/=20.0;double variance=0.0;
   for(int j=shift;j<shift+20;j++) variance+=MathPow(r[j].close-mid,2);
   const double width=2.0*MathSqrt(variance/20.0);
   lower=mid-width;upper=mid+width;
}

double Family2528CCI(const MqlRates &r[],const int shift)
{
   double mean=0.0,mad=0.0;
   for(int j=shift;j<shift+20;j++) mean+=(r[j].high+r[j].low+r[j].close)/3.0;
   mean/=20.0;
   for(int j=shift;j<shift+20;j++) mad+=MathAbs((r[j].high+r[j].low+r[j].close)/3.0-mean);
   mad/=20.0;
   return (mad>0.0 ? (((r[shift].high+r[shift].low+r[shift].close)/3.0-mean)/(0.015*mad)) : 0.0);
}

double Family2528StochK(const MqlRates &r[],const int shift)
{
   double numerator=0.0,denominator=0.0;
   for(int j=shift;j<shift+3;j++)
   {
      double highest=r[j].high,lowest=r[j].low;
      for(int k=j+1;k<j+5;k++){highest=MathMax(highest,r[k].high);lowest=MathMin(lowest,r[k].low);}
      numerator+=r[j].close-lowest;denominator+=highest-lowest;
   }
   return (denominator>0.0 ? 100.0*numerator/denominator : 50.0);
}

bool ResearchFamily2528(const MqlRates &r[],const double atr2,const bool want_buy,const int entry_id)
{
   if(ArraySize(r)<80) return false;
   if(entry_id==25)
   {
      double mid1,low1,up1,mid2,low2,up2;
      Family2528Bands(r,0,mid1,low1,up1);Family2528Bands(r,1,mid2,low2,up2);
      if(MathAbs(mid1-mid2)>0.2*atr2) return false;
      return want_buy ? (r[1].close<=low2 && r[0].close>low1 && r[0].close<mid1) :
                        (r[1].close>=up2 && r[0].close<up1 && r[0].close>mid1);
   }
   if(entry_id==26)
   {
      double fast=r[79].close,slow=fast,main[10];
      for(int j=78;j>=0;j--)
      {
         fast=(2.0/13.0)*r[j].close+(11.0/13.0)*fast;
         slow=(2.0/27.0)*r[j].close+(25.0/27.0)*slow;
         if(j<=9) main[j]=fast-slow;
      }
      double signal1=0.0,signal2=0.0;
      for(int j=0;j<9;j++){signal1+=main[j];signal2+=main[j+1];}
      signal1/=9.0;signal2/=9.0;
      return want_buy ? (main[1]-signal2<=0.0 && main[0]-signal1>=0.005*atr2 && main[0]>0.0 && r[0].close>fast) :
                        (main[1]-signal2>=0.0 && signal1-main[0]>=0.005*atr2 && main[0]<0.0 && r[0].close<fast);
   }
   if(entry_id==27)
   {
      const double c1=Family2528CCI(r,0),c2=Family2528CCI(r,1),c3=Family2528CCI(r,2),c4=Family2528CCI(r,3);
      return want_buy ? (c2<=-100.0 && c1>-100.0 && c1<0.0 && MathMin(c2,MathMin(c3,c4))<=-150.0) :
                        (c2>=100.0 && c1<100.0 && c1>0.0 && MathMax(c2,MathMax(c3,c4))>=150.0);
   }
   if(entry_id==28)
   {
      const double k1=Family2528StochK(r,0),k2=Family2528StochK(r,1),k3=Family2528StochK(r,2),k4=Family2528StochK(r,3);
      const double d1=(k1+k2+k3)/3.0,d2=(k2+k3+k4)/3.0;
      return want_buy ? (k2<=d2 && k1-d1>=6.0 && MathMin(k2,k3)<=20.0 && k1<50.0) :
                        (k2>=d2 && d1-k1>=6.0 && MathMax(k2,k3)>=80.0 && k1>50.0);
   }
   return false;
}


// Research predicates only. Caller applies chosen common quality, flat-only
// admission, master switches, earlier-OR veto and unchanged order/exit code.
// b[0]=fully CLOSED M5[1], b[1]=[2], ...; pass at least80 closed bars.
// atr2 is the native M5 ATR14 on CLOSED[2]. No date/time whitelist or future data.
// Indicator definitions: MetaQuotes regression-channel / Momentum / Fractals
// documentation and https://www.mql5.com/en/articles/14006 (Aroon author code).
// Entry combinations/thresholds below are research hypotheses, not quotations.

void ResearchAroon2932(const MqlRates &b[],const int offset,double &up,double &down)
{
   int ago_high=0,ago_low=0;
   double highest=b[offset].high,lowest=b[offset].low;
   //25 intervals use26 observations with ages0..25; newest equal extreme wins.
   for(int j=1;j<=25;j++)
   {
      if(b[offset+j].high>highest) {highest=b[offset+j].high;ago_high=j;}
      if(b[offset+j].low<lowest) {lowest=b[offset+j].low;ago_low=j;}
   }
   up=100.0*(25-ago_high)/25.0;
   down=100.0*(25-ago_low)/25.0;
}

bool ResearchFractal2932(const MqlRates &b[],const int shift,const bool high_pivot)
{
   const int p=shift-1;
   if(shift<4 || p+2>=ArraySize(b)) return false;
   for(int k=1;k<=2;k++)
      if(high_pivot ? (b[p].high<=b[p-k].high || b[p].high<=b[p+k].high) :
                       (b[p].low>=b[p-k].low || b[p].low>=b[p+k].low))
         return false;
   return true;
}

bool ResearchFamily2932(const MqlRates &b[],const double atr2,
                       const bool want_buy,const int id)
{
   if(ArraySize(b)<64 || !MathIsValidNumber(atr2) || atr2<=0.0)
      return false;
   const double c1=b[0].close,c2=b[1].close;
   if(id==29)
   {
      //OLS fitted to24 closes [26]..[3], excluding the pullback[2]/signal[1].
      double mean=0.0;
      for(int x=0;x<24;x++) mean+=b[25-x].close;
      mean/=24.0;
      double numerator=0.0,denominator=0.0;
      for(int x=0;x<24;x++)
      {
         const double dx=(double)x-11.5;
         numerator+=dx*(b[25-x].close-mean);
         denominator+=dx*dx;
      }
      const double slope=numerator/denominator;
      double sse=0.0,sst=0.0;
      for(int x=0;x<24;x++)
      {
         const double dy=b[25-x].close-mean;
         const double residual=dy-slope*((double)x-11.5);
         sse+=residual*residual;sst+=dy*dy;
      }
      if(sst<=0.0) return false;
      const double r2=MathMax(0.0,1.0-sse/sst);
      const double sigma=MathSqrt(sse/24.0);
      if(r2<0.25 || sigma<0.25*atr2) return false;
      const double intercept=mean-slope*11.5;
      const double mid2=intercept+slope*24.0;
      const double mid1=intercept+slope*25.0;
      return want_buy ?
         (slope>0.0 && c2<=mid2-1.5*sigma && c1>mid1-1.5*sigma && c1<mid1) :
         (slope<0.0 && c2>=mid2+1.5*sigma && c1<mid1+1.5*sigma && c1>mid1);
   }
   if(id==30)
   {
      double up1=0.0,down1=0.0,up2=0.0,down2=0.0;
      ResearchAroon2932(b,0,up1,down1);
      ResearchAroon2932(b,1,up2,down2);
      return want_buy ?
         (up1>down1 && up2<=down2 && up1>=72.0 && down1<=48.0) :
         (down1>up1 && down2<=up2 && down1>=72.0 && up1<=48.0);
   }
   if(id==31)
   {
      if(b[3].close<=0.0 || b[4].close<=0.0 || b[5].close<=0.0 ||
         b[12].close<=0.0 || b[13].close<=0.0)
         return false;
      // DualROC confirmation: the zero-cross occurred on CLOSED[2].
      // CLOSED[1] must accelerate in that same direction. No price breakout,
      // SMA crossover or three-candle color pattern is introduced.
      const double roc3=100.0*(c1/b[3].close-1.0);
      const double prior_roc3=100.0*(c2/b[4].close-1.0);
      const double before_roc3=100.0*(b[2].close/b[5].close-1.0);
      const double roc12=100.0*(c1/b[12].close-1.0);
      const double prior_roc12=100.0*(c2/b[13].close-1.0);
      const double body2=MathAbs(b[1].close-b[1].open);
      const double body3=MathAbs(b[2].close-b[2].open);
      if(!(body2<=body3)) return false;
      const double impulse=c1-b[3].close;
      return want_buy ?
         (prior_roc3>0.0 && before_roc3<=0.0 && roc3>prior_roc3 &&
          roc12>0.0 && roc12>prior_roc12 &&
          impulse>=0.15*atr2 && impulse<=2.0*atr2) :
         (prior_roc3<0.0 && before_roc3>=0.0 && roc3<prior_roc3 &&
          roc12<0.0 && roc12<prior_roc12 &&
          -impulse>=0.15*atr2 && -impulse<=2.0*atr2);
   }
   if(id==32)
   {
      //BUY: newer confirmed low3>older low1, with high2 between them.
      //SELL mirrors high3<high1 and breaks the intervening low2.
      //Nearest point3 uses shift>=4, so signal[1] never confirms its own pivot.
      int point3=-1,point2=-1,point1=-1;
      for(int shift=4;shift<=12;shift++)
         if(ResearchFractal2932(b,shift,!want_buy)) {point3=shift;break;}
      if(point3<0) return false;
      for(int shift=point3+3;shift<=40;shift++)
         if(ResearchFractal2932(b,shift,want_buy)) {point2=shift;break;}
      if(point2<0) return false;
      for(int shift=point2+3;shift<=62;shift++)
         if(ResearchFractal2932(b,shift,!want_buy)) {point1=shift;break;}
      if(point1<0) return false;
      if(want_buy)
      {
         const double low1=b[point1-1].low,high2=b[point2-1].high,low3=b[point3-1].low;
         const double amplitude=high2-low1;
         if(amplitude<=0.0 || low3<=low1) return false;
         const double depth=(high2-low3)/amplitude;
         return depth>=0.2 && depth<=0.8 && c2<=high2 && c1>high2 && c1-high2<=0.2*atr2;
      }
      const double high1=b[point1-1].high,low2=b[point2-1].low,high3=b[point3-1].high;
      const double amplitude=high1-low2;
      if(amplitude<=0.0 || high3>=high1) return false;
      const double depth=(high3-low2)/amplitude;
      return depth>=0.2 && depth<=0.8 && c2>=low2 && c1<low2 && low2-c1<=0.2*atr2;
   }
   return false;
}

// Closed-bar admission for NEW OR04.21..04.32 only.
// Raw family predicates are inserted before this block by the candidate builder.
bool ResearchORIsEnabled(const int id)
{
   switch(id)
   {
      case 21:return UseSessionVWAPReentryEntryFilter;
      case 22:return UseRSIResetEntryFilter;
      case 23:return UseOpeningRangeFailureEntryFilter;
      case 24:return UseADXTransitionEntryFilter;
      case 25:return UseBollingerReentryEntryFilter;
      case 26:return UseMACDTurnEntryFilter;
      case 27:return UseCCIRecoveryEntryFilter;
      case 28:return UseStochasticResetEntryFilter;
      case 29:return UseRegressionChannelEntryFilter;
      case 30:return UseAroonTurnEntryFilter;
      case 31:return UseDualROCTurnEntryFilter;
      case 32:return UseFractal123EntryFilter;
   }
   return false;
}

int ResearchOREnabledCount()
{
   int count=0;
   for(int id=21;id<=32;id++)if(ResearchORIsEnabled(id))count++;
   return count;
}

bool ResearchORAnyEnabled(){return ResearchOREnabledCount()>0;}

// Standalone new entries may restart only after the last matching position
// has closed with positive net profit, including its opening/closing costs.
// PrintSignalLog is the only diagnostic switch. No input or entry gate changes.
// Rejections are deduplicated by M5 bar + selected entry + side + reason code.
bool ResearchORDiagnosticReject(const int id,const bool want_buy,
                                const int reason_code,const string detail)
{
   if(!PrintSignalLog || id<29 || id>31 || !ResearchORIsEnabled(id) ||
      (NewORIsolatedEntry!=0 && NewORIsolatedEntry!=id)) return false;
   static datetime logged_bar[6];
   static ulong logged_reasons[6];
   const int slot=(id-29)*2+(want_buy ? 0 : 1);
   const datetime bar=iTime(_Symbol,PERIOD_M5,0);
   if(logged_bar[slot]!=bar)
   {
      logged_bar[slot]=bar;
      logged_reasons[slot]=0;
   }
   if(reason_code>=0 && reason_code<64)
   {
      const ulong bit=((ulong)1<<reason_code);
      if((logged_reasons[slot] & bit)!=0) return false;
      logged_reasons[slot]|=bit;
   }
   PrintFormat("RESEARCH BLOCK %s %s | symbol=%s M5=%s | %s",
               ResearchORTag(id),(want_buy ? "BUY" : "SELL"),_Symbol,
               TimeToString(bar,TIME_DATE|TIME_MINUTES),detail);
   return false;
}

void LogResearchORStateReadiness()
{
   if(!PrintSignalLog ||
      (!UseRegressionChannelEntryFilter && !UseAroonTurnEntryFilter && !UseDualROCTurnEntryFilter) ||
      (NewORIsolatedEntry!=0 && (NewORIsolatedEntry<29 || NewORIsolatedEntry>31))) return;
   static bool logged=false;
   static datetime logged_bar=0;
   const datetime bar=iTime(_Symbol,PERIOD_M5,0);
   if(logged && logged_bar==bar) return;
   logged=true;logged_bar=bar;
   PrintFormat("RESEARCH STATE NOT READY | symbol=%s M5=%s | M5bars=%d synchronized=%s closed1=%s ATRcalculated=%d ATRperiod=%d globalMTF=%s TPmode=%d; entry skipped, no retry added",
               _Symbol,TimeToString(bar,TIME_DATE|TIME_MINUTES),Bars(_Symbol,PERIOD_M5),
               (SeriesInfoInteger(_Symbol,PERIOD_M5,SERIES_SYNCHRONIZED) ? "YES" : "NO"),
               TimeToString(iTime(_Symbol,PERIOD_M5,1),TIME_DATE|TIME_MINUTES),
               BarsCalculated(g_entry_quality_atr_handle),EntryQualityATRPeriod,
               (UseMTFTrendEntryFilter ? "ON" : "OFF"),(int)NoSLTPMode);
   for(int tf=0;tf<TF_COUNT;tf++)
      PrintFormat("RESEARCH STATE MA | TF=%s enabledForGlobal=%s fastCalculated=%d slowCalculated=%d needClosed1>=%d needClosed2>=%d",
                  EnumToString(g_timeframes[tf]),(IsTFEnabled(tf) ? "YES" : "NO"),
                  BarsCalculated(g_fast_ma_handles[tf]),BarsCalculated(g_slow_ma_handles[tf]),
                  (int)MathMax(FastMAPeriod,SlowMAPeriod)+1,(int)MathMax(FastMAPeriod,SlowMAPeriod)+2);
}

void LogResearchOREnvironment()
{
   if(!PrintSignalLog) return;
   PrintFormat("RESEARCH ENV | symbol=%s digits=%d point=%.10f tickSize=%.10f contract=%.4f volume[min=%.4f max=%.4f step=%.4f] currency=%s accountMode=%s marginMode=%s symbolTradeMode=%s; no account identifier logged",
               _Symbol,_Digits,_Point,SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE),
               SymbolInfoDouble(_Symbol,SYMBOL_TRADE_CONTRACT_SIZE),
               SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN),SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX),
               SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP),AccountInfoString(ACCOUNT_CURRENCY),
               EnumToString((ENUM_ACCOUNT_TRADE_MODE)AccountInfoInteger(ACCOUNT_TRADE_MODE)),
               EnumToString((ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE)),
               EnumToString((ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_MODE)));
   PrintFormat("RESEARCH INPUTS | isolation=%d researchEnabled=%d REG_RE=%s AROON_TURN=%s ROC_TURN=%s masks=%d/%d/%d globalMTF=%s spreadLimit=%dpoints gapLimit=%.4fATR sessionCutoff=%dmin magic=%I64u newBarOnly=%s trading=%s permissions[terminal=%s EA=%s account=%s]",
               NewORIsolatedEntry,ResearchOREnabledCount(),
               (UseRegressionChannelEntryFilter ? "ON" : "OFF"),
               (UseAroonTurnEntryFilter ? "ON" : "OFF"),(UseDualROCTurnEntryFilter ? "ON" : "OFF"),
               R29TrendMask,R30TrendMask,R31TrendMask,(UseMTFTrendEntryFilter ? "ON" : "OFF"),
               ResearchORMaxSpreadPoints,ResearchORMaxEntryGapATR,ResearchORSessionCutoffMinutes,
               MagicNumber,(TradeOnNewBarOnly ? "ON" : "OFF"),(EnableTrading ? "ON" : "OFF"),
               (TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) ? "YES" : "NO"),
               (MQLInfoInteger(MQL_TRADE_ALLOWED) ? "YES" : "NO"),
               (AccountInfoInteger(ACCOUNT_TRADE_ALLOWED) ? "YES" : "NO"));
}

bool ResearchORPreviousCloseProfitable()
{
   if(!HistorySelect(0,TimeCurrent()))
   {
      if(PrintSignalLog) g_research_reentry_diagnostic=StringFormat("HistorySelect failed error=%d",GetLastError());
      return false;
   }
   ulong last_position=0;
   const int total=HistoryDealsTotal();
   for(int i=total-1;i>=0;i--)
   {
      const ulong deal=HistoryDealGetTicket(i);
      if(deal==0 || HistoryDealGetString(deal,DEAL_SYMBOL)!=_Symbol ||
         (ulong)HistoryDealGetInteger(deal,DEAL_MAGIC)!=MagicNumber)continue;
      const ENUM_DEAL_ENTRY entry=(ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal,DEAL_ENTRY);
      if(entry==DEAL_ENTRY_OUT || entry==DEAL_ENTRY_OUT_BY || entry==DEAL_ENTRY_INOUT)
      {last_position=(ulong)HistoryDealGetInteger(deal,DEAL_POSITION_ID);break;}
   }
   if(last_position==0)return true; // No prior closed position: initial entry.
   double net=0.0;
   for(int i=0;i<total;i++)
   {
      const ulong deal=HistoryDealGetTicket(i);
      if(deal==0 || (ulong)HistoryDealGetInteger(deal,DEAL_POSITION_ID)!=last_position)continue;
      net+=HistoryDealGetDouble(deal,DEAL_PROFIT)+HistoryDealGetDouble(deal,DEAL_SWAP)+
           HistoryDealGetDouble(deal,DEAL_COMMISSION)+HistoryDealGetDouble(deal,DEAL_FEE);
   }
   if(PrintSignalLog)
      g_research_reentry_diagnostic=StringFormat("last_position=%I64u net=%.10f %s requires net>0 including commission/swap/fee; shared Symbol+Magic across all OR tags",last_position,net,AccountInfoString(ACCOUNT_CURRENCY));
   return MathIsValidNumber(net) && net>0.0;
}

bool ResearchORSessionAllowed()
{
   const datetime now=TimeCurrent();
   if(now<=0)
   {
      if(PrintSignalLog) g_research_session_diagnostic="invalid server time";
      return false;
   }
   MqlDateTime clock;TimeToStruct(now,clock);clock.hour=0;clock.min=0;clock.sec=0;
   const datetime midnight=StructToTime(clock);
   bool schedule=false,active=false;datetime last_close=0;
   for(int day=0;day<=1;day++)
   {
      const datetime anchor=midnight-(datetime)(day*86400);
      MqlDateTime parts;TimeToStruct(anchor,parts);
      for(uint index=0;index<32;index++)
      {
         datetime from=0,to=0;
         if(!SymbolInfoSessionTrade(_Symbol,(ENUM_DAY_OF_WEEK)parts.day_of_week,index,from,to))break;
         schedule=true;
         const long start=(long)from;long finish=(long)to;
         if(start<0 || finish<0 || start>172800 || finish>172800)continue;
         if(finish<=start)finish+=86400;
         const datetime opening=anchor+(datetime)start,closing=anchor+(datetime)finish;
         if(now>=opening && now<closing)
         {active=true;if(closing>last_close)last_close=closing;}
      }
   }
   if(!schedule && MQLInfoInteger(MQL_TESTER))
   {
      static bool warned=false;
      if(!warned){Print("RESEARCH OR SESSION FALLBACK: tester has no session schedule; cutoff unavailable.");warned=true;}
      return true;
   }
   if(PrintSignalLog)
      g_research_session_diagnostic=StringFormat("schedule=%s active=%s remaining=%.2fmin required>%dmin tester=%s; missing live session schedule is blocked",(schedule ? "YES" : "NO"),(active ? "YES" : "NO"),(double)(last_close-now)/60.0,ResearchORSessionCutoffMinutes,(MQLInfoInteger(MQL_TESTER) ? "YES" : "NO"));
   return active && last_close-now>ResearchORSessionCutoffMinutes*60;
}

string ResearchORTag(const int id)
{
   switch(id)
   {
      case 21:return "VWAP_BACK";
      case 22:return "RSI2_RESET";
      case 23:return "OR_FAIL";
      case 24:return "DMI_TURN";
      case 25:return "BB_REENTER";
      case 26:return "MACD_TURN";
      case 27:return "CCI_RECOVER";
      case 28:return "STOCH_TURN";
      case 29:return "REG_RE";
      case 30:return "AROON_TURN";
      case 31:return "ROC_TURN";
      case 32:return "FRAC_123";
   }
   return "UNKNOWN";
}

// The builder inserts the per-entry parameter switch here.
void ResearchORQualityParameters(const int id,double &minimum,double &maximum,
                                 double &min_body,double &max_wick,int &trend_mask)
{
   minimum=0.4;maximum=1.8;min_body=0.5;max_wick=0.25;trend_mask=0;
   switch(id)
   {
      case 21:minimum=R21MinRangeATR;maximum=R21MaxRangeATR;min_body=R21MinBodyFraction;max_wick=R21MaxEndWickFraction;trend_mask=R21TrendMask;break;
      case 22:minimum=R22MinRangeATR;maximum=R22MaxRangeATR;min_body=R22MinBodyFraction;max_wick=R22MaxEndWickFraction;trend_mask=R22TrendMask;break;
      case 23:minimum=R23MinRangeATR;maximum=R23MaxRangeATR;min_body=R23MinBodyFraction;max_wick=R23MaxEndWickFraction;trend_mask=R23TrendMask;break;
      case 24:minimum=R24MinRangeATR;maximum=R24MaxRangeATR;min_body=R24MinBodyFraction;max_wick=R24MaxEndWickFraction;trend_mask=R24TrendMask;break;
      case 25:minimum=R25MinRangeATR;maximum=R25MaxRangeATR;min_body=R25MinBodyFraction;max_wick=R25MaxEndWickFraction;trend_mask=R25TrendMask;break;
      case 26:minimum=R26MinRangeATR;maximum=R26MaxRangeATR;min_body=R26MinBodyFraction;max_wick=R26MaxEndWickFraction;trend_mask=R26TrendMask;break;
      case 27:minimum=R27MinRangeATR;maximum=R27MaxRangeATR;min_body=R27MinBodyFraction;max_wick=R27MaxEndWickFraction;trend_mask=R27TrendMask;break;
      case 28:minimum=R28MinRangeATR;maximum=R28MaxRangeATR;min_body=R28MinBodyFraction;max_wick=R28MaxEndWickFraction;trend_mask=R28TrendMask;break;
      case 29:minimum=R29MinRangeATR;maximum=R29MaxRangeATR;min_body=R29MinBodyFraction;max_wick=R29MaxEndWickFraction;trend_mask=R29TrendMask;break;
      case 30:minimum=R30MinRangeATR;maximum=R30MaxRangeATR;min_body=R30MinBodyFraction;max_wick=R30MaxEndWickFraction;trend_mask=R30TrendMask;break;
      case 31:minimum=R31MinRangeATR;maximum=R31MaxRangeATR;min_body=R31MinBodyFraction;max_wick=R31MaxEndWickFraction;trend_mask=R31TrendMask;break;
      case 32:minimum=R32MinRangeATR;maximum=R32MaxRangeATR;min_body=R32MinBodyFraction;max_wick=R32MaxEndWickFraction;trend_mask=R32TrendMask;break;
   }
}


bool ResearchORReadRates(MqlRates &b[])
{
   if(ArrayResize(b,80)!=80)return false;
   MqlRates raw[80]; // CopyRates physical order oldest -> newest.
   if(CopyRates(_Symbol,PERIOD_M5,1,80,raw)!=80)return false;
   for(int i=0;i<80;i++)b[i]=raw[79-i];
   return true; // b[0]=closed[1], b[79]=closed[80].
}

bool ResearchORPricePattern(const MqlRates &b[],const double atr2,
                            const bool want_buy,const int id)
{
   if(id>=21 && id<=24)return ResearchFamily2124(b,atr2,want_buy,id);
   if(id>=25 && id<=28)return ResearchFamily2528(b,atr2,want_buy,id);
   if(id>=29 && id<=32)return ResearchFamily2932(b,atr2,want_buy,id);
   return false;
}

bool ResearchORQuality(const IndicatorState &s,const bool want_buy,const int id,
                       double &atr2)
{
   atr2=0.0;
   const double range=s.high-s.low;
   const double body=MathAbs(s.close-s.open);
   if(!MathIsValidNumber(range) || range<=0.0)
      return PrintSignalLog && ResearchORDiagnosticReject(id,want_buy,2,StringFormat("CANDLE_RANGE invalid range=%.10f",range));
   if(want_buy ? s.close<=s.open : s.close>=s.open)
      return PrintSignalLog && ResearchORDiagnosticReject(id,want_buy,3,StringFormat("CANDLE_COLOR open=%.10f close=%.10f",s.open,s.close));
   const datetime entry_time=iTime(_Symbol,PERIOD_M5,0);
   if(entry_time-s.ohlcv_time[0]!=300)
      return PrintSignalLog && ResearchORDiagnosticReject(id,want_buy,4,StringFormat("ENTRY_CLOCK gap=%I64dsec required=300",(long)(entry_time-s.ohlcv_time[0])));
   for(int i=0;i<5;i++)
      if(s.ohlcv_time[i]-s.ohlcv_time[i+1]!=300)
         return PrintSignalLog && ResearchORDiagnosticReject(id,want_buy,5,StringFormat("CLOSED_TIME_CONTINUITY shifts=%d/%d gap=%I64dsec required=300",i+1,i+2,(long)(s.ohlcv_time[i]-s.ohlcv_time[i+1])));
   double minimum,maximum,min_body,max_wick;int trend_mask=0;
   ResearchORQualityParameters(id,minimum,maximum,min_body,max_wick,trend_mask);
   if(!ReadEntryQualityATR(2,atr2))
      return PrintSignalLog && ResearchORDiagnosticReject(id,want_buy,6,StringFormat("ATR_NOT_READY period=%d shift=2 calculated=%d required>=%d",EntryQualityATRPeriod,BarsCalculated(g_entry_quality_atr_handle),EntryQualityATRPeriod+2));
   if(range<minimum*atr2 || range>maximum*atr2)
      return PrintSignalLog && ResearchORDiagnosticReject(id,want_buy,7,StringFormat("RANGE_ATR actual=%.6f allowed=[%.6f,%.6f] ATR2=%.10f range=%.10f",range/atr2,minimum,maximum,atr2,range));
   if(body<min_body*range)
      return PrintSignalLog && ResearchORDiagnosticReject(id,want_buy,8,StringFormat("BODY_FRACTION actual=%.6f minimum=%.6f",body/range,min_body));
   const double end_wick=(want_buy ? s.high-s.close : s.close-s.low);
   if(end_wick>max_wick*range)
      return PrintSignalLog && ResearchORDiagnosticReject(id,want_buy,9,StringFormat("END_WICK actual=%.6f maximum=%.6f",end_wick/range,max_wick));
   for(int tf=1;tf<TF_COUNT;tf++)
   {
      if((trend_mask & (1<<(tf-1)))==0)continue;
      double fast=0.0,slow=0.0;
      if(!TryReadMA(g_fast_ma_handles[tf],1,fast) || !TryReadMA(g_slow_ma_handles[tf],1,slow))
         return PrintSignalLog && ResearchORDiagnosticReject(id,want_buy,10,StringFormat("MASK_MA_NOT_READY mask=%d TF=%s shift=1 fastCalculated=%d slowCalculated=%d",trend_mask,EnumToString(g_timeframes[tf]),BarsCalculated(g_fast_ma_handles[tf]),BarsCalculated(g_slow_ma_handles[tf])));
      if(want_buy ? fast<=slow : fast>=slow)
         return PrintSignalLog && ResearchORDiagnosticReject(id,want_buy,11,StringFormat("MASK_MA_DIRECTION mask=%d TF=%s fast1=%.10f slow1=%.10f",trend_mask,EnumToString(g_timeframes[tf]),fast,slow));
   }
   if((trend_mask & 16)!=0)
   {
      double f1=0.0,f2=0.0,s1=0.0,s2=0.0;
      if(!TryReadMA(g_fast_ma_handles[2],1,f1) || !TryReadMA(g_fast_ma_handles[2],2,f2) ||
         !TryReadMA(g_slow_ma_handles[2],1,s1) || !TryReadMA(g_slow_ma_handles[2],2,s2))
         return PrintSignalLog && ResearchORDiagnosticReject(id,want_buy,12,StringFormat("MASK_SLOPE_NOT_READY mask=%d TF=M30 fastCalculated=%d slowCalculated=%d",trend_mask,BarsCalculated(g_fast_ma_handles[2]),BarsCalculated(g_slow_ma_handles[2])));
      if(want_buy ? !(f1>f2 && s1>s2) : !(f1<f2 && s1<s2))
         return PrintSignalLog && ResearchORDiagnosticReject(id,want_buy,13,StringFormat("MASK_SLOPE_DIRECTION TF=M30 fast[1/2]=%.10f/%.10f slow[1/2]=%.10f/%.10f",f1,f2,s1,s2));
   }
   for(int tf=0;tf<=1;tf++)
   {
      const int bit=(tf==0 ? 64 : 32);
      if((trend_mask & bit)==0)continue;
      double f1=0.0,f2=0.0,s1=0.0,s2=0.0;
      if(!TryReadMA(g_fast_ma_handles[tf],1,f1) || !TryReadMA(g_fast_ma_handles[tf],2,f2) ||
         !TryReadMA(g_slow_ma_handles[tf],1,s1) || !TryReadMA(g_slow_ma_handles[tf],2,s2))
         return PrintSignalLog && ResearchORDiagnosticReject(id,want_buy,14,StringFormat("MASK_SLOPE_NOT_READY mask=%d TF=%s fastCalculated=%d slowCalculated=%d",trend_mask,EnumToString(g_timeframes[tf]),BarsCalculated(g_fast_ma_handles[tf]),BarsCalculated(g_slow_ma_handles[tf])));
      if(want_buy ? !(f1>f2 && s1>s2) : !(f1<f2 && s1<s2))
         return PrintSignalLog && ResearchORDiagnosticReject(id,want_buy,15,StringFormat("MASK_SLOPE_DIRECTION TF=%s fast[1/2]=%.10f/%.10f slow[1/2]=%.10f/%.10f",EnumToString(g_timeframes[tf]),f1,f2,s1,s2));
   }
   if((trend_mask & 128)!=0 && !ResearchORObservedRunwayAllowed())
      return PrintSignalLog && ResearchORDiagnosticReject(id,want_buy,16,StringFormat("OBSERVED_RUNWAY blocked mask=%d: needs an observed weekday 30min..4h gap within up to1000 closed M5 bars and >%dmin remaining",trend_mask,ResearchORSessionCutoffMinutes));
   MqlTick quote;
   if(!SymbolInfoTick(_Symbol,quote) || quote.ask<=0.0 || quote.bid<=0.0 || quote.ask<quote.bid)
      return PrintSignalLog && ResearchORDiagnosticReject(id,want_buy,17,"QUOTE_UNAVAILABLE_OR_INVALID");
   const double pt=InputPointSize();
   if(quote.ask-quote.bid>ResearchORMaxSpreadPoints*pt)
      return PrintSignalLog && ResearchORDiagnosticReject(id,want_buy,18,StringFormat("SPREAD actual=%.3fpoints maximum=%dpoints bid=%.10f ask=%.10f point=%.10f",(pt>0.0 ? (quote.ask-quote.bid)/pt : 0.0),ResearchORMaxSpreadPoints,quote.bid,quote.ask,pt));
   const double entry_open=iOpen(_Symbol,PERIOD_M5,0);
   if(entry_open<=0.0)
      return PrintSignalLog && ResearchORDiagnosticReject(id,want_buy,19,StringFormat("ENTRY_BAR_OPEN unavailable value=%.10f",entry_open));
   if(MathAbs(entry_open-s.close)>ResearchORMaxEntryGapATR*atr2)
      return PrintSignalLog && ResearchORDiagnosticReject(id,want_buy,20,StringFormat("ENTRY_GAP actual=%.6fATR maximum=%.6fATR open0=%.10f close1=%.10f ATR2=%.10f",MathAbs(entry_open-s.close)/atr2,ResearchORMaxEntryGapATR,entry_open,s.close,atr2));
   return true;
}

// Use actual existing predicates. No old OR can open orders through this helper.
bool ResearchORPriorAlreadyMatches(const IndicatorState &s)
{
   if(NewORLegacyAlreadyMatches(s))return true;
   for(int id=9;id<=13;id++)
      for(int direction=0;direction<2;direction++)
      {
         const bool buy=(direction==0);
         if(NewORPricePattern(s,buy,id) && NewORQuality(s,buy,id))return true;
      }
   if(PassTrendRunEntryFilter(s,true) || PassTrendRunEntryFilter(s,false))return true;
   for(int id=15;id<=20;id++)
      for(int direction=0;direction<2;direction++)
      {
         const bool buy=(direction==0);
         if(ContinuationORPricePattern(s,buy,id) && ContinuationORQuality(s,buy,id))return true;
      }
   return false;
}

bool PassResearchOREntry(const IndicatorState &s,const bool want_buy,const int id)
{
   if(!ResearchORIsEnabled(id))return false;
   const int positions=CountMyPositions();
   if(positions>0)
      return PrintSignalLog && ResearchORDiagnosticReject(id,want_buy,1,StringFormat("FLAT_EXPOSURE positions=%d for Symbol+Magic; new research entries require zero",positions));
   double atr2=0.0;
   if(!ResearchORQuality(s,want_buy,id,atr2))return false;
   MqlRates b[];
   if(!ResearchORReadRates(b))
      return PrintSignalLog && ResearchORDiagnosticReject(id,want_buy,21,StringFormat("M5_HISTORY requires80 closed bars; available=%d error=%d",Bars(_Symbol,PERIOD_M5),GetLastError()));
   if(!ResearchORPricePattern(b,atr2,want_buy,id))
      return PrintSignalLog && ResearchORDiagnosticReject(id,want_buy,22,"PRICE_PATTERN not matched on closed M5 history");
   if(ResearchORPriorAlreadyMatches(s))
      return PrintSignalLog && ResearchORDiagnosticReject(id,want_buy,23,"OLD_OR_VETO an existing OR04.3..04.20 predicate already matches");
   // Preserve canonical priority even when earlier master switches are OFF.
   for(int earlier=21;earlier<id;earlier++)
   {
      double earlier_atr=0.0;
      if(ResearchORQuality(s,want_buy,earlier,earlier_atr) &&
         ResearchORPricePattern(b,earlier_atr,want_buy,earlier))
         return PrintSignalLog && ResearchORDiagnosticReject(id,want_buy,24,StringFormat("EARLIER_RESEARCH_VETO id=%d tag=%s independent of earlier master switch",earlier,ResearchORTag(earlier)));
   }
   // Same short-circuit order: session exactly once, then history only if allowed.
   if(!ResearchORSessionAllowed())
      return PrintSignalLog && ResearchORDiagnosticReject(id,want_buy,25,"RESEARCH_SESSION "+g_research_session_diagnostic);
   if(!ResearchORPreviousCloseProfitable())
      return PrintSignalLog && ResearchORDiagnosticReject(id,want_buy,26,"NATURAL_REENTRY "+g_research_reentry_diagnostic);
   return true;
}

bool PassAnyResearchOREntry(const IndicatorState &s,const bool want_buy)
{
   for(int id=21;id<=32;id++)if(PassResearchOREntry(s,want_buy,id))return true;
   return false;
}

// Only time stamps from the most recent1000 CLOSED M5 bars are inspected.
// A gap is learned only after its reopening bar has itself closed; fresh-signal
// admission already waits for six consecutive closed bars. No live OHLC read.
bool ResearchORObservedRunwayAllowed()
{
   const datetime entry_open=iTime(_Symbol,PERIOD_M5,0);
   if(entry_open<=0) return false;
   MqlRates history[];
   ArraySetAsSeries(history,false); // Physical order: oldest -> newest.
   const int copied=CopyRates(_Symbol,PERIOD_M5,1,1000,history);
   if(copied<2 || history[copied-1].time+300!=entry_open) return false;
   long close_clock=-1;
   for(int j=1;j<copied;j++)
   {
      const long separation=(long)(history[j].time-history[j-1].time);
      if(separation<=0) return false;
      // Bounds refer to adjacent OPEN-time separation, as in the proposal.
      if(separation<30*60 || separation>4*3600) continue;
      MqlDateTime older,newer;
      if(!TimeToStruct(history[j-1].time,older) || !TimeToStruct(history[j].time,newer))
         return false;
      // MQL: Sunday=0, Saturday=6; retain weekdays1..5 at both endpoints.
      if(older.day_of_week<1 || older.day_of_week>5 ||
         newer.day_of_week<1 || newer.day_of_week>5) continue;
      close_clock=((long)history[j-1].time+300)%86400;
   }
   if(close_clock<0) return false; // Unknown runway is not a passing estimate.
   datetime predicted_close=(datetime)(((long)entry_open/86400)*86400+close_clock);
   if(predicted_close<entry_open) predicted_close+=86400;
   return (long)(predicted_close-entry_open)>(long)ResearchORSessionCutoffMinutes*60;
}

// END TWELVE RESEARCH OR FUNCTIONS

// NEW ENTRY FORMULA:
// (optional MTF 04.1) AND any enabled ENTRY OR.
// Removed global quality/spread/volatility/slow-SMA-distance gates.
// SMA Pullback and confirmed Cross are ENTRY ONLY; excluded from opposite-signal exits.
// Exits call with check_entry_gates=false to retain their prior rules.
//====================================================================
// OR04.33: SMA TREND CONTINUATION. Local optional quality gates only.
// No previous-profit/session research gates are inherited from OR21..32.
// No time exit or profit-target lookahead is used by this entry source.
//====================================================================
bool STCNeedsATR()
{
   return UseSMATrendContinuationEntryFilter &&
          (UseSTCRangeATRFilter || UseSTCCloseFastATRFilter);
}

bool STCMADirection(const int tf,const int shift,const bool want_buy,
                    double &fast,double &slow)
{
   return TryReadMA(g_fast_ma_handles[tf],shift,fast) &&
          TryReadMA(g_slow_ma_handles[tf],shift,slow) &&
          (want_buy ? fast>slow : fast<slow);
}

bool STCPriorORAlreadyMatches(const IndicatorState &s)
{
   if(ResearchORPriorAlreadyMatches(s)) return true;
   MqlRates bars[];
   if(!ResearchORReadRates(bars)) return true;
   // Canonical predicates are inspected; no earlier OR can place an order here.
   for(int id=21;id<=32;id++)
      for(int direction=0;direction<2;direction++)
      {
         const bool buy=(direction==0);
         double atr2=0.0;
         if(ResearchORQuality(s,buy,id,atr2) &&
            ResearchORPricePattern(bars,atr2,buy,id)) return true;
      }
   return false;
}

bool PassSMATrendContinuationEntry(const IndicatorState &s,const bool want_buy)
{
   if(!UseSMATrendContinuationEntryFilter || CountMyPositions()>0) return false;
   if(UseSTCSpreadFilter)
   {
      MqlTick quote;
      const double pt=InputPointSize();
      if(pt<=0.0 || !SymbolInfoTick(_Symbol,quote) ||
         !MathIsValidNumber(quote.bid) || !MathIsValidNumber(quote.ask) ||
         quote.bid<=0.0 || quote.ask<=0.0 || quote.ask<quote.bid ||
         quote.ask-quote.bid>STCMaxSpreadPoints*pt+pt*1e-6) return false;
   }
   double fast=0.0,slow=0.0;
   // The sole baseline signal is CLOSED M5 MA ordering, in the trade direction.
   for(int shift=1;shift<=STCTrendBars;shift++)
      if(!STCMADirection(0,shift,want_buy,fast,slow)) return false;
   if(!STCMADirection(0,1,want_buy,fast,slow)) return false;

   if(UseSTCFreshnessFilter)
   {
      if(iTime(_Symbol,PERIOD_M5,0)-s.ohlcv_time[0]!=300) return false;
      for(int i=0;i<STCFreshBars-1;i++)
         if(s.ohlcv_time[i]-s.ohlcv_time[i+1]!=300) return false;
   }
   for(int tf=1;tf<TF_COUNT;tf++)
   {
      if((STCTrendMask & (1<<(tf-1)))==0) continue;
      double tf_fast=0.0,tf_slow=0.0;
      if(!STCMADirection(tf,1,want_buy,tf_fast,tf_slow)) return false;
   }
   for(int tf=0;tf<=2;tf++)
   {
      if((STCSlopeMask & (1<<tf))==0) continue;
      double f1=0.0,f2=0.0,s1=0.0,s2=0.0;
      if(!TryReadMA(g_fast_ma_handles[tf],1,f1) ||
         !TryReadMA(g_fast_ma_handles[tf],2,f2) ||
         !TryReadMA(g_slow_ma_handles[tf],1,s1) ||
         !TryReadMA(g_slow_ma_handles[tf],2,s2) ||
         (want_buy ? !(f1>f2 && s1>s2) : !(f1<f2 && s1<s2))) return false;
   }

   if(UseSTCCandleColorFilter &&
      (want_buy ? s.close<=s.open : s.close>=s.open)) return false;
   if(UseSTCCloseFastFilter &&
      (want_buy ? s.close<=fast : s.close>=fast)) return false;
   const bool uses_candle_quality=(UseSTCRangeATRFilter ||
                                 UseSTCBodyFractionFilter || UseSTCEndWickFilter);
   const double range=s.high-s.low;
   if(uses_candle_quality && (!MathIsValidNumber(range) || range<=0.0)) return false;
   double atr2=0.0;
   if(STCNeedsATR() && !ReadEntryQualityATR(2,atr2)) return false;
   if(UseSTCRangeATRFilter &&
      (range<STCMinRangeATR*atr2 || range>STCMaxRangeATR*atr2)) return false;
   if(UseSTCBodyFractionFilter &&
      MathAbs(s.close-s.open)<STCMinBodyFraction*range) return false;
   // End wick is measured from the real BODY, independent of candle colour.
   const double end_wick=(want_buy ? s.high-MathMax(s.open,s.close) :
                                    MathMin(s.open,s.close)-s.low);
   if(UseSTCEndWickFilter && end_wick>STCMaxEndWickFraction*range) return false;
   if(UseSTCCloseFastATRFilter &&
      MathAbs(s.close-fast)>STCMaxCloseFastATR*atr2) return false;
   if(UseSTCPriorORVeto && STCPriorORAlreadyMatches(s)) return false;
   return true;
}

//====================================================================
// OR04.34: INSIDE BAR BREAKOUT. The base predicate uses only closed M5
// [3] Mother, [2] Inside and [1] Breakout, plus the specified MA value [1].
// Local optional filters are explicit research additions, never exit rules.
//====================================================================
bool IBBNeedsATR()
{
   return UseInsideBarBreakoutEntryFilter &&
          (UseIBBRangeATRFilter || UseIBBCloseFastATRFilter || UseIBBEntryGapATRFilter);
}

bool IBBMADirection(const int tf,const int shift,const bool want_buy,
                    double &fast,double &slow)
{
   return TryReadMA(g_fast_ma_handles[tf],shift,fast) &&
          TryReadMA(g_slow_ma_handles[tf],shift,slow) &&
          (want_buy ? fast>slow : fast<slow);
}

bool InsideBarBreakoutPattern(const IndicatorState &s,const bool want_buy,
                             double &fast,double &slow)
{
   // Array [0]=closed[1], [1]=closed[2], [2]=closed[3].
   // Strict range containment is independent of Mother/Inside body colours.
   if(!(s.ohlcv_high[1]<s.ohlcv_high[2] &&
        s.ohlcv_low[1]>s.ohlcv_low[2])) return false;
   if(!IBBMADirection(0,1,want_buy,fast,slow)) return false;
   return (want_buy ?
           (s.close>s.open && s.close>s.ohlcv_high[2]) :
           (s.close<s.open && s.close<s.ohlcv_low[2]));
}

bool PassInsideBarBreakoutEntry(const IndicatorState &s,const bool want_buy)
{
   if(!UseInsideBarBreakoutEntryFilter || CountMyPositions()>0) return false;
   double fast=0.0,slow=0.0;
   if(!InsideBarBreakoutPattern(s,want_buy,fast,slow)) return false;

   // Optional filters below follow the selected IBB R7 research defaults.
   for(int shift=2;shift<=IBBTrendBars;shift++)
   {
      double older_fast=0.0,older_slow=0.0;
      if(!IBBMADirection(0,shift,want_buy,older_fast,older_slow)) return false;
   }
   if(UseIBBFreshnessFilter)
   {
      if(iTime(_Symbol,PERIOD_M5,0)-s.ohlcv_time[0]!=300) return false;
      for(int i=0;i<IBBFreshBars-1;i++)
         if(s.ohlcv_time[i]-s.ohlcv_time[i+1]!=300) return false;
   }
   for(int tf=1;tf<TF_COUNT;tf++)
   {
      if((IBBTrendMask & (1<<(tf-1)))==0) continue;
      double tf_fast=0.0,tf_slow=0.0;
      if(!IBBMADirection(tf,1,want_buy,tf_fast,tf_slow)) return false;
   }
   for(int tf=0;tf<=2;tf++)
   {
      if((IBBSlopeMask & (1<<tf))==0) continue;
      double f1=0.0,f2=0.0,s1=0.0,s2=0.0;
      if(!TryReadMA(g_fast_ma_handles[tf],1,f1) ||
         !TryReadMA(g_fast_ma_handles[tf],2,f2) ||
         !TryReadMA(g_slow_ma_handles[tf],1,s1) ||
         !TryReadMA(g_slow_ma_handles[tf],2,s2) ||
         (want_buy ? !(f1>f2 && s1>s2) : !(f1<f2 && s1<s2))) return false;
   }
   if(UseIBBCloseFastFilter &&
      (want_buy ? s.close<=fast : s.close>=fast)) return false;
   const double range=s.high-s.low;
   const bool candle_quality=(UseIBBRangeATRFilter || UseIBBBodyFractionFilter || UseIBBEndWickFilter || UseIBBRangeMotherFilter);
   if(candle_quality && (!MathIsValidNumber(range) || range<=0.0)) return false;
   if(UseIBBRangeMotherFilter || UseIBBCompressionFilter || UseIBBMinMAGapMotherFilter)
   {
      const double mother_range=s.ohlcv_high[2]-s.ohlcv_low[2];
      if(!MathIsValidNumber(mother_range) || mother_range<=0.0) return false;
      if(UseIBBRangeMotherFilter && range<IBBMinRangeMotherRatio*mother_range) return false;
      if(UseIBBMinMAGapMotherFilter &&
         MathAbs(fast-slow)<IBBMinMAGapMotherRatio*mother_range) return false;
      if(UseIBBCompressionFilter)
      {
         const double inside_range=s.ohlcv_high[1]-s.ohlcv_low[1];
         // Zero-range Inside bars remain admissible under the user formula.
         if(!MathIsValidNumber(inside_range) || inside_range<0.0 ||
            inside_range>IBBMaxInsideMotherRatio*mother_range) return false;
      }
   }
   double atr2=0.0;
   if(IBBNeedsATR() && !ReadEntryQualityATR(2,atr2)) return false;
   if(UseIBBRangeATRFilter &&
      (range<IBBMinRangeATR*atr2 || range>IBBMaxRangeATR*atr2)) return false;
   if(UseIBBBodyFractionFilter &&
      MathAbs(s.close-s.open)<IBBMinBodyFraction*range) return false;
   const double end_wick=(want_buy ? s.high-MathMax(s.open,s.close) :
                                     MathMin(s.open,s.close)-s.low);
   if(UseIBBEndWickFilter && end_wick>IBBMaxEndWickFraction*range) return false;
   if(UseIBBCloseFastATRFilter &&
      MathAbs(s.close-fast)>IBBMaxCloseFastATR*atr2) return false;
   if(UseIBBSpreadFilter || UseIBBEntryGapATRFilter)
   {
      MqlTick quote;
      const double pt=InputPointSize();
      if(pt<=0.0 || !SymbolInfoTick(_Symbol,quote) ||
         !MathIsValidNumber(quote.bid) || !MathIsValidNumber(quote.ask) ||
         quote.bid<=0.0 || quote.ask<=0.0 || quote.ask<quote.bid) return false;
      if(UseIBBSpreadFilter &&
         quote.ask-quote.bid>IBBMaxSpreadPoints*pt+pt*1e-6) return false;
      if(UseIBBEntryGapATRFilter &&
         MathAbs((want_buy ? quote.ask : quote.bid)-s.close)>IBBMaxEntryGapATR*atr2) return false;
   }
   return true;
}

// Function: EntryCondition - Apply ENTRY gates before the OR triggers.
bool EntryCondition(const IndicatorState &s,const bool want_buy,
                    const bool check_entry_gates=true)
{
   // Isolated 04.34 uses the exact three-closed-bar formula before inherited gates.
   if(check_entry_gates && NewORIsolatedEntry==34)
      return PassInsideBarBreakoutEntry(s,want_buy);
   // Isolated 04.33 deliberately starts with zero inherited entry filters.
   if(check_entry_gates && NewORIsolatedEntry==33)
      return PassSMATrendContinuationEntry(s,want_buy);
   if(!PassEntryTrendFilter(s,want_buy))
   {
      if(check_entry_gates && PrintSignalLog)
         for(int id=29;id<=31;id++)
            ResearchORDiagnosticReject(id,want_buy,27,StringFormat("GLOBAL_MTF_BIAS not aligned: mode=%s enabledTF=%d bias=%d",(MTFEntryBiasMode==MTF_MAJORITY ? "MAJORITY" : "ALL_AGREE"),EnabledTFCount(),MTFEntryBiasDirection(s)));
      return check_entry_gates && NewORIsolatedEntry==0 &&
             (PassSMATrendContinuationEntry(s,want_buy) ||
              PassInsideBarBreakoutEntry(s,want_buy));
   }

   if(check_entry_gates && NewORIsolatedEntry==3)
      return UseCandleColorEntryFilter && PassEntryCandleColorFilter(s,want_buy,true);
   if(check_entry_gates && NewORIsolatedEntry==4)
      return UseTwoCandleSMAContinuationEntryFilter && PassTwoCandleSMAContinuationEntryFilter(want_buy);
   if(check_entry_gates && NewORIsolatedEntry==7)
      return UseSMACrossConfirmedEntryFilter && PassEntrySMACrossConfirmedFilter(want_buy);
   if(check_entry_gates && NewORIsolatedEntry>=21)
      return PassResearchOREntry(s,want_buy,NewORIsolatedEntry);
   if(check_entry_gates && NewORIsolatedEntry>=15)
      return PassContinuationOREntry(s,want_buy,NewORIsolatedEntry);
   if(check_entry_gates && NewORIsolatedEntry==14)
      return PassTrendRunEntryFilter(s,want_buy);
   if(check_entry_gates && NewORIsolatedEntry>0)
      return PassFiveNewOREntry(s,want_buy,NewORIsolatedEntry);

   if(!UseCandleColorEntryFilter &&
      !(check_entry_gates && UseTwoCandleSMAContinuationEntryFilter) &&
      !UseMomentumBreakoutEntryFilter &&
      !(check_entry_gates && UseSMAPullbackRejectionEntryFilter) &&
      !(check_entry_gates && UseSMACrossConfirmedEntryFilter) &&
      !(check_entry_gates && UseRangeSweepReclaimEntryFilter) &&
      !(check_entry_gates && (NewORAnyEnabled() || UseTrendRunEntryFilter || ContinuationORAnyEnabled() || ResearchORAnyEnabled() || UseSMATrendContinuationEntryFilter || UseInsideBarBreakoutEntryFilter)))
      return false;

   return ((UseCandleColorEntryFilter &&
             PassEntryCandleColorFilter(s,want_buy,check_entry_gates)) ||
           (check_entry_gates && UseTwoCandleSMAContinuationEntryFilter &&
            PassTwoCandleSMAContinuationEntryFilter(want_buy)) ||
           (UseMomentumBreakoutEntryFilter &&
            PassEntryMomentumBreakoutFilter(want_buy,check_entry_gates)) ||
           (check_entry_gates && UseSMAPullbackRejectionEntryFilter &&
            PassEntrySMAPullbackRejectionFilter(want_buy)) ||
           (check_entry_gates && UseSMACrossConfirmedEntryFilter &&
            PassEntrySMACrossConfirmedFilter(want_buy)) ||
           (check_entry_gates && UseRangeSweepReclaimEntryFilter &&
            PassRangeSweepReclaimEntryFilter(s,want_buy)) ||
           (check_entry_gates && PassAnyFiveNewOREntry(s,want_buy)) ||
           (check_entry_gates && PassTrendRunEntryFilter(s,want_buy)) ||
           (check_entry_gates && PassAnyContinuationOREntry(s,want_buy)) ||
           (check_entry_gates && PassAnyResearchOREntry(s,want_buy)) ||
           (check_entry_gates && PassSMATrendContinuationEntry(s,want_buy)) ||
           (check_entry_gates && PassInsideBarBreakoutEntry(s,want_buy)));
}

// Function: EntryTriggerName - Label the first eligible OR source for tester
// comments and the trade log. More than one OR condition may be true.
string EntryTriggerName(const IndicatorState &s,const bool want_buy)
{
   if(NewORIsolatedEntry==34) return "INSIDE_BO";
   if(NewORIsolatedEntry==33) return "SMA_CONT";
   // If only local OR33 bypassed global MTF, preserve its correct attribution.
   if(NewORIsolatedEntry==0 && !PassEntryTrendFilter(s,want_buy))
   {
      if(PassSMATrendContinuationEntry(s,want_buy)) return "SMA_CONT";
      return PassInsideBarBreakoutEntry(s,want_buy) ? "INSIDE_BO" : "UNKNOWN";
   }
   if(NewORIsolatedEntry>=21)return ResearchORTag(NewORIsolatedEntry);
   if(NewORIsolatedEntry==3) return "PULLBACK";
   if(NewORIsolatedEntry==4) return "TWO_CANDLE";
   if(NewORIsolatedEntry==7) return "CROSS_1BAR";
   if(NewORIsolatedEntry>=15)
      return PassContinuationOREntry(s,want_buy,NewORIsolatedEntry) ? ContinuationORTag(NewORIsolatedEntry) : "UNKNOWN";
   if(NewORIsolatedEntry==14)
      return PassTrendRunEntryFilter(s,want_buy) ? "TREND_RUN" : "UNKNOWN";
   if(NewORIsolatedEntry>0)
      return PassFiveNewOREntry(s,want_buy,NewORIsolatedEntry) ? NewORTag(NewORIsolatedEntry) : "UNKNOWN";
   if(UseCandleColorEntryFilter && PassEntryCandleColorFilter(s,want_buy,true))
      return "PULLBACK";
   if(UseTwoCandleSMAContinuationEntryFilter && PassTwoCandleSMAContinuationEntryFilter(want_buy))
      return "TWO_CANDLE";
   if(UseMomentumBreakoutEntryFilter && PassEntryMomentumBreakoutFilter(want_buy))
      return "MOMENTUM";
   if(UseSMAPullbackRejectionEntryFilter && PassEntrySMAPullbackRejectionFilter(want_buy))
      return "SMA_PB";
   if(UseSMACrossConfirmedEntryFilter && PassEntrySMACrossConfirmedFilter(want_buy))
      return "CROSS_1BAR";
   if(UseRangeSweepReclaimEntryFilter && PassRangeSweepReclaimEntryFilter(s,want_buy))
      return "SWEEP_R";
   for(int id=9;id<=13;id++)
      if(PassFiveNewOREntry(s,want_buy,id)) return NewORTag(id);
   if(PassTrendRunEntryFilter(s,want_buy)) return "TREND_RUN";
   for(int id=15;id<=20;id++)
      if(PassContinuationOREntry(s,want_buy,id)) return ContinuationORTag(id);
   for(int id=21;id<=32;id++)
      if(PassResearchOREntry(s,want_buy,id)) return ResearchORTag(id);
   if(PassSMATrendContinuationEntry(s,want_buy)) return "SMA_CONT";
   if(PassInsideBarBreakoutEntry(s,want_buy)) return "INSIDE_BO";
   return "UNKNOWN";
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
   double buffer=SwingSLBufferPoints*InputPointSize();
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
         const double pt=InputPointSize();
         double raw_tp=(is_buy ? entry+FixedTPPoints*pt
                                 : entry-FixedTPPoints*pt);
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
   const double pt=InputPointSize();
   if(pt<=0.0 || LotSize<=0.0)
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

      double points=(side==POSITION_TYPE_BUY ? (tick.bid-entry)/pt
                                                   : (entry-tick.ask)/pt);
      basket_points+=points*(volume/LotSize);
   }

   return MathIsValidNumber(basket_points);
}

// Project the basket's common closing price (broker points, lot weighted).
// One-sided BUY: positions would all close at the calculated Bid TP;
// one-sided SELL: positions would all close at the calculated Ask TP.
// In a BUY+SELL hedge there can be no single broker TP valid for both
// sides simultaneously. Return a VIRTUAL target Bid level instead; the
// existing tick-based basket close remains the actual closing mechanism.
// Hedged price estimate assumes CURRENT spread (may change in the future).
// A delta-neutral hedge cannot reach a different point target by moving price.
bool CalculateBasketSharedExitPrice(double &price,bool &is_buy,bool &broker_side)
{
   price=0.0;
   is_buy=true;
   broker_side=false;
   const double pt=InputPointSize();
   if(pt<=0.0 || LotSize<=0.0) return false;
   MqlTick quote;
   if(!SymbolInfoTick(_Symbol,quote) || quote.bid<=0.0 ||
      quote.ask<=0.0 || quote.ask<quote.bid) return false;

   double buy_lots=0.0,sell_lots=0.0,buy_cost=0.0,sell_cost=0.0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol ||
         (ulong)PositionGetInteger(POSITION_MAGIC)!=MagicNumber) continue;
      const double volume=PositionGetDouble(POSITION_VOLUME);
      const double entry=PositionGetDouble(POSITION_PRICE_OPEN);
      if(volume<=0.0 || entry<=0.0) return false;
      const ENUM_POSITION_TYPE side=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if(side==POSITION_TYPE_BUY) { buy_lots+=volume;buy_cost+=volume*entry; }
      else if(side==POSITION_TYPE_SELL) { sell_lots+=volume;sell_cost+=volume*entry; }
   }
   if(buy_lots+sell_lots<=0.0) return false;
   const double required=BasketProfitTarget*pt*LotSize;
   const double tick_size=MathMax(_Point,SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE));
   if(sell_lots<=0.0)
   {
      is_buy=true;
      broker_side=true;
      price=NormalizeTickPrice((buy_cost+required)/buy_lots,true);
   }
   else if(buy_lots<=0.0)
   {
      is_buy=false;
      broker_side=true;
      price=NormalizeTickPrice((sell_cost-required)/sell_lots,false);
   }
   else
   {
      broker_side=false;
      const double net_lots=buy_lots-sell_lots;
      if(MathAbs(net_lots)<1e-8) return false;
      // Solve target = (buyL*Bid - buyCost + sellCost - sellL*Ask)/(_Point*LotSize).
      const double spread=quote.ask-quote.bid;
      const double target_bid=(required+buy_cost-sell_cost+sell_lots*spread)/net_lots;
      is_buy=(net_lots>0.0);
      price=NormalizeTickPrice(target_bid,is_buy);
   }
   return (MathIsValidNumber(price) && price>tick_size);
}

// One EA-owned horizontal marker; updates only on meaningful price changes.
// The marker is informative, never a broker stop order for a hedged basket.
void UpdateBasketSharedTPLine(const bool basket_mode)
{
   if(g_panel_prefix=="") return;
   string name=g_panel_prefix+"basket_shared_tp_line";
   if(!basket_mode || !ShowBasketTPLine)
   {
      if(ObjectFind(0,name)>=0) ObjectDelete(0,name);
      return;
   }
   double price=0.0;
   bool is_buy=true,broker_side=false;
   if(!CalculateBasketSharedExitPrice(price,is_buy,broker_side))
   {
      if(ObjectFind(0,name)>=0) ObjectDelete(0,name);
      return;
   }
   if(ObjectFind(0,name)<0)
   {
      if(!ObjectCreate(0,name,OBJ_HLINE,0,0,price)) return;
      ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
      ObjectSetInteger(0,name,OBJPROP_STYLE,broker_side ? STYLE_SOLID : STYLE_DASH);
      ObjectSetInteger(0,name,OBJPROP_WIDTH,1);
      ObjectSetString(0,name,OBJPROP_TOOLTIP,"EA basket shared target; hedge=virtual only");
   }
   const double tick=MathMax(_Point,SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE));
   if(MathAbs(ObjectGetDouble(0,name,OBJPROP_PRICE)-price)>=tick*0.5)
      ObjectSetDouble(0,name,OBJPROP_PRICE,price);
   ObjectSetInteger(0,name,OBJPROP_COLOR,broker_side ? C'79,224,157' : C'243,193,103');
   ObjectSetInteger(0,name,OBJPROP_STYLE,broker_side ? STYLE_SOLID : STYLE_DASH);
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
   const double pt=InputPointSize();
   if(CountMyPositions()==0 || pt<=0.0 || LotSize<=0.0 ||
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
   double spread_pts=(tick.ask-tick.bid)/pt;
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

//====================================================================
// SWING SL TRAILING BY ORIGINAL TP PROGRESS
//====================================================================
// Terminal globals are keyed by account+magic+position ticket, so an
// original target survives chart reload or terminal restart.
// This intentionally stores TP, not the moving SL. Positions from other
// symbols/magic numbers are never modified by the trailing routine.
// Function: TrailingTPKeyPrefix - Namespace for original TP records.
string TrailingTPKeyPrefix()
{
   return StringFormat("MTFTP_%I64d_%I64u_",
                       AccountInfoInteger(ACCOUNT_LOGIN),MagicNumber);
}

// Function: TrailingTPKey - Stable initial-TP record for a position ticket.
string TrailingTPKey(const ulong ticket)
{
   return TrailingTPKeyPrefix()+StringFormat("%I64u",ticket);
}

// Function: CacheOriginalPositionTP - Store original TP once, before SL trailing.
bool CacheOriginalPositionTP(const ulong ticket,const double tp)
{
   if(!UseTrailingStopWithSL || !UseSwingSL || !UseRRTP || tp<=0.0)
      return false;
   string key=TrailingTPKey(ticket);
   if(GlobalVariableCheck(key))
      return true;
   if(GlobalVariableSet(key,tp)==0)
   {
      PrintFormat("Trailing TP record FAILED ticket=%I64u error=%d; skipping trailing for safety.",
                  ticket,GetLastError());
      return false;
   }
   return true;
}

// Function: OriginalPositionTP - Read the original TP even if broker TP is removed.
double OriginalPositionTP(const ulong ticket)
{
   string key=TrailingTPKey(ticket);
   if(!GlobalVariableCheck(key))
      return 0.0;
   double target=GlobalVariableGet(key);
   return (MathIsValidNumber(target) && target>0.0 ? target : 0.0);
}

// Function: CleanupTrailingTPKeys - Delete records for positions that are closed.
// Run on attach and each newly opened M5 candle, not on every tick.
void CleanupTrailingTPKeys()
{
   if(!UseTrailingStopWithSL)
      return;
   string prefix=TrailingTPKeyPrefix();
   for(int i=GlobalVariablesTotal()-1;i>=0;i--)
   {
      string name=GlobalVariableName(i);
      if(StringFind(name,prefix)!=0)
         continue;
      string suffix=StringSubstr(name,StringLen(prefix));
      ulong ticket=(ulong)StringToInteger(suffix);
      if(ticket!=0 && PositionSelectByTicket(ticket) &&
         PositionGetString(POSITION_SYMBOL)==_Symbol &&
         (ulong)PositionGetInteger(POSITION_MAGIC)==MagicNumber)
         continue;
      GlobalVariableDel(name);
   }
}

// Function: ApplyTPProgressTrailing - Secure 70% of the traveled profit
// when 40% of original TP is reached, then follow at a fixed remaining
// 30% of the triggering movement (12% of ORIGINAL TP distance).
// Runs on every tick; never relaxes the existing SL; skips basket mode.
void ApplyTPProgressTrailing()
{
   if(!UseTrailingStopWithSL || !UseSwingSL || !UseRRTP)
      return;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick) || tick.bid<=0.0 || tick.ask<=0.0)
      return;
   double point=SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   double tick_size=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   if(point<=0.0) return;
   if(tick_size<=0.0) tick_size=point;
   double min_distance=(double)MathMax(
      SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL),
      SymbolInfoInteger(_Symbol,SYMBOL_TRADE_FREEZE_LEVEL))*point;
   double start_fraction=TrailingStartTPPercent/100.0;
   double protect_fraction=TrailingProtectMovePercent/100.0;

   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC)!=MagicNumber) continue;

      ENUM_POSITION_TYPE side=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      bool is_buy=(side==POSITION_TYPE_BUY);
      if(!is_buy && side!=POSITION_TYPE_SELL) continue;
      double current_sl=PositionGetDouble(POSITION_SL);
      double current_tp=PositionGetDouble(POSITION_TP);
      double entry=PositionGetDouble(POSITION_PRICE_OPEN);
      // No real SL/TP => no trailing. Basket mode removes physical TP.
      if(current_sl<=0.0 || current_tp<=0.0 || entry<=0.0) continue;
      if(!CacheOriginalPositionTP(ticket,current_tp)) continue;
      double original_tp=OriginalPositionTP(ticket);
      double full_move=(is_buy ? original_tp-entry : entry-original_tp);
      if(full_move<=tick_size || !MathIsValidNumber(full_move)) continue;

      double market=(is_buy ? tick.bid : tick.ask);
      double progress=(is_buy ? market-entry : entry-market);
      double activation=full_move*start_fraction;
      if(progress+point*1e-6<activation) continue;

      // Initial locked profit = 40% * 70% = 28% of original TP.
      // Fixed trailing gap = 40% * (100%-70%) = 12% of original TP.
      double gap=activation*(1.0-protect_fraction);
      double raw_sl=(is_buy ? market-gap : market+gap);
      double proposed=NormalizeTickPrice(raw_sl,!is_buy);
      if(proposed<=0.0) continue;
      if(is_buy)
      {
         if(proposed<=entry || proposed<=current_sl+tick_size*0.5) continue;
         if(proposed>=market-min_distance) continue;
      }
      else
      {
         if(proposed>=entry || proposed>=current_sl-tick_size*0.5) continue;
         if(proposed<=market+min_distance) continue;
      }
      bool modified=trade.PositionModify(ticket,proposed,current_tp);
      uint rc=trade.ResultRetcode();
      if(!modified || rc!=TRADE_RETCODE_DONE)
      {
         if(PrintSignalLog)
            PrintFormat("TRAIL failed ticket=%I64u rc=%u %s",ticket,rc,
                        trade.ResultRetcodeDescription());
         continue;
      }
      if(PrintSignalLog)
         PrintFormat("TRAIL %s ticket=%I64u entry=%.*f originalTP=%.*f progress=%.1f%% SL=%.*f gap=%.1f points",
                     (is_buy ? "BUY" : "SELL"),ticket,_Digits,entry,_Digits,original_tp,
                     100.0*progress/full_move,_Digits,proposed,gap/point);
   }
}

// Returns requested broker-side TP, or 0 when current mode is EA-managed.
// Prefer saved original TP when trailing is enabled; otherwise use the
// previous RR recovery behavior for positions without saved TP.
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
      if(UseTrailingStopWithSL)
      {
         ulong ticket=(ulong)PositionGetInteger(POSITION_TICKET);
         double saved_tp=OriginalPositionTP(ticket);
         if(saved_tp>0.0)
            return saved_tp;
         double broker_tp=PositionGetDouble(POSITION_TP);
         if(broker_tp>0.0 && CacheOriginalPositionTP(ticket,broker_tp))
            return broker_tp;
      }
      double sl=PositionGetDouble(POSITION_SL);
      if(sl<=0.0) return 0.0;
      double risk=(is_buy ? entry-sl : sl-entry);
      if(risk<=0.0) return 0.0;
      double raw=(is_buy ? entry+RiskRewardRatio*risk : entry-RiskRewardRatio*risk);
      return NormalizeTickPrice(raw,is_buy);
   }
   if(NoSLTPMode==TP_FIXED_POINTS)
   {
      const double pt=InputPointSize();
      double raw=(is_buy ? entry+FixedTPPoints*pt : entry-FixedTPPoints*pt);
      return NormalizeTickPrice(raw,is_buy);
   }
   return 0.0;
}

// When BOTH sides exist, physical TPs must be stripped so that an individual
// TP cannot close the order before the basket reaches its combined target.
// On return to one-sided trading, restore price-based TP if practicable.
// Returns false if a required position modification failed.
// Function: SynchronizeTakeProfits - Remove broker TPs in basket mode or restore them outside it.
bool SynchronizeTakeProfits(const bool basket_mode,const bool prepare_new_basket=false)
{
   if(!UseRRTP && !basket_mode) return true;
   bool all_ok=true;
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick)) return false;
   long stop_points=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   long freeze_points=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_FREEZE_LEVEL);
   double min_distance=(double)MathMax(stop_points,freeze_points)*_Point;
   double tolerance=MathMax(_Point*0.1,SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE)*0.1);

   double shared_price=0.0;
   bool shared_is_buy=true,broker_side=false;
   if(basket_mode && !prepare_new_basket)
      CalculateBasketSharedExitPrice(shared_price,shared_is_buy,broker_side);
   // A common physical TP can be used ONLY on a one-sided basket.
   bool shared_placement_ok=(broker_side && shared_price>0.0 &&
      (shared_is_buy ? shared_price>tick.bid+min_distance :
                       shared_price<tick.ask-min_distance));

   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC)!=MagicNumber) continue;

      double current_tp=PositionGetDouble(POSITION_TP);
      double sl=PositionGetDouble(POSITION_SL);
      // Save the original target BEFORE a basket removes physical TP.
      // When trailing is enabled, never recompute TP using a modified SL.
      if(current_tp>0.0 && sl>0.0)
         CacheOriginalPositionTP(ticket,current_tp);
      if(basket_mode)
      {
         // Same-side basket: place one common price on every position.
         // Hedge, preparing a new basket or invalid broker stop-distance:
         // no per-position TP; close by virtual combined-points target.
         const double desired=(shared_placement_ok ? shared_price : 0.0);
         if(MathAbs(current_tp-desired)<=tolerance) continue;
         bool modified=trade.PositionModify(ticket,sl,desired);
         uint code=trade.ResultRetcode();
         if(!modified || code!=TRADE_RETCODE_DONE)
         {
            if(PrintSignalLog || prepare_new_basket)
               PrintFormat("BASKET shared TP modify FAILED ticket=%I64u target=%.*f code=%u %s",
                           ticket,_Digits,desired,code,trade.ResultRetcodeDescription());
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
       UpdateBasketSharedTPLine(false);
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
// Track only indicators this EA successfully inserted. If an indicator with
// the same short name existed already, refuse to remove it on OFF to avoid
// accidentally deleting manually installed chart indicators.
bool ChartHasIndicatorName(const string shortname)
{
   for(int i=0;i<ChartIndicatorsTotal(0,0);i++)
      if(ChartIndicatorName(0,0,i)==shortname) return true;
   return false;
}

bool AddOwnedChartMA(const int handle,string &owned_name,bool &owned)
{
   if(handle==INVALID_HANDLE) return false;
   int before=ChartIndicatorsTotal(0,0);
   if(!ChartIndicatorAdd(0,0,handle)) return false;
   int after=ChartIndicatorsTotal(0,0);
   if(after<=before) return false;
   owned_name=ChartIndicatorName(0,0,after-1);
   owned=(owned_name!="");
   for(int i=0;i<before;i++)
      if(ChartIndicatorName(0,0,i)==owned_name)
      {
         // Duplicate shortname: do NOT auto-delete any of the instances.
         owned=false;
         PrintFormat("SMA display name '%s' already on chart; toggle cannot safely remove duplicates.",owned_name);
      }
   return true;
}

void SetOwnedChartIndicators(const bool visible)
{
   if(visible==g_show_chart_indicators) return;
   if(visible)
   {
      bool a=AddOwnedChartMA(g_fast_ma_handles[0],g_chart_fast_name,g_chart_fast_added);
      bool b=AddOwnedChartMA(g_slow_ma_handles[0],g_chart_slow_name,g_chart_slow_added);
      g_show_chart_indicators=(a || b);
      if(!a || !b) Print("WARNING: could not display both M5 SMA indicators.");
   }
   else
   {
      if(g_chart_fast_added && g_chart_fast_name!="" && ChartHasIndicatorName(g_chart_fast_name))
         ChartIndicatorDelete(0,0,g_chart_fast_name);
      if(g_chart_slow_added && g_chart_slow_name!="" && ChartHasIndicatorName(g_chart_slow_name))
         ChartIndicatorDelete(0,0,g_chart_slow_name);
      g_chart_fast_added=false;
      g_chart_slow_added=false;
      g_chart_fast_name="";
      g_chart_slow_name="";
      g_show_chart_indicators=false;
   }
   ChartRedraw(0);
}

void AddIndicatorsToChart()
{
   if(!HideIndicatorsOnChart) SetOwnedChartIndicators(true);
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
// Function: CurrentBrokerTimeForDailyProfit - Use the same clock for the
// daily target and the existing realized-profit panel. Tester time is simulated.
datetime CurrentBrokerTimeForDailyProfit()
{
   datetime now=TimeCurrent();
   if(!MQLInfoInteger(MQL_TESTER))
   {
      datetime server_time=TimeTradeServer();
      if(server_time>0) now=server_time;
   }
   return now;
}

// ENTRY ONLY: determine whether the broker's current trading session is
// still far enough from closing for a NEW order. Never controls exits.
// SymbolInfoSessionTrade() gives session offsets in seconds relative to
// server-day midnight. A session may end on the NEXT server day.
// OnTick TimeCurrent() is the broker's tick/server time, also in MT5 tester.
// For sessions crossing midnight, inspect both today and yesterday.
bool PassPreMarketCloseEntryFilter(datetime &session_close,bool &in_cutoff)
{
   session_close=0;
   in_cutoff=false;
   if(!UsePreMarketCloseEntryFilter) return true;

   const datetime now=TimeCurrent();
   if(now<=0) return false;

   MqlDateTime clock;
   TimeToStruct(now,clock);
   clock.hour=0;
   clock.min=0;
   clock.sec=0;
   const datetime today_midnight=StructToTime(clock);

   bool in_session=false;
   bool has_session_data=false;
   datetime latest_active_close=0;
   for(int days_ago=0;days_ago<=1;days_ago++)
   {
      const datetime session_midnight=today_midnight-(datetime)(days_ago*86400);
      MqlDateTime session_day;
      TimeToStruct(session_midnight,session_day);
      const ENUM_DAY_OF_WEEK weekday=(ENUM_DAY_OF_WEEK)session_day.day_of_week;

      for(uint index=0;index<32;index++)
      {
         datetime from=0,to=0;
         if(!SymbolInfoSessionTrade(_Symbol,weekday,index,from,to))
            break;
         has_session_data=true;

         // Do NOT modulo by 86400: broker sessions may cross midnight
         // and 'to' may already be greater than 86400 seconds.
         const long open_seconds=(long)from;
         long close_seconds=(long)to;
         if(open_seconds<0 || close_seconds<0 ||
            open_seconds>172800 || close_seconds>172800)
            continue;
         if(close_seconds<=open_seconds)
            close_seconds+=86400;

         const datetime absolute_open=session_midnight+(datetime)open_seconds;
         const datetime absolute_close=session_midnight+(datetime)close_seconds;
         if(now>=absolute_open && now<absolute_close)
         {
            in_session=true;
            if(absolute_close>latest_active_close)
               latest_active_close=absolute_close;
         }
      }
   }

   // Some MT5 Strategy Tester agents expose historical prices but do NOT
   // provide SymbolInfoSessionTrade() data. Failing closed in that case would
   // reject every entry for the entire backtest. Permit tester entries only
   // when NO session schedule is available; in this fallback the close-time
   // cutoff is not simulated (the tester/broker still controls execution).
   // Keep the original fail-closed protection in live trading and whenever
   // the tester DOES provide a schedule and the market is outside a session.
   if(!has_session_data && MQLInfoInteger(MQL_TESTER))
   {
      static bool warned_missing_tester_sessions=false;
      if(!warned_missing_tester_sessions)
      {
         Print("TESTER SESSION FALLBACK: broker session schedule unavailable. " +
               "New entries remain enabled in Strategy Tester; pre-close cutoff " +
               "is NOT simulated without session data. Live check is unchanged.");
         warned_missing_tester_sessions=true;
      }
      return true;
   }

   // Missing schedule in live trading, or already closed session: block ONLY
   // new entries; TP, SL, basket and indicator exits continue unchanged.
   if(!in_session) return false;

   session_close=latest_active_close;
   in_cutoff=(latest_active_close-now<=(long)PreMarketCloseMinutes*60);
   return !in_cutoff;
}

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

   // Match daily-target broker-server day (tester uses historical time).
   datetime now=CurrentBrokerTimeForDailyProfit();
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

// Broker-server DATE, independent of local PC time; YYYYMMDD fits in a double.
int BrokerServerDayNumber()
{
   datetime now=CurrentBrokerTimeForDailyProfit();
   if(now<=0) return 0;
   MqlDateTime dt;
   TimeToStruct(now,dt);
   return dt.year*10000+dt.mon*100+dt.day;
}

// Two terminal globals save the last locked day and the target value used.
// Survives restarting the EA. Changing the target re-evaluates the new goal.
// Only this account + symbol + magic combination shares a daily entry lock.
string DailyTargetGlobalRoot()
{
   string root=StringFormat("SMA_DPT_%I64d_%s_%I64u",
                            AccountInfoInteger(ACCOUNT_LOGIN),_Symbol,MagicNumber);
   // Terminal global-variable names have a 63-character maximum.
   return StringSubstr(root,0,57);
}

// Function: DailyTargetAllowsEntries - Check the CLOSED net P/L, not floating.
// Once reached, the daily lock persists even if later position exits reduce P/L.
// On a new server day it automatically unlocks. If history is unavailable,
// disable new entries conservatively, but never disable management of exits.
bool DailyTargetAllowsEntries(const double today_profit,
                              const bool history_ok,bool &target_hit)
{
   target_hit=false;
   if(TargetDailyProfit==0.0)
      return true;

   int today_number=BrokerServerDayNumber();
   if(today_number<=0) return false;

   string root=DailyTargetGlobalRoot();
   string day_key=root+"_DAY";
   string goal_key=root+"_GOAL";
   bool already_locked=(GlobalVariableCheck(day_key) &&
                        GlobalVariableCheck(goal_key) &&
                        (int)GlobalVariableGet(day_key)==today_number &&
                        MathAbs(GlobalVariableGet(goal_key)-TargetDailyProfit)<1e-8);

   if(!already_locked && history_ok &&
      today_profit+1e-8>=TargetDailyProfit)
   {
      already_locked=true;
      // Write the goal first and date last, to avoid a half-written lock.
      datetime saved_goal=GlobalVariableSet(goal_key,TargetDailyProfit);
      datetime saved_day=GlobalVariableSet(day_key,(double)today_number);
      if(saved_goal==0 || saved_day==0)
         PrintFormat("WARNING: daily target reached but cannot persist lock, error=%d",
                     GetLastError());
      PrintFormat("DAILY PROFIT TARGET HIT: realized %.2f >= target %.2f %s. No new positions until the next BROKER-SERVER day. Existing SL/TP/trailing/basket exits remain active.",
                  today_profit,TargetDailyProfit,AccountInfoString(ACCOUNT_CURRENCY));
   }
   target_hit=already_locked;
   return (history_ok && !target_hit);
}

// OR 04.3..04.34: compact names only; exact input switches control grey/orange.
string PanelORName(const int id)
{
   switch(id)
   {
      case 3: return "PULLBACK";
      case 4: return "2-CANDLE";
      case 5: return "MOMENTUM";
      case 6: return "SMA PULLBACK";
      case 7: return "CROSS +1";
      case 8: return "RANGE SWEEP";
      case 9: return "INSIDE RELEASE";
      case 10:return "BREAK RETEST";
      case 11:return "IMBALANCE";
      case 12:return "OUTSIDE TRAP";
      case 13:return "SMA GAP RELEASE";
      case 14:return "TREND STAIRCASE";
      case 15:return "FAST SMA TAP";
      case 16:return "PAUSE RESUME";
      case 17:return "BODY ENGULF";
      case 18:return "VOLUME IGNITION";
      case 19:return "SLOPE ACCEL";
      case 20:return "MICRO CHANNEL";
      case 21:return "VWAP REENTRY";
      case 22:return "RSI RESET";
      case 23:return "OPEN RANGE FAIL";
      case 24:return "ADX TRANSITION";
      case 25:return "BB REENTRY";
      case 26:return "MACD TURN";
      case 27:return "CCI RECOVERY";
      case 28:return "STOCH TURN";
      case 29:return "REGRESSION";
      case 30:return "AROON TURN";
      case 31:return "DUAL ROC";
      case 32:return "FRACTAL 1-2-3";
      case 33:return "SMA TREND CONT";
      case 34:return "INSIDE BREAKOUT";
   }
   return "UNKNOWN";
}

bool PanelORIsEnabled(const int id)
{
   if(NewORIsolatedEntry>0 && id!=NewORIsolatedEntry) return false;
   switch(id)
   {
      case 3:return UseCandleColorEntryFilter;
      case 4:return UseTwoCandleSMAContinuationEntryFilter;
      case 5:return UseMomentumBreakoutEntryFilter;
      case 6:return UseSMAPullbackRejectionEntryFilter;
      case 7:return UseSMACrossConfirmedEntryFilter;
      case 8:return UseRangeSweepReclaimEntryFilter;
      case 14:return UseTrendRunEntryFilter;
      case 33:return UseSMATrendContinuationEntryFilter;
      case 34:return UseInsideBarBreakoutEntryFilter;
   }
   if(id>=9 && id<=13) return NewORIsEnabled(id);
   if(id>=15 && id<=20) return ContinuationORIsEnabled(id);
   if(id>=21 && id<=32) return ResearchORIsEnabled(id);
   return false;
}

bool PanelORIsReady(const int id,const string source)
{
   switch(id)
   {
      case 3:return source=="PULLBACK";
      case 4:return source=="TWO_CANDLE";
      case 5:return source=="MOMENTUM";
      case 6:return source=="SMA_PB";
      case 7:return source=="CROSS_1BAR";
      case 8:return source=="SWEEP_R";
      case 14:return source=="TREND_RUN";
      case 33:return source=="SMA_CONT";
      case 34:return source=="INSIDE_BO";
   }
   if(id>=9 && id<=13) return source==NewORTag(id);
   if(id>=15 && id<=20) return source==ContinuationORTag(id);
   if(id>=21 && id<=32) return source==ResearchORTag(id);
   return false;
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

   // Compute account-currency CLOSED P/L once per panel refresh; reuse it
   // for daily target status and the existing today/yesterday/month rows.
   double today_closed=0.0,yesterday_closed=0.0,month_closed=0.0;
   bool history_ok=ReadClosedProfitPeriods(today_closed,yesterday_closed,month_closed);
   bool daily_target_hit=false;
   bool daily_entries_allowed=DailyTargetAllowsEntries(today_closed,history_ok,daily_target_hit);
   datetime broker_session_close=0;
   bool broker_close_cutoff=false;
   const bool broker_session_entry_allowed=PassPreMarketCloseEntryFilter(broker_session_close,broker_close_cutoff);
   string currency=AccountInfoString(ACCOUNT_CURRENCY);

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
   bool can_check_entry=(candle_valid && (NewORIsolatedEntry==33 || NewORIsolatedEntry==34 || !UseMTFTrendEntryFilter || all_valid));
   bool buy_signal=false,sell_signal=false;
   if(can_check_entry)
   {
      IndicatorState panel_state;
      ZeroMemory(panel_state);
      panel_state.open=candle[0].open;
      panel_state.high=candle[0].high;
      panel_state.low=candle[0].low;
      panel_state.close=candle[0].close;
      for(int i=0;i<TF_COUNT;i++)
      {
         panel_state.fast_ma[i]=fast[i];
         panel_state.slow_ma[i]=slow[i];
      }
      // Only the NEW range-sweep panel needs the full closed candle history.
      if(UseRangeSweepReclaimEntryFilter || NewORAnyEnabled() || UseTrendRunEntryFilter || ContinuationORAnyEnabled() || ResearchORAnyEnabled() || UseSMATrendContinuationEntryFilter || UseInsideBarBreakoutEntryFilter)
      {
         MqlRates sweep_panel_rates[OHLCV_HISTORY];
         if(CopyRates(_Symbol,PERIOD_M5,SIGNAL_SHIFT,OHLCV_HISTORY,sweep_panel_rates)==OHLCV_HISTORY)
         {
            for(int i=0;i<OHLCV_HISTORY;i++)
            {
               const int src=OHLCV_HISTORY-1-i;
               panel_state.ohlcv_time[i]=sweep_panel_rates[src].time;
               panel_state.ohlcv_open[i]=sweep_panel_rates[src].open;
               panel_state.ohlcv_high[i]=sweep_panel_rates[src].high;
               panel_state.ohlcv_low[i]=sweep_panel_rates[src].low;
               panel_state.ohlcv_close[i]=sweep_panel_rates[src].close;
               panel_state.ohlcv_volume[i]=(long)sweep_panel_rates[src].tick_volume;
            }
         }
      }
      buy_signal=BuyCondition(panel_state);
      sell_signal=SellCondition(panel_state);
      // Only recompute the winning OR on a new M5 bar or changed direction.
      // No 30x per-OR re-evaluation on each panel timer refresh.
      const datetime bar_time=iTime(_Symbol,PERIOD_M5,0);
      if(buy_signal!=sell_signal)
      {
         if(bar_time!=g_panel_ready_bar || buy_signal!=g_panel_ready_buy ||
            sell_signal!=g_panel_ready_sell)
         {
            g_panel_ready_source=EntryTriggerName(panel_state,buy_signal);
            g_panel_ready_bar=bar_time;
            g_panel_ready_buy=buy_signal;
            g_panel_ready_sell=sell_signal;
         }
      }
      else
      {
         g_panel_ready_source="";
         g_panel_ready_bar=bar_time;
         g_panel_ready_buy=false;
         g_panel_ready_sell=false;
      }
   }
   else
   {
      g_panel_ready_source="";
      g_panel_ready_buy=false;
      g_panel_ready_sell=false;
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
                           UseTwoCandleSMAContinuationEntryFilter ||
                           UseMomentumBreakoutEntryFilter ||
                           UseSMAPullbackRejectionEntryFilter ||
                           UseSMACrossConfirmedEntryFilter ||
                           UseRangeSweepReclaimEntryFilter || NewORAnyEnabled() || UseTrendRunEntryFilter || ContinuationORAnyEnabled() || ResearchORAnyEnabled() || UseSMATrendContinuationEntryFilter || UseInsideBarBreakoutEntryFilter);
   if(!any_entry_trigger) signal_text="OFF";
   else if(UsePreMarketCloseEntryFilter && !broker_session_entry_allowed)
   {
      signal_text=(broker_close_cutoff ? StringFormat("BLOCK MARKET CLOSE -%dM",PreMarketCloseMinutes) : "BROKER SESSION CLOSED");
      signal_color=PanelColorWait();
   }
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

   // Realized daily/monthly totals were read above; target uses the same data.

   // Draw the outer card first so internal cards and labels stay readable.
   PanelRectangle("background",x,y,g_panel_design_width,g_panel_design_height,
                  PanelColorBg(),PanelColorBorder());
   PanelRectangle("top_accent",x+1,y+1,g_panel_design_width-2,4,
                  C'48,139,223',C'48,139,223');
   PanelLabel("title",(g_panel_columns==2 ? "MTF SMA | BASELINE 002" : "MTF SMA | 002"),
              x+16,y+14,PanelColorText(),13,"Arial");
   string daily_trade_status=(!EnableTrading ? "TRADE OFF" :
                              (daily_target_hit ? "DAILY STOP" :
                              (!daily_entries_allowed ? "WAIT HISTORY" : "TRADE ON")));

   // On one-column charts, navigation occupies the first header row.
   // Trade status remains visible in section 02, with no separate card.
   if(g_panel_columns==2)
      PanelLabel("trading",daily_trade_status,
                 x+g_panel_design_width-112,y+17,
                 (EnableTrading && daily_entries_allowed ? PanelColorBuy() : PanelColorWait()),9);
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

      // Compact 04.3..04.34 overview (all 32 entries, two columns).
      // Grey=OFF, orange=enabled/waiting, green=selected eligible signal.
      int ey=top_y+270;
      PanelSection("entry","02  ENTRY OR  |  04.3-04.34",left_x,ey,PANEL_COL_WIDTH,412);
      PanelLabel("or_legend","GRAY OFF  |  ORANGE ACTIVE  |  GREEN READY",
                 left_x+12,ey+33,PanelColorMuted(),8);
      for(int id=3;id<=34;id++)
      {
         const int idx=id-3;
         const int col=idx/16;
         const int yy=ey+55+(idx%16)*18;
         const int xx=left_x+11+col*192;
         const bool enabled=PanelORIsEnabled(id);
         const bool ready=(enabled && g_panel_ready_source!="" &&
                           PanelORIsReady(id,g_panel_ready_source));
         const color clr=(!enabled ? PanelColorMuted() :
                          (ready ? PanelColorBuy() : PanelColorWait()));
         const string prefix=StringFormat("or_%02d_",id);
         PanelRectangle(prefix+"dot",xx,yy+3,6,6,clr,clr);
         PanelLabel(prefix+"name",StringFormat("%02d %s",id,PanelORName(id)),
                    xx+11,yy,clr,8);
      }
      PanelKV("entry_signal","ENTRY SIGNAL",signal_text,left_x,ey+352,signal_color);
      PanelKV("exec_status","TRADING",(!EnableTrading ? "DISABLED" :
              (daily_target_hit ? "DAILY TARGET HIT" :
               (!daily_entries_allowed ? "WAIT P/L HISTORY" :
               (!broker_session_entry_allowed ? "SESSION CUTOFF" : "ENABLED")))),
              left_x,ey+377,(EnableTrading && daily_entries_allowed && broker_session_entry_allowed ?
                              PanelColorBuy() : PanelColorWait()));
   }

   if(right_page)
   {
      PanelSection("positions","03  POSITIONS & EXIT",right_x,top_y,PANEL_COL_WIDTH,190);
      PanelKV("position_count","EA POSITIONS",StringFormat("%d/%s  B:%d S:%d",
              total,positions_limit,basket_buys,basket_sells),right_x,top_y+38,PanelColorText());
      PanelKV("position_hedge","HEDGE",(basket_buys>0 && basket_sells>0 ?
              "BOTH SIDES" : (AllowBothDirections ? "READY" : "OFF")),
              right_x,top_y+63,(basket_buys>0 && basket_sells>0 ? PanelColorWait() : PanelColorMuted()));
      PanelKV("position_sl","SL / TRAIL",(!UseSwingSL ? "OFF" :
              (UseTrailingStopWithSL && UseRRTP ?
               (basket_active ? "TR PAUSED (BASKET)" :
                StringFormat("M5 [%d] TR %.0f/%.0f",SwingLookbackBars,
                             TrailingStartTPPercent,TrailingProtectMovePercent)) :
               StringFormat("ON M5 [%d]",SwingLookbackBars))),
              right_x,top_y+88,(UseSwingSL ? PanelColorBuy() : PanelColorMuted()));
      PanelKV("position_tp","TP MODE",(basket_active ?
              (basket_buys>0 && basket_sells>0 ? "HEDGE VIRTUAL" : "SHARED TP / EA") : TPModeName()),
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
      double projected_tp=0.0;
      bool projected_buy=true,projected_physical=false;
      bool projected_ok=(basket_active &&
                         CalculateBasketSharedExitPrice(projected_tp,projected_buy,projected_physical));
      PanelKV("basket_target","TARGET",(projected_ok ?
              StringFormat("%.1f pt | %.*f %s",BasketProfitTarget,_Digits,projected_tp,
                           (projected_physical ? "TP" : "VIRTUAL")) :
              StringFormat("%.1f pt | %s",BasketProfitTarget,
                           (basket_active ? "NET FLAT" : "STANDBY"))),
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
      PanelKV("profit_today",(TargetDailyProfit>0.0 ? "TODAY / TARGET" : "TODAY"),
               (history_ok ? (TargetDailyProfit>0.0 ?
                  StringFormat("%+.2f / %.2f %s%s",today_closed,TargetDailyProfit,currency,
                               (daily_target_hit ? " HIT" : "")) :
                  StringFormat("%+.2f %s",today_closed,currency)) : "WAIT HISTORY"),
              right_x,py+36,(daily_target_hit ? PanelColorWait() :
               (history_ok ? (today_closed>=0.0 ? PanelColorBuy() : PanelColorSell()) : PanelColorWait())));
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
   g_entry_quality_atr_handle=INVALID_HANDLE;
   g_momentum_bbands_handle=INVALID_HANDLE;

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


   if((UseCandleColorEntryFilter && UsePullbackShortHoldQualityFilter &&
       (!MathIsValidNumber(PullbackMinSignalRangeATR) || PullbackMinSignalRangeATR<=0.0)) ||
      (UseTwoCandleSMAContinuationEntryFilter && UseTwoCandleShortHoldQualityFilter &&
       (!MathIsValidNumber(TwoCandleMaxEndWickFraction) || TwoCandleMaxEndWickFraction<0.0 || TwoCandleMaxEndWickFraction>1.0)) ||
      (UseSMACrossConfirmedEntryFilter && UseCrossShortHoldQualityFilter &&
       (!MathIsValidNumber(CrossMaxSignalRangeATR) || CrossMaxSignalRangeATR<=0.0 ||
        !MathIsValidNumber(CrossMinDirectionalGapATR) || CrossMinDirectionalGapATR<0.0)))
      return INIT_PARAMETERS_INCORRECT;

   if(NewORIsolatedEntry==34 && !UseInsideBarBreakoutEntryFilter)
      return INIT_PARAMETERS_INCORRECT;
   if(UseInsideBarBreakoutEntryFilter)
   {
      if(IBBTrendBars<1 || IBBTrendBars>OHLCV_HISTORY || IBBTrendMask<0 ||
         IBBTrendMask>15 || IBBSlopeMask<0 || IBBSlopeMask>7 ||
         (UseIBBFreshnessFilter && (IBBFreshBars<1 || IBBFreshBars>OHLCV_HISTORY)) ||
         (UseIBBSpreadFilter && IBBMaxSpreadPoints<=0) ||
         (UseIBBRangeMotherFilter && (!MathIsValidNumber(IBBMinRangeMotherRatio) ||
          IBBMinRangeMotherRatio<=0.0)) ||
         (UseIBBMinMAGapMotherFilter && (!MathIsValidNumber(IBBMinMAGapMotherRatio) ||
          IBBMinMAGapMotherRatio<=0.0)) ||
         (UseIBBCompressionFilter && (!MathIsValidNumber(IBBMaxInsideMotherRatio) ||
          IBBMaxInsideMotherRatio<=0.0 || IBBMaxInsideMotherRatio>1.0)) ||
         (UseIBBRangeATRFilter && (!MathIsValidNumber(IBBMinRangeATR) ||
          !MathIsValidNumber(IBBMaxRangeATR) || IBBMinRangeATR<0.0 ||
          IBBMaxRangeATR<=0.0 || IBBMaxRangeATR<IBBMinRangeATR)) ||
         (UseIBBBodyFractionFilter && (!MathIsValidNumber(IBBMinBodyFraction) ||
          IBBMinBodyFraction<0.0 || IBBMinBodyFraction>1.0)) ||
         (UseIBBEndWickFilter && (!MathIsValidNumber(IBBMaxEndWickFraction) ||
          IBBMaxEndWickFraction<0.0 || IBBMaxEndWickFraction>1.0)) ||
         (UseIBBCloseFastATRFilter && (!MathIsValidNumber(IBBMaxCloseFastATR) ||
          IBBMaxCloseFastATR<=0.0)) ||
         (UseIBBEntryGapATRFilter && (!MathIsValidNumber(IBBMaxEntryGapATR) ||
          IBBMaxEntryGapATR<=0.0))) return INIT_PARAMETERS_INCORRECT;
      PrintFormat("INSIDE BAR BREAKOUT OR04.34: isolation=%d, strict closed [3]/[2]/[1], Mother/Inside colours ignored; local optional filters; exits unchanged.",NewORIsolatedEntry);
   }

   if(NewORIsolatedEntry==33 && !UseSMATrendContinuationEntryFilter)
      return INIT_PARAMETERS_INCORRECT;
   if(UseSMATrendContinuationEntryFilter)
   {
      if(STCTrendBars<1 || STCTrendBars>OHLCV_HISTORY || STCTrendMask<0 ||
         STCTrendMask>15 || STCSlopeMask<0 || STCSlopeMask>7 ||
         (UseSTCSpreadFilter && STCMaxSpreadPoints<=0) ||
         (UseSTCFreshnessFilter && (STCFreshBars<1 || STCFreshBars>OHLCV_HISTORY)) ||
         (UseSTCRangeATRFilter && (!MathIsValidNumber(STCMinRangeATR) ||
          !MathIsValidNumber(STCMaxRangeATR) || STCMinRangeATR<0.0 ||
          STCMaxRangeATR<=0.0 || STCMaxRangeATR<STCMinRangeATR)) ||
         (UseSTCBodyFractionFilter && (!MathIsValidNumber(STCMinBodyFraction) ||
          STCMinBodyFraction<0.0 || STCMinBodyFraction>1.0)) ||
         (UseSTCEndWickFilter && (!MathIsValidNumber(STCMaxEndWickFraction) ||
          STCMaxEndWickFraction<0.0 || STCMaxEndWickFraction>1.0)) ||
         (UseSTCCloseFastATRFilter && (!MathIsValidNumber(STCMaxCloseFastATR) ||
          STCMaxCloseFastATR<=0.0))) return INIT_PARAMETERS_INCORRECT;
      PrintFormat("SMA TREND CONTINUATION OR04.33: isolation=%d, closed M5 MA ordering, flat-only; optional local filters; exits unchanged.",NewORIsolatedEntry);
   }

   if(NewORIsolatedEntry>=21 && NewORIsolatedEntry<=32 &&
      (ResearchOREnabledCount()!=1 || !ResearchORIsEnabled(NewORIsolatedEntry)))
   {
      PrintFormat("INVALID RESEARCH ISOLATION: selector=%d requires exactly1 enabled research OR04.21..04.32 and the selected master ON; enabled=%d selectedMaster=%s. Use selector0 for combined entries.",NewORIsolatedEntry,ResearchOREnabledCount(),(ResearchORIsEnabled(NewORIsolatedEntry) ? "ON" : "OFF"));
      return INIT_PARAMETERS_INCORRECT;
   }
   if(ResearchORAnyEnabled())
   {
      if(ResearchORMaxSpreadPoints<1 || ResearchORMaxEntryGapATR<=0.0 ||
         ResearchORSessionCutoffMinutes<0 || ResearchORSessionCutoffMinutes>1440)return INIT_PARAMETERS_INCORRECT;
      for(int id=21;id<=32;id++)
      {
         double lo,hi,body,wick;int mask;
         ResearchORQualityParameters(id,lo,hi,body,wick,mask);
         if(!MathIsValidNumber(lo) || !MathIsValidNumber(hi) || lo<=0.0 || hi<lo ||
            body<=0.0 || body>1.0 || wick<0.0 || wick>1.0 || mask<0 || mask>255)return INIT_PARAMETERS_INCORRECT;
      }
      PrintFormat("RESEARCH OR04.21..04.32; isolation=%d; closed signals; natural-positive re-entry; old-OR veto; exits unchanged.",NewORIsolatedEntry);
   }

   // New-only validation never blocks old strategies when all new groups are OFF.
   if(NewORIsolatedEntry!=0 && NewORIsolatedEntry!=3 && NewORIsolatedEntry!=4 &&
      NewORIsolatedEntry!=7 && (NewORIsolatedEntry<9 || NewORIsolatedEntry>34))
      return INIT_PARAMETERS_INCORRECT;
   if((NewORIsolatedEntry==3 && !UseCandleColorEntryFilter) ||
      (NewORIsolatedEntry==4 && !UseTwoCandleSMAContinuationEntryFilter) ||
      (NewORIsolatedEntry==7 && !UseSMACrossConfirmedEntryFilter))
      return INIT_PARAMETERS_INCORRECT;
   if(NewORIsolatedEntry>=9 && NewORIsolatedEntry<=20)
   {
      int enabled_new=0;
      for(int id=9;id<=13;id++) if(NewORIsEnabled(id)) enabled_new++;
      if(NewORIsolatedEntry>=15)
      {
         int enabled_continuation=0;
         for(int id=15;id<=20;id++) if(ContinuationORIsEnabled(id)) enabled_continuation++;
         if(enabled_continuation!=1 || !ContinuationORIsEnabled(NewORIsolatedEntry)) return INIT_PARAMETERS_INCORRECT;
      }
      else
      {
         if(ContinuationORAnyEnabled()) return INIT_PARAMETERS_INCORRECT;
         if(NewORIsolatedEntry==14)
         {
            if(enabled_new!=0 || !UseTrendRunEntryFilter) return INIT_PARAMETERS_INCORRECT;
         }
         else if(enabled_new!=1 || !NewORIsEnabled(NewORIsolatedEntry) || UseTrendRunEntryFilter) return INIT_PARAMETERS_INCORRECT;
      }
   }
   for(int id=9;id<=13;id++)
   {
      if(!NewORIsEnabled(id)) continue;
      double min_range,max_range,end_wick,fast_distance;
      NewORQualityParameters(id,min_range,max_range,end_wick,fast_distance);
      if(!MathIsValidNumber(min_range) || !MathIsValidNumber(max_range) || min_range<=0.0 || max_range<min_range ||
         !MathIsValidNumber(end_wick) || end_wick<0.0 || end_wick>1.0 ||
         !MathIsValidNumber(fast_distance) || fast_distance<0.0) return INIT_PARAMETERS_INCORRECT;
   }

   if(UseTrendRunEntryFilter &&
      (!MathIsValidNumber(TrendRunMinRangeATR) || TrendRunMinRangeATR<=0.0 ||
       !MathIsValidNumber(TrendRunMaxRangeATR) || TrendRunMaxRangeATR<TrendRunMinRangeATR ||
       !MathIsValidNumber(TrendRunMaxEndWickFraction) || TrendRunMaxEndWickFraction<0.0 || TrendRunMaxEndWickFraction>1.0 ||
       !MathIsValidNumber(TrendRunMaxCloseFastATR) || TrendRunMaxCloseFastATR<=0.0))
      return INIT_PARAMETERS_INCORRECT;

   for(int id=15;id<=20;id++)
   {
      if(!ContinuationORIsEnabled(id)) continue;
      double min_range,max_range,end_wick,fast_distance;
      bool higher_tf=false;
      ContinuationORQualityParameters(id,min_range,max_range,end_wick,fast_distance,higher_tf);
      if(!MathIsValidNumber(min_range) || min_range<=0.0 || !MathIsValidNumber(max_range) || max_range<min_range ||
         !MathIsValidNumber(end_wick) || end_wick<0.0 || end_wick>1.0 ||
         !MathIsValidNumber(fast_distance) || fast_distance<=0.0) return INIT_PARAMETERS_INCORRECT;
   }
   if(UseSMAPullbackShortHoldQualityFilter &&
      (!MathIsValidNumber(SMAPullbackMinSignalRangeATR) || SMAPullbackMinSignalRangeATR<=0.0 ||
       !MathIsValidNumber(SMAPullbackMaxEndWickFraction) || SMAPullbackMaxEndWickFraction<0.0 || SMAPullbackMaxEndWickFraction>1.0 ||
       !MathIsValidNumber(SMAPullbackMinBodyFraction) || SMAPullbackMinBodyFraction<=0.0 || SMAPullbackMinBodyFraction>1.0))
      return INIT_PARAMETERS_INCORRECT;
   if(UsePauseResumeEntryFilter && (!MathIsValidNumber(PauseResumeMaxPauseBodyATR) || PauseResumeMaxPauseBodyATR<=0.0)) return INIT_PARAMETERS_INCORRECT;
   if(UseVolumeIgnitionEntryFilter &&
      (!MathIsValidNumber(VolumeIgnitionMinVolumeRatio) || VolumeIgnitionMinVolumeRatio<=0.0 ||
       !MathIsValidNumber(VolumeIgnitionMinBodyFraction) || VolumeIgnitionMinBodyFraction<=0.0 || VolumeIgnitionMinBodyFraction>1.0)) return INIT_PARAMETERS_INCORRECT;
   if(UseSlopeAccelerationEntryFilter && (!MathIsValidNumber(SlopeAccelMinAccelerationATR) || SlopeAccelMinAccelerationATR<0.0)) return INIT_PARAMETERS_INCORRECT;

   // Validate only the enabled NEW OR; legacy entries are unaffected when OFF.
   if(UseRangeSweepReclaimEntryFilter &&
      (RangeSweepLookbackBars<2 || RangeSweepLookbackBars>=OHLCV_HISTORY ||
       !MathIsValidNumber(RangeSweepMinRangeATR) || RangeSweepMinRangeATR<=0.0 ||
       !MathIsValidNumber(RangeSweepMaxRangeATR) || RangeSweepMaxRangeATR<RangeSweepMinRangeATR ||
       !MathIsValidNumber(RangeSweepMaxEndWickFraction) ||
       RangeSweepMaxEndWickFraction<0.0 || RangeSweepMaxEndWickFraction>1.0))
   {
      Print("Invalid 04.8 Range Sweep Reclaim parameters.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if((FastMAPeriod<=0 || SlowMAPeriod<=0 || LotSize<=0.0 || !MathIsValidNumber(TargetDailyProfit) || TargetDailyProfit<0.0 || MaxPositionsPerSymbol<0 || SlippagePoints<0 || PreMarketCloseMinutes<0 || PreMarketCloseMinutes>1440 || SwingLookbackBars<1 || SwingLookbackBars>OHLCV_HISTORY || SwingSLBufferPoints<0 || (UseTrailingStopWithSL && (!MathIsValidNumber(TrailingStartTPPercent) || TrailingStartTPPercent<=0.0 || TrailingStartTPPercent>=100.0 || !MathIsValidNumber(TrailingProtectMovePercent) || TrailingProtectMovePercent<=0.0 || TrailingProtectMovePercent>=100.0)) || EntryQualityATRPeriod<1 || (UseMomentumBreakoutEntryFilter && UseMomentumBollingerCloseFilter && (MomentumBollingerPeriod<2 || !MathIsValidNumber(MomentumBollingerDeviation) || MomentumBollingerDeviation<=0.0)) || (UseTwoCandleCloseSMA8ATRFilter && (!MathIsValidNumber(TwoCandleMaxCloseSMA8ATR) || TwoCandleMaxCloseSMA8ATR<=0.0)) || (UseTwoCandleSMAContinuationEntryFilter && UseTwoCandleOpenGap12Filter && TwoCandleMaxOpenGap12Points<0) || !MathIsValidNumber(MomentumMaxRangeATR) || MomentumMaxRangeATR<=0.0 || (UseSMAPullbackRejectionEntryFilter && (!MathIsValidNumber(SMAPullbackMaxDistanceATR) || SMAPullbackMaxDistanceATR<=0.0 || (UseSMAPullbackOpenGapFilter && SMAPullbackMaxOpenGapPoints<0) || (UseSMAPullbackOpenGap23Filter && SMAPullbackMaxOpenGap23Points<0))) || BasketProfitTarget<=0.0 || !MathIsValidNumber(BasketProfitTarget) || (UseRecoveryLot && (!MathIsValidNumber(RecoveryLotMultiplier) || (RecoveryLotMultiplier!=0.0 && RecoveryLotMultiplier<1.0))) || (UseRecoveryLot && RecoveryLotMultiplier==0.0 && (DynamicRecoveryMovePoints<=0 || MaxDynamicRecoveryLot<LotSize || !MathIsValidNumber(MaxDynamicRecoveryLot) || MaxDynamicMarginPct<=0.0 || MaxDynamicMarginPct>100.0 || !MathIsValidNumber(MaxDynamicMarginPct))) || (UseSwingSL && UseRRTP && (RiskRewardRatio<=0.0 || !MathIsValidNumber(RiskRewardRatio))) || (UsingNoSLTPMode() && NoSLTPMode==TP_FIXED_POINTS && FixedTPPoints<=0) || (UseMomentumBreakoutEntryFilter && (!MathIsValidNumber(MomentumMinBodyRatio) || MomentumMinBodyRatio<=0.0 || MomentumMinBodyRatio>1.0 || MomentumBreakoutLookbackBars<1 || MomentumBreakoutLookbackBars>=OHLCV_HISTORY)) || PanelX<0 || PanelY<0 || PanelRefreshSeconds<1 || PanelFontScalePercent<60 || PanelFontScalePercent>150 || PanelMaxColumns<1 || PanelMaxColumns>2))
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

   if(!UseCandleColorEntryFilter &&
      !UseTwoCandleSMAContinuationEntryFilter &&
      !UseMomentumBreakoutEntryFilter &&
      !UseSMAPullbackRejectionEntryFilter && !UseSMACrossConfirmedEntryFilter &&
      !UseRangeSweepReclaimEntryFilter && !NewORAnyEnabled() && !UseTrendRunEntryFilter && !ContinuationORAnyEnabled() && !UseSMATrendContinuationEntryFilter && !UseInsideBarBreakoutEntryFilter && !ResearchORAnyEnabled())
   {
      Print("Entry OR group is empty: enable at least one supported entry OR master, including Research OR04.21..04.32.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(EnabledTFCount()==0 &&
      (UseMTFTrendEntryFilter ||
       (UsingNoSLTPMode() && NoSLTPMode==TP_ALL_ACTIVE_TFS_OPPOSE)))
   {
      Print("Enable at least one TF for SMA entry filtering or ALL-TF-OPPOSITE TP mode.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(UseTrailingStopWithSL)
   {
      if(!UseSwingSL || !UseRRTP)
         Print("TRAILING SL is ON but requires UseSwingSL=true AND UseRRTP=true with physical RR TP; currently inactive.");
      else
         PrintFormat("TRAILING SL ON: activate %.1f%% of original TP, protect %.1f%% of moved profit; trailing gap %.1f%% of TP distance.",
                     TrailingStartTPPercent,TrailingProtectMovePercent,
                     TrailingStartTPPercent*(100.0-TrailingProtectMovePercent)/100.0);
      CleanupTrailingTPKeys();
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
   if(UsePreMarketCloseEntryFilter)
      PrintFormat("BROKER MARKET CLOSE CUTOFF ON: stop ALL new entries %d minutes before each symbol trade-session close (server time); exits remain active. Tester with no broker session schedule will skip only this cutoff.",
                  PreMarketCloseMinutes);

   if(TargetDailyProfit>0.0)
      PrintFormat("DAILY TARGET ON: %.2f %s CLOSED net P/L (EA Symbol=%s Magic=%I64u); stop opening new positions for remainder of broker-server day on hit. Do not force-close existing positions.",
                  TargetDailyProfit,AccountInfoString(ACCOUNT_CURRENCY),_Symbol,MagicNumber);
   else
      Print("DAILY TARGET OFF: TargetDailyProfit=0, no daily-profit restriction on new entries.");
   if(UseRecoveryLot && RecoveryLotMultiplier==0.0)
       Print("WARNING: dynamic recovery sizes exposure for an assumed favorable price move, not a guaranteed TP. Basket closes on actual target points and is active even when UseRRTP=false. High margin/drawdown risk.");
   if(UseSameSideRecoveryLot)
       Print("NOTE: Same-side losing entry enables combined Basket TP with NO same-side lot increase. Swing SL remains active if configured.");
   if(ContinuationORAnyEnabled())
      PrintFormat("CONTINUATION OR 04.15-04.20 ON; isolation=%d; flat-only sequential; closed signals; legacy/earlier eligibility veto; exits unchanged.",NewORIsolatedEntry);
   if(UseTrendRunEntryFilter)
      PrintFormat("TREND RUN 04.14 ON; isolation=%d; flat-only sequential entries; closed M5 staircase with M15/M30 confirmation; legacy/new overlap veto; exits unchanged.",NewORIsolatedEntry);
   if(NewORAnyEnabled())
      PrintFormat("NEW OR 04.9-04.13 ON; isolation=%d; initial only; legacy/earlier-new overlap veto; exits unchanged.",NewORIsolatedEntry);
   if(UseRangeSweepReclaimEntryFilter)
      Print("RANGE SWEEP RECLAIM 04.8 ON: closed range sweep, midpoint reclaim, initial only, legacy-overlap veto; exits unchanged.");
   if(UseSMACrossConfirmedEntryFilter)
   {
      Print("CROSS+1BAR 04.7 MASTER ON: cross at [2] is mandatory; secondary filters are independently switchable.");
      PrintFormat("CROSS+1BAR FILTERS: QUIET10=%s [2]COLOR=%s [2]WICK=%s [1]SMA_DIR=%s [1]COLOR=%s [1]BREAK=%s [1]WICK=%s SMA12_SLOPE[1-3]=%s SMA8_SLOPE[1-5]=%s",
                  (UseCrossQuietHistory10Filter ? "ON" : "OFF"),
                  (UseCrossCandle2ColorFilter ? "ON" : "OFF"),
                  (UseCrossCandle2BodyWickFilter ? "ON" : "OFF"),
                  (UseCrossSMA1DirectionFilter ? "ON" : "OFF"),
                  (UseCrossConfirm1ColorFilter ? "ON" : "OFF"),
                  (UseCrossConfirm1BreakoutFilter ? "ON" : "OFF"),
                  (UseCrossConfirm1BodyWickFilter ? "ON" : "OFF"),
                  (UseCrossSMA12Slope13Filter ? "ON" : "OFF"),
                  (UseCrossSMA8Slope15Filter ? "ON" : "OFF"));
      if(UseSMACrossConfirmedRangeDistanceFilter)
         Print("CROSS+1BAR RANGE GAP: BUY Low[1]-(High[1]-Low[1])>=SMA12[1]; SELL High[1]+(High[1]-Low[1])<=SMA12[1]. Minimum gap, no multiplier.");
      else
         Print("WARNING: CROSS+1BAR range-position filter OFF; base [2] cross/[1] confirm rules remain active.");
   }
   if(UseTwoCandleSMAContinuationEntryFilter)
   {
      Print("TWO-CANDLE ENTRY 04.4 MASTER ON: mandatory v3.55 pattern checks now have independent switches; all ON preserves original logic.");
      PrintFormat("TWO-CANDLE CORE: SMA DIRECTION=%s SMA12 SLOPE=%s SAME COLOR=%s BREAK [2]=%s SWING BREAK=%s SIGNAL WICK=%s SWING WICK=%s",
                  (UseTwoCandleSMA8SMA12DirectionFilter ? "ON" : "OFF"),
                  (UseTwoCandleSMA12Slope15Filter ? "ON" : "OFF"),
                  (UseTwoCandleSameColor12Filter ? "ON" : "OFF"),
                  (UseTwoCandleBreakout2Filter ? "ON" : "OFF"),
                  (UseTwoCandleSwingBreakout38Filter ? "ON" : "OFF"),
                  (UseTwoCandleSignalWick1Filter ? "ON" : "OFF"),
                  (UseTwoCandleSwingWick38Filter ? "ON" : "OFF"));
      if(UseTwoCandleSignalRangeSMA8Filter)
         Print("TWO-CANDLE [1] RANGE SMA8 ON: BUY Low[1]-Range[1]<=SMA8[1]; SELL High[1]+Range[1]>=SMA8[1].");
      if(UseTwoCandleBodyInsideSMABandFilter)
         Print("TWO-CANDLE [2..8] SMA BAND FILTER ON: reject BUY or SELL if ANY candle (green/red/doji) has BOTH Open and Close within its own SMA8/SMA12 band (edges inclusive).");
      if(UseTwoCandleSMA8Slope25Filter)
         Print("TWO-CANDLE SMA8 SLOPE [2..5] ON: BUY SMA8[2]>[3]>[4]>[5]; SELL SMA8[2]<[3]<[4]<[5]. Strict closed-bar slope.");
      if(UseTwoCandleOppositeBody5Filter)
         Print("TWO-CANDLE OPPOSITE BODY [1..5] ON: BUY rejects RED body > immediately preceding GREEN body; SELL rejects GREEN body > immediately preceding RED body; equal size passes.");
      if(UseTwoCandleCloseSMA8ATRFilter)
         PrintFormat("TWO-CANDLE CLOSE/SMA8 ATR ON: abs(Close[1]-SMA8[1]) <= ATR(%d)[1] * %.2f (BUY and SELL).",
                     EntryQualityATRPeriod,TwoCandleMaxCloseSMA8ATR);
      if(UseTwoCandleOpenGap12Filter)
         PrintFormat("TWO-CANDLE OPEN GAP [2]->[1] ON: abs(Open[1]-Close[2]) <= %d broker points (BUY/SELL).",
                     TwoCandleMaxOpenGap12Points);
   }
   if(UseCandleColorEntryFilter)
   {
      Print("PULLBACK CONTINUATION: M5 [3]=[1] direction, [2] opposite, Body[1]>Body[2], Body ratio<=3, Close[1] breaks [2]; BUY Fast[1]>Slow[1] and Close[1]>Fast[1]>Low[1]; SELL Fast[1]<Slow[1] and Close[1]<Fast[1]<High[1].");
      Print("PULLBACK [3] WICK CHECK: BUY Body[3]>UpperWick[3], SELL Body[3]>LowerWick[3].");
      Print("PULLBACK M5 SMA AGREEMENT: BUY Fast[1]>Slow[1] AND Fast[2]>Slow[2]; SELL Fast[1]<Slow[1] AND Fast[2]<Slow[2].");
      Print("PULLBACK [1-7] SMA GAP: if SMA8/12 cross or touch occurs in [1]..[5], skip gap check; otherwise require positive non-narrowing gap through [7] to [1].");
   }
   if(UseMomentumBreakoutEntryFilter)
   {
      PrintFormat("M5 MOMENTUM 04.5 CORE: Color[1]=%s SMA direction[1]=%s; legacy EXIT breakout lookback=%d, minimum Body/Range=%.2f.",
                  (UseMomentumSignalColor1Filter ? "ON" : "OFF"),
                  (UseMomentumSMA8SMA12DirectionFilter ? "ON" : "OFF"),
                  MomentumBreakoutLookbackBars,MomentumMinBodyRatio);
      if((!UseMomentumSignalColor1Filter && !UseMomentumSMA8SMA12DirectionFilter))
         Print("MOMENTUM NOTE: color, breakout and SMA direction are all OFF. Both BUY/SELL may qualify at once; conflicting signals prevent entry.");
   }

   if(UseMomentumBreakoutEntryFilter && UseMomentumBodyVsBothWicks1Filter)
      Print("MOMENTUM BODY/WICKS [1] ON: Body[1]>=UpperWick[1] AND Body[1]>=LowerWick[1], equality passes (ENTRY ONLY).");
   if(UseMomentumBreakoutEntryFilter && UseMomentumBollingerCloseFilter)
      PrintFormat("MOMENTUM BOLLINGER CLOSE [1] ON: BB(%d, %.2f) M5 PRICE_CLOSE; BUY Close[1]<=Upper[1], SELL Close[1]>=Lower[1], equality passes (ENTRY ONLY).",
                  MomentumBollingerPeriod,MomentumBollingerDeviation);

   if(UseMomentumBreakoutEntryFilter && UseMomentumSlopeEntryFilter)
      Print("MOMENTUM SLOPE+GAP ON: BUY both SMAs rise, SMA8-SMA12 [1]>[2]; SELL both SMAs fall, SMA12-SMA8 [1]>[2]. All on closed M5 candles; only Momentum entries affected.");
   if(UseMomentumBreakoutEntryFilter && UseMomentumSMA8Slope13Filter)
      Print("MOMENTUM SMA8 [1..3] SLOPE ON: BUY SMA8[1]>[2]>[3]; SELL SMA8[1]<[2]<[3]. Independent Entry 04.5 filter.");

   if(UseMomentumBreakoutEntryFilter && UseMomentumOppositeBody25Filter)
      Print("MOMENTUM OPPOSITE BODY [2..5] ON: BUY blocks RED body > immediately prior GREEN body; SELL mirrors; only adjacent closed bars [2..5], equal passes (ENTRY ONLY).");
   if(UseMomentumBreakoutEntryFilter && UseMomentumOppositeColorBreakout12Filter)
      Print("MOMENTUM OPPOSITE COLOR BREAKOUT [1-2] ON: BUY [2]RED/[1]GREEN requires Close[1]>High[2]; SELL [2]GREEN/[1]RED requires Close[1]<Low[2]; other color pairs PASS (ENTRY ONLY).");

   if(UseSMAPullbackRejectionEntryFilter)
      PrintFormat("SMA PULLBACK ENTRY: [2] must be opposite non-Doji color to [1]; M5 [2] touches SMA8 and respects SMA12; [1] directional breakout, Body>directional wick; entry distance<=%.2f x ATR(%d)[2]. Entry only.",
                  SMAPullbackMaxDistanceATR,EntryQualityATRPeriod);
   if(UseSMAPullbackRejectionEntryFilter && UseSMAPullbackOpenGapFilter)
      PrintFormat("SMA PULLBACK OPEN GAP ON: abs(Open[1]-Close[2]) <= %d broker points (ENTRY 04.6 ONLY).",
                  SMAPullbackMaxOpenGapPoints);
   if(UseSMAPullbackRejectionEntryFilter && UseSMAPullbackOpenGap23Filter)
      PrintFormat("SMA PULLBACK [2-3] OPEN GAP ON: abs(Open[2]-Close[3]) <= %d broker points (ENTRY 04.6 ONLY).",
                  SMAPullbackMaxOpenGap23Points);

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
   trade.SetDeviationInPoints(NativeBrokerPointsFromInput(SlippagePoints));
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

   // Bollinger Bands are only needed for the optional 04.5 new-entry filter.
   // Buffer indexes: 0=middle, 1=upper, 2=lower.
   if(UseMomentumBreakoutEntryFilter && UseMomentumBollingerCloseFilter)
   {
      g_momentum_bbands_handle=iBands(_Symbol,PERIOD_M5,MomentumBollingerPeriod,0,
                                     MomentumBollingerDeviation,PRICE_CLOSE);
      if(g_momentum_bbands_handle==INVALID_HANDLE)
      {
         PrintFormat("Cannot create M5 Bollinger Bands(%d, %.2f) for Momentum 04.5. Error=%d",
                     MomentumBollingerPeriod,MomentumBollingerDeviation,GetLastError());
         return INIT_FAILED;
      }
   }

   // Create shared quality ATR only when at least one dependent gate is active.
   if(((UseCandleColorEntryFilter && UsePullbackShortHoldQualityFilter) || (UseSMACrossConfirmedEntryFilter && UseCrossShortHoldQualityFilter) || (UseMomentumBreakoutEntryFilter && UseMomentumInitialEntryQualityFilter) || UseSMAPullbackRejectionEntryFilter || (UseTwoCandleSMAContinuationEntryFilter && UseTwoCandleCloseSMA8ATRFilter) || (UseRangeSweepReclaimEntryFilter && UseRangeSweepSignalQualityFilter) || NewORAnyEnabled() || UseTrendRunEntryFilter || ContinuationORAnyEnabled() || ResearchORAnyEnabled() || STCNeedsATR() || IBBNeedsATR() || (UseSMATrendContinuationEntryFilter && UseSTCPriorORVeto)))
   {
      g_entry_quality_atr_handle=iATR(_Symbol,PERIOD_M5,EntryQualityATRPeriod);
      if(g_entry_quality_atr_handle==INVALID_HANDLE)
      {
         PrintFormat("Cannot create entry-quality M5 ATR(%d), error=%d",
                     EntryQualityATRPeriod,GetLastError());
         return INIT_FAILED;
      }
   }

   g_panel_prefix=StringFormat("MTFSMA002_%I64u_",MagicNumber);
   AddIndicatorsToChart();
   g_last_bar_time=iTime(_Symbol,PERIOD_M5,0);
   LogResearchOREnvironment();
   g_panel_user_percent=PanelFontScalePercent;
   if(ShowStatusPanel)
   {
      UpdateStatusPanel();
      if(!EventSetTimer(PanelRefreshSeconds))
         PrintFormat("Panel timer setup failed. Error=%d",GetLastError());
   }

   PrintFormat("MTF SMA EA BASELINE 002 v4.11 | TF=M5 | Fast=%d Slow=%d | ActiveTF=%d/5 | MTF Bias=%s | MTF_GATE=%s | PULLBACK=%s CROSS_1BAR=%s MOMENTUM=%s SMA_PB=%s | SwingSL=%s Lookback=%d | TP=%s | Trading=%s",
               FastMAPeriod,SlowMAPeriod,EnabledTFCount(),
               (MTFEntryBiasMode==MTF_MAJORITY ? "MAJORITY" : "ALL AGREE"),
               (UseMTFTrendEntryFilter ? "ON" : "OFF"),
               (UseCandleColorEntryFilter ? "ON" : "OFF"),
               (UseSMACrossConfirmedEntryFilter ? "ON" : "OFF"),
               (UseMomentumBreakoutEntryFilter ? "ON" : "OFF"),
               (UseSMAPullbackRejectionEntryFilter ? "ON" : "OFF"),
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
   UpdateBasketSharedTPLine(false);
   SetOwnedChartIndicators(false);
   DeleteStatusPanel();
   if(g_momentum_bbands_handle!=INVALID_HANDLE)
   {
      IndicatorRelease(g_momentum_bbands_handle);
      g_momentum_bbands_handle=INVALID_HANDLE;
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

      UpdateBasketSharedTPLine(basket_mode);
      if(basket_mode)
      {
         // One-sided basket has a shared broker TP. A hedge uses a virtual
         // target price plus a tick-managed combined exit; SLs are untouched.
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
         // On every tick, secure earned profits from active SL+TP positions.
         // Do not trail while combined Basket TP is in control.
         ApplyTPProgressTrailing();
      }
   }

   bool new_bar=IsNewBar();
   if(new_bar)
      CleanupTrailingTPKeys();
   if(TradeOnNewBarOnly && !new_bar)
      return;

   // No M5 indicator signal exit should fire while the basket is active.
   bool hedge_active=HasMyHedge();
   IndicatorState s;
   if(!ReadIndicatorState(s))
   {
      LogResearchORStateReadiness();
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
   datetime broker_session_close=0;
   bool broker_close_cutoff=false;
   const bool broker_session_entry_allowed=PassPreMarketCloseEntryFilter(broker_session_close,broker_close_cutoff);
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
      if(broker_session_entry_allowed && buy_signal && CountMyPositionsByType(POSITION_TYPE_SELL)>0)
         close_sell=false;
      if(broker_session_entry_allowed && sell_signal && CountMyPositionsByType(POSITION_TYPE_BUY)>0)
         close_buy=false;
   }

   // Same-side basket entry has priority over per-position MA exits even
   // if AllowBothDirections is OFF; this mode does not require hedging.
   if(UseSameSideRecoveryLot && !g_same_recovery_active && broker_session_entry_allowed)
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

   // Session cutoff blocks ALL NEW orders (including hedge/recovery entries),
   // but never exits. At a session close, missing schedule data fails closed.
   if(!broker_session_entry_allowed)
   {
      if(PrintSignalLog && buy_signal!=sell_signal)
         PrintFormat("NEW ENTRY BLOCKED: %s; %d-minute broker market-close cutoff. Session close=%s (server time).",
                     (broker_close_cutoff ? "approaching session close" : "no current broker trade session"),
                     PreMarketCloseMinutes,
                     (broker_session_close>0 ? TimeToString(broker_session_close,TIME_DATE|TIME_MINUTES) : "N/A"));
      return;
   }

   // Daily target blocks NEW orders only. All existing exits, basket TP,
   // Stop Loss and trailing above are kept running even after the limit hits.
   // Recheck history after any indicator exits on this bar.
   if(TargetDailyProfit>0.0)
   {
      double today_closed=0.0,yesterday_closed=0.0,month_closed=0.0;
      bool history_ok=ReadClosedProfitPeriods(today_closed,yesterday_closed,month_closed);
      bool target_hit=false;
      if(!DailyTargetAllowsEntries(today_closed,history_ok,target_hit))
         return;
   }

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
   // For EVERY addition to a basket, clear old individual/shared TPs before
   // submitting the new position. Otherwise a broker TP might fire while the
   // basket composition is changing (even when basket mode was already ON).
   bool prepared_existing_basket=(entry_needs_basket && CountMyPositions()>0);
   if(prepared_existing_basket && !SynchronizeTakeProfits(true,true))
   {
      Print("Basket entry postponed: existing broker TPs could not be cleared.");
      SynchronizeTakeProfits(currently_in_basket);
      return;
   }

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick))
   {
      if(prepared_existing_basket) SynchronizeTakeProfits(currently_in_basket);
      return;
   }
   double sl=0.0,tp=0.0;
   if(!PrepareOrderStops(s,is_buy,tick,sl,tp,entry_needs_basket))
   {
      if(prepared_existing_basket) SynchronizeTakeProfits(currently_in_basket);
      return;
   }

   // Final quote-sensitive ENTRY recheck: common gates may change
   // between signal evaluation and order placement.
   // A different enabled OR may still qualify independently.
   bool final_buy_signal=BuyCondition(s);
   bool final_sell_signal=SellCondition(s);
   if((is_buy && (!final_buy_signal || final_sell_signal)) ||
      (!is_buy && (!final_sell_signal || final_buy_signal)))
   {
      if(PrintSignalLog)
         Print("Entry postponed: quote moved or entry gate/OR changed before sending.");
      if(prepared_existing_basket) SynchronizeTakeProfits(currently_in_basket);
      return;
   }

   // Final session check: a slow evaluation cannot open a new order after
   // the cutoff. Restore TPs if this attempt had temporarily entered basket mode.
   datetime last_session_close=0;
   bool last_session_cutoff=false;
   if(!PassPreMarketCloseEntryFilter(last_session_close,last_session_cutoff))
   {
      if(PrintSignalLog)
         Print("Entry postponed: broker trading session closed or market-close cutoff reached.");
      if(prepared_existing_basket) SynchronizeTakeProfits(currently_in_basket);
      return;
   }

   // Store the entry trigger category in the broker comment for analysis.
   string entry_source=EntryTriggerName(s,is_buy);
   string order_comment=StringFormat("MTF %s %s",(is_buy ? "BUY" : "SELL"),entry_source);
   bool sent=(is_buy ? trade.Buy(entry_lot,_Symbol,0.0,sl,tp,order_comment) :
                       trade.Sell(entry_lot,_Symbol,0.0,sl,tp,order_comment));
   uint code=trade.ResultRetcode();
   if(!sent || (code!=TRADE_RETCODE_DONE && code!=TRADE_RETCODE_DONE_PARTIAL &&
                 code!=TRADE_RETCODE_PLACED))
   {
      PrintFormat("%s failed. retcode=%u %s",(is_buy ? "BUY" : "SELL"),
                  code,trade.ResultRetcodeDescription());
      if(prepared_existing_basket) SynchronizeTakeProfits(currently_in_basket);
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
      PrintFormat("Opened %s [%s] lot=%.5f opposite_recovery=%s same_side_basket=%s, position limit=%s, basket=%s",
                  (is_buy ? "BUY" : "SELL"),entry_source,entry_lot,
                  (UseRecoveryLot ? (g_recovery_active ? "ACTIVE" : "ARMED") : "OFF"),
                  (UseSameSideRecoveryLot ? (g_same_recovery_active ? "ACTIVE" : "ARMED") : "OFF"),
                  (MaxPositionsPerSymbol==0 ? "UNLIMITED" : IntegerToString(MaxPositionsPerSymbol)),
                  (entry_needs_basket ? "ON" : "OFF"));
   UpdateStatusPanel();
}
//+------------------------------------------------------------------+
