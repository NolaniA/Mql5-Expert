//+------------------------------------------------------------------+
//|                                             stop_news_hybrid.mq5 |
//|  News-only pending stop EA + dynamic distance + optional recovery|
//+------------------------------------------------------------------+
#property copyright "Copyright 2026"
#property version   "4.00"
#property strict
#property tester_file "news.csv"

#include <Trade/Trade.mqh>

#define TESTER_NEWS_FILE "news.csv"
#define LIVE_CALENDAR_REFRESH_SECONDS 5

CTrade trade;

//==================================================================
// INPUT
//==================================================================
input double LotSize             = 0.01;
input int    SlippagePoint       = 20;
input ulong  Magic               = 10001;

input bool   UseNewsFilter       = true;
input string NewsCurrency        = "USD";
input bool   HighImpactOnly      = true;
input int    MinutesBeforeNews   = 2;
input int    MinutesAfterNews    = 5;

input bool   UseRecoveryLot      = false;  // default = OFF
input int    RecoveryTargetPoint = 500;
input double MaxRecoveryLot      = 1.00;

//==================================================================
// TRADE STATE
//==================================================================
int PendingBuy   = 0;
int PendingSell  = 0;
int PositionBuy  = 0;
int PositionSell = 0;

double RecoveryLoss      = 0.0;
long   CycleStartTimeMsc  = 0;
bool   CycleClosing       = false;

//==================================================================
// NEWS STATE
//==================================================================
struct TesterNewsRecord
{
   datetime time;
   string   currency;
   bool     highImpact;
   string   name;
};

