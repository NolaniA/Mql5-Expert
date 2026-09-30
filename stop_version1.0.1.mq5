//+------------------------------------------------------------------+
//|                                                         stop.mq5 |
//|                                  Copyright 2025, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+

// version 1.0.3: recover by profit + distance + volume imbalance

#property copyright "Copyright 2025, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "1.10"

#include <Trade/Trade.mqh>

CTrade trade;

//==================================================================
// GLOBAL INPUT
//==================================================================

input int CandleRate = 10;

input double LotSize = 0.01;

input int DistancePoint = 2500;

input int SlippagePoint = 20;

input ulong Magic = 10001;

input int TrendBars = 3;

input int TrendStartShift = 3;

input double BasketTargetProfit = 1.0;

// ขาดทุนรวมสูงสุดของ Basket (ใส่เป็นค่าบวก เช่น 20 = ตัดที่ -20)
input double MaxBasketLoss = 2000.0;

// ฝั่งที่จะ Recovery ต้องมีกำไรรวมอย่างน้อยเท่านี้
input double MinRecoveryProfit = 1.0;

// ราคาต้องเดินจากจุดอ้างอิงของฝั่งกำไรอย่างน้อยกี่ Point
input int RecoveryTriggerPoint = 1000;

// ระยะที่คาดว่าราคาจะวิ่งต่อหลังเปิด Recovery
// ใช้สำหรับคำนวณ Recovery Lot
input int RecoveryTargetPoint = 500;

// จำกัด Lot สูงสุดของ Recovery
// ถ้าคำนวณได้มากกว่านี้ จะเปิดแบบ Partial Recovery ที่ MaxRecoveryLot
input double MaxRecoveryLot = 0.05;

input int MaxRecoveryPositions = 5;


//==================================================================
// GLOBAL
//==================================================================

MqlRates prices[];

int PendingBuy = 0;
int PendingSell = 0;

int PositionBuy = 0;
int PositionSell = 0;




//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   //===============================================================
   // EA นี้ต้องใช้ Hedging Account
   //===============================================================
   ENUM_ACCOUNT_MARGIN_MODE marginMode =
      (ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(
         ACCOUNT_MARGIN_MODE
      );


   if(marginMode != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
   {
      Print(
         "INIT FAILED | EA requires HEDGING account"
      );

      return INIT_FAILED;
   }


   //===============================================================
   // TRADE SETTINGS
   //===============================================================
   trade.SetExpertMagicNumber(Magic);

   trade.SetMarginMode();

   trade.SetDeviationInPoints(
      SlippagePoint
   );

   trade.SetTypeFillingBySymbol(
      _Symbol
   );


   return INIT_SUCCEEDED;
}


//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{

}


//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   //===============================================================
   // LOAD PRICE
   //===============================================================
   if(!LoadPrices(CandleRate))
      return;


   //===============================================================
   // LOAD CURRENT STATE
   //===============================================================
   LoadTradeState();


   //===============================================================
   // CLOSE
   // ถ้ามีทั้ง BUY + SELL ให้ปิด Position ที่กำไรมากที่สุด
   //===============================================================
   // CloseBestProfitPosition();
   ManageRecovery();


   //===============================================================
   // REFRESH STATE
   // เพราะอาจมี Position ถูกปิด
   //===============================================================
   LoadTradeState();


   //===============================================================
   // OPEN
   //===============================================================
   OpenBuyStop();

   OpenSellStop();


   //===============================================================
   // REFRESH STATE
   // เพราะอาจมี Pending Order ถูกเปิดใหม่
   //===============================================================
   LoadTradeState();


   //===============================================================
   // MODIFY
   //===============================================================
   ModifyBuyStop();

   ModifySellStop();
}


//+------------------------------------------------------------------+
//| Load Prices                                                      |
//+------------------------------------------------------------------+
bool LoadPrices(const int candle)
{
   ArraySetAsSeries(
      prices,
      true
   );


   int minimumBars =
      TrendStartShift +
      TrendBars +
      1;


   int requiredBars =
      MathMax(
         candle,
         minimumBars
      );


   int copied =
      CopyRates(
         _Symbol,
         _Period,
         0,
         requiredBars,
         prices
      );


   if(copied < requiredBars)
   {
      Print(
         "CopyRates failed",
         " | copied=", copied,
         " | required=", requiredBars
      );

      return false;
   }


   return true;
}


