//+------------------------------------------------------------------+
//|                                    stop_recovery_close_all.mq5   |
//|  Base: stop_origin.mq5                                           |
//|                                                                  |
//|  Logic                                                           |
//|  1) วาง BUY STOP + SELL STOP ตาม logic เดิม                     |
//|  2) Pending ฝั่งตรงข้ามเลื่อนตามราคาเหมือนเดิม                  |
//|  3) เมื่อมี BUY และ SELL position พร้อมกัน -> ลบ pending +       |
//|     ปิด position ของ EA ทั้งหมดทันที                             |
//|  4) คำนวณผลของรอบที่ปิดจริงจาก Deal History                    |
//|  5) ถ้าขาดทุน -> สะสมเป็น RecoveryLoss                          |
//|  6) รอบถัดไปกลับไปใช้ entry logic เดิม แต่ใช้ RecoveryLot       |
//|     ที่คำนวณจาก RecoveryLoss (ไม่อิง position ล่าสุดที่ trigger) |
//|  7) กำไรของรอบถัดไปจะหัก RecoveryLoss จนเหลือ 0 แล้วกลับ BaseLot|
//|  8) Pending distance = Spread(Ask-Bid) x 2 แบบ Dynamic          |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "2.01"
#property strict

#include <Trade/Trade.mqh>

CTrade trade;

//==================================================================
// GLOBAL INPUT
//==================================================================
input int    CandleRate          = 10;
input double LotSize             = 0.01;   // Base lot
input double DistanceMultiplier  = 2.0;    // Dynamic distance = Spread(Ask-Bid) x multiplier
input int    SlippagePoint       = 20;
input ulong  Magic               = 10001;

// คง input เดิมไว้เพื่อไม่ให้โครง LoadPrices เปลี่ยนมากเกินไป
input int    TrendBars           = 3;
input int    TrendStartShift     = 3;

// RecoveryLot จะคำนวณว่า ถ้าราคาเดินทาง RecoveryTargetPoint
// จะมีศักยภาพทำกำไรประมาณ RecoveryLoss ที่ค้างอยู่
input int    RecoveryTargetPoint = 500;

// เพดาน Recovery lot เพื่อกัน lot โตแบบไม่จำกัด
// 0 = ใช้ SYMBOL_VOLUME_MAX ของ broker
input double MaxRecoveryLot      = 1.00;

//==================================================================
// GLOBAL STATE
//==================================================================
MqlRates prices[];

int PendingBuy  = 0;
int PendingSell = 0;

int PositionBuy  = 0;
int PositionSell = 0;

// หนี้ขาดทุนที่ยังต้อง Recover
// > 0 = Recovery mode
// = 0 = Normal mode
// หมายเหตุ: ค่านี้อยู่ใน memory ของ EA และจะ reset เมื่อ re-init/restart
// หากต้องการ persist ข้าม restart สามารถเพิ่ม GlobalVariable ภายหลังได้
double RecoveryLoss = 0.0;

// เวลาเริ่มรอบปัจจุบัน ใช้กรอง Deal History ให้ไม่ปนรอบก่อนหน้า
long CycleStartTimeMsc = 0;

