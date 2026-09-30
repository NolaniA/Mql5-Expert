//+------------------------------------------------------------------+
//| XAU_Structure_EMA_MACD_RSI_Modular.mq5                           |
//| Modular M5 trend-pullback EA                                     |
//| Structure -> EMA -> Pullback/Breakout -> MACD/RSI/Price Action   |
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"

#include <Trade/Trade.mqh>
CTrade trade;

//====================================================================
// 1) GENERAL
//====================================================================
input group "01. General"
input ENUM_TIMEFRAMES InpTimeframe             = PERIOD_M5;
input ulong           InpMagic                 = 26092301;
input double          InpFixedLot              = 0.01;
input int             InpMaxPositions          = 1;
input int             InpMinBarsBetweenEntries = 2;
input int             InpSlippagePoints        = 30;
input int             InpMaxSpreadPoints       = 0;       // 0 = disabled
input bool            InpAllowBuy              = true;
input bool            InpAllowSell             = true;
input bool            InpDebugLog              = true;

//====================================================================
// 2) MARKET STRUCTURE
//====================================================================
input group "02. Market Structure"
input bool InpUseStructureFilter = true;
input int  InpStructureLookback  = 80;
input int  InpPivotSpan          = 2;

//====================================================================
// 3) EMA TREND
//====================================================================
input group "03. EMA Trend"
input bool InpUseEMAFilter       = true;
input int  InpFastEMAPeriod      = 8;
input int  InpSlowEMAPeriod      = 12;
input bool InpUseEMASlope        = true;

//====================================================================
// 4) ENTRY SETUP
//====================================================================
input group "04. Pullback / Breakout Setup"
input bool   InpUsePullbackEntry       = true;
input double InpPullbackDistanceATR    = 0.35;
input bool   InpUseBreakoutEntry       = false;
input int    InpBreakoutLookback       = 10;
input double InpMaxBreakoutDistanceATR = 1.50;

//====================================================================
// 5) MACD CONFIRMATION
//====================================================================
input group "05. MACD Confirmation"
input bool InpUseMACDConfirm     = true;
input int  InpMACDFast           = 12;
input int  InpMACDSlow           = 26;
input int  InpMACDSignal         = 9;
input bool InpMACDRequireZeroLine= false;
input bool InpUseMACDExpansion   = true;

//====================================================================
// 6) RSI CONFIRMATION
//====================================================================
input group "06. RSI Confirmation"
input bool   InpUseRSIConfirm = true;
input int    InpRSIPeriod     = 14;
input double InpRSIZoneLow    = 40.0;
input double InpRSIZoneHigh   = 60.0;
input bool   InpRequireRSITurn= true;

//====================================================================
// 7) PRICE ACTION CONFIRMATION
//====================================================================
input group "07. Price Action Confirmation"
input bool   InpUsePriceActionConfirm = true;
input bool   InpUseEngulfing          = true;
input bool   InpUseRejectionCandle    = true;
input double InpMinWickBodyRatio      = 1.50;

//====================================================================
// 8) CONFIRMATION SCORE
//====================================================================
input group "08. Confirmation Score"
input bool InpUseScoreMode            = true;
input int  InpMinConfirmationScore    = 2;
input int  InpMACDScore               = 1;
input int  InpRSIScore                = 1;
input int  InpPriceActionScore        = 2;

//====================================================================
// 9) RANGE FILTER
//====================================================================
input group "09. Range Filter"
input bool   InpUseRangeFilter        = true;
input int    InpRangeLookback         = 12;
input double InpRangeMaxEMAGapATR     = 0.12;
input double InpRangeMaxEMASlopeATR   = 0.06;
input int    InpRangeMinCrosses       = 4;