//+------------------------------------------------------------------+
//| Load Trade State                                                 |
//+------------------------------------------------------------------+
void LoadTradeState()
{
   //===============================================================
   // RESET
   //===============================================================
   PendingBuy = 0;
   PendingSell = 0;

   PositionBuy = 0;
   PositionSell = 0;


   //===============================================================
   // PENDING ORDERS
   //===============================================================
   for(int i = 0; i < OrdersTotal(); i++)
   {
      ulong ticket =
         OrderGetTicket(i);


      if(ticket == 0)
         continue;


      if(
         OrderGetString(ORDER_SYMBOL)
         !=
         _Symbol
      )
         continue;


      if(
         (ulong)OrderGetInteger(ORDER_MAGIC)
         !=
         Magic
      )
         continue;


      ENUM_ORDER_TYPE type =
         (ENUM_ORDER_TYPE)OrderGetInteger(
            ORDER_TYPE
         );


      if(type == ORDER_TYPE_BUY_STOP)
      {
         PendingBuy++;
      }
      else
      if(type == ORDER_TYPE_SELL_STOP)
      {
         PendingSell++;
      }
   }


   //===============================================================
   // POSITIONS
   //===============================================================
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket =
         PositionGetTicket(i);


      if(ticket == 0)
         continue;


      if(
         PositionGetString(POSITION_SYMBOL)
         !=
         _Symbol
      )
         continue;


      if(
         (ulong)PositionGetInteger(POSITION_MAGIC)
         !=
         Magic
      )
         continue;


      ENUM_POSITION_TYPE type =
         (ENUM_POSITION_TYPE)PositionGetInteger(
            POSITION_TYPE
         );


      if(type == POSITION_TYPE_BUY)
      {
         PositionBuy++;
      }
      else
      if(type == POSITION_TYPE_SELL)
      {
         PositionSell++;
      }
   }
}


//+------------------------------------------------------------------+
//| Get Safe Distance Point                                          |
//+------------------------------------------------------------------+
int GetDistancePoint()
{
   int stopLevel =
      (int)SymbolInfoInteger(
         _Symbol,
         SYMBOL_TRADE_STOPS_LEVEL
      );


   int freezeLevel =
      (int)SymbolInfoInteger(
         _Symbol,
         SYMBOL_TRADE_FREEZE_LEVEL
      );


   int brokerMinimum =
      MathMax(
         stopLevel,
         freezeLevel
      );


   int distance =
      MathMax(
         DistancePoint,
         brokerMinimum + 1
      );


   return distance;
}


//+------------------------------------------------------------------+
//| Normalize Buy Stop Price                                         |
//+------------------------------------------------------------------+
double NormalizeBuyPrice(double price)
{
   double tickSize =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_TRADE_TICK_SIZE
      );


   if(tickSize <= 0)
      return NormalizeDouble(price, _Digits);


   price =
      MathCeil(
         price / tickSize
      ) * tickSize;


   return NormalizeDouble(
      price,
      _Digits
   );
}


//+------------------------------------------------------------------+
//| Normalize Sell Stop Price                                        |
//+------------------------------------------------------------------+
double NormalizeSellPrice(double price)
{
   double tickSize =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_TRADE_TICK_SIZE
      );


   if(tickSize <= 0)
      return NormalizeDouble(price, _Digits);


   price =
      MathFloor(
         price / tickSize
      ) * tickSize;


   return NormalizeDouble(
      price,
      _Digits
   );
}


//+------------------------------------------------------------------+
//| Check Trade Result                                               |
//+------------------------------------------------------------------+
bool IsTradeSuccess()
{
   uint retcode =
      trade.ResultRetcode();


   return(
      retcode == TRADE_RETCODE_DONE ||
      retcode == TRADE_RETCODE_PLACED ||
      retcode == TRADE_RETCODE_DONE_PARTIAL ||
      retcode == TRADE_RETCODE_NO_CHANGES
   );
}


