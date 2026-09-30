//+------------------------------------------------------------------+
//|                     XAU_EMA_PA_BuyScalp_v1.52.mq5                |
//| BUY-only XAU scalper: short TP, no normal per-position SL        |
//| Risk is controlled by virtual exits, basket loss and daily lock  |
//+------------------------------------------------------------------+
#property version   "1.52"
#property strict

#include <Trade/Trade.mqh>
CTrade trade;

//==================================================================
// INPUTS
//==================================================================
input group "Trade Settings"
input double          LotSize                       = 0.01;
input ulong           MagicNumber                   = 260913;
input ENUM_TIMEFRAMES SignalTimeframe               = PERIOD_M1;
input int             TakeProfitPoints              = 150;
input int             MaxPositions                  = 3;
input int             SlippagePoints                = 30;
input int             MinMinutesBetweenEntries      = 0;

input group "Signal EMA Trend"
input int             FastEMAPeriod                 = 9;
input int             SlowEMAPeriod                 = 21;
input double          MinEMAGapPoints               = 0.0;
input bool            RequireFastEMARising          = false;
input bool            RequireFreshCross             = false;

input group "Higher Timeframe Trend (optional; OFF by default)"
input bool            UseTrendTF1                   = false;
input ENUM_TIMEFRAMES TrendTF1                      = PERIOD_M5;
input int             TrendTF1FastEMA               = 9;
input int             TrendTF1SlowEMA               = 21;
input bool            RequireTrendTF1Slope          = false;
input bool            UseTrendTF2                   = false;
input ENUM_TIMEFRAMES TrendTF2                      = PERIOD_M15;
input int             TrendTF2FastEMA               = 9;
input int             TrendTF2SlowEMA               = 21;
input bool            RequireTrendTF2Slope          = true;

input group "Price Action Entry"
input bool            UseBullishEngulfing           = true;
input bool            UseBullishPinBar              = true;
input bool            UseBullishBreakout            = true;
input double          PinBarWickBodyRatio           = 1.50;
input double          MinBodyPoints                 = 10.0;
input double          MaxEntryCandleRangePoints     = 0.0;     // 0 = disable
input int             PullbackTolerancePoints       = 180;
input int             MaxCloseDistanceFromFastEMA   = 250;
input int             BreakoutLookbackBars          = 3;
input int             BreakoutBufferPoints          = 0;
input int             BreakoutMaxExtensionPoints    = 0;      // 0 = disable extension filter
input bool            RequireCloseAboveFastEMA      = false;
input bool            UseMomentumEntry               = true;
input bool            UseEMAContinuationEntry        = true;

input group "Spread / Margin Filters"
input int             MaxSpreadPoints               = 0;      // 0 = no fixed cap
input double          MaxSpreadToTPPercent          = 0.0;    // 0 = disable percentage spread filter
input double          MinFreeMarginAfterTradePct    = 15.0;   // of account balance
input double          MinMarginLevelPercent         = 150.0;  // ignored when no margin is used
input bool            BlockForeignNettingPosition   = true;

input group "Virtual Exit - No Normal SL"
input bool            UseVirtualTrailing            = true;
input int             VirtualTrailStartPoints       = 70;
input int             VirtualTrailDistancePoints    = 45;
input bool            UseMaxHoldingTime             = true;
input int             MaxHoldingMinutes             = 20;
input bool            UseTrendInvalidationExit      = true;
input int             InvalidationConfirmBars       = 2;

input group "EA Risk Protection"
input bool            UseBasketLossProtection       = true;
input double          MaxFloatingLossPercent        = 1.25;   // only this EA + symbol
input int             BasketLossCooldownMinutes     = 30;
input bool            UseDailyLossLock              = true;
input double          MaxDailyLossPercent           = 2.00;   // realized + floating, this EA + symbol
input bool            UseLossStreakCooldown         = true;
input int             MaxConsecutiveLosses          = 2;
input int             LossCooldownMinutes           = 30;

input group "Diagnostics"
input bool            EnableDebugLog                = true;

//==================================================================
// GLOBALS
//==================================================================
int fastHandle      = INVALID_HANDLE;
int slowHandle      = INVALID_HANDLE;
int tf1FastHandle   = INVALID_HANDLE;
int tf1SlowHandle   = INVALID_HANDLE;
int tf2FastHandle   = INVALID_HANDLE;
int tf2SlowHandle   = INVALID_HANDLE;

bool     hedgingAccount      = false;
bool     buyMode             = false;
bool     dailyLocked         = false;
int      invalidationBars    = 0;
int      consecutiveLosses   = 0;
datetime lastLossTime        = 0;
datetime lastEntryTime       = 0;
datetime lastBarTime         = 0;
datetime lastStatusLog       = 0;
datetime basketBlockedUntil  = 0;
datetime cachedDayStart      = 0;
datetime lastDailyRiskCheck  = 0;
double   dailyStartBalance   = 0.0;

ulong  trailTickets[];
double trailPeaks[];

//==================================================================
// FORWARD DECLARATIONS
//==================================================================
bool   ValidateInputs();
bool   CreateEMAHandles();
void   ReleaseEMAHandles();
bool   TradeEnvironmentAllowed();
bool   EvaluateSetup(bool &freshBullCross, bool &trendBullish, bool &paSignal, string &paName);
bool   HigherTimeframeAllowsBuy(int fastH, int slowH, bool requireSlope, string label);
bool   IsBullishEngulfing(const MqlRates &now, const MqlRates &prev);
bool   IsBullishPinBar(const MqlRates &bar);
bool   IsBullishBreakout(const MqlRates &now, double swingHigh);
double GetSwingHigh(int lookbackBars);
bool   OpenBuy(string setupName);
double CalculateBuyTP(const MqlTick &tick);
double NormalizePriceUp(double price);
double NormalizeVolumeStrict(double requestedVolume);
bool   SpreadIsAllowed();
bool   MarginIsAllowed(double volume, double ask);
int    CountMyPositions();
int    EffectiveMaxPositions();
bool   HasForeignPositionOnSymbol();
double GetMyFloatingProfit();
double GetTodayRealizedProfit();
datetime DayStart(datetime t);
string GVPrefix();
void   InitializeDailyState();
void   ResetDailyStateIfNeeded();
void   LockForToday(string reason);
void   RebuildLossStateFromHistory();
bool   EntryCooldownActive();
void   ApplyRiskProtection();
void   ManageVirtualTrailing();
void   CloseExpiredPositions();
void   ManageTrendInvalidation();
void   CloseAllMyPositions(string reason);
bool   ClosePositionByTicket(ulong ticket, string reason);
bool   TradeRetcodeSuccessful(uint retcode);
void   PrintTradeFailure(string side, bool requestOK);
void   LogStatus(string message);
int    FindTrailIndex(ulong ticket);
void   SetTrailPeak(ulong ticket, double price);
void   RemoveTrailIndex(int index);
void   CleanupTrailState();

