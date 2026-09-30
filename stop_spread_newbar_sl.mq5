//+------------------------------------------------------------------+
//|                                      stop_spread_newbar.mq5       |
//|                         Pending Stop + Spread Distance Logic       |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "2.10"

#include <Trade/Trade.mqh>

CTrade trade;

//==================================================================
// INPUT
//==================================================================
input double LotSize                  = 0.01;
input double SpreadDistanceMultiplier = 2.0;   // ระยะ Pending/Modify = Spread x ค่านี้
input double SLTriggerSpreadMultiplier = 3.0;    // เริ่มวาง SL เมื่อราคาวิ่งกำไร >= Spread x ค่านี้
input double SLOffsetSpreadMultiplier  = 1.0;    // SL = ราคาเปิด Position +/- Spread x ค่านี้
input int    SlippagePoint             = 20;
input ulong  Magic                    = 10001;

//==================================================================
// GLOBAL
//==================================================================
MqlRates prices[];

int PendingBuy  = 0;
int PendingSell = 0;

int PositionBuy  = 0;
int PositionSell = 0;

datetime LastBarTime = 0;

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   // EA นี้ต้องใช้ Hedging Account
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

   if(SpreadDistanceMultiplier <= 0)
   {
      Print("INIT FAILED | SpreadDistanceMultiplier must be > 0");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(SLTriggerSpreadMultiplier <= 0)
   {
      Print("INIT FAILED | SLTriggerSpreadMultiplier must be > 0");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(SLOffsetSpreadMultiplier <= 0)
   {
      Print("INIT FAILED | SLOffsetSpreadMultiplier must be > 0");
      return INIT_PARAMETERS_INCORRECT;
   }

   trade.SetExpertMagicNumber(Magic);
   trade.SetMarginMode();
   trade.SetDeviationInPoints(SlippagePoint);
   trade.SetTypeFillingBySymbol(_Symbol);

   return INIT_SUCCEEDED;
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
   if(!LoadPrices())
      return;

   bool newBar = IsNewBar();

   // โหลดสถานะล่าสุด
   LoadTradeState();

   // ถ้ามีทั้ง BUY และ SELL Position
   // ให้ปิด Position ที่เปิดเก่าที่สุดก่อน
   CloseOldestPositionIfHedged();

   // Refresh state หลังอาจมี Position ถูกปิด
   LoadTradeState();

   // Position เปิดใหม่จะไม่มี SL ตั้งแต่เริ่ม
   // เมื่อราคาวิ่งกำไร >= Spread x SLTriggerSpreadMultiplier
   // จึงค่อยวาง SL ที่ราคาเปิด +/- Spread x SLOffsetSpreadMultiplier
   ManagePositionProfitStopLoss();

   // เปิด Pending ฝั่งที่ยังไม่มี Pending/Position
   OpenBuyStop();
   OpenSellStop();

   // Refresh state หลังเปิด Pending
   LoadTradeState();

   // Modify เฉพาะเมื่อเกิดแท่งใหม่เท่านั้น
   if(newBar)
   {
      ModifyBuyStop();
      ModifySellStop();
   }
}

//+------------------------------------------------------------------+
//| Load Prices                                                      |
//+------------------------------------------------------------------+
bool LoadPrices()
{
   ArraySetAsSeries(prices, true);

   int copied = CopyRates(
      _Symbol,
      _Period,
      0,
      2,
      prices
   );

   if(copied < 2)
   {
      Print("CopyRates failed | copied=", copied);
      return false;
   }

   return true;
}

//+------------------------------------------------------------------+
//| Detect New Bar                                                   |
//+------------------------------------------------------------------+
bool IsNewBar()
{
   datetime currentBarTime = prices[0].time;

   if(currentBarTime <= 0)
      return false;

   // ตอนเริ่ม EA ให้จำแท่งปัจจุบันก่อน ยังไม่ถือว่าเป็นแท่งใหม่
   if(LastBarTime == 0)
   {
      LastBarTime = currentBarTime;
      return false;
   }

   if(currentBarTime != LastBarTime)
   {
      LastBarTime = currentBarTime;
      return true;
   }

   return false;
}

//+------------------------------------------------------------------+
//| Load Trade State                                                 |
//+------------------------------------------------------------------+
void LoadTradeState()
{
   PendingBuy  = 0;
   PendingSell = 0;

   PositionBuy  = 0;
   PositionSell = 0;

   // Pending Orders
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
      else
      if(type == ORDER_TYPE_SELL_STOP)
         PendingSell++;
   }

   // Positions
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
      else
      if(type == POSITION_TYPE_SELL)
         PositionSell++;
   }
}

