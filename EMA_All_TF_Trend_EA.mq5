//+------------------------------------------------------------------+
//|                                         EMA_All_TF_Trend_EA.mq5 |
//| Trade only when every enabled timeframe confirms the same trend |
//+------------------------------------------------------------------+
#property strict
#property version "1.00"

#include <Trade/Trade.mqh>

CTrade trade;

input group "EMA trend"
input int  InpFastEmaPeriod    = 20;
input int  InpSlowEmaPeriod    = 50;
input bool InpRequireEmaSlope  = true;

input group "Timeframes used for confirmation"
input bool InpUseM1  = true;
input bool InpUseM5  = true;
input bool InpUseM15 = true;
input bool InpUseM30 = true;
input bool InpUseH1  = true;
input bool InpUseH4  = true;
input bool InpUseD1  = true;
input bool InpUseW1  = false;
input bool InpUseMN1 = false;

input group "Order settings"
input double InpLotSize          = 0.01;
input int    InpStopLossPoints   = 3000;
input int    InpTakeProfitPoints = 4500;
input int    InpMaxSpreadPoints  = 100;
input int    InpDeviationPoints  = 20;
input ulong  InpMagicNumber      = 260914;
input bool   InpOneTradePerTrend = true;
input bool   InpCloseOnTrendFlip = true;

input group "Trading session (broker server time)"
input bool InpUseSessionFilter = false;
input int  InpSessionStartHour = 7;
input int  InpSessionEndHour   = 22;

#define TF_COUNT 9

ENUM_TIMEFRAMES timeframes[TF_COUNT] =
{
   PERIOD_M1, PERIOD_M5, PERIOD_M15, PERIOD_M30, PERIOD_H1,
   PERIOD_H4, PERIOD_D1, PERIOD_W1, PERIOD_MN1
};

string timeframeNames[TF_COUNT] =
{
   "M1", "M5", "M15", "M30", "H1", "H4", "D1", "W1", "MN1"
};

bool enabledTF[TF_COUNT];
int fastHandles[TF_COUNT];
int slowHandles[TF_COUNT];

datetime lastBarTime = 0;
int lastConfirmedTrend = 0; // 1 = up, -1 = down, 0 = mixed

//+------------------------------------------------------------------+
double NormalizeVolume(double volume)
{
   const double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   const double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   const double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   volume = MathMax(minLot, MathMin(maxLot, volume));
   if(lotStep > 0.0)
      volume = MathFloor(volume / lotStep + 1e-8) * lotStep;

   return NormalizeDouble(volume, 8);
}

