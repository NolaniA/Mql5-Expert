//+------------------------------------------------------------------+
//|                                      EMA_MTF_Pullback_EA_v2.mq5 |
//| H4/H1 trend + M15 pullback + M5 confirmation + M1 EMA trigger   |
//+------------------------------------------------------------------+
#property strict
#property version "2.00"

#include <Trade/Trade.mqh>
CTrade trade;

input group "Trend: H1 and H4"
input int InpTrendFastEMA = 20;
input int InpTrendSlowEMA = 50;

input group "M15 pullback"
input int InpPullbackLookback = 8;
input int InpPullbackTolerancePoints = 300;

input group "M5 confirmation and swing"
input bool InpRequireM5Breakout = true;
input int  InpSwingBars = 10;
input int  InpSwingBufferPoints = 100;

input group "M1 entry trigger"
input int InpTriggerFastEMA = 5;
input int InpTriggerSlowEMA = 20;

input group "Risk and exit"
input bool   InpUseRiskPercent = true;
input double InpRiskPercent = 1.0;
input double InpFixedLot = 0.01;
input double InpRiskReward = 1.5;
input int    InpMaxSpreadPoints = 0;
input int    InpDeviationPoints = 20;
input ulong  InpMagicNumber = 260915;

input group "Trading session (broker server time)"
input bool InpUseSessionFilter = false;
input int  InpSessionStartHour = 7;
input int  InpSessionEndHour = 22;

int hH1Fast = INVALID_HANDLE;
int hH1Slow = INVALID_HANDLE;
int hH4Fast = INVALID_HANDLE;
int hH4Slow = INVALID_HANDLE;
int hM15Fast = INVALID_HANDLE;
int hM1Fast = INVALID_HANDLE;
int hM1Slow = INVALID_HANDLE;
datetime lastM1Bar = 0;

//+------------------------------------------------------------------+
bool ReadMA(const int handle, const int shift, double &value)
{
   double data[1];
   if(handle == INVALID_HANDLE || CopyBuffer(handle, 0, shift, 1, data) != 1)
      return false;
   value = data[0];
   return true;
}

//+------------------------------------------------------------------+
bool IsNewM1Bar()
{
   const datetime current = iTime(_Symbol, PERIOD_M1, 0);
   if(current == 0 || current == lastM1Bar)
      return false;
   lastM1Bar = current;
   return true;
}