//+------------------------------------------------------------------+
//| Open Buy Stop                                                    |
//+------------------------------------------------------------------+
void OpenBuyStop()
{
   if(
      PendingBuy != 0 ||
      PositionBuy != 0
   )
      return;


   double ask =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_ASK
      );


   if(ask <= 0)
      return;


   int distancePoint =
      GetDistancePoint();


   double price =
      NormalizeBuyPrice(
         ask +
         (
            distancePoint *
            _Point
         )
      );


   bool requestResult =
      trade.BuyStop(
         LotSize,
         price,
         _Symbol,
         0,
         0
      );


   if(
      !requestResult ||
      !IsTradeSuccess()
   )
   {
      Print(
         "BUY STOP FAILED",
         " | Price=", price,
         " | Retcode=", trade.ResultRetcode(),
         " | ", trade.ResultRetcodeDescription()
      );

      return;
   }


   Print(
      "BUY STOP OPEN",
      " | Ticket=", trade.ResultOrder(),
      " | Price=", price,
      " | Ask=", ask,
      " | Distance=", distancePoint
   );
}


//+------------------------------------------------------------------+
//| Open Sell Stop                                                   |
//+------------------------------------------------------------------+
void OpenSellStop()
{
   if(
      PendingSell != 0 ||
      PositionSell != 0
   )
      return;


   double bid =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_BID
      );


   if(bid <= 0)
      return;


   int distancePoint =
      GetDistancePoint();


   double price =
      NormalizeSellPrice(
         bid -
         (
            distancePoint *
            _Point
         )
      );


   bool requestResult =
      trade.SellStop(
         LotSize,
         price,
         _Symbol,
         0,
         0
      );


   if(
      !requestResult ||
      !IsTradeSuccess()
   )
   {
      Print(
         "SELL STOP FAILED",
         " | Price=", price,
         " | Retcode=", trade.ResultRetcode(),
         " | ", trade.ResultRetcodeDescription()
      );

      return;
   }


   Print(
      "SELL STOP OPEN",
      " | Ticket=", trade.ResultOrder(),
      " | Price=", price,
      " | Bid=", bid,
      " | Distance=", distancePoint
   );
}


//+------------------------------------------------------------------+
//| Modify Buy Stop                                                  |
//+------------------------------------------------------------------+
void ModifyBuyStop()
{
   if(
      PendingBuy == 0 ||
      PositionBuy != 0
   )
      return;


   double ask =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_ASK
      );


   if(ask <= 0)
      return;


   int distancePoint =
      GetDistancePoint();


   for(int i = 0; i < OrdersTotal(); i++)
   {
      ulong ticket =
         OrderGetTicket(i);


      if(ticket == 0)
         continue;


      if(
         OrderGetString(ORDER_SYMBOL)
         !=
         _Symbol
      )
         continue;


      if(
         (ulong)OrderGetInteger(ORDER_MAGIC)
         !=
         Magic
      )
         continue;


      ENUM_ORDER_TYPE type =
         (ENUM_ORDER_TYPE)OrderGetInteger(
            ORDER_TYPE
         );


      if(type != ORDER_TYPE_BUY_STOP)
         continue;


      double oldPrice =
         OrderGetDouble(
            ORDER_PRICE_OPEN
         );


      double distance =
         (oldPrice - ask)
         /
         _Point;


      // ราคาเคลื่อนลงหนี BUY STOP เกินระยะที่กำหนด
      // ให้เลื่อน BUY STOP ลงมาตามราคา
      if(distance > distancePoint)
      {
         double newPrice =
            NormalizeBuyPrice(
               ask +
               (
                  distancePoint *
                  _Point
               )
            );


         // ป้องกัน Modify ราคาเดิม
         if(
            MathAbs(
               newPrice - oldPrice
            ) < (_Point / 2.0)
         )
            continue;


         bool requestResult =
            trade.OrderModify(
               ticket,
               newPrice,
               0,
               0,
               ORDER_TIME_GTC,
               0,
               0
            );


         if(
            !requestResult ||
            !IsTradeSuccess()
         )
         {
            Print(
               "MODIFY BUY STOP FAILED",
               " | Ticket=", ticket,
               " | Old=", oldPrice,
               " | New=", newPrice,
               " | Distance=", distance,
               " | Retcode=", trade.ResultRetcode(),
               " | ", trade.ResultRetcodeDescription()
            );

            continue;
         }


         Print(
            "MODIFY BUY STOP",
            " | Ticket=", ticket,
            " | Old=", oldPrice,
            " | New=", newPrice,
            " | Ask=", ask,
            " | Distance=", distance
         );
      }
   }
}