//+------------------------------------------------------------------+
bool IsNewBar()
{
   const datetime barTime = iTime(_Symbol, _Period, 0);
   if(barTime == 0 || barTime == lastBarTime)
      return false;

   lastBarTime = barTime;
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
bool HasPosition(const ENUM_POSITION_TYPE type)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         (ulong)PositionGetInteger(POSITION_MAGIC) == InpMagicNumber &&
         (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == type)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
bool HasAnyPosition()
{
   return HasPosition(POSITION_TYPE_BUY) || HasPosition(POSITION_TYPE_SELL);
}

//+------------------------------------------------------------------+
bool ClosePositions(const ENUM_POSITION_TYPE type)
{
   bool success = true;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol ||
         (ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber ||
         (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != type)
         continue;

      if(!trade.PositionClose(ticket))
      {
         Print("Close failed #", ticket, ": ", trade.ResultRetcodeDescription());
         success = false;
      }
   }
   return success;
}

//+------------------------------------------------------------------+
// Returns 1 for uptrend, -1 for downtrend, 0 for mixed/not ready.
int GetConfirmedTrend()
{
   int enabledCount = 0;
   bool allUp = true;
   bool allDown = true;

   for(int i = 0; i < TF_COUNT; i++)
   {
      if(!enabledTF[i])
         continue;

      enabledCount++;
      double fastClosed[1], fastPrevious[1];
      double slowClosed[1], slowPrevious[1];

      // Closed candles only: shift 1 and shift 2.
      if(CopyBuffer(fastHandles[i], 0, 1, 1, fastClosed) != 1 ||
         CopyBuffer(fastHandles[i], 0, 2, 1, fastPrevious) != 1 ||
         CopyBuffer(slowHandles[i], 0, 1, 1, slowClosed) != 1 ||
         CopyBuffer(slowHandles[i], 0, 2, 1, slowPrevious) != 1)
      {
         Print("EMA data not ready: ", timeframeNames[i]);
         return 0;
      }

      bool tfUp = fastClosed[0] > slowClosed[0];
      bool tfDown = fastClosed[0] < slowClosed[0];

      if(InpRequireEmaSlope)
      {
         tfUp = tfUp && fastClosed[0] > fastPrevious[0] &&
                slowClosed[0] >= slowPrevious[0];
         tfDown = tfDown && fastClosed[0] < fastPrevious[0] &&
                  slowClosed[0] <= slowPrevious[0];
      }

      allUp = allUp && tfUp;
      allDown = allDown && tfDown;
   }

   if(enabledCount == 0)
      return 0;
   if(allUp)
      return 1;
   if(allDown)
      return -1;
   return 0;
}

//+------------------------------------------------------------------+
void OpenBuy()
{
   if(HasAnyPosition())
      return;

   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   const double sl = InpStopLossPoints > 0
                     ? NormalizeDouble(ask - InpStopLossPoints * _Point, _Digits) : 0.0;
   const double tp = InpTakeProfitPoints > 0
                     ? NormalizeDouble(ask + InpTakeProfitPoints * _Point, _Digits) : 0.0;

   if(!trade.Buy(NormalizeVolume(InpLotSize), _Symbol, 0.0, sl, tp, "All TF EMA UP"))
      Print("Buy failed: ", trade.ResultRetcodeDescription());
}

//+------------------------------------------------------------------+
void OpenSell()
{
   if(HasAnyPosition())
      return;

   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   const double sl = InpStopLossPoints > 0
                     ? NormalizeDouble(bid + InpStopLossPoints * _Point, _Digits) : 0.0;
   const double tp = InpTakeProfitPoints > 0
                     ? NormalizeDouble(bid - InpTakeProfitPoints * _Point, _Digits) : 0.0;

   if(!trade.Sell(NormalizeVolume(InpLotSize), _Symbol, 0.0, sl, tp, "All TF EMA DOWN"))
      Print("Sell failed: ", trade.ResultRetcodeDescription());
}

//+------------------------------------------------------------------+
int OnInit()
{
   if(InpFastEmaPeriod <= 0 || InpSlowEmaPeriod <= InpFastEmaPeriod ||
      InpLotSize <= 0.0 || InpSessionStartHour < 0 ||
      InpSessionStartHour > 23 || InpSessionEndHour < 0 || InpSessionEndHour > 23)
      return INIT_PARAMETERS_INCORRECT;

   enabledTF[0] = InpUseM1;
   enabledTF[1] = InpUseM5;
   enabledTF[2] = InpUseM15;
   enabledTF[3] = InpUseM30;
   enabledTF[4] = InpUseH1;
   enabledTF[5] = InpUseH4;
   enabledTF[6] = InpUseD1;
   enabledTF[7] = InpUseW1;
   enabledTF[8] = InpUseMN1;

   int enabledCount = 0;
   for(int i = 0; i < TF_COUNT; i++)
   {
      fastHandles[i] = INVALID_HANDLE;
      slowHandles[i] = INVALID_HANDLE;
      if(!enabledTF[i])
         continue;

      enabledCount++;
      fastHandles[i] = iMA(_Symbol, timeframes[i], InpFastEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
      slowHandles[i] = iMA(_Symbol, timeframes[i], InpSlowEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);

      if(fastHandles[i] == INVALID_HANDLE || slowHandles[i] == INVALID_HANDLE)
      {
         Print("Cannot create EMA: ", timeframeNames[i]);
         return INIT_FAILED;
      }
   }

   if(enabledCount == 0)
   {
      Print("Enable at least one timeframe");
      return INIT_PARAMETERS_INCORRECT;
   }

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(_Symbol);
   lastBarTime = iTime(_Symbol, _Period, 0);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   for(int i = 0; i < TF_COUNT; i++)
   {
      if(fastHandles[i] != INVALID_HANDLE) IndicatorRelease(fastHandles[i]);
      if(slowHandles[i] != INVALID_HANDLE) IndicatorRelease(slowHandles[i]);
   }
}

//+------------------------------------------------------------------+
void OnTick()
{
   if(!IsNewBar())
      return;

   const int trend = GetConfirmedTrend();

   if(InpCloseOnTrendFlip)
   {
      if(trend == 1 && HasPosition(POSITION_TYPE_SELL))
         ClosePositions(POSITION_TYPE_SELL);
      else if(trend == -1 && HasPosition(POSITION_TYPE_BUY))
         ClosePositions(POSITION_TYPE_BUY);
   }

   if(!IsInsideSession())
      return;

   if(InpMaxSpreadPoints > 0)
   {
      const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      if((ask - bid) / _Point > InpMaxSpreadPoints)
         return;
   }

   const bool newUpTrend = trend == 1 && lastConfirmedTrend != 1;
   const bool newDownTrend = trend == -1 && lastConfirmedTrend != -1;

   if(trend == 1 && (!InpOneTradePerTrend || newUpTrend))
      OpenBuy();
   else if(trend == -1 && (!InpOneTradePerTrend || newDownTrend))
      OpenSell();

   lastConfirmedTrend = trend;
}
//+------------------------------------------------------------------+