//+------------------------------------------------------------------+
//| INIT                                                             |
//+------------------------------------------------------------------+
int OnInit()
{
   if(!ValidateInputs())
      return INIT_PARAMETERS_INCORRECT;

   if(!SymbolSelect(_Symbol, true))
   {
      Print("INIT ERROR: cannot select symbol ", _Symbol, " error=", GetLastError());
      return INIT_FAILED;
   }

   if(!CreateEMAHandles())
   {
      ReleaseEMAHandles();
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetAsyncMode(false);

   ENUM_ACCOUNT_MARGIN_MODE marginMode =
      (ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE);

   hedgingAccount = (marginMode == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING);

   buyMode = false;
   invalidationBars = 0;
   lastBarTime = 0;
   basketBlockedUntil = 0;
   ArrayResize(trailTickets, 0);
   ArrayResize(trailPeaks, 0);

   InitializeDailyState();
   RebuildLossStateFromHistory();

   Print("==================================================");
   Print("EA READY: XAU_EMA_PA_BuyScalp v1.52");
   Print("BUY ONLY | TF=", EnumToString(SignalTimeframe),
         " EMA=", FastEMAPeriod, "/", SlowEMAPeriod,
         " TP=", TakeProfitPoints, " points");
   Print("HTF1=", UseTrendTF1 ? EnumToString(TrendTF1) : "OFF",
         " HTF2=", UseTrendTF2 ? EnumToString(TrendTF2) : "OFF");
   Print("ENTRY FILTERS | SpreadPct=", DoubleToString(MaxSpreadToTPPercent,1),
         "% MaxSpreadPts=", MaxSpreadPoints,
         " RequireCloseAboveEMA=", RequireCloseAboveFastEMA,
         " EntryCooldownMin=", MinMinutesBetweenEntries);
   Print("NO NORMAL SL | VirtualTrail=", UseVirtualTrailing,
         " MaxHold=", UseMaxHoldingTime,
         " TrendExit=", UseTrendInvalidationExit);
   Print("Risk | FloatLoss=", DoubleToString(MaxFloatingLossPercent,2),
         "% DailyLoss=", DoubleToString(MaxDailyLossPercent,2), "%");
   Print("AccountMode=", hedgingAccount ? "HEDGING" : "NETTING/EXCHANGE");
   Print("==================================================");

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| DEINIT                                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   ReleaseEMAHandles();
}

//+------------------------------------------------------------------+
//| TRADE TRANSACTION                                                |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD || trans.deal == 0)
      return;

   if(!HistoryDealSelect(trans.deal))
      return;

   string symbol = HistoryDealGetString(trans.deal, DEAL_SYMBOL);
   ulong magic = (ulong)HistoryDealGetInteger(trans.deal, DEAL_MAGIC);
   ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal, DEAL_ENTRY);

   if(symbol != _Symbol || magic != MagicNumber)
      return;

   if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY)
      RebuildLossStateFromHistory();
}

//+------------------------------------------------------------------+
//| ON TICK                                                          |
//+------------------------------------------------------------------+
void OnTick()
{
   ResetDailyStateIfNeeded();

   // Existing positions are managed even while new entries are blocked.
   ManageVirtualTrailing();
   CloseExpiredPositions();
   ApplyRiskProtection();

   if(dailyLocked)
   {
      LogStatus("NO TRADE: daily loss lock active");
      return;
   }

   if(TimeCurrent() < basketBlockedUntil)
   {
      LogStatus("NO TRADE: basket-loss cooldown active");
      return;
   }

   if(!TradeEnvironmentAllowed())
      return;

   datetime currentBar = iTime(_Symbol, SignalTimeframe, 0);
   if(currentBar <= 0)
   {
      LogStatus("NO TRADE: cannot read current bar time");
      return;
   }

   if(currentBar == lastBarTime)
      return;

   lastBarTime = currentBar;

   if(UseTrendInvalidationExit)
      ManageTrendInvalidation();

   // Re-check protection after an exit on the new bar.
   if(dailyLocked || TimeCurrent() < basketBlockedUntil)
      return;

   bool freshBullCross = false;
   bool trendBullish = false;
   bool paSignal = false;
   string paName = "";

   if(!EvaluateSetup(freshBullCross, trendBullish, paSignal, paName))
      return;

   if(!trendBullish)
   {
      buyMode = false;
      if(EnableDebugLog)
         Print("BUY MODE OFF: signal trend is not bullish");
      return;
   }

   if(freshBullCross)
      buyMode = true;
   else if(!RequireFreshCross)
      buyMode = true;

   if(!buyMode)
   {
      if(EnableDebugLog)
         Print("NO ENTRY: waiting for fresh bullish EMA cross");
      return;
   }

   if(!paSignal)
   {
      if(EnableDebugLog)
         Print("NO ENTRY: bullish trend but no valid PA setup");
      return;
   }

   if(EntryCooldownActive())
      return;

   int currentPositions = CountMyPositions();
   int maxPositions = EffectiveMaxPositions();

   if(currentPositions >= maxPositions)
   {
      if(EnableDebugLog)
         Print("NO ENTRY: MaxPositions reached | current=", currentPositions,
               " max=", maxPositions);
      return;
   }

   if(!hedgingAccount && BlockForeignNettingPosition && HasForeignPositionOnSymbol())
   {
      LogStatus("NO TRADE: foreign position exists on netting symbol");
      return;
   }

   if(!SpreadIsAllowed())
      return;

   if(EnableDebugLog)
      Print("BUY SETUP: ", paName);

   OpenBuy(paName);
}

