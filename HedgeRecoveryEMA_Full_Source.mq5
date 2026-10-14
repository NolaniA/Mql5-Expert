//+------------------------------------------------------------------+
//|                  HedgeRecoveryEMA ADX DailyTP EMA Gap Quiet Market      |
//+------------------------------------------------------------------+
#property strict

#include <Trade/Trade.mqh>

CTrade trade;


//====================================================
// INPUT
//====================================================
input double Lot            = 0.01;
input double LotStep        = 0.01;
input double LotRatio       = 1.2;

input int    DistancePoints = 100;

input int    EMAFastPeriod  = 8;
input int    EMASlowPeriod  = 21;

input ulong  MagicNumber    = 26092901;

input group "=== EMA Gap / Narrowing Filter ==="
input bool   UseEMAGapFilter        = true;  // Block entries when EMA separation is small or shrinking
input double EMAMinGapPoints        = 100.0; // Minimum absolute EMA gap in SYMBOL POINTS (0=off)
input bool   BlockEMAGapShrinking   = true;  // Reject consecutive shrinking EMA gaps
input int    EMAShrinkConfirmBars   = 1;     // Number of consecutive CLOSED-bar decreases (1..10)
input bool   EMAGapFilterRecovery   = true;  // Also block RECOVERY orders (can increase holding risk)

// Quiet trading is based on market CONDITIONS (not hard-coded clock hours).
// ATR must be below its older baseline and trading spread must be reasonable.
// This filter blocks NEW INITIAL and RECOVERY positions; exit logic remains active.
input group "=== Low Volatility Trading ONLY ==="
input bool            UseLowVolatilityFilter  = true;       // Trade only while conditions are quiet
input ENUM_TIMEFRAMES LowVolTimeframe        = PERIOD_M5;  // Independent ATR check TF
input int             LowVolATRPeriod        = 14;         // ATR length
input int             LowVolBaselineBars     = 50;         // Previous bars used for typical ATR
input double          LowVolMaxATRRatio      = 0.90;       // Recent ATR <= older ATR average x ratio
input int             LowVolConfirmBars      = 2;          // Consecutive closed bars satisfying threshold
input double          LowVolMaxATRPoints     = 0.0;        // Optional hard ATR cap in points (0=disabled)
input bool            LowVolCheckSpread      = true;       // Also reject excessively wide live spread
input double          LowVolMaxSpreadATRPercent = 35.0;    // Live spread <= ATR x percent (0=no ratio cap)
input double          LowVolMaxSpreadPoints  = 0.0;        // Optional absolute spread cap (0=disabled)
// Filter applies to all entries, including RECOVERY. Even if conditions turn
// volatile while positions are open, basket/day/range close rules still run.

input group "=== ADX Sideway Filter ==="
input bool   UseADXFilter           = true;  // Filter INITIAL orders by ADX
input int    ADXPeriod              = 14;    // ADX calculation period
input double ADXMin                 = 20.0;  // Minimum ADX (0=off)
input double ADXMax                 = 40.0;  // Maximum ADX (0=no maximum)
input bool   ADXFilterRecovery      = false; // Filter RECOVERY too (risk: recovery blocked)

input group "=== Basket Take Profit ==="
input double BasketTakeProfitMoney  = 5.0;   // EA basket floating TP; 0=disabled

input group "=== Daily Take Profit ==="
input double DailyTPPercent         = 0.0;   // % of day-start account balance; 0=disabled
input double DailyTPMoney           = 0.0;   // Fixed account-currency daily TP; 0=disabled
// If both daily goals are enabled, the smaller target applies.
// Day resets at 00:00 BROKER SERVER time. Lock persists across restart.

input group "=== Time In Position Range Exit ==="
input bool   UseRangeTimeExit       = true;
input int    RangeTimeMinutes       = 20;    // Continuous minutes inside position high/low
// After timeout, close EA basket only if Equity > Balance AND EA floating P/L > 0.


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
int handle_adx      = INVALID_HANDLE;
int handle_low_vol_atr = INVALID_HANDLE;

