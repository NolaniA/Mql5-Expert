//+------------------------------------------------------------------+
//| MyEA.mq5                                                         |
//| First working implementation of the strategy in strategy.md.     |
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"

#include <Trade/Trade.mqh>

input int    InpMaxSpreadPoints = 200;
input ulong  InpMagicNumber     = 26080801;
input bool   InpEnableSell      = false;
input bool   InpUseSessionFilter = true;
input int    InpSessionStartHour = 12;
input int    InpSessionEndHour   = 21;

const string          TRADE_SYMBOL            = "XAUUSDc";
const ENUM_TIMEFRAMES ENTRY_TIMEFRAME         = PERIOD_M15;
const ENUM_TIMEFRAMES H1_TREND_TIMEFRAME      = PERIOD_H1;
const ENUM_TIMEFRAMES H4_STRUCTURE_TIMEFRAME  = PERIOD_H4;
const double          RISK_PERCENT            = 1.0;
const double          MAX_DAILY_LOSS_PERCENT  = 2.0;
const double          MIN_REWARD_TO_RISK      = 1.5;
const int             SWING_STRENGTH          = 2;
const int             SWING_LOOKBACK_BARS     = 240;

CTrade trade;
datetime last_bar_time = 0;
datetime last_entry_bar_time = 0;

int diag_m15_bars_evaluated = 0;

int diag_buy_h4_structure_true = 0;
int diag_buy_h1_breakout_true = 0;
int diag_buy_m15_sweep_true = 0;
int diag_buy_m15_bullish_close_true = 0;
int diag_buy_complete_signal = 0;

int diag_sell_h4_structure_true = 0;
int diag_sell_h1_breakout_true = 0;
int diag_sell_m15_sweep_true = 0;
int diag_sell_m15_bearish_close_true = 0;
int diag_sell_complete_signal = 0;

int diag_signals_passed_to_try_open = 0;
int diag_spread_rejected = 0;
int diag_duplicate_signal_rejected = 0;
int diag_existing_position_rejected = 0;
int diag_daily_risk_rejected = 0;
int diag_invalid_tick_rejected = 0;
int diag_invalid_point_rejected = 0;
int diag_invalid_stop_rejected = 0;
int diag_position_sizing_rejected = 0;
int diag_position_sizing_below_min_rejected = 0;
int diag_position_sizing_above_max_rejected = 0;
int diag_position_sizing_invalid_tick_value_rejected = 0;
int diag_position_sizing_invalid_tick_size_rejected = 0;
int diag_position_sizing_normalization_failure_rejected = 0;
int diag_position_sizing_other_rejected = 0;
int diag_position_sizing_order_calc_one_lot_failed = 0;
int diag_position_sizing_loss_for_one_lot_nonpositive = 0;
int diag_position_sizing_invalid_volume_step = 0;
int diag_position_sizing_normalized_below_min = 0;
int diag_position_sizing_order_calc_volume_failed = 0;
int diag_position_sizing_actual_risk_exceeds = 0;
int diag_position_sizing_volume_reduced_to_fit_risk = 0;
int diag_market_session_rejected = 0;
int diag_margin_rejected = 0;
int diag_orders_attempted = 0;
int diag_orders_successful = 0;
int diag_orders_rejected_by_server = 0;
int diag_conflicting_signal_rejected = 0;
int diag_direction_filter_rejected = 0;
int diag_session_filter_rejected = 0;
int diag_buy_complete_breakout_age[6];
int diag_sell_complete_breakout_age[6];
int diag_buy_executed_breakout_age[6];
int diag_sell_executed_breakout_age[6];
int diag_spread_samples[];
int diag_signal_spread_samples[];
bool diag_symbol_snapshot_printed = false;

struct SignalCheck
{
   bool h4_structure;
   bool h1_breakout;
   bool m15_sweep;
   bool m15_close_direction;
   bool complete;
   double h1_level;
   double m15_level;
   double sweep_extreme;
   int h1_breakout_persistence_bars;
   datetime signal_time;
};

string BoolText(const bool value)
{
   return value ? "true" : "false";
}

int BreakoutAgeBucket(const int persistence_bars)
{
   if(persistence_bars <= 0)
      return 0;
   if(persistence_bars == 1)
      return 1;
   if(persistence_bars <= 3)
      return 2;
   if(persistence_bars <= 6)
      return 3;
   if(persistence_bars <= 12)
      return 4;
   return 5;
}

void RecordBreakoutAge(int &buckets[], const int persistence_bars)
{
   buckets[BreakoutAgeBucket(persistence_bars)]++;
}

void PrintBreakoutAgeStats(const string label, int &buckets[])
{
   PrintFormat(
      "DIAGNOSTIC_SUMMARY %s unknown=%d age_1=%d age_2_3=%d age_4_6=%d age_7_12=%d age_13_plus=%d",
      label,
      buckets[0],
      buckets[1],
      buckets[2],
      buckets[3],
      buckets[4],
      buckets[5]
   );
}

void AddSpreadSample(int &samples[], const int spread_points)
{
   if(spread_points < 0)
      return;

   const int size = ArraySize(samples);
   ArrayResize(samples, size + 1);
   samples[size] = spread_points;
}

