//+------------------------------------------------------------------+
//|                                              SMC_Dynamic_MTF.mq5  |
//| Dynamic Multi-Timeframe SMC EA                                   |
//| Flow: Anchor -> Pullback -> Liquidity Sweep -> CHoCH -> FVG       |
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"
#property description "Dynamic Multi-Timeframe SMC EA"

#include <Trade/Trade.mqh>

CTrade trade;

//--------------------------- ENUMS -----------------------------------
enum ENUM_ENTRY_MODE
{
   ENTRY_MARKET_CONFIRM = 0,
   ENTRY_FVG50_LIMIT    = 1
};

enum ENUM_TARGET_MODE
{
   TARGET_LIQUIDITY_ONLY = 0,
   TARGET_FIXED_RR       = 1,
   TARGET_LIQUIDITY_OR_RR= 2
};

enum ENUM_SMC_STATE
{
   STATE_SCAN_DIRECTION = 0,
   STATE_WAIT_PULLBACK,
   STATE_WAIT_SWEEP,
   STATE_WAIT_CHOCH,
   STATE_WAIT_ENTRY,
   STATE_IN_TRADE
};

//--------------------------- INPUTS ----------------------------------
input group "01. General"
input ulong           MagicNumber              = 26100401;
input bool            AllowBuy                 = true;
input bool            AllowSell                = true;
input int             MaxSpreadPoints          = 80;
input int             SlippagePoints           = 30;
input int             SetupTimeoutMinutes      = 360;
input bool            OneExposureOnly          = true;

input group "02. Structure / Swing"
input int             SwingLength              = 2;
input int             StructureLookbackBars    = 160;
input double          StructureBreakATR        = 0.05;

input group "03. Dynamic Direction"
input double          MinDirectionScore        = 4.0;
input int             DirectionDisplaceLookback= 8;
input double          DirectionMinTargetATR    = 1.0;

input group "04. Pullback"
input bool            UsePremiumDiscount       = true;
input double          PullbackEQPercent         = 50.0;

input group "05. Liquidity"
input bool            UseEqualLiquidity        = true;
input bool            UseSwingLiquidityFallback= true;
input int             LiquiditySearchSwings    = 6;
input double          EqualToleranceATR        = 0.08;
input double          MinSweepATR              = 0.03;

input group "06. Confirmation"
input double          DisplacementATR          = 1.20;
input double          MinBodyRatio             = 0.60;
input int             ATRPeriod                = 14;
input bool            RequireFVG               = true;
input int             FVGSearchBars            = 8;

input group "07. Entry"
input ENUM_ENTRY_MODE EntryMode                = ENTRY_FVG50_LIMIT;
input int             PendingExpiryBars        = 8;
input double          SLBufferATR              = 0.10;

input group "08. Risk / Target"
input double          RiskPercent              = 1.0;
input double          MinRR                    = 1.50;
input ENUM_TARGET_MODE TargetMode              = TARGET_LIQUIDITY_ONLY;
input double          FixedRR                  = 2.0;

input group "09. Panel"
input bool            ShowPanel                = true;

//--------------------------- GLOBALS ---------------------------------
ENUM_SMC_STATE  g_state          = STATE_SCAN_DIRECTION;
int             g_direction      = 0; // 1 buy, -1 sell
ENUM_TIMEFRAMES g_anchorTF       = PERIOD_CURRENT;
ENUM_TIMEFRAMES g_setupTF        = PERIOD_CURRENT;
ENUM_TIMEFRAMES g_liquidityTF    = PERIOD_CURRENT;
ENUM_TIMEFRAMES g_confirmTF      = PERIOD_CURRENT;
ENUM_TIMEFRAMES g_entryTF        = PERIOD_CURRENT;

double          g_anchorHigh     = 0.0;
double          g_anchorLow      = 0.0;
double          g_anchorEQ       = 0.0;

double          g_sweepLevel     = 0.0;
double          g_sweepExtreme   = 0.0;

datetime        g_setupStart     = 0;
datetime        g_confirmationTime = 0;
datetime        g_lastScanBar    = 0;
datetime        g_lastStateBar   = 0;
datetime        g_pendingPlaced  = 0;

double          g_lastH4BuyScore = 0.0;
double          g_lastH4SellScore= 0.0;
double          g_lastH1BuyScore = 0.0;
double          g_lastH1SellScore= 0.0;
double          g_lastM30BuyScore= 0.0;
double          g_lastM30SellScore=0.0;

