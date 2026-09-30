//+------------------------------------------------------------------+
//|                                           pricesactionv1.mq5     |
//|                                  Copyright 2025, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+

#property copyright "Copyright 2025, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "1.00"

#include <Trade/Trade.mqh>

CTrade trade;


//==================================================================
// GLOBAL INPUT
//==================================================================

// จำนวนแท่งที่โหลด
input int CandleRate = 100;

// Lot ต่อ Order
input double LotSize = 0.01;

// Risk Reward
input double RR = 1.5;

// Magic Number
input ulong Magic = 10001;

// จำนวน structure ที่ใช้ตรวจ Trend
input int TrendBars = 3;

// เริ่มตรวจ Trend จากแท่งไหน
// [1] = Bullish signal
// [2] = Bearish signal
// ดังนั้นเริ่ม Trend ที่ [3]
input int TrendStartShift = 3;


//==================================================================
// GLOBAL
//==================================================================

MqlRates prices[];


//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   // กำหนด Magic Number
   trade.SetExpertMagicNumber(Magic);

   // Filling Mode ตาม Symbol
   trade.SetTypeFillingBySymbol(_Symbol);

   Print(
      "EA Started",
      " | Symbol=", _Symbol,
      " | Period=", EnumToString(_Period),
      " | Magic=", Magic
   );

   return(INIT_SUCCEEDED);
}


//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Print(
      "EA Stopped",
      " | Reason=", reason
   );
}


//+------------------------------------------------------------------+
//| Expert tick                                                      |
//+------------------------------------------------------------------+
void OnTick()
{
   //===============================================================
   // 1. โหลดราคา
   //===============================================================

   if(!LoadPrices(CandleRate))
      return;


   //===============================================================
   // 2. ทำงานเฉพาะตอนเกิดแท่งใหม่
   //===============================================================

   if(!IsNewBar())
      return;


   Print(
      "=============================================="
   );


   //===============================================================
   // 3. ตรวจ Trend Up
   //===============================================================

   bool upTrend =
      IsUpTrend(
         TrendStartShift,
         TrendBars
      );


   if(!upTrend)
   {
      Print(
         "NO UP TREND"
      );

      Print(
         "=============================================="
      );

      return;
   }


   Print(
      "UP TREND FOUND"
   );


   //===============================================================
   // 4. ตรวจ Bullish Pattern
   //===============================================================

   if(!BullishCandle())
   {
      Print(
         "NO BULLISH SIGNAL"
      );

      Print(
         "=============================================="
      );

      return;
   }


   Print(
      "UP TREND + BULLISH SIGNAL FOUND"
   );


   Print(
      "Signal Candle Time = ",
      TimeToString(
         prices[1].time,
         TIME_DATE | TIME_MINUTES
      )
   );


   //===============================================================
   // 5. Clear Pending Order เก่า
   //===============================================================

   if(!ClearOldPendingOrders())
   {
      Print(
         "Cannot clear old pending orders"
      );

      Print(
         "New pending orders CANCELLED"
      );

      Print(
         "=============================================="
      );

      return;
   }


   //===============================================================
   // 6. สร้าง Pending Order ใหม่ 3 ไม้
   //===============================================================

   CalculateBuyLimits();


   Print(
      "=============================================="
   );
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


   int copied =
      CopyRates(
         _Symbol,
         _Period,
         0,
         candle,
         prices
      );


   // อย่างน้อยต้องมีข้อมูลสำหรับ Trend
   int minimumBars =
      TrendStartShift +
      TrendBars +
      1;


   if(copied < minimumBars)
   {
      Print(
         "CopyRates failed",
         " | copied=", copied,
         " | required=", minimumBars
      );

      return false;
   }


   return true;
}


//+------------------------------------------------------------------+
//| Check New Bar                                                    |
//+------------------------------------------------------------------+
bool IsNewBar()
{
   static datetime lastBarTime = 0;


   datetime currentBarTime =
      prices[0].time;


   //---------------------------------------------------------------
   // ตอนเปิด EA ครั้งแรก
   //---------------------------------------------------------------

   if(lastBarTime == 0)
   {
      lastBarTime =
         currentBarTime;

      return false;
   }


   //---------------------------------------------------------------
   // มีแท่งใหม่
   //---------------------------------------------------------------

   if(currentBarTime != lastBarTime)
   {
      lastBarTime =
         currentBarTime;

      return true;
   }


   return false;
}