//====================================================================
// 10) VOLATILITY FILTER
//====================================================================
input group "10. Volatility Filter"
input bool   InpUseVolatilityFilter   = true;
input int    InpATRPeriod             = 14;
input int    InpATRAvgPeriod          = 20;
input double InpMaxATRMultiplier      = 2.00;
input double InpMaxCandleATR          = 2.50;

//====================================================================
// 11) RISK / EXIT
//====================================================================
input group "11. Risk and Exit"
input bool   InpUseRiskPercent        = false;
input double InpRiskPercent           = 1.00;
input bool   InpUseStopLoss           = true;
input double InpStopLossATR           = 1.50;
input bool   InpUseTakeProfit         = true;
input double InpTakeProfitATR         = 2.50;

//====================================================================
// 12) POSITION MANAGEMENT
//====================================================================
input group "12. Position Management"
input bool   InpUseBreakEven          = true;
input double InpBreakEvenTriggerATR   = 1.00;
input int    InpBreakEvenOffsetPoints = 20;
input bool   InpUseTrailingStop       = true;
input double InpTrailingStartATR      = 1.50;
input double InpTrailingDistanceATR   = 1.00;
input bool   InpCloseOnOppositeSignal = false;

//====================================================================
// Globals
//====================================================================
int hFastEMA = INVALID_HANDLE;
int hSlowEMA = INVALID_HANDLE;
int hMACD    = INVALID_HANDLE;
int hRSI     = INVALID_HANDLE;
int hATR     = INVALID_HANDLE;

datetime g_lastBarTime   = 0;
datetime g_lastEntryTime = 0;

enum TrendState
{
   TREND_NEUTRAL = 0,
   TREND_BULL    = 1,
   TREND_BEAR    = -1
};

//====================================================================
// Utility
//====================================================================
void Log(string msg)
{
   if(InpDebugLog)
      Print("[ModularEA] ", msg);
}

bool IsNewBar()
{
   datetime t = iTime(_Symbol, InpTimeframe, 0);
   if(t <= 0)
      return false;

   if(g_lastBarTime == 0)
   {
      g_lastBarTime = t;
      return false;
   }

   if(t != g_lastBarTime)
   {
      g_lastBarTime = t;
      return true;
   }

   return false;
}

bool CopyRatesSeries(const int count, MqlRates &rates[])
{
   ArraySetAsSeries(rates, true);
   return (CopyRates(_Symbol, InpTimeframe, 0, count, rates) >= count);
}

bool CopyBufferSeries(const int handle,
                      const int buffer_num,
                      const int count,
                      double &values[])
{
   ArraySetAsSeries(values, true);
   return (CopyBuffer(handle, buffer_num, 0, count, values) >= count);
}

double NormalizePrice(double price)
{
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   return NormalizeDouble(price, digits);
}

double NormalizeVolume(double volume)
{
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(step <= 0.0)
      step = minLot;

   volume = MathMax(minLot, MathMin(maxLot, volume));
   volume = MathFloor(volume / step + 1e-8) * step;

   int volDigits = 2;
   if(step == 1.0)       volDigits = 0;
   else if(step == 0.1)  volDigits = 1;
   else if(step == 0.01) volDigits = 2;
   else if(step == 0.001)volDigits = 3;

   return NormalizeDouble(volume, volDigits);
}

int CountOurPositions()
{
   int count = 0;

   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;

      count++;
   }

   return count;
}

bool SpreadOK()
{
   if(InpMaxSpreadPoints <= 0)
      return true;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return false;

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(point <= 0.0)
      return false;

   double spreadPts = (tick.ask - tick.bid) / point;
   return (spreadPts <= InpMaxSpreadPoints);
}

bool EntryCooldownOK()
{
   if(g_lastEntryTime <= 0 || InpMinBarsBetweenEntries <= 0)
      return true;

   int shift = iBarShift(_Symbol, InpTimeframe, g_lastEntryTime, false);
   if(shift < 0)
      return true;

   return (shift >= InpMinBarsBetweenEntries);
}

