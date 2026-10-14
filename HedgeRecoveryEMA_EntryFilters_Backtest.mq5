//+------------------------------------------------------------------+
//|                                  HedgeRecoveryEMA.mq5            |
//+------------------------------------------------------------------+
#property strict

#include <Trade/Trade.mqh>

CTrade trade;


//====================================================
// INPUT
//====================================================
input double Lot            = 0.01;
input double LotStep        = 0.01;
input double LotRatio       = 3.0;

input int    DistancePoints = 500;

// Target floating basket profit in account currency (e.g. USD or USC)
// Calculates only positions matching current _Symbol and MagicNumber.
input double BasketTakeProfit = 10.0;

// Close EA positions after price remains inside the position-open-price range.
// A value of 20 means 20 continuous minutes (not 20 M1 candles).
input bool   EnableRangeTimeout  = true;
input int    RangeTimeoutMinutes = 20;

input int    EMAFastPeriod  = 8;
input int    EMASlowPeriod  = 21;

// INITIAL-only entry filters: recovery and closing logic are unchanged.
// Indicators are evaluated on the LAST CLOSED bar of EntryFilterTF.
input bool            EnableRSIFilter = false;
input bool            EnableADXFilter = false;
input ENUM_TIMEFRAMES EntryFilterTF   = PERIOD_M5;
input int             RSIPeriod       = 14;
input double          RSIEntryMin     = 30.0;
input double          RSIEntryMax     = 70.0;
input int             ADXPeriod       = 14;
input double          ADXEntryMin     = 20.0;
input double          ADXEntryMax     = 40.0;

input ulong  MagicNumber    = 26092901;


//====================================================
// GLOBAL
//====================================================
bool initial = true;

// Once basket TP is reached, finish closing all EA positions even if P/L fluctuates.
bool basket_closing = false;
// Latch timeout closing until every EA position has been closed.
bool range_closing = false;

// The fixed range comes from the lowest and highest open prices of EA positions.
datetime range_enter_time  = 0;
double   tracked_range_high = 0.0;
double   tracked_range_low  = 0.0;
int      tracked_range_count = 0;
bool     range_inside = false;

int recovery_level = 0;

double buy_lot  = 0.0;
double sell_lot = 0.0;


//====================================================
// EMA
//====================================================
int handle_ema_fast = INVALID_HANDLE;
int handle_ema_slow = INVALID_HANDLE;
int handle_entry_rsi = INVALID_HANDLE;
int handle_entry_adx = INVALID_HANDLE;
string entry_filter_status = "READY";
double last_entry_rsi = -1.0;
double last_entry_adx = -1.0;


//====================================================
// PANEL
//====================================================
string PANEL_PREFIX = "HRE_PANEL_";


//+------------------------------------------------------------------+
//| Volume Digits                                                    |
//+------------------------------------------------------------------+
int GetVolumeDigits()
{
   double step =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_VOLUME_STEP
      );

   int digits = 0;

   while(
      step < 1.0
      &&
      digits < 8
   )
   {
      step *= 10.0;
      digits++;
   }

   return digits;
}


//+------------------------------------------------------------------+
//| Normalize Lot                                                    |
//+------------------------------------------------------------------+
double NormalizeLot(double volume)
{
   double min_lot =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_VOLUME_MIN
      );

   double max_lot =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_VOLUME_MAX
      );

   double lot_step =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_VOLUME_STEP
      );


   if(lot_step <= 0)
      lot_step = 0.01;


   volume =
      MathMax(
         min_lot,
         MathMin(
            max_lot,
            volume
         )
      );


   volume =
      MathRound(
         volume / lot_step
      )
      *
      lot_step;


   return NormalizeDouble(
      volume,
      GetVolumeDigits()
   );
}


//+------------------------------------------------------------------+
//| Count Position                                                   |
//+------------------------------------------------------------------+
int CountPosition()
{
   int count = 0;


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
         PositionGetString(POSITION_SYMBOL)
         !=
         _Symbol
      )
         continue;


      if(
         (ulong)PositionGetInteger(POSITION_MAGIC)
         !=
         MagicNumber
      )
         continue;


      count++;
   }


   return count;
}


//+------------------------------------------------------------------+
//| Count BUY                                                        |
//+------------------------------------------------------------------+
int CountBuyPosition()
{
   int count = 0;


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
         PositionGetString(POSITION_SYMBOL)
         !=
         _Symbol
      )
         continue;


      if(
         (ulong)PositionGetInteger(POSITION_MAGIC)
         !=
         MagicNumber
      )
         continue;


      if(
         (ENUM_POSITION_TYPE)
         PositionGetInteger(POSITION_TYPE)
         ==
         POSITION_TYPE_BUY
      )
      {
         count++;
      }
   }


   return count;
}


