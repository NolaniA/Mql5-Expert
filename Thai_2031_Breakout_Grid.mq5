//+------------------------------------------------------------------+
//|                    Thai_2031_Breakout_Grid.mq5                   |
//|  M1 20:26-20:30 Thai range -> 2 consecutive breakout signals    |
//|  5-level retracement grid + martingale + selectable basket TP    |
//+------------------------------------------------------------------+
#property strict

#include <Trade/Trade.mqh>

CTrade trade;

//----------------------------- Inputs -------------------------------//
input group "01. GENERAL"
input ulong  InpMagic                  = 20312026;
input int    InpDeviationPoints        = 20;

input group "02. TIME & SESSION"
// Session is fixed in Thailand time (UTC+7)
input bool   InpAutoServerUTCOffset    = true;
input int    InpManualServerUTCOffset  = 2;      // used mainly in Strategy Tester if auto offset is unsuitable
input int    InpConfirmTimeoutMinutes  = 60;     // 20:31-21:30; expire at 21:31 Thai time

input group "03. GRID & LOT"
input double InpFirstLot               = 0.01;
input double InpMartingaleMultiplier   = 2.0;
input int    InpGridOrders             = 5;      // designed for 5, but kept configurable

//------------------------- Take Profit mode -------------------------//
enum TakeProfitMode
{
   TP_MODE_RANGE = 0,              // DEFAULT: target = confirm close +/- (20:26-20:30 range * multiplier)
   TP_MODE_BALANCE_ADAPTIVE = 1    // adaptive basket TP based on % of balance before the cycle
};

input group "04. SIDEWAY FILTER"
input bool            InpEnableSidewayFilter = true;
input ENUM_TIMEFRAMES InpADXTimeframe        = PERIOD_M1;
input int             InpADXPeriod           = 14;
input double          InpADXTrendThreshold   = 20.0;   // ADX < threshold = sideway, block new signal
input bool            InpResetSignalOnSideway= true;   // sideway breaks BUY/SELL confirmation continuity

input group "05. TAKE PROFIT - MODE"
input bool           InpEnableTakeProfit      = true;
input TakeProfitMode InpTakeProfitMode        = TP_MODE_RANGE;

input group "06. TAKE PROFIT - RANGE"
input double InpRangeTPMultiplier             = 1.0;

input group "07. TAKE PROFIT - BALANCE ADAPTIVE"
input double InpTPStartPercent                = 10.0;
input double InpTPStepPercent                 = 5.0;
input int    InpTPObserveSeconds              = 60;     // minimum observation after first reaching >= 10%
input int    InpTPStallSeconds                = 30;     // no new higher profit band for this long
input double InpVisitWeightSeconds            = 5.0;    // 1 revisit = this many "score seconds"

input group "08. SL PROFIT PROTECTION"
input bool   InpEnableHalfRangeSLProtect = true;
input double InpSLProtectTriggerRange    = 0.5;   // trigger after favorable move = Range x value
input bool   InpCloseBasketOnFrontSL     = true;  // front-entry SL hit => close basket + delete pending, same as TP

input group "09. SAFETY & CYCLE"
input bool   InpOneCyclePerThaiDay      = true;
input bool   InpDeleteOldPendingsNewDay = true;

input group "10. PANEL"
input bool             InpShowPanel      = true;
input ENUM_BASE_CORNER InpPanelCorner    = CORNER_LEFT_UPPER;
input int              InpPanelX         = 10;
input int              InpPanelY         = 20;
input int              InpPanelFontSize  = 9;

//----------------------------- State --------------------------------//
enum TradeDirection
{
   DIR_NONE = 0,
   DIR_BUY  = 1,
   DIR_SELL = -1
};

datetime       g_lastM1Bar            = 0;
int            g_thaiDateKey          = -1;

bool           g_rangeReady           = false;
double         g_rangeHigh            = 0.0;
double         g_rangeLow             = 0.0;

int            g_buySignal            = 0;
int            g_sellSignal           = 0;
TradeDirection g_confirmedDirection   = DIR_NONE;
double         g_confirmClose         = 0.0;

bool           g_dailyCycleDone       = false;
bool           g_sessionExpired       = false;
bool           g_cycleActive          = false;
double         g_cycleBaseBalance     = 0.0;
datetime       g_cycleStartTime       = 0;

// Sideway filter (ADX)
int            g_adxHandle             = INVALID_HANDLE;
double         g_lastADXValue          = 0.0;
bool           g_lastADXValid          = false;
bool           g_lastSideway           = false;

// Half-range SL protection
double         g_frontEntryPrice      = 0.0;
bool           g_halfRangeSLProtected = false;
bool           g_closingBasket        = false;

// Adaptive TP tracking
#define MAX_TP_BANDS 50
double   g_bandSeconds[MAX_TP_BANDS];
int      g_bandVisits[MAX_TP_BANDS];
int      g_lastProfitBand             = -1;
int      g_highestProfitBand          = -1;
datetime g_firstTPHitTime             = 0;
datetime g_lastNewHighBandTime        = 0;
datetime g_lastTPUpdateTime           = 0;

//-------------------------- Time helpers -----------------------------//
int GetServerUTCOffsetSeconds()
{
   if(!InpAutoServerUTCOffset)
      return InpManualServerUTCOffset * 3600;

   // Round to nearest 15 minutes to avoid small TimeTradeServer/TimeGMT drift
   long raw = (long)(TimeTradeServer() - TimeGMT());
   return (int)MathRound((double)raw / 900.0) * 900;
}

datetime ServerToThai(datetime serverTime)
{
   return serverTime - GetServerUTCOffsetSeconds() + 7 * 3600;
}

datetime ThaiToServer(datetime thaiPseudoTime)
{
   return thaiPseudoTime - 7 * 3600 + GetServerUTCOffsetSeconds();
}

int DateKey(datetime thaiTime)
{
   MqlDateTime dt;
   TimeToStruct(thaiTime, dt);
   return dt.year * 10000 + dt.mon * 100 + dt.day;
}

datetime MakeThaiTimeForToday(int hour, int minute, int second=0)
{
   datetime thaiNow = ServerToThai(TimeTradeServer());
   MqlDateTime dt;
   TimeToStruct(thaiNow, dt);
   dt.hour = hour;
   dt.min  = minute;
   dt.sec  = second;
   return StructToTime(dt);
}