//+------------------------------------------------------------------+
//| INPUT VALIDATION                                                 |
//+------------------------------------------------------------------+
bool ValidateInputs()
{
   if(LotSize <= 0.0)                                  { Print("INIT ERROR: LotSize must be > 0"); return false; }
   if(TakeProfitPoints <= 0)                           { Print("INIT ERROR: TakeProfitPoints must be > 0"); return false; }
   if(MaxPositions < 1)                                { Print("INIT ERROR: MaxPositions must be >= 1"); return false; }
   if(FastEMAPeriod < 1 || SlowEMAPeriod <= FastEMAPeriod)
                                                       { Print("INIT ERROR: invalid signal EMA periods"); return false; }
   if(UseTrendTF1 && (TrendTF1FastEMA < 1 || TrendTF1SlowEMA <= TrendTF1FastEMA))
                                                       { Print("INIT ERROR: invalid TrendTF1 EMA periods"); return false; }
   if(UseTrendTF2 && (TrendTF2FastEMA < 1 || TrendTF2SlowEMA <= TrendTF2FastEMA))
                                                       { Print("INIT ERROR: invalid TrendTF2 EMA periods"); return false; }
   if(PinBarWickBodyRatio <= 0.0)                      { Print("INIT ERROR: PinBarWickBodyRatio invalid"); return false; }
   if(MinBodyPoints < 0.0 || MaxEntryCandleRangePoints < 0.0)
                                                       { Print("INIT ERROR: invalid candle-size settings"); return false; }
   if(PullbackTolerancePoints < 0 || MaxCloseDistanceFromFastEMA < 0)
                                                       { Print("INIT ERROR: invalid pullback settings"); return false; }
   if(BreakoutLookbackBars < 2 || BreakoutBufferPoints < 0 || BreakoutMaxExtensionPoints < 0)
                                                       { Print("INIT ERROR: invalid breakout settings"); return false; }
   if(MaxSpreadPoints < 0 || MaxSpreadToTPPercent < 0.0)
                                                       { Print("INIT ERROR: invalid spread settings"); return false; }
   if(SlippagePoints < 0 || MinMinutesBetweenEntries < 0)
                                                       { Print("INIT ERROR: invalid execution settings"); return false; }
   if(UseVirtualTrailing && (VirtualTrailStartPoints <= 0 || VirtualTrailDistancePoints <= 0))
                                                       { Print("INIT ERROR: invalid virtual trailing settings"); return false; }
   if(UseMaxHoldingTime && MaxHoldingMinutes <= 0)     { Print("INIT ERROR: MaxHoldingMinutes invalid"); return false; }
   if(UseTrendInvalidationExit && InvalidationConfirmBars < 1)
                                                       { Print("INIT ERROR: InvalidationConfirmBars invalid"); return false; }
   if(UseBasketLossProtection && MaxFloatingLossPercent <= 0.0)
                                                       { Print("INIT ERROR: MaxFloatingLossPercent invalid"); return false; }
   if(UseDailyLossLock && MaxDailyLossPercent <= 0.0) { Print("INIT ERROR: MaxDailyLossPercent invalid"); return false; }
   if(UseLossStreakCooldown && (MaxConsecutiveLosses < 1 || LossCooldownMinutes <= 0))
                                                       { Print("INIT ERROR: invalid loss cooldown settings"); return false; }
   if(MinFreeMarginAfterTradePct < 0.0 || MinMarginLevelPercent < 0.0)
                                                       { Print("INIT ERROR: invalid margin settings"); return false; }
   return true;
}