int CurrentSpreadPoints(MqlTick &tick)
{
   if(!SymbolInfoTick(TRADE_SYMBOL, tick) || tick.ask <= 0.0 || tick.bid <= 0.0)
      return -1;

   const double point = SymbolInfoDouble(TRADE_SYMBOL, SYMBOL_POINT);
   if(point <= 0.0)
      return -1;

   return (int)MathRound((tick.ask - tick.bid) / point);
}

void PrintSymbolSpreadSnapshot(const MqlTick &tick)
{
   if(diag_symbol_snapshot_printed)
      return;

   const double point = SymbolInfoDouble(TRADE_SYMBOL, SYMBOL_POINT);
   const int digits = (int)SymbolInfoInteger(TRADE_SYMBOL, SYMBOL_DIGITS);
   const double max_spread_price = InpMaxSpreadPoints * point;

   PrintFormat(
      "SPREAD_DIAGNOSTIC SYMBOL symbol=%s point=%s digits=%d bid=%s ask=%s max_spread_points=%d max_spread_price=%s calculation=round((ask-bid)/SYMBOL_POINT)",
      TRADE_SYMBOL,
      DoubleToString(point, digits),
      digits,
      DoubleToString(tick.bid, digits),
      DoubleToString(tick.ask, digits),
      InpMaxSpreadPoints,
      DoubleToString(max_spread_price, digits)
   );

   diag_symbol_snapshot_printed = true;
}

void PrintSpreadStats(const string label, int &samples[])
{
   const int size = ArraySize(samples);
   if(size <= 0)
   {
      PrintFormat("SPREAD_DIAGNOSTIC %s samples=0", label);
      return;
   }

   int sorted[];
   ArrayCopy(sorted, samples);
   ArraySort(sorted);

   double sum = 0.0;
   for(int i = 0; i < size; i++)
      sum += samples[i];

   const double average = sum / size;
   const double median = (size % 2 == 1) ? (double)sorted[size / 2] : ((double)sorted[size / 2 - 1] + (double)sorted[size / 2]) / 2.0;
   int p95_index = (int)MathCeil(size * 0.95) - 1;
   if(p95_index < 0)
      p95_index = 0;
   if(p95_index >= size)
      p95_index = size - 1;

   PrintFormat(
      "SPREAD_DIAGNOSTIC %s samples=%d min_points=%d average_points=%.2f median_points=%.2f p95_points=%d max_points=%d",
      label,
      size,
      sorted[0],
      average,
      median,
      sorted[p95_index],
      sorted[size - 1]
   );
}

double NormalizeSymbolPrice(const double price)
{
   const int digits = (int)SymbolInfoInteger(TRADE_SYMBOL, SYMBOL_DIGITS);
   return NormalizeDouble(price, digits);
}

int VolumeDigits(const double step)
{
   for(int digits = 0; digits <= 8; digits++)
   {
      const double scaled = step * MathPow(10.0, digits);
      if(MathAbs(scaled - MathRound(scaled)) < 0.0000001)
         return digits;
   }
   return 8;
}

double NormalizeVolumeDown(const double raw_volume)
{
   const double min_volume = SymbolInfoDouble(TRADE_SYMBOL, SYMBOL_VOLUME_MIN);
   const double max_volume = SymbolInfoDouble(TRADE_SYMBOL, SYMBOL_VOLUME_MAX);
   const double step = SymbolInfoDouble(TRADE_SYMBOL, SYMBOL_VOLUME_STEP);

   if(step <= 0.0 || max_volume <= 0.0)
      return 0.0;

   double volume = MathFloor(raw_volume / step) * step;
   volume = NormalizeDouble(volume, VolumeDigits(step));

   if(volume > max_volume)
      volume = max_volume;

   if(volume < min_volume)
      return 0.0;

   return volume;
}

datetime CurrentServerDayStart()
{
   MqlDateTime now;
   TimeToStruct(TimeCurrent(), now);
   now.hour = 0;
   now.min = 0;
   now.sec = 0;
   return StructToTime(now);
}

int SecondsFromSessionTime(const datetime value)
{
   MqlDateTime session_time;
   TimeToStruct(value, session_time);
   return session_time.hour * 3600 + session_time.min * 60 + session_time.sec;
}

bool IsBrokerTradeSessionOpen()
{
   MqlDateTime now;
   TimeToStruct(TimeCurrent(), now);
   const ENUM_DAY_OF_WEEK day = (ENUM_DAY_OF_WEEK)now.day_of_week;
   const int current_seconds = now.hour * 3600 + now.min * 60 + now.sec;

   bool session_found = false;
   for(uint session = 0; session < 24; session++)
   {
      datetime session_from = 0;
      datetime session_to = 0;
      if(!SymbolInfoSessionTrade(TRADE_SYMBOL, day, session, session_from, session_to))
         break;

      session_found = true;
      const int from_seconds = SecondsFromSessionTime(session_from);
      const int to_seconds = SecondsFromSessionTime(session_to);

      if(from_seconds == to_seconds)
         return true;
      if(from_seconds < to_seconds && current_seconds >= from_seconds && current_seconds < to_seconds)
         return true;
      if(from_seconds > to_seconds && (current_seconds >= from_seconds || current_seconds < to_seconds))
         return true;
   }

   return !session_found;
}

bool IsWithinStrategySession()
{
   if(!InpUseSessionFilter)
      return true;

   const int start_hour = MathMax(0, MathMin(23, InpSessionStartHour));
   const int end_hour = MathMax(0, MathMin(24, InpSessionEndHour));
   if(start_hour == end_hour)
      return true;

   MqlDateTime now;
   TimeToStruct(TimeCurrent(), now);
   const int current_hour = now.hour;

   if(start_hour < end_hour)
      return current_hour >= start_hour && current_hour < end_hour;

   return current_hour >= start_hour || current_hour < end_hour;
}

