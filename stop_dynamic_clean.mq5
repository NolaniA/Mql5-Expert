//+------------------------------------------------------------------+
//|                                             stop_dynamic_clean.mq5|
//|  Dynamic pending distance + optional recovery lot                |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "3.00"
#property strict

#include <Trade/Trade.mqh>

CTrade trade;

//==================================================================
// INPUT
//==================================================================
input double LotSize             = 0.01;
input int    SlippagePoint       = 20;
input ulong  Magic               = 10001;

input bool   UseRecoveryLot      = false;  // default = OFF
input int    RecoveryTargetPoint = 500;
input double MaxRecoveryLot      = 1.00;

//==================================================================
// STATE
//==================================================================
int PendingBuy  = 0;
int PendingSell = 0;
int PositionBuy  = 0;
int PositionSell = 0;

double RecoveryLoss = 0.0;
long   CycleStartTimeMsc = 0;
bool   CycleClosing = false;

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   ENUM_ACCOUNT_MARGIN_MODE marginMode =
      (ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE);

   if(marginMode != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
   {
      Print("INIT FAILED | EA requires HEDGING account");
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(Magic);
   trade.SetMarginMode();
   trade.SetDeviationInPoints(SlippagePoint);
   trade.SetTypeFillingBySymbol(_Symbol);

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert tick                                                      |
//+------------------------------------------------------------------+
void OnTick()
{
   LoadTradeState();

   if(UseRecoveryLot)
      UpdateCycleStartFromPositions();

   if(CycleClosing)
   {
      ProcessCycleClose();
      return;
   }

   // BUY + SELL พร้อมกัน = จบรอบทันที
   if(PositionBuy > 0 && PositionSell > 0)
   {
      CycleClosing = true;
      ProcessCycleClose();
      return;
   }

   OpenBuyStop();
   OpenSellStop();

   LoadTradeState();

   ModifyBuyStop();
   ModifySellStop();
}

//+------------------------------------------------------------------+
//| Load current orders / positions                                  |
//+------------------------------------------------------------------+
void LoadTradeState()
{
   PendingBuy  = 0;
   PendingSell = 0;
   PositionBuy  = 0;
   PositionSell = 0;

   for(int i = 0; i < OrdersTotal(); i++)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0)
         continue;

      if(OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;

      if((ulong)OrderGetInteger(ORDER_MAGIC) != Magic)
         continue;

      ENUM_ORDER_TYPE type =
         (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);

      if(type == ORDER_TYPE_BUY_STOP)
         PendingBuy++;
      else if(type == ORDER_TYPE_SELL_STOP)
         PendingSell++;
   }

   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if((ulong)PositionGetInteger(POSITION_MAGIC) != Magic)
         continue;

      ENUM_POSITION_TYPE type =
         (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      if(type == POSITION_TYPE_BUY)
         PositionBuy++;
      else if(type == POSITION_TYPE_SELL)
         PositionSell++;
   }
}

//+------------------------------------------------------------------+
//| Cycle start time - only used when Recovery is ON                 |
//+------------------------------------------------------------------+
void UpdateCycleStartFromPositions()
{
   if(CycleStartTimeMsc > 0)
      return;

   long oldestTimeMsc = 0;

   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if((ulong)PositionGetInteger(POSITION_MAGIC) != Magic)
         continue;

      long positionTimeMsc = PositionGetInteger(POSITION_TIME_MSC);

      if(positionTimeMsc > 0 &&
         (oldestTimeMsc == 0 || positionTimeMsc < oldestTimeMsc))
      {
         oldestTimeMsc = positionTimeMsc;
      }
   }

   if(oldestTimeMsc > 0)
      CycleStartTimeMsc = oldestTimeMsc;
}

//+------------------------------------------------------------------+
//| Dynamic distance                                                 |
//| Distance = (Ask - Bid) * 2                                       |
//| Return value is in points                                        |
//+------------------------------------------------------------------+
int GetDistancePoint()
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return 0;

   if(tick.ask <= 0 || tick.bid <= 0 || tick.ask < tick.bid)
      return 0;

   double spreadPoint = (tick.ask - tick.bid) / _Point;
   int dynamicDistance = (int)MathCeil(spreadPoint * 2.0);

   int stopLevel =
      (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);

   int freezeLevel =
      (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);

   int brokerMinimum = MathMax(stopLevel, freezeLevel);

   return MathMax(dynamicDistance, brokerMinimum + 1);
}

