//+------------------------------------------------------------------+
//| XAU_MTF_SMA_8_12_M5_EA_BASELINE_003_v111.mq5                     |
//| M5 SMA(8,12) multi-timeframe entry, basket and recovery management |
//| Responsive status UI: grouped cards, maximum two columns.          |
//+------------------------------------------------------------------+
#property strict
#property version   "3.111"
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
// v3.57: the B3 OR family used to refuse any new entry while ONE position was open, so valid
// high-precision signals were discarded. When this is true the family honours
// MaxPositionsPerSymbol instead (0 still means unlimited). Default false keeps the certified
// one-position behaviour unchanged.
input bool AllowConcurrentORPositions = false;
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

input group "04.0 | Entry - TP-Energy Volatility Gate (Pure Structural)"
// Toggleable volatility gates comparing closed M5 energy directly against FixedTPPoints:
// - UseTPEnergyRangeGate: closed signal bar [1] range >= TPEnergyRangeMultiple * TP distance.
// - UseTPEnergyATRGate  : closed M5 ATR[2] >= TPEnergyATRMultiple * TP distance.
// Default 10.0 => TP ($0.50 on 500pt XAUUSDc) <= 10% of 1 M5 bar ($5.00), so TP fills cleanly within <=5 bars.
input bool UseM1ColorFilter = true;      // v3.109: global M1 colour gate toggle (test/recovery scenarios)
input bool UseTPEnergyRangeGate = true;
input double TPEnergyRangeMultiple = 6.0;
input bool UseTPEnergyATRGate = true;
input double TPEnergyATRMultiple = 6.0;

input int NewORIsolatedEntry = 0;

input group "04.B3.01 | Entry - OR B3_01 SMA8 Launch Engulfing (Pure-PA + Indicator)"
// Pure-PA + Indicator (zero magic decimals):
// BUY : M5 SMA8[1]>SMA12[1] & SMA8[1]>SMA8[2], M15 SMA8[1]>SMA12[1],
//       [2] RED, [1] GREEN, Close[1]>High[2], Body[1]>Wicks[1],
//       Low[1]<=SMA8[1] & Close[1]>SMA8[1] (launch off SMA8),
//       Range[1]>Range[2], Volume[1]>Volume[2], Range[1]>ATR14[2].
// SELL: exact mirror.
input bool UseB3_01_SMA8LaunchEngulf = true;

input group "04.B3.02 | Entry - OR B3_02 Outside Sweep Continuation (Pure-PA + Indicator)"
// Pure-PA + Indicator (zero magic decimals):
// BUY : Outside bar [1] (Low[1]<Low[2], Close[1]>High[2], Close[1]>Open[1]), Body[1]>Wicks[1],
//       Volume[1]>Volume[2], M5/M15/H1 SMA8>SMA12, M5 SMA8 rising, Close[1]>SMA8[1],
//       ATR14[1]>ATR14[2], 1x ATR < Range[1] < 3x ATR, M1 closed bar aligned.
// SELL: exact mirror.
input bool UseB3_02_OutsideSweepCont = true;

input group "04.B3.03 | Entry - OR B3_03 Inside Bar Breakout (Pure-PA + Indicator)"
// Pure-PA + Indicator (zero magic decimals):
// BUY : [2] Inside Bar (High[2]<High[3] && Low[2]>Low[3]), [1] breaks out (Close[1]>High[3], Close[1]>Open[1]),
//       Body[1]>Wicks[1], Volume[1]>Volume[2], M5/M15/H1 SMA8>SMA12, M5 SMA8 rising, Close[1]>SMA8[1],
//       ATR14[1]>ATR14[2], 1x ATR < Range[1] < 3x ATR, M1 closed bar aligned.
// SELL: exact mirror.
input bool UseB3_03_InsideBarBreakout = true;

input group "04.B3.04 | Entry - OR B3_04 Pinbar Rejection off SMA8 (Pure-PA + Indicator)"
// Pure-PA + Indicator (zero magic decimals, disjoint from big-body ORs):
// BUY : Bullish Pinbar off SMA8 (Close[1]>Open[1], Low[1]<=SMA8[1]<Close[1], Tail[1]>Body[1] & Tail[1]>LeadWick[1]),
//       Volume[1]>Volume[2], M5/M15/H1 SMA8>SMA12, M5 SMA8 rising & >SMA20, 1x ATR < Range[1] < 3x ATR, M1 aligned.
// SELL: exact mirror.
input bool UseB3_04_PinbarRejSMA8 = true;

input group "04.B3.05 | Entry - OR B3_05 Donchian(10) Channel Breakout (Pure-PA + Indicator)"
// Pure-PA + Indicator (zero magic decimals):
// BUY : Fresh Donchian(10) breakout (Close[1]>max(High[2..11]) && Close[2]<=max(High[2..11])),
//       Body[1]>Wicks[1], Range[1]>Range[2], Volume[1]>Volume[2],
//       M5/M15/H1 SMA8>SMA12, M5 SMA8/12 rising & >SMA20, ATR14 rising (1x..3x), M1 aligned.
// SELL: exact mirror.
input bool UseB3_05_Donchian10BO = true;

input group "04.B3.06 | Entry - OR B3_06 Bollinger Band(20,2) Breakout (Pure-PA + Indicator)"
// Pure-PA + Indicator (zero magic decimals):
// BUY : Fresh Bollinger Band(20,2) breakout (Close[1]>UpperBB && Close[2]<=UpperBB),
//       Body[1]>Wicks[1], Range[1]>Range[2], Volume[1]>Volume[2],
//       M5/M15/H1 SMA8>SMA12, M5 SMA8/12 rising, ATR14 rising (1x..3x), M1 aligned.
// SELL: exact mirror.
input bool UseB3_06_BollingerBO = true;

input group "04.B3.07 | Entry - OR B3_07 MACD(12,26,9) Histogram Turn (Pure-PA + Indicator)"
// Pure-PA + Indicator (zero magic decimals):
// BUY : MACD(12,26,9) Main[1]>0 & Hist[1]>Hist[2] & Hist[2]<=Hist[3] (fresh histogram turn),
//       Close[1]>Open[1] & Close[1]>High[2], Body[1]>Wicks[1], Range[1]>Range[2], Volume[1]>Volume[2],
//       M5/M15/H1 SMA8>SMA12, M5 SMA8 rising, 1x ATR < Range[1] < 3x ATR, M1 aligned.
// SELL: exact mirror.
input bool UseB3_07_MACDHistTurn = true;

input group "04.B3.08 | Entry - OR B3_08 Keltner Channel(20, 1*ATR) Breakout (Pure-PA + Indicator)"
// Pure-PA + Indicator (zero magic decimals):
// BUY : Fresh Keltner Channel(20, 1*ATR14) breakout (Close[1]>SMA20+ATR14 && Close[2]<=SMA20+ATR14),
//       Body[1]>Wicks[1], Range[1]>Range[2], Volume[1]>Volume[2],
//       M5/M15/H1 SMA8>SMA12, M5 SMA8 rising, 1x ATR < Range[1] < 3x ATR, M1 aligned.
// SELL: exact mirror.
input bool UseB3_08_KeltnerBO = true;

input group "04.B3.09 | Entry - OR B3_09 RSI(14) Pullback Hook Reclaim (Pure-PA + Indicator)"
// Pure-PA + Indicator (zero magic decimals):
// BUY : RSI(14) dips on [2] (RSI[2]<RSI[3]) and hooks up on [1] (RSI[1]>RSI[2]) inside 50..70,
//       Close[1]>Open[1] & Close[1]>Close[2], Body[1]>Wicks[1], Volume[1]>Volume[2],
//       M5/M15/H1 SMA8>SMA12, M5 SMA8 rising, 1x ATR < Range[1] < 3x ATR, M1 aligned.
// SELL: exact mirror.
input bool UseB3_09_RSIHookReclaim = true;

input group "04.B3.10 | Entry - OR B3_10 2-Bar Pullback Reclaim (Pure-PA + Indicator)"
// Pure-PA + Indicator (zero magic decimals):
// BUY : [3] RED & [2] RED (2-bar pullback), [1] GREEN & Close[1]>High[2], Body[1]>Wicks[1], Volume[1]>Volume[2],
//       M5/M15/H1 SMA8>SMA12, Close[1]>SMA8[1], 1x ATR < Range[1] < 3x ATR, M1 aligned.
// SELL: exact mirror.
input bool UseB3_10_TwoBarPBReclaim = true;
input group "04.B3.11 | Entry - OR B3_11 SMA8 Snap-Back Reclaim (Pure-PA + Indicators)"
input bool UseB3_11_SnapSMA8 = true;
input group "04.B3.12 | Entry - OR B3_12 Trend Pinbar Rejection (Pure-PA + Indicators)"
input bool UseB3_12_TrendPinbar = true;
input group "04.B3.15 | Entry - OR B3_15 Aroon(14) Fresh 100 Impulse (Zero-Decimal)"
input bool UseB3_15_Aroon14Imp = true;

input group "04.B3.18 | Entry - OR B3_18 1-Bar Pullback Touch SMA8 (Zero-Decimal)"
input bool UseB3_18_PB1TouchSMA8 = true;

input group "04.B3.19 | Entry - OR B3_19 Connors RSI(2) Snapback (Zero-Decimal)"
input bool UseB3_19_RSI2Snapback = true;

input group "04.B3.20 | Entry - OR B3_20 SMA(20) Pullback Bounce (Zero-Decimal)"
input bool UseB3_20_SMA20Bounce = true;

input group "04.B3.23-46 | Entry - Disjoint Zero-Decimal Regime ORs (123..146)"
input bool UseB3_23_CoolingATR      = true;
input bool UseB3_25_CCI200Power     = true;
input bool UseB3_27_TightBarCont    = true;
input bool UseB3_30_GiantBarFollow  = true;
input bool UseB3_31_InsideCloseMom  = true;
input bool UseB3_32_SMA12Bounce     = true;
input bool UseB3_33_FreshM5Cross    = true;
input bool UseB3_39_M1OppFlush      = true;
// v3.49: DISABLED. Isolated 2026 test (TP-Energy ON) gave only 15 trades/year -> below the
// 50/year floor, and 1 of 15 ran 13 bars against the 5-bar rule. Its pre-entry structure is
// identical to its winners, so no defensible filter exists; it cannot be certified.
input bool UseB3_40_MarubozuOpen    = false;
input bool UseB3_41_CounterH4Drive  = true;
input bool UseB3_42_ParallelSMAGap  = true;
input bool UseB3_43_M15CounterBnc   = true;
input bool UseB3_44_BalancedBodyBO  = true;
// v3.49: DISABLED. Isolated 2026 test (TP-Energy ON): 16 trades/year (below the 50/year
// floor), 14/16 within 5 bars, and one 211-bar trade that drove a 43.86% equity drawdown.
// That failing bar had the strongest pre-entry profile of the whole set (volume 1.74x its
// 20-bar average, RSI 88.5, 94% body, zero lead wick), so the failure is not separable by
// any pre-entry structure. Its "volume must NOT expand" premise also contradicts every
// certified momentum OR in this file. Removed from the default portfolio.
input bool UseB3_45_ParabolicGlide  = false;
input bool UseB3_46_BandLaunchSMA12 = true;
// OR id 147 (B3_47 Failed Break Reclaim) was REMOVED in v3.48 after it failed the
// five-bar criterion (85.5% on 2026). The id is retired and must not be reused.

input group "04.B3.48 | Entry - OR B3_48 Previous-Day Extreme Break (Pure-PA + Indicator)"
// Structural premise: the previous completed broker day's high/low is a level every
// participant can see, so trading through it is a genuine structural break rather than
// a break of the previous bar. Momentum continuation family, not a fade.
// BUY : previous D1 high broken by the close of bar[1], in a fully aligned 5-TF SMA8/12
//       uptrend with an expanding SMA gap, dominant body, small lead wick, expanding
//       range and volume versus both prior bars, and rising ATR. SELL: exact mirror.
// No M1 micro gate, so the trade frequency stays above the 50-per-year floor.
// No numeric thresholds beyond the structural relations above.
// v3.47 CERTIFIED DEFAULT: isolated test 2026.01.01-11.17, real ticks, lot 10, no SL,
// fixed TP 500 pts -> 72 trades, 72/72 closed by TP within 5 bars, 0 stop-outs,
// +403.95 gross, balance drawdown 0.00. Isolated October 2026 -> 6/6 within 5 bars.
// Known limit: the 2025 out-of-sample year reached only 84/94 (89.4%) within 5 bars,
// so year-to-year robustness is NOT proven. See
// b3_48_prevday_extreme_break/README_TH.md before enabling on a live account.
input bool UseB3_48_PrevDayExtremeBreak = true;

input group "04.B3.49-51 | Entry - OR Structure-Break Continuation Variants (Pure-PA + Indicator)"
// v3.51: DISABLED by default. Measured in the combined portfolio these three added only
// 31 trades and produced ALL FIVE over-5-bar trades (42, 360, 16, 35, 10 bars).
// Cause: an OR that sits at the END of the id loop only ever sees signals that every
// earlier OR already rejected, so it is adversely selected. Tail-positioned ORs cannot
// add frequency safely; they add risk. Frequency is raised by the global switch below.
input bool UseB3_49_FiveBarStructureBreak = false;
input bool UseB3_50_NineteenBarStructureBreak = false;
input bool UseB3_51_ThreeBarThrust = false;

// v3.93: B3_52 (formerly "04.B3.52 | Entry - OR B3_52 Trend Pullback Hold") is REMOVED from this
// build. Its 2026 all-entry measurement produced 79 trades with 7 over-5-bar orders; two
// redevelopment rounds could not reach 100% inside 5 bars while keeping >=50 trades/year, so the
// entry (logic, input switch and group header) is deleted rather than disabled. Id 152 is retired.

input group "04.B3.53 | Entry - OR B3_53 Deep Pullback Hold (Pure-PA + Indicator)"// v3.53 NEW. Deeper pullback than B3_52: the bar wicks down through the SLOW M5 SMA12 and
// closes back above it while SMA8 is still above SMA12, so the trend structure is intact but
// the dip reached the slower mean. Same 5-TF requirement, body dominance, volume expansion
// and rising ATR. No brk2, no numeric thresholds. SELL: exact mirror.
// v3.54 DISABLED. In the combined 2026 portfolio it opened a BUY on 2026-03-04 that ran
// 1308 bars (4.5 days) and lost 1,867.95 USD at lot 10, stopping the account out on
// 2026-03-09 after 138 consecutive wins. Adding high-frequency pullback ORs at this lot
// size with no stop loss is not survivable, so the extra frequency is refused.
input bool UseB3_53_DeepPullbackHold = false;

// v3.93: B3_54 and B3_55 REMOVED from this build. In the 2026 all-entry portfolio they produced
// 18 and 17 over-5-bar orders respectively (B3_55 inherited the same signals once B3_54 was off),
// and five redevelopment rounds could not reach 100% inside 5 bars with >=50 trades/year.
// With all three removed the 2026 portfolio closes 568/568 trades inside 5 bars.
// The three ids (152/154/155) are RETIRED and must not be reused.

input group "04.B3.56 | Entry - OR B3_56 Three-Bar Body Expansion (Pure-PA, M5 only)"
// v3.61 NEW Entry OR (development follows README_EA_Entry_OR_Development.md, one OR per round).
// Definition (no numeric threshold, no magic decimals):
// BUY : M5 bars [1],[2],[3] are all BULLISH (close>open) and their bodies strictly expand,
//       body[1] > body[2] > body[3]   with body = |Close-Open|,
//       and M5 SMA8[1] > SMA12[1].
// SELL: exact mirror - all three bars BEARISH and SMA8[1] < SMA12[1].
// Deliberately M5-only: no M15/M30/H1/H4 alignment and no volume/ATR gate are part of this first
// version, so the isolated test measures exactly this premise as requested.
input bool UseB3_56_BodyExpansion3 = true;
// v3.62 Phase-C filter for B3_56 ONLY (per README Phase C), added after the January 2026 isolated
// test failed: 78 trades, 9 over-5-bar orders and 1 stop-out.
// Behavioural hypothesis: a 3-bar body expansion that CONTRADICTS one or more higher-timeframe
// SMA8/12 trends is a late/false momentum push - the M5 bodies expand while the larger trend is
// still against it, so price needs many bars to reach the fixed TP (or never does).
// Evidence in the failing month: of the 11 orders where M15, M30, H1 and H4 all agreed with the
// trade, 11/11 closed inside 5 bars; every one of the 9 over-5-bar orders (including the 197-bar
// stop-out) had at least one higher timeframe against it.
// Filter = require M15/M30/H1 alignment and H4 alignment while UseH4AlignmentForEntries is true.
// No numeric parameter is introduced.
input bool B3_56_RequireMTFAlignment = true;
// v3.63 Phase-C filter #2 for B3_56 ONLY, added after the January 2026 run still had one order that
// needed 6 bars (2026.01.05 07:45 BUY) and no stop-out.
// Behavioural hypothesis: the fixed 500-point TP is a FIXED distance, so it can only be reached in
// 1-5 bars when the entry bar is bigger than a normal bar and volatility is expanding. When the
// expansion bar is smaller than the recent ATR (quiet tape) the same 500 points need many bars.
// The January evidence: the only over-5-bar order had range/ATR = 0.99 and ATR falling, while
// every order with range[1] > ATR and ATR rising closed within 5 bars.
// Filter = structural volatility-expansion check, no tunable number:
//   range[1] > ATR14[2]   AND   ATR14[1] > ATR14[2]
input bool B3_56_RequireVolExpansion = true;
// v3.64 Phase-C filter #3 for B3_56 ONLY, added after the full-year 2026 run kept 7 over-5-bar
// orders (all profitable, no stop-out): 124 trades, 117/124 inside 5 bars.
// Behavioural hypothesis - LIQUIDITY, not calendar: XAU only carries the volume needed to travel a
// fixed 500-point TP in 1-5 bars while the main liquidity venues are open. In the thin hours the
// same signal is a low-participation drift: price grinds the 500 points over many bars even though
// the entry bar looked like an expansion bar.
// Evidence (2026, isolated): all 7 over-5-bar orders entered between 00:00 and 08:59 server time;
// 0 of the 71 orders opened 09:00-23:59 went past 5 bars. Volume/ATR/spread/breakout proxies were
// tested first and none separated (see B3_56_RequireVolExpansion and the Phase-C report).
// CAVEAT: the window is a time window and was chosen from the same 2026 sample, so it is
// in-sample - it must be confirmed on an unseen year before this entry can be certified.
input bool B3_56_RequireLiquidSession = true;
input int  B3_56_LiquidStartHour = 9;    // broker server hour, inclusive
input int  B3_56_LiquidEndHour   = 23;   // broker server hour, inclusive