bool GetTodayDealPnl(double &pnl)
{
   pnl = 0.0;
   const datetime start_time = CurrentServerDayStart();
   const datetime end_time = TimeCurrent();

   if(!HistorySelect(start_time, end_time))
      return false;

   const int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
   {
      const ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0)
         continue;

      if(HistoryDealGetString(ticket, DEAL_SYMBOL) != TRADE_SYMBOL)
         continue;

      if((ulong)HistoryDealGetInteger(ticket, DEAL_MAGIC) != InpMagicNumber)
         continue;

      pnl += HistoryDealGetDouble(ticket, DEAL_PROFIT);
      pnl += HistoryDealGetDouble(ticket, DEAL_COMMISSION);
      pnl += HistoryDealGetDouble(ticket, DEAL_SWAP);
   }

   return true;
}

bool HasOpenPositionForSymbolAndMagic()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(PositionGetString(POSITION_SYMBOL) != TRADE_SYMBOL)
         continue;

      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      return true;
   }

   return false;
}

bool IsSwingHigh(const ENUM_TIMEFRAMES timeframe, const int shift)
{
   const int bars = iBars(TRADE_SYMBOL, timeframe);
   if(shift <= SWING_STRENGTH || shift + SWING_STRENGTH >= bars)
      return false;

   const double center = iHigh(TRADE_SYMBOL, timeframe, shift);
   if(center <= 0.0)
      return false;

   for(int offset = 1; offset <= SWING_STRENGTH; offset++)
   {
      if(center <= iHigh(TRADE_SYMBOL, timeframe, shift - offset))
         return false;
      if(center <= iHigh(TRADE_SYMBOL, timeframe, shift + offset))
         return false;
   }

   return true;
}

bool IsSwingLow(const ENUM_TIMEFRAMES timeframe, const int shift)
{
   const int bars = iBars(TRADE_SYMBOL, timeframe);
   if(shift <= SWING_STRENGTH || shift + SWING_STRENGTH >= bars)
      return false;

   const double center = iLow(TRADE_SYMBOL, timeframe, shift);
   if(center <= 0.0)
      return false;

   for(int offset = 1; offset <= SWING_STRENGTH; offset++)
   {
      if(center >= iLow(TRADE_SYMBOL, timeframe, shift - offset))
         return false;
      if(center >= iLow(TRADE_SYMBOL, timeframe, shift + offset))
         return false;
   }

   return true;
}

bool FindLatestSwing(const ENUM_TIMEFRAMES timeframe, const bool want_high, double &price, int &shift)
{
   const int bars = iBars(TRADE_SYMBOL, timeframe);
   const int first_shift = SWING_STRENGTH + 1;
   const int last_shift = MathMin(bars - SWING_STRENGTH - 1, SWING_LOOKBACK_BARS);

   for(int candidate = first_shift; candidate <= last_shift; candidate++)
   {
      const bool found = want_high ? IsSwingHigh(timeframe, candidate) : IsSwingLow(timeframe, candidate);
      if(!found)
         continue;

      shift = candidate;
      price = want_high ? iHigh(TRADE_SYMBOL, timeframe, candidate) : iLow(TRADE_SYMBOL, timeframe, candidate);
      return true;
   }

   return false;
}

bool FindTwoRecentSwings(
   const ENUM_TIMEFRAMES timeframe,
   const bool want_high,
   double &latest_price,
   double &previous_price
)
{
   const int bars = iBars(TRADE_SYMBOL, timeframe);
   const int first_shift = SWING_STRENGTH + 1;
   const int last_shift = MathMin(bars - SWING_STRENGTH - 1, SWING_LOOKBACK_BARS);
   int found_count = 0;

   for(int candidate = first_shift; candidate <= last_shift; candidate++)
   {
      const bool found = want_high ? IsSwingHigh(timeframe, candidate) : IsSwingLow(timeframe, candidate);
      if(!found)
         continue;

      const double price = want_high ? iHigh(TRADE_SYMBOL, timeframe, candidate) : iLow(TRADE_SYMBOL, timeframe, candidate);
      if(found_count == 0)
         latest_price = price;
      else
      {
         previous_price = price;
         return true;
      }

      found_count++;
   }

   return false;
}

bool IsH4StructureBullish()
{
   double latest_high = 0.0;
   double previous_high = 0.0;
   double latest_low = 0.0;
   double previous_low = 0.0;

   if(!FindTwoRecentSwings(H4_STRUCTURE_TIMEFRAME, true, latest_high, previous_high))
      return false;
   if(!FindTwoRecentSwings(H4_STRUCTURE_TIMEFRAME, false, latest_low, previous_low))
      return false;

   return latest_high > previous_high && latest_low > previous_low;
}

bool IsH4StructureBearish()
{
   double latest_high = 0.0;
   double previous_high = 0.0;
   double latest_low = 0.0;
   double previous_low = 0.0;

   if(!FindTwoRecentSwings(H4_STRUCTURE_TIMEFRAME, true, latest_high, previous_high))
      return false;
   if(!FindTwoRecentSwings(H4_STRUCTURE_TIMEFRAME, false, latest_low, previous_low))
      return false;

   return latest_high < previous_high && latest_low < previous_low;
}

