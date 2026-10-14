//+------------------------------------------------------------------+
//|                                  HedgeRecoveryEMA.mq5            |
//+------------------------------------------------------------------+
#property strict
#property version "1.11"

#include <Trade/Trade.mqh>

CTrade trade;


//====================================================
// INPUT
//====================================================
input double Lot            = 0.01;
input double LotStep        = 0.01;
input double LotRatio       = 3;

input int    DistancePoints = 100;

input int    EMAFastPeriod  = 8;
input int    EMASlowPeriod  = 21;

input ulong  MagicNumber    = 26092901;

input group "TAKE PROFIT (ACCOUNT CURRENCY)"
input double BasketTakeProfitMoney = 10.0;  // TP per cycle; 0 = disabled
input double DailyTakeProfitMoney  = 50.0;  // TP per broker day; 0 = disabled

input group "TRADING HOURS (MONDAY-FRIDAY)"
input bool EnableTradingHours    = true;   // false = no trading-time filter
input int  TradingStartHour      = 7;      // 07:00, inclusive
input int  TradingStartMinute    = 0;
input int  TradingEndHour        = 22;     // 22:00, exclusive
input int  TradingEndMinute      = 0;
input bool UseBrokerServerTime   = false;  // false = PC/VPS local clock



//====================================================
// GLOBAL
//====================================================
bool initial = true;

int recovery_level = 0;

double buy_lot  = 0.0;
double sell_lot = 0.0;


//====================================================
// EMA
//====================================================
int handle_ema_fast = INVALID_HANDLE;
int handle_ema_slow = INVALID_HANDLE;


//====================================================
// PANEL
//====================================================
string PANEL_PREFIX = "HRE_PANEL_";

// Take-profit state (saved to MT5 terminal global variables)
bool     closing_all         = false;
bool     daily_target_locked = false;
bool     daily_history_ok    = true;
datetime tracked_day        = 0;
double   daily_closed_net    = 0.0;
double   daily_total_net     = 0.0;
string   tp_prefix          = "";
string   tp_close_key       = "";
string   tp_level_key       = "";
string   tp_daily_lock_key  = "";



//+------------------------------------------------------------------+
//| Entry time filter only. Mon-Fri [07:00, 22:00) by default.         |
//| TP/CloseAll continue to run outside this window.                  |
//+------------------------------------------------------------------+
bool IsTradingSession()
{
   if(!EnableTradingHours)
      return true;

   datetime clock_time = UseBrokerServerTime ? TimeCurrent() : TimeLocal();
   MqlDateTime tm;
   TimeToStruct(clock_time, tm);

   // MQL5 weekdays: 0=Sunday, 1=Monday, ..., 6=Saturday.
   if(tm.day_of_week == 0 || tm.day_of_week == 6)
      return false;

   int current_min = tm.hour * 60 + tm.min;
   int start_min   = TradingStartHour * 60 + TradingStartMinute;
   int end_min     = TradingEndHour * 60 + TradingEndMinute;
   return (current_min >= start_min && current_min < end_min);
}

string TradingSessionInfo()
{
   if(!EnableTradingHours)
      return "OFF (24/7 ENTRIES)";

   string clock_label = UseBrokerServerTime ? "SERVER" : "LOCAL";
   return StringFormat("MON-FRI %02d:%02d-%02d:%02d %s", 
                       TradingStartHour, TradingStartMinute,
                       TradingEndHour, TradingEndMinute, clock_label);
}

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
      GlobalVariableSet(tp_level_key, (double)recovery_level);
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
//| Broker-server day for daily profit target                         |
//+------------------------------------------------------------------+
datetime GetBrokerDayStart()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dt.hour = 0;
   dt.min  = 0;
   dt.sec  = 0;
   return StructToTime(dt);
}