//+------------------------------------------------------------------+
//| Get Spread                                                       |
//+------------------------------------------------------------------+
double GetCurrentSpreadPrice()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(ask <= 0 || bid <= 0 || ask <= bid)
      return 0;

   return ask - bid;
}

//+------------------------------------------------------------------+
//| Get Safe Distance                                                |
//| requested distance = current spread x multiplier                |
//| ถ้าต่ำกว่า broker minimum จะใช้ broker minimum แทน               |
//+------------------------------------------------------------------+
double GetOrderDistancePrice()
{
   double spreadPrice = GetCurrentSpreadPrice();

   if(spreadPrice <= 0)
      return 0;

   double requestedDistance =
      spreadPrice * SpreadDistanceMultiplier;

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

   int brokerMinimumPoint =
      MathMax(stopLevel, freezeLevel) + 1;

   double brokerMinimumDistance =
      brokerMinimumPoint * _Point;

   return MathMax(
      requestedDistance,
      brokerMinimumDistance
   );
}

//+------------------------------------------------------------------+
//| Normalize Buy Stop Price                                         |
//+------------------------------------------------------------------+
double NormalizeBuyPrice(double price)
{
   double tickSize =
      SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tickSize <= 0)
      return NormalizeDouble(price, _Digits);

   price = MathCeil(price / tickSize) * tickSize;

   return NormalizeDouble(price, _Digits);
}

//+------------------------------------------------------------------+
//| Normalize Sell Stop Price                                        |
//+------------------------------------------------------------------+
double NormalizeSellPrice(double price)
{
   double tickSize =
      SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tickSize <= 0)
      return NormalizeDouble(price, _Digits);

   price = MathFloor(price / tickSize) * tickSize;

   return NormalizeDouble(price, _Digits);
}

