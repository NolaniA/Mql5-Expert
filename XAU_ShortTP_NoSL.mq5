//+------------------------------------------------------------------+
//|                                     XAU_ShortTP_NoSL_v2.mq5      |
//| Price-action scalper: short TP, no per-trade Stop Loss           |
//+------------------------------------------------------------------+
#property strict
#property version "2.00"

#include <Trade/Trade.mqh>
CTrade trade;

input group "TRADE"
input double          LotSize             = 0.01;
input int             TakeProfitPoints    = 150;
input int             MaxPositions        = 3;
input ulong           MagicNumber         = 26091302;
input int             DeviationPoints     = 50;
input ENUM_TIMEFRAMES SignalTimeframe     = PERIOD_M1;

input group "OPTIONAL SAFETY"
input bool            UseEquityGuard      = false;
input double          MaxDrawdownPercent  = 10.0;

datetime lastBarTime = 0;
bool tradingStopped = false;

int OnInit()
{
   if(LotSize <= 0.0 || TakeProfitPoints <= 0 || MaxPositions <= 0)
   {
      Print("INIT FAILED: invalid inputs");
      return INIT_PARAMETERS_INCORRECT;
   }

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(DeviationPoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   Print("EA STARTED | Symbol=", _Symbol,
         " | TF=", EnumToString(SignalTimeframe),
         " | Lot=", DoubleToString(LotSize, 2),
         " | TP points=", TakeProfitPoints);
   return INIT_SUCCEEDED;
}

void OnTick()
{
   CheckEquityGuard();
   if(tradingStopped)
      return;

   datetime barTime = iTime(_Symbol, SignalTimeframe, 0);
   if(barTime <= 0 || barTime == lastBarTime)
      return;

   lastBarTime = barTime;

   int currentPositions = CountPositions();
   if(currentPositions >= MaxPositions)
   {
      Print("SKIP | MaxPositions reached: ", currentPositions);
      return;
   }

   MqlRates candle[];
   ArraySetAsSeries(candle, true);
   ResetLastError();

   if(CopyRates(_Symbol, SignalTimeframe, 1, 1, candle) != 1)
   {
      Print("SKIP | CopyRates failed: ", GetLastError());
      return;
   }

   if(candle[0].close > candle[0].open)
      OpenPosition(ORDER_TYPE_BUY);
   else if(candle[0].close < candle[0].open)
      OpenPosition(ORDER_TYPE_SELL);
   else
      Print("SKIP | Previous candle is doji");
}

void OpenPosition(const ENUM_ORDER_TYPE orderType)
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick) || tick.ask <= 0 || tick.bid <= 0)
   {
      Print("ORDER FAILED | Invalid tick | Error=", GetLastError());
      return;
   }

   double volume = NormalizeLot(LotSize);
   if(volume <= 0)
   {
      Print("ORDER FAILED | Invalid normalized volume");
      return;
   }

   int stopsLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   int distancePoints = TakeProfitPoints;
   if(distancePoints <= stopsLevel)
      distancePoints = stopsLevel + 1;
   double tp = 0.0;
   bool sent = false;

   ResetLastError();
   if(orderType == ORDER_TYPE_BUY)
   {
      tp = NormalizeDouble(tick.ask + distancePoints * _Point, _Digits);
      sent = trade.Buy(volume, _Symbol, 0.0, 0.0, tp, "PA ShortTP BUY");
   }
   else
   {
      tp = NormalizeDouble(tick.bid - distancePoints * _Point, _Digits);
      sent = trade.Sell(volume, _Symbol, 0.0, 0.0, tp, "PA ShortTP SELL");
   }

   if(!sent)
   {
      Print("ORDER FAILED | Type=", EnumToString(orderType),
            " | Retcode=", trade.ResultRetcode(),
            " | Message=", trade.ResultRetcodeDescription(),
            " | Error=", GetLastError(),
            " | Bid=", DoubleToString(tick.bid, _Digits),
            " | Ask=", DoubleToString(tick.ask, _Digits),
            " | TP=", DoubleToString(tp, _Digits),
            " | Lot=", DoubleToString(volume, 2));
      return;
   }

   Print("ORDER OPENED | Type=", EnumToString(orderType),
         " | Deal=", trade.ResultDeal(),
         " | Price=", DoubleToString(trade.ResultPrice(), _Digits),
         " | TP=", DoubleToString(tp, _Digits));
}

int CountPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         (ulong)PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         count++;
   }
   return count;
}

double NormalizeLot(const double requestedLot)
{
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(minLot <= 0 || maxLot <= 0 || step <= 0)
      return 0.0;

   double lot = MathMax(minLot, MathMin(maxLot, requestedLot));
   lot = minLot + MathFloor((lot - minLot) / step + 0.0000001) * step;
   lot = MathMax(minLot, MathMin(maxLot, lot));

   int volumeDigits = 0;
   double tempStep = step;
   while(volumeDigits < 8 && MathAbs(tempStep - MathRound(tempStep)) > 0.00000001)
   {
      tempStep *= 10.0;
      volumeDigits++;
   }

   return NormalizeDouble(lot, volumeDigits);
}

void CheckEquityGuard()
{
   if(!UseEquityGuard || tradingStopped)
      return;

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   if(balance <= 0)
      return;

   double drawdownPercent = (balance - equity) / balance * 100.0;
   if(drawdownPercent < MaxDrawdownPercent)
      return;

   CloseAllPositions();
   tradingStopped = true;
   Print("EQUITY GUARD | Trading stopped | Drawdown=",
         DoubleToString(drawdownPercent, 2), "%");
}

void CloseAllPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol ||
         (ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;

      if(!trade.PositionClose(ticket))
         Print("CLOSE FAILED | Ticket=", ticket,
               " | Retcode=", trade.ResultRetcode(),
               " | Message=", trade.ResultRetcodeDescription());
   }
}
//+------------------------------------------------------------------+