string          g_reason         = "Init";

//--------------------------- HELPERS ---------------------------------
string TFToString(ENUM_TIMEFRAMES tf)
{
   switch(tf)
   {
      case PERIOD_M1:  return "M1";
      case PERIOD_M5:  return "M5";
      case PERIOD_M15: return "M15";
      case PERIOD_M30: return "M30";
      case PERIOD_H1:  return "H1";
      case PERIOD_H4:  return "H4";
      default:         return EnumToString(tf);
   }
}

string StateToString(ENUM_SMC_STATE st)
{
   switch(st)
   {
      case STATE_SCAN_DIRECTION: return "SCAN_DIRECTION";
      case STATE_WAIT_PULLBACK:  return "WAIT_PULLBACK";
      case STATE_WAIT_SWEEP:     return "WAIT_SWEEP";
      case STATE_WAIT_CHOCH:     return "WAIT_CHOCH";
      case STATE_WAIT_ENTRY:     return "WAIT_ENTRY";
      case STATE_IN_TRADE:       return "IN_TRADE";
   }
   return "UNKNOWN";
}

void SetState(ENUM_SMC_STATE st, string reason)
{
   g_state = st;
   g_reason = reason;
   g_lastStateBar = 0;
}

double NormalizePrice(double price)
{
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   return NormalizeDouble(price, digits);
}

double CurrentSpreadPoints()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(_Point <= 0.0) return 0.0;
   return (ask - bid) / _Point;
}

bool SpreadOK()
{
   if(MaxSpreadPoints <= 0) return true;
   return (CurrentSpreadPoints() <= MaxSpreadPoints);
}

bool CopyTF(ENUM_TIMEFRAMES tf, int count, MqlRates &rates[])
{
   ArraySetAsSeries(rates, true);
   int copied = CopyRates(_Symbol, tf, 0, count, rates);
   return (copied >= count);
}

double GetATR(ENUM_TIMEFRAMES tf, int period)
{
   int need = period + 3;
   MqlRates r[];
   if(!CopyTF(tf, need, r))
      return 0.0;

   double sum = 0.0;
   int used = 0;

   for(int i=1; i<=period; i++)
   {
      double prevClose = r[i+1].close;
      double tr1 = r[i].high - r[i].low;
      double tr2 = MathAbs(r[i].high - prevClose);
      double tr3 = MathAbs(r[i].low  - prevClose);
      double tr = MathMax(tr1, MathMax(tr2, tr3));
      sum += tr;
      used++;
   }

   if(used == 0) return 0.0;
   return sum / used;
}

bool IsSwingHigh(MqlRates &r[], int i, int len)
{
   int total = ArraySize(r);
   if(i-len < 1 || i+len >= total)
      return false;

   double p = r[i].high;
   for(int j=1; j<=len; j++)
   {
      if(p <= r[i-j].high) return false;
      if(p <= r[i+j].high) return false;
   }
   return true;
}

bool IsSwingLow(MqlRates &r[], int i, int len)
{
   int total = ArraySize(r);
   if(i-len < 1 || i+len >= total)
      return false;

   double p = r[i].low;
   for(int j=1; j<=len; j++)
   {
      if(p >= r[i-j].low) return false;
      if(p >= r[i+j].low) return false;
   }
   return true;
}

bool GetRecentSwings(ENUM_TIMEFRAMES tf,
                     double &sh1, double &sh2,
                     double &sl1, double &sl2)
{
   sh1 = sh2 = sl1 = sl2 = 0.0;

   int need = MathMax(StructureLookbackBars, 50);
   MqlRates r[];
   if(!CopyTF(tf, need, r))
      return false;

   int hc = 0, lc = 0;

   for(int i=SwingLength+1; i<need-SwingLength; i++)
   {
      if(hc < 2 && IsSwingHigh(r, i, SwingLength))
      {
         if(hc == 0) sh1 = r[i].high;
         else        sh2 = r[i].high;
         hc++;
      }

      if(lc < 2 && IsSwingLow(r, i, SwingLength))
      {
         if(lc == 0) sl1 = r[i].low;
         else        sl2 = r[i].low;
         lc++;
      }

      if(hc >= 2 && lc >= 2)
         break;
   }

   return (hc >= 2 && lc >= 2);
}