//+------------------------------------------------------------------+
//| Check Up Trend                                                   |
//| Higher High + Higher Low                                         |
//+------------------------------------------------------------------+
bool IsUpTrend(
   const int startShift,
   const int bars
)
{
   //---------------------------------------------------------------
   // Validation
   //---------------------------------------------------------------

   if(bars <= 0)
      return false;


   if(startShift < 1)
      return false;


   int requiredSize =
      startShift +
      bars +
      1;


   if(ArraySize(prices) < requiredSize)
   {
      Print(
         "Not enough data for trend",
         " | Size=", ArraySize(prices),
         " | Required=", requiredSize
      );

      return false;
   }


   //---------------------------------------------------------------
   // ตรวจ Higher High + Higher Low
   //
   // ตัวอย่าง:
   //
   // prices[3] > prices[4]
   // prices[4] > prices[5]
   // prices[5] > prices[6]
   //
   //---------------------------------------------------------------

   for(
      int i = startShift;
      i < startShift + bars;
      i++
   )
   {
      double currentHigh =
         prices[i].high;

      double previousHigh =
         prices[i + 1].high;


      double currentLow =
         prices[i].low;

      double previousLow =
         prices[i + 1].low;


      //------------------------------------------------------------
      // Higher High
      //------------------------------------------------------------

      if(currentHigh <= previousHigh)
      {
         Print(
            "UP TREND FAILED",
            " | Candle[", i, "]",
            " High=", currentHigh,
            " <= Candle[", i + 1, "]",
            " High=", previousHigh
         );

         return false;
      }


      //------------------------------------------------------------
      // Higher Low
      //------------------------------------------------------------

      if(currentLow <= previousLow)
      {
         Print(
            "UP TREND FAILED",
            " | Candle[", i, "]",
            " Low=", currentLow,
            " <= Candle[", i + 1, "]",
            " Low=", previousLow
         );

         return false;
      }
   }


   Print(
      "TREND STRUCTURE = UP",
      " | Start=[", startShift, "]",
      " | Bars=", bars
   );


   return true;
}


//+------------------------------------------------------------------+
//| Check Bullish Candle                                             |
//+------------------------------------------------------------------+
bool BullishCandle()
{
   //---------------------------------------------------------------
   // Candle [1] ต้องเป็น Bullish
   //---------------------------------------------------------------

   if(prices[1].close <= prices[1].open)
      return false;


   //---------------------------------------------------------------
   // Candle [2] ต้องเป็น Bearish
   //---------------------------------------------------------------

   if(prices[2].close >= prices[2].open)
      return false;


   //---------------------------------------------------------------
   // Bullish Body
   //---------------------------------------------------------------

   double bullishBody =
      prices[1].close -
      prices[1].open;


   //---------------------------------------------------------------
   // Bearish Body
   //---------------------------------------------------------------

   double bearishBody =
      prices[2].open -
      prices[2].close;


   //---------------------------------------------------------------
   // Print Debug
   //---------------------------------------------------------------

   Print(
      "Bullish Body=", bullishBody,
      " | Bearish Body=", bearishBody
   );


   //---------------------------------------------------------------
   // Bullish Body ต้องใหญ่กว่า Bearish Body
   //---------------------------------------------------------------

   if(bullishBody <= bearishBody)
      return false;


   return true;
}


//+------------------------------------------------------------------+
//| Check Pending Order Type                                         |
//+------------------------------------------------------------------+
bool IsPendingOrderType(
   ENUM_ORDER_TYPE type
)
{
   if(
      type == ORDER_TYPE_BUY_LIMIT       ||
      type == ORDER_TYPE_SELL_LIMIT      ||
      type == ORDER_TYPE_BUY_STOP        ||
      type == ORDER_TYPE_SELL_STOP       ||
      type == ORDER_TYPE_BUY_STOP_LIMIT  ||
      type == ORDER_TYPE_SELL_STOP_LIMIT
   )
   {
      return true;
   }


   return false;
}


