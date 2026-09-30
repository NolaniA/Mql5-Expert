//+------------------------------------------------------------------+
//|                                                            1.mq5 |
//|                                  Copyright 2025, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "1.00"


#include <Trade/Trade.mqh>

CTrade trade;

input group "=== INPUT==="
input double LotSize            = 0.01;
input int    MaxBuyPending      = 5;
input int    MaxSellPending     = 5;
input double PendingSpread      = 1.0;
input ulong  MagicNumber        = 260926;




//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
//---
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetAsyncMode(false);
//---
   return(INIT_SUCCEEDED);
  }
//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
//---
   
  }
//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
//---
   if(CloseAllIfEquityHigher())
      return;


   double open0  = iOpen(_Symbol, PERIOD_CURRENT, 0);
   double close0 = iClose(_Symbol, PERIOD_CURRENT, 0);

   if(open0 <= 0 || close0 <= 0)
      return;
      
   if(close0 > open0)
   {
      ClosePendingBuyStop();
      
      ConditionPendingSellStop();
      return;
   }
   
   if(open0 > close0)
   {
      ClosePendingSellStop();
      
      ConditionPendingBuyStop();
      return;
   }
   
}

void ConditionPendingBuyStop(){

   int buyCount = CountBuyStop();

   if(buyCount >= MaxBuyPending)
   {
      DeleteBuyStopOrderOlder();
   }

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(ask <= 0 || bid <= 0)
      return;

   double spread = ask - bid;

   if(spread <= 0)
      return;

   double open0  = iOpen(_Symbol, PERIOD_CURRENT, 0);
   double close0 = iOpen(_Symbol, PERIOD_CURRENT, 0);

   if(open0 <= 0 || close0 <= 0)
      return;


   double pendingPrice = ask + spread;

   double minBuyStopPrice = GetMinBuyStopPrice();

   if(minBuyStopPrice == 0)
   {
      bool result = trade.BuyStop(
         LotSize,
         pendingPrice,
         _Symbol,
         0.0,
         0.0,
         ORDER_TIME_GTC,
         0,
         "Candle BuyStop"
      );

      return;
   }
   else
   {
      if(pendingPrice > (minBuyStopPrice - spread))
         return;
   }

   bool result = trade.BuyStop(
         LotSize,
         pendingPrice,
         _Symbol,
         0.0,
         0.0,
         ORDER_TIME_GTC,
         0,
         "Candle BuyStop"
      );

}


double GetMinBuyStopPrice()
{
   int total = OrdersTotal();

   double minPrice = DBL_MAX;
   bool found = false;

   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);

      if(ticket == 0)
         continue;

      if(!OrderSelect(ticket))
         continue;

      //--- symbol
      if(OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;

      //--- magic
      if((ulong)OrderGetInteger(ORDER_MAGIC) != MagicNumber)
         continue;

      //--- เฉพาะ BUY STOP
      ENUM_ORDER_TYPE type =
         (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);

      if(type != ORDER_TYPE_BUY_STOP)
         continue;

      //--- ราคา Pending
      double price =
         OrderGetDouble(ORDER_PRICE_OPEN);

      //--- หา BUY STOP ราคาต่ำสุด
      if(price < minPrice)
      {
         minPrice = price;
         found = true;
      }
   }

   if(!found)
      return 0.0;

   return minPrice;
}


void ConditionPendingSellStop(){

   int sellCount = CountSellStop();
   
   if(sellCount >= MaxSellPending)
   {
      DeleteSellStopOrderOlder();
   }

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    
   if(ask <= 0 || bid <= 0)
      return;
      
   double spread = ask - bid;

   if(spread <= 0)
      return;

   double open0  = iOpen(_Symbol, PERIOD_CURRENT, 0);
   double close0 = iOpen(_Symbol, PERIOD_CURRENT, 0);

   if(open0 <= 0 || close0 <= 0)
      return;
      
   
   double pendingPrice = bid - spread;

   double maxSellStopPrice = GetMaxSellStopPrice();
   
   if(maxSellStopPrice == 0)
   {
      bool result = trade.SellStop(
         LotSize,
         pendingPrice,
         _Symbol,
         0.0,
         0.0,
         ORDER_TIME_GTC,
         0,
         "Candle SellStop"
      );
   }
   else
   {
      if(pendingPrice < (maxSellStopPrice + spread))
         return;
   }
      
   bool result = trade.SellStop(
         LotSize,
         pendingPrice,
         _Symbol,
         0.0,
         0.0,
         ORDER_TIME_GTC,
         0,
         "Candle SellStop"
      );


}