//+------------------------------------------------------------------+
//| Modify Sell Stop                                                 |
//+------------------------------------------------------------------+
void ModifySellStop()
{
   if(
      PendingSell == 0 ||
      PositionSell != 0
   )
      return;


   double bid =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_BID
      );


   if(bid <= 0)
      return;


   int distancePoint =
      GetDistancePoint();


   for(int i = 0; i < OrdersTotal(); i++)
   {
      ulong ticket =
         OrderGetTicket(i);


      if(ticket == 0)
         continue;


      if(
         OrderGetString(ORDER_SYMBOL)
         !=
         _Symbol
      )
         continue;


      if(
         (ulong)OrderGetInteger(ORDER_MAGIC)
         !=
         Magic
      )
         continue;


      ENUM_ORDER_TYPE type =
         (ENUM_ORDER_TYPE)OrderGetInteger(
            ORDER_TYPE
         );


      if(type != ORDER_TYPE_SELL_STOP)
         continue;


      double oldPrice =
         OrderGetDouble(
            ORDER_PRICE_OPEN
         );


      double distance =
         (bid - oldPrice)
         /
         _Point;


      // ราคาเคลื่อนขึ้นหนี SELL STOP เกินระยะที่กำหนด
      // ให้เลื่อน SELL STOP ขึ้นมาตามราคา
      if(distance > distancePoint)
      {
         double newPrice =
            NormalizeSellPrice(
               bid -
               (
                  distancePoint *
                  _Point
               )
            );


         // ป้องกัน Modify ราคาเดิม
         if(
            MathAbs(
               newPrice - oldPrice
            ) < (_Point / 2.0)
         )
            continue;


         bool requestResult =
            trade.OrderModify(
               ticket,
               newPrice,
               0,
               0,
               ORDER_TIME_GTC,
               0,
               0
            );


         if(
            !requestResult ||
            !IsTradeSuccess()
         )
         {
            Print(
               "MODIFY SELL STOP FAILED",
               " | Ticket=", ticket,
               " | Old=", oldPrice,
               " | New=", newPrice,
               " | Distance=", distance,
               " | Retcode=", trade.ResultRetcode(),
               " | ", trade.ResultRetcodeDescription()
            );

            continue;
         }


         Print(
            "MODIFY SELL STOP",
            " | Ticket=", ticket,
            " | Old=", oldPrice,
            " | New=", newPrice,
            " | Bid=", bid,
            " | Distance=", distance
         );
      }
   }
}


//+------------------------------------------------------------------+
//| Close Position ที่กำไรมากที่สุด                                  |
//+------------------------------------------------------------------+
bool CloseBestProfitPosition()
{
   // ต้องมีทั้ง BUY และ SELL
   if(
      PositionBuy == 0 ||
      PositionSell == 0
   )
      return false;


   ulong bestTicket = 0;

   double bestProfit = 0;


   //===============================================================
   // FIND BEST PROFIT POSITION
   //===============================================================
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket =
         PositionGetTicket(i);


      if(ticket == 0)
         continue;


      if(
         PositionGetString(POSITION_SYMBOL)
         !=
         _Symbol
      )
         continue;


      if(
         (ulong)PositionGetInteger(POSITION_MAGIC)
         !=
         Magic
      )
         continue;


      double profit =
         PositionGetDouble(
            POSITION_PROFIT
         );


      // ปิดเฉพาะ Position ที่กำไรมากกว่า 0
      if(profit <= bestProfit)
         continue;


      bestProfit = profit;

      bestTicket = ticket;
   }


   if(bestTicket == 0)
      return false;


   //===============================================================
   // CLOSE
   //===============================================================
   bool requestResult =
      trade.PositionClose(
         bestTicket,
         SlippagePoint
      );


   if(
      !requestResult ||
      !IsTradeSuccess()
   )
   {
      Print(
         "CLOSE BEST POSITION FAILED",
         " | Ticket=", bestTicket,
         " | Profit=", bestProfit,
         " | Retcode=", trade.ResultRetcode(),
         " | ", trade.ResultRetcodeDescription()
      );

      return false;
   }


   Print(
      "CLOSE BEST POSITION",
      " | Ticket=", bestTicket,
      " | Profit=", bestProfit
   );


   return true;
}