//+------------------------------------------------------------------+
//| Normalize prices                                                 |
//+------------------------------------------------------------------+
double NormalizeBuyPrice(double price)
{
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tickSize > 0)
      price = MathCeil(price / tickSize) * tickSize;

   return NormalizeDouble(price, _Digits);
}

//+------------------------------------------------------------------+
double NormalizeSellPrice(double price)
{
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tickSize > 0)
      price = MathFloor(price / tickSize) * tickSize;

   return NormalizeDouble(price, _Digits);
}

//+------------------------------------------------------------------+
//| Trade result                                                     |
//+------------------------------------------------------------------+
bool IsTradeSuccess()
{
   uint retcode = trade.ResultRetcode();

   return(
      retcode == TRADE_RETCODE_DONE ||
      retcode == TRADE_RETCODE_PLACED ||
      retcode == TRADE_RETCODE_DONE_PARTIAL ||
      retcode == TRADE_RETCODE_NO_CHANGES
   );
}

//+------------------------------------------------------------------+
//| Normalize volume                                                 |
//+------------------------------------------------------------------+
int GetVolumeDigits(double step)
{
   for(int digits = 0; digits <= 8; digits++)
   {
      if(MathAbs(step - NormalizeDouble(step, digits)) < 1e-10)
         return digits;
   }

   return 8;
}

//+------------------------------------------------------------------+
double NormalizeVolumeUp(double volume)
{
   double minVolume = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxVolume = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step      = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(minVolume <= 0)
      minVolume = LotSize;

   if(step <= 0)
      step = minVolume;

   if(maxVolume <= 0)
      maxVolume = volume;

   volume = MathMax(volume, minVolume);
   volume = MathCeil((volume / step) - 1e-10) * step;
   volume = MathMin(volume, maxVolume);

   return NormalizeDouble(volume, GetVolumeDigits(step));
}

//+------------------------------------------------------------------+
//| Recovery lot                                                     |
//+------------------------------------------------------------------+
double CalculateRecoveryLot()
{
   if(!UseRecoveryLot || RecoveryLoss <= 0 || RecoveryTargetPoint <= 0)
      return NormalizeVolumeUp(LotSize);

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return NormalizeVolumeUp(LotSize);

   int distancePoint = GetDistancePoint();
   if(distancePoint <= 0)
      return NormalizeVolumeUp(LotSize);

   double buyEntry = NormalizeBuyPrice(
      tick.ask + distancePoint * _Point
   );

   double sellEntry = NormalizeSellPrice(
      tick.bid - distancePoint * _Point
   );

   double buyTarget = NormalizeBuyPrice(
      buyEntry + RecoveryTargetPoint * _Point
   );

   double sellTarget = NormalizeSellPrice(
      sellEntry - RecoveryTargetPoint * _Point
   );

   double buyProfitPerLot  = 0.0;
   double sellProfitPerLot = 0.0;

   bool buyOk = OrderCalcProfit(
      ORDER_TYPE_BUY,
      _Symbol,
      1.0,
      buyEntry,
      buyTarget,
      buyProfitPerLot
   );

   bool sellOk = OrderCalcProfit(
      ORDER_TYPE_SELL,
      _Symbol,
      1.0,
      sellEntry,
      sellTarget,
      sellProfitPerLot
   );

   buyProfitPerLot  = MathAbs(buyProfitPerLot);
   sellProfitPerLot = MathAbs(sellProfitPerLot);

   double profitPerLot = 0.0;

   if(buyOk && buyProfitPerLot > 0)
      profitPerLot = buyProfitPerLot;

   if(sellOk && sellProfitPerLot > 0)
   {
      if(profitPerLot <= 0)
         profitPerLot = sellProfitPerLot;
      else
         profitPerLot = MathMin(profitPerLot, sellProfitPerLot);
   }

   if(profitPerLot <= 0)
      return NormalizeVolumeUp(LotSize);

   double lot = NormalizeVolumeUp(
      MathMax(LotSize, RecoveryLoss / profitPerLot)
   );

   if(MaxRecoveryLot > 0)
      lot = MathMin(lot, NormalizeVolumeUp(MaxRecoveryLot));

   return lot;
}