bool HasH1Breakout(const bool buy, double &level, int &persistence_bars)
{
   persistence_bars = 0;
   int swing_shift = 0;
   if(!FindLatestSwing(H1_TREND_TIMEFRAME, buy, level, swing_shift))
      return false;

   const double last_closed_h1_close = iClose(TRADE_SYMBOL, H1_TREND_TIMEFRAME, 1);
   if(last_closed_h1_close <= 0.0)
      return false;

   const bool breakout = buy ? last_closed_h1_close > level : last_closed_h1_close < level;
   if(!breakout)
      return false;

   for(int shift = 1; shift < swing_shift; shift++)
   {
      const double close = iClose(TRADE_SYMBOL, H1_TREND_TIMEFRAME, shift);
      if(close <= 0.0)
         break;

      const bool remained_broken = buy ? close > level : close < level;
      if(!remained_broken)
         break;

      persistence_bars++;
   }

   return true;
}

void ResetSignal(SignalCheck &signal)
{
   signal.h4_structure = false;
   signal.h1_breakout = false;
   signal.m15_sweep = false;
   signal.m15_close_direction = false;
   signal.complete = false;
   signal.h1_level = 0.0;
   signal.m15_level = 0.0;
   signal.sweep_extreme = 0.0;
   signal.h1_breakout_persistence_bars = 0;
   signal.signal_time = iTime(TRADE_SYMBOL, ENTRY_TIMEFRAME, 1);
}

void BuildSignal(const bool buy, SignalCheck &signal)
{
   ResetSignal(signal);

   signal.h4_structure = buy ? IsH4StructureBullish() : IsH4StructureBearish();
   signal.h1_breakout = HasH1Breakout(buy, signal.h1_level, signal.h1_breakout_persistence_bars);

   const double open = iOpen(TRADE_SYMBOL, ENTRY_TIMEFRAME, 1);
   const double close = iClose(TRADE_SYMBOL, ENTRY_TIMEFRAME, 1);
   const double high = iHigh(TRADE_SYMBOL, ENTRY_TIMEFRAME, 1);
   const double low = iLow(TRADE_SYMBOL, ENTRY_TIMEFRAME, 1);

   signal.m15_close_direction = buy ? close > open : close < open;

   signal.m15_level = buy ? iLow(TRADE_SYMBOL, ENTRY_TIMEFRAME, 2) : iHigh(TRADE_SYMBOL, ENTRY_TIMEFRAME, 2);
   if(signal.m15_level <= 0.0)
      return;

   if(buy)
   {
      signal.sweep_extreme = low;
      signal.m15_sweep = low < signal.m15_level && close > signal.m15_level;
   }
   else
   {
      signal.sweep_extreme = high;
      signal.m15_sweep = high > signal.m15_level && close < signal.m15_level;
   }

   signal.complete = signal.h4_structure && signal.h1_breakout && signal.m15_sweep && signal.m15_close_direction;
}

void LogStrategyRejection(const string side, const SignalCheck &signal)
{
   PrintFormat(
      "%s entry rejected on %s: H4 structure=%s, H1 breakout=%s, M15 sweep=%s, M15 candle direction=%s, H1 level=%.2f, M15 sweep level=%.2f.",
      side,
      TimeToString(signal.signal_time, TIME_DATE | TIME_MINUTES),
      BoolText(signal.h4_structure),
      BoolText(signal.h1_breakout),
      BoolText(signal.m15_sweep),
      BoolText(signal.m15_close_direction),
      signal.h1_level,
      signal.m15_level
   );
}