//+------------------------------------------------------------------+
//| EMA HANDLES                                                      |
//+------------------------------------------------------------------+
bool CreateEMAHandles()
{
   fastHandle = iMA(_Symbol, SignalTimeframe, FastEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   slowHandle = iMA(_Symbol, SignalTimeframe, SlowEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);

   if(fastHandle == INVALID_HANDLE || slowHandle == INVALID_HANDLE)
   {
      Print("INIT ERROR: cannot create signal EMA handles. error=", GetLastError());
      return false;
   }

   if(UseTrendTF1)
   {
      tf1FastHandle = iMA(_Symbol, TrendTF1, TrendTF1FastEMA, 0, MODE_EMA, PRICE_CLOSE);
      tf1SlowHandle = iMA(_Symbol, TrendTF1, TrendTF1SlowEMA, 0, MODE_EMA, PRICE_CLOSE);
      if(tf1FastHandle == INVALID_HANDLE || tf1SlowHandle == INVALID_HANDLE)
      {
         Print("INIT ERROR: cannot create TrendTF1 EMA handles. error=", GetLastError());
         return false;
      }
   }

   if(UseTrendTF2)
   {
      tf2FastHandle = iMA(_Symbol, TrendTF2, TrendTF2FastEMA, 0, MODE_EMA, PRICE_CLOSE);
      tf2SlowHandle = iMA(_Symbol, TrendTF2, TrendTF2SlowEMA, 0, MODE_EMA, PRICE_CLOSE);
      if(tf2FastHandle == INVALID_HANDLE || tf2SlowHandle == INVALID_HANDLE)
      {
         Print("INIT ERROR: cannot create TrendTF2 EMA handles. error=", GetLastError());
         return false;
      }
   }

   return true;
}

void ReleaseEMAHandles()
{
   if(fastHandle != INVALID_HANDLE)    { IndicatorRelease(fastHandle); fastHandle = INVALID_HANDLE; }
   if(slowHandle != INVALID_HANDLE)    { IndicatorRelease(slowHandle); slowHandle = INVALID_HANDLE; }
   if(tf1FastHandle != INVALID_HANDLE) { IndicatorRelease(tf1FastHandle); tf1FastHandle = INVALID_HANDLE; }
   if(tf1SlowHandle != INVALID_HANDLE) { IndicatorRelease(tf1SlowHandle); tf1SlowHandle = INVALID_HANDLE; }
   if(tf2FastHandle != INVALID_HANDLE) { IndicatorRelease(tf2FastHandle); tf2FastHandle = INVALID_HANDLE; }
   if(tf2SlowHandle != INVALID_HANDLE) { IndicatorRelease(tf2SlowHandle); tf2SlowHandle = INVALID_HANDLE; }
}

//+------------------------------------------------------------------+
//| SETUP                                                            |
//+------------------------------------------------------------------+
bool EvaluateSetup(bool &freshBullCross,
                   bool &trendBullish,
                   bool &paSignal,
                   string &paName)
{
   freshBullCross = false;
   trendBullish = false;
   paSignal = false;
   paName = "";

   if(fastHandle == INVALID_HANDLE || slowHandle == INVALID_HANDLE)
      return false;

   if(BarsCalculated(fastHandle) < 3 || BarsCalculated(slowHandle) < 3)
   {
      LogStatus("DATA WAIT: signal EMA not ready");
      return false;
   }

   double fast[2];
   double slow[2];
   MqlRates rates[3];

   ResetLastError();
   int fastCopied = CopyBuffer(fastHandle, 0, 1, 2, fast);
   int slowCopied = CopyBuffer(slowHandle, 0, 1, 2, slow);
   int rateCopied = CopyRates(_Symbol, SignalTimeframe, 1, 3, rates);

   if(fastCopied != 2 || slowCopied != 2 || rateCopied != 3)
   {
      LogStatus(StringFormat("DATA ERROR: Copy failed | fast=%d slow=%d rates=%d err=%d",
                            fastCopied, slowCopied, rateCopied, GetLastError()));
      return false;
   }

   double fastPrev = fast[0];
   double fastNow  = fast[1];
   double slowPrev = slow[0];
   double slowNow  = slow[1];

   MqlRates prev = rates[1];
   MqlRates now  = rates[2];

   double emaGapPoints = (fastNow - slowNow) / _Point;
   bool fastRising = (fastNow > fastPrev);

   trendBullish = (fastNow > slowNow && emaGapPoints >= MinEMAGapPoints);
   if(RequireFastEMARising)
      trendBullish = trendBullish && fastRising;

   freshBullCross = (fastPrev <= slowPrev && fastNow > slowNow);

   bool tf1Bull = true;
   bool tf2Bull = true;

   if(UseTrendTF1)
      tf1Bull = HigherTimeframeAllowsBuy(tf1FastHandle, tf1SlowHandle, RequireTrendTF1Slope, "TF1");
   if(UseTrendTF2)
      tf2Bull = HigherTimeframeAllowsBuy(tf2FastHandle, tf2SlowHandle, RequireTrendTF2Slope, "TF2");

   trendBullish = trendBullish && tf1Bull && tf2Bull;

   double rangePoints = (now.high - now.low) / _Point;
   if(rangePoints <= 0.0 || (MaxEntryCandleRangePoints > 0.0 && rangePoints > MaxEntryCandleRangePoints))
   {
      if(EnableDebugLog)
         Print("NO ENTRY: candle range invalid/too large | range=", DoubleToString(rangePoints,1));
      return true;
   }

   bool closeAboveFast = (now.close >= fastNow);
   if(RequireCloseAboveFastEMA && !closeAboveFast)
   {
      if(EnableDebugLog)
         Print("NO ENTRY: candle closed below fast EMA");
      return true;
   }

   double tolerance = PullbackTolerancePoints * _Point;
   bool touchedFast = (PullbackTolerancePoints <= 0) ||
                      (now.low <= fastNow + tolerance && now.high >= fastNow - tolerance);

   bool closeNearFast = (MaxCloseDistanceFromFastEMA <= 0) ||
                        (MathAbs(now.close - fastNow) / _Point <= MaxCloseDistanceFromFastEMA);

   bool engulf = UseBullishEngulfing && IsBullishEngulfing(now, prev);
   bool pinbar = UseBullishPinBar && IsBullishPinBar(now);

   double swingHigh = 0.0;
   bool breakout = false;
   if(UseBullishBreakout)
   {
      swingHigh = GetSwingHigh(BreakoutLookbackBars);
      if(swingHigh > 0.0)
         breakout = IsBullishBreakout(now, swingHigh);
   }

   // Do not require every filter to line up on the exact same candle.
   // Pullback context can be either a touch of EMA or a close reasonably near EMA.
   bool pullbackContext = touchedFast || closeNearFast;
   bool pullbackSignal = pullbackContext && (engulf || pinbar);

   double bodyPoints = MathAbs(now.close - now.open) / _Point;
   double extensionPoints = MathMax(0.0, (now.close - fastNow) / _Point);
   bool notOverExtended = (BreakoutMaxExtensionPoints <= 0 ||
                           extensionPoints <= BreakoutMaxExtensionPoints);

   bool breakoutSignal = breakout && notOverExtended;

   // Fast continuation trigger: bullish close through previous high.
   bool momentumSignal = UseMomentumEntry &&
                         now.close > now.open &&
                         bodyPoints >= MinBodyPoints &&
                         now.close > prev.high &&
                         notOverExtended;

   // Pullback/continuation trigger: current or previous candle interacts with EMA,
   // then the current candle closes bullish back above the fast EMA.
   double prevTolerance = PullbackTolerancePoints * _Point;
   bool currentOrPreviousTouchedEMA =
      (PullbackTolerancePoints <= 0) ||
      touchedFast ||
      (prev.low <= fastPrev + prevTolerance && prev.high >= fastPrev - prevTolerance);

   bool emaContinuationSignal = UseEMAContinuationEntry &&
                                currentOrPreviousTouchedEMA &&
                                now.close > now.open &&
                                bodyPoints >= MinBodyPoints &&
                                now.close >= fastNow &&
                                closeNearFast;

   paSignal = trendBullish &&
              (pullbackSignal || breakoutSignal || momentumSignal || emaContinuationSignal);

   if(paSignal)
   {
      if(engulf && pullbackContext)
         paName = "PA ENGULF";
      else if(pinbar && pullbackContext)
         paName = "PA PINBAR";
      else if(breakoutSignal)
         paName = "SWING BREAKOUT";
      else if(momentumSignal)
         paName = "MOMENTUM";
      else if(emaContinuationSignal)
         paName = "EMA CONTINUATION";
      else
         paName = "PA BUY";
   }

   if(EnableDebugLog)
   {
      Print("SETUP | ", TimeToString(now.time, TIME_DATE|TIME_MINUTES),
            " Fast=", DoubleToString(fastNow,_Digits),
            " Slow=", DoubleToString(slowNow,_Digits),
            " Gap=", DoubleToString(emaGapPoints,1),
            " TF1=", tf1Bull,
            " TF2=", tf2Bull,
            " Touch=", touchedFast,
            " CloseNear=", closeNearFast,
            " Engulf=", engulf,
            " Pin=", pinbar,
            " Breakout=", breakout,
            " Mom=", momentumSignal,
            " EMACont=", emaContinuationSignal,
            " Ext=", DoubleToString(extensionPoints,1),
            " PA=", paSignal);
   }

   return true;
}

bool HigherTimeframeAllowsBuy(int fastH, int slowH, bool requireSlope, string label)
{
   if(fastH == INVALID_HANDLE || slowH == INVALID_HANDLE)
      return false;

   if(BarsCalculated(fastH) < 3 || BarsCalculated(slowH) < 3)
   {
      LogStatus("DATA WAIT: " + label + " EMA not ready");
      return false;
   }

   double fast[2];
   double slow[2];
   int a = CopyBuffer(fastH, 0, 1, 2, fast);
   int b = CopyBuffer(slowH, 0, 1, 2, slow);

   if(a != 2 || b != 2)
      return false;

   double fastPrev = fast[0];
   double fastNow  = fast[1];
   double slowNow  = slow[1];

   // Higher TF is a veto, not a mandatory perfect alignment.
   // Block only when it is clearly bearish. If strict slope is requested,
   // retain the old strict behaviour as an optional setting.
   if(requireSlope)
      return (fastNow > slowNow && fastNow > fastPrev);

   bool strongBearish = (fastNow < slowNow && fastNow < fastPrev);
   return !strongBearish;
}

//+------------------------------------------------------------------+
//| PRICE ACTION                                                     |
//+------------------------------------------------------------------+
bool IsBullishEngulfing(const MqlRates &now, const MqlRates &prev)
{
   double bodyPoints = MathAbs(now.close - now.open) / _Point;
   if(bodyPoints < MinBodyPoints)
      return false;

   if(now.close <= now.open || prev.close >= prev.open)
      return false;

   return (now.open <= prev.close && now.close >= prev.open);
}

bool IsBullishPinBar(const MqlRates &bar)
{
   double body = MathAbs(bar.close - bar.open);
   double lowerWick = MathMin(bar.open, bar.close) - bar.low;
   double upperWick = bar.high - MathMax(bar.open, bar.close);
   double range = bar.high - bar.low;

   if(range <= 0.0 || body / _Point < MinBodyPoints)
      return false;

   double safeBody = MathMax(body, _Point);
   bool strongLowerWick = (lowerWick >= safeBody * PinBarWickBodyRatio);
   bool lowerDominates = (lowerWick > upperWick);
   bool closesHigh = (bar.close >= bar.low + range * 0.60);
   bool bullishClose = (bar.close > bar.open);

   return strongLowerWick && lowerDominates && closesHigh && bullishClose;
}

bool IsBullishBreakout(const MqlRates &now, double swingHigh)
{
   double bodyPoints = MathAbs(now.close - now.open) / _Point;
   if(bodyPoints < MinBodyPoints)
      return false;

   double trigger = swingHigh + BreakoutBufferPoints * _Point;
   return (now.close > now.open && now.close > trigger);
}

double GetSwingHigh(int lookbackBars)
{
   if(lookbackBars < 2)
      return 0.0;

   double highest = 0.0;

   // Current signal candle is shift 1, so use shifts 2..lookback+1.
   for(int shift = 2; shift <= lookbackBars + 1; shift++)
   {
      double h = iHigh(_Symbol, SignalTimeframe, shift);
      if(h <= 0.0)
         return 0.0;
      if(h > highest)
         highest = h;
   }

   return highest;
}

//+------------------------------------------------------------------+
//| OPEN BUY                                                         |
//+------------------------------------------------------------------+
bool OpenBuy(string setupName)
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick) || tick.ask <= 0.0 || tick.bid <= 0.0)
   {
      Print("BUY ERROR: invalid tick");
      return false;
   }

   double volume = NormalizeVolumeStrict(LotSize);
   if(volume <= 0.0)
   {
      Print("BUY ERROR: requested LotSize is not valid for broker volume rules");
      return false;
   }

   if(!MarginIsAllowed(volume, tick.ask))
      return false;

   double tp = CalculateBuyTP(tick);
   if(tp <= tick.ask)
   {
      Print("BUY ERROR: invalid TP | ask=", DoubleToString(tick.ask,_Digits),
            " tp=", DoubleToString(tp,_Digits));
      return false;
   }

   ResetLastError();
   bool requestOK = trade.Buy(volume, _Symbol, 0.0, 0.0, tp, setupName);
   uint retcode = trade.ResultRetcode();

   if(!requestOK || !TradeRetcodeSuccessful(retcode))
   {
      PrintTradeFailure("BUY", requestOK);
      return false;
   }

   lastEntryTime = TimeCurrent();

   Print("BUY OPENED | setup=", setupName,
         " volume=", DoubleToString(volume,2),
         " price=", DoubleToString(trade.ResultPrice(),_Digits),
         " tp=", DoubleToString(tp,_Digits),
         " retcode=", retcode);

   return true;
}