bool ThaiTimeAtOrAfter(datetime serverTime, int hour, int minute)
{
   MqlDateTime dt;
   TimeToStruct(ServerToThai(serverTime), dt);

   if(dt.hour > hour) return true;
   if(dt.hour < hour) return false;
   return (dt.min >= minute);
}

// Confirmation window starts at 20:31 Thai time.
// With the default 60 minutes, M1 bars 20:31 through 21:30 are eligible.
datetime ConfirmationDeadlineThai()
{
   return MakeThaiTimeForToday(20, 31, 0) + InpConfirmTimeoutMinutes * 60;
}

void ExpireConfirmationSession(string reason)
{
   if(g_sessionExpired || g_confirmedDirection != DIR_NONE)
      return;

   g_sessionExpired = true;
   g_buySignal      = 0;
   g_sellSignal     = 0;

   Print("CONFIRMATION SESSION EXPIRED: ", reason,
         " | no new trade until next Thai day");
}

void CheckConfirmationTimeout()
{
   if(InpConfirmTimeoutMinutes <= 0 ||
      g_sessionExpired ||
      g_confirmedDirection != DIR_NONE ||
      g_dailyCycleDone)
      return;

   datetime thaiNow = ServerToThai(TimeTradeServer());

   if(thaiNow >= ConfirmationDeadlineThai())
      ExpireConfirmationSession("timeout " + IntegerToString(InpConfirmTimeoutMinutes) + " minutes");
}

//------------------------- Price / volume ----------------------------//
double NormalizePrice(double price)
{
   double tick = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick <= 0.0)
      tick = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   return NormalizeDouble(MathRound(price / tick) * tick, digits);
}

int VolumeDigits(double step)
{
   int d = 0;
   while(d < 8 && MathAbs(step - NormalizeDouble(step, d)) > 1e-12)
      d++;
   return d;
}

double NormalizeVolume(double volume)
{
   double vmin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vmax  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double vstep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(vstep <= 0.0)
      vstep = vmin;

   volume = MathMax(vmin, MathMin(vmax, volume));
   volume = MathFloor(volume / vstep + 1e-10) * vstep;

   return NormalizeDouble(volume, VolumeDigits(vstep));
}

double LotForLevel(int levelIndex)
{
   // levelIndex starts at 0
   return NormalizeVolume(InpFirstLot * MathPow(InpMartingaleMultiplier, levelIndex));
}

//---------------------------- Ownership ------------------------------//
bool IsOwnPositionByTicket(ulong ticket)
{
   if(!PositionSelectByTicket(ticket))
      return false;

   if(PositionGetString(POSITION_SYMBOL) != _Symbol)
      return false;

   if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic)
      return false;

   return true;
}

bool IsOwnOrderByTicket(ulong ticket)
{
   if(!OrderSelect(ticket))
      return false;

   if(OrderGetString(ORDER_SYMBOL) != _Symbol)
      return false;

   if((ulong)OrderGetInteger(ORDER_MAGIC) != InpMagic)
      return false;

   return true;
}

bool HasOwnPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && IsOwnPositionByTicket(ticket))
         return true;
   }
   return false;
}

bool HasOwnOrders()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket > 0 && IsOwnOrderByTicket(ticket))
         return true;
   }
   return false;
}

void DeleteOwnPendingOrders()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || !IsOwnOrderByTicket(ticket))
         continue;

      if(!trade.OrderDelete(ticket))
         Print("OrderDelete failed ticket=", ticket,
               " ret=", trade.ResultRetcode(),
               " ", trade.ResultRetcodeDescription());
   }
}

void CloseOwnPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !IsOwnPositionByTicket(ticket))
         continue;

      if(!trade.PositionClose(ticket))
         Print("PositionClose failed ticket=", ticket,
               " ret=", trade.ResultRetcode(),
               " ", trade.ResultRetcodeDescription());
   }
}

void CloseBasketAndPendings(string reason)
{
   if(g_closingBasket)
      return;

   g_closingBasket = true;

   Print("CLOSE BASKET: ", reason);

   CloseOwnPositions();
   DeleteOwnPendingOrders();

   g_cycleActive = false;
   g_closingBasket = false;
}

//--------------------- Half-range SL protection ---------------------//
double HalfRangeProtectionTriggerPrice()
{
   if(!g_rangeReady || g_confirmedDirection == DIR_NONE || InpSLProtectTriggerRange <= 0.0)
      return 0.0;

   double rangeSize = g_rangeHigh - g_rangeLow;
   if(rangeSize <= 0.0)
      return 0.0;

   if(g_confirmedDirection == DIR_BUY)
      return NormalizePrice(g_confirmClose + rangeSize * InpSLProtectTriggerRange);

   if(g_confirmedDirection == DIR_SELL)
      return NormalizePrice(g_confirmClose - rangeSize * InpSLProtectTriggerRange);

   return 0.0;
}

bool IsValidProtectionSL(ENUM_POSITION_TYPE type, double sl, const MqlTick &tick)
{
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int stopsLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   int freezeLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   double minDistance = MathMax(stopsLevel, freezeLevel) * point;

   if(type == POSITION_TYPE_BUY)
      return (sl > 0.0 && sl < tick.bid - minDistance);

   if(type == POSITION_TYPE_SELL)
      return (sl > tick.ask + minDistance);

   return false;
}

void MoveOpenPositionsSLToFrontEntry()
{
   if(g_frontEntryPrice <= 0.0)
      g_frontEntryPrice = g_confirmClose;

   double protectSL = NormalizePrice(g_frontEntryPrice);
   if(protectSL <= 0.0)
      return;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return;

   int modified = 0;
   int failed = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !IsOwnPositionByTicket(ticket))
         continue;

      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if((g_confirmedDirection == DIR_BUY  && type != POSITION_TYPE_BUY) ||
         (g_confirmedDirection == DIR_SELL && type != POSITION_TYPE_SELL))
         continue;

      double oldSL = PositionGetDouble(POSITION_SL);
      double oldTP = PositionGetDouble(POSITION_TP);

      // Never make an existing SL worse.
      bool needsModify = false;
      if(type == POSITION_TYPE_BUY)
         needsModify = (oldSL == 0.0 || oldSL < protectSL);
      else if(type == POSITION_TYPE_SELL)
         needsModify = (oldSL == 0.0 || oldSL > protectSL);

      if(!needsModify)
         continue;

      if(!IsValidProtectionSL(type, protectSL, tick))
      {
         failed++;
         Print("Half-range SL protection skipped ticket=", ticket,
               " because front-entry SL is inside broker stop/freeze distance. SL=",
               DoubleToString(protectSL, _Digits));
         continue;
      }

      if(trade.PositionModify(ticket, protectSL, oldTP))
      {
         modified++;
         Print("Half-range SL protection ticket=", ticket,
               " new SL=", DoubleToString(protectSL, _Digits));
      }
      else
      {
         failed++;
         Print("PositionModify failed ticket=", ticket,
               " ret=", trade.ResultRetcode(),
               " ", trade.ResultRetcodeDescription());
      }
   }

   // Mark as protected only when there is at least one open position and
   // every required modification was accepted. If broker distance blocks it,
   // the EA retries on following ticks as price moves farther away.
   if(HasOwnPositions() && failed == 0)
   {
      g_halfRangeSLProtected = true;
      Print("HALF-RANGE SL PROTECTED. Front entry=",
            DoubleToString(protectSL, _Digits),
            " modified positions=", modified);
   }
}

