//+------------------------------------------------------------------+
//|                                             PendingGridEA.mq5    |
//+------------------------------------------------------------------+
#property strict
#property version   "1.30"

#include <Trade/Trade.mqh>

CTrade trade;


//====================================================================
// LOT MODE
//====================================================================
enum ENUM_LOT_MODE
{
   LOT_DESCENDING = 0,
   LOT_ASCENDING  = 1
};


//====================================================================
// INPUT
//====================================================================
input group "=== GRID INPUT ==="

input int    MaxBuyPending    = 5;
input int    MaxSellPending   = 5;
input double PendingSpread    = 1.0;
input ulong  MagicNumber      = 260926;


//====================================================================
// LOT INPUT
//====================================================================
input group "=== LOT INPUT ==="

input double LotSize          = 0.01;
input double LotStep          = 0.01;
input ENUM_LOT_MODE LotMode   = LOT_ASCENDING;


//====================================================================
// SIDEWAY INPUT
//====================================================================
input group "=== SIDEWAY INPUT ==="

// เปิด/ปิด Sideway Filter
input bool EnableSidewayFilter = true;

// Timeframe ที่ใช้ตรวจ Sideway
input ENUM_TIMEFRAMES SidewayTimeframe = PERIOD_M5;

// จำนวนแท่งย้อนหลัง
input int SidewayBars = 20;

// Range สูงสุดที่ถือว่า Sideway
// หน่วย = Point
input double SidewayMaxRangePoints = 1000;


//====================================================================
// GLOBAL
//====================================================================

// false = เปิด Grid ใหม่ได้
// true  = Grid ครบแล้ว รอ Take Profit
bool g_cycleLocked = false;


//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetAsyncMode(false);


   //===============================================================
   // ถ้า Restart EA แล้วมี Position อยู่
   // ถือว่า Cycle เดิมยังทำงาน
   //===============================================================
   if(HasEAPosition())
   {
      g_cycleLocked = true;
   }
   else
   {
      int buyCount  = CountBuyStop();
      int sellCount = CountSellStop();


      if(
         buyCount >= MaxBuyPending &&
         sellCount >= MaxSellPending
      )
      {
         g_cycleLocked = true;
      }
      else
      {
         g_cycleLocked = false;
      }
   }


   Print(
      "EA START",
      " | CycleLocked=", g_cycleLocked,
      " | LotMode=", EnumToString(LotMode),
      " | BaseLot=", LotSize,
      " | LotStep=", LotStep,
      " | SidewayFilter=", EnableSidewayFilter
   );


   return(INIT_SUCCEEDED);
}


//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
}


//+------------------------------------------------------------------+
//| Expert tick                                                      |
//+------------------------------------------------------------------+
void OnTick()
{
   //===============================================================
   // 1. TAKE PROFIT
   //
   // Equity > Balance
   //===============================================================
   if(CloseAllIfEquityHigher())
      return;


   //===============================================================
   // 2. Grid ครบแล้ว
   //
   // ไม่เปิดเพิ่มจนกว่าจะ Take Profit
   //===============================================================
   if(g_cycleLocked)
      return;


   //===============================================================
   // 3. SIDEWAY FILTER
   //
   // ถ้าเปิด Filter
   // ต้องเป็น Sideway ก่อน
   //===============================================================
   if(EnableSidewayFilter)
   {
      if(!IsSideway())
         return;
   }


   //===============================================================
   // 4. เปิด Grid
   //===============================================================
   OpenPendingGrid();
}