//====================================================================
// Market Structure
//====================================================================
bool IsPivotHigh(MqlRates &r[], int idx, int span)
{
   double h = r[idx].high;
   for(int j = 1; j <= span; ++j)
   {
      if(h <= r[idx-j].high || h <= r[idx+j].high)
         return false;
   }
   return true;
}

bool IsPivotLow(MqlRates &r[], int idx, int span)
{
   double l = r[idx].low;
   for(int j = 1; j <= span; ++j)
   {
      if(l >= r[idx-j].low || l >= r[idx+j].low)
         return false;
   }
   return true;
}

TrendState GetStructureTrend()
{
   int need = MathMax(InpStructureLookback + InpPivotSpan + 10, 30);

   MqlRates r[];
   if(!CopyRatesSeries(need, r))
      return TREND_NEUTRAL;

   double high1 = 0.0, high2 = 0.0;
   double low1  = 0.0, low2  = 0.0;
   int highs = 0, lows = 0;

   int start = InpPivotSpan + 1;
   int end   = MathMin(InpStructureLookback, ArraySize(r) - InpPivotSpan - 1);

   // Series array: lower index = more recent bar.
   for(int i = start; i <= end; ++i)
   {
      if(highs < 2 && IsPivotHigh(r, i, InpPivotSpan))
      {
         if(highs == 0) high1 = r[i].high; // latest swing high
         else           high2 = r[i].high; // previous swing high
         highs++;
      }

      if(lows < 2 && IsPivotLow(r, i, InpPivotSpan))
      {
         if(lows == 0) low1 = r[i].low;    // latest swing low
         else          low2 = r[i].low;    // previous swing low
         lows++;
      }

      if(highs >= 2 && lows >= 2)
         break;
   }

   if(highs < 2 || lows < 2)
      return TREND_NEUTRAL;

   bool bull = (high1 > high2 && low1 > low2); // HH + HL
   bool bear = (high1 < high2 && low1 < low2); // LH + LL

   if(bull) return TREND_BULL;
   if(bear) return TREND_BEAR;
   return TREND_NEUTRAL;
}

//====================================================================
// EMA Trend
//====================================================================
TrendState GetEMATrend()
{
   double fast[], slow[];
   if(!CopyBufferSeries(hFastEMA, 0, 4, fast)) return TREND_NEUTRAL;
   if(!CopyBufferSeries(hSlowEMA, 0, 4, slow)) return TREND_NEUTRAL;

   bool bull = (fast[1] > slow[1]);
   bool bear = (fast[1] < slow[1]);

   if(InpUseEMASlope)
   {
      bull = bull && fast[1] > fast[2] && slow[1] >= slow[2];
      bear = bear && fast[1] < fast[2] && slow[1] <= slow[2];
   }

   if(bull) return TREND_BULL;
   if(bear) return TREND_BEAR;
   return TREND_NEUTRAL;
}

//====================================================================
// ATR / volatility
//====================================================================
double GetClosedATR()
{
   double atr[];
   if(!CopyBufferSeries(hATR, 0, 3, atr))
      return 0.0;

   return atr[1];
}

bool IsVolatilityBlocked()
{
   if(!InpUseVolatilityFilter)
      return false;

   int need = MathMax(InpATRAvgPeriod + 3, 6);

   double atr[];
   MqlRates r[];

   if(!CopyBufferSeries(hATR, 0, need, atr))
      return true;

   if(!CopyRatesSeries(4, r))
      return true;

   double currentATR = atr[1];
   if(currentATR <= 0.0)
      return true;

   double avgATR = 0.0;
   int n = 0;

   for(int i = 2; i < MathMin(ArraySize(atr), InpATRAvgPeriod + 2); ++i)
   {
      if(atr[i] > 0.0)
      {
         avgATR += atr[i];
         n++;
      }
   }

   if(n > 0)
      avgATR /= n;
   else
      avgATR = currentATR;

   double candleRange = r[1].high - r[1].low;

   bool atrSpike    = (avgATR > 0.0 && currentATR > avgATR * InpMaxATRMultiplier);
   bool candleSpike = (candleRange > currentATR * InpMaxCandleATR);

   return (atrSpike || candleSpike);
}