//+------------------------------------------------------------------+
//| Close All Positions                                              |
//+------------------------------------------------------------------+
void CloseAllPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket =
         PositionGetTicket(i);


      if(ticket == 0)
         continue;


      if(
         PositionGetString(POSITION_SYMBOL)
         !=
         _Symbol
      )
         continue;


      if(
         (ulong)PositionGetInteger(POSITION_MAGIC)
         !=
         Magic
      )
         continue;


      bool result =
         trade.PositionClose(
            ticket,
            SlippagePoint
         );


      if(
         !result ||
         !IsTradeSuccess()
      )
      {
         Print(
            "CLOSE FAILED",
            " | Ticket=", ticket,
            " | Retcode=", trade.ResultRetcode(),
            " | ",
            trade.ResultRetcodeDescription()
         );
      }
      else
      {
         Print(
            "POSITION CLOSED",
            " | Ticket=", ticket
         );
      }
   }
}

//+------------------------------------------------------------------+
//| Get Volume Digits                                                |
//+------------------------------------------------------------------+
int GetVolumeDigits(double step)
{
   int digits = 0;

   while(step < 1.0 && digits < 8)
   {
      step *= 10.0;
      digits++;
   }

   return digits;
}


//+------------------------------------------------------------------+
//| Normalize Volume Up                                              |
//+------------------------------------------------------------------+
double NormalizeVolumeUp(double volume)
{
   double minVolume = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxVolume = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step      = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(step <= 0)
      step = minVolume;

   if(minVolume <= 0 || step <= 0)
      return 0;

   volume = MathMax(volume, minVolume);
   volume = MathCeil((volume / step) - 1e-10) * step;

   if(volume > maxVolume)
      return 0;

   return NormalizeDouble(volume, GetVolumeDigits(step));
}


//+------------------------------------------------------------------+
//| Normalize Volume Down                                            |
//+------------------------------------------------------------------+
double NormalizeVolumeDown(double volume)
{
   double minVolume = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxVolume = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step      = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(step <= 0)
      step = minVolume;

   if(minVolume <= 0 || step <= 0)
      return 0;

   volume = MathMin(volume, maxVolume);
   volume = MathFloor((volume / step) + 1e-10) * step;

   if(volume < minVolume)
      return 0;

   return NormalizeDouble(volume, GetVolumeDigits(step));
}