bool HasRecentDisplacement(ENUM_TIMEFRAMES tf, int dir, int lookback)
{
   int need = MathMax(lookback + 5, ATRPeriod + 5);
   MqlRates r[];
   if(!CopyTF(tf, need, r))
      return false;

   double atr = GetATR(tf, ATRPeriod);
   if(atr <= 0.0)
      return false;

   int maxI = MathMin(lookback, ArraySize(r)-2);

   for(int i=1; i<=maxI; i++)
   {
      double body  = MathAbs(r[i].close - r[i].open);
      double range = r[i].high - r[i].low;
      if(range <= 0.0) continue;

      double ratio = body / range;
      bool directionOK = (dir == 1 ? r[i].close > r[i].open
                                   : r[i].close < r[i].open);

      if(directionOK && body >= atr * DisplacementATR && ratio >= MinBodyRatio)
         return true;
   }

   return false;
}

bool LastClosedDisplacement(ENUM_TIMEFRAMES tf, int dir)
{
   MqlRates r[];
   if(!CopyTF(tf, ATRPeriod + 5, r))
      return false;

   double atr = GetATR(tf, ATRPeriod);
   if(atr <= 0.0)
      return false;

   double body  = MathAbs(r[1].close - r[1].open);
   double range = r[1].high - r[1].low;
   if(range <= 0.0)
      return false;

   double ratio = body / range;
   bool directionOK = (dir == 1 ? r[1].close > r[1].open
                                : r[1].close < r[1].open);

   return (directionOK &&
           body >= atr * DisplacementATR &&
           ratio >= MinBodyRatio);
}

double DirectionScore(ENUM_TIMEFRAMES tf, int dir,
                      double &rangeHigh, double &rangeLow)
{
   double sh1, sh2, sl1, sl2;
   if(!GetRecentSwings(tf, sh1, sh2, sl1, sl2))
      return 0.0;

   rangeHigh = sh1;
   rangeLow  = sl1;

   double atr = GetATR(tf, ATRPeriod);
   if(atr <= 0.0)
      return 0.0;

   double score = 0.0;
   double breakMin = atr * StructureBreakATR;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double price = (dir == 1 ? ask : bid);

   if(dir == 1)
   {
      if(sh1 > sh2) score += 1.0;                       // HH
      if(sl1 > sl2) score += 1.0;                       // HL
      if((sh1 - sh2) >= breakMin) score += 1.0;        // BOS distance
      if(HasRecentDisplacement(tf, 1, DirectionDisplaceLookback))
         score += 1.0;
      if((sh1 - price) >= atr * DirectionMinTargetATR)
         score += 1.0;                                  // room to BSL
   }
   else
   {
      if(sh1 < sh2) score += 1.0;                       // LH
      if(sl1 < sl2) score += 1.0;                       // LL
      if((sl2 - sl1) >= breakMin) score += 1.0;        // BOS distance
      if(HasRecentDisplacement(tf, -1, DirectionDisplaceLookback))
         score += 1.0;
      if((price - sl1) >= atr * DirectionMinTargetATR)
         score += 1.0;                                  // room to SSL
   }

   return score;
}

bool SelectAnchor()
{
   ENUM_TIMEFRAMES candidates[3] = {PERIOD_H4, PERIOD_H1, PERIOD_M30};

   g_lastH4BuyScore = g_lastH4SellScore = 0.0;
   g_lastH1BuyScore = g_lastH1SellScore = 0.0;
   g_lastM30BuyScore = g_lastM30SellScore = 0.0;

   for(int i=0; i<3; i++)
   {
      ENUM_TIMEFRAMES tf = candidates[i];
      double bh=0, bl=0, sh=0, sl=0;

      double buyScore  = DirectionScore(tf,  1, bh, bl);
      double sellScore = DirectionScore(tf, -1, sh, sl);

      if(tf == PERIOD_H4)
      {
         g_lastH4BuyScore = buyScore;
         g_lastH4SellScore = sellScore;
      }
      else if(tf == PERIOD_H1)
      {
         g_lastH1BuyScore = buyScore;
         g_lastH1SellScore = sellScore;
      }
      else
      {
         g_lastM30BuyScore = buyScore;
         g_lastM30SellScore = sellScore;
      }

      bool buyValid  = AllowBuy  && buyScore  >= MinDirectionScore;
      bool sellValid = AllowSell && sellScore >= MinDirectionScore;

      if(!buyValid && !sellValid)
         continue;

      if(buyValid && sellValid && MathAbs(buyScore - sellScore) < 0.5)
         continue;

      g_anchorTF = tf;

      if(buyValid && (!sellValid || buyScore > sellScore))
      {
         g_direction  = 1;
         g_anchorHigh = bh;
         g_anchorLow  = bl;
      }
      else
      {
         g_direction  = -1;
         g_anchorHigh = sh;
         g_anchorLow  = sl;
      }

      if(g_anchorHigh <= g_anchorLow)
      {
         g_direction = 0;
         continue;
      }

      g_anchorEQ = g_anchorLow +
                   (g_anchorHigh - g_anchorLow) * (PullbackEQPercent / 100.0);

      return true;
   }

   return false;
}