double GetMaxSellStopPrice()
{
   int total = OrdersTotal();

   double maxPrice = 0.0;

   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);

      if(ticket == 0)
         continue;

      if(!OrderSelect(ticket))
         continue;

      //--- symbol
      if(OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;

      //--- magic
      if((ulong)OrderGetInteger(ORDER_MAGIC) != MagicNumber)
         continue;

      //--- เฉพาะ SELL STOP
      ENUM_ORDER_TYPE type =
         (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);

      if(type != ORDER_TYPE_SELL_STOP)
         continue;

      //--- ราคา Pending
      double price =
         OrderGetDouble(ORDER_PRICE_OPEN);

      //--- หา SELL STOP ราคาสูงสุด
      if(price > maxPrice)
         maxPrice = price;
   }

   return maxPrice;
}

//+------------------------------------------------------------------+
//| Count BUY STOP                                                   |
//+------------------------------------------------------------------+
int CountBuyStop()
{
   int count = 0;


   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket =
         OrderGetTicket(i);


      if(ticket == 0)
         continue;


      if(!OrderSelect(ticket))
         continue;


      //============================================================
      // Symbol
      //============================================================
      if(
         OrderGetString(
            ORDER_SYMBOL
         ) != _Symbol
      )
      {
         continue;
      }


      //============================================================
      // Magic
      //============================================================
      ulong magic =
         (ulong)OrderGetInteger(
            ORDER_MAGIC
         );


      if(magic != MagicNumber)
         continue;


      //============================================================
      // Type
      //============================================================
      ENUM_ORDER_TYPE type =
         (ENUM_ORDER_TYPE)OrderGetInteger(
            ORDER_TYPE
         );


      if(type == ORDER_TYPE_BUY_STOP)
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


   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket =
         OrderGetTicket(i);


      if(ticket == 0)
         continue;


      if(!OrderSelect(ticket))
         continue;


      //============================================================
      // Symbol
      //============================================================
      if(
         OrderGetString(
            ORDER_SYMBOL
         ) != _Symbol
      )
      {
         continue;
      }


      //============================================================
      // Magic
      //============================================================
      ulong magic =
         (ulong)OrderGetInteger(
            ORDER_MAGIC
         );


      if(magic != MagicNumber)
         continue;


      //============================================================
      // Type
      //============================================================
      ENUM_ORDER_TYPE type =
         (ENUM_ORDER_TYPE)OrderGetInteger(
            ORDER_TYPE
         );


      if(type == ORDER_TYPE_SELL_STOP)
         count++;
   }


   return count;
}



//+------------------------------------------------------------------+
//| Delete Oldest SELL STOP                                          |
//+------------------------------------------------------------------+
void DeleteSellStopOrderOlder()
{
   int total = OrdersTotal();

   if(total == 0)
      return;

   ulong oldestTicket = 0;
   datetime oldestTime = LONG_MAX;

   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);

      if(ticket == 0)
         continue;

      if(!OrderSelect(ticket))
         continue;

      //--- symbol
      if(OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;

      //--- magic
      if((ulong)OrderGetInteger(ORDER_MAGIC) != MagicNumber)
         continue;

      //--- เฉพาะ SELL STOP
      ENUM_ORDER_TYPE type =
         (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);

      if(type != ORDER_TYPE_SELL_STOP)
         continue;

      //--- เวลาเปิด Pending
      datetime setupTime =
         (datetime)OrderGetInteger(ORDER_TIME_SETUP);

      //--- หา Order ที่เก่าที่สุด
      if(setupTime < oldestTime)
      {
         oldestTime   = setupTime;
         oldestTicket = ticket;
      }
   }


   //--- delete oldest
   if(oldestTicket > 0)
   {
      bool ok =
         trade.OrderDelete(oldestTicket);

      if(ok)
      {
         Print(
            "DELETE OLDEST SELL STOP SUCCESS",
            " | Ticket: ", oldestTicket,
            " | Time: ",
            TimeToString(
               oldestTime,
               TIME_DATE | TIME_MINUTES | TIME_SECONDS
            )
         );
      }
      else
      {
         Print(
            "DELETE OLDEST SELL STOP FAIL",
            " | Ticket: ", oldestTicket,
            " | ",
            trade.ResultRetcodeDescription()
         );
      }
   }
}