//====================================================================
// Range Filter
//====================================================================
bool IsRangeMarket()
{
   if(!InpUseRangeFilter)
      return false;

   int need = MathMax(InpRangeLookback + 3, 8);

   double fast[], slow[], atr[];
   MqlRates r[];

   if(!CopyBufferSeries(hFastEMA, 0, need, fast)) return true;
   if(!CopyBufferSeries(hSlowEMA, 0, need, slow)) return true;
   if(!CopyBufferSeries(hATR, 0, need, atr))      return true;
   if(!CopyRatesSeries(need, r))                  return true;

   double a = atr[1];
   if(a <= 0.0)
      return true;

   double gap   = MathAbs(fast[1] - slow[1]) / a;
   double slope = MathAbs(slow[1] - slow[MathMin(InpRangeLookback, ArraySize(slow)-1)]) / a;

   int crosses = 0;
   int maxI = MathMin(InpRangeLookback, ArraySize(r)-2);

   for(int i = 1; i <= maxI; ++i)
   {
      double d1 = r[i].close   - slow[i];
      double d2 = r[i+1].close - slow[i+1];

      if((d1 > 0.0 && d2 < 0.0) || (d1 < 0.0 && d2 > 0.0))
         crosses++;
   }

   bool smallGap   = (gap   <= InpRangeMaxEMAGapATR);
   bool flatEMA    = (slope <= InpRangeMaxEMASlopeATR);
   bool manyCross  = (crosses >= InpRangeMinCrosses);

   return (smallGap && flatEMA && manyCross);
}

//====================================================================
// Setup: Pullback / Breakout
//====================================================================
bool PullbackSetup(bool isBuy)
{
   if(!InpUsePullbackEntry)
      return false;

   double fast[], slow[], atr[];
   MqlRates r[];

   if(!CopyBufferSeries(hFastEMA, 0, 3, fast)) return false;
   if(!CopyBufferSeries(hSlowEMA, 0, 3, slow)) return false;
   if(!CopyBufferSeries(hATR, 0, 3, atr))      return false;
   if(!CopyRatesSeries(3, r))                  return false;

   double a = atr[1];
   if(a <= 0.0)
      return false;

   double zoneHigh = MathMax(fast[1], slow[1]);
   double zoneLow  = MathMin(fast[1], slow[1]);
   double tol      = a * InpPullbackDistanceATR;

   bool touchedZone = (r[1].low <= zoneHigh + tol && r[1].high >= zoneLow - tol);
   bool closeNear   = (MathAbs(r[1].close - fast[1]) <= tol ||
                       MathAbs(r[1].close - slow[1]) <= tol);

   if(isBuy)
      return (touchedZone || closeNear) && r[1].close >= zoneLow - tol;

   return (touchedZone || closeNear) && r[1].close <= zoneHigh + tol;
}

bool BreakoutSetup(bool isBuy)
{
   if(!InpUseBreakoutEntry)
      return false;

   int need = InpBreakoutLookback + 4;

   MqlRates r[];
   double fast[], atr[];

   if(!CopyRatesSeries(need, r))                  return false;
   if(!CopyBufferSeries(hFastEMA, 0, 3, fast))   return false;
   if(!CopyBufferSeries(hATR, 0, 3, atr))        return false;

   double a = atr[1];
   if(a <= 0.0)
      return false;

   double highest = -DBL_MAX;
   double lowest  = DBL_MAX;

   for(int i = 2; i <= InpBreakoutLookback + 1; ++i)
   {
      highest = MathMax(highest, r[i].high);
      lowest  = MathMin(lowest,  r[i].low);
   }

   double distance = MathAbs(r[1].close - fast[1]) / a;
   if(distance > InpMaxBreakoutDistanceATR)
      return false;

   if(isBuy)
      return (r[1].close > highest);

   return (r[1].close < lowest);
}

