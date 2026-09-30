//+------------------------------------------------------------------+
//|                                      NeoWave_Monowave_EA.mq5     |
//| Objective, non-repainting NeoWave-inspired Wave-3 breakout EA    |
//+------------------------------------------------------------------+
#property strict
#property version "1.00"

#include <Trade/Trade.mqh>
CTrade trade;

struct PivotPoint
{
   datetime time;
   double price;
   int type;       // 1 = swing high, -1 = swing low
   int shift;
};

input group "Monowave construction"
input ENUM_TIMEFRAMES InpSignalTF = PERIOD_M15;
input int InpPivotStrength = 3;
input int InpScanBars = 300;
input int InpMinimumWaveBars = 3;
input int InpATRPeriod = 14;
input double InpMinimumWaveATR = 1.0;

input group "Wave-2 price/time rules"
input double InpMinRetracement = 0.382;
input double InpMaxRetracement = 0.786;
input double InpMinTimeRatio = 0.382;
input double InpMaxTimeRatio = 2.618;

input group "Wave-3 trade"
input double InpWave3Projection = 1.618;
input double InpMinimumRR = 1.5;
input double InpStopBufferATR = 0.25;
input bool InpUseH4TrendFilter = true;
input int InpH4EMA = 50;

input group "Risk"
input bool InpUseRiskSizing = true;
input double InpRiskPercent = 0.25;
input double InpFixedLot = 0.01;
input int InpMaxSpreadPoints = 0;
input int InpDeviationPoints = 20;
input ulong InpMagic = 260917;
input int InpMaxTradesPerDay = 3;
input double InpMaxDailyLossPercent = 1.0;

int hATR = INVALID_HANDLE;
int hH4EMA = INVALID_HANDLE;
datetime lastBarTime = 0;
datetime lastSetupPivotTime = 0;

//+------------------------------------------------------------------+
bool ReadIndicator(const int handle, const int shift, double &value)
{
   double buffer[1];
   if(handle == INVALID_HANDLE || CopyBuffer(handle, 0, shift, 1, buffer) != 1)
      return false;
   value = buffer[0];
   return true;
}

//+------------------------------------------------------------------+
bool IsNewBar()
{
   const datetime current = iTime(_Symbol, InpSignalTF, 0);
   if(current == 0 || current == lastBarTime)
      return false;
   lastBarTime = current;
   return true;
}

//+------------------------------------------------------------------+
bool HasPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         (ulong)PositionGetInteger(POSITION_MAGIC) == InpMagic)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
bool IsPivotHigh(const MqlRates &bars[], const int shift)
{
   const double value = bars[shift].high;
   for(int j = 1; j <= InpPivotStrength; j++)
      if(value <= bars[shift-j].high || value < bars[shift+j].high)
         return false;
   return true;
}

//+------------------------------------------------------------------+
bool IsPivotLow(const MqlRates &bars[], const int shift)
{
   const double value = bars[shift].low;
   for(int j = 1; j <= InpPivotStrength; j++)
      if(value >= bars[shift-j].low || value > bars[shift+j].low)
         return false;
   return true;
}

//+------------------------------------------------------------------+
void AddAlternatingPivot(PivotPoint &pivots[], const PivotPoint &candidate)
{
   const int count = ArraySize(pivots);
   if(count == 0)
   {
      ArrayResize(pivots, 1);
      pivots[0] = candidate;
      return;
   }

   if(pivots[count-1].type == candidate.type)
   {
      const bool moreExtreme = candidate.type == 1
                               ? candidate.price > pivots[count-1].price
                               : candidate.price < pivots[count-1].price;
      if(moreExtreme)
         pivots[count-1] = candidate;
      return;
   }

   ArrayResize(pivots, count + 1);
   pivots[count] = candidate;
}

//+------------------------------------------------------------------+
bool BuildMonowaves(const MqlRates &bars[], PivotPoint &pivots[])
{
   ArrayResize(pivots, 0);
   const int total = ArraySize(bars);

   // Oldest to newest. A pivot is accepted only after right-side bars close.
   for(int shift = total - InpPivotStrength - 1; shift >= InpPivotStrength + 1; shift--)
   {
      const bool high = IsPivotHigh(bars, shift);
      const bool low = IsPivotLow(bars, shift);
      if(!high && !low)
         continue;

      PivotPoint candidate;
      candidate.time = bars[shift].time;
      candidate.shift = shift;

      if(high && low)
      {
         const int count = ArraySize(pivots);
         candidate.type = count == 0 ? 1 : -pivots[count-1].type;
      }
      else
         candidate.type = high ? 1 : -1;

      candidate.price = candidate.type == 1 ? bars[shift].high : bars[shift].low;
      AddAlternatingPivot(pivots, candidate);
   }
   return ArraySize(pivots) >= 3;
}