double CalculateBuyTP(const MqlTick &tick)
{
   long stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);

   double requestedTP = tick.ask + TakeProfitPoints * _Point;
   double minimumTP = tick.bid + (stopsLevel + 1) * _Point;
   double tp = MathMax(requestedTP, minimumTP);

   return NormalizePriceUp(tp);
}

double NormalizePriceUp(double price)
{
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize <= 0.0)
      tickSize = _Point;

   double steps = MathCeil(price / tickSize - 1e-10);
   return NormalizeDouble(steps * tickSize, _Digits);
}

//+------------------------------------------------------------------+
//| POSITION / ACCOUNT FILTERS                                       |
//+------------------------------------------------------------------+
int CountMyPositions()
{
   int count = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;

      count++;
   }

   return count;
}

int EffectiveMaxPositions()
{
   return hedgingAccount ? MaxPositions : 1;
}

bool HasForeignPositionOnSymbol()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      ulong magic = (ulong)PositionGetInteger(POSITION_MAGIC);
      if(magic != MagicNumber)
         return true;
   }

   return false;
}

bool SpreadIsAllowed()
{
   if(MaxSpreadPoints <= 0 && MaxSpreadToTPPercent <= 0.0)
      return true;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick) || tick.ask <= 0.0 || tick.bid <= 0.0)
      return false;

   double spreadPoints = (tick.ask - tick.bid) / _Point;

   if(MaxSpreadPoints > 0 && spreadPoints > MaxSpreadPoints)
   {
      if(EnableDebugLog)
         Print("NO TRADE: spread=", DoubleToString(spreadPoints,1),
               " > fixed max=", MaxSpreadPoints);
      return false;
   }

   if(MaxSpreadToTPPercent > 0.0)
   {
      double ratio = spreadPoints / TakeProfitPoints * 100.0;
      if(ratio > MaxSpreadToTPPercent)
      {
         if(EnableDebugLog)
            Print("NO TRADE: spread/TP=", DoubleToString(ratio,1),
                  "% > max=", DoubleToString(MaxSpreadToTPPercent,1), "%");
         return false;
      }
   }

   return true;
}