void ManageHalfRangeSLProtection()
{
   if(!InpEnableHalfRangeSLProtect || g_halfRangeSLProtected || !g_cycleActive)
      return;

   if(!HasOwnPositions())
      return;

   double trigger = HalfRangeProtectionTriggerPrice();
   if(trigger <= 0.0)
      return;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return;

   bool reached = false;
   if(g_confirmedDirection == DIR_BUY)
      reached = (tick.bid >= trigger);
   else if(g_confirmedDirection == DIR_SELL)
      reached = (tick.ask <= trigger);

   if(reached)
      MoveOpenPositionsSLToFrontEntry();
}


// If the SL moved to the front-entry price is hit, treat it exactly like a
// basket TP: close every remaining position and remove all pending limits.
void ManageFrontEntrySLExit(const MqlTradeTransaction &trans)
{
   if(!InpEnableHalfRangeSLProtect || !InpCloseBasketOnFrontSL)
      return;

   if(!g_cycleActive || !g_halfRangeSLProtected || g_closingBasket)
      return;

   if(trans.type != TRADE_TRANSACTION_DEAL_ADD || trans.deal == 0)
      return;

   ulong dealTicket = trans.deal;

   if(HistoryDealGetString(dealTicket, DEAL_SYMBOL) != _Symbol)
      return;

   if((ulong)HistoryDealGetInteger(dealTicket, DEAL_MAGIC) != InpMagic)
      return;

   ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
   if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY)
      return;

   ENUM_DEAL_REASON reason = (ENUM_DEAL_REASON)HistoryDealGetInteger(dealTicket, DEAL_REASON);
   if(reason != DEAL_REASON_SL)
      return;

   double exitPrice = HistoryDealGetDouble(dealTicket, DEAL_PRICE);

   // Once half-range protection is active, every protected position uses the
   // front-entry protective SL. Therefore ANY SL deal from this EA after the
   // protection flag is set ends the whole cycle immediately. We deliberately
   // do not compare the execution price with g_frontEntryPrice because broker
   // slippage/gaps can execute an SL away from the requested SL price.
   CloseBasketAndPendings(
      "Front-entry protection SL hit at " + DoubleToString(exitPrice, _Digits));
}

//------------------------- Adaptive TP data --------------------------//
void ResetTPStats()
{
   ArrayInitialize(g_bandSeconds, 0.0);
   ArrayInitialize(g_bandVisits,  0);

   g_lastProfitBand      = -1;
   g_highestProfitBand   = -1;
   g_firstTPHitTime      = 0;
   g_lastNewHighBandTime = 0;
   g_lastTPUpdateTime    = 0;
}

double OwnFloatingProfit()
{
   double result = 0.0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !IsOwnPositionByTicket(ticket))
         continue;

      result += PositionGetDouble(POSITION_PROFIT);
      result += PositionGetDouble(POSITION_SWAP);
   }

   return result;
}

double OwnRealizedProfitSince(datetime fromTime)
{
   if(fromTime <= 0)
      return 0.0;

   if(!HistorySelect(fromTime, TimeCurrent()))
      return 0.0;

   double result = 0.0;
   int total = HistoryDealsTotal();

   for(int i = 0; i < total; i++)
   {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket == 0)
         continue;

      if(HistoryDealGetString(dealTicket, DEAL_SYMBOL) != _Symbol)
         continue;

      if((ulong)HistoryDealGetInteger(dealTicket, DEAL_MAGIC) != InpMagic)
         continue;

      result += HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
      result += HistoryDealGetDouble(dealTicket, DEAL_SWAP);
      result += HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
      result += HistoryDealGetDouble(dealTicket, DEAL_FEE);
   }

   return result;
}

double CycleProfitMoney()
{
   return OwnRealizedProfitSince(g_cycleStartTime) + OwnFloatingProfit();
}

double CycleProfitPercent()
{
   if(g_cycleBaseBalance <= 0.0)
      return 0.0;

   return 100.0 * CycleProfitMoney() / g_cycleBaseBalance;
}

int ProfitBandFromPct(double profitPct)
{
   if(profitPct < InpTPStartPercent || InpTPStepPercent <= 0.0)
      return -1;

   int band = (int)MathFloor((profitPct - InpTPStartPercent) / InpTPStepPercent);

   if(band < 0)
      band = 0;
   if(band >= MAX_TP_BANDS)
      band = MAX_TP_BANDS - 1;

   return band;
}

int DominantProfitBand()
{
   int best = -1;
   double bestScore = -1.0;

   int maxBand = g_highestProfitBand;
   if(maxBand >= MAX_TP_BANDS)
      maxBand = MAX_TP_BANDS - 1;

   for(int i = 0; i <= maxBand; i++)
   {
      double score = g_bandSeconds[i] +
                     ((double)g_bandVisits[i] * InpVisitWeightSeconds);

      if(score > bestScore)
      {
         bestScore = score;
         best = i;
      }
   }

   return best;
}

double RangeTPPrice()
{
   if(!g_rangeReady || g_confirmedDirection == DIR_NONE || InpRangeTPMultiplier <= 0.0)
      return 0.0;

   double rangeSize = g_rangeHigh - g_rangeLow;
   if(rangeSize <= 0.0)
      return 0.0;

   if(g_confirmedDirection == DIR_BUY)
      return NormalizePrice(g_confirmClose + rangeSize * InpRangeTPMultiplier);

   if(g_confirmedDirection == DIR_SELL)
      return NormalizePrice(g_confirmClose - rangeSize * InpRangeTPMultiplier);

   return 0.0;
}