void MapLowerTFs(ENUM_TIMEFRAMES anchor)
{
   if(anchor == PERIOD_H4)
   {
      g_setupTF     = PERIOD_H1;
      g_liquidityTF = PERIOD_M30;
      g_confirmTF   = PERIOD_M15;
      g_entryTF     = PERIOD_M5;
   }
   else if(anchor == PERIOD_H1)
   {
      g_setupTF     = PERIOD_M30;
      g_liquidityTF = PERIOD_M15;
      g_confirmTF   = PERIOD_M5;
      g_entryTF     = PERIOD_M1;
   }
   else // M30
   {
      g_setupTF     = PERIOD_M15;
      g_liquidityTF = PERIOD_M5;
      g_confirmTF   = PERIOD_M1;
      g_entryTF     = PERIOD_M1;
   }
}

bool PullbackReached()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double price = (g_direction == 1 ? ask : bid);

   if(!UsePremiumDiscount)
      return true;

   if(g_direction == 1)
      return (price <= g_anchorEQ && price > g_anchorLow);
   else
      return (price >= g_anchorEQ && price < g_anchorHigh);
}

bool SetupInvalidated()
{
   double atr = GetATR(g_anchorTF, ATRPeriod);
   if(atr <= 0.0) atr = 0.0;

   double buffer = atr * SLBufferATR;

   // Invalidate with a CLOSED Anchor-TF candle, not an intrabar wick.
   // This prevents a valid liquidity sweep from resetting the setup too early.
   MqlRates r[];
   if(CopyTF(g_anchorTF, 3, r))
   {
      if(g_direction == 1 && r[1].close < g_anchorLow - buffer)
         return true;
      if(g_direction == -1 && r[1].close > g_anchorHigh + buffer)
         return true;
   }

   if(g_setupStart > 0 && SetupTimeoutMinutes > 0)
   {
      if((TimeCurrent() - g_setupStart) > SetupTimeoutMinutes * 60)
         return true;
   }

   return false;
}

bool FindLiquidityLevel(ENUM_TIMEFRAMES tf, int dir, double &level)
{
   level = 0.0;

   int need = MathMax(StructureLookbackBars, 80);
   MqlRates r[];
   if(!CopyTF(tf, need, r))
      return false;

   double atr = GetATR(tf, ATRPeriod);
   if(atr <= 0.0)
      return false;

   double tolerance = atr * EqualToleranceATR;

   double swings[];
   ArrayResize(swings, LiquiditySearchSwings);
   int count = 0;

   for(int i=SwingLength+2; i<need-SwingLength && count<LiquiditySearchSwings; i++)
   {
      bool isSwing = (dir == 1 ? IsSwingLow(r, i, SwingLength)
                               : IsSwingHigh(r, i, SwingLength));
      if(isSwing)
      {
         swings[count] = (dir == 1 ? r[i].low : r[i].high);
         count++;
      }
   }

   if(count == 0)
      return false;

   if(UseEqualLiquidity && count >= 2)
   {
      for(int i=0; i<count-1; i++)
      {
         for(int j=i+1; j<count; j++)
         {
            if(MathAbs(swings[i] - swings[j]) <= tolerance)
            {
               level = (swings[i] + swings[j]) / 2.0;
               return true;
            }
         }
      }
   }

   if(UseSwingLiquidityFallback)
   {
      level = swings[0];
      return true;
   }

   return false;
}