double NormalizeVolumeStrict(double requestedVolume)
{
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(minLot <= 0.0 || maxLot <= 0.0 || step <= 0.0)
      return 0.0;

   // Never silently increase risk to broker minimum or clamp above max.
   if(requestedVolume < minLot - 1e-9 || requestedVolume > maxLot + 1e-9)
   {
      Print("VOLUME REJECTED | requested=", DoubleToString(requestedVolume,8),
            " min=", DoubleToString(minLot,8),
            " max=", DoubleToString(maxLot,8));
      return 0.0;
   }

   double volume = MathFloor(requestedVolume / step + 1e-9) * step;
   volume = NormalizeDouble(volume, 8);

   if(volume < minLot - 1e-9 || volume > maxLot + 1e-9)
      return 0.0;

   return volume;
}

bool MarginIsAllowed(double volume, double ask)
{
   double requiredMargin = 0.0;
   if(!OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, volume, ask, requiredMargin))
   {
      Print("NO TRADE: OrderCalcMargin failed error=", GetLastError());
      return false;
   }

   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double remaining = freeMargin - requiredMargin;

   if(remaining < 0.0)
   {
      Print("NO TRADE: insufficient free margin");
      return false;
   }

   if(MinFreeMarginAfterTradePct > 0.0 && balance > 0.0)
   {
      double minRemaining = balance * MinFreeMarginAfterTradePct / 100.0;
      if(remaining < minRemaining)
      {
         Print("NO TRADE: free margin reserve too low | after=",
               DoubleToString(remaining,2), " requiredReserve=", DoubleToString(minRemaining,2));
         return false;
      }
   }

   if(MinMarginLevelPercent > 0.0)
   {
      double margin = AccountInfoDouble(ACCOUNT_MARGIN);
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      if(margin > 0.0)
      {
         double projectedLevel = equity / (margin + requiredMargin) * 100.0;
         if(projectedLevel < MinMarginLevelPercent)
         {
            Print("NO TRADE: projected margin level=", DoubleToString(projectedLevel,1),
                  "% < min=", DoubleToString(MinMarginLevelPercent,1), "%");
            return false;
         }
      }
   }

   return true;
}

//+------------------------------------------------------------------+
//| TRADING ENVIRONMENT                                              |
//+------------------------------------------------------------------+
bool TradeEnvironmentAllowed()
{
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
   {
      LogStatus("NO TRADE: Algo Trading disabled");
      return false;
   }

   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
   {
      LogStatus("NO TRADE: EA trading permission disabled");
      return false;
   }

   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED) ||
      !AccountInfoInteger(ACCOUNT_TRADE_EXPERT))
   {
      LogStatus("NO TRADE: account/expert trading disabled");
      return false;
   }

   ENUM_SYMBOL_TRADE_MODE mode =
      (ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);

   if(mode == SYMBOL_TRADE_MODE_DISABLED ||
      mode == SYMBOL_TRADE_MODE_CLOSEONLY ||
      mode == SYMBOL_TRADE_MODE_SHORTONLY)
   {
      LogStatus("NO TRADE: symbol does not allow BUY");
      return false;
   }

   return true;
}

//+------------------------------------------------------------------+
//| DAILY STATE                                                      |
//+------------------------------------------------------------------+
datetime DayStart(datetime t)
{
   MqlDateTime dt;
   TimeToStruct(t, dt);
   dt.hour = 0;
   dt.min  = 0;
   dt.sec  = 0;
   return StructToTime(dt);
}

string GVPrefix()
{
   return "XAU_SCALP_" + (string)AccountInfoInteger(ACCOUNT_LOGIN) +
          "_" + _Symbol + "_" + (string)MagicNumber;
}

void InitializeDailyState()
{
   cachedDayStart = DayStart(TimeCurrent());

   string prefix = GVPrefix();
   string markerName = prefix + "_DAY";
   string balanceName = prefix + "_BAL";
   string lockName = prefix + "_LOCK";

   double marker = GlobalVariableCheck(markerName) ? GlobalVariableGet(markerName) : 0.0;

   if((datetime)marker != cachedDayStart)
   {
      double realized = GetTodayRealizedProfit();
      dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE) - realized;
      if(dailyStartBalance <= 0.0)
         dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);

      GlobalVariableSet(markerName, (double)cachedDayStart);
      GlobalVariableSet(balanceName, dailyStartBalance);

      if(GlobalVariableCheck(lockName))
         GlobalVariableDel(lockName);

      dailyLocked = false;
   }
   else
   {
      dailyStartBalance = GlobalVariableCheck(balanceName)
                          ? GlobalVariableGet(balanceName)
                          : AccountInfoDouble(ACCOUNT_BALANCE);

      double lockDay = GlobalVariableCheck(lockName) ? GlobalVariableGet(lockName) : 0.0;
      dailyLocked = ((datetime)lockDay == cachedDayStart);
   }
}

