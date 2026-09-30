//+------------------------------------------------------------------+
//|                                                         stop.mq5 |
//|                                  Copyright 2025, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+

// Description: 

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

input int DistancePoint = 1500;

input int SlippagePoint = 20;

input ulong Magic = 10001;

input int TrendBars = 3;

input int TrendStartShift = 3;

input double BasketTargetProfit = 1.0;

input double MinRecoveryProfit = 1.0;

input int RecoveryStepPoint = 500;

input int MaxRecoveryPositions = 5;


//==================================================================
// GLOBAL
//==================================================================

MqlRates prices[];

int PendingBuy = 0;
int PendingSell = 0;

int PositionBuy = 0;
int PositionSell = 0;

double LastRecoveryPrice = 0;

//  1 = BUY recovery
// -1 = SELL recovery
//  0 = ยังไม่เริ่ม recovery
int RecoveryDirection = 0;


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
//| Open Recovery Sell                                               |
//+------------------------------------------------------------------+
bool OpenRecoverySell()
{
   bool result =
      trade.Sell(
         LotSize,
         _Symbol,
         0,
         0,
         0,
         "Recovery SELL"
      );


   if(
      !result ||
      !IsTradeSuccess()
   )
   {
      Print(
         "RECOVERY SELL FAILED",
         " | Retcode=", trade.ResultRetcode(),
         " | ",
         trade.ResultRetcodeDescription()
      );

      return false;
   }


   Print(
      "RECOVERY SELL",
      " | Lot=", LotSize,
      " | Price=", trade.ResultPrice()
   );


   return true;
}

//+------------------------------------------------------------------+
//| Open Recovery Buy                                                |
//+------------------------------------------------------------------+
bool OpenRecoveryBuy()
{
   bool result =
      trade.Buy(
         LotSize,
         _Symbol,
         0,
         0,
         0,
         "Recovery BUY"
      );


   if(
      !result ||
      !IsTradeSuccess()
   )
   {
      Print(
         "RECOVERY BUY FAILED",
         " | Retcode=", trade.ResultRetcode(),
         " | ",
         trade.ResultRetcodeDescription()
      );

      return false;
   }


   Print(
      "RECOVERY BUY",
      " | Lot=", LotSize,
      " | Price=", trade.ResultPrice()
   );


   return true;
}