// ATR portion cached per last CLOSED bar on the selected volatility timeframe.
// Spread is always checked live, on every tick, so spread spikes are rejected.
datetime lowVolCachedBar    = 0;
bool     lowVolATRCacheValid = false;
bool     lowVolATRAllowed    = false;
double   lowVolATRPoints     = 0.0;
double   lowVolBaselinePoints = 0.0;
double   lowVolSpreadPoints   = 0.0;
double   lowVolSpreadATRPercent = 0.0;
string   lowVolStatus       = "WAIT DATA";

// One completed-candle evaluation is shared by OnTick(), recovery, and panel.
// Status: -1 = waiting data; 0 = PASS; 1 = TOO CLOSE; 2 = SHRINKING.
datetime emaGapCachedBar = 0;
bool     emaGapCacheValid = false;
int      emaGapStatus = -1;
double   emaGapCurrentPoints = 0.0;

bool     dailyLocked         = false;
bool     pendingBasketClose  = false;
int      dailyDayId          = 0;
double   dailyStartBalance   = 0.0;
string   statePrefix         = "";
datetime rangeStartTime     = 0;
double   trackedRangeHigh    = 0.0;
double   trackedRangeLow     = 0.0;
datetime cachedHistoryTime  = 0;
int      cachedHistoryDay   = 0;
double   cachedEAClosed     = 0.0;
double   cachedAcctMovement = 0.0;


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
   // Final safety gate; never create BUY/SELL in high-volatility conditions.
   if(!PassLowVolatilityFilter()) return false;

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
   // Entry filters apply to RECOVERY only when selected in Inputs.
   // Take-profit and basket closing are NOT controlled by these filters.
   if(!PassLowVolatilityFilter())
      return;
   if(UseEMAGapFilter && EMAGapFilterRecovery && !PassEMAGapFilter())
      return;
   if(UseADXFilter && ADXFilterRecovery && !PassADXFilter())
      return;

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
//| Reset Cycle                                                      |
//+------------------------------------------------------------------+
void ResetCycle()
{
   initial = true;

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
//| Close only positions belonging to this EA (symbol + magic).      |
//| Caller decides WHEN to close; do not gate on account equity here.|
//+------------------------------------------------------------------+
bool CloseAllPosition()
{
   if(CountPosition() <= 0)
      return true;

   trade.SetAsyncMode(false);
   trade.SetExpertMagicNumber(MagicNumber);

   for(int pass = 0; pass < 3; pass++)
   {
      for(int i = PositionsTotal()-1; i >= 0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
         if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
         if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

         if(!trade.PositionClose(ticket))
            PrintFormat("CLOSE FAIL | ticket=%I64u | retcode=%u | %s",
                        ticket, trade.ResultRetcode(), trade.ResultRetcodeDescription());
      }
      if(CountPosition() == 0) break;
   }

   if(CountPosition() != 0)
   {
      Print("CLOSE STILL PENDING | Remaining positions: ", CountPosition());
      return false;
   }

   ResetCycle();
   ResetRangeClock();
   return true;
}


//+------------------------------------------------------------------+
//| Quiet market detector: low ATR relative to historical ATR        |
//| Data from CLOSED bars only to avoid decisions on forming bars.   |
//| Baseline deliberately EXCLUDES the last confirmation bars.       |
//| Live spread is recalculated every call (not cached).             |
//+------------------------------------------------------------------+
bool PassLowVolatilityFilter()
{
   if(!UseLowVolatilityFilter)
   {
      lowVolStatus = "OFF";
      return true;
   }

   if(handle_low_vol_atr == INVALID_HANDLE || _Point <= 0.0)
   {
      lowVolStatus = "WAIT DATA";
      return false;
   }

   datetime closed = iTime(_Symbol, LowVolTimeframe, 1);
   if(closed <= 0)
   {
      lowVolStatus = "WAIT DATA";
      return false;
   }

   if(!lowVolATRCacheValid || lowVolCachedBar != closed)
   {
      lowVolATRCacheValid = false;
      lowVolATRAllowed = false;
      lowVolATRPoints = 0.0;
      lowVolBaselinePoints = 0.0;
      lowVolCachedBar = closed;

      // CopyBuffer stores the oldest sampled ATR at index 0, even with
      // an ordinary (non-series) dynamic array. Shifts: 1..(lookback).
      int length = LowVolBaselineBars + LowVolConfirmBars;
      double values[];
      ArrayResize(values, length);
      if(CopyBuffer(handle_low_vol_atr, 0, 1, length, values) != length)
      {
         lowVolStatus = "WAIT DATA";
         return false; // Retry on next tick when data is ready.
      }

      double sum = 0.0;
      for(int i=0; i<LowVolBaselineBars; i++)
      {
         if(!MathIsValidNumber(values[i]) || values[i] <= 0.0 ||
            values[i] == EMPTY_VALUE)
         {
            lowVolStatus = "WAIT DATA";
            return false;
         }
         sum += values[i];
      }

      double average = sum / LowVolBaselineBars;
      if(average <= 0.0)
      {
         lowVolStatus = "WAIT DATA";
         return false;
      }

      double last = values[length-1];
      lowVolATRPoints = last / _Point;
      lowVolBaselinePoints = average / _Point;
      lowVolATRAllowed = true;
      for(int i=LowVolBaselineBars; i<length; i++)
      {
         if(!MathIsValidNumber(values[i]) || values[i] <= 0.0 ||
            values[i] == EMPTY_VALUE ||
            values[i] > average*LowVolMaxATRRatio ||
            (LowVolMaxATRPoints > 0.0 && values[i]/_Point > LowVolMaxATRPoints))
         {
            lowVolATRAllowed = false;
            break;
         }
      }
      lowVolATRCacheValid = true;
   }

   if(!lowVolATRAllowed)
   {
      lowVolStatus = "ATR TOO HIGH";
      return false;
   }

   // Check each tick; if spread is abnormally wide, stay out even on
   // quiet ATR bars. Percent-of-ATR adapts to symbol and broker digits.
   if(LowVolCheckSpread)
   {
      MqlTick tick;
      if(!SymbolInfoTick(_Symbol, tick) || tick.ask <= 0.0 ||
         tick.bid <= 0.0 || tick.ask < tick.bid)
      {
         lowVolStatus = "WAIT SPREAD";
         return false;
      }
      lowVolSpreadPoints = (tick.ask - tick.bid) / _Point;
      lowVolSpreadATRPercent = lowVolATRPoints > 0.0 ?
         (100.0 * lowVolSpreadPoints / lowVolATRPoints) : 0.0;
      if((LowVolMaxSpreadPoints > 0.0 &&
          lowVolSpreadPoints > LowVolMaxSpreadPoints) ||
         (LowVolMaxSpreadATRPercent > 0.0 &&
          lowVolSpreadATRPercent > LowVolMaxSpreadATRPercent))
      {
         lowVolStatus = "SPREAD TOO HIGH";
         return false;
      }
   }
   lowVolStatus = "QUIET / PASS";
   return true;
}

//+------------------------------------------------------------------+
//| EMA GAP filter: use CLOSED candles only to avoid intrabar noise. |
//|  - Gap = abs(EMA Fast - EMA Slow) / _Point                        |
//|  - Too close: gap below EMAMinGapPoints                           |
//|  - Shrinking: gap[1] < gap[2] < ... for N consecutive decreases. |
//| Filtering is used ONLY for opening orders, not closing positions.|
//+------------------------------------------------------------------+
bool PassEMAGapFilter()
{
   if(!UseEMAGapFilter) return true;

   datetime closedBar = iTime(_Symbol, _Period, 1);
   if(closedBar <= 0) return false;

   if(emaGapCacheValid && closedBar == emaGapCachedBar)
      return emaGapStatus == 0;

   // Cache successes only: early missing CopyBuffer data can be retried.
   emaGapCacheValid = false;
   emaGapStatus = -1;
   if(_Point <= 0.0) return false;

   double gaps[11];
   int count = BlockEMAGapShrinking ? (EMAShrinkConfirmBars + 1) : 1;
   if(count < 1 || count > 11) return false;

   for(int i=0; i<count; i++)
   {
      double fast[1], slow[1];
      // shifts 1,2,.. are last closed candle, then progressively older.
      if(CopyBuffer(handle_ema_fast, 0, 1+i, 1, fast) != 1 ||
         CopyBuffer(handle_ema_slow, 0, 1+i, 1, slow) != 1)
         return false;
      if(fast[0] == EMPTY_VALUE || slow[0] == EMPTY_VALUE ||
         !MathIsValidNumber(fast[0]) || !MathIsValidNumber(slow[0]))
         return false;
      gaps[i] = MathAbs(fast[0]-slow[0]) / _Point;
   }

   emaGapCurrentPoints = gaps[0];

   if(EMAMinGapPoints > 0.0 && emaGapCurrentPoints < EMAMinGapPoints)
      emaGapStatus = 1;
   else
   {
      bool shrinking = BlockEMAGapShrinking;
      if(shrinking)
      {
         for(int i=0; i<EMAShrinkConfirmBars; i++)
         {
            if(!(gaps[i] < gaps[i+1]))
            {
               shrinking = false;
               break;
            }
         }
      }
      emaGapStatus = shrinking ? 2 : 0;
   }

   emaGapCachedBar = closedBar;
   emaGapCacheValid = true;
   return emaGapStatus == 0;
}

string GetEMAGapStatusText()
{
   if(!UseEMAGapFilter) return "OFF";
   if(!emaGapCacheValid) return "WAIT DATA";
   if(emaGapStatus == 1) return "TOO CLOSE";
   if(emaGapStatus == 2) return "SHRINKING";
   if(emaGapStatus == 0) return "PASS";
   return "WAIT DATA";
}

//+------------------------------------------------------------------+
//| ADX from the last COMPLETED candle (iADX buffer 0).              |
//+------------------------------------------------------------------+
bool GetADXValue(double &adx)
{
   adx = 0.0;
   if(handle_adx == INVALID_HANDLE) return false;
   double buffer[1];
   if(CopyBuffer(handle_adx, 0, 1, 1, buffer) != 1) return false;
   if(buffer[0] == EMPTY_VALUE) return false;
   adx = buffer[0];
   return true;
}

bool PassADXFilter()
{
   if(!UseADXFilter) return true;
   double adx = 0.0;
   if(!GetADXValue(adx)) return false; // Do not open new trades with missing data.
   if(ADXMin > 0.0 && adx < ADXMin) return false;
   if(ADXMax > 0.0 && adx > ADXMax) return false;
   return true;
}

//+------------------------------------------------------------------+
//| Daily target accounting by BROKER SERVER date.                   |
//| Includes realized P/L and commissions of ALL deals with this     |
//| symbol/magic (both open and close deals), plus current EA float. |
//+------------------------------------------------------------------+
int CurrentServerDayId()
{
   MqlDateTime tm;
   TimeToStruct(TimeCurrent(), tm);
   return tm.year*10000 + tm.mon*100 + tm.day;
}

datetime CurrentServerDayStart()
{
   MqlDateTime tm;
   TimeToStruct(TimeCurrent(), tm);
   tm.hour=0; tm.min=0; tm.sec=0;
   return StructToTime(tm);
}

void RefreshDayHistory()
{
   datetime now = TimeCurrent();
   int day = CurrentServerDayId();
   if(cachedHistoryTime == now && cachedHistoryDay == day) return;

   cachedEAClosed = 0.0;
   cachedAcctMovement = 0.0;
   if(HistorySelect(CurrentServerDayStart(), now))
   {
      for(int i=0; i<HistoryDealsTotal(); i++)
      {
         ulong ticket = HistoryDealGetTicket(i);
         if(ticket == 0) continue;
         double pl = HistoryDealGetDouble(ticket, DEAL_PROFIT)
                   + HistoryDealGetDouble(ticket, DEAL_SWAP)
                   + HistoryDealGetDouble(ticket, DEAL_COMMISSION)
                   + HistoryDealGetDouble(ticket, DEAL_FEE);
         cachedAcctMovement += pl;
         if(HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol &&
            (ulong)HistoryDealGetInteger(ticket, DEAL_MAGIC) == MagicNumber)
            cachedEAClosed += pl;
      }
   }
   cachedHistoryTime = now;
   cachedHistoryDay = day;
}

double GetTodayClosedEAProfit()
{
   RefreshDayHistory();
   return cachedEAClosed;
}

double GetTodayEAProfit()
{
   return GetTodayClosedEAProfit() + GetFloatingProfit();
}

double GetDailyTargetAmount()
{
   double fromPct = (DailyTPPercent > 0.0) ? dailyStartBalance*DailyTPPercent/100.0 : 0.0;
   double fixed   = (DailyTPMoney > 0.0) ? DailyTPMoney : 0.0;
   if(fromPct > 0.0 && fixed > 0.0) return MathMin(fromPct, fixed);
   return MathMax(fromPct, fixed);
}

void SyncDailyState()
{
   int today = CurrentServerDayId();
   bool changed = (dailyDayId != today);
   bool haveStored = GlobalVariableCheck(statePrefix+"day") &&
                     (int)GlobalVariableGet(statePrefix+"day") == today &&
                     GlobalVariableCheck(statePrefix+"base");

   if(changed)
   {
      dailyDayId = today;
      if(haveStored)
      {
         dailyStartBalance = GlobalVariableGet(statePrefix+"base");
         dailyLocked = GlobalVariableCheck(statePrefix+"lock") &&
                       GlobalVariableGet(statePrefix+"lock") > 0.5;
      }
      else
      {
         // Reconstruct 00:00 balance from today's account deal movements.
         RefreshDayHistory();
         dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE) - cachedAcctMovement;
         if(dailyStartBalance <= 0.0)
            dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
         dailyLocked = false;
         GlobalVariableSet(statePrefix+"day", (double)today);
         GlobalVariableSet(statePrefix+"base", dailyStartBalance);
         GlobalVariableSet(statePrefix+"lock", 0.0);
      }
      PrintFormat("NEW BROKER DAY | day=%d | opening balance=%.2f | daily lock=%s",
                  today, dailyStartBalance, dailyLocked ? "YES" : "NO");
   }
   else if(haveStored && GlobalVariableCheck(statePrefix+"lock"))
      dailyLocked = (GlobalVariableGet(statePrefix+"lock") > 0.5);
}