void ResetDailyStateIfNeeded()
{
   datetime nowDay = DayStart(TimeCurrent());
   if(nowDay == cachedDayStart)
      return;

   consecutiveLosses = 0;
   lastLossTime = 0;
   basketBlockedUntil = 0;
   InitializeDailyState();
   RebuildLossStateFromHistory();

   Print("NEW TRADING DAY | daily risk state reset");
}

void LockForToday(string reason)
{
   dailyLocked = true;
   GlobalVariableSet(GVPrefix() + "_LOCK", (double)cachedDayStart);
   Print("DAILY LOCK ACTIVE | reason=", reason,
         " until next broker/server day");
}

//+------------------------------------------------------------------+
//| P/L HELPERS                                                      |
//+------------------------------------------------------------------+
double GetMyFloatingProfit()
{
   double total = 0.0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;

      total += PositionGetDouble(POSITION_PROFIT);
      total += PositionGetDouble(POSITION_SWAP);
   }

   return total;
}

double GetTodayRealizedProfit()
{
   datetime start = DayStart(TimeCurrent());
   datetime now = TimeCurrent();

   if(!HistorySelect(start, now))
      return 0.0;

   double total = 0.0;
   int deals = HistoryDealsTotal();

   for(int i = 0; i < deals; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0)
         continue;

      if(HistoryDealGetString(ticket, DEAL_SYMBOL) != _Symbol)
         continue;

      if((ulong)HistoryDealGetInteger(ticket, DEAL_MAGIC) != MagicNumber)
         continue;

      total += HistoryDealGetDouble(ticket, DEAL_PROFIT);
      total += HistoryDealGetDouble(ticket, DEAL_SWAP);
      total += HistoryDealGetDouble(ticket, DEAL_COMMISSION);
      total += HistoryDealGetDouble(ticket, DEAL_FEE);
   }

   return total;
}

void RebuildLossStateFromHistory()
{
   consecutiveLosses = 0;
   lastLossTime = 0;

   datetime start = DayStart(TimeCurrent());
   datetime now = TimeCurrent();

   if(!HistorySelect(start, now))
      return;

   int deals = HistoryDealsTotal();

   // Scan newest to oldest; stop at the first non-losing exit.
   for(int i = deals - 1; i >= 0; i--)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0)
         continue;

      if(HistoryDealGetString(ticket, DEAL_SYMBOL) != _Symbol)
         continue;

      if((ulong)HistoryDealGetInteger(ticket, DEAL_MAGIC) != MagicNumber)
         continue;

      ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(ticket, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY)
         continue;

      double net = HistoryDealGetDouble(ticket, DEAL_PROFIT) +
                   HistoryDealGetDouble(ticket, DEAL_SWAP) +
                   HistoryDealGetDouble(ticket, DEAL_COMMISSION) +
                   HistoryDealGetDouble(ticket, DEAL_FEE);

      if(net < 0.0)
      {
         consecutiveLosses++;
         if(lastLossTime == 0)
            lastLossTime = (datetime)HistoryDealGetInteger(ticket, DEAL_TIME);
      }
      else
      {
         break;
      }
   }
}

bool EntryCooldownActive()
{
   datetime now = TimeCurrent();

   if(MinMinutesBetweenEntries > 0 && lastEntryTime > 0 &&
      now - lastEntryTime < MinMinutesBetweenEntries * 60)
   {
      if(EnableDebugLog)
         Print("NO ENTRY: entry spacing cooldown active");
      return true;
   }

   if(UseLossStreakCooldown &&
      consecutiveLosses >= MaxConsecutiveLosses &&
      lastLossTime > 0 &&
      now - lastLossTime < LossCooldownMinutes * 60)
   {
      if(EnableDebugLog)
         Print("NO ENTRY: loss-streak cooldown | losses=", consecutiveLosses);
      return true;
   }

   return false;
}

//+------------------------------------------------------------------+
//| RISK PROTECTION                                                  |
//+------------------------------------------------------------------+
void ApplyRiskProtection()
{
   double base = dailyStartBalance;
   if(base <= 0.0)
      base = AccountInfoDouble(ACCOUNT_BALANCE);
   if(base <= 0.0)
      return;

   double floating = GetMyFloatingProfit();

   if(UseBasketLossProtection && floating < 0.0)
   {
      double floatingLossPct = (-floating / base) * 100.0;

      if(floatingLossPct >= MaxFloatingLossPercent)
      {
         Print("BASKET LOSS GUARD | floating=", DoubleToString(floating,2),
               " loss=", DoubleToString(floatingLossPct,2), "%");

         CloseAllMyPositions("BASKET LOSS");
         basketBlockedUntil = TimeCurrent() + BasketLossCooldownMinutes * 60;
         return;
      }
   }

   if(!UseDailyLossLock || dailyLocked)
      return;

   datetime now = TimeCurrent();
   if(lastDailyRiskCheck > 0 && now - lastDailyRiskCheck < 5)
      return;

   lastDailyRiskCheck = now;

   double realized = GetTodayRealizedProfit();
   double dayNet = realized + floating;

   if(dayNet < 0.0)
   {
      double dailyLossPct = (-dayNet / base) * 100.0;
      if(dailyLossPct >= MaxDailyLossPercent)
      {
         Print("DAILY LOSS GUARD | realized=", DoubleToString(realized,2),
               " floating=", DoubleToString(floating,2),
               " loss=", DoubleToString(dailyLossPct,2), "%");

         CloseAllMyPositions("DAILY LOSS");
         LockForToday("MAX DAILY LOSS");
      }
   }
}