bool EntrySetupOK(bool isBuy)
{
   if(!InpUsePullbackEntry && !InpUseBreakoutEntry)
      return true;

   return PullbackSetup(isBuy) || BreakoutSetup(isBuy);
}

//====================================================================
// MACD
//====================================================================
bool MACDConfirm(bool isBuy)
{
   if(!InpUseMACDConfirm)
      return true;

   double mainLine[], signalLine[];
   if(!CopyBufferSeries(hMACD, 0, 4, mainLine))   return false;
   if(!CopyBufferSeries(hMACD, 1, 4, signalLine)) return false;

   double hist1 = mainLine[1] - signalLine[1];
   double hist2 = mainLine[2] - signalLine[2];

   bool ok;

   if(isBuy)
   {
      ok = (mainLine[1] > signalLine[1]);

      if(InpMACDRequireZeroLine)
         ok = ok && (mainLine[1] > 0.0);

      if(InpUseMACDExpansion)
         ok = ok && (hist1 > hist2);
   }
   else
   {
      ok = (mainLine[1] < signalLine[1]);

      if(InpMACDRequireZeroLine)
         ok = ok && (mainLine[1] < 0.0);

      if(InpUseMACDExpansion)
         ok = ok && (hist1 < hist2);
   }

   return ok;
}

//====================================================================
// RSI
//====================================================================
bool RSIConfirm(bool isBuy)
{
   if(!InpUseRSIConfirm)
      return true;

   double rsi[];
   if(!CopyBufferSeries(hRSI, 0, 4, rsi))
      return false;

   bool inZone = (rsi[1] >= InpRSIZoneLow && rsi[1] <= InpRSIZoneHigh);
   if(!inZone)
      return false;

   if(!InpRequireRSITurn)
      return true;

   if(isBuy)
      return (rsi[1] > rsi[2]);

   return (rsi[1] < rsi[2]);
}

//====================================================================
// Price Action
//====================================================================
bool BullishEngulfing(MqlRates &r[])
{
   bool prevBear = (r[2].close < r[2].open);
   bool currBull = (r[1].close > r[1].open);

   return prevBear && currBull &&
          r[1].open <= r[2].close &&
          r[1].close >= r[2].open;
}

bool BearishEngulfing(MqlRates &r[])
{
   bool prevBull = (r[2].close > r[2].open);
   bool currBear = (r[1].close < r[1].open);

   return prevBull && currBear &&
          r[1].open >= r[2].close &&
          r[1].close <= r[2].open;
}

bool BullishRejection(MqlRates &r[])
{
   double body      = MathAbs(r[1].close - r[1].open);
   double lowerWick = MathMin(r[1].open, r[1].close) - r[1].low;
   double upperWick = r[1].high - MathMax(r[1].open, r[1].close);

   if(body <= 0.0)
      body = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   return (r[1].close > r[1].open &&
           lowerWick >= body * InpMinWickBodyRatio &&
           lowerWick > upperWick);
}

bool BearishRejection(MqlRates &r[])
{
   double body      = MathAbs(r[1].close - r[1].open);
   double upperWick = r[1].high - MathMax(r[1].open, r[1].close);
   double lowerWick = MathMin(r[1].open, r[1].close) - r[1].low;

   if(body <= 0.0)
      body = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   return (r[1].close < r[1].open &&
           upperWick >= body * InpMinWickBodyRatio &&
           upperWick > lowerWick);
}

