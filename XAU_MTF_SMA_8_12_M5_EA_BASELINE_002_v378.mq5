//+------------------------------------------------------------------+
//| XAU_MTF_SMA_8_12_M5_EA_BASELINE_002.mq5                          |
//| M5 SMA(8,12) multi-timeframe entry, basket and recovery management |
//| Responsive status UI: grouped cards, maximum two columns.          |
//+------------------------------------------------------------------+
#property strict
#property version   "3.78"
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
#define MOMENTUM_NO_CROSS_BARS 5
// Fixed quiet history of the confirmed Cross+1Bar entry (previous SET value=10).
#define CONFIRMED_CROSS_QUIET_BARS 10

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
input bool UsePreMarketCloseEntryFilter = true;
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

input group "04.1a | Entry - Optional Trend Quality Gates"
// Require H1 SMA trend to agree with the order, even when H1 voting is OFF.
input bool UseH1TrendAgreement = false;
// M5 Slow SMA must slope toward the order direction from bar [3] to [1].
input bool UseM5SlowSMASlopeEntryFilter = false;
// Older M5 Slow SMA candle index for the slope comparison (default [3]).
input int M5SlopeReferenceShift = 3;
// Minimum M5 Fast/Slow separation, normalized by M5 ATR [1].
input bool UseM5MAStrengthEntryFilter = false;
input double M5MinMASpreadATR = 0.1;
// Shared M5 ATR used by strength and momentum spike filters.
input int EntryQualityATRPeriod = 14;

input group "04.1b | Entry - Spread Gate"
// Skip new entries on abnormally wide spreads; never affects exits.
input bool UseMaxSpreadEntryFilter = false;
input int MaxEntrySpreadPoints = 200;

input group "04.1c | Entry - Optional Volatility Gate"
// Separate GLOBAL volatility gate, for any OR entry including Color and Cross.
// ATR[2] predates signal candle [1] to avoid news candles inflating their limit.
input bool UseEntryCandleATRSpikeFilter = false;
input double EntryMaxCandleRangeATR = 1.8;

input group "04.2 | Entry - Slow SMA Distance Gate"
// Global ENTRY-only distance gate; applies to all enabled OR triggers.
input bool UseSlowSMADistanceEntryFilter = false;
// Distance can be capped by M5 ATR(14) or fixed broker points.
enum ENUM_SLOW_SMA_DISTANCE_MODE
{
   SLOW_SMA_DISTANCE_ATR = 0,
   SLOW_SMA_DISTANCE_POINTS = 1
};
// When enabled: measure price-to-Slow-SMA distance against M5 ATR(14) [1].
input ENUM_SLOW_SMA_DISTANCE_MODE SlowSMADistanceMode = SLOW_SMA_DISTANCE_ATR;
// ATR calculated on closed M5 bar [1].
input int SlowSMAATRPeriod = 14;
// Maximum allowed absolute distance to Slow SMA = ATR * multiplier.
input double SlowSMAMaxDistanceATR = 1.0;
// Alternative maximum when selecting fixed POINTS (price units = points * _Point).
input int SlowSMAMaxDistancePoints = 1500;

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
input bool UseCandleColorEntryFilter = false;

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
input bool UseTwoCandleSMAContinuationEntryFilter = false;
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
// OFF by default, so it does not change existing Entry signals unless enabled.
input bool UseMomentumBreakoutEntryFilter = false;
// 04.5 ONLY: independently switchable CORE entry checks.
// Master OFF disables all Momentum entry checks; new switches default ON
// to retain the exact v3.58 ENTRY behavior when all are enabled.
// BUY green [1], SELL red [1].
input bool UseMomentumSignalColor1Filter = true;
// BUY Close[1]>highest High[2..N+1], SELL Close[1]<lowest Low[2..N+1].
input bool UseMomentumPriceBreakoutFilter = true;
// BUY SMA8[1]>SMA12[1], SELL SMA8[1]<SMA12[1].
input bool UseMomentumSMA8SMA12DirectionFilter = true;
// All three closed candles [1],[2],[3] must have Body/Range >= threshold.
// Candle colors [2] and [3] do not matter.
input bool UseMomentumBodyStrength13Filter = true;
// For Momentum ENTRY, closed M5 [1], [2], and [3] must EACH have
// Body / (High-Low) >= this fraction, regardless of candle direction.
// Older breakout-reference bars [4..N+1] are not body-strength tested.
input double MomentumMinBodyRatio = 0.6;
// Break the prior N completed M5 candle highs/lows (signal bar [1] excluded).
input int MomentumBreakoutLookbackBars = 3;
// Compare breakout candle [1] full range with ATR[2] (before the signal).
input bool UseMomentumATRSpikeFilter = true;
input double MomentumMaxRangeATR = 1.8;
// Optional ENTRY-only Body[1] vs Body[2] ratio cap; OFF preserves baseline.
input bool UseMomentumCandleBodyRatioFilter = true;
// Largest candle body / smallest candle body must not exceed this value.
input double MomentumMaxBodyRatio = 3.0;
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
// ENTRY ONLY: cap how far Close[1] breaks the previous N-bar High/Low.
// BUY:  0 < Close[1] - HighestHigh[2..N+1] <= Body[1] * 0.50.
// SELL: 0 < LowestLow[2..N+1] - Close[1] <= Body[1] * 0.50.
// Optional, no ATR and no multiplier input. Does not affect any exit.
input bool UseMomentumBreakoutExtensionFilter = false;
// ENTRY ONLY: compare CLOSED M5 [1],[2],[3],[4]: max body / min body <= 2.
// Color is irrelevant; reject zero-size bodies. This does NOT change
// the separate minimum-60% candle-body rule on closed M5 [1]..[3].
input bool UseMomentumFourCandleBodyRatioFilter = true;
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
// ENTRY ONLY: the signal candle's open-side edge must be BETWEEN SMA8 and SMA12.
// BUY green [1]: SMA12[1] <= Close[1]-Body[1] <= SMA8[1].
// SELL red [1]: SMA8[1] <= Close[1]+Body[1] <= SMA12[1].
// For directional candles, the tested expression equals Open[1].
// OFF bypasses this condition; never affects exit signals or other Entry ORs.
input bool UseMomentumOpenBodySMABandFilter = false;
// MOMENTUM ENTRY ONLY: no SMA8/12 crossover or touch within five closed M5
// candles [1]..[5]. Read older [6] to detect a cross on candle [5].
// BUY: SMA8>SMA12 throughout [1]..[6]. SELL: SMA8<SMA12 throughout.
// OFF bypasses this added Momentum-only gate; indicator exits are unchanged.
input bool UseMomentumNoRecentCrossFilter = true;
// 04.5 ENTRY ONLY: reject exhausted signal candles [1] far from SMA8.
// BUY blocks ONLY when UpperWick[1] > Body[1] AND Low[1] > SMA8[1].
// SELL blocks ONLY when LowerWick[1] > Body[1] AND High[1] < SMA8[1].
// Both parts must be true; equality passes. Does not affect exits.
input bool UseMomentumSignalWickSMA8BlockFilter = true;
// 04.5 ENTRY ONLY: compare signal Body[1] to the SMA8/SMA12 gap on [1].
// Ratio = abs(Close[1]-Open[1])/abs(SMA8[1]-SMA12[1]).
// BLOCK when ratio > limit. Requires directional positive SMA gap.
input bool UseMomentumBodySMAGapRatioFilter = true;
input double MomentumMaxBodySMAGapRatio = 2.0;
// 04.5 ENTRY ONLY: compare signal Close[1]-to-SMA8[1] to SMA gap.
// BUY: (Close[1]-SMA8[1])/(SMA8[1]-SMA12[1]); SELL mirrored.
// BLOCK when ratio > limit; Close on/behind SMA8 yields ratio <= 0.
// Requires directional positive SMA gap. Independent of Body ratio filter.
input bool UseMomentumCloseSMAGapRatioFilter = true;
input double MomentumMaxCloseSMAGapRatio = 3.0;
// 04.5 ONLY: three optional [1]-vs-[2] SMA-gap / candle-body relationship checks.
// All use fully CLOSED M5 bars. Each is independently switchable.
// A: efficiency = (directional Gap[1]-Gap[2]) / Body[1].
// Reject if below minimum. A shrinking gap yields negative efficiency.
input bool UseMomentumGapExpansionEfficiencyFilter = true;
input double MomentumMinGapExpansionEfficiency = 0.05;
// B: (Body[1]/Body[2]) / (Gap[1]/Gap[2]).
// Reject if above maximum; zero Body[2] is rejected (no division by zero).
input bool UseMomentumBodyGapGrowthMismatchFilter = true;
input double MomentumMaxBodyGapGrowthMismatch = 3.0;
// C: on fully CLOSED [1..3], locate the largest and smallest candle bodies
// (regardless of candle color), then compare EACH body's ratio against
// the SMA8/SMA12 directional gap on THAT SAME candle.
// BLOCK when abs(BodyMax/GapAtMax - BodyMin/GapAtMin) > maximum.
// Retain original input names so existing MT5 .set presets keep working.
input bool UseMomentumBodyGapRatioIncreaseFilter = true;
input double MomentumMaxBodyGapRatioIncrease = 1.5;
// 04.5 ENTRY ONLY: dynamic price boundary based on the latest CONFIRMED M5 pivot.
// Pivot uses 2 older and 2 newer CLOSED candles, excluding signal [1].
// Search nearest confirmed pivot starting at [4] through [50]; no lookahead.
// BUY UpperBand[1] = SMA12[1] + (High[swing] - SMA12[swing]).
// SELL LowerBand[1] = SMA12[1] - (SMA12[swing] - Low[swing]).
// BUY blocks if Close[1]>=UpperBand; SELL blocks if Close[1]<=LowerBand.
// No ATR, k, extra distance multiplier, or change to other Entry ORs.
// If no valid confirmed pivot exists, entry fails conservatively.
input bool UseMomentumDynamicSwingSMA12BandFilter = true;
// 04.5 ENTRY ONLY: one switch for BOTH directions against the latest
// confirmed M5 pivot (2 older + 2 newer fully closed candles [4..50]).
// BUY: Close[1] > latest confirmed Swing High.
// SELL: Close[1] < latest confirmed Swing Low.
// Missing confirmed pivot blocks the relevant entry. No use of [0]/[1]
// in pivot confirmation; does not affect other ORs or exits.
input bool UseMomentumSwingStructureBreakFilter = true;
// 04.5 ENTRY ONLY: both adjacent M5 opening price gaps must be <= limit.
// Gap [2]->[1] = abs(Open[1] - Close[2]) / _Point.
// Gap [1]->[0] = abs(Open[0] - Close[1]) / _Point.
// [0] is used ONLY for its already-known OPEN price, not Close/High/Low.
// Applies equally to BUY/SELL; equality at the cap passes.
input bool UseMomentumOpeningGaps02Filter = true;
input int MomentumMaxOpeningGap02Points = 200;
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
// 04.5 ENTRY ONLY: block a renewed SMA8/SMA12 gap-expansion surge
// after a temporary slowdown (closed M5 [1..4], entry direction).
// d1=Gap[1]-Gap[2], d2=Gap[2]-Gap[3], d3=Gap[3]-Gap[4].
// BLOCK if d1>d3>d2>0: expansion fell and then rebounded beyond the
// rate seen before the slowdown. Gradual expansion and deceleration pass.
// No fixed points, multiplier, or ratio threshold; BUY and SELL mirrored.
input bool UseMomentumGapReaccelerationBlockFilter = true;
// A/B/C each include an unconditional direction-matching cross exception:
// a SMA8/12 cross on a fully closed M5 candle [1], [2], or [3] exempts
// ONLY these three [1]-vs-[2] relationship checks. No extra input switch.
// Closed [4] is read to detect a cross on [3].
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
input bool UseSMAPullbackRejectionEntryFilter = false;
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