//+------------------------------------------------------------------+
bool IsInsideSession()
{
   if(!InpUseSessionFilter || InpSessionStartHour == InpSessionEndHour)
      return true;

   MqlDateTime now;
   TimeToStruct(TimeCurrent(), now);
   if(InpSessionStartHour < InpSessionEndHour)
      return now.hour >= InpSessionStartHour && now.hour < InpSessionEndHour;
   return now.hour >= InpSessionStartHour || now.hour < InpSessionEndHour;
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
         (ulong)PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
// 1 = up, -1 = down, 0 = H1/H4 disagree or data not ready.
int GetMainTrend()
{
   double h1Fast, h1Slow, h4Fast, h4Slow;
   if(!ReadMA(hH1Fast, 1, h1Fast) || !ReadMA(hH1Slow, 1, h1Slow) ||
      !ReadMA(hH4Fast, 1, h4Fast) || !ReadMA(hH4Slow, 1, h4Slow))
      return 0;

   if(h1Fast > h1Slow && h4Fast > h4Slow)
      return 1;
   if(h1Fast < h1Slow && h4Fast < h4Slow)
      return -1;
   return 0;
}

//+------------------------------------------------------------------+
bool HasRecentM15Pullback(const int trend)
{
   MqlRates bars[];
   ArraySetAsSeries(bars, true);
   const int needed = MathMax(2, InpPullbackLookback + 1);
   if(CopyRates(_Symbol, PERIOD_M15, 0, needed, bars) < needed)
      return false;

   for(int shift = 1; shift <= InpPullbackLookback; shift++)
   {
      double ema;
      if(!ReadMA(hM15Fast, shift, ema))
         return false;

      const double tolerance = InpPullbackTolerancePoints * _Point;
      if(trend == 1 && bars[shift].low <= ema + tolerance && bars[shift].close >= ema)
         return true;
      if(trend == -1 && bars[shift].high >= ema - tolerance && bars[shift].close <= ema)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
bool HasM5Confirmation(const int trend)
{
   if(!InpRequireM5Breakout)
      return true;

   MqlRates bars[];
   ArraySetAsSeries(bars, true);
   if(CopyRates(_Symbol, PERIOD_M5, 0, 3, bars) < 3)
      return false;

   if(trend == 1)
      return bars[1].close > bars[1].open && bars[1].close > bars[2].high;
   return bars[1].close < bars[1].open && bars[1].close < bars[2].low;
}

//+------------------------------------------------------------------+
bool HasM1Trigger(const int trend)
{
   double fast1, fast2, slow1, slow2;
   if(!ReadMA(hM1Fast, 1, fast1) || !ReadMA(hM1Fast, 2, fast2) ||
      !ReadMA(hM1Slow, 1, slow1) || !ReadMA(hM1Slow, 2, slow2))
      return false;

   if(trend == 1)
      return fast2 <= slow2 && fast1 > slow1;
   return fast2 >= slow2 && fast1 < slow1;
}

//+------------------------------------------------------------------+
bool GetSwingStop(const int trend, const double entry, double &stopLoss)
{
   MqlRates bars[];
   ArraySetAsSeries(bars, true);
   if(CopyRates(_Symbol, PERIOD_M5, 1, InpSwingBars, bars) < InpSwingBars)
      return false;

   if(trend == 1)
   {
      double swingLow = bars[0].low;
      for(int i = 1; i < InpSwingBars; i++)
         swingLow = MathMin(swingLow, bars[i].low);
      stopLoss = swingLow - InpSwingBufferPoints * _Point;
   }
   else
   {
      double swingHigh = bars[0].high;
      for(int i = 1; i < InpSwingBars; i++)
         swingHigh = MathMax(swingHigh, bars[i].high);
      stopLoss = swingHigh + InpSwingBufferPoints * _Point;
   }

   const double minDistance = MathMax((double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL),
                                      (double)InpSwingBufferPoints) * _Point;
   if(trend == 1 && entry - stopLoss < minDistance)
      stopLoss = entry - minDistance;
   if(trend == -1 && stopLoss - entry < minDistance)
      stopLoss = entry + minDistance;

   stopLoss = NormalizeDouble(stopLoss, _Digits);
   return trend == 1 ? stopLoss < entry : stopLoss > entry;
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
      volume = MathFloor(volume / step + 1e-8) * step;
   return NormalizeDouble(volume, 8);
}

//+------------------------------------------------------------------+
double CalculateVolume(const int trend, const double entry, const double stopLoss)
{
   if(!InpUseRiskPercent)
      return NormalizeVolumeDown(InpFixedLot);

   const double riskMoney = AccountInfoDouble(ACCOUNT_BALANCE) * InpRiskPercent / 100.0;
   double profitAtOneLot = 0.0;
   const ENUM_ORDER_TYPE orderType = trend == 1 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   if(!OrderCalcProfit(orderType, _Symbol, 1.0, entry, stopLoss, profitAtOneLot))
      return 0.0;

   const double lossAtOneLot = MathAbs(profitAtOneLot);
   if(lossAtOneLot <= 0.0)
      return 0.0;
   return NormalizeVolumeDown(riskMoney / lossAtOneLot);
}

//+------------------------------------------------------------------+
void OpenTrade(const int trend)
{
   if(HasPosition())
      return;

   const double entry = trend == 1 ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                   : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double stopLoss;
   if(!GetSwingStop(trend, entry, stopLoss))
      return;

   const double riskDistance = MathAbs(entry - stopLoss);
   const double takeProfit = NormalizeDouble(
      trend == 1 ? entry + riskDistance * InpRiskReward
                 : entry - riskDistance * InpRiskReward, _Digits);
   const double volume = CalculateVolume(trend, entry, stopLoss);
   if(volume <= 0.0)
   {
      Print("Calculated volume is below the symbol minimum or unavailable");
      return;
   }

   bool result;
   if(trend == 1)
      result = trade.Buy(volume, _Symbol, 0.0, stopLoss, takeProfit, "MTF Pullback Buy");
   else
      result = trade.Sell(volume, _Symbol, 0.0, stopLoss, takeProfit, "MTF Pullback Sell");

   if(!result)
      Print("Order failed: ", trade.ResultRetcodeDescription());
}

//+------------------------------------------------------------------+
int OnInit()
{
   if(InpTrendFastEMA <= 0 || InpTrendSlowEMA <= InpTrendFastEMA ||
      InpTriggerFastEMA <= 0 || InpTriggerSlowEMA <= InpTriggerFastEMA ||
      InpPullbackLookback < 1 || InpSwingBars < 2 || InpRiskReward < 1.0 ||
      InpRiskPercent <= 0.0 || InpRiskPercent > 2.0 || InpFixedLot <= 0.0 ||
      InpSessionStartHour < 0 || InpSessionStartHour > 23 ||
      InpSessionEndHour < 0 || InpSessionEndHour > 23)
      return INIT_PARAMETERS_INCORRECT;

   hH1Fast = iMA(_Symbol, PERIOD_H1, InpTrendFastEMA, 0, MODE_EMA, PRICE_CLOSE);
   hH1Slow = iMA(_Symbol, PERIOD_H1, InpTrendSlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   hH4Fast = iMA(_Symbol, PERIOD_H4, InpTrendFastEMA, 0, MODE_EMA, PRICE_CLOSE);
   hH4Slow = iMA(_Symbol, PERIOD_H4, InpTrendSlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   hM15Fast = iMA(_Symbol, PERIOD_M15, InpTrendFastEMA, 0, MODE_EMA, PRICE_CLOSE);
   hM1Fast = iMA(_Symbol, PERIOD_M1, InpTriggerFastEMA, 0, MODE_EMA, PRICE_CLOSE);
   hM1Slow = iMA(_Symbol, PERIOD_M1, InpTriggerSlowEMA, 0, MODE_EMA, PRICE_CLOSE);

   if(hH1Fast == INVALID_HANDLE || hH1Slow == INVALID_HANDLE ||
      hH4Fast == INVALID_HANDLE || hH4Slow == INVALID_HANDLE ||
      hM15Fast == INVALID_HANDLE || hM1Fast == INVALID_HANDLE || hM1Slow == INVALID_HANDLE)
      return INIT_FAILED;

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(_Symbol);
   lastM1Bar = iTime(_Symbol, PERIOD_M1, 0);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   int handles[7] = {hH1Fast, hH1Slow, hH4Fast, hH4Slow, hM15Fast, hM1Fast, hM1Slow};
   for(int i = 0; i < 7; i++)
      if(handles[i] != INVALID_HANDLE)
         IndicatorRelease(handles[i]);
}

//+------------------------------------------------------------------+
void OnTick()
{
   if(!IsNewM1Bar() || HasPosition() || !IsInsideSession())
      return;

   if(InpMaxSpreadPoints > 0)
   {
      const double spread = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) -
                             SymbolInfoDouble(_Symbol, SYMBOL_BID)) / _Point;
      if(spread > InpMaxSpreadPoints)
         return;
   }

   const int trend = GetMainTrend();
   if(trend == 0)
      return;
   if(!HasRecentM15Pullback(trend))
      return;
   if(!HasM5Confirmation(trend))
      return;
   if(!HasM1Trigger(trend))
      return;

   OpenTrade(trend);
}
//+------------------------------------------------------------------+