//+------------------------------------------------------------------+
//| Today's EA closed net profit (including commissions/fees)         |
//| The floating component is computed separately from open positions|
//+------------------------------------------------------------------+
bool GetTodayClosedNet(double &net)
{
   net = 0.0;
   if(!HistorySelect(tracked_day, TimeCurrent()))
   {
      PrintFormat("DAILY TP: HistorySelect failed, error=%d", GetLastError());
      return false;
   }

   for(int i = 0; i < HistoryDealsTotal(); i++)
   {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0) continue;
      if(HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol) continue;
      if((ulong)HistoryDealGetInteger(deal, DEAL_MAGIC) != MagicNumber) continue;

      // Include both entry and exit fees; gross profit only exists on exits.
      net += HistoryDealGetDouble(deal, DEAL_PROFIT)
           + HistoryDealGetDouble(deal, DEAL_SWAP)
           + HistoryDealGetDouble(deal, DEAL_COMMISSION)
           + HistoryDealGetDouble(deal, DEAL_FEE);
   }
   return true;
}

//+------------------------------------------------------------------+
//| Lock each broker-server day separately; restart-safe              |
//+------------------------------------------------------------------+
void RefreshDailyTarget()
{
   datetime day = GetBrokerDayStart();
   if(tracked_day != day)
   {
      tracked_day = day;
      tp_daily_lock_key = tp_prefix + "D" + IntegerToString((long)day);
      daily_target_locked = (DailyTakeProfitMoney > 0.0 &&
                             GlobalVariableCheck(tp_daily_lock_key) &&
                             GlobalVariableGet(tp_daily_lock_key) > 0.5);
      PrintFormat("DAILY TP: new broker day %s; locked=%s",
                  TimeToString(day,TIME_DATE),daily_target_locked?"YES":"NO");
   }

   daily_closed_net = 0.0;
   daily_total_net  = GetFloatingProfit();
   daily_history_ok = true;
   if(DailyTakeProfitMoney <= 0.0)
   {
      daily_target_locked = false; // disabled by user
      return;
   }

   daily_history_ok = GetTodayClosedNet(daily_closed_net);
   if(!daily_history_ok) return; // Never open new orders if daily P/L is unavailable

   daily_total_net = daily_closed_net + GetFloatingProfit();
   if(!daily_target_locked && daily_total_net >= DailyTakeProfitMoney)
   {
      // Persist the daily stop before sending any close order.
      daily_target_locked = true;
      if(GlobalVariableSet(tp_daily_lock_key, 1.0) == 0)
         PrintFormat("WARNING: could not persist DAILY LOCK, error=%d",GetLastError());
      GlobalVariablesFlush();
      PrintFormat("DAILY TP REACHED | closed=%.2f floating=%.2f total=%.2f target=%.2f %s",
                  daily_closed_net, GetFloatingProfit(), daily_total_net,
                  DailyTakeProfitMoney, AccountInfoString(ACCOUNT_CURRENCY));
   }
}

void StartCloseAll(string reason)
{
   if(closing_all) return;
   closing_all = true;
   if(GlobalVariableSet(tp_close_key, 1.0) == 0)
      PrintFormat("WARNING: could not persist CLOSE ALL state, error=%d", GetLastError());
   GlobalVariablesFlush();
   Print("CLOSE ALL START: ", reason);
}

//+------------------------------------------------------------------+
//| Reset the position cycle, but NOT the daily-profit lock           |
//+------------------------------------------------------------------+
void ResetCycle()
{
   initial = true;
   recovery_level = 0;
   buy_lot  = NormalizeLot(Lot);
   sell_lot = NormalizeLot(Lot);
   closing_all = false;
   GlobalVariableDel(tp_level_key);
   GlobalVariableDel(tp_close_key);
   GlobalVariablesFlush();
   Print("RESET CYCLE | DAILY LOCK=", daily_target_locked ? "YES" : "NO");
}

