//+------------------------------------------------------------------+
//|                            XAU_Research_TrendBreakout_EA.mq5     |
//| H4 momentum + M15 breakout + ATR risk and trailing exit          |
//+------------------------------------------------------------------+
#property strict
#property version "1.00"

#include <Trade/Trade.mqh>
CTrade trade;

input group "Signal"
input ENUM_TIMEFRAMES InpSignalTF = PERIOD_M15;
input ENUM_TIMEFRAMES InpTrendTF = PERIOD_H4;
input int InpTrendLookback = 20;
input int InpTrendEMA = 50;
input int InpEntryChannel = 20;
input int InpExitChannel = 10;
input bool InpUseADX = true;
input int InpADXPeriod = 14;
input double InpMinADX = 20.0;

input group "Volatility and exits"
input int InpATRPeriod = 14;
input double InpInitialStopATR = 2.0;
input double InpTrailingATR = 3.0;
input bool InpUseChannelExit = true;

input group "Position sizing"
input bool InpUseRiskSizing = true;
input double InpRiskPercent = 0.25;
input double InpFixedLot = 0.01;
input int InpMaxSpreadPoints = 0;
input int InpDeviationPoints = 20;
input ulong InpMagic = 260916;

input group "Safety"
input int InpMaxTradesPerDay = 3;
input double InpMaxDailyLossPercent = 1.0;
input bool InpCloseBeforeWeekend = true;
input int InpFridayCloseHour = 20;

int hTrendEMA = INVALID_HANDLE;
int hATR = INVALID_HANDLE;
int hADX = INVALID_HANDLE;
datetime lastSignalBar = 0;

//+------------------------------------------------------------------+
bool ReadBufferValue(const int handle, const int buffer, const int shift, double &value)
{
   double data[1];
   if(handle == INVALID_HANDLE || CopyBuffer(handle, buffer, shift, 1, data) != 1)
      return false;
   value = data[0];
   return true;
}

//+------------------------------------------------------------------+
bool IsNewSignalBar()
{
   const datetime time = iTime(_Symbol, InpSignalTF, 0);
   if(time == 0 || time == lastSignalBar)
      return false;
   lastSignalBar = time;
   return true;
}

//+------------------------------------------------------------------+
bool SelectOurPosition(ulong &ticket, ENUM_POSITION_TYPE &type,
                       double &openPrice, double &stopLoss)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong current = PositionGetTicket(i);
      if(current == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         (ulong)PositionGetInteger(POSITION_MAGIC) == InpMagic)
      {
         ticket = current;
         type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         stopLoss = PositionGetDouble(POSITION_SL);
         return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
datetime DayStart()
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
   if(!HistorySelect(DayStart(), TimeCurrent()))
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
         pnl += HistoryDealGetDouble(deal, DEAL_SWAP);
         pnl += HistoryDealGetDouble(deal, DEAL_COMMISSION);
      }
   }

   if(InpMaxTradesPerDay > 0 && entries >= InpMaxTradesPerDay)
      return false;
   if(InpMaxDailyLossPercent > 0.0)
   {
      const double dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE) - pnl;
      if(pnl <= -(dayStartBalance * InpMaxDailyLossPercent / 100.0))
         return false;
   }
   return true;
}

//+------------------------------------------------------------------+
bool IsFridayCutoff()
{
   if(!InpCloseBeforeWeekend)
      return false;
   MqlDateTime now;
   TimeToStruct(TimeCurrent(), now);
   return now.day_of_week == 5 && now.hour >= InpFridayCloseHour;
}

//+------------------------------------------------------------------+
double HighestHigh(const MqlRates &bars[], const int first, const int count)
{
   double value = bars[first].high;
   for(int i = first + 1; i < first + count; i++)
      value = MathMax(value, bars[i].high);
   return value;
}

//+------------------------------------------------------------------+
double LowestLow(const MqlRates &bars[], const int first, const int count)
{
   double value = bars[first].low;
   for(int i = first + 1; i < first + count; i++)
      value = MathMin(value, bars[i].low);
   return value;
}

//+------------------------------------------------------------------+
// Uses only completed H4 bars. 1=up, -1=down, 0=no trend.
int TrendDirection()
{
   const double closeNow = iClose(_Symbol, InpTrendTF, 1);
   const double closePast = iClose(_Symbol, InpTrendTF, InpTrendLookback + 1);
   double emaNow, emaPast;
   if(closeNow == 0.0 || closePast == 0.0 ||
      !ReadBufferValue(hTrendEMA, 0, 1, emaNow) ||
      !ReadBufferValue(hTrendEMA, 0, 2, emaPast))
      return 0;

   if(closeNow > closePast && closeNow > emaNow && emaNow > emaPast)
      return 1;
   if(closeNow < closePast && closeNow < emaNow && emaNow < emaPast)
      return -1;
   return 0;
}

//+------------------------------------------------------------------+
bool ADXAllows(const int direction)
{
   if(!InpUseADX)
      return true;
   double adx, plusDI, minusDI;
   if(!ReadBufferValue(hADX, 0, 1, adx) ||
      !ReadBufferValue(hADX, 1, 1, plusDI) ||
      !ReadBufferValue(hADX, 2, 1, minusDI))
      return false;
   if(adx < InpMinADX)
      return false;
   return direction == 1 ? plusDI > minusDI : minusDI > plusDI;
}

//+------------------------------------------------------------------+
double NormalizeVolumeDown(double volume)
{
   const double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   const double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   const double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(volume < minLot)
      return 0.0;
   volume = MathMin(volume, maxLot);
   if(step > 0.0)
      volume = MathFloor(volume / step + 1e-9) * step;
   return NormalizeDouble(volume, 8);
}