//+------------------------------------------------------------------+
//| VIRTUAL TRAILING                                                 |
//+------------------------------------------------------------------+
void ManageVirtualTrailing()
{
   if(!UseVirtualTrailing || VirtualTrailStartPoints <= 0 || VirtualTrailDistancePoints <= 0)
      return;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick) || tick.bid <= 0.0)
      return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_BUY)
         continue;

      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      if(openPrice <= 0.0)
         continue;

      int idx = FindTrailIndex(ticket);
      double peak = (idx >= 0) ? trailPeaks[idx] : MathMax(openPrice, tick.bid);

      if(tick.bid > peak)
         peak = tick.bid;

      SetTrailPeak(ticket, peak);

      double peakGainPoints = (peak - openPrice) / _Point;
      double pullbackPoints = (peak - tick.bid) / _Point;

      if(peakGainPoints >= VirtualTrailStartPoints &&
         pullbackPoints >= VirtualTrailDistancePoints)
      {
         ClosePositionByTicket(ticket, "VIRTUAL TRAIL");
      }
   }

   CleanupTrailState();
}

//+------------------------------------------------------------------+
//| MAX HOLDING TIME                                                 |
//+------------------------------------------------------------------+
void CloseExpiredPositions()
{
   if(!UseMaxHoldingTime || MaxHoldingMinutes <= 0)
      return;

   datetime now = TimeCurrent();

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;

      datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
      if(openTime <= 0)
         continue;

      if(now - openTime >= MaxHoldingMinutes * 60)
         ClosePositionByTicket(ticket, "MAX HOLD TIME");
   }
}

//+------------------------------------------------------------------+
//| TREND INVALIDATION EXIT                                          |
//+------------------------------------------------------------------+
void ManageTrendInvalidation()
{
   if(CountMyPositions() <= 0)
   {
      invalidationBars = 0;
      return;
   }

   if(fastHandle == INVALID_HANDLE || slowHandle == INVALID_HANDLE)
      return;

   double fast[1];
   double slow[1];
   if(CopyBuffer(fastHandle, 0, 1, 1, fast) != 1 ||
      CopyBuffer(slowHandle, 0, 1, 1, slow) != 1)
      return;

   double close1 = iClose(_Symbol, SignalTimeframe, 1);
   if(close1 <= 0.0)
      return;

   bool invalid = (fast[0] <= slow[0] && close1 < slow[0]);

   if(invalid)
      invalidationBars++;
   else
      invalidationBars = 0;

   if(invalidationBars >= InvalidationConfirmBars)
   {
      Print("TREND INVALIDATION | bars=", invalidationBars);
      CloseAllMyPositions("TREND INVALID");
      invalidationBars = 0;
   }
}

//+------------------------------------------------------------------+
//| CLOSE HELPERS                                                    |
//+------------------------------------------------------------------+
void CloseAllMyPositions(string reason)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;

      ClosePositionByTicket(ticket, reason);
   }
}

bool ClosePositionByTicket(ulong ticket, string reason)
{
   if(!PositionSelectByTicket(ticket))
      return false;

   ResetLastError();
   bool requestOK = trade.PositionClose(ticket);
   uint retcode = trade.ResultRetcode();

   if(!requestOK || !TradeRetcodeSuccessful(retcode))
   {
      Print("CLOSE ERROR | ticket=", ticket,
            " reason=", reason,
            " retcode=", retcode,
            " ", trade.ResultRetcodeDescription(),
            " err=", GetLastError());
      return false;
   }

   Print("POSITION CLOSED | ticket=", ticket, " reason=", reason);
   return true;
}

//+------------------------------------------------------------------+
//| TRAILING STATE                                                   |
//+------------------------------------------------------------------+
int FindTrailIndex(ulong ticket)
{
   int n = ArraySize(trailTickets);
   for(int i = 0; i < n; i++)
      if(trailTickets[i] == ticket)
         return i;
   return -1;
}

void SetTrailPeak(ulong ticket, double price)
{
   int idx = FindTrailIndex(ticket);
   if(idx >= 0)
   {
      if(price > trailPeaks[idx])
         trailPeaks[idx] = price;
      return;
   }

   int n = ArraySize(trailTickets);
   ArrayResize(trailTickets, n + 1);
   ArrayResize(trailPeaks, n + 1);
   trailTickets[n] = ticket;
   trailPeaks[n] = price;
}

void RemoveTrailIndex(int index)
{
   int n = ArraySize(trailTickets);
   if(index < 0 || index >= n)
      return;

   int last = n - 1;
   if(index != last)
   {
      trailTickets[index] = trailTickets[last];
      trailPeaks[index] = trailPeaks[last];
   }

   ArrayResize(trailTickets, last);
   ArrayResize(trailPeaks, last);
}

void CleanupTrailState()
{
   for(int i = ArraySize(trailTickets) - 1; i >= 0; i--)
   {
      if(!PositionSelectByTicket(trailTickets[i]))
         RemoveTrailIndex(i);
   }
}

//+------------------------------------------------------------------+
//| TRADE RESULT                                                     |
//+------------------------------------------------------------------+
bool TradeRetcodeSuccessful(uint retcode)
{
   return (retcode == TRADE_RETCODE_DONE ||
           retcode == TRADE_RETCODE_DONE_PARTIAL ||
           retcode == TRADE_RETCODE_PLACED);
}

void PrintTradeFailure(string side, bool requestOK)
{
   Print(side,
         " FAILED | requestOK=", requestOK,
         " retcode=", trade.ResultRetcode(),
         " description=", trade.ResultRetcodeDescription(),
         " brokerComment=", trade.ResultComment(),
         " bid=", DoubleToString(trade.ResultBid(),_Digits),
         " ask=", DoubleToString(trade.ResultAsk(),_Digits),
         " err=", GetLastError());
}

void LogStatus(string message)
{
   if(!EnableDebugLog)
      return;

   datetime now = TimeCurrent();
   if(now == 0 || lastStatusLog == 0 || now - lastStatusLog >= 10)
   {
      Print(message);
      lastStatusLog = now;
   }
}
//+------------------------------------------------------------------+