//+------------------------------------------------------------------+
//| Check Trade Result                                               |
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
//| Open Buy Stop                                                    |
//+------------------------------------------------------------------+
void OpenBuyStop()
{
   if(PendingBuy != 0 || PositionBuy != 0)
      return;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(ask <= 0)
      return;

   double distancePrice = GetOrderDistancePrice();

   if(distancePrice <= 0)
      return;

   double price = NormalizeBuyPrice(
      ask + distancePrice
   );

   bool requestResult = trade.BuyStop(
      LotSize,
      price,
      _Symbol,
      0,
      0
   );

   if(!requestResult || !IsTradeSuccess())
   {
      Print(
         "BUY STOP FAILED",
         " | Price=", price,
         " | Ask=", ask,
         " | Spread=", GetCurrentSpreadPrice() / _Point,
         " pt",
         " | Distance=", distancePrice / _Point,
         " pt",
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
      " | Spread=", GetCurrentSpreadPrice() / _Point,
      " pt",
      " | Distance=", distancePrice / _Point,
      " pt"
   );
}

//+------------------------------------------------------------------+
//| Open Sell Stop                                                   |
//+------------------------------------------------------------------+
void OpenSellStop()
{
   if(PendingSell != 0 || PositionSell != 0)
      return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(bid <= 0)
      return;

   double distancePrice = GetOrderDistancePrice();

   if(distancePrice <= 0)
      return;

   double price = NormalizeSellPrice(
      bid - distancePrice
   );

   bool requestResult = trade.SellStop(
      LotSize,
      price,
      _Symbol,
      0,
      0
   );

   if(!requestResult || !IsTradeSuccess())
   {
      Print(
         "SELL STOP FAILED",
         " | Price=", price,
         " | Bid=", bid,
         " | Spread=", GetCurrentSpreadPrice() / _Point,
         " pt",
         " | Distance=", distancePrice / _Point,
         " pt",
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
      " | Spread=", GetCurrentSpreadPrice() / _Point,
      " pt",
      " | Distance=", distancePrice / _Point,
      " pt"
   );
}

//+------------------------------------------------------------------+
//| Modify Buy Stop                                                  |
//| เรียกใช้เฉพาะตอนเกิดแท่งใหม่จาก OnTick                          |
//+------------------------------------------------------------------+
void ModifyBuyStop()
{
   if(PendingBuy == 0 || PositionBuy != 0)
      return;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(ask <= 0)
      return;

   double distancePrice = GetOrderDistancePrice();

   if(distancePrice <= 0)
      return;

   double newPrice = NormalizeBuyPrice(
      ask + distancePrice
   );

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

      if(type != ORDER_TYPE_BUY_STOP)
         continue;

      double oldPrice =
         OrderGetDouble(ORDER_PRICE_OPEN);

      if(MathAbs(newPrice - oldPrice) < (_Point / 2.0))
         continue;

      bool requestResult = trade.OrderModify(
         ticket,
         newPrice,
         0,
         0,
         ORDER_TIME_GTC,
         0,
         0
      );

      if(!requestResult || !IsTradeSuccess())
      {
         Print(
            "MODIFY BUY STOP FAILED",
            " | Ticket=", ticket,
            " | Old=", oldPrice,
            " | New=", newPrice,
            " | Spread=", GetCurrentSpreadPrice() / _Point,
            " pt",
            " | Distance=", distancePrice / _Point,
            " pt",
            " | Retcode=", trade.ResultRetcode(),
            " | ", trade.ResultRetcodeDescription()
         );
         continue;
      }

      Print(
         "MODIFY BUY STOP | NEW BAR",
         " | Ticket=", ticket,
         " | Old=", oldPrice,
         " | New=", newPrice,
         " | Ask=", ask,
         " | Spread=", GetCurrentSpreadPrice() / _Point,
         " pt",
         " | Distance=", distancePrice / _Point,
         " pt"
      );
   }
}

//+------------------------------------------------------------------+
//| Modify Sell Stop                                                 |
//| เรียกใช้เฉพาะตอนเกิดแท่งใหม่จาก OnTick                          |
//+------------------------------------------------------------------+
void ModifySellStop()
{
   if(PendingSell == 0 || PositionSell != 0)
      return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(bid <= 0)
      return;

   double distancePrice = GetOrderDistancePrice();

   if(distancePrice <= 0)
      return;

   double newPrice = NormalizeSellPrice(
      bid - distancePrice
   );

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

      if(type != ORDER_TYPE_SELL_STOP)
         continue;

      double oldPrice =
         OrderGetDouble(ORDER_PRICE_OPEN);

      if(MathAbs(newPrice - oldPrice) < (_Point / 2.0))
         continue;

      bool requestResult = trade.OrderModify(
         ticket,
         newPrice,
         0,
         0,
         ORDER_TIME_GTC,
         0,
         0
      );

      if(!requestResult || !IsTradeSuccess())
      {
         Print(
            "MODIFY SELL STOP FAILED",
            " | Ticket=", ticket,
            " | Old=", oldPrice,
            " | New=", newPrice,
            " | Spread=", GetCurrentSpreadPrice() / _Point,
            " pt",
            " | Distance=", distancePrice / _Point,
            " pt",
            " | Retcode=", trade.ResultRetcode(),
            " | ", trade.ResultRetcodeDescription()
         );
         continue;
      }

      Print(
         "MODIFY SELL STOP | NEW BAR",
         " | Ticket=", ticket,
         " | Old=", oldPrice,
         " | New=", newPrice,
         " | Bid=", bid,
         " | Spread=", GetCurrentSpreadPrice() / _Point,
         " pt",
         " | Distance=", distancePrice / _Point,
         " pt"
      );
   }
}