bool DetectLiquiditySweep(ENUM_TIMEFRAMES tf, int dir,
                          double &liqLevel, double &extreme)
{
   liqLevel = 0.0;
   extreme  = 0.0;

   if(!FindLiquidityLevel(tf, dir, liqLevel))
      return false;

   MqlRates r[];
   if(!CopyTF(tf, ATRPeriod + 10, r))
      return false;

   double atr = GetATR(tf, ATRPeriod);
   if(atr <= 0.0)
      return false;

   double minSweep = atr * MinSweepATR;

   if(dir == 1)
   {
      bool swept = (r[1].low < liqLevel - minSweep &&
                    r[1].close > liqLevel);
      if(swept)
      {
         extreme = r[1].low;
         return true;
      }
   }
   else
   {
      bool swept = (r[1].high > liqLevel + minSweep &&
                    r[1].close < liqLevel);
      if(swept)
      {
         extreme = r[1].high;
         return true;
      }
   }

   return false;
}

bool DetectCHoCH(ENUM_TIMEFRAMES tf, int dir)
{
   int need = MathMax(StructureLookbackBars, 80);
   MqlRates r[];
   if(!CopyTF(tf, need, r))
      return false;

   double ref = 0.0;

   for(int i=SwingLength+2; i<need-SwingLength; i++)
   {
      if(dir == 1 && IsSwingHigh(r, i, SwingLength))
      {
         ref = r[i].high;
         break;
      }
      if(dir == -1 && IsSwingLow(r, i, SwingLength))
      {
         ref = r[i].low;
         break;
      }
   }

   if(ref <= 0.0)
      return false;

   if(dir == 1)
      return (r[1].close > ref && r[2].close <= ref);
   else
      return (r[1].close < ref && r[2].close >= ref);
}

bool FindRecentFVG(ENUM_TIMEFRAMES tf, int dir,
                   double &zoneLow, double &zoneHigh)
{
   zoneLow = zoneHigh = 0.0;

   int need = MathMax(FVGSearchBars + 5, 12);
   MqlRates r[];
   if(!CopyTF(tf, need, r))
      return false;

   int maxI = MathMin(FVGSearchBars, ArraySize(r)-3);

   for(int i=1; i<=maxI; i++)
   {
      int newer = i;
      int older = i + 2;

      // Do not reuse an old FVG from before the CHoCH confirmation leg.
      if(g_confirmationTime > 0 && r[newer].time < g_confirmationTime)
         continue;

      if(dir == 1)
      {
         if(r[older].high < r[newer].low)
         {
            zoneLow  = r[older].high;
            zoneHigh = r[newer].low;
            return true;
         }
      }
      else
      {
         if(r[older].low > r[newer].high)
         {
            zoneLow  = r[newer].high;
            zoneHigh = r[older].low;
            return true;
         }
      }
   }

   return false;
}

bool HasOurExposure()
{
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;

      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         (ulong)PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         return true;
   }

   for(int i=OrdersTotal()-1; i>=0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;

      if(OrderGetString(ORDER_SYMBOL) == _Symbol &&
         (ulong)OrderGetInteger(ORDER_MAGIC) == MagicNumber)
         return true;
   }

   return false;
}

void DeleteOurPendingOrders()
{
   for(int i=OrdersTotal()-1; i>=0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;

      if(OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;
      if((ulong)OrderGetInteger(ORDER_MAGIC) != MagicNumber)
         continue;

      ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(type == ORDER_TYPE_BUY_LIMIT ||
         type == ORDER_TYPE_SELL_LIMIT ||
         type == ORDER_TYPE_BUY_STOP ||
         type == ORDER_TYPE_SELL_STOP ||
         type == ORDER_TYPE_BUY_STOP_LIMIT ||
         type == ORDER_TYPE_SELL_STOP_LIMIT)
      {
         trade.OrderDelete(ticket);
      }
   }
}

double NormalizeVolume(double vol)
{
   double minVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(step <= 0.0)
      return 0.0;

   vol = MathMax(minVol, MathMin(maxVol, vol));
   vol = MathFloor(vol / step) * step;

   int digits = 2;
   if(step >= 1.0) digits = 0;
   else if(step >= 0.1) digits = 1;
   else if(step >= 0.01) digits = 2;
   else if(step >= 0.001) digits = 3;

   return NormalizeDouble(vol, digits);
}

double CalculateRiskLot(double entry, double sl)
{
   double distance = MathAbs(entry - sl);
   if(distance <= 0.0)
      return 0.0;

   double riskMoney = AccountInfoDouble(ACCOUNT_BALANCE) * RiskPercent / 100.0;
   if(riskMoney <= 0.0)
      return 0.0;

   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickVal  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tickVal <= 0.0)
      tickVal = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);

   if(tickSize <= 0.0 || tickVal <= 0.0)
      return 0.0;

   double lossPerLot = (distance / tickSize) * tickVal;
   if(lossPerLot <= 0.0)
      return 0.0;

   return NormalizeVolume(riskMoney / lossPerLot);
}