//+------------------------------------------------------------------+
//| Count SELL                                                       |
//+------------------------------------------------------------------+
int CountSellPosition()
{
   int count = 0;


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
         PositionGetString(POSITION_SYMBOL)
         !=
         _Symbol
      )
         continue;


      if(
         (ulong)PositionGetInteger(POSITION_MAGIC)
         !=
         MagicNumber
      )
         continue;


      if(
         (ENUM_POSITION_TYPE)
         PositionGetInteger(POSITION_TYPE)
         ==
         POSITION_TYPE_SELL
      )
      {
         count++;
      }
   }


   return count;
}


//+------------------------------------------------------------------+
//| Total BUY Lot                                                    |
//+------------------------------------------------------------------+
double GetTotalBuyLot()
{
   double total_lot = 0.0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);

      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;

      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_BUY)
         continue;

      total_lot += PositionGetDouble(POSITION_VOLUME);
   }

   return NormalizeDouble(total_lot, GetVolumeDigits());
}


//+------------------------------------------------------------------+
//| Total SELL Lot                                                   |
//+------------------------------------------------------------------+
double GetTotalSellLot()
{
   double total_lot = 0.0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);

      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;

      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_SELL)
         continue;

      total_lot += PositionGetDouble(POSITION_VOLUME);
   }

   return NormalizeDouble(total_lot, GetVolumeDigits());
}


//+------------------------------------------------------------------+
//| Floating Profit                                                  |
//+------------------------------------------------------------------+
double GetFloatingProfit()
{
   double profit = 0.0;


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
         PositionGetString(POSITION_SYMBOL)
         !=
         _Symbol
      )
         continue;


      if(
         (ulong)PositionGetInteger(POSITION_MAGIC)
         !=
         MagicNumber
      )
         continue;


      profit +=
         PositionGetDouble(
            POSITION_PROFIT
         );


      profit +=
         PositionGetDouble(
            POSITION_SWAP
         );
   }


   return profit;
}


//+------------------------------------------------------------------+
//| Highest Position Price                                           |
//+------------------------------------------------------------------+
double GetHighestPositionPrice()
{
   double highest = 0.0;
   bool found = false;


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
         PositionGetString(POSITION_SYMBOL)
         !=
         _Symbol
      )
         continue;


      if(
         (ulong)PositionGetInteger(POSITION_MAGIC)
         !=
         MagicNumber
      )
         continue;


      double price =
         PositionGetDouble(
            POSITION_PRICE_OPEN
         );


      if(
         !found
         ||
         price > highest
      )
      {
         highest = price;
         found = true;
      }
   }


   if(!found)
      return 0.0;


   return highest;
}


//+------------------------------------------------------------------+
//| Lowest Position Price                                            |
//+------------------------------------------------------------------+
double GetLowestPositionPrice()
{
   double lowest = 0.0;
   bool found = false;


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
         PositionGetString(POSITION_SYMBOL)
         !=
         _Symbol
      )
         continue;


      if(
         (ulong)PositionGetInteger(POSITION_MAGIC)
         !=
         MagicNumber
      )
         continue;


      double price =
         PositionGetDouble(
            POSITION_PRICE_OPEN
         );


      if(
         !found
         ||
         price < lowest
      )
      {
         lowest = price;
         found = true;
      }
   }


   if(!found)
      return 0.0;


   return lowest;
}


//+------------------------------------------------------------------+
//| EMA                                                              |
//+------------------------------------------------------------------+
bool GetEMAValue(
   double &fast,
   double &slow
)
{
   double fast_buffer[1];
   double slow_buffer[1];


   // แท่งปิดล่าสุด
   if(
      CopyBuffer(
         handle_ema_fast,
         0,
         1,
         1,
         fast_buffer
      )
      !=
      1
   )
      return false;


   if(
      CopyBuffer(
         handle_ema_slow,
         0,
         1,
         1,
         slow_buffer
      )
      !=
      1
   )
      return false;


   fast = fast_buffer[0];
   slow = slow_buffer[0];


   return true;
}


//+------------------------------------------------------------------+
//| Recovery Base Lot                                                |
//+------------------------------------------------------------------+
double GetRecoveryBaseLot()
{
   //==================================================
   // Recovery 0 = Lot
   // Recovery 1 = Lot + LotStep
   // Recovery 2 = Lot + LotStep * 2
   //==================================================
   double base =
      Lot
      +
      (
         LotStep
         *
         recovery_level
      );


   return NormalizeLot(base);
}


//+------------------------------------------------------------------+
//| Calculate Recovery Lots                                          |
//+------------------------------------------------------------------+
bool CalculateRecoveryLots(
   double ema_fast,
   double ema_slow,
   double &recovery_buy,
   double &recovery_sell
)
{
   double base_lot =
      GetRecoveryBaseLot();


   //==================================================
   // BULLISH
   //
   // SELL : BUY = 1 : 3
   //==================================================
   if(
      ema_fast
      >
      ema_slow
   )
   {
      recovery_buy =
         NormalizeLot(
            base_lot
            *
            LotRatio
         );


      recovery_sell =
         NormalizeLot(
            base_lot
         );


      return true;
   }


   //==================================================
   // BEARISH
   //
   // BUY : SELL = 1 : 3
   //==================================================
   if(
      ema_fast
      <
      ema_slow
   )
   {
      recovery_buy =
         NormalizeLot(
            base_lot
         );


      recovery_sell =
         NormalizeLot(
            base_lot
            *
            LotRatio
         );


      return true;
   }


   return false;
}