bool CalculatePositionSize(
   const bool buy,
   const double entry_price,
   const double stop_loss,
   const double risk_money,
   double &volume,
   double &actual_risk
)
{
   volume = 0.0;
   actual_risk = 0.0;

   const ENUM_ORDER_TYPE order_type = buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double loss_for_one_lot = 0.0;
   if(!OrderCalcProfit(order_type, TRADE_SYMBOL, 1.0, entry_price, stop_loss, loss_for_one_lot))
   {
      diag_position_sizing_order_calc_one_lot_failed++;
      if(SymbolInfoDouble(TRADE_SYMBOL, SYMBOL_TRADE_TICK_VALUE) <= 0.0)
         diag_position_sizing_invalid_tick_value_rejected++;
      else if(SymbolInfoDouble(TRADE_SYMBOL, SYMBOL_TRADE_TICK_SIZE) <= 0.0)
         diag_position_sizing_invalid_tick_size_rejected++;
      else
         diag_position_sizing_other_rejected++;
      return false;
   }

   loss_for_one_lot = MathAbs(loss_for_one_lot);
   if(loss_for_one_lot <= 0.0)
   {
      diag_position_sizing_loss_for_one_lot_nonpositive++;
      if(SymbolInfoDouble(TRADE_SYMBOL, SYMBOL_TRADE_TICK_VALUE) <= 0.0)
         diag_position_sizing_invalid_tick_value_rejected++;
      else if(SymbolInfoDouble(TRADE_SYMBOL, SYMBOL_TRADE_TICK_SIZE) <= 0.0)
         diag_position_sizing_invalid_tick_size_rejected++;
      else
         diag_position_sizing_other_rejected++;
      return false;
   }

   const double raw_volume = risk_money / loss_for_one_lot;
   const double min_volume = SymbolInfoDouble(TRADE_SYMBOL, SYMBOL_VOLUME_MIN);
   const double max_volume = SymbolInfoDouble(TRADE_SYMBOL, SYMBOL_VOLUME_MAX);
   const double step = SymbolInfoDouble(TRADE_SYMBOL, SYMBOL_VOLUME_STEP);
   volume = NormalizeVolumeDown(raw_volume);
   if(volume <= 0.0)
   {
      if(raw_volume < min_volume)
         diag_position_sizing_below_min_rejected++;
      else if(raw_volume > max_volume)
         diag_position_sizing_above_max_rejected++;
      else if(step <= 0.0 || min_volume <= 0.0 || max_volume <= 0.0)
      {
         diag_position_sizing_normalization_failure_rejected++;
         diag_position_sizing_invalid_volume_step++;
      }
      else
      {
         diag_position_sizing_normalization_failure_rejected++;
         diag_position_sizing_normalized_below_min++;
      }
      return false;
   }

   double profit_at_stop = 0.0;
   if(!OrderCalcProfit(order_type, TRADE_SYMBOL, volume, entry_price, stop_loss, profit_at_stop))
   {
      diag_position_sizing_order_calc_volume_failed++;
      if(SymbolInfoDouble(TRADE_SYMBOL, SYMBOL_TRADE_TICK_VALUE) <= 0.0)
         diag_position_sizing_invalid_tick_value_rejected++;
      else if(SymbolInfoDouble(TRADE_SYMBOL, SYMBOL_TRADE_TICK_SIZE) <= 0.0)
         diag_position_sizing_invalid_tick_size_rejected++;
      else
         diag_position_sizing_other_rejected++;
      return false;
   }

   actual_risk = MathAbs(profit_at_stop);
   while(actual_risk - risk_money > 0.01)
   {
      const double next_volume = NormalizeDouble(volume - step, VolumeDigits(step));
      if(next_volume < min_volume)
      {
         volume = 0.0;
         actual_risk = 0.0;
         diag_position_sizing_below_min_rejected++;
         return false;
      }

      volume = next_volume;
      diag_position_sizing_volume_reduced_to_fit_risk++;

      if(!OrderCalcProfit(order_type, TRADE_SYMBOL, volume, entry_price, stop_loss, profit_at_stop))
      {
         diag_position_sizing_order_calc_volume_failed++;
         if(SymbolInfoDouble(TRADE_SYMBOL, SYMBOL_TRADE_TICK_VALUE) <= 0.0)
            diag_position_sizing_invalid_tick_value_rejected++;
         else if(SymbolInfoDouble(TRADE_SYMBOL, SYMBOL_TRADE_TICK_SIZE) <= 0.0)
            diag_position_sizing_invalid_tick_size_rejected++;
         else
            diag_position_sizing_other_rejected++;
         return false;
      }

      actual_risk = MathAbs(profit_at_stop);
   }

   return true;
}

bool HasEnoughMargin(const bool buy, const double volume, const double entry_price, double &required_margin)
{
   required_margin = 0.0;
   const ENUM_ORDER_TYPE order_type = buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;

   if(!OrderCalcMargin(order_type, TRADE_SYMBOL, volume, entry_price, required_margin))
      return false;

   return required_margin <= AccountInfoDouble(ACCOUNT_MARGIN_FREE);
}