bool CheckDailyTakeProfit()
{
   SyncDailyState();
   double target = GetDailyTargetAmount();
   // Setting both targets to zero explicitly disables the daily lock.
   if(target <= 0.0)
   {
      if(dailyLocked)
      {
         dailyLocked=false;
         GlobalVariableSet(statePrefix+"lock", 0.0);
      }
      return false;
   }
   if(dailyLocked) return true;
   double pl = GetTodayEAProfit();
   if(pl < target) return false;

   dailyLocked = true;
   GlobalVariableSet(statePrefix+"lock", 1.0);
   PrintFormat("DAILY TP HIT | day=%d | EA net today=%.2f | target=%.2f | lock till next broker day",
               dailyDayId, pl, target);
   return true;
}

//+------------------------------------------------------------------+
//| Track uninterrupted time spent inside existing POSITION range.   |
//| Reset when price leaves, boundaries change, or cycle is flat.    |
//| Save timer in MT5 GlobalVariables to survive EA restarts.        |
//+------------------------------------------------------------------+
void ResetRangeClock()
{
   if(rangeStartTime == 0 && trackedRangeHigh == 0.0 && trackedRangeLow == 0.0)
      return;
   rangeStartTime=0;
   trackedRangeHigh=0.0;
   trackedRangeLow=0.0;
   GlobalVariableSet(statePrefix+"rtime", 0.0);
   GlobalVariableSet(statePrefix+"rhigh", 0.0);
   GlobalVariableSet(statePrefix+"rlow", 0.0);
}