//+------------------------------------------------------------------+
//| Calculate Recovery Lot                                           |
//| Project Basket ไปยัง RecoveryTargetPoint แล้วหา lot ที่ทำให้     |
//| projected total profit ถึง BasketTargetProfit                    |
//+------------------------------------------------------------------+
double CalculateRecoveryLot(
   ENUM_ORDER_TYPE recoveryType,
   double currentBasketProfit
)
{
   if(recoveryType != ORDER_TYPE_BUY && recoveryType != ORDER_TYPE_SELL)
      return 0;

   if(RecoveryTargetPoint <= 0)
      return 0;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(bid <= 0 || ask <= 0)
      return 0;

   double move = RecoveryTargetPoint * _Point;

   double targetBid = bid;
   double targetAsk = ask;

   if(recoveryType == ORDER_TYPE_BUY)
   {
      targetBid = bid + move;
      targetAsk = ask + move;
   }
   else
   {
      targetBid = bid - move;
      targetAsk = ask - move;
   }

   if(targetBid <= 0 || targetAsk <= 0)
      return 0;

   double existingPositionDelta = 0;

   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if((ulong)PositionGetInteger(POSITION_MAGIC) != Magic)
         continue;

      ENUM_POSITION_TYPE positionType =
         (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      double volume = PositionGetDouble(POSITION_VOLUME);
      double delta = 0;
      bool calculated = false;

      if(positionType == POSITION_TYPE_BUY)
      {
         calculated = OrderCalcProfit(
            ORDER_TYPE_BUY,
            _Symbol,
            volume,
            bid,
            targetBid,
            delta
         );
      }
      else if(positionType == POSITION_TYPE_SELL)
      {
         calculated = OrderCalcProfit(
            ORDER_TYPE_SELL,
            _Symbol,
            volume,
            ask,
            targetAsk,
            delta
         );
      }

      if(!calculated)
      {
         Print(
            "RECOVERY LOT CALC FAILED",
            " | ExistingTicket=", ticket,
            " | Error=", GetLastError()
         );
         return 0;
      }

      existingPositionDelta += delta;
   }

   double projectedWithoutRecovery =
      currentBasketProfit + existingPositionDelta;

   double profitPerLot = 0;
   bool calculated = false;

   if(recoveryType == ORDER_TYPE_BUY)
   {
      calculated = OrderCalcProfit(
         ORDER_TYPE_BUY,
         _Symbol,
         1.0,
         ask,
         targetBid,
         profitPerLot
      );
   }
   else
   {
      calculated = OrderCalcProfit(
         ORDER_TYPE_SELL,
         _Symbol,
         1.0,
         bid,
         targetAsk,
         profitPerLot
      );
   }

   if(!calculated || profitPerLot <= 0)
   {
      Print(
         "RECOVERY LOT CALC FAILED",
         " | ProfitPerLot=", profitPerLot,
         " | Error=", GetLastError()
      );
      return 0;
   }

   double requiredProfit =
      BasketTargetProfit - projectedWithoutRecovery;

   if(requiredProfit <= 0)
   {
      Print(
         "RECOVERY NOT REQUIRED",
         " | Current=", currentBasketProfit,
         " | Projected=", projectedWithoutRecovery,
         " | Target=", BasketTargetProfit
      );
      return 0;
   }

   double rawLot = requiredProfit / profitPerLot;
   double recoveryLot = NormalizeVolumeUp(rawLot);

   if(recoveryLot <= 0)
      return 0;

   // Partial recovery: ถ้า lot เกินเพดาน ให้เปิดเท่าที่ MaxRecoveryLot
   if(recoveryLot > MaxRecoveryLot)
   {
      double cappedLot = NormalizeVolumeDown(MaxRecoveryLot);

      if(cappedLot <= 0)
         return 0;

      Print(
         "RECOVERY LOT CAPPED",
         " | RequiredLot=", recoveryLot,
         " | CappedLot=", cappedLot,
         " | MaxRecoveryLot=", MaxRecoveryLot
      );

      recoveryLot = cappedLot;
   }

   Print(
      "RECOVERY LOT CALCULATED",
      " | Type=", recoveryType == ORDER_TYPE_BUY ? "BUY" : "SELL",
      " | CurrentBasket=", currentBasketProfit,
      " | ProjectedWithoutRecovery=", projectedWithoutRecovery,
      " | RequiredProfit=", requiredProfit,
      " | ProfitPerLot=", profitPerLot,
      " | RawLot=", rawLot,
      " | RecoveryLot=", recoveryLot,
      " | TargetPoint=", RecoveryTargetPoint
   );

   return recoveryLot;
}


//+------------------------------------------------------------------+
//| Open Recovery Sell                                               |
//+------------------------------------------------------------------+
bool OpenRecoverySell(double recoveryLot)
{
   if(recoveryLot <= 0)
      return false;

   bool result = trade.Sell(
      recoveryLot,
      _Symbol,
      0,
      0,
      0,
      "Recovery SELL"
   );

   if(!result || !IsTradeSuccess())
   {
      Print(
         "RECOVERY SELL FAILED",
         " | Lot=", recoveryLot,
         " | Retcode=", trade.ResultRetcode(),
         " | ", trade.ResultRetcodeDescription()
      );
      return false;
   }

   Print(
      "RECOVERY SELL",
      " | Lot=", recoveryLot,
      " | Price=", trade.ResultPrice()
   );

   return true;
}