void TryOpenSignal(const bool buy, const SignalCheck &signal)
{
   const string side = buy ? "BUY" : "SELL";
   const datetime entry_bar_time = iTime(TRADE_SYMBOL, ENTRY_TIMEFRAME, 0);

   diag_signals_passed_to_try_open++;

   if(entry_bar_time == last_entry_bar_time)
   {
      diag_duplicate_signal_rejected++;
      PrintFormat("%s entry rejected: an entry was already processed on the current M15 candle.", side);
      return;
   }
   last_entry_bar_time = entry_bar_time;

   if(HasOpenPositionForSymbolAndMagic())
   {
      diag_existing_position_rejected++;
      PrintFormat("%s entry rejected: existing position found for %s with Magic Number %s.", side, TRADE_SYMBOL, IntegerToString((long)InpMagicNumber));
      return;
   }

   MqlTick tick;
   const int spread_points = CurrentSpreadPoints(tick);
   if(spread_points < 0)
   {
      diag_invalid_tick_rejected++;
      PrintFormat("%s entry rejected: no valid tick is available for %s.", side, TRADE_SYMBOL);
      return;
   }
   AddSpreadSample(diag_signal_spread_samples, spread_points);
   PrintSymbolSpreadSnapshot(tick);

   const double point = SymbolInfoDouble(TRADE_SYMBOL, SYMBOL_POINT);
   if(point <= 0.0)
   {
      diag_invalid_point_rejected++;
      PrintFormat("%s entry rejected: symbol point size is invalid.", side);
      return;
   }

   if(spread_points > InpMaxSpreadPoints)
   {
      diag_spread_rejected++;
      PrintFormat("%s entry rejected: spread %d points exceeds configured limit %d.", side, spread_points, InpMaxSpreadPoints);
      return;
   }

   const double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   const double risk_money = balance * RISK_PERCENT / 100.0;
   const double max_daily_loss_money = balance * MAX_DAILY_LOSS_PERCENT / 100.0;

   double today_pnl = 0.0;
   if(!GetTodayDealPnl(today_pnl))
   {
      diag_daily_risk_rejected++;
      PrintFormat("%s entry rejected: could not read today's deal history for daily loss control.", side);
      return;
   }

   const double today_loss = MathMax(0.0, -today_pnl);
   if(today_loss >= max_daily_loss_money)
   {
      diag_daily_risk_rejected++;
      PrintFormat("%s entry rejected: daily loss %.2f has reached the %.2f limit.", side, today_loss, max_daily_loss_money);
      return;
   }

   if(today_loss + risk_money > max_daily_loss_money)
   {
      diag_daily_risk_rejected++;
      PrintFormat(
         "%s entry rejected: daily loss %.2f plus proposed risk %.2f would exceed the %.2f daily limit.",
         side,
         today_loss,
         risk_money,
         max_daily_loss_money
      );
      return;
   }

   if(!IsBrokerTradeSessionOpen())
   {
      diag_market_session_rejected++;
      PrintFormat(
         "%s entry rejected: broker trade session is closed for %s at %s.",
         side,
         TRADE_SYMBOL,
         TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS)
      );
      return;
   }

   const double entry_price = buy ? tick.ask : tick.bid;
   const double stop_reference_price = buy ? tick.bid : tick.ask;
   const long stop_level_points = SymbolInfoInteger(TRADE_SYMBOL, SYMBOL_TRADE_STOPS_LEVEL);
   const double min_stop_distance = MathMax(point, (double)stop_level_points * point);
   double stop_loss = buy ? signal.sweep_extreme - point : signal.sweep_extreme + point;

   if(buy && stop_reference_price - stop_loss < min_stop_distance)
      stop_loss = stop_reference_price - min_stop_distance;
   if(!buy && stop_loss - stop_reference_price < min_stop_distance)
      stop_loss = stop_reference_price + min_stop_distance;

   stop_loss = NormalizeSymbolPrice(stop_loss);

   if((buy && stop_loss >= stop_reference_price) || (!buy && stop_loss <= stop_reference_price))
   {
      diag_invalid_stop_rejected++;
      PrintFormat("%s entry rejected: stop loss is not valid beyond the liquidity sweep.", side);
      return;
   }

   const double risk_distance = MathAbs(entry_price - stop_loss);
   if(risk_distance <= 0.0)
   {
      diag_invalid_stop_rejected++;
      PrintFormat("%s entry rejected: risk distance is zero.", side);
      return;
   }

   const double take_profit = NormalizeSymbolPrice(buy ? entry_price + risk_distance * MIN_REWARD_TO_RISK : entry_price - risk_distance * MIN_REWARD_TO_RISK);
   double volume = 0.0;
   double actual_risk = 0.0;

   if(!CalculatePositionSize(buy, entry_price, stop_loss, risk_money, volume, actual_risk))
   {
      diag_position_sizing_rejected++;
      PrintFormat("%s entry rejected: position size could not be calculated without exceeding 1%% risk.", side);
      return;
   }

   double required_margin = 0.0;
   if(!HasEnoughMargin(buy, volume, entry_price, required_margin))
   {
      diag_margin_rejected++;
      PrintFormat("%s entry rejected: required margin %.2f exceeds free margin %.2f.", side, required_margin, AccountInfoDouble(ACCOUNT_MARGIN_FREE));
      return;
   }

   PrintFormat(
      "%s entry accepted on %s: entry=%.2f, sl=%.2f, tp=%.2f, volume=%.2f, risk=%.2f, spread=%d/%d points, h1_breakout_age_bars=%d, H1 level=%.2f, M15 sweep level=%.2f.",
      side,
      TimeToString(entry_bar_time, TIME_DATE | TIME_MINUTES),
      entry_price,
      stop_loss,
      take_profit,
      volume,
      actual_risk,
      spread_points,
      InpMaxSpreadPoints,
      signal.h1_breakout_persistence_bars,
      signal.h1_level,
      signal.m15_level
   );

   bool sent = false;
   diag_orders_attempted++;
   if(buy)
      sent = trade.Buy(volume, TRADE_SYMBOL, 0.0, stop_loss, take_profit, "MyEA buy");
   else
      sent = trade.Sell(volume, TRADE_SYMBOL, 0.0, stop_loss, take_profit, "MyEA sell");

   if(!sent)
   {
      diag_orders_rejected_by_server++;
      PrintFormat(
         "%s order rejected by server: retcode=%d, description=%s.",
         side,
         trade.ResultRetcode(),
         trade.ResultRetcodeDescription()
      );
      return;
   }

   diag_orders_successful++;
   if(buy)
      RecordBreakoutAge(diag_buy_executed_breakout_age, signal.h1_breakout_persistence_bars);
   else
      RecordBreakoutAge(diag_sell_executed_breakout_age, signal.h1_breakout_persistence_bars);
   PrintFormat(
      "%s order accepted by server: order=%s, retcode=%d, description=%s.",
      side,
      IntegerToString((long)trade.ResultOrder()),
      trade.ResultRetcode(),
      trade.ResultRetcodeDescription()
   );
}