bool PriceActionConfirm(bool isBuy)
{
   if(!InpUsePriceActionConfirm)
      return true;

   MqlRates r[];
   if(!CopyRatesSeries(4, r))
      return false;

   bool engulf = false;
   bool reject = false;

   if(InpUseEngulfing)
      engulf = isBuy ? BullishEngulfing(r) : BearishEngulfing(r);

   if(InpUseRejectionCandle)
      reject = isBuy ? BullishRejection(r) : BearishRejection(r);

   if(!InpUseEngulfing && !InpUseRejectionCandle)
      return true;

   return (engulf || reject);
}

//====================================================================
// Confirm score / strict mode
//====================================================================
bool ConfirmationOK(bool isBuy, int &score, int &maxScore)
{
   score = 0;
   maxScore = 0;

   bool macdOK  = true;
   bool rsiOK   = true;
   bool priceOK = true;

   if(InpUseMACDConfirm)
   {
      maxScore += MathMax(0, InpMACDScore);
      macdOK = MACDConfirm(isBuy);
      if(macdOK) score += MathMax(0, InpMACDScore);
   }

   if(InpUseRSIConfirm)
   {
      maxScore += MathMax(0, InpRSIScore);
      rsiOK = RSIConfirm(isBuy);
      if(rsiOK) score += MathMax(0, InpRSIScore);
   }

   if(InpUsePriceActionConfirm)
   {
      maxScore += MathMax(0, InpPriceActionScore);
      priceOK = PriceActionConfirm(isBuy);
      if(priceOK) score += MathMax(0, InpPriceActionScore);
   }

   if(maxScore <= 0)
      return true;

   if(InpUseScoreMode)
   {
      int required = MathMin(MathMax(0, InpMinConfirmationScore), maxScore);
      return (score >= required);
   }

   return (macdOK && rsiOK && priceOK);
}

//====================================================================
// Full signal evaluation
//====================================================================
bool DirectionFiltersOK(bool isBuy, TrendState &structure, TrendState &emaTrend)
{
   structure = TREND_NEUTRAL;
   emaTrend  = TREND_NEUTRAL;

   if(InpUseStructureFilter)
   {
      structure = GetStructureTrend();

      if(isBuy  && structure != TREND_BULL) return false;
      if(!isBuy && structure != TREND_BEAR) return false;
   }

   if(InpUseEMAFilter)
   {
      emaTrend = GetEMATrend();

      if(isBuy  && emaTrend != TREND_BULL) return false;
      if(!isBuy && emaTrend != TREND_BEAR) return false;
   }

   return true;
}

bool BuildSignal(bool isBuy, int &score, int &maxScore)
{
   TrendState structure, emaTrend;

   if(!DirectionFiltersOK(isBuy, structure, emaTrend))
      return false;

   if(!EntrySetupOK(isBuy))
      return false;

   if(!ConfirmationOK(isBuy, score, maxScore))
      return false;

   return true;
}

//====================================================================
// Lot / Stops
//====================================================================
double CalculateLot(double stopDistancePrice)
{
   if(!InpUseRiskPercent || !InpUseStopLoss || stopDistancePrice <= 0.0)
      return NormalizeVolume(InpFixedLot);

   double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskMoney = balance * InpRiskPercent / 100.0;

   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);

   if(tickSize <= 0.0 || tickValue <= 0.0)
      return NormalizeVolume(InpFixedLot);

   double lossPerLot = (stopDistancePrice / tickSize) * tickValue;
   if(lossPerLot <= 0.0)
      return NormalizeVolume(InpFixedLot);

   return NormalizeVolume(riskMoney / lossPerLot);
}

void BuildStops(bool isBuy, double entry, double atr, double &sl, double &tp)
{
   sl = 0.0;
   tp = 0.0;

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int stopsLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDist = stopsLevel * point;

   if(InpUseStopLoss)
   {
      double dist = MathMax(atr * InpStopLossATR, minDist);
      sl = isBuy ? entry - dist : entry + dist;
      sl = NormalizePrice(sl);
   }

   if(InpUseTakeProfit)
   {
      double dist = MathMax(atr * InpTakeProfitATR, minDist);
      tp = isBuy ? entry + dist : entry - dist;
      tp = NormalizePrice(tp);
   }
}