//+------------------------------------------------------------------+
//| CHECK SIDEWAY                                                    |
//+------------------------------------------------------------------+
bool IsSideway()
{
   //===============================================================
   // Validate
   //===============================================================
   if(SidewayBars <= 0)
      return false;


   if(SidewayMaxRangePoints <= 0)
      return false;


   double point =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_POINT
      );


   if(point <= 0)
      return false;


   //===============================================================
   // Array
   //===============================================================
   double highs[];
   double lows[];


   ArraySetAsSeries(
      highs,
      true
   );


   ArraySetAsSeries(
      lows,
      true
   );


   //===============================================================
   // ใช้แท่งปิด
   //
   // start = 1
   // ไม่ใช้แท่งปัจจุบัน [0]
   //===============================================================
   int copiedHigh =
      CopyHigh(
         _Symbol,
         SidewayTimeframe,
         1,
         SidewayBars,
         highs
      );


   int copiedLow =
      CopyLow(
         _Symbol,
         SidewayTimeframe,
         1,
         SidewayBars,
         lows
      );


   //===============================================================
   // ข้อมูลไม่ครบ
   //===============================================================
   if(
      copiedHigh < SidewayBars ||
      copiedLow < SidewayBars
   )
   {
      return false;
   }


   //===============================================================
   // Highest High
   //===============================================================
   int highIndex =
      ArrayMaximum(
         highs,
         0,
         SidewayBars
      );


   //===============================================================
   // Lowest Low
   //===============================================================
   int lowIndex =
      ArrayMinimum(
         lows,
         0,
         SidewayBars
      );


   if(
      highIndex < 0 ||
      lowIndex < 0
   )
   {
      return false;
   }


   double highest =
      highs[highIndex];


   double lowest =
      lows[lowIndex];


   //===============================================================
   // Range
   //===============================================================
   double rangePrice =
      highest - lowest;


   double rangePoints =
      rangePrice / point;


   //===============================================================
   // Sideway
   //
   // Range <= Maximum
   //===============================================================
   bool sideway =
      rangePoints <=
      SidewayMaxRangePoints;


   //===============================================================
   // Debug
   //===============================================================
   static datetime lastPrintBar = 0;


   datetime currentBar =
      iTime(
         _Symbol,
         SidewayTimeframe,
         0
      );


   if(currentBar != lastPrintBar)
   {
      lastPrintBar =
         currentBar;


      Print(
         "SIDEWAY CHECK",
         " | TF=", EnumToString(SidewayTimeframe),
         " | Bars=", SidewayBars,
         " | High=",
         DoubleToString(
            highest,
            _Digits
         ),
         " | Low=",
         DoubleToString(
            lowest,
            _Digits
         ),
         " | RangePoints=",
         DoubleToString(
            rangePoints,
            0
         ),
         " | Max=",
         DoubleToString(
            SidewayMaxRangePoints,
            0
         ),
         " | Result=",
         sideway
      );
   }


   return sideway;
}