//+------------------------------------------------------------------+
//| Open Hedge                                                       |
//+------------------------------------------------------------------+
bool OpenHedgePosition(
   double buy_volume,
   double sell_volume,
   string order_comment
)
{
   trade.SetExpertMagicNumber(
      MagicNumber
   );


   buy_volume =
      NormalizeLot(
         buy_volume
      );


   sell_volume =
      NormalizeLot(
         sell_volume
      );


   //==================================================
   // BUY
   //==================================================
   bool buy_result =
      trade.Buy(
         buy_volume,
         _Symbol,
         0,
         0,
         0,
         order_comment + " BUY"
      );


   if(!buy_result)
   {
      Print(
         "BUY ERROR",
         " | ",
         trade.ResultRetcode(),
         " | ",
         trade.ResultRetcodeDescription()
      );


      return false;
   }


   //==================================================
   // SELL
   //==================================================
   bool sell_result =
      trade.Sell(
         sell_volume,
         _Symbol,
         0,
         0,
         0,
         order_comment + " SELL"
      );


   if(!sell_result)
   {
      Print(
         "SELL ERROR",
         " | ",
         trade.ResultRetcode(),
         " | ",
         trade.ResultRetcodeDescription()
      );


      return false;
   }


   Print(
      order_comment,
      " | BUY = ",
      buy_volume,
      " | SELL = ",
      sell_volume
   );


   return true;
}


//+------------------------------------------------------------------+
//| Allow a NEW basket only if enabled entry filters pass.          |
//| Shift 1 = last CLOSED bar, never the forming candle (shift 0).  |
//+------------------------------------------------------------------+
bool IsInitialEntryAllowed()
{
   entry_filter_status = "READY";

   if(EnableRSIFilter)
   {
      double rsi_value[1];
      if(handle_entry_rsi == INVALID_HANDLE ||
         CopyBuffer(handle_entry_rsi, 0, 1, 1, rsi_value) != 1 ||
         !MathIsValidNumber(rsi_value[0]))
      {
         entry_filter_status = "WAIT RSI DATA";
         return false;
      }

      last_entry_rsi = rsi_value[0];
      if(last_entry_rsi < RSIEntryMin || last_entry_rsi > RSIEntryMax)
      {
         entry_filter_status = "WAIT RSI";
         return false;
      }
   }

   if(EnableADXFilter)
   {
      double adx_value[1];
      // iADX: buffer 0 = MAIN_LINE (ADX), 1 = +DI, 2 = -DI.
      if(handle_entry_adx == INVALID_HANDLE ||
         CopyBuffer(handle_entry_adx, 0, 1, 1, adx_value) != 1 ||
         !MathIsValidNumber(adx_value[0]))
      {
         entry_filter_status = "WAIT ADX DATA";
         return false;
      }

      last_entry_adx = adx_value[0];
      if(last_entry_adx < ADXEntryMin || last_entry_adx > ADXEntryMax)
      {
         entry_filter_status = "WAIT ADX";
         return false;
      }
   }

   return true;
}

//+------------------------------------------------------------------+
//| Initial                                                          |
//+------------------------------------------------------------------+
bool OpenInitialPosition()
{
   buy_lot =
      NormalizeLot(
         Lot
      );


   sell_lot =
      NormalizeLot(
         Lot
      );


   return OpenHedgePosition(
      buy_lot,
      sell_lot,
      "INITIAL"
   );
}


//+------------------------------------------------------------------+
//| Recovery                                                         |
//+------------------------------------------------------------------+
void OpenRecovery(
   string recovery_type
)
{
   double ema_fast = 0.0;
   double ema_slow = 0.0;


   if(
      !GetEMAValue(
         ema_fast,
         ema_slow
      )
   )
      return;


   double recovery_buy  = 0.0;
   double recovery_sell = 0.0;


   if(
      !CalculateRecoveryLots(
         ema_fast,
         ema_slow,
         recovery_buy,
         recovery_sell
      )
   )
   {
      Print(
         recovery_type,
         " | EMA FLAT",
         " | NO RECOVERY"
      );


      return;
   }


   //==================================================
   // เก็บค่าไว้แสดง Panel
   //==================================================
   buy_lot =
      recovery_buy;


   sell_lot =
      recovery_sell;


   string trend = "";


   if(
      ema_fast
      >
      ema_slow
   )
   {
      trend = "BUY";
   }
   else
   {
      trend = "SELL";
   }


   Print(
      recovery_type,
      " | EMA = ",
      trend,
      " | LEVEL = ",
      recovery_level + 1,
      " | BUY LOT = ",
      buy_lot,
      " | SELL LOT = ",
      sell_lot
   );


   //==================================================
   // OPEN
   //==================================================
   if(
      OpenHedgePosition(
         buy_lot,
         sell_lot,
         recovery_type + " EMA " + trend
      )
   )
   {
      //===============================================
      // เพิ่ม Level เฉพาะเมื่อเปิดสำเร็จ
      //===============================================
      recovery_level++;
   }
}