input group "04.7 | Entry - OR SMA Cross + 1-Bar Confirmation"
// Confirmed SMA Cross is the only SMA Cross ENTRY; indicator exits remain independent.
// Cross occurs on CLOSED M5 [2], comparing SMA[3] -> SMA[2].
// Default subfilters: [2] directional color/body-wicks, [1] direction,
// directional color/body-wicks and breakout beyond [2]. All can be toggled.
// Quiet-history lookback is fixed at 10 when its switch is ON.
// The obsolete shared 04.4 input has been removed.
input bool UseSMACrossConfirmedEntryFilter = false;
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
// Default ON for the integrated Cross+1Bar Range setup; turn OFF before choosing Open+Body.
input bool UseSMACrossConfirmedRangeDistanceFilter = true;
// Alternative ENTRY-only filter (original v3.03 Open+Body rule):
// BUY: Open[1]-Body[1] >= SMA12[1].
// SELL: Open[1]+Body[1] <= SMA12[1].
// Body[1] = abs(Close[1]-Open[1]); no ATR or multiplier.
// For isolated backtests, do not enable both filter modes together.
input bool UseSMACrossConfirmedOpenBodySMAFilter = false;
// Entry = optional MTF/QUALITY/SPREAD/SLOW-SMA gates AND
//         (PULLBACK OR MOMENTUM OR SMA PULLBACK REJECTION OR CROSS CONFIRM).

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
// Shared ATR handle for M5 MA strength and Momentum spike caps.
int g_entry_quality_atr_handle = INVALID_HANDLE;
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

// Function: PassEntryTrendQualityFilters - Optional direction-sensitive trend gates.
// MTF voting is unchanged; all checks apply only to opening new positions.
bool PassEntryTrendQualityFilters(const bool want_buy)
{
   if(UseH1TrendAgreement)
   {
      double hf=0.0,hs=0.0;
      if(!TryReadMA(g_fast_ma_handles[3],SIGNAL_SHIFT,hf) ||
         !TryReadMA(g_slow_ma_handles[3],SIGNAL_SHIFT,hs))
         return false;
      if(want_buy ? (hf<=hs) : (hf>=hs))
         return false;
   }
   if(UseM5SlowSMASlopeEntryFilter || UseM5MAStrengthEntryFilter)
   {
      double fast=0.0,slow=0.0;
      if(!TryReadMA(g_fast_ma_handles[0],SIGNAL_SHIFT,fast) ||
         !TryReadMA(g_slow_ma_handles[0],SIGNAL_SHIFT,slow))
         return false;
      // A quality-confirmed M5 trend must point in the same direction.
      if(want_buy ? (fast<=slow) : (fast>=slow))
         return false;
      if(UseM5SlowSMASlopeEntryFilter)
      {
         double old_slow=0.0;
         if(!TryReadMA(g_slow_ma_handles[0],M5SlopeReferenceShift,old_slow))
            return false;
         if(want_buy ? (slow<=old_slow) : (slow>=old_slow))
            return false;
      }
      if(UseM5MAStrengthEntryFilter)
      {
         double atr=0.0;
         if(!ReadEntryQualityATR(SIGNAL_SHIFT,atr)) return false;
         if(MathAbs(fast-slow)/atr < M5MinMASpreadATR) return false;
      }
   }
   return true;
}

// Function: PassEntrySpreadFilter - Reject a new order on excessive bid/ask spread.
bool PassEntrySpreadFilter()
{
   if(!UseMaxSpreadEntryFilter) return true;
   MqlTick tick;
   if(_Point<=0.0 || !SymbolInfoTick(_Symbol,tick) ||
      tick.ask<=0.0 || tick.bid<=0.0 || tick.ask<tick.bid)
      return false;
   double spread_points=(tick.ask-tick.bid)/_Point;
   return (spread_points<=(double)MaxEntrySpreadPoints+1e-6);
}

// Function: PassEntryCandleSpikeFilter - Optional GLOBAL extreme-candle cap.
// This guard differs from the Momentum-only spike filter and blocks every OR.
bool PassEntryCandleSpikeFilter()
{
   if(!UseEntryCandleATRSpikeFilter) return true;
   MqlRates signal[1];
   if(CopyRates(_Symbol,PERIOD_M5,SIGNAL_SHIFT,1,signal)!=1)
      return false;
   double atr=0.0;
   if(!ReadEntryQualityATR(2,atr)) return false;
   double range=signal[0].high-signal[0].low;
   if(!MathIsValidNumber(range) || range<=0.0) return false;
   return (range<=EntryMaxCandleRangeATR*atr);
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
   return (EvaluatePullbackPattern(want_buy)==3);
}

// Independent ENTRY 04.4: SMA12 slope + two same-color breakout candles.
// Additional previous swing check: Close[1] strictly breaks [3]..[8].
// SMA12 slope uses fully CLOSED M5 bars [1] through [5].
// This entry does not modify other OR setups or indicator-driven exits.
bool PassTwoCandleSMAContinuationEntryFilter(const bool want_buy)
{
   // Master switch always overrides all 04.4 subfilters.
   if(!UseTwoCandleSMAContinuationEntryFilter)
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
      if(_Point<=0.0)
         return false;
      const double gap_points=MathAbs(signal.open-prior.close)/_Point;
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
//         7=Open+Body-to-SMA12 block,
//         8=confirmation [1] body vs upper/lower wick block,
//         9=three-closed-bar SMA12 slope block,
//         10=[2] candle color block, 11=[1] candle color block,
//         12=five-closed-bar SMA8 slope block.
// The two optional position filters are mutually exclusive.
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

   // Alternative filter: exact v3.03 Open +/- Body rule, kept independently.
   // The confirmation candle [1] has already passed its direction/wick checks.
   if(UseSMACrossConfirmedOpenBodySMAFilter)
   {
      const double body1=MathAbs(confirm_bar.close-confirm_bar.open);
      const double level=(want_buy ?
         confirm_bar.open-body1 : confirm_bar.open+body1);
      if(!MathIsValidNumber(body1) || !MathIsValidNumber(level) ||
         !MathIsValidNumber(s1) || body1<=0.0 ||
         (want_buy ? level<s1 : level>s1))
         return 7;
   }

   return 5;
}

bool PassEntrySMACrossConfirmedFilter(const bool want_buy)
{
   return (EvaluateSMACrossOneBarConfirmation(want_buy)==5);
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

   // ENTRY ONLY: test BOTH closed [3] and [2]. [1] is checked below.
   // Keep this separate from breakout lookback: even when lookback=1,
   // the body rule still checks exactly [1], [2], and [3].
   // Physical CopyRates order is oldest -> newest: prior[0]=[3], prior[1]=[2].
   // Existing exit signals skip this historical body rule.
   if(check_entry_window && UseMomentumBodyStrength13Filter)
   {
      MqlRates prior[2];
      if(CopyRates(_Symbol,PERIOD_M5,2,2,prior)!=2)
         return false;
      for(int i=0;i<2;i++)
      {
         const double range_i=prior[i].high-prior[i].low;
         const double body_i=MathAbs(prior[i].close-prior[i].open);
         if(!MathIsValidNumber(range_i) || !MathIsValidNumber(body_i) ||
            !MathIsValidNumber(prior[i].high) || !MathIsValidNumber(prior[i].low) ||
            !MathIsValidNumber(prior[i].open) || !MathIsValidNumber(prior[i].close) ||
            range_i<=0.0 || prior[i].high<MathMax(prior[i].open,prior[i].close) ||
            prior[i].low>MathMin(prior[i].open,prior[i].close))
            return false;
         if(body_i/range_i+1e-12<MomentumMinBodyRatio)
            return true; // A weak [2] or [3] blocks only a NEW Momentum entry.
      }
   }

   // The [1] signal strength remains mandatory for BOTH entries and exits.
   MqlRates signal=rates[count-1];
   const double range=signal.high-signal.low;
   const double body=MathAbs(signal.close-signal.open);
   if(!MathIsValidNumber(range) || !MathIsValidNumber(body) || range<=0.0)
      return false;
   // Keep the original candle-strength rule for legacy indicator EXIT calls.
   // Core switches are entry-only and never change opposite-signal exits.
   if((!check_entry_window || UseMomentumBodyStrength13Filter) &&
      body/range+1e-12<MomentumMinBodyRatio)
      return true;

   double highest=rates[0].high;
   double lowest=rates[0].low;
   for(int i=1;i<count-1;i++)
   {
      highest=MathMax(highest,rates[i].high);
      lowest=MathMin(lowest,rates[i].low);
   }

   if(UseMomentumATRSpikeFilter)
   {
      double previous_atr=0.0;
      if(!ReadEntryQualityATR(2,previous_atr)) return false;
      // A very large breakout candle may be a news spike: reject it.
      if(range>MomentumMaxRangeATR*previous_atr)
         return true;
   }

   double fast=0.0,slow=0.0;
   if(!check_entry_window || UseMomentumSMA8SMA12DirectionFilter)
      if(!TryReadMA(g_fast_ma_handles[0],SIGNAL_SHIFT,fast) ||
         !TryReadMA(g_slow_ma_handles[0],SIGNAL_SHIFT,slow))
         return false;

   // For exit calls (check_entry_window=false), keep ALL original core rules.
   // For entries, OFF switches bypass only their corresponding rule.
   const bool check_color=(!check_entry_window || UseMomentumSignalColor1Filter);
   const bool check_breakout=(!check_entry_window || UseMomentumPriceBreakoutFilter);
   const bool check_sma=(!check_entry_window || UseMomentumSMA8SMA12DirectionFilter);
   buy_breakout=(!check_color || signal.close>signal.open) &&
                (!check_breakout || signal.close>highest) &&
                (!check_sma || fast>slow);
   sell_breakout=(!check_color || signal.close<signal.open) &&
                 (!check_breakout || signal.close<lowest) &&
                 (!check_sma || fast<slow);
   return true;
}