bool MarginOK(ENUM_ORDER_TYPE type, double volume, double price)
{
   double margin = 0.0;
   if(!OrderCalcMargin(type, _Symbol, volume, price, margin))
      return false;

   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   return (freeMargin > margin * 1.05);
}

bool StopsDistanceOK(double entry, double sl, double tp, bool pending)
{
   long stopsLevelPoints = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDistance = (double)stopsLevelPoints * _Point;

   if(MathAbs(entry - sl) < minDistance)
      return false;
   if(MathAbs(tp - entry) < minDistance)
      return false;

   if(pending && minDistance > 0.0)
   {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

      if(g_direction == 1 && (ask - entry) < minDistance)
         return false;
      if(g_direction == -1 && (entry - bid) < minDistance)
         return false;
   }

   return true;
}

bool BuildStopsTargets(double entry, double &sl, double &tp, double &rr)
{
   double atr = GetATR(g_entryTF, ATRPeriod);
   if(atr <= 0.0)
      return false;

   double buffer = atr * SLBufferATR;

   if(g_direction == 1)
      sl = g_sweepExtreme - buffer;
   else
      sl = g_sweepExtreme + buffer;

   sl = NormalizePrice(sl);

   double risk = MathAbs(entry - sl);
   if(risk <= 0.0)
      return false;

   double liquidityTP = (g_direction == 1 ? g_anchorHigh : g_anchorLow);
   double fixedTP = (g_direction == 1 ? entry + risk * FixedRR
                                      : entry - risk * FixedRR);

   if(TargetMode == TARGET_FIXED_RR)
   {
      tp = fixedTP;
   }
   else if(TargetMode == TARGET_LIQUIDITY_ONLY)
   {
      tp = liquidityTP;
   }
   else
   {
      double liqRR = (g_direction == 1
                      ? (liquidityTP - entry) / risk
                      : (entry - liquidityTP) / risk);

      if(liqRR >= MinRR)
         tp = liquidityTP;
      else
         tp = fixedTP;
   }

   tp = NormalizePrice(tp);

   if(g_direction == 1)
   {
      if(!(sl < entry && tp > entry))
         return false;
      rr = (tp - entry) / (entry - sl);
   }
   else
   {
      if(!(sl > entry && tp < entry))
         return false;
      rr = (entry - tp) / (sl - entry);
   }

   return (rr >= MinRR);
}