void ManageRangeBasketTP()
{
   if(!g_cycleActive || !InpEnableTakeProfit || InpTakeProfitMode != TP_MODE_RANGE)
      return;

   if(!HasOwnPositions() && !HasOwnOrders())
   {
      g_cycleActive = false;
      return;
   }

   // Do not finish a cycle from price alone if no position was opened.
   if(!HasOwnPositions())
      return;

   double target = RangeTPPrice();
   if(target <= 0.0)
      return;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return;

   bool reached = false;

   // Use executable side of the quote for a basket exit.
   if(g_confirmedDirection == DIR_BUY)
      reached = (tick.bid >= target);
   else if(g_confirmedDirection == DIR_SELL)
      reached = (tick.ask <= target);

   if(reached)
   {
      string reason =
         "Range TP reached, target=" + DoubleToString(target, _Digits) +
         " multiplier=" + DoubleToString(InpRangeTPMultiplier, 2);

      CloseBasketAndPendings(reason);
   }
}

void ManageAdaptiveBasketTP()
{
   if(!g_cycleActive || !InpEnableTakeProfit || InpTakeProfitMode != TP_MODE_BALANCE_ADAPTIVE)
      return;

   // If everything has already been closed/stopped, cycle is over.
   if(!HasOwnPositions() && !HasOwnOrders())
   {
      g_cycleActive = false;
      return;
   }

   datetime now = TimeCurrent();
   double profitPct = CycleProfitPercent();
   int currentBand = ProfitBandFromPct(profitPct);

   if(g_lastTPUpdateTime == 0)
      g_lastTPUpdateTime = now;

   double elapsed = (double)(now - g_lastTPUpdateTime);
   if(elapsed < 0.0) elapsed = 0.0;
   if(elapsed > 60.0) elapsed = 60.0; // avoid oversized jumps after no ticks

   // Time since the previous tick belongs to the previous observed band.
   if(g_lastProfitBand >= 0 && g_lastProfitBand < MAX_TP_BANDS)
      g_bandSeconds[g_lastProfitBand] += elapsed;

   g_lastTPUpdateTime = now;

   if(currentBand < 0)
   {
      g_lastProfitBand = -1;
      return;
   }

   if(g_firstTPHitTime == 0)
   {
      g_firstTPHitTime = now;
      g_lastNewHighBandTime = now;
   }

   if(currentBand != g_lastProfitBand)
   {
      g_bandVisits[currentBand]++;
      g_lastProfitBand = currentBand;
   }

   if(currentBand > g_highestProfitBand)
   {
      g_highestProfitBand = currentBand;
      g_lastNewHighBandTime = now;

      double lower = InpTPStartPercent + currentBand * InpTPStepPercent;
      double upper = lower + InpTPStepPercent;

      Print("New TP band reached: ", DoubleToString(lower, 2),
            "% - ", DoubleToString(upper, 2), "%");
   }

   if((now - g_firstTPHitTime) < InpTPObserveSeconds)
      return;

   if((now - g_lastNewHighBandTime) < InpTPStallSeconds)
      return;

   int dominant = DominantProfitBand();
   if(dominant < 0)
      return;

   // Close only when the current profit is actually inside the band
   // that has the highest dwell/revisit score.
   if(currentBand == dominant)
   {
      double bandLow  = InpTPStartPercent + dominant * InpTPStepPercent;
      double bandHigh = bandLow + InpTPStepPercent;

      string reason =
         "Adaptive TP, profit=" + DoubleToString(profitPct, 2) +
         "% dominant=" + DoubleToString(bandLow, 2) +
         "-" + DoubleToString(bandHigh, 2) + "%";

      CloseBasketAndPendings(reason);
   }
}

//--------------------------- Daily reset -----------------------------//
void ResetDailyState(bool deletePendings)
{
   if(deletePendings)
      DeleteOwnPendingOrders();

   g_rangeReady         = false;
   g_rangeHigh          = 0.0;
   g_rangeLow           = 0.0;

   g_buySignal          = 0;
   g_sellSignal         = 0;
   g_confirmedDirection = DIR_NONE;
   g_confirmClose       = 0.0;

   g_dailyCycleDone     = false;
   g_sessionExpired     = false;

   // Do not forcibly close an open position just because the Thai date changed.
   // If positions remain, adaptive TP can still manage the existing cycle.
   if(!HasOwnPositions() && !HasOwnOrders())
   {
      g_cycleActive          = false;
      g_cycleBaseBalance     = 0.0;
      g_cycleStartTime       = 0;
      g_frontEntryPrice      = 0.0;
      g_halfRangeSLProtected = false;
      ResetTPStats();
   }
}

void CheckThaiDayChange()
{
   datetime thaiNow = ServerToThai(TimeTradeServer());
   int key = DateKey(thaiNow);

   if(g_thaiDateKey < 0)
   {
      g_thaiDateKey = key;
      return;
   }

   if(key != g_thaiDateKey)
   {
      g_thaiDateKey = key;
      ResetDailyState(InpDeleteOldPendingsNewDay);
      Print("New Thai trading day reset: ", key);
   }
}

//------------------------- Session range -----------------------------//
bool Load2026to2030Range()
{
   datetime thaiStart = MakeThaiTimeForToday(20, 26, 0);
   datetime thaiEnd   = MakeThaiTimeForToday(20, 30, 59);

   datetime serverStart = ThaiToServer(thaiStart);
   datetime serverEnd   = ThaiToServer(thaiEnd);

   MqlRates rates[];
   ArraySetAsSeries(rates, false);

   int copied = CopyRates(_Symbol, PERIOD_M1, serverStart, serverEnd, rates);
   if(copied <= 0)
   {
      Print("CopyRates 20:26-20:30 failed. error=", GetLastError());
      return false;
   }

   double hi = -DBL_MAX;
   double lo =  DBL_MAX;
   int validBars = 0;

   for(int i = 0; i < copied; i++)
   {
      datetime thaiBarTime = ServerToThai(rates[i].time);
      MqlDateTime dt;
      TimeToStruct(thaiBarTime, dt);

      // Explicitly keep exactly 5 M1 bars: 20:26, 20:27, 20:28, 20:29, 20:30 Thai time.
      if(dt.hour == 20 && dt.min >= 26 && dt.min <= 30)
      {
         if(rates[i].high > hi) hi = rates[i].high;
         if(rates[i].low  < lo) lo = rates[i].low;
         validBars++;
      }
   }

   if(validBars < 5 || hi <= lo)
   {
      Print("Range not ready. valid M1 bars=", validBars,
            " hi=", hi, " lo=", lo);
      return false;
   }

   g_rangeHigh  = NormalizePrice(hi);
   g_rangeLow   = NormalizePrice(lo);
   g_rangeReady = true;

   Print("Thai 20:26-20:30 range ready. High=",
         DoubleToString(g_rangeHigh, _Digits),
         " Low=", DoubleToString(g_rangeLow, _Digits));

   return true;
}