//====================================================================
// Trading
//====================================================================
bool OpenTrade(bool isBuy, int score, int maxScore)
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return false;

   double atr = GetClosedATR();
   if(atr <= 0.0)
      return false;

   double entry = isBuy ? tick.ask : tick.bid;
   double sl, tp;
   BuildStops(isBuy, entry, atr, sl, tp);

   double stopDistance = (sl > 0.0) ? MathAbs(entry - sl) : 0.0;
   double lot = CalculateLot(stopDistance);

   if(lot <= 0.0)
      return false;

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePoints);

   string comment = StringFormat("ModularEA %s score=%d/%d",
                                 isBuy ? "BUY" : "SELL",
                                 score,
                                 maxScore);

   bool ok = false;

   if(isBuy)
      ok = trade.Buy(lot, _Symbol, 0.0, sl, tp, comment);
   else
      ok = trade.Sell(lot, _Symbol, 0.0, sl, tp, comment);

   if(ok)
   {
      g_lastEntryTime = iTime(_Symbol, InpTimeframe, 0);

      Log(StringFormat("%s opened lot=%.2f SL=%.*f TP=%.*f score=%d/%d",
                       isBuy ? "BUY" : "SELL",
                       lot,
                       (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS), sl,
                       (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS), tp,
                       score,
                       maxScore));
   }
   else
   {
      Log(StringFormat("Order failed. retcode=%u, %s",
                       trade.ResultRetcode(),
                       trade.ResultRetcodeDescription()));
   }

   return ok;
}

//====================================================================
// Position Management
//====================================================================
void ManagePositions()
{
   double atr = GetClosedATR();
   if(atr <= 0.0)
      return;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return;

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;

      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double oldSL     = PositionGetDouble(POSITION_SL);
      double oldTP     = PositionGetDouble(POSITION_TP);

      bool isBuy = (type == POSITION_TYPE_BUY);
      double current = isBuy ? tick.bid : tick.ask;
      double profitDistance = isBuy ? (current - openPrice) : (openPrice - current);

      double newSL = oldSL;
      bool needModify = false;

      // Break-even
      if(InpUseBreakEven && profitDistance >= atr * InpBreakEvenTriggerATR)
      {
         double be = isBuy
                   ? openPrice + InpBreakEvenOffsetPoints * point
                   : openPrice - InpBreakEvenOffsetPoints * point;

         be = NormalizePrice(be);

         if(isBuy)
         {
            if(oldSL == 0.0 || be > newSL)
            {
               newSL = be;
               needModify = true;
            }
         }
         else
         {
            if(oldSL == 0.0 || be < newSL)
            {
               newSL = be;
               needModify = true;
            }
         }
      }

      // ATR trailing
      if(InpUseTrailingStop && profitDistance >= atr * InpTrailingStartATR)
      {
         double trail = isBuy
                      ? current - atr * InpTrailingDistanceATR
                      : current + atr * InpTrailingDistanceATR;

         trail = NormalizePrice(trail);

         if(isBuy)
         {
            if((newSL == 0.0 || trail > newSL) && trail < current)
            {
               newSL = trail;
               needModify = true;
            }
         }
         else
         {
            if((newSL == 0.0 || trail < newSL) && trail > current)
            {
               newSL = trail;
               needModify = true;
            }
         }
      }

      if(needModify && newSL > 0.0 && MathAbs(newSL - oldSL) >= point)
      {
         if(!trade.PositionModify(ticket, newSL, oldTP))
            Log(StringFormat("PositionModify failed ticket=%I64u ret=%u %s",
                             ticket,
                             trade.ResultRetcode(),
                             trade.ResultRetcodeDescription()));
      }
   }
}