//+------------------------------------------------------------------+
//| Normalize BUY Position Stop Loss                                 |
//| BUY SL ใช้การปัดลง เพื่อไม่ให้ SL ขยับเข้าใกล้ราคาปัจจุบันเกินไป |
//+------------------------------------------------------------------+
double NormalizeBuyStopLoss(double price)
{
   double tickSize =
      SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tickSize <= 0)
      return NormalizeDouble(price, _Digits);

   price = MathFloor(price / tickSize) * tickSize;

   return NormalizeDouble(price, _Digits);
}

//+------------------------------------------------------------------+
//| Normalize SELL Position Stop Loss                                |
//| SELL SL ใช้การปัดขึ้น เพื่อไม่ให้ SL ขยับเข้าใกล้ราคาปัจจุบันเกินไป|
//+------------------------------------------------------------------+
double NormalizeSellStopLoss(double price)
{
   double tickSize =
      SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tickSize <= 0)
      return NormalizeDouble(price, _Digits);

   price = MathCeil(price / tickSize) * tickSize;

   return NormalizeDouble(price, _Digits);
}

//+------------------------------------------------------------------+
//| Check whether SL price is currently allowed by broker            |
//| ไม่เลื่อน SL ออกจากสูตร หากยังใกล้ราคาปัจจุบันเกินไปจะรอก่อน       |
//+------------------------------------------------------------------+
bool IsStopLossDistanceValid(
   ENUM_POSITION_TYPE type,
   double slPrice,
   double bid,
   double ask
)
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

   double minimumDistance =
      (MathMax(stopLevel, freezeLevel) + 1) * _Point;

   if(type == POSITION_TYPE_BUY)
      return (bid - slPrice) >= minimumDistance;

   if(type == POSITION_TYPE_SELL)
      return (slPrice - ask) >= minimumDistance;

   return false;
}