//+------------------------------------------------------------------+
//| Manage Hedge Recovery                                            |
//+------------------------------------------------------------------+
void ManageRecovery()
{
   double buyProfit = 0;
   double sellProfit = 0;
   double totalProfit = 0;

   int buyCount = 0;
   int sellCount = 0;

   int recoveryBuyCount = 0;
   int recoverySellCount = 0;

   long latestRecoveryTime = 0;
   double latestRecoveryPrice = 0;
   int latestRecoveryDirection = 0;


   //===============================================================
   // CALCULATE BASKET
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


      double profit =
         PositionGetDouble(
            POSITION_PROFIT
         );


      string comment =
         PositionGetString(
            POSITION_COMMENT
         );


      double openPrice =
         PositionGetDouble(
            POSITION_PRICE_OPEN
         );


      long positionTime =
         PositionGetInteger(
            POSITION_TIME_MSC
         );


      totalProfit += profit;


      //============================================================
      // BUY
      //============================================================
      if(type == POSITION_TYPE_BUY)
      {
         buyProfit += profit;

         buyCount++;


         if(StringFind(comment, "Recovery BUY") >= 0)
         {
            recoveryBuyCount++;


            if(positionTime > latestRecoveryTime)
            {
               latestRecoveryTime = positionTime;
               latestRecoveryPrice = openPrice;
               latestRecoveryDirection = 1;
            }
         }
      }


      //============================================================
      // SELL
      //============================================================
      else
      if(type == POSITION_TYPE_SELL)
      {
         sellProfit += profit;

         sellCount++;


         if(StringFind(comment, "Recovery SELL") >= 0)
         {
            recoverySellCount++;


            if(positionTime > latestRecoveryTime)
            {
               latestRecoveryTime = positionTime;
               latestRecoveryPrice = openPrice;
               latestRecoveryDirection = -1;
            }
         }
      }
   }


   //===============================================================
   // ต้องมีทั้ง BUY และ SELL ก่อนจึงเริ่ม Recovery
   //===============================================================
   if(
      buyCount == 0 ||
      sellCount == 0
   )
   {
      RecoveryDirection = 0;
      LastRecoveryPrice = 0;

      return;
   }


   //===============================================================
   // BASKET PROFIT ถึงเป้า -> ปิดทั้งหมด
   //===============================================================
   if(totalProfit >= BasketTargetProfit)
   {
      Print(
         "BASKET TARGET",
         " | Total=", totalProfit,
         " | Buy=", buyProfit,
         " | Sell=", sellProfit
      );


      CloseAllPositions();


      RecoveryDirection = 0;
      LastRecoveryPrice = 0;

      return;
   }


   //===============================================================
   // COUNT RECOVERY POSITIONS จริง
   //===============================================================
   int recoveryPositions =
      recoveryBuyCount +
      recoverySellCount;


   if(recoveryPositions >= MaxRecoveryPositions)
      return;


   //===============================================================
   // RECOVER POSITION จากโค้ดเก่าเป็น BUY และ SELL ปนกัน
   // ห้ามเปิดเพิ่มเพื่อไม่ให้สลับฝั่งมั่วอีก
   //===============================================================
   if(
      recoveryBuyCount > 0 &&
      recoverySellCount > 0
   )
   {
      Print(
         "RECOVERY LOCK CONFLICT",
         " | RecoveryBuy=", recoveryBuyCount,
         " | RecoverySell=", recoverySellCount,
         " | No new recovery will be opened"
      );

      return;
   }


   //===============================================================
   // RECOVER DIRECTION
   //
   // สำคัญ:
   // - ต้องมีฝั่งใดฝั่งหนึ่งกำไร >= MinRecoveryProfit ก่อน
   // - ห้ามใช้แค่ BUY > SELL เพราะ -2 > -3 ก็เป็นจริง
   // - เมื่อเลือกฝั่งแล้วให้ LOCK ฝั่งนั้นจนจบรอบ
   //===============================================================
   if(RecoveryDirection == 0)
   {
      // ถ้ามี Recovery ค้างอยู่ เช่น EA restart
      // ให้ Restore direction จาก Position ที่มีอยู่
      if(recoveryBuyCount > 0)
      {
         RecoveryDirection = 1;
      }
      else
      if(recoverySellCount > 0)
      {
         RecoveryDirection = -1;
      }

      // ยังไม่เคย Recovery
      // เริ่มได้เมื่อฝั่งที่ชนะมีกำไร >= MinRecoveryProfit เท่านั้น
      else
      {
         if(
            buyProfit >= MinRecoveryProfit &&
            buyProfit > sellProfit
         )
         {
            RecoveryDirection = 1;
         }
         else
         if(
            sellProfit >= MinRecoveryProfit &&
            sellProfit > buyProfit
         )
         {
            RecoveryDirection = -1;
         }
         else
         {
            // BUY และ SELL ยังติดลบทั้งคู่
            // หรือยังไม่มีฝั่งกำไรชัดเจน
            return;
         }
      }
   }


   //===============================================================
   // RESTORE LAST RECOVERY PRICE
   // กรณี EA restart / re-init
   //===============================================================
   if(
      LastRecoveryPrice == 0 &&
      recoveryPositions > 0 &&
      latestRecoveryDirection == RecoveryDirection
   )
   {
      LastRecoveryPrice =
         latestRecoveryPrice;
   }


   //===============================================================
   // FIRST RECOVERY
   // เปิดเมื่อมี BUY/SELL อยู่แล้ว และมีฝั่งกำไร >= MinRecoveryProfit
   //===============================================================
   if(recoveryPositions == 0)
   {
      if(RecoveryDirection == 1)
      {
         // BUY ต้องมีกำไรถึงขั้นต่ำก่อนเปิด Recovery
         if(buyProfit < MinRecoveryProfit)
            return;


         if(OpenRecoveryBuy())
         {
            LastRecoveryPrice =
               trade.ResultPrice();


            Print(
               "RECOVERY DIRECTION LOCKED",
               " | BUY",
               " | BuyProfit=", buyProfit,
               " | SellProfit=", sellProfit,
               " | Total=", totalProfit,
               " | Price=", LastRecoveryPrice
            );
         }
      }
      else
      if(RecoveryDirection == -1)
      {
         // SELL ต้องมีกำไรถึงขั้นต่ำก่อนเปิด Recovery
         if(sellProfit < MinRecoveryProfit)
            return;


         if(OpenRecoverySell())
         {
            LastRecoveryPrice =
               trade.ResultPrice();


            Print(
               "RECOVERY DIRECTION LOCKED",
               " | SELL",
               " | BuyProfit=", buyProfit,
               " | SellProfit=", sellProfit,
               " | Total=", totalProfit,
               " | Price=", LastRecoveryPrice
            );
         }
      }


      return;
   }


   //===============================================================
   // BUY RECOVERY
   // เมื่อ Lock BUY แล้ว จะไม่เปลี่ยนไป SELL กลางรอบ
   //===============================================================
   if(RecoveryDirection == 1)
   {
      // ฝั่ง BUY ต้องยังมีกำไรรวมถึงขั้นต่ำ
      // ถ้ายังไม่ถึง ให้รอ ไม่เปิดเพิ่ม และไม่สลับฝั่ง
      if(buyProfit < MinRecoveryProfit)
         return;


      double ask =
         SymbolInfoDouble(
            _Symbol,
            SYMBOL_ASK
         );


      if(
         ask <= 0 ||
         LastRecoveryPrice <= 0
      )
         return;


      double distance =
         (ask - LastRecoveryPrice)
         /
         _Point;


      // ราคาต้องวิ่งต่อในทิศ BUY อีก RecoveryStepPoint
      if(distance >= RecoveryStepPoint)
      {
         if(OpenRecoveryBuy())
         {
            LastRecoveryPrice =
               trade.ResultPrice();


            Print(
               "RECOVERY BUY ADDED",
               " | Step=", distance,
               " | BuyProfit=", buyProfit,
               " | SellProfit=", sellProfit,
               " | Total=", totalProfit,
               " | RecoveryCount=", recoveryPositions + 1,
               " | Price=", LastRecoveryPrice
            );
         }
      }


      return;
   }


   //===============================================================
   // SELL RECOVERY
   // เมื่อ Lock SELL แล้ว จะไม่เปลี่ยนไป BUY กลางรอบ
   //===============================================================
   if(RecoveryDirection == -1)
   {
      // ฝั่ง SELL ต้องยังมีกำไรรวมถึงขั้นต่ำ
      // ถ้ายังไม่ถึง ให้รอ ไม่เปิดเพิ่ม และไม่สลับฝั่ง
      if(sellProfit < MinRecoveryProfit)
         return;


      double bid =
         SymbolInfoDouble(
            _Symbol,
            SYMBOL_BID
         );


      if(
         bid <= 0 ||
         LastRecoveryPrice <= 0
      )
         return;


      double distance =
         (LastRecoveryPrice - bid)
         /
         _Point;


      // ราคาต้องวิ่งต่อในทิศ SELL อีก RecoveryStepPoint
      if(distance >= RecoveryStepPoint)
      {
         if(OpenRecoverySell())
         {
            LastRecoveryPrice =
               trade.ResultPrice();


            Print(
               "RECOVERY SELL ADDED",
               " | Step=", distance,
               " | BuyProfit=", buyProfit,
               " | SellProfit=", sellProfit,
               " | Total=", totalProfit,
               " | RecoveryCount=", recoveryPositions + 1,
               " | Price=", LastRecoveryPrice
            );
         }
      }


      return;
   }
}