//+------------------------------------------------------------------+
double TradeVolume(const int direction, const double entry, const double stop)
{
   if(!InpUseRiskSizing)
      return NormalizeVolumeDown(InpFixedLot);

   double oneLotResult = 0.0;
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
void OpenBreakout(const int direction, const double atr)
{
   if(!DailyLimitsAllowEntry() || IsFridayCutoff())
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
   double stop = direction == 1 ? entry - InpInitialStopATR * atr
                                : entry + InpInitialStopATR * atr;
   const double brokerMinimum = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   if(direction == 1 && entry - stop < brokerMinimum) stop = entry - brokerMinimum;
   if(direction == -1 && stop - entry < brokerMinimum) stop = entry + brokerMinimum;
   stop = NormalizeDouble(stop, _Digits);

   const double volume = TradeVolume(direction, entry, stop);
   if(volume <= 0.0)
   {
      Print("Volume unavailable or below broker minimum");
      return;
   }

   bool sent = direction == 1
               ? trade.Buy(volume, _Symbol, 0.0, stop, 0.0, "H4 MOM M15 BO BUY")
               : trade.Sell(volume, _Symbol, 0.0, stop, 0.0, "H4 MOM M15 BO SELL");
   if(!sent)
      Print("Entry failed: ", trade.ResultRetcodeDescription());
}

//+------------------------------------------------------------------+
void ManagePosition(const MqlRates &bars[], const double atr)
{
   ulong ticket;
   ENUM_POSITION_TYPE type;
   double openPrice, currentStop;
   if(!SelectOurPosition(ticket, type, openPrice, currentStop))
      return;

   if(IsFridayCutoff())
   {
      trade.PositionClose(ticket);
      return;
   }

   bool channelExit = false;
   if(InpUseChannelExit)
   {
      if(type == POSITION_TYPE_BUY)
         channelExit = bars[1].close < LowestLow(bars, 2, InpExitChannel);
      else
         channelExit = bars[1].close > HighestHigh(bars, 2, InpExitChannel);
   }
   if(channelExit)
   {
      trade.PositionClose(ticket);
      return;
   }

   double newStop = type == POSITION_TYPE_BUY
                    ? bars[1].close - InpTrailingATR * atr
                    : bars[1].close + InpTrailingATR * atr;
   newStop = NormalizeDouble(newStop, _Digits);

   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   const double minDistance = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;

   if(type == POSITION_TYPE_BUY && newStop > currentStop && newStop < bid - minDistance)
      trade.PositionModify(ticket, newStop, 0.0);
   else if(type == POSITION_TYPE_SELL &&
           (currentStop == 0.0 || newStop < currentStop) && newStop > ask + minDistance)
      trade.PositionModify(ticket, newStop, 0.0);
}

//+------------------------------------------------------------------+
int OnInit()
{
   if(InpTrendLookback < 2 || InpTrendEMA < 2 || InpEntryChannel < 2 ||
      InpExitChannel < 2 || InpATRPeriod < 2 || InpInitialStopATR <= 0.0 ||
      InpTrailingATR <= 0.0 || InpRiskPercent <= 0.0 || InpRiskPercent > 1.0 ||
      InpFixedLot <= 0.0 || InpMaxDailyLossPercent < 0.0 ||
      InpMaxDailyLossPercent > 2.0 || InpFridayCloseHour < 0 || InpFridayCloseHour > 23)
      return INIT_PARAMETERS_INCORRECT;

   hTrendEMA = iMA(_Symbol, InpTrendTF, InpTrendEMA, 0, MODE_EMA, PRICE_CLOSE);
   hATR = iATR(_Symbol, InpSignalTF, InpATRPeriod);
   if(InpUseADX)
      hADX = iADX(_Symbol, InpSignalTF, InpADXPeriod);
   if(hTrendEMA == INVALID_HANDLE || hATR == INVALID_HANDLE ||
      (InpUseADX && hADX == INVALID_HANDLE))
      return INIT_FAILED;

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(_Symbol);
   lastSignalBar = iTime(_Symbol, InpSignalTF, 0);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(hTrendEMA != INVALID_HANDLE) IndicatorRelease(hTrendEMA);
   if(hATR != INVALID_HANDLE) IndicatorRelease(hATR);
   if(hADX != INVALID_HANDLE) IndicatorRelease(hADX);
}

//+------------------------------------------------------------------+
void OnTick()
{
   if(!IsNewSignalBar())
      return;

   const int needed = MathMax(InpEntryChannel, InpExitChannel) + 2;
   MqlRates bars[];
   ArraySetAsSeries(bars, true);
   if(CopyRates(_Symbol, InpSignalTF, 0, needed, bars) < needed)
      return;

   double atr;
   if(!ReadBufferValue(hATR, 0, 1, atr) || atr <= 0.0)
      return;

   ulong ticket;
   ENUM_POSITION_TYPE type;
   double openPrice, stop;
   if(SelectOurPosition(ticket, type, openPrice, stop))
   {
      ManagePosition(bars, atr);
      return;
   }

   const int direction = TrendDirection();
   if(direction == 0 || !ADXAllows(direction))
      return;

   const double priorHigh = HighestHigh(bars, 2, InpEntryChannel);
   const double priorLow = LowestLow(bars, 2, InpEntryChannel);
   const bool buyBreakout = direction == 1 && bars[1].close > priorHigh;
   const bool sellBreakout = direction == -1 && bars[1].close < priorLow;

   if(buyBreakout)
      OpenBreakout(1, atr);
   else if(sellBreakout)
      OpenBreakout(-1, atr);
}
//+------------------------------------------------------------------+