//+------------------------------------------------------------------+
//| Recovery Down                                                    |
//+------------------------------------------------------------------+
void RecoveryDown(
   double ask,
   double lowest_price
)
{
   double distance =
      DistancePoints
      *
      _Point;


   //==================================================
   // เงื่อนไขเดิม
   //
   // Ask + Distance <= Lowest
   //==================================================
   if(
      ask + distance
      <=
      lowest_price
   )
   {
      OpenRecovery(
         "RECOVERY DOWN"
      );
   }
}


//+------------------------------------------------------------------+
//| Recovery Up                                                      |
//+------------------------------------------------------------------+
void RecoveryUp(
   double bid,
   double highest_price
)
{
   double distance =
      DistancePoints
      *
      _Point;


   //==================================================
   // เงื่อนไขเดิม
   //
   // Bid - Distance >= Highest
   //==================================================
   if(
      bid - distance
      >=
      highest_price
   )
   {
      OpenRecovery(
         "RECOVERY UP"
      );
   }
}


//+------------------------------------------------------------------+
//| Reset Range Timer                                                |
//+------------------------------------------------------------------+
void ResetRangeTimer()
{
   range_enter_time = 0;
   tracked_range_high = 0.0;
   tracked_range_low = 0.0;
   tracked_range_count = 0;
   range_inside = false;
}

//+------------------------------------------------------------------+
//| Is Range Timeout                                                 |
//| Reference: highest / lowest OPEN price among EA positions.       |
//| Price: middle of current Bid and Ask.                            |
//| Timer resets on breakout or when EA position range changes.     |
//+------------------------------------------------------------------+
bool IsRangeTimeout(const MqlTick &tick,
                    const int position_count,
                    const double highest_price,
                    const double lowest_price)
{
   if(!EnableRangeTimeout || RangeTimeoutMinutes <= 0 ||
      position_count <= 0 || highest_price <= 0.0 ||
      lowest_price <= 0.0 || highest_price < lowest_price ||
      tick.ask <= 0.0 || tick.bid <= 0.0)
   {
      ResetRangeTimer();
      return false;
   }

   const bool range_changed =
      (tracked_range_count != position_count ||
       MathAbs(tracked_range_high - highest_price) > _Point * 0.5 ||
       MathAbs(tracked_range_low - lowest_price) > _Point * 0.5);

   if(range_changed)
   {
      range_enter_time = 0;
      tracked_range_count = position_count;
      tracked_range_high = highest_price;
      tracked_range_low  = lowest_price;
   }

   const double mid_price = (tick.bid + tick.ask) / 2.0;
   range_inside = (mid_price >= lowest_price && mid_price <= highest_price);

   if(!range_inside)
   {
      range_enter_time = 0;
      return false;
   }

   datetime now = (datetime)tick.time;
   if(now <= 0)
      now = TimeCurrent();

   if(range_enter_time == 0 || now < range_enter_time)
   {
      range_enter_time = now;
      return false;
   }

   return ((long)(now - range_enter_time) >= (long)RangeTimeoutMinutes * 60);
}

//+------------------------------------------------------------------+
//| Reset Cycle                                                      |
//+------------------------------------------------------------------+
void ResetCycle()
{
   ResetRangeTimer();
   initial = true;
   basket_closing = false;
   range_closing = false;
   entry_filter_status = "READY";

   recovery_level = 0;


   buy_lot =
      NormalizeLot(
         Lot
      );


   sell_lot =
      NormalizeLot(
         Lot
      );


   Print(
      "RESET CYCLE",
      " | INITIAL = TRUE",
      " | RECOVERY LEVEL = 0",
      " | BUY = ",
      buy_lot,
      " | SELL = ",
      sell_lot
   );
}