// true ระหว่างกระบวนการลบ pending + ปิด positions
// เพื่อป้องกัน EA เปิด order ใหม่ก่อนปิดรอบเก่าเสร็จ
bool CycleClosing = false;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   // EA นี้ต้องใช้ Hedging Account
   ENUM_ACCOUNT_MARGIN_MODE marginMode =
      (ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(
         ACCOUNT_MARGIN_MODE
      );

   if(marginMode != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
   {
      Print("INIT FAILED | EA requires HEDGING account");
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(Magic);
   trade.SetMarginMode();
   trade.SetDeviationInPoints(SlippagePoint);
   trade.SetTypeFillingBySymbol(_Symbol);

   RecoveryLoss      = 0.0;
   CycleStartTimeMsc = 0;
   CycleClosing      = false;

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
   if(!LoadPrices(CandleRate))
      return;

   LoadTradeState();
   UpdateCycleStartFromPositions();

   //===============================================================
   // ถ้ากำลังปิดรอบอยู่ ห้ามเปิด order ใหม่จนกว่าจะปิดหมดจริง
   //===============================================================
   if(CycleClosing)
   {
      ProcessCycleClose();
      return;
   }

   //===============================================================
   // เงื่อนไขใหม่หลัก:
   // เมื่อมี BUY + SELL position พร้อมกัน ให้จบรอบทันที
   // ไม่มี Basket Target และไม่มี Recovery Direction
   //===============================================================
   if(PositionBuy > 0 && PositionSell > 0)
   {
      Print(
         "HEDGE DETECTED -> CLOSE ALL",
         " | Buy=", PositionBuy,
         " | Sell=", PositionSell,
         " | RecoveryLossBefore=", DoubleToString(RecoveryLoss, 2)
      );

      CycleClosing = true;
      ProcessCycleClose();
      return;
   }

   //===============================================================
   // OPEN - ใช้ logic เดิม
   // ต่างกันเพียง Lot จะเป็น BaseLot หรือ RecoveryLot
   //===============================================================
   OpenBuyStop();
   OpenSellStop();

   // refresh state เพราะอาจมี pending เปิดใหม่
   LoadTradeState();

   //===============================================================
   // MODIFY - ใช้ trailing pending logic เดิม
   //===============================================================
   ModifyBuyStop();
   ModifySellStop();
}

//+------------------------------------------------------------------+
//| Load Prices                                                      |
//+------------------------------------------------------------------+
bool LoadPrices(const int candle)
{
   ArraySetAsSeries(prices, true);

   int minimumBars =
      TrendStartShift +
      TrendBars +
      1;

   int requiredBars = MathMax(candle, minimumBars);

   int copied = CopyRates(
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
   PendingBuy  = 0;
   PendingSell = 0;

   PositionBuy  = 0;
   PositionSell = 0;

   // PENDING ORDERS
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

   // POSITIONS
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
//| เก็บเวลาเริ่มรอบจาก position ตัวแรกของรอบ                       |
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

      long positionTimeMsc =
         PositionGetInteger(POSITION_TIME_MSC);

      if(
         positionTimeMsc > 0 &&
         (oldestTimeMsc == 0 || positionTimeMsc < oldestTimeMsc)
      )
      {
         oldestTimeMsc = positionTimeMsc;
      }
   }

   if(oldestTimeMsc > 0)
   {
      CycleStartTimeMsc = oldestTimeMsc;

      Print(
         "CYCLE START",
         " | TimeMsc=", CycleStartTimeMsc,
         " | LotMode=", (RecoveryLoss > 0 ? "RECOVERY" : "NORMAL"),
         " | RecoveryLoss=", DoubleToString(RecoveryLoss, 2)
      );
   }
}

//+------------------------------------------------------------------+
//| Get Dynamic Distance Point                                       |
//| Distance = (Ask - Bid) / _Point * DistanceMultiplier             |
//| Default: Spread x 2                                              |
//| และต้องไม่น้อยกว่าระยะขั้นต่ำของ Broker                          |
//+------------------------------------------------------------------+
int GetDistancePoint()
{
   MqlTick tick;

   if(!SymbolInfoTick(_Symbol, tick))
      return 0;

   if(tick.ask <= 0 || tick.bid <= 0 || tick.ask < tick.bid)
      return 0;

   double spreadPoint =
      (tick.ask - tick.bid) / _Point;

   int dynamicDistance =
      (int)MathCeil(
         spreadPoint * DistanceMultiplier
      );

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

   int brokerMinimum = MathMax(
      stopLevel,
      freezeLevel
   );

   // กันกรณี spread เล็กผิดปกติ หรือ Broker บังคับ minimum distance
   return MathMax(
      dynamicDistance,
      brokerMinimum + 1
   );
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

   price = MathCeil(price / tickSize) * tickSize;

   return NormalizeDouble(price, _Digits);
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
//| Volume digits from volume step                                   |
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
//| Normalize Volume Up                                              |
//| ปัดขึ้นเพื่อไม่ให้ RecoveryLot ต่ำกว่า lot ที่คำนวณ              |
//+------------------------------------------------------------------+
double NormalizeVolumeUp(double volume)
{
   double minVolume =
      SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   double maxVolume =
      SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   double step =
      SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(minVolume <= 0)
      minVolume = LotSize;

   if(maxVolume <= 0)
      maxVolume = volume;

   if(step <= 0)
      step = minVolume;

   // ทำ max ให้ลง step ก่อน
   double safeMax = MathFloor((maxVolume / step) + 1e-10) * step;

   if(safeMax < minVolume)
      safeMax = minVolume;

   volume = MathMax(volume, minVolume);
   volume = MathCeil((volume / step) - 1e-10) * step;
   volume = MathMin(volume, safeMax);

   return NormalizeDouble(
      volume,
      GetVolumeDigits(step)
   );
}

//+------------------------------------------------------------------+
//| Calculate Recovery Lot                                           |
//| ไม่เลือก BUY/SELL จากไม้ล่าสุด                                   |
//| คำนวณศักยภาพกำไรต่อ 1 lot ของทั้งสองฝั่ง แล้วใช้ค่าที่ต่ำกว่า   |
//| เพื่อให้ sizing conservative กว่า                                |
//+------------------------------------------------------------------+
double CalculateRecoveryLot()
{
   if(RecoveryLoss <= 0)
      return NormalizeVolumeUp(LotSize);

   if(RecoveryTargetPoint <= 0)
   {
      Print(
         "RECOVERY LOT FALLBACK",
         " | RecoveryTargetPoint must be > 0"
      );

      return NormalizeVolumeUp(LotSize);
   }

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(ask <= 0 || bid <= 0)
      return NormalizeVolumeUp(LotSize);

   int distancePoint = GetDistancePoint();

   if(distancePoint <= 0)
      return NormalizeVolumeUp(LotSize);

   double buyEntry = NormalizeBuyPrice(
      ask + distancePoint * _Point
   );

   double buyTarget = NormalizeBuyPrice(
      buyEntry + RecoveryTargetPoint * _Point
   );

   double sellEntry = NormalizeSellPrice(
      bid - distancePoint * _Point
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
   {
      Print(
         "RECOVERY LOT FALLBACK",
         " | OrderCalcProfit failed",
         " | RecoveryLoss=", DoubleToString(RecoveryLoss, 2)
      );

      return NormalizeVolumeUp(LotSize);
   }

   double rawLot = RecoveryLoss / profitPerLot;

   // Recovery lot ต้องไม่ต่ำกว่า Base lot
   rawLot = MathMax(rawLot, LotSize);

   double recoveryLot = NormalizeVolumeUp(rawLot);

   // MaxRecoveryLot จำกัดเฉพาะ Recovery mode เท่านั้น
   if(MaxRecoveryLot > 0)
   {
      double minVolume = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      double step      = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

      if(step <= 0)
         step = (minVolume > 0 ? minVolume : 0.01);

      double requestedCap = MathMax(MaxRecoveryLot, LotSize);

      double recoveryCap =
         MathFloor((requestedCap / step) + 1e-10) * step;

      if(minVolume > 0)
         recoveryCap = MathMax(recoveryCap, minVolume);

      recoveryLot = MathMin(recoveryLot, recoveryCap);
      recoveryLot = NormalizeDouble(recoveryLot, GetVolumeDigits(step));
   }

   Print(
      "RECOVERY LOT CALC",
      " | RecoveryLoss=", DoubleToString(RecoveryLoss, 2),
      " | TargetPoint=", RecoveryTargetPoint,
      " | ProfitPerLot=", DoubleToString(profitPerLot, 2),
      " | RawLot=", DoubleToString(rawLot, 8),
      " | FinalLot=", DoubleToString(recoveryLot, 8)
   );

   return recoveryLot;
}

//+------------------------------------------------------------------+
//| Get lot for next order                                           |
//+------------------------------------------------------------------+
double GetCurrentTradeLot()
{
   if(RecoveryLoss > 0)
      return CalculateRecoveryLot();

   return NormalizeVolumeUp(LotSize);
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

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(ask <= 0)
      return;

   int distancePoint = GetDistancePoint();

   if(distancePoint <= 0)
      return;

   double price = NormalizeBuyPrice(
      ask +
      (distancePoint * _Point)
   );

   double volume = GetCurrentTradeLot();

   if(volume <= 0)
      return;

   bool requestResult = trade.BuyStop(
      volume,
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
         " | Lot=", volume,
         " | Price=", price,
         " | Retcode=", trade.ResultRetcode(),
         " | ", trade.ResultRetcodeDescription()
      );

      return;
   }

   Print(
      "BUY STOP OPEN",
      " | Ticket=", trade.ResultOrder(),
      " | Lot=", volume,
      " | Mode=", (RecoveryLoss > 0 ? "RECOVERY" : "NORMAL"),
      " | RecoveryLoss=", DoubleToString(RecoveryLoss, 2),
      " | Price=", price,
      " | Ask=", ask,
      " | DistancePoint=", distancePoint,
      " | SpreadPoint=", DoubleToString((ask - SymbolInfoDouble(_Symbol, SYMBOL_BID)) / _Point, 1),
      " | Multiplier=", DoubleToString(DistanceMultiplier, 2)
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

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(bid <= 0)
      return;

   int distancePoint = GetDistancePoint();

   if(distancePoint <= 0)
      return;

   double price = NormalizeSellPrice(
      bid -
      (distancePoint * _Point)
   );

   double volume = GetCurrentTradeLot();

   if(volume <= 0)
      return;

   bool requestResult = trade.SellStop(
      volume,
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
         " | Lot=", volume,
         " | Price=", price,
         " | Retcode=", trade.ResultRetcode(),
         " | ", trade.ResultRetcodeDescription()
      );

      return;
   }

   Print(
      "SELL STOP OPEN",
      " | Ticket=", trade.ResultOrder(),
      " | Lot=", volume,
      " | Mode=", (RecoveryLoss > 0 ? "RECOVERY" : "NORMAL"),
      " | RecoveryLoss=", DoubleToString(RecoveryLoss, 2),
      " | Price=", price,
      " | Bid=", bid,
      " | DistancePoint=", distancePoint,
      " | SpreadPoint=", DoubleToString((SymbolInfoDouble(_Symbol, SYMBOL_ASK) - bid) / _Point, 1),
      " | Multiplier=", DoubleToString(DistanceMultiplier, 2)
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

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(ask <= 0)
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

      ENUM_ORDER_TYPE type =
         (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);

      if(type != ORDER_TYPE_BUY_STOP)
         continue;

      double oldPrice = OrderGetDouble(ORDER_PRICE_OPEN);

      double distance =
         (oldPrice - ask) /
         _Point;

      // ราคาเคลื่อนลงหนี BUY STOP เกินระยะที่กำหนด
      // ให้เลื่อน BUY STOP ลงมาตามราคา
      if(distance > distancePoint)
      {
         double newPrice = NormalizeBuyPrice(
            ask +
            (distancePoint * _Point)
         );

         if(
            MathAbs(newPrice - oldPrice) <
            (_Point / 2.0)
         )
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

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(bid <= 0)
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

      ENUM_ORDER_TYPE type =
         (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);

      if(type != ORDER_TYPE_SELL_STOP)
         continue;

      double oldPrice = OrderGetDouble(ORDER_PRICE_OPEN);

      double distance =
         (bid - oldPrice) /
         _Point;

      // ราคาเคลื่อนขึ้นหนี SELL STOP เกินระยะที่กำหนด
      // ให้เลื่อน SELL STOP ขึ้นมาตามราคา
      if(distance > distancePoint)
      {
         double newPrice = NormalizeSellPrice(
            bid -
            (distancePoint * _Point)
         );

         if(
            MathAbs(newPrice - oldPrice) <
            (_Point / 2.0)
         )
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
//| Delete All Pending Orders                                        |
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

      if(
         type != ORDER_TYPE_BUY_STOP &&
         type != ORDER_TYPE_SELL_STOP &&
         type != ORDER_TYPE_BUY_LIMIT &&
         type != ORDER_TYPE_SELL_LIMIT &&
         type != ORDER_TYPE_BUY_STOP_LIMIT &&
         type != ORDER_TYPE_SELL_STOP_LIMIT
      )
         continue;

      bool result = trade.OrderDelete(ticket);

      if(
         !result ||
         !IsTradeSuccess()
      )
      {
         Print(
            "DELETE PENDING FAILED",
            " | Ticket=", ticket,
            " | Retcode=", trade.ResultRetcode(),
            " | ", trade.ResultRetcodeDescription()
         );
      }
      else
      {
         Print(
            "PENDING DELETED",
            " | Ticket=", ticket
         );
      }
   }
}

//+------------------------------------------------------------------+
//| Close All Positions                                              |
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

      bool result = trade.PositionClose(
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
            " | ", trade.ResultRetcodeDescription()
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
//| Process Cycle Close                                              |
//+------------------------------------------------------------------+
void ProcessCycleClose()
{
   // ลบ pending ก่อน เพื่อป้องกันมี pending trigger เพิ่มระหว่างปิด
   DeleteAllPending();

   // ปิดทุก position ของ symbol + magic นี้
   CloseAllPositions();

   // ตรวจอีกครั้งว่าปิดหมดจริงหรือยัง
   LoadTradeState();

   if(
      PositionBuy != 0 ||
      PositionSell != 0 ||
      PendingBuy != 0 ||
      PendingSell != 0
   )
   {
      // ยังมีค้าง -> tick ถัดไปจะเข้ามาปิดซ้ำ
      return;
   }

   // ปิดหมดแล้วจึงคำนวณผลจริงของรอบ
   FinalizeCycleRecovery();

   CycleClosing      = false;
   CycleStartTimeMsc = 0;

   Print(
      "CYCLE CLOSED COMPLETE",
      " | RecoveryLossAfter=", DoubleToString(RecoveryLoss, 2),
      " | NextMode=", (RecoveryLoss > 0 ? "RECOVERY" : "NORMAL")
   );
}

//+------------------------------------------------------------------+
//| Get result of the just-closed cycle from deal history            |
//| Result = PROFIT + SWAP + COMMISSION + FEE                        |
//+------------------------------------------------------------------+
bool GetClosedCycleResult(double &cycleResult)
{
   cycleResult = 0.0;

   if(CycleStartTimeMsc <= 0)
   {
      Print(
         "CYCLE RESULT FAILED",
         " | CycleStartTimeMsc is 0"
      );

      return false;
   }

   datetime fromTime =
      (datetime)MathMax(
         0.0,
         (double)(CycleStartTimeMsc / 1000) - 2.0
      );

   datetime toTime = TimeCurrent() + 2;

   if(!HistorySelect(fromTime, toTime))
   {
      Print(
         "CYCLE RESULT FAILED",
         " | HistorySelect failed"
      );

      return false;
   }

   int dealCount = 0;
   int totalDeals = HistoryDealsTotal();

   for(int i = 0; i < totalDeals; i++)
   {
      ulong dealTicket = HistoryDealGetTicket(i);

      if(dealTicket == 0)
         continue;

      string symbol =
         HistoryDealGetString(
            dealTicket,
            DEAL_SYMBOL
         );

      if(symbol != _Symbol)
         continue;

      ulong dealMagic =
         (ulong)HistoryDealGetInteger(
            dealTicket,
            DEAL_MAGIC
         );

      if(dealMagic != Magic)
         continue;

      long dealTimeMsc =
         HistoryDealGetInteger(
            dealTicket,
            DEAL_TIME_MSC
         );

      // กัน deal จากรอบก่อนหน้าที่อยู่ใน HistorySelect buffer 2 วินาที
      if(dealTimeMsc < CycleStartTimeMsc)
         continue;

      double profit =
         HistoryDealGetDouble(
            dealTicket,
            DEAL_PROFIT
         );

      double swap =
         HistoryDealGetDouble(
            dealTicket,
            DEAL_SWAP
         );

      double commission =
         HistoryDealGetDouble(
            dealTicket,
            DEAL_COMMISSION
         );

      double fee =
         HistoryDealGetDouble(
            dealTicket,
            DEAL_FEE
         );

      cycleResult +=
         profit +
         swap +
         commission +
         fee;

      dealCount++;
   }

   if(dealCount == 0)
   {
      Print(
         "CYCLE RESULT FAILED",
         " | No deals found",
         " | StartMsc=", CycleStartTimeMsc
      );

      return false;
   }

   Print(
      "CYCLE RESULT",
      " | Deals=", dealCount,
      " | Net=", DoubleToString(cycleResult, 2)
   );

   return true;
}

//+------------------------------------------------------------------+
//| Update Recovery Debt                                             |
//+------------------------------------------------------------------+
void FinalizeCycleRecovery()
{
   double cycleResult = 0.0;

   if(!GetClosedCycleResult(cycleResult))
   {
      // ถ้าหาผลรอบไม่ได้ จะไม่เดา RecoveryLoss
      // เพื่อป้องกันการเพิ่ม lot จากข้อมูลผิด
      Print(
         "RECOVERY NOT UPDATED",
         " | Could not calculate closed cycle result"
      );

      return;
   }

   // ขาดทุน -> เพิ่มหนี้ recovery
   if(cycleResult < 0)
   {
      RecoveryLoss += MathAbs(cycleResult);

      Print(
         "RECOVERY LOSS ADDED",
         " | CycleLoss=", DoubleToString(MathAbs(cycleResult), 2),
         " | RecoveryLoss=", DoubleToString(RecoveryLoss, 2)
      );

      return;
   }

   // กำไร -> หักหนี้ recovery ที่ค้างอยู่
   if(cycleResult > 0 && RecoveryLoss > 0)
   {
      double oldRecoveryLoss = RecoveryLoss;

      RecoveryLoss = MathMax(
         0.0,
         RecoveryLoss - cycleResult
      );

      Print(
         "RECOVERY LOSS REDUCED",
         " | CycleProfit=", DoubleToString(cycleResult, 2),
         " | Before=", DoubleToString(oldRecoveryLoss, 2),
         " | After=", DoubleToString(RecoveryLoss, 2)
      );

      return;
   }

   // กำไรใน Normal mode ไม่ต้องทำอะไร
   Print(
      "NORMAL CYCLE PROFIT",
      " | CycleProfit=", DoubleToString(cycleResult, 2),
      " | RecoveryLoss=", DoubleToString(RecoveryLoss, 2)
   );
}