//+------------------------------------------------------------------+
double GetTradeLot()
{
   if(UseRecoveryLot && RecoveryLoss > 0)
      return CalculateRecoveryLot();

   return NormalizeVolumeUp(LotSize);
}

//+------------------------------------------------------------------+
//| Open Buy Stop                                                    |
//+------------------------------------------------------------------+
void OpenBuyStop()
{
   if(PendingBuy != 0 || PositionBuy != 0)
      return;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return;

   int distancePoint = GetDistancePoint();
   if(distancePoint <= 0)
      return;

   double price = NormalizeBuyPrice(
      tick.ask + distancePoint * _Point
   );

   double volume = GetTradeLot();
   if(volume <= 0)
      return;

   bool result = trade.BuyStop(volume, price, _Symbol, 0, 0);

   if(!result || !IsTradeSuccess())
   {
      Print(
         "BUY STOP FAILED | ",
         trade.ResultRetcode(),
         " | ",
         trade.ResultRetcodeDescription()
      );
   }
}

//+------------------------------------------------------------------+
//| Open Sell Stop                                                   |
//+------------------------------------------------------------------+
void OpenSellStop()
{
   if(PendingSell != 0 || PositionSell != 0)
      return;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return;

   int distancePoint = GetDistancePoint();
   if(distancePoint <= 0)
      return;

   double price = NormalizeSellPrice(
      tick.bid - distancePoint * _Point
   );

   double volume = GetTradeLot();
   if(volume <= 0)
      return;

   bool result = trade.SellStop(volume, price, _Symbol, 0, 0);

   if(!result || !IsTradeSuccess())
   {
      Print(
         "SELL STOP FAILED | ",
         trade.ResultRetcode(),
         " | ",
         trade.ResultRetcodeDescription()
      );
   }
}

//+------------------------------------------------------------------+
//| Modify Buy Stop                                                  |
//+------------------------------------------------------------------+
void ModifyBuyStop()
{
   if(PendingBuy == 0 || PositionBuy != 0)
      return;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return;

   int distancePoint = GetDistancePoint();
   if(distancePoint <= 0)
      return;

   for(int i = 0; i < OrdersTotal(); i++)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0)
         continue;

      if(OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;

      if((ulong)OrderGetInteger(ORDER_MAGIC) != Magic)
         continue;

      if((ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE) != ORDER_TYPE_BUY_STOP)
         continue;

      double oldPrice = OrderGetDouble(ORDER_PRICE_OPEN);
      double distance = (oldPrice - tick.ask) / _Point;

      if(distance <= distancePoint)
         continue;

      double newPrice = NormalizeBuyPrice(
         tick.ask + distancePoint * _Point
      );

      if(MathAbs(newPrice - oldPrice) < (_Point / 2.0))
         continue;

      bool result = trade.OrderModify(
         ticket,
         newPrice,
         0,
         0,
         ORDER_TIME_GTC,
         0,
         0
      );

      if(!result || !IsTradeSuccess())
      {
         Print(
            "MODIFY BUY STOP FAILED | Ticket=", ticket,
            " | ", trade.ResultRetcodeDescription()
         );
      }
   }
}

//+------------------------------------------------------------------+
//| Modify Sell Stop                                                 |
//+------------------------------------------------------------------+
void ModifySellStop()
{
   if(PendingSell == 0 || PositionSell != 0)
      return;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return;

   int distancePoint = GetDistancePoint();
   if(distancePoint <= 0)
      return;

   for(int i = 0; i < OrdersTotal(); i++)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0)
         continue;

      if(OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;

      if((ulong)OrderGetInteger(ORDER_MAGIC) != Magic)
         continue;

      if((ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE) != ORDER_TYPE_SELL_STOP)
         continue;

      double oldPrice = OrderGetDouble(ORDER_PRICE_OPEN);
      double distance = (tick.bid - oldPrice) / _Point;

      if(distance <= distancePoint)
         continue;

      double newPrice = NormalizeSellPrice(
         tick.bid - distancePoint * _Point
      );

      if(MathAbs(newPrice - oldPrice) < (_Point / 2.0))
         continue;

      bool result = trade.OrderModify(
         ticket,
         newPrice,
         0,
         0,
         ORDER_TIME_GTC,
         0,
         0
      );

      if(!result || !IsTradeSuccess())
      {
         Print(
            "MODIFY SELL STOP FAILED | Ticket=", ticket,
            " | ", trade.ResultRetcodeDescription()
         );
      }
   }
}