//+------------------------------------------------------------------+
//| Delete Oldest BUY STOP                                           |
//+------------------------------------------------------------------+
void DeleteBuyStopOrderOlder()
{
   int total = OrdersTotal();

   if(total == 0)
      return;

   ulong oldestTicket = 0;
   datetime oldestTime = LONG_MAX;

   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);

      if(ticket == 0)
         continue;

      if(!OrderSelect(ticket))
         continue;

      //--- symbol
      if(OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;

      //--- magic
      if((ulong)OrderGetInteger(ORDER_MAGIC) != MagicNumber)
         continue;

      //--- เฉพาะ BUY STOP
      ENUM_ORDER_TYPE type =
         (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);

      if(type != ORDER_TYPE_BUY_STOP)
         continue;

      //--- เวลาเปิด Pending
      datetime setupTime =
         (datetime)OrderGetInteger(ORDER_TIME_SETUP);

      //--- หา Order ที่เก่าที่สุด
      if(setupTime < oldestTime)
      {
         oldestTime   = setupTime;
         oldestTicket = ticket;
      }
   }


   //--- delete oldest
   if(oldestTicket > 0)
   {
      bool ok =
         trade.OrderDelete(oldestTicket);

      if(ok)
      {
         Print(
            "DELETE OLDEST BUY STOP SUCCESS",
            " | Ticket: ", oldestTicket,
            " | Time: ",
            TimeToString(
               oldestTime,
               TIME_DATE | TIME_MINUTES | TIME_SECONDS
            )
         );
      }
      else
      {
         Print(
            "DELETE OLDEST BUY STOP FAIL",
            " | Ticket: ", oldestTicket,
            " | ",
            trade.ResultRetcodeDescription()
         );
      }
   }
}
  
  
//+------------------------------------------------------------------+
//| Close Pending BUY STOP                                           |
//+------------------------------------------------------------------+
void ClosePendingBuyStop()
{
   int total = OrdersTotal();

   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);

      if(ticket == 0)
         continue;

      if(!OrderSelect(ticket))
         continue;

      //--- check symbol
      if(OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;

      //--- check magic
      ulong magic = (ulong)OrderGetInteger(ORDER_MAGIC);

      if(magic != MagicNumber)
         continue;

      //--- check order type
      ENUM_ORDER_TYPE type =
         (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);

      if(type != ORDER_TYPE_BUY_STOP)
         continue;

      //--- delete pending
      bool ok = trade.OrderDelete(ticket);

      if(ok)
      {
         Print(
            "Close BUY STOP success | Ticket: ",
            ticket
         );
      }
      else
      {
         Print(
            "Close BUY STOP fail | Ticket: ",
            ticket,
            " | ",
            trade.ResultRetcodeDescription()
         );
      }
   }
}


//+------------------------------------------------------------------+
//| Close Pending SELL STOP                                          |
//+------------------------------------------------------------------+
void ClosePendingSellStop()
{
   int total = OrdersTotal();

   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);

      if(ticket == 0)
         continue;

      if(!OrderSelect(ticket))
         continue;

      //--- check symbol
      if(OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;

      //--- check magic
      ulong magic = (ulong)OrderGetInteger(ORDER_MAGIC);

      if(magic != MagicNumber)
         continue;

      //--- check order type
      ENUM_ORDER_TYPE type =
         (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);

      if(type != ORDER_TYPE_SELL_STOP)
         continue;

      //--- delete pending
      bool ok = trade.OrderDelete(ticket);

      if(ok)
      {
         Print(
            "Close SELL STOP success | Ticket: ",
            ticket
         );
      }
      else
      {
         Print(
            "Close SELL STOP fail | Ticket: ",
            ticket,
            " | ",
            trade.ResultRetcodeDescription()
         );
      }
   }
}

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
   // Equity ยังไม่มากกว่า Balance
   //===============================================================
   if(equity <= balance)
      return false;


   Print(
      "EQUITY > BALANCE",
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
   for(int i = PositionsTotal() - 1; i >= 0; i--)
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
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket =
         OrderGetTicket(i);


      if(ticket == 0)
         continue;


      if(!OrderSelect(ticket))
         continue;


      ENUM_ORDER_TYPE type =
         (ENUM_ORDER_TYPE)OrderGetInteger(
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


   return true;
}