//+------------------------------------------------------------------+
bool H4TrendAllows(const int direction)
{
   if(!InpUseH4TrendFilter)
      return true;
   double ema1, ema2;
   if(!ReadIndicator(hH4EMA, 1, ema1) || !ReadIndicator(hH4EMA, 2, ema2))
      return false;
   const double close1 = iClose(_Symbol, PERIOD_H4, 1);
   if(direction == 1)
      return close1 > ema1 && ema1 > ema2;
   return close1 < ema1 && ema1 < ema2;
}

//+------------------------------------------------------------------+
datetime GetDayStart()
{
   MqlDateTime day;
   TimeToStruct(TimeCurrent(), day);
   day.hour = 0;
   day.min = 0;
   day.sec = 0;
   return StructToTime(day);
}

//+------------------------------------------------------------------+
bool DailyLimitsAllowEntry()
{
   if(!HistorySelect(GetDayStart(), TimeCurrent()))
      return false;
   int entries = 0;
   double pnl = 0.0;
   for(int i = 0; i < HistoryDealsTotal(); i++)
   {
      const ulong deal = HistoryDealGetTicket(i);
      if(deal == 0 || HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol ||
         (ulong)HistoryDealGetInteger(deal, DEAL_MAGIC) != InpMagic)
         continue;
      const ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal, DEAL_ENTRY);
      if(entry == DEAL_ENTRY_IN || entry == DEAL_ENTRY_INOUT)
         entries++;
      if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY || entry == DEAL_ENTRY_INOUT)
      {
         pnl += HistoryDealGetDouble(deal, DEAL_PROFIT);
         pnl += HistoryDealGetDouble(deal, DEAL_COMMISSION);
         pnl += HistoryDealGetDouble(deal, DEAL_SWAP);
      }
   }

   if(InpMaxTradesPerDay > 0 && entries >= InpMaxTradesPerDay)
      return false;
   if(InpMaxDailyLossPercent > 0.0)
   {
      const double startBalance = AccountInfoDouble(ACCOUNT_BALANCE) - pnl;
      if(pnl <= -(startBalance * InpMaxDailyLossPercent / 100.0))
         return false;
   }
   return true;
}

//+------------------------------------------------------------------+
double NormalizeVolumeDown(double volume)
{
   const double minimum = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   const double maximum = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   const double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(volume < minimum)
      return 0.0;
   volume = MathMin(volume, maximum);
   if(step > 0.0)
      volume = MathFloor(volume / step + 1e-9) * step;
   return NormalizeDouble(volume, 8);
}

//+------------------------------------------------------------------+
double CalculateVolume(const int direction, const double entry, const double stop)
{
   if(!InpUseRiskSizing)
      return NormalizeVolumeDown(InpFixedLot);
   double oneLotResult;
   const ENUM_ORDER_TYPE type = direction == 1 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   if(!OrderCalcProfit(type, _Symbol, 1.0, entry, stop, oneLotResult))
      return 0.0;
   const double oneLotLoss = MathAbs(oneLotResult);
   if(oneLotLoss <= 0.0)
      return 0.0;
   const double riskMoney = AccountInfoDouble(ACCOUNT_EQUITY) * InpRiskPercent / 100.0;
   return NormalizeVolumeDown(riskMoney / oneLotLoss);
}

//+------------------------------------------------------------------+
bool ValidateWave12(const PivotPoint &p0, const PivotPoint &p1,
                    const PivotPoint &p2, const int direction,
                    const double atr, double &wave1Length)
{
   if(direction == 1)
   {
      if(p0.type != -1 || p1.type != 1 || p2.type != -1 || p2.price <= p0.price)
         return false;
      wave1Length = p1.price - p0.price;
   }
   else
   {
      if(p0.type != 1 || p1.type != -1 || p2.type != 1 || p2.price >= p0.price)
         return false;
      wave1Length = p0.price - p1.price;
   }

   if(wave1Length < InpMinimumWaveATR * atr)
      return false;

   const double correction = direction == 1 ? p1.price - p2.price
                                            : p2.price - p1.price;
   const double retracement = correction / wave1Length;
   if(retracement < InpMinRetracement || retracement > InpMaxRetracement)
      return false;

   const long wave1Seconds = (long)(p1.time - p0.time);
   const long wave2Seconds = (long)(p2.time - p1.time);
   if(wave1Seconds <= 0 || wave2Seconds <= 0)
      return false;
   const double timeRatio = (double)wave2Seconds / (double)wave1Seconds;
   if(timeRatio < InpMinTimeRatio || timeRatio > InpMaxTimeRatio)
      return false;

   const int secondsPerBar = PeriodSeconds(InpSignalTF);
   if(secondsPerBar <= 0 || wave1Seconds / secondsPerBar < InpMinimumWaveBars ||
      wave2Seconds / secondsPerBar < InpMinimumWaveBars)
      return false;
   return true;
}