input group "04.B3.65 | Entry - OR B3_65 Body Chain Two-Bar Break"
// v3.81 NEW Entry OR (README: one OR per round, isolated test).
// Same engine as B3_63 (which passed 2025+2026 with 100% inside 5 bars) but the structural level
// is only the PREVIOUS bar's extreme instead of the three-bar extreme. Rationale: the chain already
// proves bodies are expanding, so the level only needs to confirm that the last bar closed beyond
// the prior bar - requiring three bars of level as well made the entry fire only ~50 times a year.
// BUY : bars [1][2][3] bullish, body[1] > body[2] > body[3], close[1] > high[2]
//       body[1] > wicks[1], vol[1] > vol[2], ATR14 rising
//       SMA8 > SMA12 + M15/M30/H1/H4 alignment + server hour 07..23
// SELL: exact mirror.
input bool UseB3_65_ChainTwoBarBreak = true;
input group "04.B3.80 | Entry - OR B3_80 Break & Retest of 10-bar Level (PA trigger ?????????)"
// v3.105 NEW Entry OR (??? v093). Price-action trigger: a 10-bar level is broken, price returns to
// retest it, and the retest bar holds the level and closes back through it.
// Offline 2026 (M5): trigger ?????? = 128/136 (94.1%); ??????????? MTF M15/H1/H4 alignment = 23/23 (100%).
// DEFINITION
// BUY : level = max(high[3..13]); close[2] > level (breakout); low[1] <= level (retest touched);
//       close[1] > level (held) + dominance + volume + ATR rising + SMA8/12 + M15/M30/H1/H4 + M1 + hour 07..23
// SELL: mirror with level = min(low[3..13])
input bool UseB3_80_BreakRetest = true;
input int  B3_65_LiquidStartHour = 7;
input int  B3_65_LiquidEndHour   = 23;

input group "04.B3.52 | Global Entry - H4 Alignment Requirement"
// Master requirement used by every continuation OR in the 123..151 block.
// OFF lets the same ORs fire when H4 disagrees with M5/M15/M30/H1.
// Offline measurement over 2026: keeping H4 costs about half the signals
// (663/yr at 96.0% within 5 bars versus 1131/yr at 95.6% with H4 dropped).
// This is a single structural relaxation applied to the whole family, NOT a numeric
// threshold change, and it does not alter any individual OR's own logic.
input bool UseH4AlignmentForEntries = true;

input group "04.R1 | Recovery - Fixed Protective Stop (works with the fixed TP)"
// v3.55 NEW recovery control. The 2026 and 2025 combined portfolios each ended in a
// stop-out from ONE runaway trade (1308 and 1546 bars, -1,867.95 and a full wipe) while
// every other trade closed at the 500-point TP. The EA's swing SL forces an RR-based TP and
// therefore cannot be combined with the fixed TP, so this adds a standalone protective stop.
// Off by default: the certification configuration still runs with no stop loss.
// ProtectiveStopPoints is measured in broker points and applies to new entries only.
input bool UseProtectiveStop = false;
input int  ProtectiveStopPoints = 0;

// v3.60: the Maximum Holding Bars force-close feature (UseMaxHoldExit / MaxHoldBars) that was
// added in v3.59 has been REMOVED because it is not permitted. Exits must come from the fixed
// 500-point TP; no time-based close may be used to satisfy the five-bar rule.

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
input bool UseFastEscapeRecovery = true;
input int FastRecoveryAfterBars = 5;
input int FastRecoveryMaxPositions = 0;
input int FastRecoverySameSideStepPts = 1000;
input int FastRecoveryHedgeMinLossPts = 1500;
input int    RecoveryMaxMinutes = 30;      // v3.108: time cap per recovery episode (minutes)
input bool   RecoveryBreakevenExit = true; // v3.110: close the recovery basket as soon as it is >= 0 points
input bool   RecoveryAtrScaled = false;       // v3.111: scale flip/add distances to ATR14 instead of fixed points
input double RecoveryAtrLossMultiple = 0.5;  // basket loss must reach this many ATRs before a flip
input double RecoveryAtrStepMultiple = 0.5;  // adverse distance must reach this many ATRs before averaging
input bool   RecoveryWhipsawGuard = false;    // never flip inside a bar already stretched vs ATR
input double RecoveryWhipsawRangeMultiple = 1.5;
input int    RecoveryMaxFlipsPerEpisode = 0; // 0 = unlimited // v3.110: close the recovery basket as soon as it is >= 0 points
input double FastRecoveryNetFlipRatio = 1.5;

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
double   g_basket_realized_pts     = 0.0;
// Latched after first opposite entry until all EA positions are flat.
bool     g_recovery_active         = false;
// v3.108: when the current recovery episode started (0 = none).
datetime g_recovery_started_at     = 0;
int      g_recovery_flips          = 0;   // v3.111: flips used in the current recovery episode
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

//====================================================================
// PER-BAR & FLAT-TICK PERFORMANCE CACHE (zero behavioral change)
//====================================================================
#define PERF_MA_CACHE_SHIFTS 16
#define PERF_ATR_CACHE_SHIFTS 4
datetime g_perf_cache_bar0 = 0;
bool     g_ma_fast_ok[TF_COUNT][PERF_MA_CACHE_SHIFTS];
double   g_ma_fast_val[TF_COUNT][PERF_MA_CACHE_SHIFTS];
bool     g_ma_slow_ok[TF_COUNT][PERF_MA_CACHE_SHIFTS];
double   g_ma_slow_val[TF_COUNT][PERF_MA_CACHE_SHIFTS];
bool     g_atr_cache_ok[PERF_ATR_CACHE_SHIFTS];
double   g_atr_cache_val[PERF_ATR_CACHE_SHIFTS];
bool     g_m1_bar1_ok = false;
MqlRates g_m1_bar1;
bool     g_cached_buy_valid = false;
bool     g_cached_sell_valid = false;
string   g_cached_buy_tag = "";
string   g_cached_sell_tag = "";
bool     g_flat_cleanup_done = false;

void EnsurePerBarCache()
{
   const datetime bar0=iTime(_Symbol,PERIOD_M5,0);
   if(bar0<=0 || bar0==g_perf_cache_bar0) return;
   g_perf_cache_bar0=bar0;
   ArrayInitialize(g_ma_fast_ok,false);
   ArrayInitialize(g_ma_slow_ok,false);
   ArrayInitialize(g_atr_cache_ok,false);
   g_m1_bar1_ok=false;
   g_cached_buy_valid=false;
   g_cached_sell_valid=false;
   g_cached_buy_tag="";
   g_cached_sell_tag="";
}