//+------------------------------------------------------------------+
//| Close own EA positions only. Do not abort the close on errors.     |
//+------------------------------------------------------------------+
bool CloseAllPosition()
{
   if(!closing_all) return false;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      bool sent = trade.PositionClose(ticket);
      uint rc = trade.ResultRetcode();
      if(!sent || (rc != TRADE_RETCODE_DONE && rc != TRADE_RETCODE_DONE_PARTIAL))
         PrintFormat("CLOSE RETRY NEEDED: ticket=%I64u code=%u %s",
                     ticket,rc,trade.ResultRetcodeDescription());
   }

   if(CountPosition() == 0)
   {
      ResetCycle();
      // Refresh after closes so the panel and daily target reflect realized P/L.
      RefreshDailyTarget();
   }
   return true; // Never open new entries on a closing tick, even if a close failed
}

//+------------------------------------------------------------------+
//| Priority: daily TP > cycle TP. Close requests persist on restart.|
//+------------------------------------------------------------------+
bool ProcessTakeProfits()
{
   RefreshDailyTarget();

   int positions = CountPosition();
   if(positions == 0 && closing_all)
   {
      ResetCycle();
      RefreshDailyTarget();
   }

   if(daily_target_locked)
   {
      if(positions > 0) StartCloseAll("DAILY PROFIT TARGET");
      if(closing_all) CloseAllPosition();
      return true; // Stay stopped until the next broker-server day
   }

   if(positions > 0 && !closing_all && BasketTakeProfitMoney > 0.0 &&
      GetFloatingProfit() >= BasketTakeProfitMoney)
   {
      PrintFormat("CYCLE TP REACHED: float=%.2f target=%.2f %s",
                  GetFloatingProfit(), BasketTakeProfitMoney,
                  AccountInfoString(ACCOUNT_CURRENCY));
      StartCloseAll("BASKET TAKE PROFIT");
   }

   if(closing_all)
      return CloseAllPosition();

   if(DailyTakeProfitMoney > 0.0 && !daily_history_ok)
   {
      // Fail closed for new entries; do not liquidate existing positions.
      // The basket close above is still allowed even if HistorySelect fails.
      return true;
   }
   return false;
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
      460
   );


   ObjectSetInteger(
      0,
      bg,
      OBJPROP_YSIZE,
      510
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
   CreatePanelLabel("CYCLETP",   25,346, 10, clrGold);
   CreatePanelLabel("DAILYPL",   25,370, 10, clrWhite);
   CreatePanelLabel("DAILYTP",   25,394, 10, clrGold);
   CreatePanelLabel("REMAIN",    25,418, 10, clrWhite);
   CreatePanelLabel("TPSTATUS",  25,442, 10, clrWhite);
   CreatePanelLabel("SESSION",   25,466, 10, clrWhite);


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
      status = "WAIT INITIAL";
   if(closing_all) status = "CLOSING ALL";
   else if(daily_target_locked) status = "DAILY TARGET LOCK";
    else if(DailyTakeProfitMoney > 0.0 && !daily_history_ok)
        status = "DAILY HISTORY UNAVAILABLE";
    else if(!IsTradingSession())
        status = "OUTSIDE TRADING HOURS";


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


   string currency = AccountInfoString(ACCOUNT_CURRENCY);
   string cycleText = (BasketTakeProfitMoney > 0.0)
                      ? DoubleToString(BasketTakeProfitMoney, 2) : "OFF";
   string dayText   = (DailyTakeProfitMoney > 0.0)
                      ? DoubleToString(DailyTakeProfitMoney, 2) : "OFF";
   string remaining = (DailyTakeProfitMoney > 0.0 && daily_history_ok)
                      ? DoubleToString(MathMax(0.0,DailyTakeProfitMoney - daily_total_net), 2)
                      : "N/A";

   SetPanelText("CYCLETP", "CYCLE TP   : " + cycleText + " " + currency, clrGold);
   SetPanelText("DAILYPL", "TODAY NET  : " +
                (daily_history_ok ? DoubleToString(daily_total_net,2) : "N/A") +
                "  (closed " + DoubleToString(daily_closed_net,2) + ")",
                daily_total_net >= 0.0 ? clrLime : clrTomato);
   SetPanelText("DAILYTP", "DAILY TP   : " + dayText + " " + currency, clrGold);
   SetPanelText("REMAIN",  "DAILY LEFT : " + remaining + " " + currency, clrWhite);
   SetPanelText("TPSTATUS", "DAILY LOCK : " +
                (daily_target_locked ? "YES - UNTIL NEXT BROKER DAY" : "NO"),
                daily_target_locked ? clrTomato : clrSilver);
   SetPanelText("SESSION", "SESSION    : " + TradingSessionInfo() +
                (IsTradingSession() ? " [OPEN]" : " [CLOSED]"),
                IsTradingSession() ? clrLime : clrTomato);

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


   if(Lot <= 0.0 || LotStep < 0.0 || LotRatio < 1.0 || DistancePoints <= 0 ||
       BasketTakeProfitMoney < 0.0 || DailyTakeProfitMoney < 0.0 ||
       TradingStartHour < 0 || TradingStartHour > 23 ||
       TradingStartMinute < 0 || TradingStartMinute > 59 ||
       TradingEndHour < 0 || TradingEndHour > 23 ||
       TradingEndMinute < 0 || TradingEndMinute > 59 ||
       (TradingStartHour * 60 + TradingStartMinute >=
        TradingEndHour * 60 + TradingEndMinute))
   {
      Print("ERROR: INVALID EA INPUT");
      return INIT_PARAMETERS_INCORRECT;
   }

   // Short account/symbol/magic prefix, isolated from other EAs.
   tp_prefix = "HTP." + IntegerToString((long)AccountInfoInteger(ACCOUNT_LOGIN)) +
               "." + _Symbol + "." + IntegerToString((long)MagicNumber) + ".";
   tp_close_key = tp_prefix + "CLOSE";
   tp_level_key = tp_prefix + "LEVEL";
   closing_all = GlobalVariableCheck(tp_close_key) &&
                 GlobalVariableGet(tp_close_key) > 0.5;

   int n = CountPosition();
   initial = (n == 0);
   recovery_level = 0;
   if(n > 0)
   {
      recovery_level = GlobalVariableCheck(tp_level_key)
                       ? (int)GlobalVariableGet(tp_level_key)
                       : (int)MathMax(0, n/2 - 1);
      if(CountBuyPosition() != CountSellPosition())
         Print("WARNING: UNPAIRED HEDGE POSITIONS - AUTO RECOVERY WILL BE BLOCKED");
   }
   else if(closing_all)
      ResetCycle();

   buy_lot  = NormalizeLot(Lot);
   sell_lot = NormalizeLot(Lot);
   RefreshDailyTarget();
   EventSetTimer(5); // retry pending Close All and update daily target


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
   // Exits and daily lock ALWAYS take priority over any new entry.
   if(ProcessTakeProfits())
   {
      UpdatePanel();
      return;
   }

   // Entry filter: applies to both INITIAL and RECOVERY only.
   // Existing trades stay open and both TP levels keep working.
   if(!IsTradingSession())
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
         if(
            OpenInitialPosition()
         )
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


   // Do not scale a broken BUY/SELL hedge pair.
   if(CountBuyPosition() != CountSellPosition())
   {
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
//| TIMER: retry close even if market ticks are sparse              |
//+------------------------------------------------------------------+
void OnTimer()
{
   ProcessTakeProfits();
   UpdatePanel();
}

//+------------------------------------------------------------------+
//| DEINIT                                                           |
//+------------------------------------------------------------------+
void OnDeinit(
   const int reason
)
{
   EventKillTimer();
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


   DeletePanel();
}
//+------------------------------------------------------------------+