//+------------------------------------------------------------------+
//| Close All EA Positions                                           |
//| Called for either Basket TP or Range Timeout.                    |
//| Once started, keep closing until all EA positions are gone.     |
//+------------------------------------------------------------------+
bool CloseAllPosition()
{
   int remaining = CountPosition();
   if(remaining <= 0)
   {
      if(basket_closing || range_closing)
      {
         ResetCycle();
         return true;
      }
      return false;
   }

   // Basket TP still works independently of the range timeout.
   if(!basket_closing && !range_closing)
   {
      double basket_profit = GetFloatingProfit();
      if(basket_profit < BasketTakeProfit)
         return false;

      basket_closing = true;
      Print("BASKET TP HIT | TARGET = ", DoubleToString(BasketTakeProfit, 2),
            " | FLOATING = ", DoubleToString(basket_profit, 2),
            " | SYMBOL = ", _Symbol,
            " | MAGIC = ", MagicNumber);
   }

   // A closing flag stays set even if P/L or price changes during liquidation.
   for(int pass = 0; pass < 3; pass++)
   {
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0 || !PositionSelectByTicket(ticket))
            continue;

         if(PositionGetString(POSITION_SYMBOL) != _Symbol)
            continue;
         if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
            continue;

         bool result = trade.PositionClose(ticket);
         uint retcode = trade.ResultRetcode();
         if(result &&
            (retcode == TRADE_RETCODE_DONE || retcode == TRADE_RETCODE_DONE_PARTIAL))
         {
            Print("CLOSE RESULT | TICKET = ", ticket,
                  " | ", trade.ResultRetcodeDescription());
         }
         else
         {
            Print("CLOSE FAIL | TICKET = ", ticket,
                  " | RETCODE = ", retcode,
                  " | ", trade.ResultRetcodeDescription());
         }
      }

      if(CountPosition() == 0)
         break;
   }

   if(CountPosition() == 0)
   {
      ResetCycle();
      return true;
   }

   // True means "liquidation in progress"; suppress recovery entries.
   return true;
}


//+------------------------------------------------------------------+
//| Create Panel Label                                               |
//+------------------------------------------------------------------+
void CreatePanelLabel(
   string name,
   int x,
   int y,
   int font_size,
   color text_color
)
{
   string object_name =
      PANEL_PREFIX
      +
      name;


   if(
      ObjectFind(
         0,
         object_name
      )
      <
      0
   )
   {
      ObjectCreate(
         0,
         object_name,
         OBJ_LABEL,
         0,
         0,
         0
      );
   }


   ObjectSetInteger(
      0,
      object_name,
      OBJPROP_CORNER,
      CORNER_LEFT_UPPER
   );


   ObjectSetInteger(
      0,
      object_name,
      OBJPROP_XDISTANCE,
      x
   );


   ObjectSetInteger(
      0,
      object_name,
      OBJPROP_YDISTANCE,
      y
   );


   ObjectSetInteger(
      0,
      object_name,
      OBJPROP_FONTSIZE,
      font_size
   );


   ObjectSetInteger(
      0,
      object_name,
      OBJPROP_COLOR,
      text_color
   );


   ObjectSetInteger(
      0,
      object_name,
      OBJPROP_SELECTABLE,
      false
   );


   ObjectSetInteger(
      0,
      object_name,
      OBJPROP_HIDDEN,
      true
   );


   ObjectSetString(
      0,
      object_name,
      OBJPROP_FONT,
      "Consolas"
   );
}


//+------------------------------------------------------------------+
//| Set Panel                                                        |
//+------------------------------------------------------------------+
void SetPanelText(
   string name,
   string text,
   color text_color
)
{
   string object_name =
      PANEL_PREFIX
      +
      name;


   ObjectSetString(
      0,
      object_name,
      OBJPROP_TEXT,
      text
   );


   ObjectSetInteger(
      0,
      object_name,
      OBJPROP_COLOR,
      text_color
   );
}


//+------------------------------------------------------------------+
//| Create Panel                                                     |
//+------------------------------------------------------------------+
void CreatePanel()
{
   string bg =
      PANEL_PREFIX
      +
      "BG";


   if(
      ObjectFind(
         0,
         bg
      )
      <
      0
   )
   {
      ObjectCreate(
         0,
         bg,
         OBJ_RECTANGLE_LABEL,
         0,
         0,
         0
      );
   }


   ObjectSetInteger(
      0,
      bg,
      OBJPROP_CORNER,
      CORNER_LEFT_UPPER
   );


   ObjectSetInteger(
      0,
      bg,
      OBJPROP_XDISTANCE,
      10
   );


   ObjectSetInteger(
      0,
      bg,
      OBJPROP_YDISTANCE,
      20
   );


   ObjectSetInteger(
      0,
      bg,
      OBJPROP_XSIZE,
      330
   );


   ObjectSetInteger(
      0,
      bg,
      OBJPROP_YSIZE,
      438
   );


   ObjectSetInteger(
      0,
      bg,
      OBJPROP_BGCOLOR,
      clrBlack
   );


   ObjectSetInteger(
      0,
      bg,
      OBJPROP_COLOR,
      clrDimGray
   );


   ObjectSetInteger(
      0,
      bg,
      OBJPROP_SELECTABLE,
      false
   );


   ObjectSetInteger(
      0,
      bg,
      OBJPROP_HIDDEN,
      true
   );


   CreatePanelLabel("TITLE",     25, 30, 12, clrGold);
   CreatePanelLabel("STATUS",    25, 58, 10, clrWhite);
   CreatePanelLabel("POSITION",  25, 82, 10, clrWhite);
   CreatePanelLabel("LEVEL",     25,106, 10, clrWhite);
   CreatePanelLabel("LOTS",      25,130, 10, clrWhite);
   CreatePanelLabel("TOTALLOT",  25,154, 10, clrWhite);
    CreatePanelLabel("RATIO",     25,178, 10, clrWhite);
   CreatePanelLabel("EMA",       25,202, 10, clrWhite);
   CreatePanelLabel("TREND",     25,226, 10, clrWhite);
   CreatePanelLabel("PRICE",     25,250, 10, clrWhite);
   CreatePanelLabel("RANGE",     25,274, 10, clrWhite);
   CreatePanelLabel("ACCOUNT",   25,298, 10, clrWhite);
   CreatePanelLabel("FLOATING",  25,322, 10, clrWhite);
   CreatePanelLabel("BASKET_TP", 25,346, 10, clrWhite);
   CreatePanelLabel("RANGE_TIME",25,370, 10, clrWhite);
   CreatePanelLabel("FILTERS",   25,394, 10, clrWhite);


   SetPanelText(
      "TITLE",
      "HEDGE RECOVERY EMA 1:3",
      clrGold
   );
}