void UpdateRangeClock()
{
   if(!UseRangeTimeExit || RangeTimeMinutes <= 0 || CountPosition() < 2)
   {
      ResetRangeClock();
      return;
   }

   double high=GetHighestPositionPrice();
   double low=GetLowestPositionPrice();
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick)) return;

   if(high <= low || tick.bid < low || tick.bid > high)
   {
      ResetRangeClock();
      return;
   }

   bool boundaryChanged=(MathAbs(high-trackedRangeHigh)>_Point*0.5 ||
                         MathAbs(low-trackedRangeLow)>_Point*0.5);
   if(rangeStartTime == 0 || boundaryChanged)
   {
      rangeStartTime=TimeCurrent();
      trackedRangeHigh=high;
      trackedRangeLow=low;
      GlobalVariableSet(statePrefix+"rtime", (double)rangeStartTime);
      GlobalVariableSet(statePrefix+"rhigh", high);
      GlobalVariableSet(statePrefix+"rlow", low);
   }
}

bool RangeTimeoutReached()
{
   if(!UseRangeTimeExit || RangeTimeMinutes <= 0 || rangeStartTime <= 0)
      return false;
   return ((TimeCurrent()-rangeStartTime) >= RangeTimeMinutes*60);
}

// Call this only with open EA positions.
// Equity > Balance is specifically required by the user for range-time exit.
bool ShouldRangeClose()
{
   return RangeTimeoutReached() &&
          AccountInfoDouble(ACCOUNT_EQUITY) > AccountInfoDouble(ACCOUNT_BALANCE) &&
          GetFloatingProfit() > 0.0;
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
      425
   );


   ObjectSetInteger(
      0,
      bg,
      OBJPROP_YSIZE,
      558
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
   CreatePanelLabel("ADX",       25,346, 10, clrWhite);
   CreatePanelLabel("BASKETTP",  25,370, 10, clrWhite);
   CreatePanelLabel("DAILYTP",   25,394, 10, clrWhite);
   CreatePanelLabel("RANGETIME", 25,418, 10, clrWhite);
   CreatePanelLabel("DAYLOCK",   25,442, 10, clrWhite);
   CreatePanelLabel("EMAGAP",    25,466, 10, clrWhite);
   CreatePanelLabel("VOLATILITY",25,490, 10, clrWhite);
   CreatePanelLabel("SPREAD",    25,514, 10, clrWhite);


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
   if(UseADXFilter && total == 0 && !PassADXFilter())
      status = "WAIT ADX";
   bool emaGapAllowed = PassEMAGapFilter();
   if(UseEMAGapFilter && !emaGapAllowed &&
      (total==0 || EMAGapFilterRecovery))
      status = "WAIT EMA GAP";
   bool quietMarketAllowed = PassLowVolatilityFilter();
   if(UseLowVolatilityFilter && !quietMarketAllowed)
      status = "WAIT LOW VOL";
   if(pendingBasketClose)
      status = "CLOSING BASKET";
   if(dailyLocked)
      status = "DAILY TP - STOP";


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


   double adx=0.0;
   bool adxOk=GetADXValue(adx);
   SetPanelText("ADX",
                "ADX FILTER  : " + (UseADXFilter ? (adxOk ? DoubleToString(adx,1) : "WAIT DATA") : "OFF") +
                (UseADXFilter ? StringFormat(" [%.0f..%s]", ADXMin,
                  ADXMax>0.0 ? DoubleToString(ADXMax,0) : "INF") : ""),
                (!UseADXFilter || PassADXFilter()) ? clrLime : clrTomato);

   SetPanelText("BASKETTP",
                "BASKET TP   : " + (BasketTakeProfitMoney>0.0 ?
                  DoubleToString(BasketTakeProfitMoney,2) : "OFF"), clrWhite);

   double dailyTarget=GetDailyTargetAmount();
   double dailyPnL=GetTodayEAProfit();
   SetPanelText("DAILYTP",
                "DAILY P/L   : " + DoubleToString(dailyPnL,2) +
                " / " + (dailyTarget>0.0 ? DoubleToString(dailyTarget,2) : "OFF"),
                dailyPnL>=0.0 ? clrLime : clrTomato);

   string rangeText="OFF";
   if(UseRangeTimeExit && RangeTimeMinutes>0)
   {
      if(rangeStartTime>0)
         rangeText=IntegerToString((int)(TimeCurrent()-rangeStartTime)/60) +
                   " / " + IntegerToString(RangeTimeMinutes) + " min";
      else
         rangeText="OUTSIDE / WAIT";
   }
   SetPanelText("RANGETIME", "RANGE TIMER : " + rangeText, clrWhite);
   SetPanelText("DAYLOCK", "DAY STATUS  : " +
                (dailyLocked ? "LOCKED (next server day)" : "ACTIVE"),
                dailyLocked ? clrTomato : clrLime);

   SetPanelText("EMAGAP", "EMA GAP     : " +
                (UseEMAGapFilter && emaGapCacheValid ?
                  DoubleToString(emaGapCurrentPoints,1)+" pts | " : "") +
                GetEMAGapStatusText() +
                (UseEMAGapFilter ?
                  StringFormat(" [Min %.0f]",EMAMinGapPoints) : ""),
                (!UseEMAGapFilter || emaGapAllowed) ? clrLime : clrTomato);

   SetPanelText("VOLATILITY",
                "LOW VOL     : " + lowVolStatus +
                (UseLowVolatilityFilter && lowVolATRCacheValid ?
                 StringFormat(" [ATR %.1f / AVG %.1f pts]", lowVolATRPoints,
                              lowVolBaselinePoints) : ""),
                (!UseLowVolatilityFilter || quietMarketAllowed) ? clrLime : clrTomato);

   SetPanelText("SPREAD",
                "SPREAD      : " +
                (UseLowVolatilityFilter && LowVolCheckSpread ?
                 StringFormat("%.1f pts (%.1f%% ATR)", lowVolSpreadPoints,
                              lowVolSpreadATRPercent) : "OFF"),
                (!UseLowVolatilityFilter || quietMarketAllowed) ? clrLime : clrTomato);

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


   if(UseLowVolatilityFilter &&
      (LowVolATRPeriod < 2 || LowVolBaselineBars < 5 || LowVolBaselineBars > 2000 ||
       LowVolConfirmBars < 1 || LowVolConfirmBars > 50 ||
       LowVolMaxATRRatio <= 0.0 || LowVolMaxATRRatio > 5.0 ||
       LowVolMaxATRPoints < 0.0 || LowVolMaxSpreadATRPercent < 0.0 ||
       LowVolMaxSpreadPoints < 0.0))
   {
      Print("ERROR: Invalid low-volatility filter parameters");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(ADXPeriod < 2 || RangeTimeMinutes < 0 || BasketTakeProfitMoney < 0.0 ||
      DailyTPPercent < 0.0 || DailyTPMoney < 0.0 || ADXMin < 0.0 || ADXMax < 0.0 ||
      EMAMinGapPoints < 0.0 || EMAShrinkConfirmBars < 1 || EMAShrinkConfirmBars > 10 ||
      (ADXMax > 0.0 && ADXMax < ADXMin))
   {
      Print("ERROR: Invalid ADX / EMA Gap / TP / Range parameters");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(UseADXFilter)
   {
      handle_adx=iADX(_Symbol,_Period,ADXPeriod);
      if(handle_adx == INVALID_HANDLE)
      {
         Print("ADX HANDLE ERROR");
         return INIT_FAILED;
      }
   }

   if(UseLowVolatilityFilter)
   {
      handle_low_vol_atr = iATR(_Symbol, LowVolTimeframe, LowVolATRPeriod);
      if(handle_low_vol_atr == INVALID_HANDLE)
      {
         Print("LOW VOL ATR HANDLE ERROR | ", GetLastError());
         return INIT_FAILED;
      }
   }

   statePrefix=StringFormat("HRE_%I64d_%s_%I64u_",
                            AccountInfoInteger(ACCOUNT_LOGIN),_Symbol,MagicNumber);
   SyncDailyState();

   // Restore range timer only for the same EA/position range.
   if(GlobalVariableCheck(statePrefix+"rtime") &&
      GlobalVariableCheck(statePrefix+"rhigh") &&
      GlobalVariableCheck(statePrefix+"rlow"))
   {
      rangeStartTime=(datetime)GlobalVariableGet(statePrefix+"rtime");
      trackedRangeHigh=GlobalVariableGet(statePrefix+"rhigh");
      trackedRangeLow=GlobalVariableGet(statePrefix+"rlow");
   }

   //==================================================
   // RESET
   //==================================================
   initial = (CountPosition()==0);

   recovery_level = MathMax(0, CountPosition()/2 - 1);


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
   // 1) Target and time-range accounting happens before any new order.
   SyncDailyState();
   UpdateRangeClock();

   // 2) Daily cap is highest priority: close EA positions and forbid
   //    new INITIAL/RECOVERY orders until the next broker-server day.
   if(CheckDailyTakeProfit())
   {
      if(CountPosition()>0)
         CloseAllPosition();  // retry each tick while day remains locked
      UpdatePanel();
      return;
   }

   // 3) Retry an incomplete basket close without opening new positions.
   if(pendingBasketClose)
   {
      if(CloseAllPosition()) pendingBasketClose=false;
      UpdatePanel();
      return;
   }

   int position_count=CountPosition();
   if(position_count>0)
   {
      // Regular basket TP applies only to this EA's floating profit.
      if(BasketTakeProfitMoney>0.0 && GetFloatingProfit()>=BasketTakeProfitMoney)
      {
         PrintFormat("BASKET TP | EA floating=%.2f | target=%.2f",
                     GetFloatingProfit(),BasketTakeProfitMoney);
         pendingBasketClose=true;
      }
      // Smallest possible TP after being trapped in POSITION range.
      else if(ShouldRangeClose())
      {
         PrintFormat("RANGE TIME TP | minutes=%d | EA floating=%.2f | equity=%.2f | balance=%.2f",
                    (int)((TimeCurrent()-rangeStartTime)/60),GetFloatingProfit(),
                    AccountInfoDouble(ACCOUNT_EQUITY),AccountInfoDouble(ACCOUNT_BALANCE));
         pendingBasketClose=true;
      }

      if(pendingBasketClose)
      {
         if(CloseAllPosition()) pendingBasketClose=false;
         UpdatePanel();
         return;
      }
   }

   // 4) INIT: ADX filter applies to a NEW cycle by default.
   //    If EA is attached with existing matching positions, recover state.
   if(initial)
   {
      if(position_count>0)
      {
         initial=false;
         recovery_level=MathMax(0,position_count/2-1);
      }
      else
      {
         if(PassLowVolatilityFilter() && PassEMAGapFilter() &&
            PassADXFilter() && OpenInitialPosition())
         {
            initial=false;
            Print("INITIAL COMPLETE");
         }
         UpdatePanel();
         return;
      }
   }

   if(position_count==0)
   {
      ResetCycle();
      UpdatePanel();
      return;
   }

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick)) return;

   double highest_price=GetHighestPositionPrice();
   double lowest_price=GetLowestPositionPrice();
   if(highest_price<=0.0 || lowest_price<=0.0) return;

   // Keep original EMA-based recovery logic. Optional ADX filtering is
   // handled inside OpenRecovery().
   RecoveryDown(tick.ask,lowest_price);
   RecoveryUp(tick.bid,highest_price);
   UpdatePanel();
}

// Trade events can change today's realized profit within the same second.
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   cachedHistoryTime=0;
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


   if(handle_adx != INVALID_HANDLE)
      IndicatorRelease(handle_adx);
   if(handle_low_vol_atr != INVALID_HANDLE)
      IndicatorRelease(handle_low_vol_atr);

   DeletePanel();
}
//+------------------------------------------------------------------+