//+------------------------------------------------------------------+
//| Add Profit Stop Loss                                             |
//|                                                                  |
//| ไม่มี SL ตอนเปิด Position                                       |
//| BUY : Trigger เมื่อ Bid - Open >= Spread x Trigger               |
//|       SL = Open + Spread x Offset                                |
//| SELL: Trigger เมื่อ Open - Ask >= Spread x Trigger               |
//|       SL = Open - Spread x Offset                                |
//|                                                                  |
//| ตั้ง SL เฉพาะ Position ที่ SL ยังเป็น 0 และไม่ลากต่อหลังตั้งแล้ว    |
//+------------------------------------------------------------------+
void ManagePositionProfitStopLoss()
{
   MqlTick tick;

   if(!SymbolInfoTick(_Symbol, tick))
      return;

   if(tick.ask <= 0 || tick.bid <= 0 || tick.ask <= tick.bid)
      return;

   double spreadPrice = tick.ask - tick.bid;

   if(spreadPrice <= 0)
      return;

   double triggerDistance =
      spreadPrice * SLTriggerSpreadMultiplier;

   double slOffset =
      spreadPrice * SLOffsetSpreadMultiplier;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
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

      if(type != POSITION_TYPE_BUY &&
         type != POSITION_TYPE_SELL)
         continue;

      // ห้ามมี SL ตั้งแต่เริ่ม และถ้าเคยวางแล้วจะไม่ Modify SL ซ้ำ
      double currentSL =
         PositionGetDouble(POSITION_SL);

      if(currentSL > 0)
         continue;

      double openPrice =
         PositionGetDouble(POSITION_PRICE_OPEN);

      double currentTP =
         PositionGetDouble(POSITION_TP);

      if(openPrice <= 0)
         continue;

      double profitDistance = 0;
      double newSL = 0;

      if(type == POSITION_TYPE_BUY)
      {
         profitDistance = tick.bid - openPrice;

         if(profitDistance < triggerDistance)
            continue;

         newSL = NormalizeBuyStopLoss(
            openPrice + slOffset
         );

         // BUY SL ต้องอยู่เหนือราคาเข้าและต่ำกว่า Bid
         if(newSL <= openPrice || newSL >= tick.bid)
            continue;
      }
      else
      {
         profitDistance = openPrice - tick.ask;

         if(profitDistance < triggerDistance)
            continue;

         newSL = NormalizeSellStopLoss(
            openPrice - slOffset
         );

         // SELL SL ต้องอยู่ต่ำกว่าราคาเข้าและสูงกว่า Ask
         if(newSL >= openPrice || newSL <= tick.ask)
            continue;
      }

      // ถ้าระยะ Stop/Freeze ของ Broker ยังไม่ผ่าน ให้รอราคาวิ่งต่อ
      // โดยไม่เปลี่ยนสูตร SL = Position +/- Spread
      if(!IsStopLossDistanceValid(
            type,
            newSL,
            tick.bid,
            tick.ask
         ))
      {
         continue;
      }

      bool requestResult = trade.PositionModify(
         ticket,
         newSL,
         currentTP
      );

      if(!requestResult || !IsTradeSuccess())
      {
         Print(
            "SET PROFIT SL FAILED",
            " | Ticket=", ticket,
            " | Side=", (type == POSITION_TYPE_BUY ? "BUY" : "SELL"),
            " | Open=", openPrice,
            " | SL=", newSL,
            " | Spread=", spreadPrice / _Point,
            " pt",
            " | Trigger=", triggerDistance / _Point,
            " pt",
            " | ProfitDistance=", profitDistance / _Point,
            " pt",
            " | Retcode=", trade.ResultRetcode(),
            " | ", trade.ResultRetcodeDescription()
         );

         continue;
      }

      Print(
         "SET PROFIT SL",
         " | Ticket=", ticket,
         " | Side=", (type == POSITION_TYPE_BUY ? "BUY" : "SELL"),
         " | Open=", openPrice,
         " | SL=", newSL,
         " | Spread=", spreadPrice / _Point,
         " pt",
         " | Trigger=", triggerDistance / _Point,
         " pt",
         " | ProfitDistance=", profitDistance / _Point,
         " pt"
      );
   }
}

//+------------------------------------------------------------------+
//| Close Oldest Position If Both BUY and SELL Exist                 |
//+------------------------------------------------------------------+
bool CloseOldestPositionIfHedged()
{
   if(PositionBuy == 0 || PositionSell == 0)
      return false;

   ulong oldestTicket = 0;
   long  oldestTime   = 0;
   ENUM_POSITION_TYPE oldestType = POSITION_TYPE_BUY;

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

      if(type != POSITION_TYPE_BUY &&
         type != POSITION_TYPE_SELL)
         continue;

      long positionTime =
         PositionGetInteger(POSITION_TIME_MSC);

      if(oldestTicket == 0 || positionTime < oldestTime)
      {
         oldestTicket = ticket;
         oldestTime   = positionTime;
         oldestType   = type;
      }
   }

   if(oldestTicket == 0)
      return false;

   string side =
      (oldestType == POSITION_TYPE_BUY)
      ? "BUY"
      : "SELL";

   bool requestResult = trade.PositionClose(
      oldestTicket,
      SlippagePoint
   );

   if(!requestResult || !IsTradeSuccess())
   {
      Print(
         "CLOSE OLDEST POSITION FAILED",
         " | Ticket=", oldestTicket,
         " | Side=", side,
         " | TimeMSC=", oldestTime,
         " | Retcode=", trade.ResultRetcode(),
         " | ", trade.ResultRetcodeDescription()
      );
      return false;
   }

   Print(
      "CLOSE OLDEST POSITION",
      " | Ticket=", oldestTicket,
      " | Side=", side,
      " | TimeMSC=", oldestTime,
      " | Reason=BUY+SELL coexist"
   );

   return true;
}