//+------------------------------------------------------------------+
//| Update Panel                                                     |
//+------------------------------------------------------------------+
void UpdatePanel()
{
   MqlTick tick;


   double ask = 0.0;
   double bid = 0.0;


   if(
      SymbolInfoTick(
         _Symbol,
         tick
      )
   )
   {
      ask = tick.ask;
      bid = tick.bid;
   }


   double high =
      GetHighestPositionPrice();


   double low =
      GetLowestPositionPrice();


   double ema_fast = 0.0;
   double ema_slow = 0.0;


   GetEMAValue(
      ema_fast,
      ema_slow
   );


   int total =
      CountPosition();


   int buy_count =
      CountBuyPosition();


   int sell_count =
      CountSellPosition();




    double total_buy_lot =
       GetTotalBuyLot();


    double total_sell_lot =
       GetTotalSellLot();
   double balance =
      AccountInfoDouble(
         ACCOUNT_BALANCE
      );


   double equity =
      AccountInfoDouble(
         ACCOUNT_EQUITY
      );


   double floating =
      GetFloatingProfit();


   //==================================================
   // TREND
   //==================================================
   string trend = "FLAT";

   color trend_color =
      clrSilver;


   if(
      ema_fast
      >
      ema_slow
   )
   {
      trend = "BUY";

      trend_color =
         clrLime;
   }
   else
   if(
      ema_fast
      <
      ema_slow
   )
   {
      trend = "SELL";

      trend_color =
         clrTomato;
   }


   //==================================================
   // NEXT RECOVERY LOT
   //==================================================
   double next_buy  = Lot;
   double next_sell = Lot;


   CalculateRecoveryLots(
      ema_fast,
      ema_slow,
      next_buy,
      next_sell
   );


   //==================================================
   // STATUS
   //==================================================
   string status =
      initial
      ?
      "INITIAL"
      :
      "RECOVERY";


   if(total == 0)
   {
      status = "WAIT INITIAL";
      if(initial && entry_filter_status != "READY")
         status = entry_filter_status;
   }


   SetPanelText(
      "STATUS",
      "STATUS     : " + status,
      clrWhite
   );


   SetPanelText(
      "POSITION",
      "POSITION   : "
      +
      IntegerToString(total)
      +
      "  BUY="
      +
      IntegerToString(buy_count)
      +
      " SELL="
      +
      IntegerToString(sell_count),
      clrWhite
   );


   SetPanelText(
      "LEVEL",
      "REC LEVEL  : "
      +
      IntegerToString(
         recovery_level
      ),
      clrWhite
   );


   SetPanelText(
      "LOTS",
      "NEXT LOT   : BUY "
      +
      DoubleToString(
         next_buy,
         GetVolumeDigits()
      )
      +
      " | SELL "
      +
      DoubleToString(
         next_sell,
         GetVolumeDigits()
      ),
      clrWhite
   );

    SetPanelText(
       "TOTALLOT",
       "TOTAL LOT  : BUY "
      +
       DoubleToString(
          total_buy_lot,
          GetVolumeDigits()
      )
      +
       " | SELL "
      +
       DoubleToString(
          total_sell_lot,
          GetVolumeDigits()
      ),
       clrWhite
   );


    SetPanelText(
       "RATIO",
      "RATIO      : TREND "
      +
      DoubleToString(
         LotRatio,
         1
      )
      +
      " : HEDGE 1",
      clrWhite
   );


   SetPanelText(
      "EMA",
      "EMA "
      +
      IntegerToString(
         EMAFastPeriod
      )
      +
      "/"
      +
      IntegerToString(
         EMASlowPeriod
      )
      +
      " : "
      +
      DoubleToString(
         ema_fast,
         _Digits
      )
      +
      " / "
      +
      DoubleToString(
         ema_slow,
         _Digits
      ),
      clrWhite
   );


   SetPanelText(
      "TREND",
      "EMA TREND  : "
      +
      trend,
      trend_color
   );


   SetPanelText(
      "PRICE",
      "ASK / BID  : "
      +
      DoubleToString(
         ask,
         _Digits
      )
      +
      " / "
      +
      DoubleToString(
         bid,
         _Digits
      ),
      clrWhite
   );


   SetPanelText(
      "RANGE",
      "HIGH / LOW : "
      +
      DoubleToString(
         high,
         _Digits
      )
      +
      " / "
      +
      DoubleToString(
         low,
         _Digits
      ),
      clrWhite
   );


   SetPanelText(
      "ACCOUNT",
      "BAL / EQ    : "
      +
      DoubleToString(
         balance,
         2
      )
      +
      " / "
      +
      DoubleToString(
         equity,
         2
      ),
      clrWhite
   );


   SetPanelText(
      "FLOATING",
      "FLOATING    : "
      +
      DoubleToString(
         floating,
         2
      ),
      floating >= 0
      ?
      clrLime
      :
      clrTomato
   );


   SetPanelText(
      "BASKET_TP",
      "BASKET TP  : " + DoubleToString(BasketTakeProfit, 2) +
      " | NOW " + DoubleToString(floating, 2),
      basket_closing ? clrGold : clrWhite
   );

   string time_text = "OFF";
   color time_color = clrSilver;

   if(EnableRangeTimeout && RangeTimeoutMinutes > 0)
   {
      time_text = "OUTSIDE / " + IntegerToString(RangeTimeoutMinutes) + "m";
      if(range_inside && range_enter_time > 0)
      {
         int elapsed = (int)(TimeCurrent() - range_enter_time);
         if(elapsed < 0)
            elapsed = 0;

         time_text = StringFormat("%02d:%02d / %d:00",
                                  elapsed / 60, elapsed % 60,
                                  RangeTimeoutMinutes);
         time_color = clrGold;
      }
   }
   if(range_closing)
   {
      time_text = "TIMEOUT - CLOSING";
      time_color = clrTomato;
   }

   SetPanelText("RANGE_TIME", "RANGE TIME : " + time_text, time_color);

   string rsi_text = "OFF";
   if(EnableRSIFilter)
      rsi_text = (last_entry_rsi < 0.0 ? "WAIT" : DoubleToString(last_entry_rsi, 1));
   string adx_text = "OFF";
   if(EnableADXFilter)
      adx_text = (last_entry_adx < 0.0 ? "WAIT" : DoubleToString(last_entry_adx, 1));

   // Values shown are LAST CHECKED on INITIAL; not refreshed mid-basket.
   SetPanelText("FILTERS", "ENTRY " + EnumToString(EntryFilterTF) + " : RSI " + rsi_text + " | ADX " + adx_text,
                entry_filter_status == "READY" ? clrWhite : clrGold);

   ChartRedraw();
}


