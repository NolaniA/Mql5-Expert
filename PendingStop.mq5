//+------------------------------------------------------------------+
//|                                                  PendingStop.mq5 |
//|                                  Copyright 2025, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "1.00"

#include <FunctionT.mqh>


//---define
int OrderTotalBuy      = 0;
int OrderTotalSell     = 0;
int PositionTotalBuy   = 0;
int PositionTotalSell  = 0;






//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
//---

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
   CountOrders(OrderTotalBuy, OrderTotalSell);
   CountPositions(PositionTotalBuy, PositionTotalSell);


   double point         = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double spread_price  = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * point;
   
   if(OrderTotalBuy == 0 && PositionTotalBuy < 1)
   {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double price_buy_stop = ask + spread_price + (point * 5);
      trade.BuyStop(0.01, price_buy_stop, _Symbol, 0, 0);
   }
   
   if(OrderTotalSell == 0 && PositionTotalSell < 1)
   {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double price_sell_stop = bid - spread_price - (point * 5);
      trade.SellStop(0.01, price_sell_stop, _Symbol, 0, 0);
   }


   ClosePendingOrder(300);
   TrailingStop(500, 200000);
   
   if(PositionTotalBuy == 1 && PositionTotalSell == 1)
   {
      int    profit_type   = -1;
      double profit_lot    = 0;
      ulong  profit_ticket = 0;
   
      // 1) หา position ที่กำไร
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(!PositionSelectByTicket(ticket)) continue;
   
         double profit = PositionGetDouble(POSITION_PROFIT);
         if(profit > 0)
         {
            profit_type   = (int)PositionGetInteger(POSITION_TYPE);
            profit_lot    = PositionGetDouble(POSITION_VOLUME);
            profit_ticket = ticket;
            break; // เอาตัวแรกพอ
         }
      }
   
      // 2) ปิด position ที่ขาดทุน
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(!PositionSelectByTicket(ticket)) continue;
   
         if(PositionGetDouble(POSITION_PROFIT) < 0)
            trade.PositionClose(ticket);
      }
   
      // 3) เปิด order ใหม่ฝั่งกำไร
      if(profit_lot > 0)
      {
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double sl_points = 2000 * _Point; // ปลอดภัยกว่า
   
         if(profit_type == POSITION_TYPE_BUY)
            trade.Buy(profit_lot * 10, _Symbol, ask, ask - sl_points, 0);
         else
            trade.Sell(profit_lot * 10, _Symbol, bid, bid + sl_points, 0);
      }
   
      // 4) ปิดทั้งหมดเมื่อกำไรถึงเป้า
      double balance = AccountInfoDouble(ACCOUNT_BALANCE);
      double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   
      if(equity >= balance * 1.01) // กำไร 1%
      {
         for(int i = PositionsTotal() - 1; i >= 0; i--)
         {
            ulong ticket = PositionGetTicket(i);
            trade.PositionClose(ticket);
         }
      }
   }

   
   
   


   Comment(OrderTotalBuy, OrderTotalSell,"\n",PositionTotalBuy,PositionTotalSell);
  }
//+------------------------------------------------------------------+


//v.1
//CountOrders(OrderTotalBuy, OrderTotalSell);
//   CountPositions(PositionTotalBuy, PositionTotalSell);
//
//
//
//   if(OrderTotalBuy == 0 && PositionTotalBuy <= 1){
//      double   high  =  iHigh(_Symbol, PERIOD_M5, 0);
//      trade.BuyStop(0.01, high, _Symbol, 0, 0);
//   }
//   if(OrderTotalSell == 0 && PositionTotalSell <= 1){
//      double   low  =  iLow(_Symbol, PERIOD_M5, 0);
//      trade.SellStop(0.01, low, _Symbol, 0, 0);
//   }
//
//   ClosePendingOrder(300);
//   TrailingStop(500, 2000);



//if(PositionTotalBuy >= 1 && PositionTotalSell >= 1)
//     {
//      //---find position profit
//      int      type  =  0;
//      double   lot   =  0;
//
//      for(int i=0; PositionsTotal() > i; i++)
//        {
//         ulong ticket   =  PositionGetTicket(i);
//         if(!PositionSelectByTicket(ticket))continue;
//         if(PositionGetDouble(POSITION_PROFIT) > 0)
//           {
//            type     = (int)PositionGetInteger(POSITION_TYPE);
//            lot      =  PositionGetDouble(POSITION_VOLUME);
//            break;
//            
//           }
//         if(PositionGetDouble(POSITION_PROFIT) < 0){
//            trade.PositionClose(ticket);
//         }
//        }
//
//      if(lot > 0)
//        {
//         double price_ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
//         double price_bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
//         if(type == POSITION_TYPE_BUY)
//           {
//
//            trade.Buy(lot*10, _Symbol, price_ask,price_ask - 20000*_Point, 0);
//           }
//         else
//           {
//            trade.Sell(lot*10, _Symbol, price_bid, price_bid + 20000*_Point, 0);
//           }
//        }
//
////      double   balance  =  AccountInfoDouble(ACCOUNT_BALANCE);
////      double   equity   =  AccountInfoDouble(ACCOUNT_EQUITY);
////
////      if(equity > balance)
////        {
////         for(int i=0; PositionsTotal() > i; i++)
////           {
////            ulong ticket   =  PositionGetTicket(i);
////            trade.PositionClose(ticket);
////           }
////        }
//
//
//     }


//---function for multiple lot size
   
//   if(PositionTotalBuy == 1 && PositionTotalSell == 1)
//     {
//      //---find position profit
//      int    profit_type   = -1;
//      double profit_lot    = 0;
//      ulong  profit_ticket = 0;
//
//      for(int i=0; PositionsTotal() > i; i++)
//        {
//         ulong ticket   =  PositionGetTicket(i);
//         if(!PositionSelectByTicket(ticket))continue;
//         if(PositionGetDouble(POSITION_PROFIT) > 0)
//           {
//            profit_type     = (int)PositionGetInteger(POSITION_TYPE);
//            profit_lot      =  PositionGetDouble(POSITION_VOLUME);
//            profit_ticket   = ticket;
//            break;
//            
//           }
//         if(PositionGetDouble(POSITION_PROFIT) < 0){
//            trade.PositionClose(ticket);
//         }
//        }
//
//      if(profit_lot > 0)
//        {
//         double price_ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
//         double price_bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
//         if(type == POSITION_TYPE_BUY)
//           {
//
//            trade.Buy(lot*10, _Symbol, price_ask,price_ask - 200000*_Point, 0);
//           }
//         else
//           {
//            trade.Sell(lot*10, _Symbol, price_bid, price_bid + 200000*_Point, 0);
//           }
//        }
//
//      double   balance  =  AccountInfoDouble(ACCOUNT_BALANCE);
//      double   equity   =  AccountInfoDouble(ACCOUNT_EQUITY);
//
//      if(equity > balance)
//        {
//         for(int i=0; PositionsTotal() > i; i++)
//           {
//            ulong ticket   =  PositionGetTicket(i);
//            trade.PositionClose(ticket);
//           }
//        }
//
//
//     }
