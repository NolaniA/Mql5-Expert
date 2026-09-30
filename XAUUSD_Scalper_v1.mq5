//+------------------------------------------------------------------+
//|                                          XAUUSD_Scalper_v1.mq5   |
//|  EMA trend + RSI momentum + ATR risk management                  |
//+------------------------------------------------------------------+
#property strict
#property version   "1.40"

#include <Trade/Trade.mqh>

CTrade trade;

//--- Trading setup
input ENUM_TIMEFRAMES SignalTimeframe = PERIOD_M5;
input int             FastEMAPeriod   = 9;
input int             SlowEMAPeriod   = 21;
input bool            UseHTFTrend     = true;
input ENUM_TIMEFRAMES TrendTimeframe  = PERIOD_H1;
input int             TrendEMAPeriod  = 200;
input int             RSIPeriod       = 14;
input double          BuyRSIMin       = 50.0;
input double          BuyRSIMax       = 68.0;
input double          SellRSIMin      = 32.0;
input double          SellRSIMax      = 50.0;
input int             ATRPeriod       = 14;
input bool            UseADXFilter    = true;
input int             ADXPeriod       = 14;
input double          MinADX          = 20.0;
input double          MaxEntryDistanceATR = 0.80;
input double          StopATR         = 1.50;
input double          TakeProfitRR    = 1.80;

//--- Risk controls
input bool            UseRiskPercent  = true;
input double          RiskPercent     = 0.5;
input double          FixedLot        = 0.01;
input double          MaxDailyLossPct = 2.0;
input bool            UseSpreadFilter = true;
input int             MaxSpreadPoints = 350;
input int             MaxPositions    = 1;
input int             SlippagePoints  = 30;
input ulong           MagicNumber     = 26091201;

//--- Position management
input bool            UseBreakEven    = true;
input double          BreakEvenAtR    = 1.00;
input int             BreakEvenLockPoints = 10;
input bool            UseTrailing     = false;
input double          TrailStartR     = 1.50;
input double          TrailATR        = 1.00;

//--- Broker-server trading hours; equal values mean all day
input int             StartHour       = 7;
input int             EndHour         = 20;
input bool            CloseAtSessionEnd = true;
input bool            AvoidWeekend      = true;
input int             FridayLastEntryHour = 18;
input int             FridayCloseHour     = 19;