//-------------------------- Order placement --------------------------//
bool PlaceBuyGrid()
{
   if(InpGridOrders < 2)
   {
      Print("InpGridOrders must be >= 2");
      return false;
   }

   double zoneTop = NormalizePrice(g_confirmClose);
   double zoneLow = NormalizePrice(g_rangeLow);

   if(zoneTop <= zoneLow)
   {
      Print("BUY zone invalid. top<=low");
      return false;
   }

   // 5 entries means 5 equal risk segments:
   // entry1 = top
   // entry2 = top - 1*(range/5)
   // ...
   // entry5 = top - 4*(range/5)
   // SL5    = zoneLow
   double step = (zoneTop - zoneLow) / InpGridOrders;

   double entry[];
   double sl[];
   ArrayResize(entry, InpGridOrders);
   ArrayResize(sl, InpGridOrders);

   for(int i = 0; i < InpGridOrders; i++)
   {
      entry[i] = NormalizePrice(zoneTop - i * step);
      sl[i]    = (i < InpGridOrders - 1)
                 ? NormalizePrice(zoneTop - (i + 1) * step)
                 : zoneLow;
   }

   g_cycleBaseBalance     = AccountInfoDouble(ACCOUNT_BALANCE);
   g_cycleStartTime       = TimeCurrent();
   g_frontEntryPrice      = 0.0;
   g_halfRangeSLProtected = false;
   ResetTPStats();

   bool placedAny = false;

   // First leg: market BUY immediately after confirmation.
   double lot0 = LotForLevel(0);
   if(trade.Buy(lot0, _Symbol, 0.0, sl[0], 0.0, "2031 BUY #1"))
   {
      placedAny = true;
      g_frontEntryPrice = NormalizePrice(trade.ResultPrice());
      if(g_frontEntryPrice <= 0.0)
         g_frontEntryPrice = entry[0];
      Print("BUY #1 market lot=", lot0,
            " intended entry=", DoubleToString(entry[0], _Digits),
            " SL=", DoubleToString(sl[0], _Digits));
   }
   else
   {
      Print("BUY #1 failed ret=", trade.ResultRetcode(),
            " ", trade.ResultRetcodeDescription());
   }

   // Remaining legs: BUY LIMIT retracement orders.
   for(int i = 1; i < InpGridOrders; i++)
   {
      double lot = LotForLevel(i);
      string comment = "2031 BUY #" + IntegerToString(i + 1);

      if(trade.BuyLimit(lot, entry[i], _Symbol, sl[i], 0.0,
                        ORDER_TIME_GTC, 0, comment))
      {
         placedAny = true;
         Print(comment,
               " lot=", lot,
               " entry=", DoubleToString(entry[i], _Digits),
               " SL=", DoubleToString(sl[i], _Digits));
      }
      else
      {
         Print(comment, " failed ret=", trade.ResultRetcode(),
               " ", trade.ResultRetcodeDescription(),
               " entry=", DoubleToString(entry[i], _Digits),
               " SL=", DoubleToString(sl[i], _Digits));
      }
   }

   if(placedAny)
      g_cycleActive = true;
   else
   {
      g_cycleBaseBalance = 0.0;
      g_cycleStartTime   = 0;
   }

   return placedAny;
}

bool PlaceSellGrid()
{
   if(InpGridOrders < 2)
   {
      Print("InpGridOrders must be >= 2");
      return false;
   }

   double zoneBottom = NormalizePrice(g_confirmClose);
   double zoneHigh   = NormalizePrice(g_rangeHigh);

   if(zoneBottom >= zoneHigh)
   {
      Print("SELL zone invalid. bottom>=high");
      return false;
   }

   double step = (zoneHigh - zoneBottom) / InpGridOrders;

   double entry[];
   double sl[];
   ArrayResize(entry, InpGridOrders);
   ArrayResize(sl, InpGridOrders);

   for(int i = 0; i < InpGridOrders; i++)
   {
      entry[i] = NormalizePrice(zoneBottom + i * step);
      sl[i]    = (i < InpGridOrders - 1)
                 ? NormalizePrice(zoneBottom + (i + 1) * step)
                 : zoneHigh;
   }

   g_cycleBaseBalance     = AccountInfoDouble(ACCOUNT_BALANCE);
   g_cycleStartTime       = TimeCurrent();
   g_frontEntryPrice      = 0.0;
   g_halfRangeSLProtected = false;
   ResetTPStats();

   bool placedAny = false;

   // First leg: market SELL immediately after confirmation.
   double lot0 = LotForLevel(0);
   if(trade.Sell(lot0, _Symbol, 0.0, sl[0], 0.0, "2031 SELL #1"))
   {
      placedAny = true;
      g_frontEntryPrice = NormalizePrice(trade.ResultPrice());
      if(g_frontEntryPrice <= 0.0)
         g_frontEntryPrice = entry[0];
      Print("SELL #1 market lot=", lot0,
            " intended entry=", DoubleToString(entry[0], _Digits),
            " SL=", DoubleToString(sl[0], _Digits));
   }
   else
   {
      Print("SELL #1 failed ret=", trade.ResultRetcode(),
            " ", trade.ResultRetcodeDescription());
   }

   // Remaining legs: SELL LIMIT retracement orders.
   for(int i = 1; i < InpGridOrders; i++)
   {
      double lot = LotForLevel(i);
      string comment = "2031 SELL #" + IntegerToString(i + 1);

      if(trade.SellLimit(lot, entry[i], _Symbol, sl[i], 0.0,
                         ORDER_TIME_GTC, 0, comment))
      {
         placedAny = true;
         Print(comment,
               " lot=", lot,
               " entry=", DoubleToString(entry[i], _Digits),
               " SL=", DoubleToString(sl[i], _Digits));
      }
      else
      {
         Print(comment, " failed ret=", trade.ResultRetcode(),
               " ", trade.ResultRetcodeDescription(),
               " entry=", DoubleToString(entry[i], _Digits),
               " SL=", DoubleToString(sl[i], _Digits));
      }
   }

   if(placedAny)
      g_cycleActive = true;
   else
   {
      g_cycleBaseBalance = 0.0;
      g_cycleStartTime   = 0;
   }

   return placedAny;
}