//+------------------------------------------------------------------+
void TryWave3Entry(const MqlRates &bars[], const PivotPoint &p0,
                   const PivotPoint &p1, const PivotPoint &p2,
                   const int direction, const double atr)
{
   if(p2.time == lastSetupPivotTime || !H4TrendAllows(direction) ||
      !DailyLimitsAllowEntry())
      return;

   double wave1Length;
   if(!ValidateWave12(p0, p1, p2, direction, atr, wave1Length))
      return;

   const bool breakout = direction == 1
                         ? bars[2].close <= p1.price && bars[1].close > p1.price
                         : bars[2].close >= p1.price && bars[1].close < p1.price;
   if(!breakout)
      return;

   if(InpMaxSpreadPoints > 0)
   {
      const double spread = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) -
                             SymbolInfoDouble(_Symbol, SYMBOL_BID)) / _Point;
      if(spread > InpMaxSpreadPoints)
         return;
   }

   const double entry = direction == 1 ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                       : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double stop = direction == 1 ? p2.price - InpStopBufferATR * atr
                                : p2.price + InpStopBufferATR * atr;
   const double risk = MathAbs(entry - stop);
   if(risk <= 0.0)
      return;

   double target = direction == 1 ? p2.price + InpWave3Projection * wave1Length
                                  : p2.price - InpWave3Projection * wave1Length;
   const double reward = direction == 1 ? target - entry : entry - target;
   if(reward <= 0.0 || reward / risk < InpMinimumRR)
      return;

   const double minStop = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   if(direction == 1 && entry - stop < minStop) stop = entry - minStop;
   if(direction == -1 && stop - entry < minStop) stop = entry + minStop;
   stop = NormalizeDouble(stop, _Digits);
   target = NormalizeDouble(target, _Digits);

   const double volume = CalculateVolume(direction, entry, stop);
   if(volume <= 0.0)
      return;

   const bool sent = direction == 1
                     ? trade.Buy(volume, _Symbol, 0.0, stop, target, "NeoWave W3 Buy")
                     : trade.Sell(volume, _Symbol, 0.0, stop, target, "NeoWave W3 Sell");
   if(sent)
      lastSetupPivotTime = p2.time;
   else
      Print("Order failed: ", trade.ResultRetcodeDescription());
}

//+------------------------------------------------------------------+
int OnInit()
{
   if(InpPivotStrength < 1 || InpScanBars < 50 || InpMinimumWaveBars < 1 ||
      InpATRPeriod < 2 || InpMinRetracement <= 0.0 ||
      InpMaxRetracement <= InpMinRetracement || InpMinTimeRatio <= 0.0 ||
      InpMaxTimeRatio <= InpMinTimeRatio || InpWave3Projection <= 1.0 ||
      InpMinimumRR < 1.0 || InpRiskPercent <= 0.0 || InpRiskPercent > 1.0 ||
      InpFixedLot <= 0.0 || InpMaxDailyLossPercent < 0.0 ||
      InpMaxDailyLossPercent > 2.0)
      return INIT_PARAMETERS_INCORRECT;

   hATR = iATR(_Symbol, InpSignalTF, InpATRPeriod);
   if(InpUseH4TrendFilter)
      hH4EMA = iMA(_Symbol, PERIOD_H4, InpH4EMA, 0, MODE_EMA, PRICE_CLOSE);
   if(hATR == INVALID_HANDLE || (InpUseH4TrendFilter && hH4EMA == INVALID_HANDLE))
      return INIT_FAILED;

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(_Symbol);
   lastBarTime = iTime(_Symbol, InpSignalTF, 0);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(hATR != INVALID_HANDLE) IndicatorRelease(hATR);
   if(hH4EMA != INVALID_HANDLE) IndicatorRelease(hH4EMA);
}

//+------------------------------------------------------------------+
void OnTick()
{
   if(!IsNewBar() || HasPosition())
      return;

   const int needed = MathMax(InpScanBars, InpPivotStrength * 2 + 20);
   MqlRates bars[];
   ArraySetAsSeries(bars, true);
   if(CopyRates(_Symbol, InpSignalTF, 0, needed, bars) < needed)
      return;

   double atr;
   if(!ReadIndicator(hATR, 1, atr) || atr <= 0.0)
      return;

   PivotPoint pivots[];
   if(!BuildMonowaves(bars, pivots))
      return;

   const int count = ArraySize(pivots);
   PivotPoint p0, p1, p2;
   p0 = pivots[count-3];
   p1 = pivots[count-2];
   p2 = pivots[count-1];

   if(p0.type == -1 && p1.type == 1 && p2.type == -1)
      TryWave3Entry(bars, p0, p1, p2, 1, atr);
   else if(p0.type == 1 && p1.type == -1 && p2.type == 1)
      TryWave3Entry(bars, p0, p1, p2, -1, atr);
}
//+------------------------------------------------------------------+