//+------------------------------------------------------------------+
//| Open BUY + SELL Pending Grid                                     |
//+------------------------------------------------------------------+
void OpenPendingGrid()
{
   double ask =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_ASK
      );


   double bid =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_BID
      );


   if(ask <= 0 || bid <= 0)
      return;


   double spread =
      ask - bid;


   if(spread <= 0)
      return;


   //===============================================================
   // ระยะห่างแต่ละ Pending
   //===============================================================
   double gap =
      spread * PendingSpread;


   if(gap <= 0)
      return;


   //===============================================================
   // Count
   //===============================================================
   int buyCount =
      CountBuyStop();


   int sellCount =
      CountSellStop();


   //================================================================
   // BUY STOP
   //
   // Ask + Gap * Level
   //================================================================
   if(buyCount < MaxBuyPending)
   {
      for(
         int level = buyCount + 1;
         level <= MaxBuyPending;
         level++
      )
      {
         //==========================================================
         // Price
         //==========================================================
         double pendingPrice =
            ask +
            (gap * level);


         pendingPrice =
            NormalizeBuyStopPrice(
               pendingPrice
            );


         //==========================================================
         // Broker Stop Level
         //==========================================================
         if(!CheckBuyStopPrice(pendingPrice))
         {
            Print(
               "BUY STOP INVALID",
               " | Level=", level,
               " | Price=",
               DoubleToString(
                  pendingPrice,
                  _Digits
               )
            );


            continue;
         }


         //==========================================================
         // Lot
         //==========================================================
         double lot =
            GetLotByLevel(
               level,
               MaxBuyPending
            );


         //==========================================================
         // Create BUY STOP
         //==========================================================
         bool result =
            trade.BuyStop(
               lot,
               pendingPrice,
               _Symbol,
               0.0,
               0.0,
               ORDER_TIME_GTC,
               0,
               "Grid BuyStop"
            );


         if(result)
         {
            Print(
               "BUY STOP SUCCESS",
               " | Level=", level,
               " | Lot=",
               DoubleToString(
                  lot,
                  2
               ),
               " | Price=",
               DoubleToString(
                  pendingPrice,
                  _Digits
               )
            );
         }
         else
         {
            Print(
               "BUY STOP FAIL",
               " | Level=", level,
               " | Lot=",
               DoubleToString(
                  lot,
                  2
               ),
               " | Price=",
               DoubleToString(
                  pendingPrice,
                  _Digits
               ),
               " | ",
               trade.ResultRetcodeDescription()
            );
         }
      }
   }


   //================================================================
   // SELL STOP
   //
   // Bid - Gap * Level
   //================================================================
   if(sellCount < MaxSellPending)
   {
      for(
         int level = sellCount + 1;
         level <= MaxSellPending;
         level++
      )
      {
         //==========================================================
         // Price
         //==========================================================
         double pendingPrice =
            bid -
            (gap * level);


         pendingPrice =
            NormalizeSellStopPrice(
               pendingPrice
            );


         //==========================================================
         // Broker Stop Level
         //==========================================================
         if(!CheckSellStopPrice(pendingPrice))
         {
            Print(
               "SELL STOP INVALID",
               " | Level=", level,
               " | Price=",
               DoubleToString(
                  pendingPrice,
                  _Digits
               )
            );


            continue;
         }


         //==========================================================
         // Lot
         //==========================================================
         double lot =
            GetLotByLevel(
               level,
               MaxSellPending
            );


         //==========================================================
         // Create SELL STOP
         //==========================================================
         bool result =
            trade.SellStop(
               lot,
               pendingPrice,
               _Symbol,
               0.0,
               0.0,
               ORDER_TIME_GTC,
               0,
               "Grid SellStop"
            );


         if(result)
         {
            Print(
               "SELL STOP SUCCESS",
               " | Level=", level,
               " | Lot=",
               DoubleToString(
                  lot,
                  2
               ),
               " | Price=",
               DoubleToString(
                  pendingPrice,
                  _Digits
               )
            );
         }
         else
         {
            Print(
               "SELL STOP FAIL",
               " | Level=", level,
               " | Lot=",
               DoubleToString(
                  lot,
                  2
               ),
               " | Price=",
               DoubleToString(
                  pendingPrice,
                  _Digits
               ),
               " | ",
               trade.ResultRetcodeDescription()
            );
         }
      }
   }


   //===============================================================
   // Count หลังเปิด
   //===============================================================
   buyCount =
      CountBuyStop();


   sellCount =
      CountSellStop();


   //===============================================================
   // BUY + SELL ครบ
   //
   // Lock Cycle
   //===============================================================
   if(
      buyCount >= MaxBuyPending &&
      sellCount >= MaxSellPending
   )
   {
      g_cycleLocked =
         true;


      Print(
         "GRID COMPLETE -> LOCK",
         " | BUY=", buyCount,
         " | SELL=", sellCount
      );
   }
}


//+------------------------------------------------------------------+
//| Calculate Lot ตาม Level                                          |
//+------------------------------------------------------------------+
double GetLotByLevel(
   int level,
   int maxOrders
)
{
   double lot =
      LotSize;


   if(level < 1)
      level = 1;


   if(maxOrders < 1)
      maxOrders = 1;


   //===============================================================
   // DESCENDING
   //
   // 0.05
   // 0.04
   // 0.03
   // 0.02
   // 0.01
   //===============================================================
   if(LotMode == LOT_DESCENDING)
   {
      lot =
         LotSize +
         (
            (maxOrders - level)
            * LotStep
         );
   }


   //===============================================================
   // ASCENDING
   //
   // 0.01
   // 0.02
   // 0.03
   // 0.04
   // 0.05
   //===============================================================
   else
   if(LotMode == LOT_ASCENDING)
   {
      lot =
         LotSize +
         (
            (level - 1)
            * LotStep
         );
   }


   return NormalizeVolume(
      lot
   );
}


//+------------------------------------------------------------------+
//| Normalize Volume                                                 |
//+------------------------------------------------------------------+
double NormalizeVolume(
   double volume
)
{
   double minVolume =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_VOLUME_MIN
      );


   double maxVolume =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_VOLUME_MAX
      );


   double volumeStep =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_VOLUME_STEP
      );


   volume =
      MathMax(
         minVolume,
         MathMin(
            maxVolume,
            volume
         )
      );


   if(volumeStep > 0)
   {
      volume =
         MathFloor(
            (volume / volumeStep)
            + 0.00000001
         )
         * volumeStep;
   }


   return NormalizeDouble(
      volume,
      8
   );
}