int      fast_handle = INVALID_HANDLE;
int      slow_handle = INVALID_HANDLE;
int      rsi_handle  = INVALID_HANDLE;
int      atr_handle  = INVALID_HANDLE;
int      trend_handle = INVALID_HANDLE;
int      adx_handle   = INVALID_HANDLE;
datetime last_bar_time = 0;
ulong    checked_bars = 0;
ulong    blocked_session = 0;
ulong    blocked_spread = 0;
ulong    blocked_position = 0;
ulong    blocked_daily_loss = 0;
ulong    no_signal_bars = 0;
ulong    entry_attempts = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   if(FastEMAPeriod <= 0 || SlowEMAPeriod <= FastEMAPeriod ||
      TrendEMAPeriod <= 0 || RSIPeriod <= 0 || ATRPeriod <= 0 ||
      ADXPeriod <= 0 || MinADX < 0 || MaxEntryDistanceATR <= 0 || StopATR <= 0 ||
      TakeProfitRR <= 0 || RiskPercent <= 0 || MaxPositions < 1 ||
      StartHour < 0 || StartHour > 23 || EndHour < 0 || EndHour > 23 ||
      FridayLastEntryHour < 0 || FridayLastEntryHour > 23 ||
      FridayCloseHour < 0 || FridayCloseHour > 23)
      return INIT_PARAMETERS_INCORRECT;

   fast_handle = iMA(_Symbol, SignalTimeframe, FastEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   slow_handle = iMA(_Symbol, SignalTimeframe, SlowEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   rsi_handle  = iRSI(_Symbol, SignalTimeframe, RSIPeriod, PRICE_CLOSE);
   atr_handle  = iATR(_Symbol, SignalTimeframe, ATRPeriod);
   trend_handle = iMA(_Symbol, TrendTimeframe, TrendEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   adx_handle   = iADX(_Symbol, SignalTimeframe, ADXPeriod);

   if(fast_handle == INVALID_HANDLE || slow_handle == INVALID_HANDLE ||
      rsi_handle == INVALID_HANDLE || atr_handle == INVALID_HANDLE ||
      trend_handle == INVALID_HANDLE || adx_handle == INVALID_HANDLE)
   {
      Print("Cannot create indicator handles. Error: ", GetLastError());
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   if(StringFind(_Symbol, "XAU") < 0)
      Print("Warning: this EA is designed for XAUUSD; chart symbol is ", _Symbol);

   MqlTick tick;
   if(SymbolInfoTick(_Symbol, tick))
      Print("XAU Scalper v1.40 initialized | Symbol=", _Symbol,
            " | Point=", DoubleToString(_Point, _Digits),
            " | Current spread=", DoubleToString((tick.ask-tick.bid)/_Point, 1),
            " points | Max spread=", MaxSpreadPoints);

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(fast_handle != INVALID_HANDLE) IndicatorRelease(fast_handle);
   if(slow_handle != INVALID_HANDLE) IndicatorRelease(slow_handle);
   if(rsi_handle  != INVALID_HANDLE) IndicatorRelease(rsi_handle);
   if(atr_handle  != INVALID_HANDLE) IndicatorRelease(atr_handle);
   if(trend_handle != INVALID_HANDLE) IndicatorRelease(trend_handle);
   if(adx_handle   != INVALID_HANDLE) IndicatorRelease(adx_handle);

   Print("XAU Scalper summary | checked=", checked_bars,
         " | session_block=", blocked_session,
         " | spread_block=", blocked_spread,
         " | position_block=", blocked_position,
         " | daily_loss_block=", blocked_daily_loss,
         " | no_signal=", no_signal_bars,
         " | entry_attempts=", entry_attempts);
}

//+------------------------------------------------------------------+
void OnTick()
{
   ClosePositionsForSchedule();
   ManagePositions();

   datetime current_bar = iTime(_Symbol, SignalTimeframe, 0);
   if(current_bar == 0 || current_bar == last_bar_time)
      return;
   last_bar_time = current_bar;
   checked_bars++;

   if(!TradingAllowed())
      return;

   CheckEntry();
}

//+------------------------------------------------------------------+
bool TradingAllowed()
{
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) ||
      !MQLInfoInteger(MQL_TRADE_ALLOWED))
      return false;

   MqlDateTime now;
   TimeToStruct(TimeCurrent(), now);

   if(AvoidWeekend && (now.day_of_week == 0 || now.day_of_week == 6 ||
      (now.day_of_week == 5 && now.hour >= FridayLastEntryHour)))
   {
      blocked_session++;
      return false;
   }

   if(StartHour != EndHour)
   {
      bool in_session = (StartHour < EndHour)
                        ? (now.hour >= StartHour && now.hour < EndHour)
                        : (now.hour >= StartHour || now.hour < EndHour);
      if(!in_session)
      {
         blocked_session++;
         return false;
      }
   }

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return false;
   if(UseSpreadFilter && MaxSpreadPoints > 0 &&
      (tick.ask - tick.bid) / _Point > MaxSpreadPoints)
   {
      blocked_spread++;
      return false;
   }

   if(CountMyPositions() >= MaxPositions)
   {
      blocked_position++;
      return false;
   }

   if(MaxDailyLossPct > 0 && TodayNetProfit() <= -(AccountInfoDouble(ACCOUNT_BALANCE) * MaxDailyLossPct / 100.0))
   {
      Print("Daily loss limit reached; new entries are paused.");
      blocked_daily_loss++;
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
bool IsInsideSession(const MqlDateTime &now)
{
   if(StartHour == EndHour)
      return true;

   return (StartHour < EndHour)
          ? (now.hour >= StartHour && now.hour < EndHour)
          : (now.hour >= StartHour || now.hour < EndHour);
}

//+------------------------------------------------------------------+
void ClosePositionsForSchedule()
{
   MqlDateTime now;
   TimeToStruct(TimeCurrent(), now);

   bool weekend_close = AvoidWeekend &&
                        (now.day_of_week == 6 || now.day_of_week == 0 ||
                         (now.day_of_week == 5 && now.hour >= FridayCloseHour));
   bool session_close = CloseAtSessionEnd && !IsInsideSession(now);
   if(!weekend_close && !session_close)
      return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol ||
         (ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;

      if(!trade.PositionClose(ticket))
         Print("Scheduled close failed for #", ticket, ": ",
               trade.ResultRetcodeDescription());
      else
         Print("Position #", ticket, " closed by session/weekend protection.");
   }
}

//+------------------------------------------------------------------+
void CheckEntry()
{
   double fast[], slow[], rsi[], atr[], trend[], adx[], plus_di[], minus_di[];
   MqlRates rates[];
   ArrayResize(fast, 3);
   ArrayResize(slow, 3);
   ArrayResize(rsi, 3);
   ArrayResize(atr, 3);
   ArrayResize(trend, 3);
   ArrayResize(adx, 3);
   ArrayResize(plus_di, 3);
   ArrayResize(minus_di, 3);
   ArrayResize(rates, 3);
   ArraySetAsSeries(fast, true);
   ArraySetAsSeries(slow, true);
   ArraySetAsSeries(rsi, true);
   ArraySetAsSeries(atr, true);
   ArraySetAsSeries(trend, true);
   ArraySetAsSeries(adx, true);
   ArraySetAsSeries(plus_di, true);
   ArraySetAsSeries(minus_di, true);
   ArraySetAsSeries(rates, true);

   if(CopyBuffer(fast_handle, 0, 0, 3, fast) < 3 ||
      CopyBuffer(slow_handle, 0, 0, 3, slow) < 3 ||
      CopyBuffer(rsi_handle,  0, 0, 3, rsi)  < 3 ||
      CopyBuffer(atr_handle,  0, 0, 3, atr)  < 3 ||
      CopyBuffer(trend_handle, 0, 0, 3, trend) < 3 ||
      CopyBuffer(adx_handle, 0, 0, 3, adx) < 3 ||
      CopyBuffer(adx_handle, 1, 0, 3, plus_di) < 3 ||
      CopyBuffer(adx_handle, 2, 0, 3, minus_di) < 3 ||
      CopyRates(_Symbol, SignalTimeframe, 0, 3, rates) < 3)
      return;

   double htf_close = iClose(_Symbol, TrendTimeframe, 1);
   bool trend_ready = (htf_close > 0.0 && trend[1] > 0.0);
   bool htf_buy_ok  = !UseHTFTrend ||
                      (trend_ready && htf_close > trend[1] && trend[1] > trend[2]);
   bool htf_sell_ok = !UseHTFTrend ||
                      (trend_ready && htf_close < trend[1] && trend[1] < trend[2]);
   bool adx_ok      = !UseADXFilter || adx[1] >= MinADX;
   bool buy_strength  = !UseADXFilter || plus_di[1] > minus_di[1];
   bool sell_strength = !UseADXFilter || minus_di[1] > plus_di[1];
   bool near_mean = MathAbs(rates[1].close - slow[1]) <= atr[1] * MaxEntryDistanceATR;

   // Pullback-reclaim: previous candle was at/below the fast EMA and the
   // latest closed candle reclaims it in the direction of the larger trend.
   bool buy_signal = htf_buy_ok && adx_ok && buy_strength && near_mean &&
                     slow[1] > slow[2] && fast[1] > slow[1] &&
                     rates[2].close <= fast[2] &&
                     rates[1].close > fast[1] &&
                     rates[1].close > rates[1].open &&
                     rsi[1] >= BuyRSIMin && rsi[1] <= BuyRSIMax;

   bool sell_signal = htf_sell_ok && adx_ok && sell_strength && near_mean &&
                      slow[1] < slow[2] && fast[1] < slow[1] &&
                      rates[2].close >= fast[2] &&
                      rates[1].close < fast[1] &&
                      rates[1].close < rates[1].open &&
                      rsi[1] >= SellRSIMin && rsi[1] <= SellRSIMax;

   if(!buy_signal && !sell_signal)
   {
      no_signal_bars++;
      return;
   }

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return;

   double min_stop = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   double stop_distance = MathMax(atr[1] * StopATR, min_stop + (2.0 * _Point));
   double entry = buy_signal ? tick.ask : tick.bid;
   double sl = buy_signal ? entry - stop_distance : entry + stop_distance;
   double tp = buy_signal ? entry + stop_distance * TakeProfitRR
                          : entry - stop_distance * TakeProfitRR;
   sl = NormalizeDouble(sl, _Digits);
   tp = NormalizeDouble(tp, _Digits);

   ENUM_ORDER_TYPE type = buy_signal ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double lots = CalculateLots(type, entry, sl);
   if(lots <= 0)
      return;

   entry_attempts++;

   bool sent = buy_signal
               ? trade.Buy(lots, _Symbol, 0.0, sl, tp, "XAU scalp buy")
               : trade.Sell(lots, _Symbol, 0.0, sl, tp, "XAU scalp sell");

   if(!sent)
      Print("Entry failed: ", trade.ResultRetcode(), " - ", trade.ResultRetcodeDescription());
}

//+------------------------------------------------------------------+
double CalculateLots(ENUM_ORDER_TYPE type, double entry, double sl)
{
   double volume = FixedLot;
   if(UseRiskPercent)
   {
      double risk_money = AccountInfoDouble(ACCOUNT_EQUITY) * RiskPercent / 100.0;
      double loss_one_lot = 0.0;
      if(!OrderCalcProfit(type, _Symbol, 1.0, entry, sl, loss_one_lot))
      {
         Print("OrderCalcProfit failed: ", GetLastError());
         return 0.0;
      }
      loss_one_lot = MathAbs(loss_one_lot);
      if(loss_one_lot <= 0.0)
         return 0.0;
      volume = risk_money / loss_one_lot;
   }

   double min_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double max_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0.0)
      return 0.0;

   volume = MathFloor(volume / step) * step;
   volume = MathMax(min_lot, MathMin(max_lot, volume));
   int volume_digits = (int)MathMax(0, MathCeil(-MathLog10(step)));
   return NormalizeDouble(volume, volume_digits);
}

//+------------------------------------------------------------------+
void ManagePositions()
{
   double atr[];
   ArrayResize(atr, 2);
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(atr_handle, 0, 0, 2, atr) < 2 || atr[1] <= 0)
      return;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return;

   double min_stop = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol ||
         (ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;

      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
      double old_sl     = PositionGetDouble(POSITION_SL);
      double tp         = PositionGetDouble(POSITION_TP);
      double current    = (type == POSITION_TYPE_BUY) ? tick.bid : tick.ask;
      // TP preserves the original R distance even after SL moves to break-even.
      double initial_risk = (tp > 0.0 && TakeProfitRR > 0.0)
                            ? MathAbs(tp - open_price) / TakeProfitRR
                            : atr[1] * StopATR;
      if(initial_risk <= 0)
         continue;

      double profit_distance = (type == POSITION_TYPE_BUY) ? current - open_price
                                                            : open_price - current;
      double new_sl = old_sl;

      if(UseBreakEven && profit_distance >= initial_risk * BreakEvenAtR)
      {
         double be = (type == POSITION_TYPE_BUY)
                     ? open_price + BreakEvenLockPoints * _Point
                     : open_price - BreakEvenLockPoints * _Point;
         if(type == POSITION_TYPE_BUY && (new_sl == 0.0 || be > new_sl)) new_sl = be;
         if(type == POSITION_TYPE_SELL && (new_sl == 0.0 || be < new_sl)) new_sl = be;
      }

      if(UseTrailing && profit_distance >= initial_risk * TrailStartR)
      {
         double trail = (type == POSITION_TYPE_BUY) ? current - atr[1] * TrailATR
                                                    : current + atr[1] * TrailATR;
         if(type == POSITION_TYPE_BUY && (new_sl == 0.0 || trail > new_sl)) new_sl = trail;
         if(type == POSITION_TYPE_SELL && (new_sl == 0.0 || trail < new_sl)) new_sl = trail;
      }

      if(type == POSITION_TYPE_BUY)
         new_sl = MathMin(new_sl, tick.bid - min_stop);
      else
         new_sl = MathMax(new_sl, tick.ask + min_stop);
      new_sl = NormalizeDouble(new_sl, _Digits);

      bool improves = (type == POSITION_TYPE_BUY && new_sl > old_sl + _Point) ||
                      (type == POSITION_TYPE_SELL && (old_sl == 0.0 || new_sl < old_sl - _Point));
      if(improves && !trade.PositionModify(ticket, new_sl, tp))
         Print("SL modification failed: ", trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
int CountMyPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol &&
         (ulong)PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         count++;
   }
   return count;
}

//+------------------------------------------------------------------+
double TodayNetProfit()
{
   MqlDateTime now;
   TimeToStruct(TimeCurrent(), now);
   now.hour = 0;
   now.min  = 0;
   now.sec  = 0;
   datetime day_start = StructToTime(now);

   if(!HistorySelect(day_start, TimeCurrent()))
      return 0.0;

   double total = 0.0;
   for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
   {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0 || HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol ||
         (ulong)HistoryDealGetInteger(deal, DEAL_MAGIC) != MagicNumber)
         continue;

      ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal, DEAL_ENTRY);
      if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY)
         total += HistoryDealGetDouble(deal, DEAL_PROFIT)
                + HistoryDealGetDouble(deal, DEAL_SWAP)
                + HistoryDealGetDouble(deal, DEAL_COMMISSION);
   }
   return total;
}
//+------------------------------------------------------------------+