//+------------------------------------------------------------------+
//| Clear Old Pending Orders                                         |
//+------------------------------------------------------------------+
bool ClearOldPendingOrders()
{
   int total =
      OrdersTotal();


   int foundCount   = 0;
   int deletedCount = 0;

   bool allSuccess =
      true;


   //---------------------------------------------------------------
   // Loop จากท้ายมาหน้า
   //---------------------------------------------------------------

   for(
      int i = total - 1;
      i >= 0;
      i--
   )
   {
      //------------------------------------------------------------
      // Get Ticket
      //------------------------------------------------------------

      ulong ticket =
         OrderGetTicket(i);


      if(ticket == 0)
         continue;


      //------------------------------------------------------------
      // Symbol
      //------------------------------------------------------------

      string symbol =
         OrderGetString(
            ORDER_SYMBOL
         );


      if(symbol != _Symbol)
         continue;


      //------------------------------------------------------------
      // Magic Number
      //------------------------------------------------------------

      ulong orderMagic =
         (ulong)OrderGetInteger(
            ORDER_MAGIC
         );


      if(orderMagic != Magic)
         continue;


      //------------------------------------------------------------
      // Order Type
      //------------------------------------------------------------

      ENUM_ORDER_TYPE type =
         (ENUM_ORDER_TYPE)
         OrderGetInteger(
            ORDER_TYPE
         );


      //------------------------------------------------------------
      // เอาเฉพาะ Pending
      //------------------------------------------------------------

      if(!IsPendingOrderType(type))
         continue;


      foundCount++;


      //------------------------------------------------------------
      // Old Entry
      //------------------------------------------------------------

      double oldPrice =
         OrderGetDouble(
            ORDER_PRICE_OPEN
         );


      Print(
         "DELETE OLD PENDING",
         " | Ticket=", ticket,
         " | Type=", EnumToString(type),
         " | Price=", oldPrice
      );


      //------------------------------------------------------------
      // Delete
      //------------------------------------------------------------

      bool deleted =
         trade.OrderDelete(
            ticket
         );


      uint retcode =
         trade.ResultRetcode();


      //------------------------------------------------------------
      // Success
      //------------------------------------------------------------

      if(
         deleted &&
         retcode == TRADE_RETCODE_DONE
      )
      {
         deletedCount++;


         Print(
            "DELETE SUCCESS",
            " | Ticket=", ticket,
            " | Retcode=", retcode,
            " | ",
            trade.ResultRetcodeDescription()
         );
      }


      //------------------------------------------------------------
      // Failed
      //------------------------------------------------------------

      else
      {
         allSuccess =
            false;


         Print(
            "DELETE FAILED",
            " | Ticket=", ticket,
            " | Retcode=", retcode,
            " | ",
            trade.ResultRetcodeDescription()
         );
      }
   }


   //---------------------------------------------------------------
   // ไม่มี Pending เก่า
   //---------------------------------------------------------------

   if(foundCount == 0)
   {
      Print(
         "No old pending orders found"
      );

      return true;
   }


   //---------------------------------------------------------------
   // Summary
   //---------------------------------------------------------------

   Print(
      "Clear Pending Summary",
      " | Found=", foundCount,
      " | Deleted=", deletedCount
   );


   //---------------------------------------------------------------
   // ลบไม่ครบ
   //---------------------------------------------------------------

   if(!allSuccess)
   {
      Print(
         "Some pending orders could not be deleted"
      );

      return false;
   }


   return true;
}