void ClosePositionsByType(ENUM_POSITION_TYPE typeToClose)
{
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;

      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if(type != typeToClose)
         continue;

      if(!trade.PositionClose(ticket))
      {
         Log(StringFormat("PositionClose failed ticket=%I64u ret=%u %s",
                          ticket,
                          trade.ResultRetcode(),
                          trade.ResultRetcodeDescription()));
      }
   }
}

//====================================================================
// OnInit / OnDeinit / OnTick
//====================================================================
int OnInit()
{
   if(InpFastEMAPeriod <= 0 ||
      InpSlowEMAPeriod <= 0 ||
      InpRSIPeriod <= 0 ||
      InpATRPeriod <= 0 ||
      InpPivotSpan < 1)
   {
      Print("Invalid input parameters.");
      return INIT_PARAMETERS_INCORRECT;
   }

   hFastEMA = iMA(_Symbol, InpTimeframe, InpFastEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   hSlowEMA = iMA(_Symbol, InpTimeframe, InpSlowEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   hMACD    = iMACD(_Symbol, InpTimeframe, InpMACDFast, InpMACDSlow, InpMACDSignal, PRICE_CLOSE);
   hRSI     = iRSI(_Symbol, InpTimeframe, InpRSIPeriod, PRICE_CLOSE);
   hATR     = iATR(_Symbol, InpTimeframe, InpATRPeriod);

   if(hFastEMA == INVALID_HANDLE ||
      hSlowEMA == INVALID_HANDLE ||
      hMACD    == INVALID_HANDLE ||
      hRSI     == INVALID_HANDLE ||
      hATR     == INVALID_HANDLE)
   {
      Print("Failed to create indicator handles.");
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePoints);

   g_lastBarTime = iTime(_Symbol, InpTimeframe, 0);

   Log("Initialized.");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(hFastEMA != INVALID_HANDLE) IndicatorRelease(hFastEMA);
   if(hSlowEMA != INVALID_HANDLE) IndicatorRelease(hSlowEMA);
   if(hMACD    != INVALID_HANDLE) IndicatorRelease(hMACD);
   if(hRSI     != INVALID_HANDLE) IndicatorRelease(hRSI);
   if(hATR     != INVALID_HANDLE) IndicatorRelease(hATR);
}

void OnTick()
{
   // Position management runs every tick.
   ManagePositions();

   // New entries are evaluated only once per new signal bar.
   if(!IsNewBar())
      return;

   if(!SpreadOK())
   {
      Log("Blocked: spread.");
      return;
   }

   if(IsVolatilityBlocked())
   {
      Log("Blocked: volatility spike.");
      return;
   }

   if(IsRangeMarket())
   {
      Log("Blocked: range market.");
      return;
   }

   int buyScore = 0, buyMax = 0;
   int sellScore = 0, sellMax = 0;

   bool buySignal  = InpAllowBuy  && BuildSignal(true,  buyScore,  buyMax);
   bool sellSignal = InpAllowSell && BuildSignal(false, sellScore, sellMax);

   // Optional position exit when a complete opposite signal appears.
   if(InpCloseOnOppositeSignal)
   {
      if(buySignal)
         ClosePositionsByType(POSITION_TYPE_SELL);

      if(sellSignal)
         ClosePositionsByType(POSITION_TYPE_BUY);
   }

   if(CountOurPositions() >= InpMaxPositions)
      return;

   if(!EntryCooldownOK())
   {
      Log("Blocked: entry cooldown.");
      return;
   }

   // Avoid ambiguous simultaneous signals.
   if(buySignal && sellSignal)
   {
      Log("Blocked: simultaneous BUY and SELL signal.");
      return;
   }

   if(buySignal)
      OpenTrade(true, buyScore, buyMax);
   else if(sellSignal)
      OpenTrade(false, sellScore, sellMax);
}
//+------------------------------------------------------------------+