//+------------------------------------------------------------------+
//| Open Recovery Buy                                                |
//+------------------------------------------------------------------+
bool OpenRecoveryBuy(double recoveryLot)
{
   if(recoveryLot <= 0)
      return false;

   bool result = trade.Buy(
      recoveryLot,
      _Symbol,
      0,
      0,
      0,
      "Recovery BUY"
   );

   if(!result || !IsTradeSuccess())
   {
      Print(
         "RECOVERY BUY FAILED",
         " | Lot=", recoveryLot,
         " | Retcode=", trade.ResultRetcode(),
         " | ", trade.ResultRetcodeDescription()
      );
      return false;
   }

   Print(
      "RECOVERY BUY",
      " | Lot=", recoveryLot,
      " | Price=", trade.ResultPrice()
   );

   return true;
}


//+------------------------------------------------------------------+
//| Manage Recovery - Profit + Distance                              |
//+------------------------------------------------------------------+
void ManageRecovery()
{
   double buyProfit = 0;
   double sellProfit = 0;
   double totalProfit = 0;

   double buyVolume = 0;
   double sellVolume = 0;

   double buyOpenValue = 0;
   double sellOpenValue = 0;

   int recoveryPositions = 0;

   double latestRecoveryBuyPrice = 0;
   double latestRecoverySellPrice = 0;

   long latestRecoveryBuyTime = 0;
   long latestRecoverySellTime = 0;

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

      double profit = PositionGetDouble(POSITION_PROFIT);
      double volume = PositionGetDouble(POSITION_VOLUME);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      long positionTime = PositionGetInteger(POSITION_TIME_MSC);
      string comment = PositionGetString(POSITION_COMMENT);

      totalProfit += profit;

      if(type == POSITION_TYPE_BUY)
      {
         buyProfit += profit;
         buyVolume += volume;
         buyOpenValue += openPrice * volume;

         if(StringFind(comment, "Recovery BUY") >= 0)
         {
            recoveryPositions++;

            if(positionTime > latestRecoveryBuyTime)
            {
               latestRecoveryBuyTime = positionTime;
               latestRecoveryBuyPrice = openPrice;
            }
         }
      }
      else if(type == POSITION_TYPE_SELL)
      {
         sellProfit += profit;
         sellVolume += volume;
         sellOpenValue += openPrice * volume;

         if(StringFind(comment, "Recovery SELL") >= 0)
         {
            recoveryPositions++;

            if(positionTime > latestRecoverySellTime)
            {
               latestRecoverySellTime = positionTime;
               latestRecoverySellPrice = openPrice;
            }
         }
      }
   }

   // ต้องมีทั้ง BUY และ SELL ก่อนจึงเข้าสู่ recovery basket
   if(buyVolume <= 0 || sellVolume <= 0)
      return;

   // กำไรรวมถึงเป้า -> ปิดทั้งหมด
   if(totalProfit >= BasketTargetProfit)
   {
      Print(
         "BASKET TARGET",
         " | Total=", totalProfit,
         " | BuyProfit=", buyProfit,
         " | SellProfit=", sellProfit,
         " | BuyVolume=", buyVolume,
         " | SellVolume=", sellVolume
      );

      CloseAllPositions();
      return;
   }

   // Stop Loss ระดับ Basket
   if(MaxBasketLoss > 0 && totalProfit <= -MaxBasketLoss)
   {
      Print(
         "MAX BASKET LOSS",
         " | Total=", totalProfit,
         " | Limit=-", MaxBasketLoss,
         " | BuyVolume=", buyVolume,
         " | SellVolume=", sellVolume
      );

      CloseAllPositions();
      return;
   }

   if(recoveryPositions >= MaxRecoveryPositions)
      return;

   if(RecoveryTriggerPoint <= 0)
      return;

   double buyAveragePrice = buyOpenValue / buyVolume;
   double sellAveragePrice = sellOpenValue / sellVolume;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(bid <= 0 || ask <= 0)
      return;

   double volumeStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(volumeStep <= 0)
      volumeStep = 0.01;

   double volumeTolerance = volumeStep / 2.0;
   bool volumeBalanced =
      MathAbs(buyVolume - sellVolume) < volumeTolerance;

   //============================================================
   // BALANCED VOLUME
   // ฝั่งที่กำไร และราคาเดินต่อครบ distance -> recovery ฝั่งนั้น
   //============================================================
   if(volumeBalanced)
   {
      if(buyProfit >= MinRecoveryProfit && buyProfit > sellProfit)
      {
         double referencePrice =
            latestRecoveryBuyPrice > 0
            ? latestRecoveryBuyPrice
            : buyAveragePrice;

         double distance = (bid - referencePrice) / _Point;

         if(distance < RecoveryTriggerPoint)
            return;

         double recoveryLot =
            CalculateRecoveryLot(ORDER_TYPE_BUY, totalProfit);

         if(recoveryLot <= 0)
            return;

         if(OpenRecoveryBuy(recoveryLot))
         {
            Print(
               "PROFIT DISTANCE RECOVERY",
               " | Direction=BUY",
               " | Mode=BALANCED",
               " | BuyProfit=", buyProfit,
               " | SellProfit=", sellProfit,
               " | BuyVolume=", buyVolume,
               " | SellVolume=", sellVolume,
               " | Reference=", referencePrice,
               " | Distance=", distance,
               " | Lot=", recoveryLot
            );
         }

         return;
      }

      if(sellProfit >= MinRecoveryProfit && sellProfit > buyProfit)
      {
         double referencePrice =
            latestRecoverySellPrice > 0
            ? latestRecoverySellPrice
            : sellAveragePrice;

         double distance = (referencePrice - ask) / _Point;

         if(distance < RecoveryTriggerPoint)
            return;

         double recoveryLot =
            CalculateRecoveryLot(ORDER_TYPE_SELL, totalProfit);

         if(recoveryLot <= 0)
            return;

         if(OpenRecoverySell(recoveryLot))
         {
            Print(
               "PROFIT DISTANCE RECOVERY",
               " | Direction=SELL",
               " | Mode=BALANCED",
               " | BuyProfit=", buyProfit,
               " | SellProfit=", sellProfit,
               " | BuyVolume=", buyVolume,
               " | SellVolume=", sellVolume,
               " | Reference=", referencePrice,
               " | Distance=", distance,
               " | Lot=", recoveryLot
            );
         }

         return;
      }

      return;
   }

   //============================================================
   // NET BUY -> candidate SELL
   //============================================================
   if(buyVolume > sellVolume)
   {
      if(sellProfit < MinRecoveryProfit)
         return;

      double referencePrice =
         latestRecoverySellPrice > 0
         ? latestRecoverySellPrice
         : sellAveragePrice;

      double distance = (referencePrice - ask) / _Point;

      if(distance < RecoveryTriggerPoint)
         return;

      double recoveryLot =
         CalculateRecoveryLot(ORDER_TYPE_SELL, totalProfit);

      if(recoveryLot <= 0)
         return;

      if(OpenRecoverySell(recoveryLot))
      {
         Print(
            "PROFIT DISTANCE RECOVERY",
            " | Direction=SELL",
            " | Mode=NET_BUY",
            " | SellProfit=", sellProfit,
            " | BuyVolume=", buyVolume,
            " | SellVolume=", sellVolume,
            " | Reference=", referencePrice,
            " | Distance=", distance,
            " | Lot=", recoveryLot
         );
      }

      return;
   }

   //============================================================
   // NET SELL -> candidate BUY
   //============================================================
   if(sellVolume > buyVolume)
   {
      if(buyProfit < MinRecoveryProfit)
         return;

      double referencePrice =
         latestRecoveryBuyPrice > 0
         ? latestRecoveryBuyPrice
         : buyAveragePrice;

      double distance = (bid - referencePrice) / _Point;

      if(distance < RecoveryTriggerPoint)
         return;

      double recoveryLot =
         CalculateRecoveryLot(ORDER_TYPE_BUY, totalProfit);

      if(recoveryLot <= 0)
         return;

      if(OpenRecoveryBuy(recoveryLot))
      {
         Print(
            "PROFIT DISTANCE RECOVERY",
            " | Direction=BUY",
            " | Mode=NET_SELL",
            " | BuyProfit=", buyProfit,
            " | BuyVolume=", buyVolume,
            " | SellVolume=", sellVolume,
            " | Reference=", referencePrice,
            " | Distance=", distance,
            " | Lot=", recoveryLot
         );
      }

      return;
   }
}