// Quiet data reads, also safe while higher-timeframe history is loading.
// Function: TryReadMA - Read an SMA sample without log spam while history is still loading.
bool TryReadMA(const int handle,const int shift,double &value)
{
   if(handle==INVALID_HANDLE || shift<0)
      return false;

   int cache_tf=-1;
   bool cache_is_fast=false;
   if(shift>=1 && shift<PERF_MA_CACHE_SHIFTS)
   {
      EnsurePerBarCache();
      for(int tf=0;tf<TF_COUNT;tf++)
      {
         if(handle==g_fast_ma_handles[tf]) { cache_tf=tf; cache_is_fast=true; break; }
         if(handle==g_slow_ma_handles[tf]) { cache_tf=tf; cache_is_fast=false; break; }
      }
      if(cache_tf>=0)
      {
         if(cache_is_fast && g_ma_fast_ok[cache_tf][shift])
         {
            value=g_ma_fast_val[cache_tf][shift];
            return true;
         }
         if(!cache_is_fast && g_ma_slow_ok[cache_tf][shift])
         {
            value=g_ma_slow_val[cache_tf][shift];
            return true;
         }
      }
   }

   if(BarsCalculated(handle)<MathMax(FastMAPeriod,SlowMAPeriod)+shift)
      return false;

   double sample[1];
   if(CopyBuffer(handle,0,shift,1,sample)!=1)
      return false;
   if(!MathIsValidNumber(sample[0]) || sample[0]==EMPTY_VALUE)
      return false;
   value=sample[0];
   if(cache_tf>=0)
   {
      if(cache_is_fast) { g_ma_fast_ok[cache_tf][shift]=true; g_ma_fast_val[cache_tf][shift]=value; }
      else              { g_ma_slow_ok[cache_tf][shift]=true; g_ma_slow_val[cache_tf][shift]=value; }
   }
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

// Cached scaled point unit initialized in OnInit() for 2-digit vs 3-digit symbols.
double g_set_point = 0.0;

// Function: InitSetPoint - Detect symbol decimal places (_Digits 2 vs 3) in OnInit()
// and set g_set_point so 3-digit calibrated inputs work on both without input edits.
void InitSetPoint()
{
   if(_Point<=0.0)
      g_set_point=0.0;
   else if(_Digits==2)
      g_set_point=_Point*0.1;
   else
      g_set_point=_Point;
}

// Function: InputPointSize - Return the scaled point unit (initialized in OnInit).
double InputPointSize()
{
   if(g_set_point>0.0) return g_set_point;
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
   bool require_mtfs=((UseMTFTrendEntryFilter && NewORIsolatedEntry!=33 && NewORIsolatedEntry!=34 && NewORIsolatedEntry!=35 && NewORIsolatedEntry!=36) ||
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
   if(g_entry_quality_atr_handle==INVALID_HANDLE || shift<1)
      return false;
   if(shift<PERF_ATR_CACHE_SHIFTS)
   {
      EnsurePerBarCache();
      if(g_atr_cache_ok[shift])
      {
         atr=g_atr_cache_val[shift];
         return true;
      }
   }
   if(BarsCalculated(g_entry_quality_atr_handle)<EntryQualityATRPeriod+shift)
      return false;
   double values[1];
   if(CopyBuffer(g_entry_quality_atr_handle,0,shift,1,values)!=1 ||
      !MathIsValidNumber(values[0]) || values[0]<=0.0)
      return false;
   atr=values[0];
   if(shift<PERF_ATR_CACHE_SHIFTS)
   {
      g_atr_cache_ok[shift]=true;
      g_atr_cache_val[shift]=atr;
   }
   return true;
}

bool PassTPEnergyGate(const IndicatorState &s)
{
   if(!UseTPEnergyRangeGate && !UseTPEnergyATRGate)
      return true;
   if(CountMyPositions()>0)
      return true;
   const double pt=InputPointSize();
   const double tp_dist=(FixedTPPoints>0 && pt>0.0 ? FixedTPPoints*pt : 0.0);
   if(tp_dist<=0.0)
      return true;
   if(UseTPEnergyRangeGate && TPEnergyRangeMultiple>0.0)
   {
      const double rng1=s.high-s.low;
      if(!MathIsValidNumber(rng1) || rng1<tp_dist*TPEnergyRangeMultiple)
         return false;
   }
   if(UseTPEnergyATRGate && TPEnergyATRMultiple>0.0)
   {
      double atr2=0.0;
      if(!ReadEntryQualityATR(2,atr2) || atr2<tp_dist*TPEnergyATRMultiple)
         return false;
   }
   return true;
}

//====================================================================
// BASELINE_003 PURE-PA + INDICATOR ENTRY ORs (101..199)
// Self-contained, zero magic decimal tuning, independent of Global Gates.
//====================================================================
bool B3ORAnyEnabled()
{
   return (UseB3_01_SMA8LaunchEngulf || UseB3_02_OutsideSweepCont || UseB3_03_InsideBarBreakout || UseB3_04_PinbarRejSMA8 ||
           UseB3_05_Donchian10BO || UseB3_06_BollingerBO || UseB3_07_MACDHistTurn || UseB3_08_KeltnerBO ||
           UseB3_09_RSIHookReclaim || UseB3_10_TwoBarPBReclaim || UseB3_11_SnapSMA8 || UseB3_12_TrendPinbar ||
           UseB3_15_Aroon14Imp || UseB3_18_PB1TouchSMA8 || UseB3_19_RSI2Snapback || UseB3_20_SMA20Bounce ||
           UseB3_23_CoolingATR || UseB3_25_CCI200Power || UseB3_27_TightBarCont || UseB3_30_GiantBarFollow ||
           UseB3_31_InsideCloseMom || UseB3_32_SMA12Bounce || UseB3_33_FreshM5Cross ||
           UseB3_39_M1OppFlush || UseB3_40_MarubozuOpen || UseB3_41_CounterH4Drive || UseB3_42_ParallelSMAGap ||
            UseB3_43_M15CounterBnc || UseB3_44_BalancedBodyBO || UseB3_45_ParabolicGlide || UseB3_46_BandLaunchSMA12 ||
                         UseB3_48_PrevDayExtremeBreak || UseB3_49_FiveBarStructureBreak ||
             UseB3_50_NineteenBarStructureBreak || UseB3_51_ThreeBarThrust || UseB3_53_DeepPullbackHold || UseB3_56_BodyExpansion3 || UseB3_65_ChainTwoBarBreak || UseB3_80_BreakRetest);
}

bool B3ORIsEnabled(const int id)
{
   switch(id)
   {
      case 101: return UseB3_01_SMA8LaunchEngulf;
      case 102: return UseB3_02_OutsideSweepCont;
      case 103: return UseB3_03_InsideBarBreakout;
      case 104: return UseB3_04_PinbarRejSMA8;
      case 105: return UseB3_05_Donchian10BO;
      case 106: return UseB3_06_BollingerBO;
      case 107: return UseB3_07_MACDHistTurn;
      case 108: return UseB3_08_KeltnerBO;
      case 109: return UseB3_09_RSIHookReclaim;
      case 110: return UseB3_10_TwoBarPBReclaim;
      case 111: return UseB3_11_SnapSMA8;
      case 112: return UseB3_12_TrendPinbar;
      case 115: return UseB3_15_Aroon14Imp;
      case 118: return UseB3_18_PB1TouchSMA8;
      case 119: return UseB3_19_RSI2Snapback;
      case 120: return UseB3_20_SMA20Bounce;
      case 123: return UseB3_23_CoolingATR;
      case 125: return UseB3_25_CCI200Power;
      case 127: return UseB3_27_TightBarCont;
      case 130: return UseB3_30_GiantBarFollow;
      case 131: return UseB3_31_InsideCloseMom;
      case 132: return UseB3_32_SMA12Bounce;
      case 133: return UseB3_33_FreshM5Cross;
      case 139: return UseB3_39_M1OppFlush;
      case 140: return UseB3_40_MarubozuOpen;
      case 141: return UseB3_41_CounterH4Drive;
      case 142: return UseB3_42_ParallelSMAGap;
      case 143: return UseB3_43_M15CounterBnc;
      case 144: return UseB3_44_BalancedBodyBO;
      case 145: return UseB3_45_ParabolicGlide;
      case 146: return UseB3_46_BandLaunchSMA12;
      case 148: return UseB3_48_PrevDayExtremeBreak;
      case 149: return UseB3_49_FiveBarStructureBreak;
      case 150: return UseB3_50_NineteenBarStructureBreak;
      case 151: return UseB3_51_ThreeBarThrust;
      case 153: return UseB3_53_DeepPullbackHold;
      case 156: return UseB3_56_BodyExpansion3;
      case 165: return UseB3_65_ChainTwoBarBreak;
      case 180: return UseB3_80_BreakRetest;
   }
   return false;
}

string B3ORTag(const int id)
{
   switch(id)
   {
      case 101: return "B3_01_SMA8_ENG";
      case 102: return "B3_02_OUTSIDE";
      case 103: return "B3_03_INSIDE_BO";
      case 104: return "B3_04_PIN_SMA8";
      case 105: return "B3_05_DONCH10";
      case 106: return "B3_06_BB20_BO";
      case 107: return "B3_07_MACD_TURN";
      case 108: return "B3_08_KC_BO";
      case 109: return "B3_09_RSI_HOOK";
      case 110: return "B3_10_PB2_REC";
      case 111: return "B3_11_SNAP_SMA8";
      case 112: return "B3_12_PIN_TREND";
      case 115: return "B3_15_AROON14";
      case 118: return "B3_18_PB1_T8";
      case 119: return "B3_19_RSI2_SNAP";
      case 120: return "B3_20_SMA20_BNC";
      case 123: return "B3_23_COOL_ATR";
      case 125: return "B3_25_CCI200_PWR";
      case 127: return "B3_27_TIGHT_CONT";
      case 130: return "B3_30_GIANT_BAR";
      case 131: return "B3_31_IN_CL_MOM";
      case 132: return "B3_32_SMA12_BNC";
      case 133: return "B3_33_M5_CROSS";
      case 139: return "B3_39_M1_FLUSH";
      case 140: return "B3_40_MARU_OPEN";
      case 141: return "B3_41_CNTR_H4";
      case 142: return "B3_42_PAR_SMA";
      case 143: return "B3_43_M15_BNC";
      case 144: return "B3_44_BAL_BODY";
      case 145: return "B3_45_PARA_GLD";
      case 146: return "B3_46_BAND_LCH";
      case 148: return "B3_48_PREVDAY_BRK";
      case 149: return "B3_49_N5_BRK";
      case 150: return "B3_50_N19_BRK";
      case 151: return "B3_51_3BAR_THRUST";
      case 153: return "B3_53_DEEP_PULLBACK";
      case 156: return "B3_56_BODY_X3";
      case 165: return "B3_65_CHAIN_2BRK";
      case 180: return "B3_80_BRK_RETEST";
   }
   return "UNKNOWN";
}

int g_b3_macd_handle=INVALID_HANDLE;

bool ReadB3MACD3(double &m1,double &h1_out,double &h2_out,double &h3_out)
{
   if(g_b3_macd_handle==INVALID_HANDLE)
      g_b3_macd_handle=iMACD(_Symbol,PERIOD_M5,12,26,9,PRICE_CLOSE);
   if(g_b3_macd_handle==INVALID_HANDLE) return false;
   double main_b[3],sig_b[3];
   if(CopyBuffer(g_b3_macd_handle,0,1,3,main_b)!=3 || CopyBuffer(g_b3_macd_handle,1,1,3,sig_b)!=3)
      return false;
   // CopyBuffer with non-series default: index 2 = shift 1 (newest closed), index 1 = shift 2, index 0 = shift 3
   if(!MathIsValidNumber(main_b[2]) || !MathIsValidNumber(sig_b[2]) ||
      !MathIsValidNumber(main_b[1]) || !MathIsValidNumber(sig_b[1]) ||
      !MathIsValidNumber(main_b[0]) || !MathIsValidNumber(sig_b[0]))
      return false;
   m1=main_b[2];
   h1_out=main_b[2]-sig_b[2];
   h2_out=main_b[1]-sig_b[1];
   h3_out=main_b[0]-sig_b[0];
   return true;
}

bool PassB3M1Color(const bool want_buy)
{
   const datetime m5_bar0=iTime(_Symbol,PERIOD_M5,0);
   if(m5_bar0<=0) return false;
   if(!g_m1_bar1_ok)
   {
      MqlRates m1[1];
      if(CopyRates(_Symbol,PERIOD_M1,1,1,m1)!=1) return false;
      if(m1[0].time>=m5_bar0 || !MathIsValidNumber(m1[0].open) || !MathIsValidNumber(m1[0].close))
         return false;
      g_m1_bar1=m1[0];
      g_m1_bar1_ok=true;
   }
   return (want_buy ? (g_m1_bar1.close>g_m1_bar1.open) : (g_m1_bar1.close<g_m1_bar1.open));
}

bool ComputeB3CCI20(const IndicatorState &s,double &cci_out)
{
   double tp[20],sum_tp=0.0;
   for(int k=0;k<20;k++)
   {
      const double hk=s.ohlcv_high[k],lk=s.ohlcv_low[k],ck=s.ohlcv_close[k];
      if(!MathIsValidNumber(hk) || !MathIsValidNumber(lk) || !MathIsValidNumber(ck))
         return false;
      tp[k]=(hk+lk+ck)/3.0;
      sum_tp+=tp[k];
   }
   const double mean_tp=sum_tp/20.0;
   double md=0.0;
   for(int k=0;k<20;k++) md+=MathAbs(tp[k]-mean_tp);
   md/=20.0;
   cci_out=(md>0.0 ? (tp[0]-mean_tp)/(0.015*md) : 0.0);
   return true;
}

bool ComputeB3RSI14At(const IndicatorState &s,const int start_idx,double &rsi_out)
{
   if(start_idx<0 || start_idx+14>=OHLCV_HISTORY) return false;
   double gains=0.0,losses=0.0;
   for(int k=start_idx;k<start_idx+14;k++)
   {
      const double c_cur=s.ohlcv_close[k],c_prev=s.ohlcv_close[k+1];
      if(!MathIsValidNumber(c_cur) || !MathIsValidNumber(c_prev)) return false;
      const double d=c_cur-c_prev;
      if(d>0.0) gains+=d;
      else losses-=d;
   }
   rsi_out=(losses<=0.0 ? 100.0 : 100.0-100.0/(1.0+gains/losses));
   return true;
}

bool ComputeB3RSI14(const IndicatorState &s,double &rsi_out)
{
   return ComputeB3RSI14At(s,0,rsi_out);
}

bool PassB3OREntry(const IndicatorState &s,const bool want_buy,const int id)
{
   if(!B3ORIsEnabled(id)) return false;
   if(!AllowConcurrentORPositions && CountMyPositions()>0) return false;
   // v3.58: with concurrency enabled only one position PER DIRECTION is allowed, so a second
   // same-direction entry (which is chasing an already-running move) is still refused.
   if(AllowConcurrentORPositions &&
      CountMyPositionsByType(want_buy ? POSITION_TYPE_BUY : POSITION_TYPE_SELL)>0) return false;
   const double o1=s.ohlcv_open[0],h1=s.ohlcv_high[0],l1=s.ohlcv_low[0],c1=s.ohlcv_close[0];
   const double o2=s.ohlcv_open[1],h2=s.ohlcv_high[1],l2=s.ohlcv_low[1],c2=s.ohlcv_close[1];
   if(!MathIsValidNumber(o1) || !MathIsValidNumber(h1) || !MathIsValidNumber(l1) || !MathIsValidNumber(c1) ||
      !MathIsValidNumber(o2) || !MathIsValidNumber(h2) || !MathIsValidNumber(l2) || !MathIsValidNumber(c2))
      return false;

   if(id==101) // B3_01: SMA8 Launch Engulfing (Pure-PA + M5/M15/H1 SMA8/12 Expanding + CCI20 + ATR14 + M1)
   {
      const double h3=s.ohlcv_high[2],l3=s.ohlcv_low[2];
      if(!MathIsValidNumber(h3) || !MathIsValidNumber(l3))
         return false;
      // 1. Pure-PA 2-bar pullback engulfing: [2] opposite pullback, [1] trend engulfing beyond [2]
      if(want_buy ? !(c2<o2 && c1>o1 && c1>h2)
                  : !(c2>o2 && c1<o1 && c1<l2))
         return false;
      // 2. Pure-PA Body dominance (body > combined wicks), 3-bar Range expansion & Volume expansion
      const double rng1=h1-l1, rng2=h2-l2, rng3=h3-l3;
      const double body1=MathAbs(c1-o1);
      if(rng1<=0.0 || body1<=(rng1-body1) || rng1<=rng2 || rng1<=rng3)
         return false;
      if(s.ohlcv_volume[0]<=s.ohlcv_volume[1])
         return false;
      // 3. Indicator: M5 SMA8/12 rising, gap expanding, and Launch off SMA8[1]
      double f1=0.0,s1=0.0,f2=0.0,s2=0.0;
      if(!TryReadMA(g_fast_ma_handles[0],1,f1) || !TryReadMA(g_slow_ma_handles[0],1,s1) ||
         !TryReadMA(g_fast_ma_handles[0],2,f2) || !TryReadMA(g_slow_ma_handles[0],2,s2))
         return false;
      if(want_buy ? !(f1>s1 && f1>f2 && (f1-s1)>(f2-s2) && l1<=f1 && c1>f1)
                  : !(f1<s1 && f1<f2 && (s1-f1)>(s2-f2) && h1>=f1 && c1<f1))
         return false;
      // 4. Indicator: M15 & H1 SMA8/12 trend alignment
      double m15_f=0.0,m15_s=0.0,h1_f=0.0,h1_s=0.0;
      if(!TryReadMA(g_fast_ma_handles[1],1,m15_f) || !TryReadMA(g_slow_ma_handles[1],1,m15_s) ||
         !TryReadMA(g_fast_ma_handles[3],1,h1_f)  || !TryReadMA(g_slow_ma_handles[3],1,h1_s))
         return false;
      if(want_buy ? !(m15_f>m15_s && h1_f>h1_s) : !(m15_f<m15_s && h1_f<h1_s))
         return false;
      // 5. Indicator: Healthy rising volatility (ATR14[1]>ATR14[2] and 1x ATR < Range[1] < 3x ATR)
      double atr1=0.0,atr2=0.0;
      if(!ReadEntryQualityATR(1,atr1) || !ReadEntryQualityATR(2,atr2) ||
         atr1<=atr2 || rng1<=atr2 || rng1>=3.0*atr2)
         return false;
      // 6. Indicator: Textbook CCI(20) momentum zone (+100..+200 BUY / -200..-100 SELL, skip extreme exhaustion)
      double tp[20],sum_tp=0.0;
      for(int k=0;k<20;k++)
      {
         const double hk=s.ohlcv_high[k],lk=s.ohlcv_low[k],ck=s.ohlcv_close[k];
         if(!MathIsValidNumber(hk) || !MathIsValidNumber(lk) || !MathIsValidNumber(ck))
            return false;
         tp[k]=(hk+lk+ck)/3.0;
         sum_tp+=tp[k];
      }
      const double mean_tp=sum_tp/20.0;
      double md=0.0;
      for(int k=0;k<20;k++) md+=MathAbs(tp[k]-mean_tp);
      md/=20.0;
      const double cci1=(md>0.0 ? (tp[0]-mean_tp)/(0.015*md) : 0.0);
      if(want_buy ? !(cci1>100.0 && cci1<200.0) : !(cci1<-100.0 && cci1>-200.0))
         return false;
      // 7. Pure-PA M1 entry timing: last closed M1 candle aligned with direction
      const datetime m5_bar0=iTime(_Symbol,PERIOD_M5,0);
      if(m5_bar0<=0) return false;
      if(!g_m1_bar1_ok)
      {
         MqlRates m1[1];
         if(CopyRates(_Symbol,PERIOD_M1,1,1,m1)!=1) return false;
         if(m1[0].time>=m5_bar0 || !MathIsValidNumber(m1[0].open) || !MathIsValidNumber(m1[0].close))
            return false;
         g_m1_bar1=m1[0];
         g_m1_bar1_ok=true;
      }
      if(want_buy ? (g_m1_bar1.close<=g_m1_bar1.open) : (g_m1_bar1.close>=g_m1_bar1.open))
         return false;
      return true;
   }
   if(id==102) // B3_02: Outside Bar Liquidity Sweep Continuation (Pure-PA + M5/M15/H1 SMA8/12 Expanding + ATR14 + M1)
   {
      const double h3=s.ohlcv_high[2],l3=s.ohlcv_low[2];
      if(!MathIsValidNumber(h3) || !MathIsValidNumber(l3))
         return false;
      // 1. Pure-PA Outside Bar Sweep + 3-bar breakout: sweeps opposite extreme of [2] and closes beyond [2] & [3]
      if(want_buy ? !(c1>o1 && l1<l2 && c1>h2 && c1>h3)
                  : !(c1<o1 && h1>h2 && c1<l2 && c1<l3))
         return false;
      // 2. Pure-PA Body dominance, 3-bar Range expansion & Volume expansion
      const double rng1=h1-l1, rng2=h2-l2, rng3=h3-l3;
      const double body1=MathAbs(c1-o1);
      if(rng1<=0.0 || body1<=(rng1-body1) || rng1<=rng2 || rng1<=rng3)
         return false;
      if(s.ohlcv_volume[0]<=s.ohlcv_volume[1])
         return false;
      // 3. Indicator: M5 SMA8/12 rising, gap expanding, aligned with SMA20[1] & Close[1] on trend side
      double f1=0.0,s1=0.0,f2=0.0,s2=0.0;
      if(!TryReadMA(g_fast_ma_handles[0],1,f1) || !TryReadMA(g_slow_ma_handles[0],1,s1) ||
         !TryReadMA(g_fast_ma_handles[0],2,f2) || !TryReadMA(g_slow_ma_handles[0],2,s2))
         return false;
      double sum20=0.0;
      for(int k=0;k<20;k++)
      {
         if(!MathIsValidNumber(s.ohlcv_close[k])) return false;
         sum20+=s.ohlcv_close[k];
      }
      const double sma20=sum20/20.0;
      if(want_buy ? !(f1>s1 && f1>f2 && (f1-s1)>(f2-s2) && c1>f1 && f1>sma20 && c1>sma20)
                  : !(f1<s1 && f1<f2 && (s1-f1)>(s2-f2) && c1<f1 && f1<sma20 && c1<sma20))
         return false;
      // 4. Indicator: M15 & H1 SMA8/12 trend alignment
      double m15_f=0.0,m15_s=0.0,h1_f=0.0,h1_s=0.0;
      if(!TryReadMA(g_fast_ma_handles[1],1,m15_f) || !TryReadMA(g_slow_ma_handles[1],1,m15_s) ||
         !TryReadMA(g_fast_ma_handles[3],1,h1_f)  || !TryReadMA(g_slow_ma_handles[3],1,h1_s))
         return false;
      if(want_buy ? !(m15_f>m15_s && h1_f>h1_s) : !(m15_f<m15_s && h1_f<h1_s))
         return false;
      // 5. Indicator: Healthy rising volatility (ATR14[1]>ATR14[2], 1x ATR < Range[1] < 3x ATR)
      double atr1=0.0,atr2=0.0;
      if(!ReadEntryQualityATR(1,atr1) || !ReadEntryQualityATR(2,atr2) ||
         atr1<=atr2 || rng1<=atr2 || rng1>=3.0*atr2)
         return false;
      // 6. Pure-PA M1 entry timing
      return PassB3M1Color(want_buy);
   }
   if(id==103) // B3_03: Inside Bar Breakout (Pure-PA Trend Mother + Inclusive Inside + Vol>[2,3] + M5/H1 SMA8/12 + ATR14 + M1)
   {
      const double o3=s.ohlcv_open[2],h3=s.ohlcv_high[2],l3=s.ohlcv_low[2],c3=s.ohlcv_close[2];
      if(!MathIsValidNumber(o3) || !MathIsValidNumber(h3) || !MathIsValidNumber(l3) || !MathIsValidNumber(c3))
         return false;
      // 1. Pure-PA Trend Mother Bar [3] + Inclusive Inside Bar [2] + Breakout Bar [1] closing beyond Mother Bar [3]
      if(!(h2<=h3 && l2>=l3))
         return false;
      if(want_buy ? !(c3>o3 && c1>o1 && c1>h3) : !(c3<o3 && c1<o1 && c1<l3))
         return false;
      // 2. Pure-PA Body dominance, Breakout Range > Mother Bar Range[3], & Breakout Volume > both [2] and [3]
      const double rng1=h1-l1, rng3=h3-l3;
      const double body1=MathAbs(c1-o1);
      if(rng1<=0.0 || body1<=(rng1-body1) || rng1<=rng3)
         return false;
      if(s.ohlcv_volume[0]<=s.ohlcv_volume[1] || s.ohlcv_volume[0]<=s.ohlcv_volume[2])
         return false;
      // 3. Indicator: M5 SMA8/12 rising, aligned with SMA20[1] & Close[1] on trend side
      double f1=0.0,s1=0.0,f2=0.0;
      if(!TryReadMA(g_fast_ma_handles[0],1,f1) || !TryReadMA(g_slow_ma_handles[0],1,s1) ||
         !TryReadMA(g_fast_ma_handles[0],2,f2))
         return false;
      double sum20=0.0;
      for(int k=0;k<20;k++)
      {
         if(!MathIsValidNumber(s.ohlcv_close[k])) return false;
         sum20+=s.ohlcv_close[k];
      }
      const double sma20=sum20/20.0;
      if(want_buy ? !(f1>s1 && f1>f2 && c1>f1 && f1>sma20 && c1>sma20)
                  : !(f1<s1 && f1<f2 && c1<f1 && f1<sma20 && c1<sma20))
         return false;
      // 4. Indicator: H1 SMA8/12 trend alignment
      double h1_f=0.0,h1_s=0.0;
      if(!TryReadMA(g_fast_ma_handles[3],1,h1_f) || !TryReadMA(g_slow_ma_handles[3],1,h1_s))
         return false;
      if(want_buy ? (h1_f<=h1_s) : (h1_f>=h1_s))
         return false;
      // 5. Indicator: Healthy breakout range (1x ATR < Range[1] < 3x ATR)
      double atr2=0.0;
      if(!ReadEntryQualityATR(2,atr2) || rng1<=atr2 || rng1>=3.0*atr2)
         return false;
      // 6. Pure-PA M1 entry timing
      return PassB3M1Color(want_buy);
   }
   if(id==104) // B3_04: Pinbar Wick Rejection off SMA8 (Pure-PA Tail>50% + Wick-Only Reject + M5/M30/H1 SMA8/12 + RSI14 + ATR14 + M1)
   {
      // 1. Pure-PA Pinbar: bullish/neutral close with dominant rejection tail (>50% of total range)
      if(want_buy ? (c1<o1) : (c1>o1))
         return false;
      const double rng1=h1-l1;
      const double tail1=(want_buy ? (o1-l1) : (h1-o1));
      if(rng1<=0.0 || tail1<=(rng1-tail1))
         return false;
      if(s.ohlcv_volume[0]<=s.ohlcv_volume[1])
         return false;
      // 2. Indicator: M5 SMA8/12 both rising & Wick-Only Rejection of SMA8 (Open & Close on trend side, Low/High pierces SMA8)
      double f1=0.0,s1=0.0,f2=0.0,s2=0.0;
      if(!TryReadMA(g_fast_ma_handles[0],1,f1) || !TryReadMA(g_slow_ma_handles[0],1,s1) ||
         !TryReadMA(g_fast_ma_handles[0],2,f2) || !TryReadMA(g_slow_ma_handles[0],2,s2))
         return false;
      if(want_buy ? !(f1>s1 && f1>f2 && s1>s2 && l1<=f1 && o1>=f1 && c1>f1)
                  : !(f1<s1 && f1<f2 && s1<s2 && h1>=f1 && o1<=f1 && c1<f1))
         return false;
      // 3. Indicator: M30 & H1 SMA8/12 trend alignment
      double m30_f=0.0,m30_s=0.0,h1_f=0.0,h1_s=0.0;
      if(!TryReadMA(g_fast_ma_handles[2],1,m30_f) || !TryReadMA(g_slow_ma_handles[2],1,m30_s) ||
         !TryReadMA(g_fast_ma_handles[3],1,h1_f)  || !TryReadMA(g_slow_ma_handles[3],1,h1_s))
         return false;
      if(want_buy ? !(m30_f>m30_s && h1_f>h1_s)
                  : !(m30_f<m30_s && h1_f<h1_s))
         return false;
      // 4. Indicator: Healthy rejection range (1x ATR < Range[1] < 3x ATR) & RSI(14) trend side (>50 BUY / <50 SELL)
      double atr2=0.0,rsi1=50.0;
      if(!ReadEntryQualityATR(2,atr2) || rng1<=atr2 || rng1>=3.0*atr2)
         return false;
      if(!ComputeB3RSI14(s,rsi1) || (want_buy ? (rsi1<=50.0) : (rsi1>=50.0)))
         return false;
      // 5. Pure-PA M1 entry timing
      return PassB3M1Color(want_buy);
   }
   if(id==105) // B3_05: Donchian(10) Channel Breakout (Pure-PA + Donchian10 + M5/M15/H1 SMA8/12 + SMA20 + ATR14 + M1)
   {
      // 1. Fresh Donchian(10) breakout: [1] closes beyond 10-bar channel [2..11], [2] was inside
      if(want_buy ? (c1<=o1) : (c1>=o1))
         return false;
      double hh10=-DBL_MAX,ll10=DBL_MAX;
      for(int k=1;k<=10;k++)
      {
         const double hk=s.ohlcv_high[k],lk=s.ohlcv_low[k];
         if(!MathIsValidNumber(hk) || !MathIsValidNumber(lk)) return false;
         if(hk>hh10) hh10=hk;
         if(lk<ll10) ll10=lk;
      }
      if(want_buy ? !(c1>hh10 && c2<=hh10) : !(c1<ll10 && c2>=ll10))
         return false;
      // 2. Pure-PA Body dominance, Range expansion & Volume expansion
      const double rng1=h1-l1, rng2=h2-l2;
      const double body1=MathAbs(c1-o1);
      if(rng1<=0.0 || body1<=(rng1-body1) || rng1<=rng2)
         return false;
      if(s.ohlcv_volume[0]<=s.ohlcv_volume[1] || s.ohlcv_volume[0]<=s.ohlcv_volume[2])
         return false;
      // 3. Indicator: M5 SMA8/12 both rising & aligned with SMA20[1]
      double f1=0.0,s1=0.0,f2=0.0,s2=0.0;
      if(!TryReadMA(g_fast_ma_handles[0],1,f1) || !TryReadMA(g_slow_ma_handles[0],1,s1) ||
         !TryReadMA(g_fast_ma_handles[0],2,f2) || !TryReadMA(g_slow_ma_handles[0],2,s2))
         return false;
      double sum20=0.0;
      for(int k=0;k<20;k++)
      {
         if(!MathIsValidNumber(s.ohlcv_close[k])) return false;
         sum20+=s.ohlcv_close[k];
      }
      const double sma20=sum20/20.0;
      if(want_buy ? !(f1>s1 && f1>f2 && s1>s2 && o1>=f1 && c1>f1 && f1>sma20)
                  : !(f1<s1 && f1<f2 && s1<s2 && o1<=f1 && c1<f1 && f1<sma20))
         return false;
      // 4. Indicator: M15, H1 & H4 SMA8/12 trend alignment
      double m15_f=0.0,m15_s=0.0,h1_f=0.0,h1_s=0.0,h4_f=0.0,h4_s=0.0;
      if(!TryReadMA(g_fast_ma_handles[1],1,m15_f) || !TryReadMA(g_slow_ma_handles[1],1,m15_s) ||
         !TryReadMA(g_fast_ma_handles[3],1,h1_f)  || !TryReadMA(g_slow_ma_handles[3],1,h1_s)  ||
         !TryReadMA(g_fast_ma_handles[4],1,h4_f)  || !TryReadMA(g_slow_ma_handles[4],1,h4_s))
         return false;
      if(want_buy ? !(m15_f>m15_s && h1_f>h1_s && h4_f>h4_s)
                  : !(m15_f<m15_s && h1_f<h1_s && h4_f<h4_s))
         return false;
      // 5. Indicator: Rising volatility (1x ATR < Range[1] < 2x ATR) & RSI(14) inside 30..70 (no overbought/oversold breakout trap)
      double atr1=0.0,atr2=0.0,rsi1=50.0;
      if(!ReadEntryQualityATR(1,atr1) || !ReadEntryQualityATR(2,atr2) ||
         atr1<=atr2 || rng1<=atr2 || rng1>=2.0*atr2)
         return false;
      if(!ComputeB3RSI14(s,rsi1) || (want_buy ? (rsi1>=70.0) : (rsi1<=30.0)))
         return false;
      // 6. Pure-PA M1 entry timing
      return PassB3M1Color(want_buy);
   }
   if(id==106) // B3_06: Bollinger Band(20,2) Breakout (Pure-PA + BB(20,2) + M5/M15/H1 SMA8/12 + ATR14 + M1)
   {
      if(want_buy ? (c1<=o1) : (c1>=o1))
         return false;
      // 1. Standard Bollinger Band(20,2.0) fresh breakout
      double sum20=0.0;
      for(int k=0;k<20;k++)
      {
         if(!MathIsValidNumber(s.ohlcv_close[k])) return false;
         sum20+=s.ohlcv_close[k];
      }
      const double mean20=sum20/20.0;
      double var20=0.0;
      for(int k=0;k<20;k++) { const double d=s.ohlcv_close[k]-mean20; var20+=d*d; }
      const double sd20=MathSqrt(var20/20.0);
      const double upper_bb=mean20+2.0*sd20, lower_bb=mean20-2.0*sd20;
      if(want_buy ? !(c1>upper_bb && c2<=upper_bb) : !(c1<lower_bb && c2>=lower_bb))
         return false;
      // 2. Pure-PA Body dominance, Range expansion & Volume expansion
      const double rng1=h1-l1, rng2=h2-l2;
      const double body1=MathAbs(c1-o1);
      if(rng1<=0.0 || body1<=(rng1-body1) || rng1<=rng2)
         return false;
      if(s.ohlcv_volume[0]<=s.ohlcv_volume[1])
         return false;
      // 3. Indicator: M5 SMA8/12 both rising & Close[1] on trend side
      double f1=0.0,s1=0.0,f2=0.0,s2=0.0;
      if(!TryReadMA(g_fast_ma_handles[0],1,f1) || !TryReadMA(g_slow_ma_handles[0],1,s1) ||
         !TryReadMA(g_fast_ma_handles[0],2,f2) || !TryReadMA(g_slow_ma_handles[0],2,s2))
         return false;
      if(want_buy ? !(f1>s1 && f1>f2 && s1>s2 && o1>=f1 && c1>f1)
                  : !(f1<s1 && f1<f2 && s1<s2 && o1<=f1 && c1<f1))
         return false;
      // 4. Indicator: M15 & H1 SMA8/12 trend alignment
      double m15_f=0.0,m15_s=0.0,h1_f=0.0,h1_s=0.0;
      if(!TryReadMA(g_fast_ma_handles[1],1,m15_f) || !TryReadMA(g_slow_ma_handles[1],1,m15_s) ||
         !TryReadMA(g_fast_ma_handles[3],1,h1_f)  || !TryReadMA(g_slow_ma_handles[3],1,h1_s))
         return false;
      if(want_buy ? !(m15_f>m15_s && h1_f>h1_s) : !(m15_f<m15_s && h1_f<h1_s))
         return false;
      // 5. Indicator: Rising volatility (1x..3x ATR), RSI(14) 30..70 & CCI(20) not extreme (<200 / >-200)
      double atr1=0.0,atr2=0.0,rsi1=50.0,cci1=0.0;
      if(!ReadEntryQualityATR(1,atr1) || !ReadEntryQualityATR(2,atr2) ||
         atr1<=atr2 || rng1<=atr2 || rng1>=3.0*atr2)
         return false;
      if(!ComputeB3RSI14(s,rsi1) || (want_buy ? (rsi1>=70.0) : (rsi1<=30.0)))
         return false;
      if(!ComputeB3CCI20(s,cci1) || (want_buy ? (cci1>=200.0) : (cci1<=-200.0)))
         return false;
      // 6. Pure-PA M1 entry timing
      return PassB3M1Color(want_buy);
   }
   if(id==107) // B3_07: MACD(12,26,9) Histogram Acceleration (Pure-PA Break + MACD Main>0 & Hist>0 Expanding + M5/M15/H1 SMA8/12 + ATR14 + RSI14 + M1)
   {
      const double h3=s.ohlcv_high[2],l3=s.ohlcv_low[2];
      if(!MathIsValidNumber(h3) || !MathIsValidNumber(l3))
         return false;
      // 1. Pure-PA impulse [1] breaking [2] & [3] with Body dominance, Range & 2-bar Volume Surge
      if(want_buy ? !(c1>o1 && c1>h2 && c1>h3)
                  : !(c1<o1 && c1<l2 && c1<l3))
         return false;
      const double rng1=h1-l1, rng2=h2-l2;
      const double body1=MathAbs(c1-o1);
      if(rng1<=0.0 || body1<=(rng1-body1) || rng1<=rng2)
         return false;
      if(s.ohlcv_volume[0]<=s.ohlcv_volume[1] || s.ohlcv_volume[0]<=s.ohlcv_volume[2])
         return false;
      // 2. Indicator: Standard MACD(12,26,9) above zero & positive histogram accelerating
      double m1=0.0,mh1=0.0,mh2=0.0,mh3=0.0;
      if(!ReadB3MACD3(m1,mh1,mh2,mh3))
         return false;
      if(want_buy ? !(m1>0.0 && mh1>0.0 && mh1>mh2)
                  : !(m1<0.0 && mh1<0.0 && mh1<mh2))
         return false;
      // 3. Indicator: M5 SMA8/12 both rising & Open[1]/Close[1] on trend side of SMA8[1]
      double f1=0.0,s1=0.0,f2=0.0,s2=0.0;
      if(!TryReadMA(g_fast_ma_handles[0],1,f1) || !TryReadMA(g_slow_ma_handles[0],1,s1) ||
         !TryReadMA(g_fast_ma_handles[0],2,f2) || !TryReadMA(g_slow_ma_handles[0],2,s2))
         return false;
      if(want_buy ? !(f1>s1 && f1>f2 && s1>s2 && o1>=f1 && c1>f1)
                  : !(f1<s1 && f1<f2 && s1<s2 && o1<=f1 && c1<f1))
         return false;
      // 4. Indicator: M15, M30 & H1 SMA8/12 trend alignment
      double m15_f=0.0,m15_s=0.0,m30_f=0.0,m30_s=0.0,h1_f=0.0,h1_s=0.0;
      if(!TryReadMA(g_fast_ma_handles[1],1,m15_f) || !TryReadMA(g_slow_ma_handles[1],1,m15_s) ||
         !TryReadMA(g_fast_ma_handles[2],1,m30_f) || !TryReadMA(g_slow_ma_handles[2],1,m30_s) ||
         !TryReadMA(g_fast_ma_handles[3],1,h1_f)  || !TryReadMA(g_slow_ma_handles[3],1,h1_s))
         return false;
      if(want_buy ? !(m15_f>m15_s && m30_f>m30_s && h1_f>h1_s)
                  : !(m15_f<m15_s && m30_f<m30_s && h1_f<h1_s))
         return false;
      // 5. Indicator: Rising volatility (1x..2x ATR) & RSI(14) 30..70 (no overbought/oversold trap)
      double atr1=0.0,atr2=0.0,rsi1=50.0;
      if(!ReadEntryQualityATR(1,atr1) || !ReadEntryQualityATR(2,atr2) ||
         atr1<=atr2 || rng1<=atr2 || rng1>=2.0*atr2)
         return false;
      if(!ComputeB3RSI14(s,rsi1) || (want_buy ? (rsi1>=70.0) : (rsi1<=30.0)))
         return false;
      // 6. Pure-PA M1 entry timing
      return PassB3M1Color(want_buy);
   }
   if(id==108) // B3_08: Keltner Channel(20, 1*ATR) Breakout (Pure-PA + KC + M5/M15/H1 SMA8/12 + ATR14 + M1)
   {
      if(want_buy ? (c1<=o1) : (c1>=o1))
         return false;
      // 1. Fresh Keltner Channel(20, 1*ATR14) breakout
      double atr2=0.0;
      if(!ReadEntryQualityATR(2,atr2) || atr2<=0.0)
         return false;
      double sum20=0.0;
      for(int k=0;k<20;k++)
      {
         if(!MathIsValidNumber(s.ohlcv_close[k])) return false;
         sum20+=s.ohlcv_close[k];
      }
      const double sma20=sum20/20.0;
      const double upper_kc=sma20+atr2, lower_kc=sma20-atr2;
      if(want_buy ? !(c1>upper_kc && c2<=upper_kc) : !(c1<lower_kc && c2>=lower_kc))
         return false;
      // 2. Pure-PA Body dominance, Range expansion & 3-bar Volume Surge (Vol[1] > max(Vol[2..4]))
      const double rng1=h1-l1, rng2=h2-l2;
      const double body1=MathAbs(c1-o1);
      if(rng1<=0.0 || body1<=(rng1-body1) || rng1<=rng2 || rng1<=atr2 || rng1>=3.0*atr2)
         return false;
      if(s.ohlcv_volume[0]<=s.ohlcv_volume[1] || s.ohlcv_volume[0]<=s.ohlcv_volume[2] || s.ohlcv_volume[0]<=s.ohlcv_volume[3])
         return false;
      // 3. Indicator: M5 SMA8/12 established 2-bar trend, rising & Open[1]/Close[1] on trend side of SMA8[1]
      double f1=0.0,s1=0.0,f2=0.0,s2=0.0;
      if(!TryReadMA(g_fast_ma_handles[0],1,f1) || !TryReadMA(g_slow_ma_handles[0],1,s1) ||
         !TryReadMA(g_fast_ma_handles[0],2,f2) || !TryReadMA(g_slow_ma_handles[0],2,s2))
         return false;
      if(want_buy ? !(f1>s1 && f2>s2 && f1>f2 && o1>=f1 && c1>f1)
                  : !(f1<s1 && f2<s2 && f1<f2 && o1<=f1 && c1<f1))
         return false;
      // 4. Indicator: M15, M30 & H1 SMA8/12 trend alignment
      double m15_f=0.0,m15_s=0.0,m30_f=0.0,m30_s=0.0,h1_f=0.0,h1_s=0.0;
      if(!TryReadMA(g_fast_ma_handles[1],1,m15_f) || !TryReadMA(g_slow_ma_handles[1],1,m15_s) ||
         !TryReadMA(g_fast_ma_handles[2],1,m30_f) || !TryReadMA(g_slow_ma_handles[2],1,m30_s) ||
         !TryReadMA(g_fast_ma_handles[3],1,h1_f)  || !TryReadMA(g_slow_ma_handles[3],1,h1_s))
         return false;
      if(want_buy ? !(m15_f>m15_s && m30_f>m30_s && h1_f>h1_s)
                  : !(m15_f<m15_s && m30_f<m30_s && h1_f<h1_s))
         return false;
      // 5. Pure-PA M1 entry timing
      return PassB3M1Color(want_buy);
   }
   if(id==109) // B3_09: RSI(14) Pullback Hook Reclaim (Pure-PA Break + RSI14 Hook + Vol>[2,3] + M5/M15/H1/H4 SMA8/12 + ATR14 + M1)
   {
      // 1. Pure-PA trend close breaking [2], Body dominance & 2-bar Volume Surge
      if(want_buy ? !(c1>o1 && c1>h2) : !(c1<o1 && c1<l2))
         return false;
      const double rng1=h1-l1;
      const double body1=MathAbs(c1-o1);
      if(rng1<=0.0 || body1<=(rng1-body1))
         return false;
      if(s.ohlcv_volume[0]<=s.ohlcv_volume[1] || s.ohlcv_volume[0]<=s.ohlcv_volume[2])
         return false;
      // 2. Indicator: Standard RSI(14) pullback hook (dipped on [2], hooks back on [1] inside 50..70 / 30..50)
      double r1=50.0,r2=50.0,r3=50.0;
      if(!ComputeB3RSI14At(s,0,r1) || !ComputeB3RSI14At(s,1,r2) || !ComputeB3RSI14At(s,2,r3))
         return false;
      if(want_buy ? !(r2<r3 && r1>r2 && r1>50.0 && r1<70.0)
                  : !(r2>r3 && r1<r2 && r1<50.0 && r1>30.0))
         return false;
      // 3. Indicator: M5 SMA8/12 rising & Close[1] on trend side
      double f1=0.0,s1=0.0,f2=0.0;
      if(!TryReadMA(g_fast_ma_handles[0],1,f1) || !TryReadMA(g_slow_ma_handles[0],1,s1) ||
         !TryReadMA(g_fast_ma_handles[0],2,f2))
         return false;
      if(want_buy ? !(f1>s1 && f1>f2 && c1>f1)
                  : !(f1<s1 && f1<f2 && c1<f1))
         return false;
      // 4. Indicator: M15, H1 & H4 SMA8/12 trend alignment
      double m15_f=0.0,m15_s=0.0,h1_f=0.0,h1_s=0.0,h4_f=0.0,h4_s=0.0;
      if(!TryReadMA(g_fast_ma_handles[1],1,m15_f) || !TryReadMA(g_slow_ma_handles[1],1,m15_s) ||
         !TryReadMA(g_fast_ma_handles[3],1,h1_f)  || !TryReadMA(g_slow_ma_handles[3],1,h1_s)  ||
         !TryReadMA(g_fast_ma_handles[4],1,h4_f)  || !TryReadMA(g_slow_ma_handles[4],1,h4_s))
         return false;
      if(want_buy ? !(m15_f>m15_s && h1_f>h1_s && h4_f>h4_s)
                  : !(m15_f<m15_s && h1_f<h1_s && h4_f<h4_s))
         return false;
      // 5. Indicator: Healthy non-exhausted range (1x ATR < Range[1] < 2x ATR)
      double atr2=0.0;
      if(!ReadEntryQualityATR(2,atr2) || rng1<=atr2 || rng1>=2.0*atr2)
         return false;
      // 6. Pure-PA M1 entry timing
      return PassB3M1Color(want_buy);
   }
   if(id==110) // B3_10: 2-Bar Pullback Reclaim (Pure-PA [3],[2] Opp -> [1] Break [2]&[3] + M5/M15/M30/H1 SMA8/12 + CCI20 + RSI14 + ATR14 + M1)
   {
      const double o3=s.ohlcv_open[2],h3=s.ohlcv_high[2],l3=s.ohlcv_low[2],c3=s.ohlcv_close[2];
      if(!MathIsValidNumber(o3) || !MathIsValidNumber(h3) || !MathIsValidNumber(l3) || !MathIsValidNumber(c3))
         return false;
      // 1. Pure-PA 2-bar pullback [3],[2] opposite -> [1] trend reclaim breaking [2] & [3]
      if(want_buy ? !(c3<o3 && c2<o2 && c1>o1 && c1>h2 && c1>h3)
                  : !(c3>o3 && c2>o2 && c1<o1 && c1<l2 && c1<l3))
         return false;
      // 2. Pure-PA Body dominance & Volume expansion
      const double rng1=h1-l1;
      const double body1=MathAbs(c1-o1);
      if(rng1<=0.0 || body1<=(rng1-body1))
         return false;
      if(s.ohlcv_volume[0]<=s.ohlcv_volume[1])
         return false;
      // 3. Indicator: M5 SMA8/12 aligned & Close[1] on trend side
      double f1=0.0,s1=0.0;
      if(!TryReadMA(g_fast_ma_handles[0],1,f1) || !TryReadMA(g_slow_ma_handles[0],1,s1))
         return false;
      if(want_buy ? !(f1>s1 && c1>f1) : !(f1<s1 && c1<f1))
         return false;
      // 4. Indicator: M15, M30 & H1 SMA8/12 trend alignment
      double m15_f=0.0,m15_s=0.0,m30_f=0.0,m30_s=0.0,h1_f=0.0,h1_s=0.0;
      if(!TryReadMA(g_fast_ma_handles[1],1,m15_f) || !TryReadMA(g_slow_ma_handles[1],1,m15_s) ||
         !TryReadMA(g_fast_ma_handles[2],1,m30_f) || !TryReadMA(g_slow_ma_handles[2],1,m30_s) ||
         !TryReadMA(g_fast_ma_handles[3],1,h1_f)  || !TryReadMA(g_slow_ma_handles[3],1,h1_s))
         return false;
      if(want_buy ? !(m15_f>m15_s && m30_f>m30_s && h1_f>h1_s)
                  : !(m15_f<m15_s && m30_f<m30_s && h1_f<h1_s))
         return false;
      // 5. Indicator: Healthy range (1x..3x ATR), CCI(20) not extreme (<200 / >-200) & RSI(14) not extreme (20..80)
      double atr2=0.0,cci1=0.0,rsi1=50.0;
      if(!ReadEntryQualityATR(2,atr2) || rng1<=atr2 || rng1>=3.0*atr2)
         return false;
      if(!ComputeB3CCI20(s,cci1) || (want_buy ? (cci1>=200.0) : (cci1<=-200.0)))
         return false;
      if(!ComputeB3RSI14(s,rsi1) || (want_buy ? (rsi1>=80.0) : (rsi1<=20.0)))
         return false;
      // 6. Pure-PA M1 entry timing
      return PassB3M1Color(want_buy);
   }
   if(id==111) // B3_11: SMA8 Snap-Back Reclaim (Zero-decimal Pure-PA + SMA8/12 Gap Exp + M15/H1 + ATR14 + M1)
   {
      // 1. Active session only (skip dead rollover 20:00..02:59)
      MqlDateTime dt111;
      const datetime b0=iTime(_Symbol,PERIOD_M5,0);
      if(b0<=0 || !TimeToStruct(b0,dt111) || dt111.hour<3 || dt111.hour>19)
         return false;
      // 2. Pure-PA: [2] opposite candle, [1] strong snap-back (Body > 2*Wicks, breaks [2], Vol[1]>Vol[2])
      const double rng1=h1-l1, body1=MathAbs(c1-o1);
      if(rng1<=0.0 || body1<=2.0*(rng1-body1) || s.ohlcv_volume[0]<=s.ohlcv_volume[1])
         return false;
      if(want_buy ? !(c2<o2 && c1>o1 && c1>h2)
                  : !(c2>o2 && c1<o1 && c1<l2))
         return false;
      // 3. Indicator: [2] closed across SMA8[2], [1] reclaims SMA8[1] with M5 SMA8/12 gap expanding
      double f1=0.0,s1=0.0,f2=0.0,s2=0.0;
      if(!TryReadMA(g_fast_ma_handles[0],1,f1) || !TryReadMA(g_slow_ma_handles[0],1,s1) ||
         !TryReadMA(g_fast_ma_handles[0],2,f2) || !TryReadMA(g_slow_ma_handles[0],2,s2))
         return false;
      if(want_buy ? !(f1>s1 && c1>f1 && c2<f2 && (f1-s1)>(f2-s2))
                  : !(f1<s1 && c1<f1 && c2>f2 && (s1-f1)>(s2-f2)))
         return false;
      // 4. Indicator: M15 & H1 SMA8/12 alignment + ATR cap (skip parabolic > 3x ATR)
      double m15_f=0.0,m15_s=0.0,h1_f=0.0,h1_s=0.0,atr2=0.0;
      if(!TryReadMA(g_fast_ma_handles[1],1,m15_f) || !TryReadMA(g_slow_ma_handles[1],1,m15_s) ||
         !TryReadMA(g_fast_ma_handles[3],1,h1_f)  || !TryReadMA(g_slow_ma_handles[3],1,h1_s))
         return false;
      if(want_buy ? !(m15_f>m15_s && h1_f>h1_s) : !(m15_f<m15_s && h1_f<h1_s))
         return false;
      if(!ReadEntryQualityATR(2,atr2) || rng1>=3.0*atr2)
         return false;
      // 5. Pure-PA M1 entry timing
      return PassB3M1Color(want_buy);
   }
   if(id==112) // B3_12: Trend Pinbar Rejection (Open on SMA8 side, Tail>50% rng, Vol>2, M5/M15/M30/H1, ATR 1..3x, RSI>50/<50, M1)
   {
      const double rng1=h1-l1;
      if(rng1<=0.0 || s.ohlcv_volume[0]<=s.ohlcv_volume[1])
         return false;
      const double lower_w=MathMin(o1,c1)-l1, upper_w=h1-MathMax(o1,c1);
      if(want_buy ? !(c1>o1 && lower_w>0.5*rng1) : !(c1<o1 && upper_w>0.5*rng1))
         return false;
      double f1=0.0,s1=0.0,m15_f=0.0,m15_s=0.0,m30_f=0.0,m30_s=0.0,h1_f=0.0,h1_s=0.0,atr2=0.0,rsi1=50.0;
      if(!TryReadMA(g_fast_ma_handles[0],1,f1)    || !TryReadMA(g_slow_ma_handles[0],1,s1) ||
         !TryReadMA(g_fast_ma_handles[1],1,m15_f) || !TryReadMA(g_slow_ma_handles[1],1,m15_s) ||
         !TryReadMA(g_fast_ma_handles[2],1,m30_f) || !TryReadMA(g_slow_ma_handles[2],1,m30_s) ||
         !TryReadMA(g_fast_ma_handles[3],1,h1_f)  || !TryReadMA(g_slow_ma_handles[3],1,h1_s))
         return false;
      if(want_buy ? !(f1>s1 && o1>f1 && m15_f>m15_s && m30_f>m30_s && h1_f>h1_s)
                  : !(f1<s1 && o1<f1 && m15_f<m15_s && m30_f<m30_s && h1_f<h1_s))
         return false;
      if(!ReadEntryQualityATR(2,atr2) || rng1<=atr2 || rng1>=3.0*atr2)
         return false;
      if(!ComputeB3RSI14(s,rsi1) || (want_buy ? (rsi1<=50.0) : (rsi1>=50.0)))
         return false;
      return PassB3M1Color(want_buy);
   }
   if(id==115) // B3_15: Aroon(14) Fresh 100 Impulse (Pure-PA + Aroon14 + M5/M15/H1 + ATR rising 1..2x + RSI 30..70 + M1)
   {
      MqlDateTime dt115;
      const datetime b0=iTime(_Symbol,PERIOD_M5,0);
      if(b0<=0 || !TimeToStruct(b0,dt115) || dt115.hour<3 || dt115.hour>=22)
         return false;
      const double rng1=h1-l1, body1=MathAbs(c1-o1);
      if(rng1<=0.0 || body1<=(rng1-body1) || s.ohlcv_volume[0]<=s.ohlcv_volume[1] || s.ohlcv_volume[0]<=s.ohlcv_volume[2])
         return false;
      if(want_buy ? (c1<=o1) : (c1>=o1))
         return false;
      // Aroon(14) at bar[1] (indices 0..14) and bar[2] (indices 1..15)
      int hi1=0,lo1=0,hi2=1,lo2=1;
      for(int k=1;k<=14;k++)
      {
         if(s.ohlcv_high[k]>s.ohlcv_high[hi1]) hi1=k;
         if(s.ohlcv_low[k]<s.ohlcv_low[lo1])   lo1=k;
      }
      for(int k=2;k<=15;k++)
      {
         if(s.ohlcv_high[k]>s.ohlcv_high[hi2]) hi2=k;
         if(s.ohlcv_low[k]<s.ohlcv_low[lo2])   lo2=k;
      }
      // hi1==0 means AroonUp[1]==100; hi2>1 means AroonUp[2]<100; lo1>7 means AroonDown[1]<50
      if(want_buy ? !(hi1==0 && hi2>1 && lo1>7) : !(lo1==0 && lo2>1 && hi1>7))
         return false;
      const double rng2=h2-l2, rng3=s.ohlcv_high[2]-s.ohlcv_low[2];
      const double lead15=(want_buy ? (h1-c1) : (c1-l1)), tail15=(want_buy ? (o1-l1) : (h1-o1));
      if(rng1<=rng2 || rng1<=rng3 || lead15>=tail15) return false;
      double f1=0.0,s1=0.0,f2=0.0,m15_f=0.0,m15_s=0.0,m30_f=0.0,m30_s=0.0,h1_f=0.0,h1_s=0.0,h4_f=0.0,h4_s=0.0,atr1=0.0,atr2=0.0,rsi1=50.0,cci1=0.0;
      if(!TryReadMA(g_fast_ma_handles[0],1,f1)    || !TryReadMA(g_slow_ma_handles[0],1,s1) ||
         !TryReadMA(g_fast_ma_handles[0],2,f2)    ||
         !TryReadMA(g_fast_ma_handles[1],1,m15_f) || !TryReadMA(g_slow_ma_handles[1],1,m15_s) ||
         !TryReadMA(g_fast_ma_handles[2],1,m30_f) || !TryReadMA(g_slow_ma_handles[2],1,m30_s) ||
         !TryReadMA(g_fast_ma_handles[3],1,h1_f)  || !TryReadMA(g_slow_ma_handles[3],1,h1_s) ||
         !TryReadMA(g_fast_ma_handles[4],1,h4_f)  || !TryReadMA(g_slow_ma_handles[4],1,h4_s))
         return false;
      if(want_buy ? !(f1>s1 && f1>f2 && c1>f1 && m15_f>m15_s && m30_f>m30_s && h1_f>h1_s && h4_f>h4_s)
                  : !(f1<s1 && f1<f2 && c1<f1 && m15_f<m15_s && m30_f<m30_s && h1_f<h1_s && h4_f<h4_s))
         return false;
      if(!ReadEntryQualityATR(1,atr1) || !ReadEntryQualityATR(2,atr2) || atr1<=atr2 || rng1<=atr2 || rng1>=2.0*atr2)
         return false;
      if(!ComputeB3RSI14(s,rsi1) || rsi1<=30.0 || rsi1>=70.0)
         return false;
      if(!ComputeB3CCI20(s,cci1) || (want_buy ? !(cci1>100.0 && cci1<200.0) : !(cci1<-100.0 && cci1>-200.0)))
         return false;
      return PassB3M1Color(want_buy);
   }
   if(id==118) // B3_18: 1-Bar Pullback Touch SMA8 Holding SMA12 (Upgraded HE_PB1_T8: Pure-PA + M5/M15/H1/H4 + ATR<=2x + M1)
   {
      MqlDateTime dt118;
      const datetime b0=iTime(_Symbol,PERIOD_M5,0);
      if(b0<=0 || !TimeToStruct(b0,dt118) || dt118.hour<3 || dt118.hour>=22)
         return false;
      const double rng1=h1-l1, rng2=h2-l2, body1=MathAbs(c1-o1);
      if(rng1<=0.0 || body1<=(rng1-body1) || rng1<=rng2 || s.ohlcv_volume[0]<=s.ohlcv_volume[1])
         return false;
      if(want_buy ? !(c2<o2 && c1>o1 && c1>h2) : !(c2>o2 && c1<o1 && c1<l2))
         return false;
      double f1=0.0,s1=0.0,f2=0.0,s2=0.0,m15_f=0.0,m15_s=0.0,m30_f=0.0,m30_s=0.0,h1_f=0.0,h1_s=0.0,h4_f=0.0,h4_s=0.0,atr1=0.0,atr2=0.0,rsi1=50.0;
      if(!TryReadMA(g_fast_ma_handles[0],1,f1)    || !TryReadMA(g_slow_ma_handles[0],1,s1) ||
         !TryReadMA(g_fast_ma_handles[0],2,f2)    || !TryReadMA(g_slow_ma_handles[0],2,s2) ||
         !TryReadMA(g_fast_ma_handles[1],1,m15_f) || !TryReadMA(g_slow_ma_handles[1],1,m15_s) ||
         !TryReadMA(g_fast_ma_handles[2],1,m30_f) || !TryReadMA(g_slow_ma_handles[2],1,m30_s) ||
         !TryReadMA(g_fast_ma_handles[3],1,h1_f)  || !TryReadMA(g_slow_ma_handles[3],1,h1_s) ||
         !TryReadMA(g_fast_ma_handles[4],1,h4_f)  || !TryReadMA(g_slow_ma_handles[4],1,h4_s))
         return false;
      if(want_buy ? !(f1>s1 && f1>f2 && c1>f1 && l2<=f2 && c2>s2 && m15_f>m15_s && m30_f>m30_s && h1_f>h1_s && h4_f>h4_s)
                  : !(f1<s1 && f1<f2 && c1<f1 && h2>=f2 && c2<s2 && m15_f<m15_s && m30_f<m30_s && h1_f<h1_s && h4_f<h4_s))
         return false;
      if(!ReadEntryQualityATR(1,atr1) || !ReadEntryQualityATR(2,atr2) || atr1<=atr2 || rng1<=atr2 || rng1>2.0*atr2)
         return false;
      if(!ComputeB3RSI14(s,rsi1) || rsi1<=30.0 || rsi1>=70.0)
         return false;
      return PassB3M1Color(want_buy);
   }
   if(id==119) // B3_19: Connors RSI(2) Snapback in Trend (RSI(2)[2]<15/>85, breaks [2], M5/M15/M30/H1, ATR 1..2x, CCI<200, M1)
   {
      MqlDateTime dt119;
      const datetime b0=iTime(_Symbol,PERIOD_M5,0);
      if(b0<=0 || !TimeToStruct(b0,dt119) || dt119.hour<3 || dt119.hour>=22)
         return false;
      const double c3=s.ohlcv_close[2],c4=s.ohlcv_close[3];
      if(!MathIsValidNumber(c3) || !MathIsValidNumber(c4)) return false;
      const double rng1=h1-l1, rng2=h2-l2, body1=MathAbs(c1-o1);
      if(rng1<=0.0 || body1<=(rng1-body1) || rng1<=rng2 || s.ohlcv_volume[0]<=s.ohlcv_volume[1] || s.ohlcv_volume[0]<=s.ohlcv_volume[2])
         return false;
      if(want_buy ? !(c1>o1 && c1>h2) : !(c1<o1 && c1<l2))
         return false;
      const double g1=MathMax(c2-c3,0.0),l_1=MathMax(c3-c2,0.0);
      const double g2=MathMax(c3-c4,0.0),l_2=MathMax(c4-c3,0.0);
      const double ag=(g1+g2)*0.5, al=(l_1+l_2)*0.5;
      const double rsi2=(al<=0.0 ? 100.0 : 100.0-100.0/(1.0+ag/al));
      if(want_buy ? (rsi2>=15.0) : (rsi2<=85.0))
         return false;
      double f1=0.0,s1=0.0,f2=0.0,s2=0.0,m15_f=0.0,m15_s=0.0,m30_f=0.0,m30_s=0.0,h1_f=0.0,h1_s=0.0,h4_f=0.0,h4_s=0.0,atr1=0.0,atr2=0.0,cci1=0.0;
      if(!TryReadMA(g_fast_ma_handles[0],1,f1)    || !TryReadMA(g_slow_ma_handles[0],1,s1) ||
         !TryReadMA(g_fast_ma_handles[0],2,f2)    || !TryReadMA(g_slow_ma_handles[0],2,s2) ||
         !TryReadMA(g_fast_ma_handles[1],1,m15_f) || !TryReadMA(g_slow_ma_handles[1],1,m15_s) ||
         !TryReadMA(g_fast_ma_handles[2],1,m30_f) || !TryReadMA(g_slow_ma_handles[2],1,m30_s) ||
         !TryReadMA(g_fast_ma_handles[3],1,h1_f)  || !TryReadMA(g_slow_ma_handles[3],1,h1_s) ||
         !TryReadMA(g_fast_ma_handles[4],1,h4_f)  || !TryReadMA(g_slow_ma_handles[4],1,h4_s))
         return false;
      if(want_buy ? !(f1>s1 && f1>f2 && (f1-s1)>(f2-s2) && c1>f1 && m15_f>m15_s && m30_f>m30_s && h1_f>h1_s && h4_f>h4_s)
                  : !(f1<s1 && f1<f2 && (s1-f1)>(s2-f2) && c1<f1 && m15_f<m15_s && m30_f<m30_s && h1_f<h1_s && h4_f<h4_s))
         return false;
      if(!ReadEntryQualityATR(1,atr1) || !ReadEntryQualityATR(2,atr2) || atr1<=atr2 || rng1<=atr2 || rng1>2.0*atr2)
         return false;
      if(!ComputeB3CCI20(s,cci1) || (want_buy ? !(cci1>100.0 && cci1<200.0) : !(cci1<-100.0 && cci1>-200.0)))
         return false;
      return PassB3M1Color(want_buy);
   }
   if(id==120) // B3_20: SMA(20) Pullback Bounce (Touch SMA20 on [1] or [2], launch above SMA20 & SMA8, M15/M30/H1, ATR rising 1..2x, RSI 30..70, M1)
   {
      MqlDateTime dt120;
      const datetime b0=iTime(_Symbol,PERIOD_M5,0);
      if(b0<=0 || !TimeToStruct(b0,dt120) || dt120.hour<3 || dt120.hour>=22)
         return false;
      const double rng1=h1-l1, body1=MathAbs(c1-o1);
      if(rng1<=0.0 || body1<=(rng1-body1) || s.ohlcv_volume[0]<=s.ohlcv_volume[1] || s.ohlcv_volume[0]<=s.ohlcv_volume[2])
         return false;
      if(want_buy ? !(c1>o1 && c1>h2) : !(c1<o1 && c1<l2))
         return false;
      double sum1=0.0,sum2=0.0,cl20[20];
      if(CopyClose(_Symbol,PERIOD_M5,2,20,cl20)!=20) return false;
      for(int k=0;k<20;k++)
      {
         if(!MathIsValidNumber(s.ohlcv_close[k]) || !MathIsValidNumber(cl20[k])) return false;
         sum1+=s.ohlcv_close[k]; sum2+=cl20[k];
      }
      const double sma20_1=sum1/20.0, sma20_2=sum2/20.0;
      if(want_buy ? !((l1<=sma20_1 || l2<=sma20_2) && c1>sma20_1)
                  : !((h1>=sma20_1 || h2>=sma20_2) && c1<sma20_1))
         return false;
      const double rng2_20=h2-l2;
      if(rng1<=rng2_20) return false;
      double f1=0.0,s1=0.0,f2=0.0,m15_f=0.0,m15_s=0.0,m30_f=0.0,m30_s=0.0,h1_f=0.0,h1_s=0.0,h4_f=0.0,h4_s=0.0,atr1=0.0,atr2=0.0,rsi1=50.0,cci1=0.0;
      if(!TryReadMA(g_fast_ma_handles[0],1,f1)    || !TryReadMA(g_slow_ma_handles[0],1,s1) ||
         !TryReadMA(g_fast_ma_handles[0],2,f2)    ||
         !TryReadMA(g_fast_ma_handles[1],1,m15_f) || !TryReadMA(g_slow_ma_handles[1],1,m15_s) ||
         !TryReadMA(g_fast_ma_handles[2],1,m30_f) || !TryReadMA(g_slow_ma_handles[2],1,m30_s) ||
         !TryReadMA(g_fast_ma_handles[3],1,h1_f)  || !TryReadMA(g_slow_ma_handles[3],1,h1_s) ||
         !TryReadMA(g_fast_ma_handles[4],1,h4_f)  || !TryReadMA(g_slow_ma_handles[4],1,h4_s))
         return false;
      if(want_buy ? !(f1>s1 && f1>f2 && c1>f1 && m15_f>m15_s && m30_f>m30_s && h1_f>h1_s && h4_f>h4_s)
                  : !(f1<s1 && f1<f2 && c1<f1 && m15_f<m15_s && m30_f<m30_s && h1_f<h1_s && h4_f<h4_s))
         return false;
      if(!ReadEntryQualityATR(1,atr1) || !ReadEntryQualityATR(2,atr2) || atr1<=atr2 || rng1<=atr2 || rng1>2.0*atr2)
         return false;
      if(!ComputeB3RSI14(s,rsi1) || rsi1<=30.0 || rsi1>=70.0)
         return false;
      if(!ComputeB3CCI20(s,cci1) || (want_buy ? !(cci1>100.0 && cci1<200.0) : !(cci1<-100.0 && cci1>-200.0)))
         return false;
      return PassB3M1Color(want_buy);
   }
   if(id>=123 && id<=180) // Disjoint Zero-Decimal Regime ORs (non-overlapping with B3_01..B3_20)
   {
      const double rng1=h1-l1, rng2=h2-l2, body1=MathAbs(c1-o1);
      if(rng1<=0.0) return false;
      const double lead1=(want_buy ? (h1-c1) : (c1-l1)), tail1=(want_buy ? (o1-l1) : (h1-o1));
      const bool dir_ok=(want_buy ? (c1>o1) : (c1<o1));
      const bool brk2=(want_buy ? (c1>h2) : (c1<l2));
      const bool m1_ok=PassB3M1Color(want_buy);
      if(!dir_ok) return false;
      // Only id==139 uses opposite M1 micro-pullback; all other disjoint ORs require M1 aligned
      // 139 uses an opposite M1 micro-pullback; 148..151 deliberately have no M1 gate so
      // their trade frequency stays above the 50-per-year floor.
      if(UseM1ColorFilter && id!=139 && id!=148 && id!=149 && id!=150 && id!=151 && id!=152 && id!=153 && id!=154 && id!=155 && id!=156 && !m1_ok) return false;

      double f1=0.0,s1=0.0,f2=0.0,s2=0.0,m15_f=0.0,m15_s=0.0,m15_f2=0.0,m30_f=0.0,m30_s=0.0,h1_f=0.0,h1_s=0.0,h1_f2=0.0,h4_f=0.0,h4_s=0.0;
      double atr1=0.0,atr2=0.0;
      if(!TryReadMA(g_fast_ma_handles[0],1,f1) || !TryReadMA(g_slow_ma_handles[0],1,s1) ||
         !TryReadMA(g_fast_ma_handles[0],2,f2) || !TryReadMA(g_slow_ma_handles[0],2,s2) ||
         !TryReadMA(g_fast_ma_handles[1],1,m15_f) || !TryReadMA(g_slow_ma_handles[1],1,m15_s) ||
         !TryReadMA(g_fast_ma_handles[1],2,m15_f2) ||
         !TryReadMA(g_fast_ma_handles[2],1,m30_f) || !TryReadMA(g_slow_ma_handles[2],1,m30_s) ||
         !TryReadMA(g_fast_ma_handles[3],1,h1_f)  || !TryReadMA(g_slow_ma_handles[3],1,h1_s) ||
         !TryReadMA(g_fast_ma_handles[3],2,h1_f2) ||
         !TryReadMA(g_fast_ma_handles[4],1,h4_f)  || !TryReadMA(g_slow_ma_handles[4],1,h4_s) ||
         !ReadEntryQualityATR(1,atr1) || !ReadEntryQualityATR(2,atr2))
         return false;

      const bool m5_ok=(want_buy ? (f1>s1 && f1>f2 && c1>f1) : (f1<s1 && f1<f2 && c1<f1));
      const bool m5_exp=(want_buy ? ((f1-s1)>(f2-s2)) : ((s1-f1)>(s2-f2)));
      const bool m15_ok=(want_buy ? (m15_f>m15_s) : (m15_f<m15_s));
      const bool m30_ok=(want_buy ? (m30_f>m30_s) : (m30_f<m30_s));
      const bool h1_ok=(want_buy ? (h1_f>h1_s) : (h1_f<h1_s));
      // v3.51: H4 alignment is a global opt-out for the whole continuation family.
      const bool h4_ok=((!UseH4AlignmentForEntries) || (want_buy ? (h4_f>h4_s) : (h4_f<h4_s)));
      const double o3=s.ohlcv_open[2], h3=s.ohlcv_high[2], l3=s.ohlcv_low[2], c3=s.ohlcv_close[2];
      const double rng3=h3-l3;

      if(id==148) // B3_48_PrevDayExtremeBreak: close through the previous day's extreme in a full 5-TF trend
      {
         // The previous completed broker day is a structure every participant can see,
         // so this is a structural break rather than a break of the previous bar only.
         const double day_hi=iHigh(_Symbol,PERIOD_D1,1);
         const double day_lo=iLow(_Symbol,PERIOD_D1,1);
         if(!MathIsValidNumber(day_hi) || !MathIsValidNumber(day_lo) || day_hi<=0.0 || day_lo<=0.0)
            return false;
         if(want_buy ? !(c1>day_hi) : !(c1<day_lo))
            return false;
         return (m5_ok && m5_exp && m15_ok && m30_ok && h1_ok && h4_ok &&
                 body1>(rng1-body1) && lead1<tail1 &&
                 rng1>rng2 && rng1>rng3 &&
                 s.ohlcv_volume[0]>s.ohlcv_volume[1] && s.ohlcv_volume[0]>s.ohlcv_volume[2] &&
                 atr1>atr2);
      }

      // ---------------------------------------------------------------
      // v3.50 new ORs (149..151). All keep the certified continuation core
      // (m5_ok/m5_exp/5-TF alignment/body dominance/small lead wick/expanding
      // range+volume/rising ATR) and differ ONLY in which level they break.
      // This keeps them structurally distinct from ids 123..148 while raising
      // the portfolio trade frequency.
      // ---------------------------------------------------------------
      if(id==149) // B3_49_FiveBarStructureBreak: close through the highest high / lowest low of bars [2..6]
      {
         double lvl=0.0;
         if(want_buy)
         {
            lvl=MathMax(h2,h3);
            for(int k=3;k<=5;k++) if(s.ohlcv_high[k]>lvl) lvl=s.ohlcv_high[k];
            if(!(c1>lvl)) return false;
         }
         else
         {
            lvl=MathMin(l2,l3);
            for(int k=3;k<=5;k++) if(s.ohlcv_low[k]<lvl) lvl=s.ohlcv_low[k];
            if(!(c1<lvl)) return false;
         }
         return (m5_ok && m5_exp && m15_ok && m30_ok && h1_ok && h4_ok &&
                 body1>(rng1-body1) && lead1<tail1 &&
                 rng1>rng2 && rng1>rng3 &&
                 s.ohlcv_volume[0]>s.ohlcv_volume[1] && s.ohlcv_volume[0]>s.ohlcv_volume[2] &&
                 atr1>atr2);
      }
      if(id==150) // B3_50_NineteenBarStructureBreak: close through the extreme of bars [2..20]
      {
         double lvl=0.0;
         if(want_buy)
         {
            lvl=h2;
            for(int k=2;k<=19;k++) if(s.ohlcv_high[k]>lvl) lvl=s.ohlcv_high[k];
            if(!(c1>lvl)) return false;
         }
         else
         {
            lvl=l2;
            for(int k=2;k<=19;k++) if(s.ohlcv_low[k]<lvl) lvl=s.ohlcv_low[k];
            if(!(c1<lvl)) return false;
         }
         return (m5_ok && m5_exp && m15_ok && m30_ok && h1_ok && h4_ok &&
                 body1>(rng1-body1) && lead1<tail1 &&
                 rng1>rng2 && s.ohlcv_volume[0]>s.ohlcv_volume[1] && atr1>atr2);
      }
      if(id==151) // B3_51_ThreeBarThrust: three consecutive closes AND higher lows in the trend direction
      {
         const double o4=s.ohlcv_open[3], c4=s.ohlcv_close[3];
         if(!MathIsValidNumber(c4)) return false;
         if(want_buy)
         {
            if(!(c1>o1 && c2>o2 && c3>o3)) return false;   // three up closes
            if(!(c1>c2 && c2>c3 && c3>c4)) return false;   // strictly rising closes
            if(!(l1>l2 || l2>l3)) return false;            // higher lows supporting the thrust
         }
         else
         {
            if(!(c1<o1 && c2<o2 && c3<o3)) return false;
            if(!(c1<c2 && c2<c3 && c3<c4)) return false;
            if(!(h1<h2 || h2<h3)) return false;
         }
         return (m5_ok && m5_exp && m15_ok && m30_ok && h1_ok && h4_ok &&
                 body1>(rng1-body1) && lead1<tail1 &&
                 s.ohlcv_volume[0]>=s.ohlcv_volume[1] && s.ohlcv_volume[1]>=s.ohlcv_volume[2] &&
                 atr1>atr2);
      }

      // v3.93: B3_52 (id 152) REMOVED from this build - 2026 portfolio produced 7 over-5-bar orders
      // and two redevelopment rounds could not reach 100% inside 5 bars with >=50 trades/year.

      if(id==153) // B3_53_DeepPullbackHold: wick through M5 SMA12 and close back above it
      {
         const bool deep_hold=(want_buy ? (l1<=s1 && c1>s1 && c1>o1 && s1<f1)
                                        : (h1>=s1 && c1<s1 && c1<o1 && s1>f1));
         if(!deep_hold) return false;
         return (m5_ok && m15_ok && m30_ok && h1_ok && h4_ok &&
                 body1>(rng1-body1) && s.ohlcv_volume[0]>s.ohlcv_volume[1] && atr1>atr2);
      }

      // v3.93: B3_54 (id 154) and B3_55 (id 155) REMOVED from this build - 18 and 17 over-5-bar
      // orders in the 2026 portfolio (B3_55 inherited the same signals once B3_54 was off), and five
      // redevelopment rounds could not reach 100% inside 5 bars with >=50 trades/year.
      // After removing all three the 2026 portfolio closes 568/568 trades inside 5 bars.


      // ---------------------------------------------------------------
      // v3.61 NEW OR 156 - the requested premise, nothing else:
      //   BUY  : [1][2][3] all green, body[1] > body[2] > body[3], M5 SMA8 > SMA12
      //   SELL : [1][2][3] all red,   body[1] > body[2] > body[3], M5 SMA8 < SMA12
      // [1] colour is already enforced by the shared dir_ok above; this block adds [2][3].
      // No MTF alignment, no volume, no ATR: those are candidates for Phase C filters only if the
      // isolated test shows over-5-bar orders.
      // ---------------------------------------------------------------
      if(id==156) // B3_56_BodyExpansion3
      {
         const double body2=MathAbs(c2-o2), body3=MathAbs(c3-o3);
         if(body1<=0.0 || body2<=0.0 || body3<=0.0) return false;   // no doji bodies
         if(want_buy ? !(c2>o2 && c3>o3) : !(c2<o2 && c3<o3)) return false;
         if(!(body1>body2 && body2>body3)) return false;
         if(want_buy ? !(f1>s1) : !(f1<s1)) return false;           // M5 SMA8 vs SMA12
         if(B3_56_RequireMTFAlignment)
         {
            // Phase-C anti-false-momentum gate: the expansion must not fight a higher-TF trend.
            if(!m15_ok || !m30_ok || !h1_ok || !h4_ok) return false;
         }
         if(B3_56_RequireVolExpansion)
         {
            // Phase-C volatility gate: the signal bar must be a volatility-expansion bar,
            // otherwise the fixed TP distance needs more than 5 bars to fill.
            if(!(rng1>atr2)) return false;
            if(!(atr1>atr2)) return false;
         }
         if(B3_56_RequireLiquidSession)
         {
            // Phase-C liquidity gate: server-hour window where XAU carries enough participation
            // for a fixed 500-point TP to fill inside 5 bars.
            const datetime signal_time=iTime(_Symbol,PERIOD_M5,1);
            if(signal_time<=0) return false;
            MqlDateTime clock;
            TimeToStruct(signal_time,clock);
            if(clock.hour<B3_56_LiquidStartHour || clock.hour>B3_56_LiquidEndHour) return false;
         }
         return true;
      }

      // ---------------------------------------------------------------
      // v3.75 NEW OR 163 - body chain AND three-bar level break:
      //   BUY  : 3 expanding bullish bodies + close above max(high[2..4]) + core gates + session
      //   SELL : mirror
      // ---------------------------------------------------------------
      // ---------------------------------------------------------------
      // v3.81 NEW OR 165 - body chain + previous-bar extreme break (higher frequency sibling of 163)
      //   BUY  : 3 expanding bullish bodies, close[1] > high[2], + core gates + session 07..23
      //   SELL : mirror
      // ---------------------------------------------------------------
      if(id==165) // B3_65_ChainTwoBarBreak
      {
         const double body2=MathAbs(c2-o2), body3=MathAbs(c3-o3);
         if(body1<=0.0 || body2<=0.0 || body3<=0.0) return false;
         if(want_buy ? !(c2>o2 && c3>o3) : !(c2<o2 && c3<o3)) return false;
         if(!(body1>body2 && body2>body3)) return false;
         if(want_buy ? !(c1>h2) : !(c1<l2)) return false;
         if(!(body1>(rng1-body1))) return false;
         if(s.ohlcv_volume[0]<=s.ohlcv_volume[1]) return false;
         if(!(atr1>atr2)) return false;
         if(want_buy ? !(f1>s1) : !(f1<s1)) return false;
         if(!m15_ok || !m30_ok || !h1_ok || !h4_ok) return false;
         const datetime sig_time=iTime(_Symbol,PERIOD_M5,1);
         if(sig_time<=0) return false;
         MqlDateTime clk;
         TimeToStruct(sig_time,clk);
         if(clk.hour<B3_65_LiquidStartHour || clk.hour>B3_65_LiquidEndHour) return false;
         return true;
      }

      // ---------------------------------------------------------------
      // v3.105 NEW OR 180 - Break & Retest of a 10-bar level (PA trigger ??????????? v093)
      //   BUY : close[2] > max(high[3..13]), low[1] <= level, close[1] > level
      //   SELL: close[2] < min(low[3..13]), high[1] >= level, close[1] < level
      // ---------------------------------------------------------------
      if(id==180) // B3_80_BreakRetest
      {
         double lvl_hi=-DBL_MAX, lvl_lo=DBL_MAX;
         for(int k=3;k<=13;k++)
         {
            const double kh=iHigh(_Symbol,PERIOD_M5,k);
            const double kl=iLow(_Symbol,PERIOD_M5,k);
            if(!MathIsValidNumber(kh) || !MathIsValidNumber(kl)) return false;
            if(kh>lvl_hi) lvl_hi=kh;
            if(kl<lvl_lo) lvl_lo=kl;
         }
         if(want_buy)
         {
            if(!(c2>lvl_hi)) return false;               // breakout bar closed above the level
            if(!(l1<=lvl_hi)) return false;              // retest touched the level
            if(!(c1>lvl_hi)) return false;               // held and closed back above
         }
         else
         {
            if(!(c2<lvl_lo)) return false;
            if(!(h1>=lvl_lo)) return false;
            if(!(c1<lvl_lo)) return false;
         }
         if(!(body1>(rng1-body1))) return false;
         if(s.ohlcv_volume[0]<=s.ohlcv_volume[1]) return false;
         if(!(atr1>atr2)) return false;
         if(!m15_ok || !m30_ok || !h1_ok || !h4_ok) return false;
         const datetime sig_time=iTime(_Symbol,PERIOD_M5,1);
         if(sig_time<=0) return false;
         MqlDateTime clk;
         TimeToStruct(sig_time,clk);
         if(clk.hour<7 || clk.hour>23) return false;
         return true;
      }

      if(id==123) // B3_23_CoolingATR (certified 100%)
      {
         if(atr1>atr2) return false;
         return (brk2 && m5_ok && m5_exp && m15_ok && m30_ok && h1_ok && body1>(rng1-body1) && lead1<tail1 &&
                 rng1>rng2 && rng1>rng3 && s.ohlcv_volume[0]>s.ohlcv_volume[1] && s.ohlcv_volume[0]>s.ohlcv_volume[2]);
      }
      if(id==125) // B3_25_CCI200Power (certified 100%)
      {
         double cci1=0.0;
         if(!ComputeB3CCI20(s,cci1)) return false;
         if(want_buy ? (cci1<200.0) : (cci1>-200.0)) return false;
         return (brk2 && m5_ok && m5_exp && m15_ok && m30_ok && h1_ok && h4_ok &&
                 body1>(rng1-body1) && lead1<tail1 && rng1>rng2 && rng1>rng3 &&
                 s.ohlcv_volume[0]>s.ohlcv_volume[1] && s.ohlcv_volume[0]>s.ohlcv_volume[2] &&
                 atr1>atr2 && rng1>atr2 && rng1<3.0*atr2);
      }
      if(id==127) // B3_27_TightBarCont (certified 100%)
      {
         if(rng1>atr2) return false;
         double rsi1=50.0;
         if(!ComputeB3RSI14(s,rsi1) || rsi1<=30.0 || rsi1>=70.0) return false;
         return (brk2 && m5_ok && m5_exp && m15_ok && m30_ok && h1_ok && h4_ok &&
                 body1>(rng1-body1) && lead1<tail1 && s.ohlcv_volume[0]>s.ohlcv_volume[1]);
      }
      if(id==130) // B3_30_GiantBarFollow (certified 100%)
      {
         if(rng1<3.0*atr2) return false;
         return (brk2 && body1>(rng1-body1) && lead1<tail1 &&
                 s.ohlcv_volume[0]>s.ohlcv_volume[1] && s.ohlcv_volume[0]>s.ohlcv_volume[2] &&
                 m5_ok && m15_ok && m30_ok && h1_ok && h4_ok);
      }
      if(id==131) // B3_31_InsideCloseMom (certified 100%)
      {
         if(brk2) return false;
         const bool body_brk=(want_buy ? (c1>MathMax(o2,c2)) : (c1<MathMin(o2,c2)));
         return (body_brk && m5_ok && m5_exp && m15_ok && m30_ok && h1_ok && h4_ok &&
                 body1>(rng1-body1) && lead1<tail1 && s.ohlcv_volume[0]>s.ohlcv_volume[1]);
      }
      if(id==132) // B3_32_SMA12Bounce (certified 100%)
      {
         if(want_buy ? (f1>f2) : (f1<f2)) return false;
         double rsi1=50.0;
         if(!ComputeB3RSI14(s,rsi1) || rsi1<=30.0 || rsi1>=70.0) return false;
         const bool touch12=(want_buy ? ((l1<=s1 || l2<=s2) && c1>f1 && f1>s1) : ((h1>=s1 || h2>=s2) && c1<f1 && f1<s1));
         return (brk2 && touch12 && m15_ok && m30_ok && h1_ok && h4_ok &&
                 body1>(rng1-body1) && lead1<tail1 && rng1>rng2 && atr1>atr2 && s.ohlcv_volume[0]>s.ohlcv_volume[1]);
      }
      if(id==133) // B3_33_FreshM5Cross (certified 100%)
      {
         double rsi1=50.0;
         if(!ComputeB3RSI14(s,rsi1) || rsi1<=30.0 || rsi1>=70.0) return false;
         const bool fresh_x=(want_buy ? (f2<=s2 && f1>s1 && c1>f1) : (f2>=s2 && f1<s1 && c1<f1));
         return (brk2 && fresh_x && m15_ok && m30_ok && h1_ok && h4_ok &&
                 body1>(rng1-body1) && lead1<tail1 && rng1>rng2 && rng1>rng3 &&
                 s.ohlcv_volume[0]>s.ohlcv_volume[1] && s.ohlcv_volume[0]>s.ohlcv_volume[2] && atr1>atr2);
      }
      if(id==139) // B3_39_M1OppFlush: M1 micro-pullback opposite (!m1_ok) inside explosive 5-TF M5 trend bar
      {
         if(m1_ok) return false; // strictly disjoint from ALL M1-aligned ORs
         double rsi1=50.0, cci1=0.0;
         if(!ComputeB3RSI14(s,rsi1) || rsi1<=30.0 || rsi1>=70.0) return false;
         if(!ComputeB3CCI20(s,cci1) || (want_buy ? !(cci1>100.0 && cci1<200.0) : !(cci1<-100.0 && cci1>-200.0))) return false;
         return (brk2 && m5_ok && m5_exp && m15_ok && m30_ok && h1_ok && h4_ok &&
                 body1>(rng1-body1) && lead1<tail1 && rng1>rng2 && rng1>rng3 &&
                 s.ohlcv_volume[0]>s.ohlcv_volume[1] && s.ohlcv_volume[0]>s.ohlcv_volume[2] &&
                 atr1>atr2 && rng1>atr2 && rng1<3.0*atr2);
      }
      if(id==140) // B3_40_MarubozuOpen: Marubozu open (lead1>=tail1) with huge body (body > 2*wicks) + 3-bar expansion + CCI 100..200
      {
         if(lead1<tail1) return false; // strictly disjoint from lead1<tail1 ORs
         double rsi1=50.0, cci1=0.0;
         if(!ComputeB3RSI14(s,rsi1) || rsi1<=30.0 || rsi1>=70.0) return false;
         if(!ComputeB3CCI20(s,cci1) || (want_buy ? !(cci1>100.0 && cci1<200.0) : !(cci1<-100.0 && cci1>-200.0))) return false;
         return (brk2 && m5_ok && m5_exp && m15_ok && m30_ok && h1_ok && h4_ok &&
                 body1>2.0*(rng1-body1) && rng1>rng2 && rng1>rng3 &&
                 s.ohlcv_volume[0]>s.ohlcv_volume[1] && s.ohlcv_volume[0]>s.ohlcv_volume[2] &&
                 atr1>atr2 && rng1>atr2 && rng1<3.0*atr2);
      }
      if(id==141) // B3_41_CounterH4Drive: H4 opposite (!h4_ok), strong M5+M15(rising)+M30+H1(rising) intraday drive
      {
         if(h4_ok) return false; // strictly disjoint from H4-aligned ORs
         if(want_buy ? (m15_f<=m15_f2 || h1_f<=h1_f2) : (m15_f>=m15_f2 || h1_f>=h1_f2)) return false;
         double rsi1=50.0, cci1=0.0;
         if(!ComputeB3RSI14(s,rsi1) || rsi1<=30.0 || rsi1>=70.0) return false;
         if(!ComputeB3CCI20(s,cci1) || (want_buy ? !(cci1>100.0 && cci1<200.0) : !(cci1<-100.0 && cci1>-200.0))) return false;
         return (brk2 && m5_ok && m5_exp && m15_ok && m30_ok && h1_ok &&
                 body1>(rng1-body1) && lead1<tail1 && rng1>rng2 && rng1>rng3 &&
                 s.ohlcv_volume[0]>s.ohlcv_volume[1] && s.ohlcv_volume[0]>s.ohlcv_volume[2] &&
                 atr1>atr2 && rng1>atr2 && rng1<3.0*atr2);
      }
      if(id==142) // B3_42_ParallelSMAGap: steady parallel SMA8/12 (!m5_exp, both rising) in full 5-TF trend
      {
         if(m5_exp) return false; // strictly disjoint from m5_exp ORs
         if(want_buy ? (s1<=s2) : (s1>=s2)) return false;
         double rsi1=50.0;
         if(!ComputeB3RSI14(s,rsi1) || rsi1<=30.0 || rsi1>=70.0) return false;
         return (brk2 && m5_ok && m15_ok && m30_ok && h1_ok && h4_ok &&
                 body1>(rng1-body1) && lead1<tail1 && rng1>rng2 && s.ohlcv_volume[0]>s.ohlcv_volume[1] &&
                 atr1>atr2 && rng1>atr2 && rng1<2.0*atr2);
      }
      if(id==143) // B3_43_M15CounterBnc: M15 lagging (!m15_ok) but M15 fast SMA turning in trend + M5+M30+H1+H4 + CCI 100..200
      {
         if(m15_ok) return false; // strictly disjoint from ALL M15-aligned ORs
         if(want_buy ? (m15_f<=m15_f2) : (m15_f>=m15_f2)) return false;
         double rsi1=50.0, cci1=0.0;
         if(!ComputeB3RSI14(s,rsi1) || rsi1<=30.0 || rsi1>=70.0) return false;
         if(!ComputeB3CCI20(s,cci1) || (want_buy ? !(cci1>100.0 && cci1<200.0) : !(cci1<-100.0 && cci1>-200.0))) return false;
         return (brk2 && m5_ok && m5_exp && m30_ok && h1_ok && h4_ok &&
                 body1>(rng1-body1) && lead1<tail1 && rng1>rng2 && rng1>rng3 &&
                 s.ohlcv_volume[0]>s.ohlcv_volume[1] && s.ohlcv_volume[0]>s.ohlcv_volume[2] &&
                 atr1>atr2 && rng1>atr2 && rng1<3.0*atr2);
      }
      if(id==144) // B3_44_BalancedBodyBO: balanced body (body<=wicks, body>lead & body>tail) high-vol breakout
      {
         if(body1>(rng1-body1) || body1<=lead1 || body1<=tail1) return false; // disjoint from big-body AND pinbars
         double rsi1=50.0, cci1=0.0;
         if(!ComputeB3RSI14(s,rsi1) || rsi1<=30.0 || rsi1>=70.0) return false;
         if(!ComputeB3CCI20(s,cci1) || (want_buy ? !(cci1>100.0 && cci1<200.0) : !(cci1<-100.0 && cci1>-200.0))) return false;
         return (brk2 && m5_ok && m5_exp && m15_ok && m30_ok && h1_ok && h4_ok &&
                 rng1>rng2 && s.ohlcv_volume[0]>s.ohlcv_volume[1] && s.ohlcv_volume[0]>s.ohlcv_volume[2] &&
                 atr1>atr2 && rng1>atr2 && rng1<2.0*atr2);
      }
      if(id==145) // B3_45_ParabolicGlide: Vol[1]<=Vol[2] low-resistance glide in parabolic RSI>=70/<=30 + M15/H1 slope + 3-bar range + rising ATR
      {
         if(s.ohlcv_volume[0]>s.ohlcv_volume[1]) return false;
         if(want_buy ? (m15_f<=m15_f2 || h1_f<=h1_f2) : (m15_f>=m15_f2 || h1_f>=h1_f2)) return false;
         double rsi1=50.0;
         if(!ComputeB3RSI14(s,rsi1)) return false;
         if(want_buy ? (rsi1<70.0) : (rsi1>30.0)) return false;
         return (brk2 && m5_ok && m5_exp && m15_ok && m30_ok && h1_ok && h4_ok &&
                 body1>(rng1-body1) && lead1<tail1 && rng1>rng2 && rng1>rng3 &&
                 atr1>atr2 && rng1>atr2 && rng1<3.0*atr2);
      }
      if(id==146) // B3_46_BandLaunchSMA12: early launch closing inside SMA8-SMA12 band (c1<=f1 && c1>s1) in 4-HTF trend
      {
         const bool in_band=(want_buy ? (c1<=f1 && c1>s1) : (c1>=f1 && c1<s1));
         if(!in_band) return false; // strictly disjoint from c1>f1 ORs
         double rsi1=50.0;
         if(!ComputeB3RSI14(s,rsi1) || rsi1<=30.0 || rsi1>=70.0) return false;
         return (brk2 && m15_ok && m30_ok && h1_ok && h4_ok &&
                 body1>(rng1-body1) && lead1<tail1 && rng1>rng2 && s.ohlcv_volume[0]>s.ohlcv_volume[1] && atr1>atr2);
      }
      return false;
   }
   return false;
}

bool EntryCondition(const IndicatorState &s,const bool want_buy,
                    const bool check_entry_gates=true)
{
   EnsurePerBarCache();
   if(check_entry_gates && !PassTPEnergyGate(s))
      return false;
   if(check_entry_gates && !PassEntryTrendFilter(s,want_buy))
      return false;
   string hit_tag="";
   bool matched=false;

    if(check_entry_gates && NewORIsolatedEntry>=101 && NewORIsolatedEntry<=180)
   {
      matched=PassB3OREntry(s,want_buy,NewORIsolatedEntry);
      if(matched) hit_tag=B3ORTag(NewORIsolatedEntry);
   }
   else if(check_entry_gates)
   {
       for(int id=101;id<=180 && !matched;id++)
         if(PassB3OREntry(s,want_buy,id)) { matched=true; hit_tag=B3ORTag(id); }
   }

   if(check_entry_gates)
   {
      if(want_buy) { g_cached_buy_valid=matched; g_cached_buy_tag=(matched ? hit_tag : ""); }
      else         { g_cached_sell_valid=matched; g_cached_sell_tag=(matched ? hit_tag : ""); }
   }
   return matched;
}

string EntryTriggerName(const IndicatorState &s,const bool want_buy)
{
   EnsurePerBarCache();
   if(want_buy && g_cached_buy_valid && g_cached_buy_tag!="")
      return g_cached_buy_tag;
   if(!want_buy && g_cached_sell_valid && g_cached_sell_tag!="")
      return g_cached_sell_tag;
   if(EntryCondition(s,want_buy,true))
      return want_buy ? g_cached_buy_tag : g_cached_sell_tag;
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
         // v3.55 recovery: optional protective stop that coexists with the fixed TP.
         if(UseProtectiveStop && ProtectiveStopPoints>0)
         {
            const double pstop=InputPointSize();
            double raw_sl=(is_buy ? entry-ProtectiveStopPoints*pstop
                                  : entry+ProtectiveStopPoints*pstop);
            sl=NormalizeTickPrice(raw_sl,!is_buy);
            if(sl<=0.0 ||
               (is_buy && sl>=price_to_check-min_distance) ||
               (!is_buy && sl<=price_to_check+min_distance))
               sl=0.0; // broker would reject a stop this close; fall back to unprotected
         }
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
   const int total=PositionsTotal();
   if(total<=0) return 0;
   int count=0;
   for(int i=total-1; i>=0; i--)
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
   if(g_recovery_started_at<=0) g_recovery_started_at=TimeCurrent();
   g_recovery_flips=0;
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
      g_recovery_started_at=0;
      g_recovery_flips=0;
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
   basket_points=g_basket_realized_pts;
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
   const double required=(BasketProfitTarget - g_basket_realized_pts)*pt*LotSize;
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
      case 35:return "SMA BAND ENGULF";
      case 36:return "SMA GAP EXPAND";
      case 37:return "SWEEP ENGULF";
      case 38:return "PB2 RECLAIM";
   }
   return "UNKNOWN";
}

bool PanelORIsEnabled(const int id)
{
   if(NewORIsolatedEntry>0 && id!=NewORIsolatedEntry) return false;
   return B3ORIsEnabled(id);
}

bool PanelORIsReady(const int id,const string source)
{
   return (source==B3ORTag(id));
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
   if(!ShowStatusPanel || g_panel_prefix=="" ||
      (MQLInfoInteger(MQL_TESTER) && !MQLInfoInteger(MQL_VISUAL_MODE)))
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
   bool can_check_entry=(candle_valid && (NewORIsolatedEntry==33 || NewORIsolatedEntry==34 || NewORIsolatedEntry==35 || NewORIsolatedEntry==36 || NewORIsolatedEntry==37 || NewORIsolatedEntry==38 || !UseMTFTrendEntryFilter || all_valid));
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
      if(B3ORAnyEnabled())
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
   bool any_entry_trigger=B3ORAnyEnabled();
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

      // Compact 04.3..04.38 overview (all 36 entries, two columns).
      // Grey=OFF, orange=enabled/waiting, green=selected eligible signal.
      int ey=top_y+270;
      PanelSection("entry","02  ENTRY OR  |  04.3-04.38",left_x,ey,PANEL_COL_WIDTH,448);
      PanelLabel("or_legend","GRAY OFF  |  ORANGE ACTIVE  |  GREEN READY",
                 left_x+12,ey+33,PanelColorMuted(),8);
      for(int id=3;id<=38;id++)
      {
         const int idx=id-3;
         const int col=idx/18;
         const int yy=ey+55+(idx%18)*18;
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
      PanelKV("entry_signal","ENTRY SIGNAL",signal_text,left_x,ey+370,signal_color);
      PanelKV("exec_status","TRADING",(!EnableTrading ? "DISABLED" :
              (daily_target_hit ? "DAILY TARGET HIT" :
               (!daily_entries_allowed ? "WAIT P/L HISTORY" :
               (!broker_session_entry_allowed ? "SESSION CUTOFF" : "ENABLED")))),
              left_x,ey+395,(EnableTrading && daily_entries_allowed && broker_session_entry_allowed ?
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
   g_perf_cache_bar0=0;
   g_flat_cleanup_done=false;

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


    if(NewORIsolatedEntry!=0 && (NewORIsolatedEntry<101 || NewORIsolatedEntry>180))
      return INIT_PARAMETERS_INCORRECT;
    if(NewORIsolatedEntry>=101 && NewORIsolatedEntry<=180 && !B3ORIsEnabled(NewORIsolatedEntry))
      return INIT_PARAMETERS_INCORRECT;

   if((FastMAPeriod<=0 || SlowMAPeriod<=0 || LotSize<=0.0 || !MathIsValidNumber(TargetDailyProfit) || TargetDailyProfit<0.0 || MaxPositionsPerSymbol<0 || SlippagePoints<0 || PreMarketCloseMinutes<0 || PreMarketCloseMinutes>1440 || SwingLookbackBars<1 || SwingLookbackBars>OHLCV_HISTORY || SwingSLBufferPoints<0 || (UseTrailingStopWithSL && (!MathIsValidNumber(TrailingStartTPPercent) || TrailingStartTPPercent<=0.0 || TrailingStartTPPercent>=100.0 || !MathIsValidNumber(TrailingProtectMovePercent) || TrailingProtectMovePercent<=0.0 || TrailingProtectMovePercent>=100.0)) || EntryQualityATRPeriod<1 || BasketProfitTarget<=0.0 || !MathIsValidNumber(BasketProfitTarget) || (UseRecoveryLot && (!MathIsValidNumber(RecoveryLotMultiplier) || (RecoveryLotMultiplier!=0.0 && RecoveryLotMultiplier<1.0))) || (UseRecoveryLot && RecoveryLotMultiplier==0.0 && (DynamicRecoveryMovePoints<=0 || MaxDynamicRecoveryLot<LotSize || !MathIsValidNumber(MaxDynamicRecoveryLot) || MaxDynamicMarginPct<=0.0 || MaxDynamicMarginPct>100.0 || !MathIsValidNumber(MaxDynamicMarginPct))) || (UseSwingSL && UseRRTP && (RiskRewardRatio<=0.0 || !MathIsValidNumber(RiskRewardRatio))) || (UsingNoSLTPMode() && NoSLTPMode==TP_FIXED_POINTS && FixedTPPoints<=0) || PanelX<0 || PanelY<0 || PanelRefreshSeconds<1 || PanelFontScalePercent<60 || PanelFontScalePercent>150 || PanelMaxColumns<1 || PanelMaxColumns>2))
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

   if(!B3ORAnyEnabled())
   {
      Print("Entry OR group is empty: enable at least one BASELINE_003 Zero-Decimal entry.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(EnabledTFCount()==0 &&
      (UseMTFTrendEntryFilter ||
       (UsingNoSLTPMode() && NoSLTPMode==TP_ALL_ACTIVE_TFS_OPPOSE)))
   {
      Print("Enable at least one TF for SMA entry filtering or ALL-TF-OPPOSITE TP mode.");
      return INIT_PARAMETERS_INCORRECT;
   }

   g_basket_realized_pts=0.0;
   g_recovery_key=StringFormat("SMAREC_%I64d_%s_%I64u",
                               AccountInfoInteger(ACCOUNT_LOGIN),_Symbol,MagicNumber);
   g_recovery_active=(GlobalVariableCheck(g_recovery_key) &&
                      GlobalVariableGet(g_recovery_key)>0.5);
   RefreshRecoveryState();

   g_same_recovery_key=StringFormat("SMABASK_SS2_%I64d_%s_%I64u",
                                    AccountInfoInteger(ACCOUNT_LOGIN),_Symbol,MagicNumber);
   if(UseSameSideRecoveryLot && GlobalVariableCheck(g_same_recovery_key))
      g_same_recovery_active=(GlobalVariableGet(g_same_recovery_key)>0.5);
   RefreshSameSideRecoveryState();

   InitSetPoint();
   PrintFormat("POINT SCALE INIT: Symbol=%s Digits=%d NativePoint=%.5f SetPoint=%.5f",
               _Symbol,_Digits,_Point,g_set_point);
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

   if(UseTPEnergyATRGate || B3ORAnyEnabled())
   {
      g_entry_quality_atr_handle=iATR(_Symbol,PERIOD_M5,EntryQualityATRPeriod);
      if(g_entry_quality_atr_handle==INVALID_HANDLE)
      {
         PrintFormat("Cannot create entry-quality M5 ATR(%d), error=%d",
                     EntryQualityATRPeriod,GetLastError());
         return INIT_FAILED;
      }
   }

   g_panel_prefix=StringFormat("MTFSMA003_%I64u_",MagicNumber);
   AddIndicatorsToChart();
   g_last_bar_time=iTime(_Symbol,PERIOD_M5,0);
   g_panel_user_percent=PanelFontScalePercent;
   if(ShowStatusPanel)
   {
      UpdateStatusPanel();
      if(!EventSetTimer(PanelRefreshSeconds))
         PrintFormat("Panel timer setup failed. Error=%d",GetLastError());
   }

   PrintFormat("MTF SMA EA BASELINE_003 v3.30 (Pure Zero-Decimal) | TF=M5 | Fast=%d Slow=%d | ActiveTF=%d/5 | SwingSL=%s | TP=%s | Trading=%s",
               FastMAPeriod,SlowMAPeriod,EnabledTFCount(),
               (UseSwingSL ? "ON" : "OFF"),TPModeName(),(EnableTrading ? "ON" : "OFF"));
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
   if(g_b3_macd_handle!=INVALID_HANDLE)
   {
      IndicatorRelease(g_b3_macd_handle);
      g_b3_macd_handle=INVALID_HANDLE;
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
// Unlimited Ultra-Fast Recovery Signal: tracks live net exposure (buy_lots - sell_lots),
// supports unlimited Same-Side Fast-Avg + Re-Flip Hedges (never freezes!), pauses normal entries until flat.
bool EvaluateFastRecoverySignal(const IndicatorState &s,bool &out_buy,bool &out_sell,bool &out_is_flip,double &out_abs_net_lots)
{
   out_buy=false;
   out_sell=false;
   out_is_flip=false;
   out_abs_net_lots=0.0;
   if(!UseFastEscapeRecovery) return false;
   const int my_pos=CountMyPositions();
   if(my_pos<=0 || (FastRecoveryMaxPositions>0 && my_pos>=FastRecoveryMaxPositions)) return false;
   double basket_pts=0.0;
   if(!CalculateBasketProfitPoints(basket_pts) || basket_pts>=0.0) return false;

   const long min_sec=(long)FastRecoveryAfterBars * (long)PeriodSeconds(PERIOD_M5);
   const datetime now_t=TimeCurrent();
   double buy_lots=0.0, sell_lots=0.0;
   double lowest_buy=1e18, highest_sell=-1e18;
   datetime latest_open_t=0;
   double latest_open_px=0.0;
   bool stuck_enough=(MathAbs(g_basket_realized_pts)>1e-6);
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC)!=MagicNumber) continue;
      datetime open_t=(datetime)PositionGetInteger(POSITION_TIME);
      if(open_t>0 && (long)(now_t-open_t)>=min_sec) stuck_enough=true;
      double px=PositionGetDouble(POSITION_PRICE_OPEN);
      double vol=PositionGetDouble(POSITION_VOLUME);
      if(open_t>=latest_open_t) { latest_open_t=open_t; latest_open_px=px; }
      ENUM_POSITION_TYPE tp_side=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if(tp_side==POSITION_TYPE_BUY)  { buy_lots+=vol;  if(px<lowest_buy)   lowest_buy=px; }
      if(tp_side==POSITION_TYPE_SELL) { sell_lots+=vol; if(px>highest_sell) highest_sell=px; }
   }
   if(!stuck_enough) return false;

   const double net_lots=buy_lots-sell_lots;
   const double pt=InputPointSize();
   const double o1=s.ohlcv_open[0], c1=s.ohlcv_close[0];
   if(pt<=0.0 || !MathIsValidNumber(o1) || !MathIsValidNumber(c1))
      return false;
   const double step_dist=FastRecoverySameSideStepPts*pt;
   const double flip_dist=MathMax(step_dist,(double)FastRecoveryHedgeMinLossPts*pt);
   // v3.111 ATR-scaled thresholds + whipsaw guard + flip cap per episode.
   double atr_rec=0.0, atr_pts=0.0;
   if(ReadEntryQualityATR(1,atr_rec) && atr_rec>0.0 && pt>0.0) atr_pts=atr_rec/pt;
   double step_pts_eff=(double)FastRecoverySameSideStepPts;
   double loss_pts_eff=(double)FastRecoveryHedgeMinLossPts;
   if(RecoveryAtrScaled && atr_pts>0.0)
   {
      step_pts_eff=MathMax(step_pts_eff,RecoveryAtrStepMultiple*atr_pts);
      loss_pts_eff=MathMax(loss_pts_eff,RecoveryAtrLossMultiple*atr_pts);
   }
   const double step_dist_eff=step_pts_eff*pt;
   const double flip_dist_eff=MathMax(step_dist_eff,loss_pts_eff*pt);
   bool whipsaw_bar=false;
   if(RecoveryWhipsawGuard && atr_pts>0.0 && pt>0.0)
      whipsaw_bar=(((s.ohlcv_high[0]-s.ohlcv_low[0])/pt) > RecoveryWhipsawRangeMultiple*atr_pts);
   const bool flip_allowed=((!whipsaw_bar) &&
                            (RecoveryMaxFlipsPerEpisode<=0 || g_recovery_flips<RecoveryMaxFlipsPerEpisode));

   // Rule C (PRIORITY): Unlimited Ultra-Fast Net-Flip when M5 + M15 flip against our current NET direction.
   // Require BOTH basket loss >= FastRecoveryHedgeMinLossPts AND distance from latest open leg >= flip_dist
   // so a fresh FAST_AVG leg cannot trigger a panic flip right at the bottom/top.
   if(flip_allowed && basket_pts <= -loss_pts_eff)
   {
      double f1=0.0,s1=0.0,m15_f=0.0,m15_s=0.0;
      if(TryReadMA(g_fast_ma_handles[0],1,f1)    && TryReadMA(g_slow_ma_handles[0],1,s1) &&
         TryReadMA(g_fast_ma_handles[1],1,m15_f) && TryReadMA(g_slow_ma_handles[1],1,m15_s))
      {
         if(net_lots>1e-6 && (latest_open_px - c1)>=flip_dist_eff && f1<s1 && m15_f<m15_s && c1<f1 && c1<o1)
         {
            out_sell=true;
            out_is_flip=true;
            out_abs_net_lots=MathAbs(net_lots);
            return true;
         }
         if(net_lots<-1e-6 && (c1 - latest_open_px)>=flip_dist_eff && f1>s1 && m15_f>m15_s && c1>f1 && c1>o1)
         {
            out_buy=true;
            out_is_flip=true;
            out_abs_net_lots=MathAbs(net_lots);
            return true;
         }
      }
   }

   // Rule A: Unlimited Same-Side Fast Rebound Averaging in our current NET direction (cuts breakeven fast!)
   if(net_lots>1e-6 && (lowest_buy - c1)>=step_dist_eff && c1>o1)
   {
      out_buy=true;
      out_is_flip=false;
      return true;
   }
   if(net_lots<-1e-6 && (c1 - highest_sell)>=step_dist_eff && c1<o1)
   {
      out_sell=true;
      out_is_flip=false;
      return true;
   }
   return false;
}

// Close all EA positions prior to a netting FAST_FLIP to reclaim 100% of gross margin
// while recording exact LotSize-normalized realized points into g_basket_realized_pts.
bool CloseAllForNetFlip()
{
   const double pt=InputPointSize();
   if(pt<=0.0 || LotSize<=0.0) return false;
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick) || tick.bid<=0.0 || tick.ask<=0.0) return false;

   bool all_ok=true;
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC)!=MagicNumber) continue;
      ENUM_POSITION_TYPE side=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double entry=PositionGetDouble(POSITION_PRICE_OPEN);
      double vol=PositionGetDouble(POSITION_VOLUME);
      double est_pts=(side==POSITION_TYPE_BUY ? (tick.bid-entry)/pt : (entry-tick.ask)/pt)*(vol/LotSize);
      if(trade.PositionClose(ticket,SlippagePoints))
      {
         g_basket_realized_pts+=est_pts;
      }
      else
      {
         all_ok=false;
      }
   }
   return all_ok;
}