//+------------------------------------------------------------------+
//| Calculate Buy Limits                                             |
//+------------------------------------------------------------------+
void CalculateBuyLimits()
{
   //---------------------------------------------------------------
   // Bullish Body ของ Candle [1]
   //---------------------------------------------------------------

   double bullishBody =
      prices[1].close -
      prices[1].open;


   if(bullishBody <= 0)
      return;


   //---------------------------------------------------------------
   // Body / 3
   //---------------------------------------------------------------

   double step =
      bullishBody / 3.0;


   //---------------------------------------------------------------
   // Entry 1
   //
   // Open ของ Bullish Candle
   //---------------------------------------------------------------

   double entry1 =
      prices[1].open;


   //---------------------------------------------------------------
   // Entry 2
   //
   // 1/3 ของ Body
   //---------------------------------------------------------------

   double entry2 =
      prices[1].open +
      step;


   //---------------------------------------------------------------
   // Entry 3
   //
   // 2/3 ของ Body
   //---------------------------------------------------------------

   double entry3 =
      prices[1].open +
      (step * 2.0);


   //---------------------------------------------------------------
   // SL
   //
   // Low ต่ำสุดระหว่าง Candle [1] และ [2]
   //---------------------------------------------------------------

   double sl =
      MathMin(
         prices[1].low,
         prices[2].low
      );


   //---------------------------------------------------------------
   // Normalize Price
   //---------------------------------------------------------------

   entry1 =
      NormalizeDouble(
         entry1,
         _Digits
      );


   entry2 =
      NormalizeDouble(
         entry2,
         _Digits
      );


   entry3 =
      NormalizeDouble(
         entry3,
         _Digits
      );


   sl =
      NormalizeDouble(
         sl,
         _Digits
      );


   //---------------------------------------------------------------
   // Debug
   //---------------------------------------------------------------

   Print(
      "Bullish Body=", bullishBody
   );


   Print(
      "Step=", step
   );


   Print(
      "Entry1=", entry1,
      " | Entry2=", entry2,
      " | Entry3=", entry3
   );


   Print(
      "SL=", sl
   );


   //---------------------------------------------------------------
   // BUY LIMIT 1
   //---------------------------------------------------------------

   PlaceBuyLimit(
      LotSize,
      entry1,
      sl,
      RR,
      "PA_BUY_1"
   );


   //---------------------------------------------------------------
   // BUY LIMIT 2
   //---------------------------------------------------------------

   PlaceBuyLimit(
      LotSize,
      entry2,
      sl,
      RR,
      "PA_BUY_2"
   );


   //---------------------------------------------------------------
   // BUY LIMIT 3
   //---------------------------------------------------------------

   PlaceBuyLimit(
      LotSize,
      entry3,
      sl,
      RR,
      "PA_BUY_3"
   );
}


//+------------------------------------------------------------------+
//| Place Buy Limit                                                  |
//+------------------------------------------------------------------+
bool PlaceBuyLimit(
   double volume,
   double entry,
   double sl,
   double rr,
   string comment
)
{
   //---------------------------------------------------------------
   // Current Ask
   //---------------------------------------------------------------

   double ask =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_ASK
      );


   //---------------------------------------------------------------
   // Buy Limit ต้องต่ำกว่า Ask
   //---------------------------------------------------------------

   if(entry >= ask)
   {
      Print(
         comment,
         " SKIPPED",
         " | Entry=", entry,
         " | Ask=", ask,
         " | Buy Limit must be below Ask"
      );

      return false;
   }


   //---------------------------------------------------------------
   // SL ต้องต่ำกว่า Entry
   //---------------------------------------------------------------

   if(sl >= entry)
   {
      Print(
         comment,
         " SKIPPED",
         " | Invalid SL",
         " | Entry=", entry,
         " | SL=", sl
      );

      return false;
   }


   //---------------------------------------------------------------
   // Risk
   //---------------------------------------------------------------

   double risk =
      entry -
      sl;


   if(risk <= 0)
   {
      Print(
         comment,
         " SKIPPED",
         " | Invalid Risk"
      );

      return false;
   }


   //---------------------------------------------------------------
   // TP
   //
   // TP = Entry + Risk * RR
   //---------------------------------------------------------------

   double tp =
      entry +
      (risk * rr);


   tp =
      NormalizeDouble(
         tp,
         _Digits
      );


   //---------------------------------------------------------------
   // Print Order
   //---------------------------------------------------------------

   Print(
      comment,
      " | Entry=", entry,
      " | SL=", sl,
      " | TP=", tp,
      " | Risk=", risk,
      " | RR=", rr
   );


   //---------------------------------------------------------------
   // Send Buy Limit
   //---------------------------------------------------------------

   bool sent =
      trade.BuyLimit(
         volume,
         entry,
         _Symbol,
         sl,
         tp,
         ORDER_TIME_GTC,
         0,
         comment
      );


   //---------------------------------------------------------------
   // Trade Server Result
   //---------------------------------------------------------------

   uint retcode =
      trade.ResultRetcode();


   //---------------------------------------------------------------
   // Success
   //---------------------------------------------------------------

   if(
      sent &&
      (
         retcode == TRADE_RETCODE_PLACED ||
         retcode == TRADE_RETCODE_DONE
      )
   )
   {
      Print(
         comment,
         " SUCCESS",
         " | Order=", trade.ResultOrder(),
         " | Retcode=", retcode,
         " | ",
         trade.ResultRetcodeDescription()
      );


      return true;
   }


   //---------------------------------------------------------------
   // Failed
   //---------------------------------------------------------------

   Print(
      comment,
      " FAILED",
      " | Retcode=", retcode,
      " | ",
      trade.ResultRetcodeDescription()
   );


   return false;
}