bool PlaceEntry()
{
   if(!SpreadOK())
   {
      g_reason = "Spread too high";
      return false;
   }

   if(OneExposureOnly && HasOurExposure())
   {
      SetState(STATE_IN_TRADE, "Existing exposure");
      return false;
   }

   double zoneLow=0.0, zoneHigh=0.0;
   bool hasFVG = FindRecentFVG(g_entryTF, g_direction, zoneLow, zoneHigh);

   if(RequireFVG && !hasFVG)
   {
      g_reason = "Waiting FVG";
      return false;
   }

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double entry = (g_direction == 1 ? ask : bid);
   bool usePending = false;

   if(EntryMode == ENTRY_FVG50_LIMIT && hasFVG)
   {
      double mid = (zoneLow + zoneHigh) / 2.0;

      if(g_direction == 1 && mid < ask)
      {
         entry = mid;
         usePending = true;
      }
      else if(g_direction == -1 && mid > bid)
      {
         entry = mid;
         usePending = true;
      }
   }

   entry = NormalizePrice(entry);

   double sl=0.0, tp=0.0, rr=0.0;
   if(!BuildStopsTargets(entry, sl, tp, rr))
   {
      g_reason = "Invalid SL/TP or RR < minimum";
      return false;
   }

   if(!StopsDistanceOK(entry, sl, tp, usePending))
   {
      g_reason = "Entry/SL/TP too close for broker stop level";
      return false;
   }

   double volume = CalculateRiskLot(entry, sl);
   if(volume <= 0.0)
   {
      g_reason = "Risk lot = 0";
      return false;
   }

   ENUM_ORDER_TYPE marginType = (g_direction == 1 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   if(!MarginOK(marginType, volume, entry))
   {
      g_reason = "Not enough margin";
      return false;
   }

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   bool ok = false;
   string comment = "SMC " + TFToString(g_anchorTF);

   if(usePending)
   {
      if(g_direction == 1)
         ok = trade.BuyLimit(volume, entry, _Symbol, sl, tp, ORDER_TIME_GTC, 0, comment);
      else
         ok = trade.SellLimit(volume, entry, _Symbol, sl, tp, ORDER_TIME_GTC, 0, comment);
   }
   else
   {
      if(g_direction == 1)
         ok = trade.Buy(volume, _Symbol, 0.0, sl, tp, comment);
      else
         ok = trade.Sell(volume, _Symbol, 0.0, sl, tp, comment);
   }

   if(ok)
   {
      g_pendingPlaced = TimeCurrent();
      SetState(STATE_IN_TRADE,
               StringFormat("Order placed | lot %.2f | RR %.2f", volume, rr));
      return true;
   }

   g_reason = "Trade failed: " + trade.ResultRetcodeDescription();
   return false;
}

bool IsNewBar(ENUM_TIMEFRAMES tf, datetime &lastBar)
{
   datetime t = iTime(_Symbol, tf, 0);
   if(t <= 0)
      return false;

   if(t != lastBar)
   {
      lastBar = t;
      return true;
   }
   return false;
}

void ResetSetup(string reason)
{
   DeleteOurPendingOrders();

   g_direction = 0;
   g_anchorTF = PERIOD_CURRENT;
   g_setupTF = PERIOD_CURRENT;
   g_liquidityTF = PERIOD_CURRENT;
   g_confirmTF = PERIOD_CURRENT;
   g_entryTF = PERIOD_CURRENT;

   g_anchorHigh = 0.0;
   g_anchorLow = 0.0;
   g_anchorEQ = 0.0;

   g_sweepLevel = 0.0;
   g_sweepExtreme = 0.0;

   g_setupStart = 0;
   g_confirmationTime = 0;
   g_pendingPlaced = 0;
   g_lastStateBar = 0;

   SetState(STATE_SCAN_DIRECTION, reason);
}

void UpdatePanel()
{
   if(!ShowPanel)
   {
      Comment("");
      return;
   }

   string dir = (g_direction == 1 ? "BUY" :
                 g_direction == -1 ? "SELL" : "NONE");

   string anchor = (g_anchorTF == PERIOD_CURRENT ? "-" : TFToString(g_anchorTF));

   string txt = "";
   txt += "SMC Dynamic MTF EA\n";
   txt += "State: " + StateToString(g_state) + "\n";
   txt += "Direction: " + dir + " | Anchor: " + anchor + "\n";

   if(g_anchorTF != PERIOD_CURRENT)
   {
      txt += "Setup/Liq/Confirm/Entry: " +
             TFToString(g_setupTF) + "/" +
             TFToString(g_liquidityTF) + "/" +
             TFToString(g_confirmTF) + "/" +
             TFToString(g_entryTF) + "\n";

      txt += StringFormat("Anchor H/L/EQ: %.2f / %.2f / %.2f\n",
                          g_anchorHigh, g_anchorLow, g_anchorEQ);
   }

   txt += StringFormat("Scores H4 B/S: %.1f / %.1f\n",
                       g_lastH4BuyScore, g_lastH4SellScore);
   txt += StringFormat("Scores H1 B/S: %.1f / %.1f\n",
                       g_lastH1BuyScore, g_lastH1SellScore);
   txt += StringFormat("Scores M30 B/S: %.1f / %.1f\n",
                       g_lastM30BuyScore, g_lastM30SellScore);

   if(g_sweepLevel > 0.0)
      txt += StringFormat("Sweep level/extreme: %.2f / %.2f\n",
                          g_sweepLevel, g_sweepExtreme);

   txt += StringFormat("Spread: %.1f pts\n", CurrentSpreadPoints());
   txt += "Reason: " + g_reason;

   Comment(txt);
}

//--------------------------- EVENTS ----------------------------------
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   // Do not delete an existing EA pending order merely because the EA was reloaded.
   g_state = STATE_SCAN_DIRECTION;
   g_reason = "EA initialized";
   g_lastStateBar = 0;
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   Comment("");
}