//+------------------------------------------------------------------+
//| Delete Panel                                                     |
//+------------------------------------------------------------------+
void DeletePanel()
{
   ObjectsDeleteAll(
      0,
      PANEL_PREFIX
   );


   ChartRedraw();
}


//+------------------------------------------------------------------+
//| INIT                                                             |
//+------------------------------------------------------------------+
int OnInit()
{
   if(BasketTakeProfit <= 0.0 || !MathIsValidNumber(BasketTakeProfit))
   {
      Print("ERROR: BasketTakeProfit must be greater than zero");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(EnableRangeTimeout && RangeTimeoutMinutes <= 0)
   {
      Print("ERROR: RangeTimeoutMinutes must be greater than zero when enabled");
      return INIT_PARAMETERS_INCORRECT;
   }

   // Validate enabled filters, including legal indicator periods/ranges.
   if((EnableRSIFilter && (RSIPeriod < 2 || RSIEntryMin < 0.0 ||
       RSIEntryMax > 100.0 || RSIEntryMin >= RSIEntryMax)) ||
      (EnableADXFilter && (ADXPeriod < 2 || ADXEntryMin < 0.0 ||
       ADXEntryMin >= ADXEntryMax)))
   {
      Print("ERROR: invalid RSI/ADX entry filter parameters");
      return INIT_PARAMETERS_INCORRECT;
   }

   basket_closing = false;
   range_closing = false;
   ResetRangeTimer();
   entry_filter_status = "READY";
   last_entry_rsi = -1.0;
   last_entry_adx = -1.0;

   //==================================================
   // ต้องเป็น Hedging Account
   //==================================================
   if(
      (ENUM_ACCOUNT_MARGIN_MODE)
      AccountInfoInteger(
         ACCOUNT_MARGIN_MODE
      )
      !=
      ACCOUNT_MARGIN_MODE_RETAIL_HEDGING
   )
   {
      Print(
         "ERROR : HEDGING ACCOUNT REQUIRED"
      );


      return INIT_FAILED;
   }


   trade.SetExpertMagicNumber(
      MagicNumber
   );


   trade.SetTypeFillingBySymbol(
      _Symbol
   );


   //==================================================
   // EMA
   //==================================================
   handle_ema_fast =
      iMA(
         _Symbol,
         _Period,
         EMAFastPeriod,
         0,
         MODE_EMA,
         PRICE_CLOSE
      );


   handle_ema_slow =
      iMA(
         _Symbol,
         _Period,
         EMASlowPeriod,
         0,
         MODE_EMA,
         PRICE_CLOSE
      );


   if(
      handle_ema_fast
      ==
      INVALID_HANDLE
      ||
      handle_ema_slow
      ==
      INVALID_HANDLE
   )
   {
      Print(
         "EMA HANDLE ERROR"
      );


      return INIT_FAILED;
   }


   //==================================================
   // INITIAL entry filters (only create handles if enabled).
   //==================================================
   if(EnableRSIFilter)
   {
      handle_entry_rsi = iRSI(_Symbol, EntryFilterTF, RSIPeriod, PRICE_CLOSE);
      if(handle_entry_rsi == INVALID_HANDLE)
      {
         Print("ERROR: RSI handle creation failed");
         return INIT_FAILED;
      }
   }

   if(EnableADXFilter)
   {
      handle_entry_adx = iADX(_Symbol, EntryFilterTF, ADXPeriod);
      if(handle_entry_adx == INVALID_HANDLE)
      {
         Print("ERROR: ADX handle creation failed");
         return INIT_FAILED;
      }
   }

   //==================================================
   // RESET
   //==================================================
   // Continue monitoring existing EA positions when reattaching the EA.
   initial = (CountPosition() == 0);

   recovery_level = 0;


   buy_lot =
      NormalizeLot(
         Lot
      );


   sell_lot =
      NormalizeLot(
         Lot
      );


   //==================================================
   // PANEL
   //==================================================
   CreatePanel();

   UpdatePanel();


   Print(
      "EA START",
      " | INITIAL LOT = ",
      Lot,
      " | RATIO = 1:",
      LotRatio
   );


   return INIT_SUCCEEDED;
}


//+------------------------------------------------------------------+
//| TICK                                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   UpdatePanel();


   //==================================================
   // CLOSE ALL
   //==================================================
   if(CloseAllPosition())
   {
      UpdatePanel();
      return;
   }


   int position_count =
      CountPosition();


   //==================================================
   // INITIAL
   //==================================================
   if(initial)
   {
      if(
         position_count
         ==
         0
      )
      {
         if(IsInitialEntryAllowed() && OpenInitialPosition())
         {
            initial = false;


            Print(
               "INITIAL COMPLETE"
            );
         }
      }


      UpdatePanel();

      return;
   }


   //==================================================
   // ไม่มี Position
   //==================================================
   if(
      position_count
      ==
      0
   )
   {
      ResetCycle();

      UpdatePanel();

      return;
   }


   //==================================================
   // PRICE
   //==================================================
   MqlTick tick;


   if(
      !SymbolInfoTick(
         _Symbol,
         tick
      )
   )
      return;


   //==================================================
   // POSITION RANGE
   //==================================================
   double highest_price =
      GetHighestPositionPrice();


   double lowest_price =
      GetLowestPositionPrice();


   if(
      highest_price <= 0
      ||
      lowest_price <= 0
   )
      return;

   //==================================================
   // RANGE TIMEOUT: close even when basket is negative
   //==================================================
   if(IsRangeTimeout(tick, position_count, highest_price, lowest_price))
   {
      range_closing = true;
      Print("RANGE TIMEOUT | ", RangeTimeoutMinutes, " minutes",
            " | LOW = ", DoubleToString(lowest_price, _Digits),
            " | HIGH = ", DoubleToString(highest_price, _Digits),
            " | BASKET = ", DoubleToString(GetFloatingProfit(), 2));
      CloseAllPosition();
      UpdatePanel();
      return;
   }

   //==================================================
   // RECOVERY DOWN
   //==================================================
   RecoveryDown(
      tick.ask,
      lowest_price
   );


   //==================================================
   // RECOVERY UP
   //==================================================
   RecoveryUp(
      tick.bid,
      highest_price
   );


   UpdatePanel();
}


//+------------------------------------------------------------------+
//| DEINIT                                                           |
//+------------------------------------------------------------------+
void OnDeinit(
   const int reason
)
{
   if(
      handle_ema_fast
      !=
      INVALID_HANDLE
   )
   {
      IndicatorRelease(
         handle_ema_fast
      );
   }


   if(
      handle_ema_slow
      !=
      INVALID_HANDLE
   )
   {
      IndicatorRelease(
         handle_ema_slow
      );
   }


   if(handle_entry_rsi != INVALID_HANDLE)
      IndicatorRelease(handle_entry_rsi);

   if(handle_entry_adx != INVALID_HANDLE)
      IndicatorRelease(handle_entry_adx);

   DeletePanel();
}
//+------------------------------------------------------------------+