// Optional MOMENTUM ENTRY-only strength balance: signal M5 [1] vs prior M5 [2].
// CopyRates stores oldest -> newest: bars[0]=[2], bars[1]=[1].
// Zero-sized bodies are rejected when the filter is ON (no division by zero).
bool PassMomentumCandleBodyRatioFilter()
{
   if(!UseMomentumCandleBodyRatioFilter)
      return true;

   MqlRates bars[2];
   if(CopyRates(_Symbol,PERIOD_M5,SIGNAL_SHIFT,2,bars)!=2)
      return false;

   double body1=MathAbs(bars[1].close-bars[1].open);
   double body2=MathAbs(bars[0].close-bars[0].open);
   if(!MathIsValidNumber(body1) || !MathIsValidNumber(body2) ||
      body1<=0.0 || body2<=0.0)
      return false;

   double ratio=MathMax(body1,body2)/MathMin(body1,body2);
   return (MathIsValidNumber(ratio) && ratio<=MomentumMaxBodyRatio+1e-10);
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

// MOMENTUM ENTRY ONLY: avoid chasing an excessively extended breakout.
// Re-read fully CLOSED bar [1] and High/Low of the preceding N M5 bars.
// This must not be used for exit signal evaluation.
bool PassMomentumBreakoutExtensionFilter(const bool want_buy)
{
   if(!UseMomentumBreakoutExtensionFilter)
      return true;

   const int count=MomentumBreakoutLookbackBars+1;
   if(count<2 || count>OHLCV_HISTORY)
      return false;

   MqlRates bars[];
   if(ArrayResize(bars,count)!=count ||
      CopyRates(_Symbol,PERIOD_M5,SIGNAL_SHIFT,count,bars)!=count)
      return false;

   // CopyRates physical layout: oldest [N+1] -> latest signal [1].
   const MqlRates signal=bars[count-1];
   const double body1=MathAbs(signal.close-signal.open);
   if(!MathIsValidNumber(body1) || body1<=0.0 ||
      !MathIsValidNumber(signal.close))
      return false;

   double highest=bars[0].high;
   double lowest=bars[0].low;
   for(int i=1;i<count-1;i++)
   {
      if(!MathIsValidNumber(bars[i].high) || !MathIsValidNumber(bars[i].low))
         return false;
      highest=MathMax(highest,bars[i].high);
      lowest=MathMin(lowest,bars[i].low);
   }
   if(!MathIsValidNumber(highest) || !MathIsValidNumber(lowest) || highest<lowest)
      return false;

   const double extension=(want_buy ? signal.close-highest : lowest-signal.close);
   // Require a true breakout and not more than HALF the signal body's size.
   return (MathIsValidNumber(extension) && extension>0.0 &&
           extension<=body1*0.50+_Point*1e-8);
}

// MOMENTUM ENTRY ONLY: max/min absolute body of fully CLOSED [1]..[4].
// Candle direction is irrelevant; reject Doji and missing data.
bool PassMomentumFourCandleBodyRatioFilter()
{
   if(!UseMomentumFourCandleBodyRatioFilter)
      return true;

   MqlRates bars[4];
   // Static CopyRates: bars[0]=[4], [1]=[3], [2]=[2], [3]=[1].
   if(CopyRates(_Symbol,PERIOD_M5,SIGNAL_SHIFT,4,bars)!=4)
      return false;

   double smallest=DBL_MAX;
   double largest=0.0;
   for(int i=0;i<4;i++)
   {
      const double body=MathAbs(bars[i].close-bars[i].open);
      if(!MathIsValidNumber(body) || body<=0.0)
         return false;
      smallest=MathMin(smallest,body);
      largest=MathMax(largest,body);
   }

   const double ratio=largest/smallest;
   return (MathIsValidNumber(ratio) && ratio<=2.0+1e-10);
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

// MOMENTUM ENTRY ONLY: directional [1] candle begins within the SMA8/12 band.
// SELL: SMA8 <= Close+Body <= SMA12; BUY: SMA12 <= Close-Body <= SMA8.
// This reads SMA values and OHLC on the same fully closed M5 bar [1].
bool PassMomentumOpenBodySMABandFilter(const bool want_buy)
{
   if(!UseMomentumOpenBodySMABandFilter)
      return true;

   MqlRates signal[1];
   if(CopyRates(_Symbol,PERIOD_M5,SIGNAL_SHIFT,1,signal)!=1)
      return false;

   const double open1=signal[0].open;
   const double close1=signal[0].close;
   const double body1=MathAbs(close1-open1);
   if(!MathIsValidNumber(open1) || !MathIsValidNumber(close1) ||
      !MathIsValidNumber(body1) || body1<=0.0 ||
      (want_buy ? close1<=open1 : close1>=open1))
      return false;

   double fast1=0.0,slow1=0.0;
   if(!TryReadMA(g_fast_ma_handles[0],SIGNAL_SHIFT,fast1) ||
      !TryReadMA(g_slow_ma_handles[0],SIGNAL_SHIFT,slow1))
      return false;
   if(!MathIsValidNumber(fast1) || !MathIsValidNumber(slow1) ||
      (want_buy ? fast1<=slow1 : fast1>=slow1))
      return false;

   const double tested_value=(want_buy ? close1-body1 : close1+body1);
   const double band_low=(want_buy ? slow1 : fast1);
   const double band_high=(want_buy ? fast1 : slow1);
   const double tolerance=_Point*1e-7;
   return (tested_value>=band_low-tolerance &&
           tested_value<=band_high+tolerance);
}

// MOMENTUM ENTRY ONLY: require the M5 SMA8/12 relationship to be stable
// through all five recently completed candles [1]..[5]. Also read [6] so
// that a cross on [5] cannot slip through undetected. Equality/touch blocks.
// BUY: Fast > Slow throughout the window; SELL: Fast < Slow throughout.
// This is independent of confirmed-cross ENTRY and never changes EXIT logic.
bool PassMomentumNoRecentCrossFilter(const bool want_buy)
{
   if(!UseMomentumNoRecentCrossFilter)
      return true;

   for(int shift=1;shift<=MOMENTUM_NO_CROSS_BARS+1;shift++)
   {
      double fast=0.0,slow=0.0;
      if(!TryReadMA(g_fast_ma_handles[0],shift,fast) ||
         !TryReadMA(g_slow_ma_handles[0],shift,slow))
         return false;
      if(want_buy ? (fast<=slow) : (fast>=slow))
         return false;
   }
   return true;
}

// 04.5 ENTRY ONLY: directional rejection wick while the WHOLE signal bar
// is beyond SMA8; block only if both tests match on closed M5 [1].
bool PassMomentumSignalWickSMA8BlockFilter(const bool want_buy)
{
   if(!UseMomentumSignalWickSMA8BlockFilter)
      return true;

   MqlRates bars[1];
   if(CopyRates(_Symbol,PERIOD_M5,1,1,bars)!=1)
      return false;
   const MqlRates signal=bars[0];
   if(!MathIsValidNumber(signal.open) || !MathIsValidNumber(signal.close) ||
      !MathIsValidNumber(signal.high) || !MathIsValidNumber(signal.low) ||
      signal.high<signal.low ||
      signal.high<MathMax(signal.open,signal.close) ||
      signal.low>MathMin(signal.open,signal.close))
      return false;

   double fast1=0.0;
   if(!TryReadMA(g_fast_ma_handles[0],1,fast1))
      return false;
   const double body=MathAbs(signal.close-signal.open);
   const double wick=(want_buy ?
      signal.high-MathMax(signal.open,signal.close) :
      MathMin(signal.open,signal.close)-signal.low);
   if(!MathIsValidNumber(body) || !MathIsValidNumber(wick) || wick<0.0)
      return false;

   const bool reject=(want_buy ?
      (wick>body && signal.low>fast1) :
      (wick>body && signal.high<fast1));
   return !reject;
}

// 04.5 ENTRY ONLY: two independently switchable anti-extension tests.
// Both use fully CLOSED M5 [1] and its own SMA8/SMA12 values.
// If either is enabled, require nonzero SMA separation in trade direction;
// reject invalid/flat/opposing gaps to avoid misleading ratios.
bool PassMomentumSMAGapRatioFilters(const bool want_buy)
{
   if(!UseMomentumBodySMAGapRatioFilter && !UseMomentumCloseSMAGapRatioFilter)
      return true;

   MqlRates candle[1];
   if(CopyRates(_Symbol,PERIOD_M5,1,1,candle)!=1)
      return false;
   const double open1=candle[0].open;
   const double close1=candle[0].close;
   if(!MathIsValidNumber(open1) || !MathIsValidNumber(close1))
      return false;

   double f1=0.0,s1=0.0;
   if(!TryReadMA(g_fast_ma_handles[0],1,f1) ||
      !TryReadMA(g_slow_ma_handles[0],1,s1))
      return false;
   const double gap=(want_buy ? f1-s1 : s1-f1);
   if(!MathIsValidNumber(gap) || gap<=0.0)
      return false;

   if(UseMomentumBodySMAGapRatioFilter)
   {
      const double body_ratio=MathAbs(close1-open1)/gap;
      if(!MathIsValidNumber(body_ratio) ||
         body_ratio>MomentumMaxBodySMAGapRatio+1e-10)
         return false;
   }
   if(UseMomentumCloseSMAGapRatioFilter)
   {
      const double close_distance=(want_buy ? close1-f1 : f1-close1);
      const double close_ratio=close_distance/gap;
      if(!MathIsValidNumber(close_ratio) ||
         close_ratio>MomentumMaxCloseSMAGapRatio+1e-10)
         return false;
   }
   return true;
}

// 04.5 ONLY: detect a same-direction SMA8/12 cross on [1]..[3]
// (fully closed M5 bars). Result: -1=data unavailable, 0=no cross, 1=cross.
// Used internally by A/B/C; there is intentionally no bypass input.
int MomentumRecentDirectionalCrossState(const bool want_buy)
{
   for(int shift=1;shift<=3;shift++)
   {
      double fn=0.0,sn=0.0,fo=0.0,so=0.0;
      if(!TryReadMA(g_fast_ma_handles[0],shift,fn) ||
         !TryReadMA(g_slow_ma_handles[0],shift,sn) ||
         !TryReadMA(g_fast_ma_handles[0],shift+1,fo) ||
         !TryReadMA(g_slow_ma_handles[0],shift+1,so))
         return -1;
      if(want_buy ? (fo<=so && fn>sn) : (fo>=so && fn<sn))
         return 1;
   }
   return 0;
}

// 04.5 ONLY: optional directional SMA8/12 gap vs candle-body checks.
// A/B use CLOSED [1],[2]; C finds largest/smallest Body in CLOSED [1..3].
// The cross exception is internal to A/B/C and only runs when one is ON.
bool PassMomentumGapRelationshipFilters(const bool want_buy)
{
   const bool any_filter=(UseMomentumGapExpansionEfficiencyFilter ||
                          UseMomentumBodyGapGrowthMismatchFilter ||
                          UseMomentumBodyGapRatioIncreaseFilter);
   if(!any_filter)
      return true;

   // Built into A/B/C: a same-direction cross in closed [1..3] means
   // the SMA gap may naturally lag the signal candle. Skip A/B/C only.
   const int cross_state=MomentumRecentDirectionalCrossState(want_buy);
   if(cross_state<0) return false; // fail closed on missing history
   if(cross_state==1) return true;

   MqlRates bars[2]; // physical order: [2], then [1]
   if(CopyRates(_Symbol,PERIOD_M5,1,2,bars)!=2)
      return false;
   const double body1=MathAbs(bars[1].close-bars[1].open);
   const double body2=MathAbs(bars[0].close-bars[0].open);
   if(!MathIsValidNumber(body1) || !MathIsValidNumber(body2) ||
      body1<=0.0 ||
      (UseMomentumBodyGapGrowthMismatchFilter && body2<=0.0))
      return false;

   double f1=0.0,s1=0.0,f2=0.0,s2=0.0;
   if(!TryReadMA(g_fast_ma_handles[0],1,f1) ||
      !TryReadMA(g_slow_ma_handles[0],1,s1) ||
      !TryReadMA(g_fast_ma_handles[0],2,f2) ||
      !TryReadMA(g_slow_ma_handles[0],2,s2))
      return false;
   const double gap1=(want_buy ? f1-s1 : s1-f1);
   const double gap2=(want_buy ? f2-s2 : s2-f2);
   if(!MathIsValidNumber(gap1) || !MathIsValidNumber(gap2) ||
      gap1<=0.0 || gap2<=0.0)
      return false;

   if(UseMomentumGapExpansionEfficiencyFilter)
   {
      const double efficiency=(gap1-gap2)/body1;
      if(!MathIsValidNumber(efficiency) ||
         efficiency+1e-12<MomentumMinGapExpansionEfficiency)
         return false;
   }
   if(UseMomentumBodyGapGrowthMismatchFilter)
   {
      const double mismatch=(body1/body2)/(gap1/gap2);
      if(!MathIsValidNumber(mismatch) ||
         mismatch>MomentumMaxBodyGapGrowthMismatch+1e-10)
         return false;
   }
   if(UseMomentumBodyGapRatioIncreaseFilter)
   {
      MqlRates recent[3]; // oldest -> newest: [3], [2], [1]
      if(CopyRates(_Symbol,PERIOD_M5,1,3,recent)!=3)
         return false;

      double max_body=-1.0,min_body=DBL_MAX;
      int max_shift=-1,min_shift=-1;
      for(int i=0;i<3;i++)
      {
         const double body=MathAbs(recent[i].close-recent[i].open);
         if(!MathIsValidNumber(body) || body<=0.0)
            return false;
         if(body>max_body)
         {
            max_body=body;
            max_shift=3-i;
         }
         if(body<min_body)
         {
            min_body=body;
            min_shift=3-i;
         }
      }

      // Match each extreme body to the SMA gap of its OWN candle,
      // rather than mismatching price and MA from different shifts.
      double max_fast=0.0,max_slow=0.0,min_fast=0.0,min_slow=0.0;
      if(!TryReadMA(g_fast_ma_handles[0],max_shift,max_fast) ||
         !TryReadMA(g_slow_ma_handles[0],max_shift,max_slow) ||
         !TryReadMA(g_fast_ma_handles[0],min_shift,min_fast) ||
         !TryReadMA(g_slow_ma_handles[0],min_shift,min_slow))
         return false;
      const double max_gap=(want_buy ? max_fast-max_slow : max_slow-max_fast);
      const double min_gap=(want_buy ? min_fast-min_slow : min_slow-min_fast);
      if(!MathIsValidNumber(max_gap) || !MathIsValidNumber(min_gap) ||
         max_gap<=0.0 || min_gap<=0.0)
         return false;

      const double max_ratio=max_body/max_gap;
      const double min_ratio=min_body/min_gap;
      const double ratio_change=max_ratio-min_ratio;
      // Compare BOTH directions of change, just as the previous [1-2] test did.
      if(!MathIsValidNumber(ratio_change) ||
         MathAbs(ratio_change)>MomentumMaxBodyGapRatioIncrease+1e-10)
      {
         if(PrintSignalLog)
            PrintFormat("MOMENTUM %s BODY/GAP [1..3] EXTREMES BLOCK: max Body[%d]=%.4f Gap=%.4f Ratio=%.4f; min Body[%d]=%.4f Gap=%.4f Ratio=%.4f; abs difference=%.4f max allowed=%.4f",
                        (want_buy ? "BUY" : "SELL"),max_shift,max_body,max_gap,max_ratio,
                        min_shift,min_body,min_gap,min_ratio,MathAbs(ratio_change),
                        MomentumMaxBodyGapRatioIncrease);
         return false;
      }
   }
   return true;
}

// 04.5 ENTRY ONLY: a sudden re-acceleration in the trend-side SMA gap
// after a slowdown can be an exhaustion move. Uses four fully CLOSED bars.
// The filter deliberately has no adjustable threshold.
bool PassMomentumGapReaccelerationBlockFilter(const bool want_buy)
{
   if(!UseMomentumGapReaccelerationBlockFilter)
      return true;

   double gap[4]; // index 0=[1], 1=[2], 2=[3], 3=[4]
   for(int shift=1;shift<=4;shift++)
   {
      double fast=0.0,slow=0.0;
      if(!TryReadMA(g_fast_ma_handles[0],shift,fast) ||
         !TryReadMA(g_slow_ma_handles[0],shift,slow))
         return false;
      gap[shift-1]=(want_buy ? fast-slow : slow-fast);
      if(!MathIsValidNumber(gap[shift-1]) || gap[shift-1]<=0.0)
         return false;
   }

   const double d1=gap[0]-gap[1];
   const double d2=gap[1]-gap[2];
   const double d3=gap[2]-gap[3];
   const bool rebound=(d1>d3 && d3>d2 && d2>0.0);
   if(PrintSignalLog && rebound)
      PrintFormat("MOMENTUM %s SMA GAP REACCELERATION BLOCK: d3=%.4f d2=%.4f d1=%.4f (d1>d3>d2>0)",
                  (want_buy ? "BUY" : "SELL"),d3,d2,d1);
   return !rebound;
}

// 04.5 ENTRY ONLY: latest confirmed 2-left/2-right pivot, excluding [1].
// In MQL5 shift decreases toward the present. Start [4] so the two
// confirming newer candles are [3],[2], not the signal candle [1].
// Returns false if there is no confirmed pivot in [4..50] or data is missing.
bool FindMomentumLatestConfirmedSwing(const bool want_buy,
                                      int &swing_shift,double &swing_price)
{
   swing_shift=-1;
   swing_price=0.0;
   const int first_shift=4;
   const int last_shift=50;
   // Need older shifts s+1,s+2 for the oldest pivot candidate.
   if(Bars(_Symbol,PERIOD_M5)<last_shift+3)
      return false;

   for(int shift=first_shift;shift<=last_shift;shift++)
   {
      double pivot=(want_buy ? iHigh(_Symbol,PERIOD_M5,shift) :
                               iLow(_Symbol,PERIOD_M5,shift));
      if(!MathIsValidNumber(pivot) || pivot<=0.0)
         return false;

      bool confirmed=true;
      for(int j=1;j<=2;j++)
      {
         const double older=(want_buy ? iHigh(_Symbol,PERIOD_M5,shift+j) :
                                        iLow(_Symbol,PERIOD_M5,shift+j));
         const double newer=(want_buy ? iHigh(_Symbol,PERIOD_M5,shift-j) :
                                        iLow(_Symbol,PERIOD_M5,shift-j));
         if(!MathIsValidNumber(older) || !MathIsValidNumber(newer) ||
            older<=0.0 || newer<=0.0)
            return false;
         // Strict extrema; equal highs/lows are not a confirmed pivot.
         if(want_buy ? (pivot<=older || pivot<=newer) :
                       (pivot>=older || pivot>=newer))
         {
            confirmed=false;
            break;
         }
      }
      if(confirmed)
      {
         swing_shift=shift;
         swing_price=pivot;
         return true;
      }
   }
   return false;
}

// No multiplier: carry the swing-to-SMA12 vertical distance forward to [1].
// Only blocks Momentum entries, not its opposite-signal exit path.
bool PassMomentumDynamicSwingSMA12BandFilter(const bool want_buy)
{
   if(!UseMomentumDynamicSwingSMA12BandFilter)
      return true;

   int swing_shift=-1;
   double swing_price=0.0;
   if(!FindMomentumLatestConfirmedSwing(want_buy,swing_shift,swing_price))
      return false;

   double slow1=0.0,slow_at_swing=0.0;
   if(!TryReadMA(g_slow_ma_handles[0],1,slow1) ||
      !TryReadMA(g_slow_ma_handles[0],swing_shift,slow_at_swing))
      return false;
   const double swing_gap=(want_buy ? swing_price-slow_at_swing :
                                     slow_at_swing-swing_price);
   if(!MathIsValidNumber(swing_gap) || swing_gap<=0.0)
      return false;

   MqlRates closed_signal[1];
   if(CopyRates(_Symbol,PERIOD_M5,1,1,closed_signal)!=1 ||
      !MathIsValidNumber(closed_signal[0].close) ||
      closed_signal[0].close<=0.0)
      return false;
   const double band=(want_buy ? slow1+swing_gap : slow1-swing_gap);
   if(!MathIsValidNumber(band)) return false;
   const bool pass=(want_buy ? closed_signal[0].close<band :
                                closed_signal[0].close>band);
   if(PrintSignalLog && !pass)
      PrintFormat("MOMENTUM DYNAMIC SWING/SMA12 BAND BLOCK %s: swing[%d]=%.*f SMA12[swing]=%.*f gap=%.*f SMA12[1]=%.*f band=%.*f Close[1]=%.*f",
                  (want_buy ? "BUY" : "SELL"),swing_shift,_Digits,swing_price,
                  _Digits,slow_at_swing,_Digits,swing_gap,_Digits,slow1,
                  _Digits,band,_Digits,closed_signal[0].close);
   return pass;
}

// 04.5 ENTRY ONLY: one switch requires BUY above confirmed Swing High
// or SELL below confirmed Swing Low. Pivot excludes signal [1] and live [0].
bool PassMomentumSwingStructureBreakFilter(const bool want_buy)
{
   if(!UseMomentumSwingStructureBreakFilter)
      return true;

   int swing_shift=-1;
   double swing_price=0.0;
   if(!FindMomentumLatestConfirmedSwing(want_buy,swing_shift,swing_price))
   {
      if(PrintSignalLog)
         PrintFormat("MOMENTUM %s SWING %s BREAK BLOCK: no confirmed pivot in [4..50].",
                     (want_buy ? "BUY" : "SELL"),(want_buy ? "HIGH" : "LOW"));
      return false;
   }

   const double close1=iClose(_Symbol,PERIOD_M5,1);
   if(!MathIsValidNumber(close1) || close1<=0.0)
      return false;

   const bool pass=(want_buy ? close1>swing_price : close1<swing_price);
   if(PrintSignalLog && !pass)
      PrintFormat("MOMENTUM %s SWING %s BREAK BLOCK: Close[1]=%.*f %s Swing%s[%d]=%.*f",
                  (want_buy ? "BUY" : "SELL"),(want_buy ? "HIGH" : "LOW"),
                  _Digits,close1,(want_buy ? "<=" : ">="),
                  (want_buy ? "High" : "Low"),swing_shift,_Digits,swing_price);
   return pass;
}

// 04.5 ENTRY ONLY: reject either of the two adjacent opening gaps [2]->[1]
// and [1]->[0] exceeding a common broker-point maximum.
// Read only Open[0] from the forming M5 bar. All prior bars are closed.
bool PassMomentumOpeningGaps02Filter()
{
   if(!UseMomentumOpeningGaps02Filter)
      return true;
   if(_Point<=0.0)
      return false;

   const double close2=iClose(_Symbol,PERIOD_M5,2);
   const double open1=iOpen(_Symbol,PERIOD_M5,1);
   const double close1=iClose(_Symbol,PERIOD_M5,1);
   const double open0=iOpen(_Symbol,PERIOD_M5,0);
   if(!MathIsValidNumber(close2) || !MathIsValidNumber(open1) ||
      !MathIsValidNumber(close1) || !MathIsValidNumber(open0) ||
      close2<=0.0 || open1<=0.0 || close1<=0.0 || open0<=0.0)
      return false;

   const double gap21=MathAbs(open1-close2)/_Point;
   const double gap10=MathAbs(open0-close1)/_Point;
   if(!MathIsValidNumber(gap21) || !MathIsValidNumber(gap10))
      return false;
   const bool pass=(gap21<=(double)MomentumMaxOpeningGap02Points+1e-6 &&
                    gap10<=(double)MomentumMaxOpeningGap02Points+1e-6);
   if(PrintSignalLog && !pass)
      PrintFormat("MOMENTUM OPEN GAP [0..2] BLOCK: Close[2]->Open[1]=%.1f pts Close[1]->Open[0]=%.1f pts max=%d pts",
                  gap21,gap10,MomentumMaxOpeningGap02Points);
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
   if(!PassMomentumCandleBodyRatioFilter())
      return false;
   if(!PassMomentumSlopeEntryFilter(want_buy))
      return false;
   if(!PassMomentumSMA8Slope13Filter(want_buy))
      return false;
   if(!PassMomentumBreakoutExtensionFilter(want_buy))
      return false;
   if(!PassMomentumFourCandleBodyRatioFilter())
      return false;
   if(!PassMomentumOppositeBody25Filter(want_buy))
      return false;
   if(!PassMomentumOppositeColorBreakout12Filter(want_buy))
      return false;
   if(!PassMomentumOpenBodySMABandFilter(want_buy))
      return false;
   if(!PassMomentumNoRecentCrossFilter(want_buy))
      return false;
   if(!PassMomentumSignalWickSMA8BlockFilter(want_buy))
      return false;
   if(!PassMomentumSMAGapRatioFilters(want_buy))
      return false;
   if(!PassMomentumGapRelationshipFilters(want_buy))
      return false;
   if(!PassMomentumGapReaccelerationBlockFilter(want_buy))
      return false;
   if(!PassMomentumDynamicSwingSMA12BandFilter(want_buy))
      return false;
   if(!PassMomentumSwingStructureBreakFilter(want_buy))
      return false;
   if(!PassMomentumOpeningGaps02Filter())
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
      if(_Point<=0.0) return -1;
      const double gap23_points=MathAbs(pullback.open-third[0].close)/_Point;
      if(!MathIsValidNumber(gap23_points)) return -1;
      if(gap23_points>(double)SMAPullbackMaxOpenGap23Points+1e-6) return 11;
   }

   // Check closed [2] Close against the already closed [1] Open.
   // Absolute gap blocks both upward and downward discontinuities equally.
   if(UseSMAPullbackOpenGapFilter)
   {
      if(_Point<=0.0) return -1;
      const double open_gap_points=MathAbs(signal.open-pullback.close)/_Point;
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

// NEW ENTRY FORMULA:
// (optional MTF) AND (optional slow SMA distance) AND (optional quality)
// AND (optional spread) AND (PULLBACK OR CROSS OR MOMENTUM OR SMA PULLBACK OR CROSS CONFIRM).
// SMA Pullback and confirmed Cross are ENTRY ONLY; excluded from opposite-signal exits.
// Exits call with check_entry_gates=false to retain their prior rules.
// Function: EntryCondition - Apply ENTRY gates before the OR triggers.
bool EntryCondition(const IndicatorState &s,const bool want_buy,
                    const bool check_entry_gates=true)
{
   if(!PassEntryTrendFilter(s,want_buy))
      return false;
   if(check_entry_gates && !PassEntrySlowSMADistanceFilter(want_buy))
      return false;
   if(check_entry_gates && !PassEntryTrendQualityFilters(want_buy))
      return false;
   if(check_entry_gates && !PassEntryCandleSpikeFilter())
      return false;
   if(check_entry_gates && !PassEntrySpreadFilter())
      return false;

   if(!UseCandleColorEntryFilter &&
      !(check_entry_gates && UseTwoCandleSMAContinuationEntryFilter) &&
      !UseMomentumBreakoutEntryFilter &&
      !(check_entry_gates && UseSMAPullbackRejectionEntryFilter) &&
      !(check_entry_gates && UseSMACrossConfirmedEntryFilter))
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
            PassEntrySMACrossConfirmedFilter(want_buy)));
}

// Function: EntryTriggerName - Label the first eligible OR source for tester
// comments and the trade log. More than one OR condition may be true.
string EntryTriggerName(const IndicatorState &s,const bool want_buy)
{
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
      // Save the original target BEFORE a basket removes physical TP.
      // When trailing is enabled, never recompute TP using a modified SL.
      if(current_tp>0.0 && sl>0.0)
         CacheOriginalPositionTP(ticket,current_tp);
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
   bool can_check_entry=(candle_valid && (!UseMTFTrendEntryFilter || all_valid));
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
                           UseTwoCandleSMAContinuationEntryFilter ||
                           UseMomentumBreakoutEntryFilter ||
                           UseSMAPullbackRejectionEntryFilter ||
                           UseSMACrossConfirmedEntryFilter);
   if(!any_entry_trigger) signal_text="OFF";
   else if(UsePreMarketCloseEntryFilter && !broker_session_entry_allowed)
   {
      signal_text=(broker_close_cutoff ? StringFormat("BLOCK MARKET CLOSE -%dM",PreMarketCloseMinutes) : "BROKER SESSION CLOSED");
      signal_color=PanelColorWait();
   }
   else if(!can_check_entry) { signal_text="WAIT DATA"; signal_color=PanelColorWait(); }
   else if(UseMaxSpreadEntryFilter && !PassEntrySpreadFilter())
   {
      signal_text="BLOCK SPREAD";
      signal_color=PanelColorSell();
   }
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

   string cross_confirm_text="OFF";
   color cross_confirm_color=PanelColorMuted();
   if(UseSMACrossConfirmedEntryFilter)
   {
      int confirmed_buy=EvaluateSMACrossOneBarConfirmation(true);
      int confirmed_sell=EvaluateSMACrossOneBarConfirmation(false);
      if(confirmed_buy==5)
      {
         cross_confirm_text="BUY CROSS +1 READY";
         cross_confirm_color=PanelColorBuy();
      }
      else if(confirmed_sell==5)
      {
         cross_confirm_text="SELL CROSS +1 READY";
         cross_confirm_color=PanelColorSell();
      }
      else if(confirmed_buy<0 || confirmed_sell<0)
      {
         cross_confirm_text="WAIT CROSS MA DATA";
         cross_confirm_color=PanelColorWait();
      }
      else if(confirmed_buy>0 || confirmed_sell>0)
      {
         const bool block_buy=(confirmed_buy>0);
         const int code=(block_buy ? confirmed_buy : confirmed_sell);
         const string side=(block_buy ? "BUY" : "SELL");
         cross_confirm_text=side+(code==1 ? " RECENT CROSS BLOCK" :
                                  (code==2 ? " [2] WICK BLOCK" :
                                   (code==3 ? " [1] BREAK BLOCK" :
                                    (code==4 ? " [1] SMA REVERSE" :
                                     (code==6 ? " RANGE GAP BLOCK" :
                                      (code==7 ? " OPEN+BODY SMA BLOCK" :
                                       (code==8 ? " [1] WICK BLOCK" :
                                        (code==9 ? " SMA12 SLOPE BLOCK" :
                                         (code==10 ? " [2] COLOR BLOCK" :
                                          (code==11 ? " [1] COLOR BLOCK" :
                                           (code==12 ? " SMA8 SLOPE BLOCK" :
                                            " WAIT SETUP")))))))))));
         cross_confirm_color=PanelColorWait();
      }
      else
         cross_confirm_text="WAIT CROSS ON [2]";
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
         const bool ratio_ok=PassMomentumCandleBodyRatioFilter();
         const bool slope_ok=(ratio_ok && PassMomentumSlopeEntryFilter(true));
         const bool sma8_slope_ok=(slope_ok && PassMomentumSMA8Slope13Filter(true));
         const bool extension_ok=(sma8_slope_ok && PassMomentumBreakoutExtensionFilter(true));
         const bool four_ok=(extension_ok && PassMomentumFourCandleBodyRatioFilter());
         const bool opposite_body_ok=(four_ok && PassMomentumOppositeBody25Filter(true));
         const bool opposite_breakout_ok=(opposite_body_ok && PassMomentumOppositeColorBreakout12Filter(true));
         const bool sma_band_ok=(opposite_breakout_ok && PassMomentumOpenBodySMABandFilter(true));
         const bool quiet_ok=(sma_band_ok && PassMomentumNoRecentCrossFilter(true));
         const bool wick_sma_ok=(quiet_ok && PassMomentumSignalWickSMA8BlockFilter(true));
         const bool sma_gap_ratios_ok=(wick_sma_ok && PassMomentumSMAGapRatioFilters(true));
         const bool gap_relation_ok=(sma_gap_ratios_ok && PassMomentumGapRelationshipFilters(true));
         const bool gap_reaccel_ok=(gap_relation_ok && PassMomentumGapReaccelerationBlockFilter(true));
         const bool swing_band_ok=(gap_reaccel_ok && PassMomentumDynamicSwingSMA12BandFilter(true));
         const bool swing_break_ok=(swing_band_ok && PassMomentumSwingStructureBreakFilter(true));
         const bool opening_gap_ok=(swing_break_ok && PassMomentumOpeningGaps02Filter());
         const bool body_wicks_ok=(opening_gap_ok && PassMomentumBodyVsBothWicks1Filter());
         const bool bollinger_ok=(body_wicks_ok && PassMomentumBollingerCloseFilter(true));
         momentum_text=(!ratio_ok ? "BUY RATIO BLOCK" :
                        (!slope_ok ? "BUY SLOPE/GAP BLOCK" :
                         (!extension_ok ? "BUY EXTENSION BLOCK" :
                          (!four_ok ? "BUY 4-BODY RATIO BLOCK" :
                           (!sma_band_ok ? "BUY SMA BAND BLOCK" :
                            (!quiet_ok ? "BUY RECENT SMA CROSS BLOCK" :
                             (!wick_sma_ok ? "BUY WICK/SMA8 BLOCK" : "BUY TRIGGER")))))));
         if(four_ok && !opposite_body_ok)
            momentum_text="BUY OPP BODY [2-5] BLOCK";
         if(opposite_body_ok && !opposite_breakout_ok)
            momentum_text="BUY OPP COLOR [1-2] BREAK BLOCK";
         if(slope_ok && !sma8_slope_ok)
            momentum_text="BUY SMA8 [1-3] SLOPE BLOCK";
         if(wick_sma_ok && !sma_gap_ratios_ok)
            momentum_text="BUY SMA GAP RATIO BLOCK";
         if(sma_gap_ratios_ok && !gap_relation_ok)
            momentum_text="BUY SMA GAP [1-2] BLOCK";
         if(gap_relation_ok && !gap_reaccel_ok)
            momentum_text="BUY SMA GAP REACCEL BLOCK";
         if(gap_reaccel_ok && !swing_band_ok)
            momentum_text="BUY DYNAMIC SWING BAND BLOCK";
         if(swing_band_ok && !swing_break_ok)
            momentum_text="BUY SWING HIGH BREAK BLOCK";
         if(swing_break_ok && !opening_gap_ok)
            momentum_text="BUY OPEN GAP [0-2] BLOCK";
         if(opening_gap_ok && !body_wicks_ok)
            momentum_text="BUY BODY/WICKS [1] BLOCK";
         if(body_wicks_ok && !bollinger_ok)
            momentum_text="BUY BOLLINGER [1] BLOCK";
         momentum_color=(bollinger_ok ? PanelColorBuy() : PanelColorWait());
      }
      else if(momentum_sell)
      {
         const bool ratio_ok=PassMomentumCandleBodyRatioFilter();
         const bool slope_ok=(ratio_ok && PassMomentumSlopeEntryFilter(false));
         const bool sma8_slope_ok=(slope_ok && PassMomentumSMA8Slope13Filter(false));
         const bool extension_ok=(sma8_slope_ok && PassMomentumBreakoutExtensionFilter(false));
         const bool four_ok=(extension_ok && PassMomentumFourCandleBodyRatioFilter());
         const bool opposite_body_ok=(four_ok && PassMomentumOppositeBody25Filter(false));
         const bool opposite_breakout_ok=(opposite_body_ok && PassMomentumOppositeColorBreakout12Filter(false));
         const bool sma_band_ok=(opposite_breakout_ok && PassMomentumOpenBodySMABandFilter(false));
         const bool quiet_ok=(sma_band_ok && PassMomentumNoRecentCrossFilter(false));
         const bool wick_sma_ok=(quiet_ok && PassMomentumSignalWickSMA8BlockFilter(false));
         const bool sma_gap_ratios_ok=(wick_sma_ok && PassMomentumSMAGapRatioFilters(false));
         const bool gap_relation_ok=(sma_gap_ratios_ok && PassMomentumGapRelationshipFilters(false));
         const bool gap_reaccel_ok=(gap_relation_ok && PassMomentumGapReaccelerationBlockFilter(false));
         const bool swing_band_ok=(gap_reaccel_ok && PassMomentumDynamicSwingSMA12BandFilter(false));
         const bool swing_break_ok=(swing_band_ok && PassMomentumSwingStructureBreakFilter(false));
         const bool opening_gap_ok=(swing_break_ok && PassMomentumOpeningGaps02Filter());
         const bool body_wicks_ok=(opening_gap_ok && PassMomentumBodyVsBothWicks1Filter());
         const bool bollinger_ok=(body_wicks_ok && PassMomentumBollingerCloseFilter(false));
         momentum_text=(!ratio_ok ? "SELL RATIO BLOCK" :
                        (!slope_ok ? "SELL SLOPE/GAP BLOCK" :
                         (!extension_ok ? "SELL EXTENSION BLOCK" :
                          (!four_ok ? "SELL 4-BODY RATIO BLOCK" :
                           (!sma_band_ok ? "SELL SMA BAND BLOCK" :
                            (!quiet_ok ? "SELL RECENT SMA CROSS BLOCK" :
                             (!wick_sma_ok ? "SELL WICK/SMA8 BLOCK" : "SELL TRIGGER")))))));
         if(four_ok && !opposite_body_ok)
            momentum_text="SELL OPP BODY [2-5] BLOCK";
         if(opposite_body_ok && !opposite_breakout_ok)
            momentum_text="SELL OPP COLOR [1-2] BREAK BLOCK";
         if(slope_ok && !sma8_slope_ok)
            momentum_text="SELL SMA8 [1-3] SLOPE BLOCK";
         if(wick_sma_ok && !sma_gap_ratios_ok)
            momentum_text="SELL SMA GAP RATIO BLOCK";
         if(sma_gap_ratios_ok && !gap_relation_ok)
            momentum_text="SELL SMA GAP [1-2] BLOCK";
         if(gap_relation_ok && !gap_reaccel_ok)
            momentum_text="SELL SMA GAP REACCEL BLOCK";
         if(gap_reaccel_ok && !swing_band_ok)
            momentum_text="SELL DYNAMIC SWING BAND BLOCK";
         if(swing_band_ok && !swing_break_ok)
            momentum_text="SELL SWING LOW BREAK BLOCK";
         if(swing_break_ok && !opening_gap_ok)
            momentum_text="SELL OPEN GAP [0-2] BLOCK";
         if(opening_gap_ok && !body_wicks_ok)
            momentum_text="SELL BODY/WICKS [1] BLOCK";
         if(body_wicks_ok && !bollinger_ok)
            momentum_text="SELL BOLLINGER [1] BLOCK";
         momentum_color=(bollinger_ok ? PanelColorSell() : PanelColorWait());
      }
      else
         momentum_text="NO BREAKOUT";
   }

   string sma_pullback_text="OFF";
   color sma_pullback_color=PanelColorMuted();
   if(UseSMAPullbackRejectionEntryFilter)
   {
      int buy_pb=EvaluateSMAPullbackRejection(true);
      int sell_pb=EvaluateSMAPullbackRejection(false);
      if(buy_pb==3) { sma_pullback_text="BUY SMA PB READY"; sma_pullback_color=PanelColorBuy(); }
      else if(sell_pb==3) { sma_pullback_text="SELL SMA PB READY"; sma_pullback_color=PanelColorSell(); }
      else if(buy_pb==4 || sell_pb==4)
      {
         sma_pullback_text=(buy_pb==4 ? "BUY" : "SELL")+" [2] COLOR BLOCK";
         sma_pullback_color=PanelColorWait();
      }
      else if(buy_pb==5 || sell_pb==5)
      {
         sma_pullback_text=(buy_pb==5 ? "BUY" : "SELL")+" [2] WICK BLOCK";
         sma_pullback_color=PanelColorWait();
      }
      else if(buy_pb==6 || sell_pb==6)
      {
         sma_pullback_text=(buy_pb==6 ? "BUY" : "SELL")+" OPEN GAP BLOCK";
         sma_pullback_color=PanelColorWait();
      }
      else if(buy_pb==7 || sell_pb==7)
      {
         sma_pullback_text=(buy_pb==7 ? "BUY" : "SELL")+" [2-5] BREAK BLOCK";
         sma_pullback_color=PanelColorWait();
      }
      else if(buy_pb==8 || sell_pb==8)
      {
         sma_pullback_text=(buy_pb==8 ? "BUY" : "SELL")+" [3] SMA12 BLOCK";
         sma_pullback_color=PanelColorWait();
      }
      else if(buy_pb==9 || sell_pb==9)
      {
         sma_pullback_text=(buy_pb==9 ? "BUY" : "SELL")+" [1-3] SMA GAP BLOCK";
         sma_pullback_color=PanelColorWait();
      }
      else if(buy_pb==11 || sell_pb==11)
      {
         sma_pullback_text=(buy_pb==11 ? "BUY" : "SELL")+" [2-3] OPEN GAP BLOCK";
         sma_pullback_color=PanelColorWait();
      }
      else if(buy_pb==1 || sell_pb==1)
      {
         sma_pullback_text=(buy_pb==1 ? "BUY" : "SELL")+" WICK BLOCK";
         sma_pullback_color=PanelColorWait();
      }
      else if(buy_pb==2 || sell_pb==2)
      {
         sma_pullback_text=(buy_pb==2 ? "BUY" : "SELL")+" DIST BLOCK";
         sma_pullback_color=PanelColorWait();
      }
      else if(buy_pb<0 || sell_pb<0)
      {
         sma_pullback_text="WAIT SMA/ATR DATA";
         sma_pullback_color=PanelColorWait();
      }
      else sma_pullback_text="WAIT SMA PULLBACK";
   }

   string two_candle_text="OFF";
   color two_candle_color=PanelColorMuted();
   if(UseTwoCandleSMAContinuationEntryFilter)
   {
      if(PassTwoCandleSMAContinuationEntryFilter(true))
      {
         two_candle_text="BUY 2-CANDLE READY";
         two_candle_color=PanelColorBuy();
      }
      else if(PassTwoCandleSMAContinuationEntryFilter(false))
      {
         two_candle_text="SELL 2-CANDLE READY";
         two_candle_color=PanelColorSell();
      }
      else
      {
         two_candle_text="WAIT 2-CANDLE";
         two_candle_color=PanelColorWait();
      }
   }

   string color_trigger="OFF";
   color color_trigger_color=PanelColorMuted();
   if(UseCandleColorEntryFilter)
   {
      int buy_pb=EvaluatePullbackPattern(true);
      int sell_pb=EvaluatePullbackPattern(false);
      if(buy_pb==3 && sell_pb!=3)
      {
         color_trigger="BUY PULLBACK";
         color_trigger_color=PanelColorBuy();
      }
      else if(sell_pb==3 && buy_pb!=3)
      {
         color_trigger="SELL PULLBACK";
         color_trigger_color=PanelColorSell();
      }
      else if(buy_pb<0 || sell_pb<0)
      {
         color_trigger="WAIT M5 DATA";
         color_trigger_color=PanelColorWait();
      }
      else if(buy_pb>0 || sell_pb>0)
      {
         bool blocked_buy=(buy_pb>0);
         int code=(blocked_buy ? buy_pb : sell_pb);
         string side=(blocked_buy ? "BUY" : "SELL");
         color_trigger=side+(code==1 ? " RATIO >3" :
                             (code==4 ? " M5 SMA BLOCK" :
                              (code==5 ? " [3] WICK BLOCK" :
                               (code==6 ? " M5 SMA[2] BLOCK" :
                               (code==7 ? " [1-7] SMA GAP BLOCK" :
                                (code==8 ? " [1-3] SMA12 SLOPE BLOCK" : " 3-CANDLE BLOCK"))))));
         color_trigger_color=PanelColorWait();
      }
      else
      {
         color_trigger="WAIT PULLBACK";
         color_trigger_color=PanelColorWait();
      }
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

   string quality_text="OFF";
   color quality_color=PanelColorMuted();
   bool quality_enabled=(UseH1TrendAgreement || UseM5SlowSMASlopeEntryFilter ||
                         UseM5MAStrengthEntryFilter || UseEntryCandleATRSpikeFilter);
   if(quality_enabled)
   {
      bool check_buy=(mtf_bias>=0);
      bool trend_pass=PassEntryTrendQualityFilters(check_buy);
      bool volatility_pass=PassEntryCandleSpikeFilter();
      bool passed=(trend_pass && volatility_pass);
      quality_text=(passed ? "PASS" : (!volatility_pass ? "VOL BLOCK" : "TREND BLOCK"));
      quality_color=(passed ? PanelColorBuy() : PanelColorSell());
   }
   string spread_text="OFF";
   color spread_color=PanelColorMuted();
   if(UseMaxSpreadEntryFilter)
   {
      MqlTick spread_tick;
      if(SymbolInfoTick(_Symbol,spread_tick) && _Point>0.0 &&
         spread_tick.ask>0.0 && spread_tick.bid>0.0)
      {
         double current_spread=(spread_tick.ask-spread_tick.bid)/_Point;
         bool spread_ok=PassEntrySpreadFilter();
         spread_text=StringFormat("%.0f / %d %s",current_spread,
                                  MaxEntrySpreadPoints,(spread_ok ? "PASS" : "BLOCK"));
         spread_color=(spread_ok ? PanelColorBuy() : PanelColorSell());
      }
      else
      {
         spread_text="WAIT QUOTE";
         spread_color=PanelColorWait();
      }
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

      // Execution is merged into Entry instead of being a separate card.
      int ey=top_y+270;
      PanelSection("entry","02  ENTRY FILTERS  |  GATE + OR",left_x,ey,PANEL_COL_WIDTH,394);
      PanelKV("entry_gate","MTF GATE",(UseMTFTrendEntryFilter ?
              (MTFEntryBiasMode==MTF_MAJORITY ? "ON MAJORITY" : "ON ALL AGREE") : "OFF"),
              left_x,ey+38,(UseMTFTrendEntryFilter ? PanelColorBuy() : PanelColorMuted()));
      PanelKV("entry_candle","M5 CANDLE [1]",candle_text,left_x,ey+62,candle_color);
      PanelKV("entry_color","PULLBACK (OR)",color_trigger,left_x,ey+86,color_trigger_color);
      PanelKV("entry_two_candle","2-CANDLE (OR)",two_candle_text,left_x,ey+110,two_candle_color);
       PanelKV("entry_cross_1bar","CROSS +1 BAR (OR)",cross_confirm_text,left_x,ey+134,cross_confirm_color);
       PanelKV("entry_momentum","MOMENTUM (OR)",momentum_text,left_x,ey+158,momentum_color);
       PanelKV("entry_sma_pb","SMA PULLBACK (OR)",sma_pullback_text,left_x,ey+182,sma_pullback_color);
       PanelKV("entry_distance","SLOW SMA DIST",slow_distance_text,left_x,ey+206,slow_distance_color);
       PanelKV("entry_quality","QUALITY / VOL",quality_text,left_x,ey+232,quality_color);
       PanelKV("entry_spread","SPREAD GATE",spread_text,left_x,ey+256,spread_color);
       PanelKV("entry_signal","ENTRY SIGNAL",signal_text,left_x,ey+280,signal_color);
       PanelKV("exec_mode","ORDER EVAL",(TradeOnNewBarOnly ? "M5 NEW BAR" : "EVERY TICK"),
               left_x,ey+304,PanelColorText());
       PanelKV("exec_status","TRADING",(!EnableTrading ? "DISABLED" :
                (daily_target_hit ? "DAILY TARGET HIT" :
                (!daily_entries_allowed ? "WAIT P/L HISTORY" :
                (!broker_session_entry_allowed ?
                 (broker_close_cutoff ? "CLOSE CUTOFF" : "SESSION CLOSED") : "ENABLED")))),
               left_x,ey+329,(EnableTrading && daily_entries_allowed && broker_session_entry_allowed ?
                                PanelColorBuy() : PanelColorWait()));
       PanelLabel("or_hint","MTF + Distance + Quality + Spread AND enabled OR triggers.",
                  left_x+12,ey+370,PanelColorMuted(),8);
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
   g_slow_distance_atr_handle=INVALID_HANDLE;
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

   // Validate the two mutually exclusive position filters ONLY when
   // 04.7 is enabled. OFF entries must not stop an unrelated strategy.
   if(UseSMACrossConfirmedEntryFilter &&
      UseSMACrossConfirmedRangeDistanceFilter &&
      UseSMACrossConfirmedOpenBodySMAFilter)
   {
      Print("CROSS+1BAR: select only ONE filter mode: RangeDistance OR OpenBodySMA.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(FastMAPeriod<=0 || SlowMAPeriod<=0 || LotSize<=0.0 ||
      !MathIsValidNumber(TargetDailyProfit) || TargetDailyProfit<0.0 ||
      MaxPositionsPerSymbol<0 || SlippagePoints<0 ||
      PreMarketCloseMinutes<0 || PreMarketCloseMinutes>1440 ||
      SwingLookbackBars<1 || SwingLookbackBars>OHLCV_HISTORY ||
      SwingSLBufferPoints<0 ||
      (UseTrailingStopWithSL &&
       (!MathIsValidNumber(TrailingStartTPPercent) ||
        TrailingStartTPPercent<=0.0 || TrailingStartTPPercent>=100.0 ||
        !MathIsValidNumber(TrailingProtectMovePercent) ||
        TrailingProtectMovePercent<=0.0 || TrailingProtectMovePercent>=100.0)) ||
      M5SlopeReferenceShift<2 || M5SlopeReferenceShift>OHLCV_HISTORY ||
      EntryQualityATRPeriod<1 ||
      (UseMomentumBreakoutEntryFilter && UseMomentumBollingerCloseFilter &&
       (MomentumBollingerPeriod<2 ||
        !MathIsValidNumber(MomentumBollingerDeviation) || MomentumBollingerDeviation<=0.0)) ||
      (UseMomentumBreakoutEntryFilter && UseMomentumOpeningGaps02Filter &&
       MomentumMaxOpeningGap02Points<0) ||
      (UseMomentumBreakoutEntryFilter && UseMomentumBodySMAGapRatioFilter &&
       (!MathIsValidNumber(MomentumMaxBodySMAGapRatio) || MomentumMaxBodySMAGapRatio<=0.0)) ||
      (UseMomentumBreakoutEntryFilter && UseMomentumCloseSMAGapRatioFilter &&
       (!MathIsValidNumber(MomentumMaxCloseSMAGapRatio) || MomentumMaxCloseSMAGapRatio<=0.0)) ||
      (UseMomentumBreakoutEntryFilter && UseMomentumGapExpansionEfficiencyFilter &&
       (!MathIsValidNumber(MomentumMinGapExpansionEfficiency) || MomentumMinGapExpansionEfficiency<0.0)) ||
      (UseMomentumBreakoutEntryFilter && UseMomentumBodyGapGrowthMismatchFilter &&
       (!MathIsValidNumber(MomentumMaxBodyGapGrowthMismatch) || MomentumMaxBodyGapGrowthMismatch<=0.0)) ||
      (UseMomentumBreakoutEntryFilter && UseMomentumBodyGapRatioIncreaseFilter &&
       (!MathIsValidNumber(MomentumMaxBodyGapRatioIncrease) || MomentumMaxBodyGapRatioIncrease<0.0)) ||
      (UseTwoCandleCloseSMA8ATRFilter &&
       (!MathIsValidNumber(TwoCandleMaxCloseSMA8ATR) || TwoCandleMaxCloseSMA8ATR<=0.0)) ||
      (UseTwoCandleSMAContinuationEntryFilter && UseTwoCandleOpenGap12Filter &&
       TwoCandleMaxOpenGap12Points<0) ||
      !MathIsValidNumber(M5MinMASpreadATR) || M5MinMASpreadATR<0.0 ||
      !MathIsValidNumber(MomentumMaxRangeATR) || MomentumMaxRangeATR<=0.0 ||
      (UseMomentumCandleBodyRatioFilter &&
        (!MathIsValidNumber(MomentumMaxBodyRatio) || MomentumMaxBodyRatio<1.0)) ||
      (UseSMAPullbackRejectionEntryFilter &&
        (!MathIsValidNumber(SMAPullbackMaxDistanceATR) || SMAPullbackMaxDistanceATR<=0.0 ||
         (UseSMAPullbackOpenGapFilter && SMAPullbackMaxOpenGapPoints<0) ||
         (UseSMAPullbackOpenGap23Filter && SMAPullbackMaxOpenGap23Points<0))) ||
      !MathIsValidNumber(EntryMaxCandleRangeATR) || EntryMaxCandleRangeATR<=0.0 ||
      MaxEntrySpreadPoints<1 ||
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

   if(!UseCandleColorEntryFilter &&
      !UseTwoCandleSMAContinuationEntryFilter &&
      !UseMomentumBreakoutEntryFilter &&
      !UseSMAPullbackRejectionEntryFilter && !UseSMACrossConfirmedEntryFilter)
   {
      Print("Entry OR group is empty: enable Pullback, 2-Candle, MomentumBreakout, SMAPullback or Cross+1Bar.");
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
   if(UseSlowSMADistanceEntryFilter)
      PrintFormat("GLOBAL ENTRY Slow SMA distance enabled: mode=%s, ATR period=%d, multiplier=%.2f, max points=%d. All OR entry triggers are gated.",
                  (SlowSMADistanceMode==SLOW_SMA_DISTANCE_ATR ? "ATR" : "POINTS"),
                  SlowSMAATRPeriod,SlowSMAMaxDistanceATR,SlowSMAMaxDistancePoints);
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
      else if(UseSMACrossConfirmedOpenBodySMAFilter)
         Print("CROSS+1BAR OPEN+BODY SMA: BUY Open[1]-Body[1]>=SMA12[1]; SELL Open[1]+Body[1]<=SMA12[1]. No multiplier.");
      else
         Print("WARNING: CROSS+1BAR enabled with BOTH SMA12 position filters OFF; base [2] cross/[1] confirm rules remain active.");
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
   if(UseH1TrendAgreement || UseM5SlowSMASlopeEntryFilter || UseM5MAStrengthEntryFilter)
      PrintFormat("ENTRY QUALITY: H1=%s M5-slope=%s (reference shift %d) M5-strength=%s (min %.2f ATR), ATR=%d",
                  (UseH1TrendAgreement ? "ON" : "OFF"),
                  (UseM5SlowSMASlopeEntryFilter ? "ON" : "OFF"),M5SlopeReferenceShift,
                  (UseM5MAStrengthEntryFilter ? "ON" : "OFF"),M5MinMASpreadATR,EntryQualityATRPeriod);
   if(UseMaxSpreadEntryFilter)
      PrintFormat("ENTRY spread cap enabled: %d points",MaxEntrySpreadPoints);
   if(UseEntryCandleATRSpikeFilter)
      PrintFormat("GLOBAL ENTRY candle range cap: Range[1] <= %.2f x ATR(%d)[2]",
                  EntryMaxCandleRangeATR,EntryQualityATRPeriod);
   if(UseMomentumBreakoutEntryFilter)
   {
      PrintFormat("M5 MOMENTUM 04.5 CORE: Color[1]=%s Breakout[N=%d]=%s SMA direction[1]=%s BodyStrength[1..3]=%s (min %.2f); entry-only toggles; exit rules unchanged.",
                  (UseMomentumSignalColor1Filter ? "ON" : "OFF"),
                  MomentumBreakoutLookbackBars,(UseMomentumPriceBreakoutFilter ? "ON" : "OFF"),
                  (UseMomentumSMA8SMA12DirectionFilter ? "ON" : "OFF"),
                  (UseMomentumBodyStrength13Filter ? "ON" : "OFF"),MomentumMinBodyRatio);
      if(!UseMomentumSignalColor1Filter && !UseMomentumPriceBreakoutFilter &&
         !UseMomentumSMA8SMA12DirectionFilter)
         Print("MOMENTUM NOTE: color, breakout and SMA direction are all OFF. Both BUY/SELL may qualify at once; conflicting signals prevent entry.");
   }
   if(UseMomentumBreakoutEntryFilter && UseMomentumBodySMAGapRatioFilter)
      PrintFormat("MOMENTUM BODY/SMA GAP [1] ON: Body[1] / abs(SMA8[1]-SMA12[1]) <= %.2f.",MomentumMaxBodySMAGapRatio);
   if(UseMomentumBreakoutEntryFilter && UseMomentumCloseSMAGapRatioFilter)
      PrintFormat("MOMENTUM CLOSE/SMA GAP [1] ON: directional Close-to-SMA8 / SMA gap <= %.2f.",MomentumMaxCloseSMAGapRatio);
   if(UseMomentumBreakoutEntryFilter &&
      (UseMomentumGapExpansionEfficiencyFilter ||
       UseMomentumBodyGapGrowthMismatchFilter ||
       UseMomentumBodyGapRatioIncreaseFilter))
      PrintFormat("MOMENTUM GAP filters: Efficiency[1-2]=%s (min %.3f) GrowthMismatch[1-2]=%s (max %.2f) ExtremeBody/Gap[1-3]=%s (abs diff max %.2f); A/B/C include built-in same-direction SMA cross exception on closed [1..3]. Other gates unchanged.",
                  (UseMomentumGapExpansionEfficiencyFilter ? "ON" : "OFF"),MomentumMinGapExpansionEfficiency,
                  (UseMomentumBodyGapGrowthMismatchFilter ? "ON" : "OFF"),MomentumMaxBodyGapGrowthMismatch,
                  (UseMomentumBodyGapRatioIncreaseFilter ? "ON" : "OFF"),MomentumMaxBodyGapRatioIncrease);
   if(UseMomentumBreakoutEntryFilter && UseMomentumGapReaccelerationBlockFilter)
      Print("MOMENTUM GAP REACCELERATION ON: CLOSED [1..4], directional gap delta d1>d3>d2>0 blocks the entry (no threshold); exits and other ORs unchanged.");
   if(UseMomentumBreakoutEntryFilter && UseMomentumDynamicSwingSMA12BandFilter)
      Print("MOMENTUM DYNAMIC SWING/SMA12 BAND ON: latest confirmed M5 2/2 pivot in [4..50]; BUY Close[1] < SMA12[1]+(SwingHigh-SMA12[swing]); SELL mirrored. No ATR or multiplier. Missing pivot blocks entry.");
   if(UseMomentumBreakoutEntryFilter && UseMomentumSwingStructureBreakFilter)
      Print("MOMENTUM SWING STRUCTURE BREAK ON: BUY Close[1] > confirmed Swing High; SELL Close[1] < confirmed Swing Low (2/2 pivot [4..50]); unavailable swing blocks entry.");
   if(UseMomentumBreakoutEntryFilter && UseMomentumOpeningGaps02Filter)
      PrintFormat("MOMENTUM OPEN GAPS [0..2] ON: abs(Open[1]-Close[2]) and abs(Open[0]-Close[1]) <= %d broker points (ENTRY ONLY).",MomentumMaxOpeningGap02Points);
   if(UseMomentumBreakoutEntryFilter && UseMomentumBodyVsBothWicks1Filter)
      Print("MOMENTUM BODY/WICKS [1] ON: Body[1]>=UpperWick[1] AND Body[1]>=LowerWick[1], equality passes (ENTRY ONLY).");
   if(UseMomentumBreakoutEntryFilter && UseMomentumBollingerCloseFilter)
      PrintFormat("MOMENTUM BOLLINGER CLOSE [1] ON: BB(%d, %.2f) M5 PRICE_CLOSE; BUY Close[1]<=Upper[1], SELL Close[1]>=Lower[1], equality passes (ENTRY ONLY).",
                  MomentumBollingerPeriod,MomentumBollingerDeviation);
   if(UseMomentumBreakoutEntryFilter && UseMomentumSignalWickSMA8BlockFilter)
      Print("MOMENTUM WICK/SMA8 [1] ON: BLOCK BUY if UpperWick>Body AND Low>SMA8; BLOCK SELL if LowerWick>Body AND High<SMA8 (strict; ENTRY ONLY).");
   if(UseMomentumBreakoutEntryFilter && UseMomentumCandleBodyRatioFilter)
      PrintFormat("MOMENTUM ENTRY: max body ratio [1]/[2] = %.2f",MomentumMaxBodyRatio);
   if(UseMomentumBreakoutEntryFilter && UseMomentumSlopeEntryFilter)
      Print("MOMENTUM SLOPE+GAP ON: BUY both SMAs rise, SMA8-SMA12 [1]>[2]; SELL both SMAs fall, SMA12-SMA8 [1]>[2]. All on closed M5 candles; only Momentum entries affected.");
   if(UseMomentumBreakoutEntryFilter && UseMomentumSMA8Slope13Filter)
      Print("MOMENTUM SMA8 [1..3] SLOPE ON: BUY SMA8[1]>[2]>[3]; SELL SMA8[1]<[2]<[3]. Independent Entry 04.5 filter.");
   if(UseMomentumBreakoutEntryFilter && UseMomentumBreakoutExtensionFilter)
      Print("MOMENTUM EXTENSION ON: breakout beyond previous N-bar High/Low must be positive and <= 50% of Body[1] (ENTRY ONLY).");
   if(UseMomentumBreakoutEntryFilter && UseMomentumFourCandleBodyRatioFilter)
      Print("MOMENTUM 4-BODY RATIO ON: max Body[1..4] / min Body[1..4] <= 2.0, no zero bodies (ENTRY ONLY).");
   if(UseMomentumBreakoutEntryFilter && UseMomentumOppositeBody25Filter)
      Print("MOMENTUM OPPOSITE BODY [2..5] ON: BUY blocks RED body > immediately prior GREEN body; SELL mirrors; only adjacent closed bars [2..5], equal passes (ENTRY ONLY).");
   if(UseMomentumBreakoutEntryFilter && UseMomentumOppositeColorBreakout12Filter)
      Print("MOMENTUM OPPOSITE COLOR BREAKOUT [1-2] ON: BUY [2]RED/[1]GREEN requires Close[1]>High[2]; SELL [2]GREEN/[1]RED requires Close[1]<Low[2]; other color pairs PASS (ENTRY ONLY).");
   if(UseMomentumBreakoutEntryFilter && UseMomentumOpenBodySMABandFilter)
      Print("MOMENTUM SMA BAND ON: BUY SMA12[1]<=Close[1]-Body[1]<=SMA8[1]; SELL SMA8[1]<=Close[1]+Body[1]<=SMA12[1] (ENTRY ONLY).");
   if(UseMomentumBreakoutEntryFilter && UseMomentumNoRecentCrossFilter)
      PrintFormat("MOMENTUM NO RECENT CROSS ON: no SMA8/12 cross/touch in previous %d CLOSED M5 candles [1]..[%d] (using [%d] as older reference). Momentum ENTRY ONLY.",
                  MOMENTUM_NO_CROSS_BARS,MOMENTUM_NO_CROSS_BARS,MOMENTUM_NO_CROSS_BARS+1);
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
   if(UseM5MAStrengthEntryFilter || UseEntryCandleATRSpikeFilter ||
      (UseMomentumBreakoutEntryFilter && UseMomentumATRSpikeFilter) ||
      UseSMAPullbackRejectionEntryFilter ||
      (UseTwoCandleSMAContinuationEntryFilter && UseTwoCandleCloseSMA8ATRFilter))
   {
      g_entry_quality_atr_handle=iATR(_Symbol,PERIOD_M5,EntryQualityATRPeriod);
      if(g_entry_quality_atr_handle==INVALID_HANDLE)
      {
         PrintFormat("Cannot create entry-quality M5 ATR(%d), error=%d",
                     EntryQualityATRPeriod,GetLastError());
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

   PrintFormat("MTF SMA EA BASELINE 002 v3.78 | TF=M5 | Fast=%d Slow=%d | ActiveTF=%d/5 | MTF Bias=%s | MTF_GATE=%s | PULLBACK=%s CROSS_1BAR=%s MOMENTUM=%s SMA_PB=%s | SwingSL=%s Lookback=%d | TP=%s | Trading=%s",
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
   DeleteStatusPanel();
   if(g_slow_distance_atr_handle!=INVALID_HANDLE)
   {
      IndicatorRelease(g_slow_distance_atr_handle);
      g_slow_distance_atr_handle=INVALID_HANDLE;
   }
   if(g_entry_quality_atr_handle!=INVALID_HANDLE)
   {
      IndicatorRelease(g_entry_quality_atr_handle);
      g_entry_quality_atr_handle=INVALID_HANDLE;
   }
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
      if(newly_switching_to_basket) SynchronizeTakeProfits(false);
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
      if(newly_switching_to_basket) SynchronizeTakeProfits(false);
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
      PrintFormat("Opened %s [%s] lot=%.5f opposite_recovery=%s same_side_basket=%s, position limit=%s, basket=%s",
                  (is_buy ? "BUY" : "SELL"),entry_source,entry_lot,
                  (UseRecoveryLot ? (g_recovery_active ? "ACTIVE" : "ARMED") : "OFF"),
                  (UseSameSideRecoveryLot ? (g_same_recovery_active ? "ACTIVE" : "ARMED") : "OFF"),
                  (MaxPositionsPerSymbol==0 ? "UNLIMITED" : IntegerToString(MaxPositionsPerSymbol)),
                  (entry_needs_basket ? "ON" : "OFF"));
   UpdateStatusPanel();
}
//+------------------------------------------------------------------+