//+------------------------------------------------------------------+
//| Count BUY STOP                                                   |
//+------------------------------------------------------------------+
int CountBuyStop()
{
   int count = 0;


   for(
      int i = OrdersTotal() - 1;
      i >= 0;
      i--
   )
   {
      ulong ticket =
         OrderGetTicket(i);


      if(ticket == 0)
         continue;


      if(!OrderSelect(ticket))
         continue;


      if(
         OrderGetString(
            ORDER_SYMBOL
         ) != _Symbol
      )
      {
         continue;
      }


      if(
         (ulong)OrderGetInteger(
            ORDER_MAGIC
         ) != MagicNumber
      )
      {
         continue;
      }


      ENUM_ORDER_TYPE type =
         (ENUM_ORDER_TYPE)
         OrderGetInteger(
            ORDER_TYPE
         );


      if(type != ORDER_TYPE_BUY_STOP)
         continue;


      count++;
   }


   return count;
}


//+------------------------------------------------------------------+
//| Count SELL STOP                                                  |
//+------------------------------------------------------------------+
int CountSellStop()
{
   int count = 0;


   for(
      int i = OrdersTotal() - 1;
      i >= 0;
      i--
   )
   {
      ulong ticket =
         OrderGetTicket(i);


      if(ticket == 0)
         continue;


      if(!OrderSelect(ticket))
         continue;


      if(
         OrderGetString(
            ORDER_SYMBOL
         ) != _Symbol
      )
      {
         continue;
      }


      if(
         (ulong)OrderGetInteger(
            ORDER_MAGIC
         ) != MagicNumber
      )
      {
         continue;
      }


      ENUM_ORDER_TYPE type =
         (ENUM_ORDER_TYPE)
         OrderGetInteger(
            ORDER_TYPE
         );


      if(type != ORDER_TYPE_SELL_STOP)
         continue;


      count++;
   }


   return count;
}


//+------------------------------------------------------------------+
//| Check EA Position                                                |
//+------------------------------------------------------------------+
bool HasEAPosition()
{
   for(
      int i = PositionsTotal() - 1;
      i >= 0;
      i--
   )
   {
      ulong ticket =
         PositionGetTicket(i);


      if(ticket == 0)
         continue;


      if(!PositionSelectByTicket(ticket))
         continue;


      if(
         PositionGetString(
            POSITION_SYMBOL
         ) != _Symbol
      )
      {
         continue;
      }


      if(
         (ulong)PositionGetInteger(
            POSITION_MAGIC
         ) != MagicNumber
      )
      {
         continue;
      }


      return true;
   }


   return false;
}


//+------------------------------------------------------------------+
//| Check BUY STOP Price                                             |
//+------------------------------------------------------------------+
bool CheckBuyStopPrice(
   double pendingPrice
)
{
   double ask =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_ASK
      );


   double point =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_POINT
      );


   int stopsLevel =
      (int)SymbolInfoInteger(
         _Symbol,
         SYMBOL_TRADE_STOPS_LEVEL
      );


   double minDistance =
      stopsLevel * point;


   if(
      pendingPrice <
      ask + minDistance
   )
   {
      return false;
   }


   return true;
}


//+------------------------------------------------------------------+
//| Check SELL STOP Price                                            |
//+------------------------------------------------------------------+
bool CheckSellStopPrice(
   double pendingPrice
)
{
   double bid =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_BID
      );


   double point =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_POINT
      );


   int stopsLevel =
      (int)SymbolInfoInteger(
         _Symbol,
         SYMBOL_TRADE_STOPS_LEVEL
      );


   double minDistance =
      stopsLevel * point;


   if(
      pendingPrice >
      bid - minDistance
   )
   {
      return false;
   }


   return true;
}


//+------------------------------------------------------------------+
//| Normalize BUY STOP                                               |
//+------------------------------------------------------------------+
double NormalizeBuyStopPrice(
   double price
)
{
   double tickSize =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_TRADE_TICK_SIZE
      );


   if(tickSize <= 0)
   {
      return NormalizeDouble(
         price,
         _Digits
      );
   }


   price =
      MathCeil(
         price / tickSize
      )
      * tickSize;


   return NormalizeDouble(
      price,
      _Digits
   );
}