bool PlaceConfirmedGrid()
{
   if(g_dailyCycleDone && InpOneCyclePerThaiDay)
      return false;

   bool ok = false;

   if(g_confirmedDirection == DIR_BUY)
      ok = PlaceBuyGrid();
   else if(g_confirmedDirection == DIR_SELL)
      ok = PlaceSellGrid();

   if(ok)
      g_dailyCycleDone = true;

   return ok;
}

//------------------------- Sideway filter ----------------------------//
bool ReadADXValue(int shift, double &value)
{
   value = 0.0;

   if(!InpEnableSidewayFilter)
      return false;

   if(g_adxHandle == INVALID_HANDLE)
      return false;

   double buffer[1];
   int copied = CopyBuffer(g_adxHandle, 0, shift, 1, buffer);
   if(copied != 1 || buffer[0] == EMPTY_VALUE)
      return false;

   value = buffer[0];
   return true;
}

bool IsSidewayByADX(int shift, double &adxValue)
{
   if(!InpEnableSidewayFilter)
   {
      g_lastADXValue = 0.0;
      g_lastADXValid = false;
      g_lastSideway  = false;
      adxValue       = 0.0;
      return false;
   }

   if(!ReadADXValue(shift, adxValue))
   {
      g_lastADXValid = false;
      return true; // fail-safe: do not create a new signal if ADX data is unavailable
   }

   g_lastADXValue = adxValue;
   g_lastADXValid = true;
   g_lastSideway  = (adxValue < InpADXTrendThreshold);

   return g_lastSideway;
}

//------------------------- Signal processing -------------------------//
bool CandleBodyGreaterThanWicks(const MqlRates &candle)
{
   double body      = MathAbs(candle.close - candle.open);
   double upperWick = candle.high - MathMax(candle.open, candle.close);
   double lowerWick = MathMin(candle.open, candle.close) - candle.low;

   // Signal candle is valid only when its real body is larger than
   // BOTH the upper wick and the lower wick.
   return (body > upperWick && body > lowerWick);
}

void ProcessClosedM1Bar()
{
   MqlRates bar[1];
   if(CopyRates(_Symbol, PERIOD_M1, 1, 1, bar) != 1)
      return;

   datetime thaiBarTime = ServerToThai(bar[0].time);

   // Only today's Thai date.
   if(DateKey(thaiBarTime) != g_thaiDateKey)
      return;

   // Signals start from the 20:31 Thai candle onward.
   if(!ThaiTimeAtOrAfter(bar[0].time, 20, 31))
      return;

   if(g_sessionExpired)
      return;

   // The candle whose OPEN time reaches the deadline is outside the window.
   // Default 60 minutes => allow 20:31..21:30, reject 21:31 onward.
   if(InpConfirmTimeoutMinutes > 0 &&
      thaiBarTime >= ConfirmationDeadlineThai() &&
      g_confirmedDirection == DIR_NONE)
   {
      ExpireConfirmationSession("closed M1 bar reached deadline");
      return;
   }

   if(!g_rangeReady && !Load2026to2030Range())
      return;

   if(g_dailyCycleDone && InpOneCyclePerThaiDay)
      return;

   // Sideway filter is checked on the last CLOSED candle of the selected ADX timeframe.
   // If ADX < threshold, this M1 candle is ignored and cannot add BUY/SELL signal.
   double adxValue = 0.0;
   if(InpEnableSidewayFilter)
   {
      bool sideway = IsSidewayByADX(1, adxValue);
      if(!g_lastADXValid)
      {
         Print("SIDEWAY FILTER: ADX data unavailable, skip signal bar ",
               TimeToString(thaiBarTime, TIME_DATE|TIME_MINUTES));
         return;
      }

      if(sideway)
      {
         if(InpResetSignalOnSideway)
         {
            g_buySignal  = 0;
            g_sellSignal = 0;
         }

         Print("SIDEWAY FILTER: blocked signal | ADX=",
               DoubleToString(adxValue, 2),
               " < ", DoubleToString(InpADXTrendThreshold, 2),
               " | reset=", (InpResetSignalOnSideway ? "YES" : "NO"),
               " | bar=", TimeToString(thaiBarTime, TIME_DATE|TIME_MINUTES));
         return;
      }
   }

   bool strongBody = CandleBodyGreaterThanWicks(bar[0]);

   bool buyBreak =
      (bar[0].open  < g_rangeHigh &&
       bar[0].close > g_rangeHigh &&
       strongBody);

   bool sellBreak =
      (bar[0].open  > g_rangeLow &&
       bar[0].close < g_rangeLow &&
       strongBody);

   // "Continuity" here means:
   // BUY event followed by another BUY event -> BUY=2.
   // Opposite event clears the previous side.
   // Neutral bars do NOT clear the current signal count.
   if(buyBreak)
   {
      g_buySignal++;
      g_sellSignal = 0;

      Print("BUY signal +1 => ", g_buySignal,
            " | bar=", TimeToString(thaiBarTime, TIME_DATE|TIME_MINUTES),
            " O=", DoubleToString(bar[0].open, _Digits),
            " C=", DoubleToString(bar[0].close, _Digits));

      if(g_buySignal >= 2 && g_confirmedDirection == DIR_NONE)
      {
         g_buySignal            = 2;
         g_confirmedDirection   = DIR_BUY;
         g_confirmClose         = NormalizePrice(bar[0].close);

         Print("BUY CONFIRMED. Confirm close=",
               DoubleToString(g_confirmClose, _Digits),
               " zone low=", DoubleToString(g_rangeLow, _Digits));

         PlaceConfirmedGrid();
      }
   }
   else if(sellBreak)
   {
      g_sellSignal++;
      g_buySignal = 0;

      Print("SELL signal +1 => ", g_sellSignal,
            " | bar=", TimeToString(thaiBarTime, TIME_DATE|TIME_MINUTES),
            " O=", DoubleToString(bar[0].open, _Digits),
            " C=", DoubleToString(bar[0].close, _Digits));

      if(g_sellSignal >= 2 && g_confirmedDirection == DIR_NONE)
      {
         g_sellSignal           = 2;
         g_confirmedDirection   = DIR_SELL;
         g_confirmClose         = NormalizePrice(bar[0].close);

         Print("SELL CONFIRMED. Confirm close=",
               DoubleToString(g_confirmClose, _Digits),
               " zone high=", DoubleToString(g_rangeHigh, _Digits));

         PlaceConfirmedGrid();
      }
   }
}