void OnTick()
{
   UpdatePanel();

   // If position/pending exists, protect state from duplicate entries.
   if(g_state != STATE_IN_TRADE && OneExposureOnly && HasOurExposure())
   {
      SetState(STATE_IN_TRADE, "Exposure detected");
      return;
   }

   // Manage exposure / pending timeout.
   if(g_state == STATE_IN_TRADE)
   {
      if(HasOurExposure())
      {
         if(g_pendingPlaced > 0 &&
            PendingExpiryBars > 0 &&
            g_entryTF != PERIOD_CURRENT)
         {
            int sec = PeriodSeconds(g_entryTF);
            if(sec > 0 &&
               (TimeCurrent() - g_pendingPlaced) > PendingExpiryBars * sec)
            {
               // Only pending orders are deleted. Open positions remain untouched.
               bool hadPosition = false;
               for(int i=PositionsTotal()-1; i>=0; i--)
               {
                  ulong ticket = PositionGetTicket(i);
                  if(ticket == 0) continue;
                  if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
                     (ulong)PositionGetInteger(POSITION_MAGIC) == MagicNumber)
                  {
                     hadPosition = true;
                     break;
                  }
               }

               if(!hadPosition)
               {
                  DeleteOurPendingOrders();
                  ResetSetup("Pending expired");
               }
            }
         }
         return;
      }

      ResetSetup("Trade cycle finished");
      return;
   }

   if(g_state != STATE_SCAN_DIRECTION && SetupInvalidated())
   {
      ResetSetup("Setup invalidated/timeout");
      return;
   }

   // 1) Dynamic Anchor scan.
   if(g_state == STATE_SCAN_DIRECTION)
   {
      if(!IsNewBar(PERIOD_M30, g_lastScanBar))
         return;

      if(!SpreadOK())
      {
         g_reason = "Waiting spread";
         return;
      }

      if(SelectAnchor())
      {
         MapLowerTFs(g_anchorTF);
         g_setupStart = TimeCurrent();
         SetState(STATE_WAIT_PULLBACK,
                  "Anchor selected: " + TFToString(g_anchorTF));
      }
      else
      {
         g_reason = "No H4/H1/M30 direction passed score";
      }
      return;
   }

   // 2) Wait for price to reach discount/premium of Anchor range.
   if(g_state == STATE_WAIT_PULLBACK)
   {
      if(PullbackReached())
         SetState(STATE_WAIT_SWEEP, "Pullback reached EQ zone");
      else
         g_reason = "Waiting pullback";
      return;
   }

   // 3) Liquidity sweep on lower TF.
   if(g_state == STATE_WAIT_SWEEP)
   {
      if(!IsNewBar(g_liquidityTF, g_lastStateBar))
         return;

      double level=0.0, extreme=0.0;
      if(DetectLiquiditySweep(g_liquidityTF, g_direction, level, extreme))
      {
         g_sweepLevel = level;
         g_sweepExtreme = extreme;
         SetState(STATE_WAIT_CHOCH,
                  "Liquidity sweep on " + TFToString(g_liquidityTF));
      }
      else
      {
         g_reason = "Waiting liquidity sweep";
      }
      return;
   }

   // 4) CHoCH + displacement.
   if(g_state == STATE_WAIT_CHOCH)
   {
      if(!IsNewBar(g_confirmTF, g_lastStateBar))
         return;

      bool choch = DetectCHoCH(g_confirmTF, g_direction);
      bool displacement = LastClosedDisplacement(g_confirmTF, g_direction);

      if(choch && displacement)
      {
         // Start of the closed confirmation candle. FVGs older than this are ignored.
         g_confirmationTime = iTime(_Symbol, g_confirmTF, 1);
         SetState(STATE_WAIT_ENTRY,
                  "CHoCH + displacement confirmed");
      }
      else
      {
         if(!choch && !displacement)
            g_reason = "Waiting CHoCH + displacement";
         else if(!choch)
            g_reason = "Waiting CHoCH";
         else
            g_reason = "Waiting displacement";
      }
      return;
   }

   // 5) FVG / Entry.
   if(g_state == STATE_WAIT_ENTRY)
   {
      // Try immediately once, then only on a new entry-TF bar.
      if(g_lastStateBar == 0)
      {
         g_lastStateBar = iTime(_Symbol, g_entryTF, 0);
         PlaceEntry();
         return;
      }

      if(IsNewBar(g_entryTF, g_lastStateBar))
         PlaceEntry();

      return;
   }
}
//+------------------------------------------------------------------+