//+------------------------------------------------------------------+
//| Normalize SELL STOP                                              |
//+------------------------------------------------------------------+
double NormalizeSellStopPrice(
   double price
)
{
   double tickSize =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_TRADE_TICK_SIZE
      );


   if(tickSize <= 0)
   {
      return NormalizeDouble(
         price,
         _Digits
      );
   }


   price =
      MathFloor(
         price / tickSize
      )
      * tickSize;


   return NormalizeDouble(
      price,
      _Digits
   );
}


//+------------------------------------------------------------------+
//| TAKE PROFIT                                                      |
//|                                                                  |
//| Equity > Balance                                                 |
//|                                                                  |
//| Close ALL Position                                               |
//| Delete ALL Pending                                               |
//| Unlock Cycle                                                     |
//+------------------------------------------------------------------+
bool CloseAllIfEquityHigher()
{
   double balance =
      AccountInfoDouble(
         ACCOUNT_BALANCE
      );


   double equity =
      AccountInfoDouble(
         ACCOUNT_EQUITY
      );


   //===============================================================
   // ยังไม่ Take Profit
   //===============================================================
   if(equity <= balance)
      return false;


   Print(
      "TAKE PROFIT",
      " | Equity=",
      DoubleToString(
         equity,
         2
      ),
      " | Balance=",
      DoubleToString(
         balance,
         2
      )
   );


   //===============================================================
   // CLOSE ALL POSITIONS
   //===============================================================
   for(
      int i = PositionsTotal() - 1;
      i >= 0;
      i--
   )
   {
      ulong ticket =
         PositionGetTicket(i);


      if(ticket == 0)
         continue;


      if(!PositionSelectByTicket(ticket))
         continue;


      bool result =
         trade.PositionClose(
            ticket
         );


      if(result)
      {
         Print(
            "CLOSE POSITION SUCCESS",
            " | Ticket=",
            ticket
         );
      }
      else
      {
         Print(
            "CLOSE POSITION FAIL",
            " | Ticket=",
            ticket,
            " | ",
            trade.ResultRetcodeDescription()
         );
      }
   }


   //===============================================================
   // DELETE ALL PENDING
   //===============================================================
   for(
      int i = OrdersTotal() - 1;
      i >= 0;
      i--
   )
   {
      ulong ticket =
         OrderGetTicket(i);


      if(ticket == 0)
         continue;


      if(!OrderSelect(ticket))
         continue;


      ENUM_ORDER_TYPE type =
         (ENUM_ORDER_TYPE)
         OrderGetInteger(
            ORDER_TYPE
         );


      bool isPending =
      (
         type == ORDER_TYPE_BUY_LIMIT       ||
         type == ORDER_TYPE_SELL_LIMIT      ||
         type == ORDER_TYPE_BUY_STOP        ||
         type == ORDER_TYPE_SELL_STOP       ||
         type == ORDER_TYPE_BUY_STOP_LIMIT  ||
         type == ORDER_TYPE_SELL_STOP_LIMIT
      );


      if(!isPending)
         continue;


      bool result =
         trade.OrderDelete(
            ticket
         );


      if(result)
      {
         Print(
            "DELETE PENDING SUCCESS",
            " | Ticket=",
            ticket
         );
      }
      else
      {
         Print(
            "DELETE PENDING FAIL",
            " | Ticket=",
            ticket,
            " | ",
            trade.ResultRetcodeDescription()
         );
      }
   }


   //===============================================================
   // ปิดหมดแล้ว
   //===============================================================
   if(
      PositionsTotal() == 0 &&
      OrdersTotal() == 0
   )
   {
      //============================================================
      // เปิด Cycle ใหม่
      //
      // แต่ Cycle ใหม่จะต้องผ่าน IsSideway() อีกครั้ง
      // ก่อนกาง Grid
      //============================================================
      g_cycleLocked =
         false;


      Print(
         "TAKE PROFIT COMPLETE",
         " -> UNLOCK NEW CYCLE"
      );
   }


   return true;
}
//+------------------------------------------------------------------+