bool IsNewM1Bar()
{
   datetime t = iTime(_Symbol, PERIOD_M1, 0);
   if(t <= 0)
      return false;

   if(g_lastM1Bar == 0)
   {
      g_lastM1Bar = t;
      return false;
   }

   if(t != g_lastM1Bar)
   {
      g_lastM1Bar = t;
      return true;
   }

   return false;
}

//----------------------------- Panel ---------------------------------//
#define PANEL_BG_NAME  "TH2031_PANEL_BG"
#define PANEL_PREFIX   "TH2031_PANEL_"
#define PANEL_ROWS     26

string PanelRowName(int row)
{
   return PANEL_PREFIX + IntegerToString(row);
}

int CountOwnPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && IsOwnPositionByTicket(ticket))
         count++;
   }
   return count;
}

int CountOwnPendingOrders()
{
   int count = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket > 0 && IsOwnOrderByTicket(ticket))
         count++;
   }
   return count;
}

double OwnPositionLots()
{
   double lots = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !IsOwnPositionByTicket(ticket))
         continue;
      lots += PositionGetDouble(POSITION_VOLUME);
   }
   return lots;
}

double OwnPendingLots()
{
   double lots = 0.0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || !IsOwnOrderByTicket(ticket))
         continue;
      lots += OrderGetDouble(ORDER_VOLUME_CURRENT);
   }
   return lots;
}

string DirectionText()
{
   if(g_confirmedDirection == DIR_BUY)  return "BUY";
   if(g_confirmedDirection == DIR_SELL) return "SELL";
   return "NONE";
}

string TPModeText()
{
   if(!InpEnableTakeProfit)
      return "OFF";
   if(InpTakeProfitMode == TP_MODE_RANGE)
      return "RANGE";
   return "BALANCE_ADAPTIVE";
}

string SessionText()
{
   if(g_sessionExpired)
      return "EXPIRED";
   if(g_confirmedDirection != DIR_NONE)
      return "CONFIRMED";
   return "WAIT SIGNAL";
}

string SecondsToClock(long seconds)
{
   if(seconds < 0) seconds = 0;
   int hh = (int)(seconds / 3600);
   int mm = (int)((seconds % 3600) / 60);
   int ss = (int)(seconds % 60);
   return StringFormat("%02d:%02d:%02d", hh, mm, ss);
}

void DeletePanel()
{
   ObjectDelete(0, PANEL_BG_NAME);
   for(int i = 0; i < PANEL_ROWS; i++)
      ObjectDelete(0, PanelRowName(i));
}

void CreatePanel()
{
   if(!InpShowPanel)
   {
      DeletePanel();
      return;
   }

   if(ObjectFind(0, PANEL_BG_NAME) < 0)
   {
      ObjectCreate(0, PANEL_BG_NAME, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, PANEL_BG_NAME, OBJPROP_CORNER, InpPanelCorner);
      ObjectSetInteger(0, PANEL_BG_NAME, OBJPROP_XDISTANCE, InpPanelX);
      ObjectSetInteger(0, PANEL_BG_NAME, OBJPROP_YDISTANCE, InpPanelY);
      ObjectSetInteger(0, PANEL_BG_NAME, OBJPROP_XSIZE, 300);
      ObjectSetInteger(0, PANEL_BG_NAME, OBJPROP_YSIZE, 520);
      ObjectSetInteger(0, PANEL_BG_NAME, OBJPROP_BGCOLOR, clrBlack);
      ObjectSetInteger(0, PANEL_BG_NAME, OBJPROP_COLOR, clrDimGray);
      ObjectSetInteger(0, PANEL_BG_NAME, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, PANEL_BG_NAME, OBJPROP_BACK, false);
      ObjectSetInteger(0, PANEL_BG_NAME, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, PANEL_BG_NAME, OBJPROP_HIDDEN, true);
   }

   for(int i = 0; i < PANEL_ROWS; i++)
   {
      string name = PanelRowName(i);
      if(ObjectFind(0, name) >= 0)
         continue;

      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, InpPanelCorner);
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE, InpPanelX + 12);
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE, InpPanelY + 10 + i * 19);
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE, InpPanelFontSize);
      ObjectSetString(0, name, OBJPROP_FONT, "Consolas");
      ObjectSetInteger(0, name, OBJPROP_COLOR, clrWhite);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   }
}

void SetPanelRow(int row, string text, color clr=clrWhite)
{
   if(row < 0 || row >= PANEL_ROWS)
      return;

   string name = PanelRowName(row);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
}