int OnInit()
{
   if(_Symbol != TRADE_SYMBOL)
   {
      PrintFormat("MyEA initialization rejected: strategy symbol is %s but chart/tester symbol is %s.", TRADE_SYMBOL, _Symbol);
      return INIT_FAILED;
   }

   if(!SymbolSelect(TRADE_SYMBOL, true))
   {
      PrintFormat("MyEA initialization rejected: could not select symbol %s.", TRADE_SYMBOL);
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(20);
   trade.SetTypeFillingBySymbol(TRADE_SYMBOL);

   PrintFormat(
      "MyEA initialized: symbol=%s, entry=M15, trend=H1/H4, risk=%.2f%%, daily loss cap=%.2f%%, RR=%.2f, spread limit=%d points, Magic Number=%s. Swings use confirmed %d-left/%d-right closed-candle pivots.",
      TRADE_SYMBOL,
      RISK_PERCENT,
      MAX_DAILY_LOSS_PERCENT,
      MIN_REWARD_TO_RISK,
      InpMaxSpreadPoints,
      IntegerToString((long)InpMagicNumber),
      SWING_STRENGTH,
      SWING_STRENGTH
   );

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   const int signals_passed_after_spread = diag_signals_passed_to_try_open - diag_spread_rejected;
   const int accounted_after_spread =
      diag_position_sizing_rejected +
      diag_existing_position_rejected +
      diag_daily_risk_rejected +
      diag_invalid_stop_rejected +
      diag_duplicate_signal_rejected +
      diag_margin_rejected +
      diag_invalid_tick_rejected +
      diag_invalid_point_rejected +
      diag_market_session_rejected +
      diag_orders_attempted;
   const int unexplained_after_spread = signals_passed_after_spread - accounted_after_spread;
   const int position_sizing_accounted =
      diag_position_sizing_below_min_rejected +
      diag_position_sizing_above_max_rejected +
      diag_position_sizing_invalid_tick_value_rejected +
      diag_position_sizing_invalid_tick_size_rejected +
      diag_position_sizing_normalization_failure_rejected +
      diag_position_sizing_other_rejected;

   PrintFormat(
      "DIAGNOSTIC_SUMMARY M15 bars_evaluated=%d deinit_reason=%d",
      diag_m15_bars_evaluated,
      reason
   );
   PrintFormat(
      "DIAGNOSTIC_SUMMARY BUY h4_structure_true=%d h1_breakout_true=%d m15_sweep_true=%d m15_bullish_close_true=%d complete_buy_signal=%d",
      diag_buy_h4_structure_true,
      diag_buy_h1_breakout_true,
      diag_buy_m15_sweep_true,
      diag_buy_m15_bullish_close_true,
      diag_buy_complete_signal
   );
   PrintFormat(
      "DIAGNOSTIC_SUMMARY SELL h4_structure_true=%d h1_breakout_true=%d m15_sweep_true=%d m15_bearish_close_true=%d complete_sell_signal=%d",
      diag_sell_h4_structure_true,
      diag_sell_h1_breakout_true,
      diag_sell_m15_sweep_true,
      diag_sell_m15_bearish_close_true,
      diag_sell_complete_signal
   );
   PrintFormat(
      "DIAGNOSTIC_SUMMARY EXECUTION signals_passed_to_try_open=%d spread_rejected=%d daily_risk_rejected=%d position_sizing_rejected=%d margin_rejected=%d orders_attempted=%d orders_successful=%d orders_rejected_by_server=%d",
      diag_signals_passed_to_try_open,
      diag_spread_rejected,
      diag_daily_risk_rejected,
      diag_position_sizing_rejected,
      diag_margin_rejected,
      diag_orders_attempted,
      diag_orders_successful,
      diag_orders_rejected_by_server
   );
   PrintFormat(
      "DIAGNOSTIC_SUMMARY EXECUTION_REJECTION_ACCOUNTING signals_passed_after_spread=%d position_sizing_rejected=%d existing_position_rejected=%d daily_risk_rejected=%d invalid_stop_rejected=%d duplicate_signal_rejected=%d margin_rejected=%d invalid_tick_rejected=%d invalid_point_rejected=%d market_session_rejected=%d orders_attempted=%d accounted_after_spread=%d unexplained_after_spread=%d conflicting_signal_rejected=%d",
      signals_passed_after_spread,
      diag_position_sizing_rejected,
      diag_existing_position_rejected,
      diag_daily_risk_rejected,
      diag_invalid_stop_rejected,
      diag_duplicate_signal_rejected,
      diag_margin_rejected,
      diag_invalid_tick_rejected,
      diag_invalid_point_rejected,
      diag_market_session_rejected,
      diag_orders_attempted,
      accounted_after_spread,
      unexplained_after_spread,
      diag_conflicting_signal_rejected
   );
   PrintFormat(
      "DIAGNOSTIC_SUMMARY POSITION_SIZING_REJECTIONS total=%d below_min=%d above_max=%d invalid_tick_value=%d invalid_tick_size=%d normalization_failure=%d other=%d accounted=%d unexplained=%d",
      diag_position_sizing_rejected,
      diag_position_sizing_below_min_rejected,
      diag_position_sizing_above_max_rejected,
      diag_position_sizing_invalid_tick_value_rejected,
      diag_position_sizing_invalid_tick_size_rejected,
      diag_position_sizing_normalization_failure_rejected,
      diag_position_sizing_other_rejected,
      position_sizing_accounted,
      diag_position_sizing_rejected - position_sizing_accounted
   );
   PrintFormat(
      "DIAGNOSTIC_SUMMARY POSITION_SIZING_DETAIL order_calc_one_lot_failed=%d loss_for_one_lot_nonpositive=%d invalid_volume_step=%d normalized_below_min=%d order_calc_volume_failed=%d actual_risk_exceeds=%d volume_reduced_to_fit_risk=%d",
      diag_position_sizing_order_calc_one_lot_failed,
      diag_position_sizing_loss_for_one_lot_nonpositive,
      diag_position_sizing_invalid_volume_step,
      diag_position_sizing_normalized_below_min,
      diag_position_sizing_order_calc_volume_failed,
      diag_position_sizing_actual_risk_exceeds,
      diag_position_sizing_volume_reduced_to_fit_risk
   );
   PrintFormat(
      "DIAGNOSTIC_SUMMARY STRATEGY_FILTER direction_filter_rejected=%d session_filter_rejected=%d enable_sell=%d use_session_filter=%d session_start_hour=%d session_end_hour=%d",
      diag_direction_filter_rejected,
      diag_session_filter_rejected,
      InpEnableSell ? 1 : 0,
      InpUseSessionFilter ? 1 : 0,
      InpSessionStartHour,
      InpSessionEndHour
   );
   PrintBreakoutAgeStats("H1_BREAKOUT_AGE_COMPLETE_BUY", diag_buy_complete_breakout_age);
   PrintBreakoutAgeStats("H1_BREAKOUT_AGE_COMPLETE_SELL", diag_sell_complete_breakout_age);
   PrintBreakoutAgeStats("H1_BREAKOUT_AGE_EXECUTED_BUY", diag_buy_executed_breakout_age);
   PrintBreakoutAgeStats("H1_BREAKOUT_AGE_EXECUTED_SELL", diag_sell_executed_breakout_age);
   PrintSpreadStats("ALL_M15_BARS", diag_spread_samples);
   PrintSpreadStats("COMPLETE_SIGNALS", diag_signal_spread_samples);
}

void OnTick()
{
   const datetime current_bar = iTime(TRADE_SYMBOL, ENTRY_TIMEFRAME, 0);
   if(current_bar == 0 || current_bar == last_bar_time)
      return;

   last_bar_time = current_bar;
   diag_m15_bars_evaluated++;

   MqlTick tick;
   const int bar_spread_points = CurrentSpreadPoints(tick);
   AddSpreadSample(diag_spread_samples, bar_spread_points);
   if(bar_spread_points >= 0)
      PrintSymbolSpreadSnapshot(tick);

   SignalCheck buy_signal;
   SignalCheck sell_signal;
   BuildSignal(true, buy_signal);
   BuildSignal(false, sell_signal);

   if(buy_signal.h4_structure)
      diag_buy_h4_structure_true++;
   if(buy_signal.h1_breakout)
      diag_buy_h1_breakout_true++;
   if(buy_signal.m15_sweep)
      diag_buy_m15_sweep_true++;
   if(buy_signal.m15_close_direction)
      diag_buy_m15_bullish_close_true++;
   if(buy_signal.complete)
   {
      diag_buy_complete_signal++;
      RecordBreakoutAge(diag_buy_complete_breakout_age, buy_signal.h1_breakout_persistence_bars);
   }

   if(sell_signal.h4_structure)
      diag_sell_h4_structure_true++;
   if(sell_signal.h1_breakout)
      diag_sell_h1_breakout_true++;
   if(sell_signal.m15_sweep)
      diag_sell_m15_sweep_true++;
   if(sell_signal.m15_close_direction)
      diag_sell_m15_bearish_close_true++;
   if(sell_signal.complete)
   {
      diag_sell_complete_signal++;
      RecordBreakoutAge(diag_sell_complete_breakout_age, sell_signal.h1_breakout_persistence_bars);
   }

   if(buy_signal.complete && sell_signal.complete)
   {
      diag_conflicting_signal_rejected++;
      PrintFormat("Entry rejected on %s: both BUY and SELL signals were complete on the same closed M15 candle.", TimeToString(current_bar, TIME_DATE | TIME_MINUTES));
      last_entry_bar_time = current_bar;
      return;
   }

   if(buy_signal.complete)
   {
      if(!IsWithinStrategySession())
      {
         diag_session_filter_rejected++;
         PrintFormat("BUY entry rejected on %s: outside configured broker-time strategy session %02d:00-%02d:00.", TimeToString(current_bar, TIME_DATE | TIME_MINUTES), InpSessionStartHour, InpSessionEndHour);
         return;
      }
      TryOpenSignal(true, buy_signal);
      return;
   }

   if(sell_signal.complete)
   {
      if(!IsWithinStrategySession())
      {
         diag_session_filter_rejected++;
         PrintFormat("SELL entry rejected on %s: outside configured broker-time strategy session %02d:00-%02d:00.", TimeToString(current_bar, TIME_DATE | TIME_MINUTES), InpSessionStartHour, InpSessionEndHour);
         return;
      }
      if(!InpEnableSell)
      {
         diag_direction_filter_rejected++;
         PrintFormat("SELL entry rejected on %s: SELL direction disabled for controlled direction hypothesis test.", TimeToString(current_bar, TIME_DATE | TIME_MINUTES));
         return;
      }
      TryOpenSignal(false, sell_signal);
      return;
   }

   if(buy_signal.m15_sweep && buy_signal.m15_close_direction)
      LogStrategyRejection("BUY", buy_signal);

   if(sell_signal.m15_sweep && sell_signal.m15_close_direction)
      LogStrategyRejection("SELL", sell_signal);
}