//+------------------------------------------------------------------+
//| Delete EA Buy/Sell Stop                                          |
//+------------------------------------------------------------------+
void DeleteAllPending()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0)
         continue;

      if(OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;

      if((ulong)OrderGetInteger(ORDER_MAGIC) != Magic)
         continue;

      ENUM_ORDER_TYPE type =
         (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);

      if(type != ORDER_TYPE_BUY_STOP && type != ORDER_TYPE_SELL_STOP)
         continue;

      bool result = trade.OrderDelete(ticket);

      if(!result || !IsTradeSuccess())
      {
         Print(
            "DELETE PENDING FAILED | Ticket=", ticket,
            " | ", trade.ResultRetcodeDescription()
         );
      }
   }
}

//+------------------------------------------------------------------+
//| Close all EA positions                                           |
//+------------------------------------------------------------------+
void CloseAllPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if((ulong)PositionGetInteger(POSITION_MAGIC) != Magic)
         continue;

      bool result = trade.PositionClose(ticket, SlippagePoint);

      if(!result || !IsTradeSuccess())
      {
         Print(
            "CLOSE FAILED | Ticket=", ticket,
            " | ", trade.ResultRetcodeDescription()
         );
      }
   }
}

//+------------------------------------------------------------------+
//| Close cycle                                                      |
//+------------------------------------------------------------------+
void ProcessCycleClose()
{
   DeleteAllPending();
   CloseAllPositions();
   LoadTradeState();

   if(PositionBuy != 0 || PositionSell != 0 ||
      PendingBuy != 0 || PendingSell != 0)
   {
      return;
   }

   if(UseRecoveryLot)
      FinalizeCycleRecovery();
   else
      RecoveryLoss = 0.0;

   CycleStartTimeMsc = 0;
   CycleClosing = false;
}

//+------------------------------------------------------------------+
//| Closed cycle result                                              |
//+------------------------------------------------------------------+
bool GetClosedCycleResult(double &cycleResult)
{
   cycleResult = 0.0;

   if(CycleStartTimeMsc <= 0)
      return false;

   datetime fromTime =
      (datetime)MathMax(
         0.0,
         (double)(CycleStartTimeMsc / 1000) - 2.0
      );

   if(!HistorySelect(fromTime, TimeCurrent() + 2))
      return false;

   int dealCount = 0;

   for(int i = 0; i < HistoryDealsTotal(); i++)
   {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket == 0)
         continue;

      if(HistoryDealGetString(dealTicket, DEAL_SYMBOL) != _Symbol)
         continue;

      if((ulong)HistoryDealGetInteger(dealTicket, DEAL_MAGIC) != Magic)
         continue;

      long dealTimeMsc = HistoryDealGetInteger(dealTicket, DEAL_TIME_MSC);
      if(dealTimeMsc < CycleStartTimeMsc)
         continue;

      cycleResult +=
         HistoryDealGetDouble(dealTicket, DEAL_PROFIT) +
         HistoryDealGetDouble(dealTicket, DEAL_SWAP) +
         HistoryDealGetDouble(dealTicket, DEAL_COMMISSION) +
         HistoryDealGetDouble(dealTicket, DEAL_FEE);

      dealCount++;
   }

   return dealCount > 0;
}

//+------------------------------------------------------------------+
//| Update recovery loss                                             |
//+------------------------------------------------------------------+
void FinalizeCycleRecovery()
{
   double cycleResult = 0.0;

   if(!GetClosedCycleResult(cycleResult))
      return;

   if(cycleResult < 0)
   {
      RecoveryLoss += MathAbs(cycleResult);
      return;
   }

   if(cycleResult > 0 && RecoveryLoss > 0)
   {
      RecoveryLoss = MathMax(0.0, RecoveryLoss - cycleResult);
   }
}
