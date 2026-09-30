//+------------------------------------------------------------------+
//|                                  Pine_Candle_Conditions_EA.mq5   |
//| Converts the supplied Pine Script candle conditions to MQL5 EA  |
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"

#include <Trade/Trade.mqh>

CTrade trade;

input double InpLotSize             = 0.01;
input int    InpStopLossPoints      = 3000;   // 0 = no Stop Loss
input int    InpTakeProfitPoints    = 4500;   // 0 = no Take Profit
input int    InpMinimumCandlePoints = 100;    // Pine: 100 * syminfo.mintick
input int    InpMaxSpreadPoints     = 0;      // 0 = disable spread filter
input ulong  InpMagicNumber        = 260913;
input int    InpDeviationPoints     = 20;
input bool   InpOnePositionOnly     = true;
input bool   InpCloseOpposite       = true;

datetime lastBarTime = 0;

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
   const datetime currentBarTime = iTime(_Symbol, _Period, 0);
   if(currentBarTime == 0 || currentBarTime == lastBarTime)
      return false;

   lastBarTime = currentBarTime;
   return true;
}

//+------------------------------------------------------------------+
bool HasPosition(const ENUM_POSITION_TYPE positionType)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         (ulong)PositionGetInteger(POSITION_MAGIC) == InpMagicNumber &&
         (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == positionType)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
bool ClosePositions(const ENUM_POSITION_TYPE positionType)
{
   bool result = true;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol ||
         (ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber ||
         (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != positionType)
         continue;

      if(!trade.PositionClose(ticket))
      {
         Print("Close failed #", ticket, ": ", trade.ResultRetcodeDescription());
         result = false;
      }
   }
   return result;
}

//+------------------------------------------------------------------+
void OpenBuy()
{
   if(InpCloseOpposite && HasPosition(POSITION_TYPE_SELL))
      if(!ClosePositions(POSITION_TYPE_SELL))
         return;

   if(InpOnePositionOnly && HasPosition(POSITION_TYPE_BUY))
      return;

   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   const double sl  = InpStopLossPoints > 0
                      ? NormalizeDouble(ask - InpStopLossPoints * _Point, _Digits) : 0.0;
   const double tp  = InpTakeProfitPoints > 0
                      ? NormalizeDouble(ask + InpTakeProfitPoints * _Point, _Digits) : 0.0;

   if(!trade.Buy(NormalizeVolume(InpLotSize), _Symbol, 0.0, sl, tp, "Pine Buy"))
      Print("Buy failed: ", trade.ResultRetcodeDescription());
}

//+------------------------------------------------------------------+
void OpenSell()
{
   if(InpCloseOpposite && HasPosition(POSITION_TYPE_BUY))
      if(!ClosePositions(POSITION_TYPE_BUY))
         return;

   if(InpOnePositionOnly && HasPosition(POSITION_TYPE_SELL))
      return;

   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   const double sl  = InpStopLossPoints > 0
                      ? NormalizeDouble(bid + InpStopLossPoints * _Point, _Digits) : 0.0;
   const double tp  = InpTakeProfitPoints > 0
                      ? NormalizeDouble(bid - InpTakeProfitPoints * _Point, _Digits) : 0.0;

   if(!trade.Sell(NormalizeVolume(InpLotSize), _Symbol, 0.0, sl, tp, "Pine Sell"))
      Print("Sell failed: ", trade.ResultRetcodeDescription());
}

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   // Prevent a historical signal from opening immediately after attaching EA.
   lastBarTime = iTime(_Symbol, _Period, 0);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnTick()
{
   if(!IsNewBar())
      return;

   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, _Period, 0, 5, rates) < 5)
   {
      Print("Not enough candle data");
      return;
   }

   if(InpMaxSpreadPoints > 0)
   {
      const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      if((ask - bid) / _Point > InpMaxSpreadPoints)
         return;
   }

   const double minimumBody = InpMinimumCandlePoints * _Point;

   // Exact translation of Pine buyCondition1..3.
   const bool buyCondition1 =
      rates[1].close > rates[1].open &&
      rates[2].open  > rates[2].close &&
      rates[1].close > rates[2].open &&
      (rates[2].open - rates[2].close) > minimumBody;

   const bool buyCondition2 =
      rates[1].close > rates[1].open &&
      rates[2].close > rates[2].open &&
      rates[3].open  > rates[3].close &&
      rates[1].close > rates[3].open &&
      (rates[3].open - rates[3].close) > (rates[2].close - rates[2].open) &&
      (rates[3].open - rates[3].close) > minimumBody;

   const bool buyCondition3 =
      rates[1].close > rates[1].open &&
      rates[2].close > rates[2].open &&
      rates[3].close > rates[3].open &&
      rates[4].open  > rates[4].close &&
      rates[1].close > rates[4].open &&
      (rates[4].open - rates[4].close) > (rates[2].close - rates[2].open) &&
      (rates[4].open - rates[4].close) > (rates[3].close - rates[3].open) &&
      (rates[4].open - rates[4].close) > minimumBody;

   // Exact translation of Pine sellCondition1..3.
   const bool sellCondition1 =
      rates[1].close < rates[1].open &&
      rates[2].open  < rates[2].close &&
      rates[1].close < rates[2].open &&
      (rates[2].close - rates[2].open) > minimumBody;

   const bool sellCondition2 =
      rates[3].close > rates[3].open &&
      rates[2].open  > rates[2].close &&
      rates[1].open  > rates[1].close &&
      rates[3].open  > rates[1].close &&
      (rates[3].close - rates[3].open) > (rates[2].open - rates[2].close) &&
      (rates[3].close - rates[3].open) > minimumBody;

   const bool sellCondition3 =
      rates[4].close > rates[4].open &&
      rates[3].open  > rates[3].close &&
      rates[2].open  > rates[2].close &&
      rates[1].open  > rates[1].close &&
      rates[4].open  > rates[1].close &&
      (rates[4].close - rates[4].open) > (rates[2].open - rates[2].close) &&
      (rates[4].close - rates[4].open) > (rates[3].open - rates[3].close) &&
      (rates[4].close - rates[4].open) > minimumBody;

   const bool buySignal  = buyCondition1 || buyCondition2 || buyCondition3;
   const bool sellSignal = sellCondition1 || sellCondition2 || sellCondition3;

   if(buySignal && !sellSignal)
   {
      Print("BUY signal: ", buyCondition1, ",", buyCondition2, ",", buyCondition3);
      OpenBuy();
   }
   else if(sellSignal && !buySignal)
   {
      Print("SELL signal: ", sellCondition1, ",", sellCondition2, ",", sellCondition3);
      OpenSell();
   }
}
//+------------------------------------------------------------------+