void ShowStatus()
{
   if(!InpShowPanel)
   {
      DeletePanel();
      return;
   }

   CreatePanel();

   datetime thaiNow = ServerToThai(TimeTradeServer());
   double rangeSize = (g_rangeReady ? g_rangeHigh - g_rangeLow : 0.0);
   double rangeTarget = RangeTPPrice();
   double cyclePct = 0.0;
   if(g_cycleActive && g_cycleBaseBalance > 0.0)
      cyclePct = CycleProfitPercent();

   double cycleMoney = 0.0;
   if(g_cycleActive && g_cycleBaseBalance > 0.0)
      cycleMoney = CycleProfitMoney();

   int posCount = CountOwnPositions();
   int ordCount = CountOwnPendingOrders();
   double posLots = OwnPositionLots();
   double ordLots = OwnPendingLots();

   color sessionColor = clrWhite;
   if(g_sessionExpired) sessionColor = clrTomato;
   else if(g_confirmedDirection != DIR_NONE) sessionColor = clrLime;

   color dirColor = clrSilver;
   if(g_confirmedDirection == DIR_BUY)  dirColor = clrLime;
   if(g_confirmedDirection == DIR_SELL) dirColor = clrTomato;

   SetPanelRow(0,  "THAI 20:31 BREAKOUT GRID", clrGold);
   SetPanelRow(1,  "Thai Time      : " + TimeToString(thaiNow, TIME_DATE|TIME_SECONDS));
   SetPanelRow(2,  "Session        : " + SessionText(), sessionColor);
   SetPanelRow(3,  "Range Ready    : " + (g_rangeReady ? "YES" : "NO"));
   SetPanelRow(4,  "Range High     : " + (g_rangeReady ? DoubleToString(g_rangeHigh, _Digits) : "-"));
   SetPanelRow(5,  "Range Low      : " + (g_rangeReady ? DoubleToString(g_rangeLow, _Digits) : "-"));
   SetPanelRow(6,  "Range Size     : " + (g_rangeReady ? DoubleToString(rangeSize, _Digits) : "-"));
   SetPanelRow(7,  "BUY / SELL Sig : " + IntegerToString(g_buySignal) + " / " + IntegerToString(g_sellSignal));
   SetPanelRow(8,  "Confirmed      : " + DirectionText(), dirColor);
   SetPanelRow(9,  "Confirm Close  : " + (g_confirmClose > 0.0 ? DoubleToString(g_confirmClose, _Digits) : "-"));
   SetPanelRow(10, "TP Mode        : " + TPModeText());
   SetPanelRow(11, "Range TP       : " + (rangeTarget > 0.0 ? DoubleToString(rangeTarget, _Digits) : "-"));
   SetPanelRow(12, "Cycle Active   : " + (g_cycleActive ? "YES" : "NO"));
   SetPanelRow(13, "Positions      : " + IntegerToString(posCount) + " | Lots " + DoubleToString(posLots, 2));
   SetPanelRow(14, "Pending Orders : " + IntegerToString(ordCount) + " | Lots " + DoubleToString(ordLots, 2));
   SetPanelRow(15, "Cycle P/L      : " + DoubleToString(cycleMoney, 2));
   SetPanelRow(16, "Cycle P/L %    : " + DoubleToString(cyclePct, 2) + "%");
   SetPanelRow(17, "Base Balance   : " + (g_cycleBaseBalance > 0.0 ? DoubleToString(g_cycleBaseBalance, 2) : "-"));

   datetime deadline = ConfirmationDeadlineThai();
   long leftSeconds = (long)(deadline - thaiNow);
   string deadlineText = "-";
   string leftText = "-";
   if(InpConfirmTimeoutMinutes > 0 && g_confirmedDirection == DIR_NONE && !g_sessionExpired)
   {
      deadlineText = TimeToString(deadline, TIME_MINUTES|TIME_SECONDS);
      leftText = SecondsToClock(leftSeconds);
   }

   SetPanelRow(18, "Confirm Until  : " + deadlineText);
   SetPanelRow(19, "Confirm Left   : " + leftText);

   string tpDetail = "-";
   if(InpEnableTakeProfit && InpTakeProfitMode == TP_MODE_RANGE)
      tpDetail = "Range x " + DoubleToString(InpRangeTPMultiplier, 2);
   else if(InpEnableTakeProfit && InpTakeProfitMode == TP_MODE_BALANCE_ADAPTIVE)
      tpDetail = DoubleToString(InpTPStartPercent, 1) + "% + step " + DoubleToString(InpTPStepPercent, 1) + "%";
   SetPanelRow(20, "TP Detail      : " + tpDetail);

   double protectTrigger = HalfRangeProtectionTriggerPrice();
   string protectStatus = "OFF";
   color protectColor = clrSilver;
   if(InpEnableHalfRangeSLProtect)
   {
      protectStatus = g_halfRangeSLProtected ? "PROTECTED" : "WAIT";
      protectColor = g_halfRangeSLProtected ? clrLime : clrWhite;
   }
   SetPanelRow(21, "SL Protect     : " + protectStatus, protectColor);
   SetPanelRow(22, "SL Trigger     : " + (protectTrigger > 0.0 ? DoubleToString(protectTrigger, _Digits) : "-"));
   SetPanelRow(23, "Front Entry SL : " + (g_frontEntryPrice > 0.0 ? DoubleToString(g_frontEntryPrice, _Digits) : "-"));

   string sidewayText = "OFF";
   color sidewayColor = clrSilver;
   if(InpEnableSidewayFilter)
   {
      double panelADX = 0.0;
      if(ReadADXValue(1, panelADX))
      {
         g_lastADXValue = panelADX;
         g_lastADXValid = true;
         g_lastSideway  = (panelADX < InpADXTrendThreshold);
         sidewayText    = g_lastSideway ? "SIDEWAY - BLOCK" : "TREND - ALLOW";
         sidewayColor   = g_lastSideway ? clrTomato : clrLime;
      }
      else
      {
         g_lastADXValid = false;
         sidewayText    = "ADX N/A - BLOCK";
         sidewayColor   = clrTomato;
      }
   }

   string adxValueText = "-";
   if(InpEnableSidewayFilter && g_lastADXValid)
      adxValueText = DoubleToString(g_lastADXValue, 2) + " / Min " + DoubleToString(InpADXTrendThreshold, 2);

   SetPanelRow(24, "Sideway Filter : " + sidewayText, sidewayColor);
   SetPanelRow(25, "ADX Value      : " + adxValueText);

   ChartRedraw(0);
}

//----------------------------- Events --------------------------------//
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   if(InpEnableSidewayFilter)
   {
      if(InpADXPeriod <= 0 || InpADXTrendThreshold < 0.0)
      {
         Print("Invalid ADX sideway filter inputs");
         return INIT_PARAMETERS_INCORRECT;
      }

      g_adxHandle = iADX(_Symbol, InpADXTimeframe, InpADXPeriod);
      if(g_adxHandle == INVALID_HANDLE)
      {
         Print("Failed to create ADX handle. error=", GetLastError());
         return INIT_FAILED;
      }
   }

   g_thaiDateKey = DateKey(ServerToThai(TimeTradeServer()));
   g_lastM1Bar   = iTime(_Symbol, PERIOD_M1, 0);

   ResetTPStats();
   CreatePanel();

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(g_adxHandle != INVALID_HANDLE)
   {
      IndicatorRelease(g_adxHandle);
      g_adxHandle = INVALID_HANDLE;
   }

   DeletePanel();
   Comment("");
}

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   ManageFrontEntrySLExit(trans);
}

void OnTick()
{
   CheckThaiDayChange();

   if(IsNewM1Bar())
      ProcessClosedM1Bar();

   // Run after ProcessClosedM1Bar so the last eligible candle (21:30
   // with a 60-minute window) can still confirm when 21:31 begins.
   CheckConfirmationTimeout();

   ManageHalfRangeSLProtection();
   ManageRangeBasketTP();
   ManageAdaptiveBasketTP();

   if(g_cycleActive && !HasOwnPositions() && !HasOwnOrders())
      g_cycleActive = false;

   ShowStatus();
}
//+------------------------------------------------------------------+