// Clamp desired recovery lot to 75% of free margin so OrderSend never fails with NO_MONEY.
double ClampLotToFreeMargin(const bool is_buy,const double desired_lot)
{
   if(desired_lot<=0.0) return 0.0;
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick)) return desired_lot;
   const double px=(is_buy ? tick.ask : tick.bid);
   const ENUM_ORDER_TYPE ot=(is_buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   double margin_1=0.0;
   if(!OrderCalcMargin(ot,_Symbol,1.0,px,margin_1) || margin_1<=0.0)
      return desired_lot;
   const double free_margin=AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(free_margin<=0.0) return 0.0;
   const double max_safe=(free_margin*0.75)/margin_1;
   if(desired_lot<=max_safe) return desired_lot;
   const double vol_min=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   const double vol_step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   if(vol_step<=0.0 || max_safe<vol_min) return 0.0;
   return MathFloor(max_safe/vol_step)*vol_step;
}

void OnTick()
{
   // Fast path when account is flat and latches/visuals are already clean (>95% of ticks).
   const int total_positions=PositionsTotal();
   if(total_positions>0)
      g_flat_cleanup_done=false;
   if(CountMyPositions()==0 && !g_basket_closing)
      g_basket_realized_pts=0.0;
   if(total_positions==0 && !g_basket_closing && g_flat_cleanup_done &&
      !g_recovery_active && !g_same_recovery_active)
   {
      bool new_bar_fast=IsNewBar();
      if(new_bar_fast)
         CleanupTrailingTPKeys();
      if(TradeOnNewBarOnly && !new_bar_fast)
         return;
   }
   else
   {
      // Synchronize the recovery latch even if entry trading is disabled.
      // The state resets ONLY after the final EA position has been closed.
      RefreshRecoveryState();
      RefreshSameSideRecoveryState();

      // v3.110 RECOVERY BREAKEVEN EXIT: end the episode the moment the basket is not losing.
      if(EnableTrading && g_recovery_active && RecoveryBreakevenExit)
      {
         double be_pts=0.0;
         if(CalculateBasketProfitPoints(be_pts) && be_pts>=0.0)
         {
            PrintFormat("RECOVERY BE EXIT: basket %.1f points -> closing all EA positions.",be_pts);
            ClosePositionsByType(POSITION_TYPE_BUY);
            ClosePositionsByType(POSITION_TYPE_SELL);
            return;
         }
      }

      // v3.108 RECOVERY TIME CAP: a recovery episode must never outlive RecoveryMaxMinutes.
      if(EnableTrading && g_recovery_active && RecoveryMaxMinutes>0 && g_recovery_started_at>0 &&
         (TimeCurrent()-g_recovery_started_at)>=(long)RecoveryMaxMinutes*60)
      {
         PrintFormat("RECOVERY TIME CAP: %d minutes exceeded -> closing all EA positions.",
                     RecoveryMaxMinutes);
         ClosePositionsByType(POSITION_TYPE_BUY);
         ClosePositionsByType(POSITION_TYPE_SELL);
         return;
      }

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
         bool realized_flip_basket=(UseFastEscapeRecovery && MathAbs(g_basket_realized_pts)>1e-6 && (buys+sells)>0);
         bool basket_mode=((hedged && UseRRTP && UseHedgeBasketTP) || same_basket || dynamic_basket || realized_flip_basket);

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

      if(total_positions==0 && !g_basket_closing && !g_recovery_active && !g_same_recovery_active)
         g_flat_cleanup_done=true;

      bool new_bar=IsNewBar();
      if(new_bar)
         CleanupTrailingTPKeys();
      if(TradeOnNewBarOnly && !new_bar)
         return;
   }

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

   // Pause all normal Entry ORs while any position/recovery is active when FastEscapeRecovery is enabled.
   const bool pause_normal_for_recovery=((UseFastEscapeRecovery && CountMyPositions()>0) || g_recovery_active);
   bool buy_signal=(pause_normal_for_recovery ? false : BuyCondition(s));
   bool sell_signal=(pause_normal_for_recovery ? false : SellCondition(s));
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
   bool fast_recov_used=false;
   bool fast_recov_is_flip=false;
   double fast_recov_abs_net=0.0;
   if(buy_signal==sell_signal && UseFastEscapeRecovery && CountMyPositions()>0)
   {
      bool fr_buy=false, fr_sell=false;
      if(EvaluateFastRecoverySignal(s,fr_buy,fr_sell,fast_recov_is_flip,fast_recov_abs_net))
      {
         buy_signal=fr_buy;
         sell_signal=fr_sell;
         fast_recov_used=true;
      }
   }
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
   if(fast_recov_used)
   {
      if(fast_recov_is_flip && fast_recov_abs_net>0.0)
      {
         // Netting-style flip: close existing legs first to free 100% of gross margin
         // while preserving exact realized P/L in g_basket_realized_pts.
         CloseAllForNetFlip();
         requested_lot=fast_recov_abs_net*MathMax(0.5,FastRecoveryNetFlipRatio);
         requested_lot=ClampLotToFreeMargin(is_buy,requested_lot);
         if(requested_lot<=0.0)
            return;
      }
      else
      {
         requested_lot=ClampLotToFreeMargin(is_buy,LotSize);
         if(requested_lot<=0.0)
            return;
      }
   }
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
                             (UseRecoveryLot && RecoveryLotMultiplier==0.0 && g_recovery_active) ||
                             (UseFastEscapeRecovery && MathAbs(g_basket_realized_pts)>1e-6));
   bool entry_needs_basket=((opening_hedge && UseRRTP && UseHedgeBasketTP) ||
                            (UseSameSideRecoveryLot &&
                             (same_side_trigger || g_same_recovery_active)) ||
                            use_dynamic_entry ||
                            (fast_recov_used && fast_recov_is_flip) ||
                            (UseFastEscapeRecovery && MathAbs(g_basket_realized_pts)>1e-6));
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
   if(!fast_recov_used)
   {
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
   string entry_source=(fast_recov_used ? (fast_recov_is_flip ? "FAST_FLIP" : "FAST_AVG") : EntryTriggerName(s,is_buy));
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