TesterNewsRecord TesterNews[];
int      TesterNewsCount       = 0;
datetime LastCalendarCheckTime = 0;
bool     CachedLiveNewsActive  = false;

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

   if(LotSize <= 0)
   {
      Print("INIT FAILED | LotSize must be > 0");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(MinutesBeforeNews < 0 || MinutesAfterNews < 0)
   {
      Print("INIT FAILED | News minutes cannot be negative");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(UseRecoveryLot && RecoveryTargetPoint <= 0)
   {
      Print("INIT FAILED | RecoveryTargetPoint must be > 0");
      return INIT_PARAMETERS_INCORRECT;
   }

   trade.SetExpertMagicNumber(Magic);
   trade.SetMarginMode();
   trade.SetDeviationInPoints(SlippagePoint);
   trade.SetTypeFillingBySymbol(_Symbol);

   if(UseNewsFilter && IsTesterMode())
   {
      if(!LoadTesterNews())
      {
         Print(
            "INIT FAILED | Backtest requires ", TESTER_NEWS_FILE,
            " with at least one valid news row"
         );
         return INIT_FAILED;
      }
   }

   Print(
      "EA READY | NewsFilter=", UseNewsFilter,
      " | Tester=", IsTesterMode(),
      " | Recovery=", UseRecoveryLot
   );

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

   // Finish an already-started close sequence first.
   if(CycleClosing)
   {
      ProcessCycleClose();
      return;
   }

   // BUY + SELL together = end current cycle immediately.
   if(PositionBuy > 0 && PositionSell > 0)
   {
      CycleClosing = true;
      ProcessCycleClose();
      return;
   }

   bool hasOpenPosition = (PositionBuy > 0 || PositionSell > 0);

   // A new cycle may start only during the configured news window.
   // If a position already exists, continue managing that cycle even
   // after the news window ends.
   if(!hasOpenPosition && !IsNewsTradingTime())
   {
      DeleteAllPending();
      return;
   }

   OpenBuyStop();
   OpenSellStop();

   LoadTradeState();

   ModifyBuyStop();
   ModifySellStop();
}

//+------------------------------------------------------------------+
//| Tester mode                                                      |
//+------------------------------------------------------------------+
bool IsTesterMode()
{
   return (MQLInfoInteger(MQL_TESTER) != 0);
}

//+------------------------------------------------------------------+
//| Current clock                                                    |
//+------------------------------------------------------------------+
datetime GetTradingTime()
{
   if(IsTesterMode())
      return TimeCurrent();

   datetime serverTime = TimeTradeServer();
   if(serverTime > 0)
      return serverTime;

   return TimeCurrent();
}

//+------------------------------------------------------------------+
//| News gate                                                        |
//+------------------------------------------------------------------+
bool IsNewsTradingTime()
{
   if(!UseNewsFilter)
      return true;

   datetime now = GetTradingTime();
   if(now <= 0)
      return false;

   if(IsTesterMode())
      return IsTesterNewsWindow(now);

   return IsLiveNewsWindow(now);
}

//+------------------------------------------------------------------+
//| Live: MT5 Economic Calendar                                      |
//+------------------------------------------------------------------+
bool IsLiveNewsWindow(datetime now)
{
   if(LastCalendarCheckTime > 0 &&
      now >= LastCalendarCheckTime &&
      (now - LastCalendarCheckTime) < LIVE_CALENDAR_REFRESH_SECONDS)
   {
      return CachedLiveNewsActive;
   }

   LastCalendarCheckTime = now;
   CachedLiveNewsActive  = false;

   datetime fromTime = now - MinutesAfterNews * 60;
   datetime toTime   = now + MinutesBeforeNews * 60;

   MqlCalendarValue values[];
   ResetLastError();

   int count = CalendarValueHistory(
      values,
      fromTime,
      toTime,
      "",
      NewsCurrency
   );

   if(count < 0)
   {
      Print("CALENDAR ERROR | ", GetLastError());
      return false;
   }

   for(int i = 0; i < count; i++)
   {
      MqlCalendarEvent event;

      if(!CalendarEventById(values[i].event_id, event))
         continue;

      if(HighImpactOnly && event.importance != CALENDAR_IMPORTANCE_HIGH)
         continue;

      datetime newsTime  = values[i].time;
      datetime startTime = newsTime - MinutesBeforeNews * 60;
      datetime endTime   = newsTime + MinutesAfterNews * 60;

      if(now >= startTime && now <= endTime)
      {
         CachedLiveNewsActive = true;
         return true;
      }
   }

   return false;
}

//+------------------------------------------------------------------+
//| Tester: CSV historical news                                      |
//| Format: datetime;currency;importance;event                       |
//| Example: 2026.09.17 01:00;USD;HIGH;FOMC Rate Decision           |
//+------------------------------------------------------------------+
bool LoadTesterNews()
{
   ArrayResize(TesterNews, 0);
   TesterNewsCount = 0;

   ResetLastError();
   int handle = FileOpen(
      TESTER_NEWS_FILE,
      FILE_READ | FILE_CSV | FILE_ANSI,
      ';'
   );

   if(handle == INVALID_HANDLE)
   {
      Print(
         "NEWS CSV OPEN FAILED | File=", TESTER_NEWS_FILE,
         " | Error=", GetLastError()
      );
      return false;
   }

   while(!FileIsEnding(handle))
   {
      string timeText   = FileReadString(handle);
      string currency   = FileReadString(handle);
      string importance = FileReadString(handle);
      string eventName  = FileReadString(handle);

      if(timeText == "")
         continue;

      if(timeText == "datetime" || timeText == "DATETIME")
         continue;

      if(StringSubstr(timeText, 0, 1) == "#")
         continue;

      datetime newsTime = StringToTime(timeText);
      if(newsTime <= 0)
      {
         Print("NEWS CSV SKIP | Invalid datetime: ", timeText);
         continue;
      }

      bool isHigh = IsHighImportanceText(importance);

      int newSize = TesterNewsCount + 1;
      if(ArrayResize(TesterNews, newSize) != newSize)
      {
         FileClose(handle);
         Print("NEWS CSV FAILED | Cannot resize news array");
         return false;
      }

      TesterNews[TesterNewsCount].time       = newsTime;
      TesterNews[TesterNewsCount].currency   = currency;
      TesterNews[TesterNewsCount].highImpact = isHigh;
      TesterNews[TesterNewsCount].name       = eventName;

      TesterNewsCount++;
   }

   FileClose(handle);

   Print("NEWS CSV LOADED | Records=", TesterNewsCount);
   return (TesterNewsCount > 0);
}

//+------------------------------------------------------------------+
bool IsHighImportanceText(string value)
{
   if(value == "HIGH" || value == "High" || value == "high")
      return true;

   return false;
}

//+------------------------------------------------------------------+
bool IsTesterNewsWindow(datetime now)
{
   for(int i = 0; i < TesterNewsCount; i++)
   {
      if(TesterNews[i].currency != NewsCurrency)
         continue;

      if(HighImpactOnly && !TesterNews[i].highImpact)
         continue;

      datetime startTime = TesterNews[i].time - MinutesBeforeNews * 60;
      datetime endTime   = TesterNews[i].time + MinutesAfterNews * 60;

      if(now >= startTime && now <= endTime)
         return true;
   }

   return false;
}

//+------------------------------------------------------------------+
//| Load current orders / positions                                  |
//+------------------------------------------------------------------+
void LoadTradeState()
{
   PendingBuy   = 0;
   PendingSell  = 0;
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
      Print(
         "RECOVERY DEBT ADD | Cycle=", DoubleToString(cycleResult, 2),
         " | Debt=", DoubleToString(RecoveryLoss, 2)
      );
      return;
   }

   if(cycleResult > 0 && RecoveryLoss > 0)
   {
      RecoveryLoss = MathMax(0.0, RecoveryLoss - cycleResult);
      Print(
         "RECOVERY DEBT REDUCE | Cycle=", DoubleToString(cycleResult, 2),
         " | Debt=", DoubleToString(RecoveryLoss, 2)
      );
   }
}
