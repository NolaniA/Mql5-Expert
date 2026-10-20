//+------------------------------------------------------------------+
//|                                      XAU_Indicator_Template_EA.mq5|
//|  Template EA: EMA Fast/Slow + MACD(12,26,9) + MA(12) + RSI(14)  |
//|  Entry/Exit conditions are intentionally left for the user.      |
//+------------------------------------------------------------------+
#property strict
#property version   "1.07"
#property description "Virtual swing, BE, sideway filter, capped recovery, $30 daily profit limit"

#include <Trade/Trade.mqh>
CTrade trade;

#define MACD_HISTORY 5
#define OHLCV_HISTORY 20

//====================================================================
// INPUTS
//====================================================================
input group "=== Trading ==="
input bool             EnableTrading          = false;      // Safety: enable after writing conditions
input double           LotSize                = 0.01;
input ulong            MagicNumber            = 26092301;
input bool             TradeOnNewBarOnly      = true;
input int              SignalShift            = 1;          // 1 = closed candle, 0 = current candle
input int              MaxPositionsPerSymbol  = 5;   // 1 base order + up to 4 profitable adds
input int              SlippagePoints         = 30;

input group "=== Daily Profit Target (USD account) ==="
input bool             EnableDailyProfitTarget = true;
input double           DailyProfitTargetUSD    = 30.0; // Realized TODAY + floating EA P/L
// At target: CLOSE all EA positions on this symbol and stop entries until next BROKER day.

input group "=== Virtual Swing Reference (NO initial SL) ==="
// This is ONLY a reference for the break-even trigger; no order has a stop at this swing.
input int              SwingSLBufferPoints   = 0;   // Extend virtual BUY low / SELL high by points

input group "=== Break-Even Protection ==="
input bool             EnableBreakEven           = true;   // Set a NEW SL only after profit reaches threshold
input double           BreakEvenTriggerPercent   = 50.0;   // Profit >= 50% of entry-to-virtual-swing distance
// -1 = AUTO 2x the CURRENT spread at BE trigger; 0 = entry; >0 = fixed points
input int              BreakEvenOffsetPoints     = -1;

input group "=== Sideway Filter (ADX / EMA Gap) ==="
input bool             EnableSidewayFilter       = true;     // Block NEW entries and pyramiding in sideways market
input int              SidewayADXPeriod          = 14;
input double           SidewayMinADX             = 20.0;     // ADX < 20 => sideways / weak trend
input int              SidewayMinEMAGapPoints    = 0;        // 0 = off; optional EMA separation filter

input group "=== Profit Pyramiding (Points) ==="
input bool             EnableProfitPyramiding  = true;
input int              PyramidMinProfitPoints  = 300;   // Last order must be in profit by this many points
input int              PyramidStepPoints       = 300;   // Price must have moved favorably this far from last entry
input bool             PyramidOneAddPerBar     = true;  // At most one pyramid addition per candle

// Recover only AFTER a completed flat-to-flat basket closes with net loss.
// A basket includes the initial position and all profitable pyramid additions.
// All entries in the same basket use the SAME cycle lot.
enum ENUM_CYCLE_RECOVERY_MODE
{
   RECOVERY_ADD_LOT = 0,        // BaseLot + lossSteps * RecoveryLotStep
   RECOVERY_MULTIPLY_LOT = 1    // BaseLot * MathPow(RecoveryLotFactor,lossSteps)
};

input group "=== Loss Cycle Lot Recovery ==="
input bool                     EnableLossCycleRecovery = false;  // Opt-in; test on demo first
input ENUM_CYCLE_RECOVERY_MODE RecoveryMode            = RECOVERY_ADD_LOT;
input double                   RecoveryLotStep         = 0.01;
input double                   RecoveryLotFactor       = 1.50;
input int                      RecoveryMaxLossSteps    = 2;      // Losses beyond this do not raise lot
input double                   RecoveryMaxLotMultiplier= 3.0;    // Hard cap relative to LotSize
input double                   RecoveryMaxAbsoluteLot  = 0.0;    // 0 = use relative and broker caps

input group "=== Main Chart Moving Averages ==="
input int              FastMAPeriod           = 8;
input int              SlowMAPeriod           = 12;
input ENUM_MA_METHOD   MainMAMethod           = MODE_EMA;
input ENUM_APPLIED_PRICE MainMAPrice           = PRICE_CLOSE;

input group "=== MACD Window ==="
input int              MACDFastPeriod         = 12;
input int              MACDSlowPeriod         = 26;
input int              MACDSignalPeriod       = 9;
input ENUM_APPLIED_PRICE MACDPrice             = PRICE_CLOSE;
input int              MACDMAPeriod           = 12;         // MA applied to MACD main line
input ENUM_MA_METHOD   MACDMAMethod           = MODE_SMA;
input int              RSIPeriod              = 14;         // RSI applied to MACD main line

input group "=== Display ==="
input bool             ShowIndicatorsOnChart  = false;

//====================================================================
// INDICATOR HANDLES
//====================================================================
int hFastMA  = INVALID_HANDLE;
int hSlowMA  = INVALID_HANDLE;
int hMACD    = INVALID_HANDLE;
int hADX     = INVALID_HANDLE;
int hMACDMA  = INVALID_HANDLE;
int hRSI     = INVALID_HANDLE;

int g_macd_window = -1;
datetime g_last_bar_time = 0;
datetime g_last_pyramid_bar_time = 0;
datetime g_last_sideway_log_bar = 0;

// Today's target locks by broker-server date, and survives an EA restart.
int    g_daily_date = 0;
bool   g_daily_locked = false;
bool   g_daily_realized_valid = false;
double g_daily_realized = 0.0;
datetime g_daily_history_error_bar = 0;

// Restored from executed deal history on init; updated after every close.
int      g_loss_cycle_step    = 0;
double   g_cycle_open_volume  = 0.0;
double   g_cycle_net_profit   = 0.0;
double   g_cycle_entry_lot    = 0.0;
ulong    g_last_history_deal = 0;
datetime g_last_history_time = 0;
bool     g_deal_history_dirty = true;
bool     g_is_replaying_history = false;
ulong    g_cycle_position_ids[];  // Also recognizes broker SL/manual exits when DEAL_MAGIC=0.



//====================================================================
// DATA STRUCTURE USED BY YOUR ENTRY/EXIT LOGIC
//====================================================================
struct IndicatorState
{
   datetime time;

   double open;
   double high;
   double low;
   double close;

   // OHLCV ย้อนหลัง 20 แท่ง
   // index 0 = แท่งตาม SignalShift, index 19 = แท่งเก่าสุด
   datetime ohlcv_time[OHLCV_HISTORY];
   double   ohlcv_open[OHLCV_HISTORY];
   double   ohlcv_high[OHLCV_HISTORY];
   double   ohlcv_low[OHLCV_HISTORY];
   double   ohlcv_close[OHLCV_HISTORY];
   long     ohlcv_volume[OHLCV_HISTORY];

   double fast_ma;
   double slow_ma;

   double macd_main;
   double macd_signal;
   double macd_ma;
   double rsi;

   // MACD ย้อนหลัง 5 แท่ง
   double macd_main_prev[MACD_HISTORY];
   double macd_signal_prev[MACD_HISTORY];
};

//====================================================================
// HELPER: copy one value from an indicator buffer
//====================================================================
bool CopyOne(const int handle,const int buffer,const int shift,double &value)
{
   double temp[1];
   ResetLastError();

   if(CopyBuffer(handle,buffer,shift,1,temp) != 1)
   {
      PrintFormat("CopyBuffer failed. handle=%d buffer=%d shift=%d error=%d",
                  handle,buffer,shift,GetLastError());
      return false;
   }

   value = temp[0];
   return true;
}

//====================================================================
// HELPER: read OHLC + all indicator values
//====================================================================
bool ReadIndicatorState(const int shift, IndicatorState &s)
{
   MqlRates rates[OHLCV_HISTORY];

   ResetLastError();
   if(CopyRates(_Symbol,_Period,shift,OHLCV_HISTORY,rates) != OHLCV_HISTORY)
   {
      PrintFormat("CopyRates OHLCV failed. shift=%d count=%d error=%d",
                  shift,OHLCV_HISTORY,GetLastError());
      return false;
   }

   // CopyRates จะคืนข้อมูลเรียงจากเก่า -> ใหม่ใน physical array
   // เรากลับ index ให้ [0] = แท่งล่าสุดตาม shift, [19] = แท่งเก่าสุด
   for(int i = 0; i < OHLCV_HISTORY; i++)
   {
      int src = OHLCV_HISTORY - 1 - i;

      s.ohlcv_time[i]   = rates[src].time;
      s.ohlcv_open[i]   = rates[src].open;
      s.ohlcv_high[i]   = rates[src].high;
      s.ohlcv_low[i]    = rates[src].low;
      s.ohlcv_close[i]  = rates[src].close;
      s.ohlcv_volume[i] = (long)rates[src].tick_volume;
   }

   // ค่าเดิมสำหรับ logic ที่อ้าง s.open / s.high / s.low / s.close
   s.time  = s.ohlcv_time[0];
   s.open  = s.ohlcv_open[0];
   s.high  = s.ohlcv_high[0];
   s.low   = s.ohlcv_low[0];
   s.close = s.ohlcv_close[0];

   if(!CopyOne(hFastMA,0,shift,s.fast_ma))
      return false;

   if(!CopyOne(hSlowMA,0,shift,s.slow_ma))
      return false;

   if(!CopyOne(hMACD,0,shift,s.macd_main))
      return false;

   if(!CopyOne(hMACD,1,shift,s.macd_signal))
      return false;

   if(!CopyOne(hMACDMA,0,shift,s.macd_ma))
      return false;

   if(!CopyOne(hRSI,0,shift,s.rsi))
      return false;

   //==============================================================
   // MACD HISTORY
   //==============================================================
   for(int i = 0; i < MACD_HISTORY; i++)
   {
      int history_shift = shift + i;

      if(!CopyOne(
            hMACD,
            0,
            history_shift,
            s.macd_main_prev[i]
         ))
         return false;

      if(!CopyOne(
            hMACD,
            1,
            history_shift,
            s.macd_signal_prev[i]
         ))
         return false;
   }

   return true;
}

//====================================================================
// SIDEWAY FILTER: block opening NEW positions, not existing SL/exit logic.
// ADX main line buffer 0 < SidewayMinADX indicates weak/no trend.
// Optional EMA gap filter (0 = disabled) catches converging EMAs.
// Always use the last CLOSED bar for the ADX filter (no repainting).
// If enabled and ADX data cannot be read, fail safe: block entries.
//====================================================================
bool IsSidewayMarket(const IndicatorState &s)
{
   if(!EnableSidewayFilter)
      return false;

   double adx_value = 0.0;
   int adx_shift = (SignalShift > 1 ? SignalShift : 1);
   if(hADX == INVALID_HANDLE || !CopyOne(hADX,0,adx_shift,adx_value) ||
      !MathIsValidNumber(adx_value) || adx_value == EMPTY_VALUE)
   {
      // Data not ready: safest to avoid NEW trades (existing positions still managed).
      return true;
   }

   bool weak_trend = (adx_value < SidewayMinADX);
   double ema_gap_points = MathAbs(s.fast_ma-s.slow_ma)/_Point;
   bool narrow_emas = (SidewayMinEMAGapPoints > 0 &&
                       ema_gap_points < SidewayMinEMAGapPoints);

   if(weak_trend || narrow_emas)
   {
      datetime current_bar = iTime(_Symbol,_Period,0);
      if(current_bar != g_last_sideway_log_bar)
      {
         g_last_sideway_log_bar = current_bar;
         PrintFormat("Sideway: skip NEW entries; ADX=%.2f (min=%.2f), EMA gap=%.1f points (min=%d)",
                     adx_value,SidewayMinADX,ema_gap_points,SidewayMinEMAGapPoints);
      }
      return true;
   }
   return false;
}

//====================================================================
// ENTRY PATTERNS + THEIR SWING ANCHORS
// Index 0 is the signal candle (SignalShift), older candles follow.
// BUY  = 1-3 strong green candles preceded by one strong red candle.
// SELL = 1-3 strong red candles preceded by one strong green candle.
// The anchor INCLUDES every candle in the matching pattern (1-3 + 1).
// Using the same matchers for signal and SL avoids mismatched anchors.
//====================================================================
bool FindBuySignalSwing(const IndicatorState &s,double &swing_low)
{
   for(int greenCount = 1; greenCount <= 3; greenCount++)
   {
      double totalGreenBody = 0.0;
      bool validGreen = true;

      for(int i = 0; i < greenCount; i++)
      {
         double open  = s.ohlcv_open[i];
         double close = s.ohlcv_close[i];
         double high  = s.ohlcv_high[i];
         double low   = s.ohlcv_low[i];

         double body      = MathAbs(close - open);
         double upperWick = MathAbs(high - close);
         double lowerWick = MathAbs(open - low);

         if(close <= open || body <= upperWick || body <= lowerWick)
         {
            validGreen = false;
            break;
         }
         totalGreenBody += body;
      }

      if(!validGreen)
         continue;

      int redIndex = greenCount;
      double redOpen  = s.ohlcv_open[redIndex];
      double redClose = s.ohlcv_close[redIndex];
      double redHigh  = s.ohlcv_high[redIndex];
      double redLow   = s.ohlcv_low[redIndex];
      double redBody      = MathAbs(redClose - redOpen);
      double redUpperWick = MathAbs(redHigh - redOpen);
      double redLowerWick = MathAbs(redClose - redLow);

      if(redClose >= redOpen 
      || redBody <= redUpperWick ||
         redBody <= redLowerWick
         )
         continue;

      if(totalGreenBody > redBody)
      {
         // Low of prior red candle AND all matched green candles.
         swing_low = s.ohlcv_low[redIndex];
         for(int i = 0; i < greenCount; i++)
            swing_low = MathMin(swing_low,s.ohlcv_low[i]);
         return true;
      }
   }
   return false;
}

bool FindSellSignalSwing(const IndicatorState &s,double &swing_high)
{
   for(int redCount = 1; redCount <= 3; redCount++)
   {
      double totalRedBody = 0.0;
      bool validRed = true;

      for(int i = 0; i < redCount; i++)
      {
         double open  = s.ohlcv_open[i];
         double close = s.ohlcv_close[i];
         double high  = s.ohlcv_high[i];
         double low   = s.ohlcv_low[i];

         double body      = MathAbs(close - open);
         double upperWick = MathAbs(high - open);
         double lowerWick = MathAbs(close - low);

         if(close >= open || body <= upperWick || body <= lowerWick)
         {
            validRed = false;
            break;
         }
         totalRedBody += body;
      }

      if(!validRed)
         continue;

      int greenIndex = redCount;
      double greenOpen  = s.ohlcv_open[greenIndex];
      double greenClose = s.ohlcv_close[greenIndex];
      double greenHigh  = s.ohlcv_high[greenIndex];
      double greenLow   = s.ohlcv_low[greenIndex];
      double greenBody      = MathAbs(greenClose - greenOpen);
      double greenUpperWick = MathAbs(greenHigh - greenClose);
      double greenLowerWick = MathAbs(greenOpen - greenLow);

      if(greenClose <= greenOpen || greenBody <= greenUpperWick ||
         greenBody <= greenLowerWick)
         continue;

      if(totalRedBody > greenBody)
      {
         // High of prior green candle AND all matched red candles.
         swing_high = s.ohlcv_high[greenIndex];
         for(int i = 0; i < redCount; i++)
            swing_high = MathMax(swing_high,s.ohlcv_high[i]);
         return true;
      }
   }
   return false;
}

bool BuyCondition(const IndicatorState &s)
{
   double swing_low = 0.0;
   return FindBuySignalSwing(s,swing_low);
}

bool SellCondition(const IndicatorState &s)
{
   double swing_high = 0.0;
   return FindSellSignalSwing(s,swing_high);
}

bool CloseBuyCondition(const IndicatorState &s)
{
   return SellCondition(s);
}

bool CloseSellCondition(const IndicatorState &s)
{
   return BuyCondition(s);
}

//====================================================================
// POSITION HELPERS
//====================================================================
int CountMyPositions()
{
   int count = 0;

   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;

      count++;
   }

   return count;
}

void ClosePositionsByType(const ENUM_POSITION_TYPE type_to_close)
{
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;

      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if(type != type_to_close)
         continue;

      if(!trade.PositionClose(ticket))
      {
         PrintFormat("Close failed. ticket=%I64u retcode=%u %s",
                     ticket,trade.ResultRetcode(),trade.ResultRetcodeDescription());
      }
   }
}

//====================================================================
// LOSS-CYCLE LOT RECOVERY
// Tracks realized Profit+Swap+Commission+Fee for the full EA basket.
// A cycle begins when EA exposure grows from zero and ends at zero.
// Deals are replayed in history order to retain the loss-step after restart.
// IMPORTANT: Use a dedicated MagicNumber for this strategy. Past historical
// trades of the same symbol+magic contribute to the reconstructed steps.
//====================================================================
void FinishRecoveryCycle()
{
   if(g_cycle_open_volume > 1e-7)
      return;

   double final_profit = g_cycle_net_profit;
   if(final_profit < -0.0000001)
      g_loss_cycle_step = MathMin(g_loss_cycle_step+1,RecoveryMaxLossSteps);
   else
      g_loss_cycle_step = 0;

   if(!g_is_replaying_history && EnableLossCycleRecovery)
      PrintFormat("Recovery CYCLE CLOSED: net=%.2f, nextLossStep=%d",
                  final_profit,g_loss_cycle_step);
   ArrayResize(g_cycle_position_ids,0);
   g_cycle_open_volume=0.0;
   g_cycle_net_profit=0.0;
   g_cycle_entry_lot=0.0;
}

// Call at init, on new closing deals and immediately after synchronous close.
// Small overlap at the last second is harmless: old deal tickets are skipped.
void RefreshRecoveryHistory(const bool force=false)
{
   if(!force && !g_deal_history_dirty)
      return;

   datetime from_time = g_last_history_time;
   if(!HistorySelect(from_time,TimeCurrent()+1))
   {
      PrintFormat("Recovery history select failed, error=%d",GetLastError());
      return;
   }

   int total = HistoryDealsTotal();
   for(int i=0;i<total;i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket==0 || ticket<=g_last_history_deal)
         continue;

      datetime deal_time = (datetime)HistoryDealGetInteger(ticket,DEAL_TIME);
      if(deal_time>g_last_history_time)
         g_last_history_time=deal_time;
      g_last_history_deal=ticket;

      if(HistoryDealGetString(ticket,DEAL_SYMBOL)!=_Symbol)
         continue;
      ENUM_DEAL_TYPE deal_type=(ENUM_DEAL_TYPE)HistoryDealGetInteger(ticket,DEAL_TYPE);
      if(deal_type!=DEAL_TYPE_BUY && deal_type!=DEAL_TYPE_SELL)
         continue;

      ENUM_DEAL_ENTRY entry=(ENUM_DEAL_ENTRY)HistoryDealGetInteger(ticket,DEAL_ENTRY);
      ulong position_id=(ulong)HistoryDealGetInteger(ticket,DEAL_POSITION_ID);
      bool own_magic=((ulong)HistoryDealGetInteger(ticket,DEAL_MAGIC)==MagicNumber);
      bool tracked_id=false;
      for(int p=0;p<ArraySize(g_cycle_position_ids);p++)
         if(g_cycle_position_ids[p]==position_id && position_id>0)
         {
            tracked_id=true;
            break;
         }
      if(!own_magic && !tracked_id)
         continue;

      double volume=HistoryDealGetDouble(ticket,DEAL_VOLUME);
      double net = HistoryDealGetDouble(ticket,DEAL_PROFIT)
                 + HistoryDealGetDouble(ticket,DEAL_SWAP)
                 + HistoryDealGetDouble(ticket,DEAL_COMMISSION)
                 + HistoryDealGetDouble(ticket,DEAL_FEE);

      if(entry==DEAL_ENTRY_IN && own_magic)
      {
         if(g_cycle_open_volume<=1e-7)
         {
            g_cycle_open_volume=0.0;
            g_cycle_net_profit=0.0;
            g_cycle_entry_lot=volume;
            ArrayResize(g_cycle_position_ids,0);
            tracked_id=false;
         }
         if(position_id>0 && !tracked_id)
         {
            int n=ArraySize(g_cycle_position_ids);
            ArrayResize(g_cycle_position_ids,n+1,16);
            g_cycle_position_ids[n]=position_id;
         }
         g_cycle_open_volume+=volume;
         g_cycle_net_profit+=net;
      }
      else if(entry==DEAL_ENTRY_OUT || entry==DEAL_ENTRY_OUT_BY)
      {
         if(g_cycle_open_volume<=1e-7)
            continue;  // Opening deal missing from broker's available history.
         g_cycle_net_profit+=net;
         g_cycle_open_volume=MathMax(0.0,g_cycle_open_volume-volume);
         if(g_cycle_open_volume<=1e-7)
            FinishRecoveryCycle();
      }
      else if(entry==DEAL_ENTRY_INOUT)
      {
         // This EA closes positions first; netting reversal is not supported
         // as a lot-recovery cycle boundary.
         g_cycle_net_profit+=net;
         if(g_cycle_open_volume<=1e-7)
         {
            g_cycle_open_volume=volume;
            g_cycle_entry_lot=volume;
         }
      }
   }
   g_deal_history_dirty=false;
}

// Broker volume restrictions and user cap apply to ALL recovery levels.
double NormalizeRecoveryVolume(double requested)
{
   double min_volume=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double max_volume=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   if(min_volume<=0 || max_volume<=0 || step<=0)
      return 0.0;

   double hard_max=LotSize*RecoveryMaxLotMultiplier;
   if(RecoveryMaxAbsoluteLot>0.0)
      hard_max=MathMin(hard_max,RecoveryMaxAbsoluteLot);
   hard_max=MathMin(hard_max,max_volume);

   if(hard_max+1e-9<min_volume)
      return 0.0;
   // Round downward so step normalization never exceeds the safety cap.
   requested=MathMin(requested,hard_max);
   if(requested+1e-9<min_volume)
      return 0.0;
   double steps=MathFloor((requested-min_volume)/step+1e-8);
   double result=min_volume+steps*step;
   return NormalizeDouble(result,8);
}

double RecoveryLotForNextCycle()
{
   double requested=LotSize;
   if(EnableLossCycleRecovery && g_loss_cycle_step>0)
   {
      if(RecoveryMode==RECOVERY_ADD_LOT)
         requested=LotSize + g_loss_cycle_step*RecoveryLotStep;
      else
         requested=LotSize*MathPow(RecoveryLotFactor,g_loss_cycle_step);
   }
   return NormalizeRecoveryVolume(requested);
}

double RecoveryLotForOrder()
{
   // While positions are open use original basket lot, even if some
   // winning/losing positions have been individually closed.
   if(g_cycle_open_volume>1e-7 && g_cycle_entry_lot>0.0)
      return NormalizeRecoveryVolume(g_cycle_entry_lot);

   return RecoveryLotForNextCycle();
}

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type==TRADE_TRANSACTION_DEAL_ADD)
   {
      g_deal_history_dirty=true;
      // Commissions and realized profits can change on any new deal.
      g_daily_realized_valid=false;
   }
}

//====================================================================
// DAILY PROFIT TARGET
//  * Account currency must be USD; this is an explicit US-dollar target.
//  * Day boundaries are broker-server midnight, not PC local time.
//  * Include today's EA realized deal profit/swap/commission/fees and
//    current EA position profit + swap (floating).
//  * At the threshold, immediately latch the day and CLOSE all EA positions.
//  * A terminal global variable persists the daily lock across EA restarts.
//  * Only this _Symbol and MagicNumber are included.
//====================================================================
int BrokerDateKey(const datetime now,datetime &day_start)
{
   MqlDateTime parts;
   TimeToStruct(now,parts);
   int key=parts.year*10000+parts.mon*100+parts.day;
   parts.hour=0;
   parts.min=0;
   parts.sec=0;
   day_start=StructToTime(parts);
   return key;
}

string DailyProfitLockKey(const int date_key)
{
   return StringFormat("DPT_%I64d_%s_%I64u_%d",
                       AccountInfoInteger(ACCOUNT_LOGIN),_Symbol,MagicNumber,date_key);
}

// Read today's realized P/L only when a deal has changed or the day rolls over.
// Some manual / broker close deals may have DEAL_MAGIC=0. For those, follow
// the position identifier back to its opening deal before attributing P/L.
bool GetTodayRealizedProfit(const datetime day_start,double &realized)
{
   if(g_daily_realized_valid)
   {
      realized=g_daily_realized;
      return true;
   }

   if(!HistorySelect(day_start,TimeCurrent()+60))
      return false;

   double result=0.0;
   ulong untagged_position_ids[];
   double untagged_nets[];
   int untagged_count=0;

   int total=HistoryDealsTotal();
   for(int i=0;i<total;i++)
   {
      ulong deal=HistoryDealGetTicket(i);
      if(deal==0 || HistoryDealGetString(deal,DEAL_SYMBOL)!=_Symbol)
         continue;

      ENUM_DEAL_TYPE type=(ENUM_DEAL_TYPE)HistoryDealGetInteger(deal,DEAL_TYPE);
      if(type!=DEAL_TYPE_BUY && type!=DEAL_TYPE_SELL)
         continue;

      double net=HistoryDealGetDouble(deal,DEAL_PROFIT)
                +HistoryDealGetDouble(deal,DEAL_SWAP)
                +HistoryDealGetDouble(deal,DEAL_COMMISSION)
                +HistoryDealGetDouble(deal,DEAL_FEE);
      ulong deal_magic=(ulong)HistoryDealGetInteger(deal,DEAL_MAGIC);
      if(deal_magic==MagicNumber)
      {
         result+=net;
         continue;
      }

      // Fall back only for closing deals without a magic number.
      if(deal_magic!=0)
         continue;
      ENUM_DEAL_ENTRY entry=(ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal,DEAL_ENTRY);
      if(entry!=DEAL_ENTRY_OUT && entry!=DEAL_ENTRY_OUT_BY && entry!=DEAL_ENTRY_INOUT)
         continue;
      ulong position_id=(ulong)HistoryDealGetInteger(deal,DEAL_POSITION_ID);
      if(position_id==0)
         continue;

      ArrayResize(untagged_position_ids,untagged_count+1);
      ArrayResize(untagged_nets,untagged_count+1);
      untagged_position_ids[untagged_count]=position_id;
      untagged_nets[untagged_count]=net;
      untagged_count++;
   }

   // IMPORTANT: HistorySelectByPosition changes the history selection. This
   // runs AFTER collecting all today's deals so the day window is not lost.
   for(int i=0;i<untagged_count;i++)
   {
      ulong position_id=untagged_position_ids[i];
      if(!HistorySelectByPosition(position_id))
         return false; // Can't attribute the exit reliably; don't allow entries.

      bool our_position=false;
      int position_deals=HistoryDealsTotal();
      for(int j=0;j<position_deals;j++)
      {
         ulong deal=HistoryDealGetTicket(j);
         if(deal==0 || HistoryDealGetString(deal,DEAL_SYMBOL)!=_Symbol)
            continue;
         if((ulong)HistoryDealGetInteger(deal,DEAL_MAGIC)!=MagicNumber)
            continue;
         ENUM_DEAL_ENTRY entry=(ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal,DEAL_ENTRY);
         if(entry==DEAL_ENTRY_IN || entry==DEAL_ENTRY_INOUT)
         {
            our_position=true;
            break;
         }
      }
      if(our_position)
         result+=untagged_nets[i];
   }

   realized=result;
   g_daily_realized=result;
   g_daily_realized_valid=true;
   return true;
}

double MyFloatingProfit()
{
   double result=0.0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol ||
         (ulong)PositionGetInteger(POSITION_MAGIC)!=MagicNumber)
         continue;
      result+=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
   }
   return result;
}

void CloseMyPositionsForDailyProfit()
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol ||
         (ulong)PositionGetInteger(POSITION_MAGIC)!=MagicNumber)
         continue;

      ResetLastError();
      bool sent=trade.PositionClose(ticket);
      uint retcode=trade.ResultRetcode();
      if(!sent || (retcode!=TRADE_RETCODE_DONE &&
                   retcode!=TRADE_RETCODE_DONE_PARTIAL))
         PrintFormat("Daily target: CLOSE failed ticket=%I64u code=%u (%s) err=%d",
                     ticket,retcode,trade.ResultRetcodeDescription(),GetLastError());
   }
   // A synchronous close may have been filled even before OnTradeTransaction.
   g_daily_realized_valid=false;
}

// Returns true when opening NEW trades must be blocked for this broker day.
// This is called BEFORE the new-bar gate so the target works on EVERY TICK.
bool HandleDailyProfitTarget()
{
   if(!EnableDailyProfitTarget)
      return false;

   datetime day_start=0;
   int current_day=BrokerDateKey(TimeCurrent(),day_start);
   if(current_day!=g_daily_date)
   {
      g_daily_date=current_day;
      g_daily_realized_valid=false;
      g_daily_locked=GlobalVariableCheck(DailyProfitLockKey(current_day));
      PrintFormat("Daily profit: new broker day %d, limit=%.2f USD, locked=%s",
                  current_day,DailyProfitTargetUSD,g_daily_locked?"true":"false");
   }

   if(g_daily_locked)
   {
      // A prior close could fail or only partially fill. Retry until flat.
      CloseMyPositionsForDailyProfit();
      return true;
   }

   double realized=0.0;
   if(!GetTodayRealizedProfit(day_start,realized))
   {
      datetime bar=iTime(_Symbol,_Period,0);
      if(bar!=g_daily_history_error_bar)
      {
         g_daily_history_error_bar=bar;
         PrintFormat("Daily target: history unavailable error=%d; block NEW trades until it recovers.",
                     GetLastError());
      }
      return true;
   }

   double floating=MyFloatingProfit();
   double total=realized+floating;
   if(total+1e-7<DailyProfitTargetUSD)
      return false;

   g_daily_locked=true;
   string lock_key=DailyProfitLockKey(current_day);
   ResetLastError();
   if(GlobalVariableSet(lock_key,1.0)==0)
      PrintFormat("WARNING: daily target lock not persisted (err=%d)",GetLastError());
   else
      GlobalVariablesFlush();

   PrintFormat("DAILY TARGET HIT: day=%d realized=%.2f floating=%.2f total=%.2f target=%.2f USD. Close ALL EA positions and stop new trades.",
               current_day,realized,floating,total,DailyProfitTargetUSD);
   CloseMyPositionsForDailyProfit();
   return true;
}

//====================================================================
// PROFIT-ONLY PYRAMIDING
// Add only if the existing EA positions all match the current signal,
// the whole side is profitable, and the MOST RECENT position is profitable
// by the required number of points. New entry must also be at least the
// configured spacing away from the most recent position's entry price.
// Only independent positions (hedging accounts) can be counted this way.
//====================================================================
bool CanAddProfitPosition(const ENUM_POSITION_TYPE side)
{
   if(!EnableProfitPyramiding || MaxPositionsPerSymbol <= 1)
      return false;

   if((ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE)
         != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
      return false;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick) || tick.bid <= 0.0 || tick.ask <= 0.0)
      return false;

   datetime bar_time = iTime(_Symbol,_Period,0);
   if(PyramidOneAddPerBar &&
      (bar_time == 0 || g_last_pyramid_bar_time == bar_time))
      return false;

   int count = 0;
   double basket_profit = 0.0;
   long latest_time_msc = -1;
   ulong latest_ticket = 0;
   double latest_open_price = 0.0;
   double latest_profit = 0.0;
   datetime latest_time = 0;

   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;

      // Never add while the EA has a position on the opposite side.
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != side)
         return false;

      count++;
      double position_profit = PositionGetDouble(POSITION_PROFIT) +
                               PositionGetDouble(POSITION_SWAP);
      basket_profit += position_profit;

      long opened_msc = PositionGetInteger(POSITION_TIME_MSC);
      if(opened_msc > latest_time_msc ||
         (opened_msc == latest_time_msc && ticket > latest_ticket))
      {
         latest_time_msc   = opened_msc;
         latest_ticket     = ticket;
         latest_open_price = PositionGetDouble(POSITION_PRICE_OPEN);
         latest_profit     = position_profit;
         latest_time       = (datetime)PositionGetInteger(POSITION_TIME);
      }
   }

   if(count == 0 || count >= MaxPositionsPerSymbol)
      return false;

   // Both the entire side and the newest order must show floating profit.
   if(basket_profit <= 0.0 || latest_profit <= 0.0)
      return false;

   // Prevent adding another order within the candle of the newest entry
   // even if the EA was restarted during that candle.
   if(PyramidOneAddPerBar && latest_time >= bar_time)
      return false;

   double favorable_points = 0.0;
   if(side == POSITION_TYPE_BUY)
      favorable_points = (tick.bid - latest_open_price) / _Point;
   else if(side == POSITION_TYPE_SELL)
      favorable_points = (latest_open_price - tick.ask) / _Point;
   else
      return false;

   if(favorable_points + 1e-6 < PyramidMinProfitPoints)
      return false;
   if(favorable_points + 1e-6 < PyramidStepPoints)
      return false;

   return true;
}

//====================================================================
// VIRTUAL SWING REFERENCE (NOT an order SL).
// The virtual swing is calculated from the entry's OWN candle pattern.
// BUY -> low of pattern minus buffer; SELL -> high plus buffer.
// It is used ONLY to determine the trigger distance for break-even.
//====================================================================
bool CalculateVirtualSwing(const ENUM_POSITION_TYPE side,
                           const IndicatorState &s,double &virtual_swing)
{
   virtual_swing=0.0;
   double swing_price=0.0;
   if(side==POSITION_TYPE_BUY)
   {
      if(!FindBuySignalSwing(s,swing_price))
         return false;
      virtual_swing=swing_price-SwingSLBufferPoints*_Point;
   }
   else if(side==POSITION_TYPE_SELL)
   {
      if(!FindSellSignalSwing(s,swing_price))
         return false;
      virtual_swing=swing_price+SwingSLBufferPoints*_Point;
   }
   else
      return false;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick) || tick.bid<=0.0 || tick.ask<=0.0)
      return false;

   double tick_size=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   if(tick_size<=0.0) tick_size=_Point;
   // Snap the virtual reference OUTSIDE the swing, but do not submit an SL.
   if(side==POSITION_TYPE_BUY)
      virtual_swing=MathFloor(virtual_swing/tick_size+1e-9)*tick_size;
   else
      virtual_swing=MathCeil(virtual_swing/tick_size-1e-9)*tick_size;
   virtual_swing=NormalizeDouble(virtual_swing,_Digits);

   double entry_quote=(side==POSITION_TYPE_BUY ? tick.ask : tick.bid);
   double risk=(side==POSITION_TYPE_BUY ? entry_quote-virtual_swing
                                          : virtual_swing-entry_quote);
   if(virtual_swing<=0.0 || risk<tick_size*0.5)
   {
      PrintFormat("Invalid virtual swing: side=%s entryQuote=%s swing=%s. Entry skipped.",
                  side==POSITION_TYPE_BUY?"BUY":"SELL",
                  DoubleToString(entry_quote,_Digits),
                  DoubleToString(virtual_swing,_Digits));
      return false;
   }
   return true;
}

// POSITION_IDENTIFIER does not change when a broker re-tickets a position.
// It links each position to its unique original virtual swing even across restarts.
string VirtualSwingKey(const ulong position_id)
{
   return StringFormat("VSW1_%I64d_%I64u_%I64u",
                       AccountInfoInteger(ACCOUNT_LOGIN),MagicNumber,position_id);
}

bool SaveVirtualSwing(const ulong position_id,const double virtual_swing)
{
   if(position_id==0 || virtual_swing<=0.0)
      return false;
   string key=VirtualSwingKey(position_id);
   ResetLastError();
   if(GlobalVariableSet(key,virtual_swing)==0)
   {
      PrintFormat("Cannot save virtual swing for position=%I64u err=%d",
                  position_id,GetLastError());
      return false;
   }
   GlobalVariablesFlush();
   return true;
}

// Global variables persist in THIS MT5 terminal. The position's comment is a
// secondary fallback for a restart/lost variable (some brokers change comments).
// For older positions opened with a real SL, keep the existing protective SL
// and use its adverse-side price as a last-resort reference.
bool LoadVirtualSwing(const ulong position_id,const double entry,
                      const double old_sl,const bool is_buy,
                      const string comment,double &virtual_swing)
{
   string key=VirtualSwingKey(position_id);
   if(GlobalVariableGet(key,virtual_swing) && virtual_swing>0.0)
      return true;

   int pos=StringFind(comment,"|VS=");
   if(pos>=0)
   {
      virtual_swing=StringToDouble(StringSubstr(comment,pos+4));
      if(virtual_swing>0.0)
      {
         SaveVirtualSwing(position_id,virtual_swing);
         return true;
      }
   }

   if(old_sl>0.0 &&
      ((is_buy && old_sl<entry) || (!is_buy && old_sl>entry)))
   {
      virtual_swing=old_sl; // Legacy v1.05 position with original real SL
      return true;
   }
   return false;
}

//====================================================================
// BREAK-EVEN PROTECTION - evaluated on EVERY TICK.
// No SL is placed at entry. The FIRST real SL is set ONLY after the price
// moves favorably >= threshold% * distance(entry, virtual swing).
// Default BE offset = 2x current spread, not 2x the original spread.
// BUY checks Bid, SELL checks Ask (the executable close-side price).
//====================================================================
void ManageBreakEvenPositions()
{
   if(!EnableBreakEven)
      return;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick) || tick.bid<=0.0 || tick.ask<=0.0)
      return;

   double tick_size=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   if(tick_size<=0.0) tick_size=_Point;

   int stops_level=(int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   int freeze_level=(int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_FREEZE_LEVEL);
   double min_gap=(MathMax(stops_level,freeze_level)+1)*_Point;
   double epsilon=MathMax(tick_size,_Point)*0.1;

   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol ||
         (ulong)PositionGetInteger(POSITION_MAGIC)!=MagicNumber)
         continue;

      ENUM_POSITION_TYPE side=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if(side!=POSITION_TYPE_BUY && side!=POSITION_TYPE_SELL)
         continue;

      bool is_buy=(side==POSITION_TYPE_BUY);
      double entry=PositionGetDouble(POSITION_PRICE_OPEN);
      double old_sl=PositionGetDouble(POSITION_SL);
      double tp=PositionGetDouble(POSITION_TP);
      if(entry<=0.0) continue;

      // A stop at or beyond entry already protects this position; BE is one-time.
      if(old_sl>0.0 &&
         ((is_buy && old_sl>=entry-epsilon) ||
          (!is_buy && old_sl<=entry+epsilon)))
         continue;

      ulong position_id=(ulong)PositionGetInteger(POSITION_IDENTIFIER);
      double virtual_swing=0.0;
      if(!LoadVirtualSwing(position_id,entry,old_sl,is_buy,
                           PositionGetString(POSITION_COMMENT),virtual_swing))
         continue; // Do not invent a different swing for a pre-existing position.

      double risk_distance=is_buy ? entry-virtual_swing : virtual_swing-entry;
      if(risk_distance<=epsilon)
         continue;

      double favorable_distance=is_buy ? tick.bid-entry : entry-tick.ask;
      if(favorable_distance<=0.0)
         continue;

      double position_profit=PositionGetDouble(POSITION_PROFIT)
                            +PositionGetDouble(POSITION_SWAP);
      if(position_profit<=0.0)
         continue;
      double trigger_distance=risk_distance*BreakEvenTriggerPercent/100.0;
      if(favorable_distance+epsilon<trigger_distance)
         continue;

      double live_spread=MathMax(0.0,tick.ask-tick.bid);
      double offset_price=(BreakEvenOffsetPoints==-1)
                          ? 2.0*live_spread
                          : (double)BreakEvenOffsetPoints*_Point;
      double raw_sl=entry+(is_buy?1.0:-1.0)*offset_price;
      double desired_sl=is_buy
                        ? MathCeil(raw_sl/tick_size-1e-9)*tick_size
                        : MathFloor(raw_sl/tick_size+1e-9)*tick_size;
      desired_sl=NormalizeDouble(desired_sl,_Digits);

      // Do not loosen an SL, and only modify when the broker's gap allows it.
      if(is_buy)
      {
         if((old_sl>0.0 && desired_sl<=old_sl+epsilon) ||
             tick.bid-desired_sl<min_gap)
            continue;
      }
      else
      {
         if((old_sl>0.0 && desired_sl>=old_sl-epsilon) ||
             desired_sl-tick.ask<min_gap)
            continue;
      }

      ResetLastError();
      bool sent=trade.PositionModify(ticket,desired_sl,tp);
      uint retcode=trade.ResultRetcode();
      if(!sent || retcode!=TRADE_RETCODE_DONE)
      {
         PrintFormat("VirtualSwing BE failed: ticket=%I64u desiredSL=%s retcode=%u (%s) error=%d",
                     ticket,DoubleToString(desired_sl,_Digits),retcode,
                     trade.ResultRetcodeDescription(),GetLastError());
         continue;
      }

      PrintFormat("VirtualSwing BE set: ticket=%I64u side=%s entry=%s virtualSwing=%s distance=%.1fpts trigger=%.1f%% SL=%s spread=%.1fpts offset=%.1fpts",
                  ticket,is_buy?"BUY":"SELL",DoubleToString(entry,_Digits),
                  DoubleToString(virtual_swing,_Digits),risk_distance/_Point,
                  BreakEvenTriggerPercent,DoubleToString(desired_sl,_Digits),
                  live_spread/_Point,offset_price/_Point);
   }
}

//====================================================================
// OPEN with SL=0, TP=0. Attach the virtual swing to the actual position ID
// AFTER the trade fills; entry fill may differ from quoted market price.
//====================================================================
bool OpenMyPosition(const ENUM_POSITION_TYPE side,const string order_comment,
                    const IndicatorState &s)
{
   double virtual_swing=0.0;
   if(!CalculateVirtualSwing(side,s,virtual_swing))
      return false;

   RefreshRecoveryHistory(true);
   double order_lot=RecoveryLotForOrder();
   if(order_lot<=0.0)
   {
      Print("Recovery lot invalid for broker or configured cap. Entry skipped.");
      return false;
   }

   MqlTick current_tick;
   if(!SymbolInfoTick(_Symbol,current_tick))
      return false;
   ENUM_ORDER_TYPE order_type=(side==POSITION_TYPE_BUY ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   double margin_needed=0.0;
   double market_price=(side==POSITION_TYPE_BUY ? current_tick.ask : current_tick.bid);
   if(!OrderCalcMargin(order_type,_Symbol,order_lot,market_price,margin_needed) ||
      margin_needed>AccountInfoDouble(ACCOUNT_MARGIN_FREE))
   {
      PrintFormat("Insufficient margin for recovery lot %.3f; estimated margin %.2f",
                  order_lot,margin_needed);
      return false;
   }

   // Secondary persistence if the local terminal global variable is lost.
   string stored_comment=order_comment+"|VS="+DoubleToString(virtual_swing,_Digits);
   bool sent=false;
   if(side==POSITION_TYPE_BUY)
      sent=trade.Buy(order_lot,_Symbol,0.0,0.0,0.0,stored_comment);
   else if(side==POSITION_TYPE_SELL)
      sent=trade.Sell(order_lot,_Symbol,0.0,0.0,0.0,stored_comment);
   else
      return false;

   uint retcode=trade.ResultRetcode();
   bool filled=(retcode==TRADE_RETCODE_DONE || retcode==TRADE_RETCODE_DONE_PARTIAL);
   if(!sent || !filled)
   {
      PrintFormat("%s failed: retcode=%u (%s)",order_comment,
                  retcode,trade.ResultRetcodeDescription());
      return false;
   }

   ulong deal_ticket=trade.ResultDeal();
   ulong order_ticket=trade.ResultOrder();
   ulong position_id=0;
   if(deal_ticket>0 && HistoryDealSelect(deal_ticket))
      position_id=(ulong)HistoryDealGetInteger(deal_ticket,DEAL_POSITION_ID);
   if(position_id==0 && order_ticket>0)
   {
      // A normal newly opened position has IDENTIFIER == opening order ticket.
      for(int i=PositionsTotal()-1;i>=0;i--)
      {
         ulong pt=PositionGetTicket(i);
         if(pt==0 || !PositionSelectByTicket(pt)) continue;
         if(PositionGetString(POSITION_SYMBOL)!=_Symbol ||
            (ulong)PositionGetInteger(POSITION_MAGIC)!=MagicNumber) continue;
         if((ulong)PositionGetInteger(POSITION_IDENTIFIER)==order_ticket)
         {
            position_id=order_ticket;
            break;
         }
      }
   }

   bool saved=(position_id>0 && SaveVirtualSwing(position_id,virtual_swing));
   if(!saved)
      PrintFormat("WARNING: Virtual swing not saved to terminal global variable for deal=%I64u. Fallback to position comment; verify BE on demo!",
                  deal_ticket);

   PrintFormat("%s executed WITHOUT INITIAL SL. deal=%I64u lot=%.3f virtualSwing=%s positionId=%I64u BE=%.1f%% of swing distance",
               order_comment,deal_ticket,order_lot,
               DoubleToString(virtual_swing,_Digits),position_id,
               BreakEvenTriggerPercent);
   return true;
}

//====================================================================
// NEW BAR CHECK
//====================================================================
bool IsNewBar()
{
   datetime current_bar_time = iTime(_Symbol,_Period,0);
   if(current_bar_time == 0)
      return false;

   if(current_bar_time != g_last_bar_time)
   {
      g_last_bar_time = current_bar_time;
      return true;
   }

   return false;
}

//====================================================================
// ADD INDICATORS TO CHART
//====================================================================
bool AddIndicatorsToChart()
{
   if(!ShowIndicatorsOnChart)
      return true;

   // Main price window
   if(!ChartIndicatorAdd(0,0,hFastMA))
      PrintFormat("Cannot add Fast MA to chart. Error=%d",GetLastError());

   if(!ChartIndicatorAdd(0,0,hSlowMA))
      PrintFormat("Cannot add Slow MA to chart. Error=%d",GetLastError());

   // Create a new subwindow for MACD.
   int windows_total = (int)ChartGetInteger(0,CHART_WINDOWS_TOTAL);
   g_macd_window = windows_total;

   if(!ChartIndicatorAdd(0,g_macd_window,hMACD))
   {
      PrintFormat("Cannot add MACD to chart. Error=%d",GetLastError());
      return false;
   }

   // Add MA-on-MACD and RSI-on-MACD into the same subwindow.
   if(!ChartIndicatorAdd(0,g_macd_window,hMACDMA))
      PrintFormat("Cannot add MACD MA to chart. Error=%d",GetLastError());

   if(!ChartIndicatorAdd(0,g_macd_window,hRSI))
      PrintFormat("Cannot add RSI to chart. Error=%d",GetLastError());

   ChartRedraw(0);
   return true;
}

//====================================================================
// INITIALIZATION
//====================================================================
int OnInit()
{
   if(FastMAPeriod <= 0 || SlowMAPeriod <= 0 ||
      MACDFastPeriod <= 0 || MACDSlowPeriod <= 0 || MACDSignalPeriod <= 0 ||
      MACDMAPeriod <= 0 || RSIPeriod <= 0)
   {
      Print("Invalid indicator period.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(EnableDailyProfitTarget && DailyProfitTargetUSD<=0.0)
   {
      Print("DailyProfitTargetUSD must be > 0 when the daily limit is enabled.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(EnableDailyProfitTarget && AccountInfoString(ACCOUNT_CURRENCY)!="USD")
   {
      PrintFormat("Daily profit target is USD 30-style. Account currency is %s, not USD. Disable the limit or use a USD account.",
                  AccountInfoString(ACCOUNT_CURRENCY));
      return INIT_PARAMETERS_INCORRECT;
   }

   if(SignalShift < 0)
   {
      Print("SignalShift must be >= 0");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(SwingSLBufferPoints < 0)
   {
      Print("SwingSLBufferPoints must be >= 0.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(MaxPositionsPerSymbol < 1 || LotSize <= 0.0)
   {
      Print("MaxPositionsPerSymbol must be >= 1 and LotSize must be > 0.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(RecoveryMaxLossSteps<0 || RecoveryLotStep<0.0 ||
      RecoveryLotFactor<1.0 || RecoveryMaxLotMultiplier<1.0 ||
      (RecoveryMaxAbsoluteLot>0.0 && RecoveryMaxAbsoluteLot<LotSize))
   {
      Print("Invalid recovery controls: steps >=0, factor >=1, cap >=base.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(EnableBreakEven &&
       (BreakEvenTriggerPercent <= 0.0 || BreakEvenOffsetPoints < -1))
   {
      Print("BreakEvenTriggerPercent must be > 0 and BreakEvenOffsetPoints >= -1 (-1 = AUTO 2x spread).");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(EnableSidewayFilter &&
      (SidewayADXPeriod < 2 || SidewayMinADX < 0.0 || SidewayMinADX > 100.0 ||
       SidewayMinEMAGapPoints < 0))
   {
      Print("Invalid sideway settings: ADXPeriod >= 2, MinADX 0..100, MinEMAGapPoints >= 0.");
      return INIT_PARAMETERS_INCORRECT;
   }

   Print("WARNING: Virtual Swing mode is active. All NEW positions open with SL=0. The swing is only a BE reference; losses before BE are NOT capped by a stop order.");
   if(EnableLossCycleRecovery)
      Print("WARNING: Lot recovery while positions have no initial SL increases drawdown/liquidation risk.");

   // Rebuild the step from closed baskets in deal history at EA startup.
   g_is_replaying_history=true;
   RefreshRecoveryHistory(true);
   g_is_replaying_history=false;
   PrintFormat("Recovery startup: enabled=%s lossStep=%d cycleOpenVolume=%.3f",
               EnableLossCycleRecovery ? "true" : "false",
               g_loss_cycle_step,g_cycle_open_volume);

   if(EnableProfitPyramiding &&
      (PyramidMinProfitPoints <= 0 || PyramidStepPoints <= 0))
   {
      Print("PyramidMinProfitPoints and PyramidStepPoints must be > 0.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(EnableProfitPyramiding &&
      (ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE)
         != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
      Print("Pyramiding requires a HEDGING account. Base entry and virtual swing BE remain active; additions are disabled.");

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   // Main-chart EMAs
   hFastMA = iMA(_Symbol,_Period,FastMAPeriod,0,MainMAMethod,MainMAPrice);
   hSlowMA = iMA(_Symbol,_Period,SlowMAPeriod,0,MainMAMethod,MainMAPrice);

   // MACD
   hMACD = iMACD(_Symbol,_Period,
                 MACDFastPeriod,MACDSlowPeriod,MACDSignalPeriod,MACDPrice);
   if(EnableSidewayFilter)
      hADX = iADX(_Symbol,_Period,SidewayADXPeriod);

   if(hFastMA == INVALID_HANDLE ||
      hSlowMA == INVALID_HANDLE ||
      hMACD   == INVALID_HANDLE ||
      (EnableSidewayFilter && hADX == INVALID_HANDLE))
   {
      PrintFormat("Cannot create base indicator handles. Error=%d",GetLastError());
      return INIT_FAILED;
   }

   // MQL5 allows an indicator handle to be supplied as applied_price.
   // Here MA(12) and RSI(14) are calculated from MACD's main data,
   // matching the overlay style shown in the reference chart.
   hMACDMA = iMA(_Symbol,_Period,MACDMAPeriod,0,MACDMAMethod,(ENUM_APPLIED_PRICE)hMACD);
   hRSI    = iRSI(_Symbol,_Period,RSIPeriod,(ENUM_APPLIED_PRICE)hMACD);

   if(hMACDMA == INVALID_HANDLE || hRSI == INVALID_HANDLE)
   {
      PrintFormat("Cannot create chained indicator handles. Error=%d",GetLastError());
      return INIT_FAILED;
   }

   AddIndicatorsToChart();

   // Initialize bar tracker so the EA does not treat attach-time as a new bar.
   g_last_bar_time = iTime(_Symbol,_Period,0);

   Print("EA initialized. Trading is ", (EnableTrading ? "ENABLED" : "DISABLED"),
         ". Write your logic in BuyCondition/SellCondition/CloseBuyCondition/CloseSellCondition.");

   return INIT_SUCCEEDED;
}

//====================================================================
// DEINITIALIZATION
//====================================================================
void OnDeinit(const int reason)
{
   if(hFastMA != INVALID_HANDLE) IndicatorRelease(hFastMA);
   if(hSlowMA != INVALID_HANDLE) IndicatorRelease(hSlowMA);
   if(hMACDMA != INVALID_HANDLE) IndicatorRelease(hMACDMA);
   if(hRSI    != INVALID_HANDLE) IndicatorRelease(hRSI);
   if(hMACD   != INVALID_HANDLE) IndicatorRelease(hMACD);
   if(hADX    != INVALID_HANDLE) IndicatorRelease(hADX);
}

//====================================================================
// MAIN LOOP (loss recovery changes LOT ONLY; entry and exit patterns unchanged)
//====================================================================
void OnTick()
{
   // Check daily total profit and force CLOSE on EVERY TICK, not only new bars.
   // When locked, no new entry, pyramid or ordinary signal-driven reversal.
   if(EnableTrading && HandleDailyProfitTarget())
      return;

   // Virtual swing break-even evaluates every tick, regardless of entry cadence.
   if(EnableTrading)
      ManageBreakEvenPositions();

   if(TradeOnNewBarOnly && !IsNewBar())
      return;

   // Capture any SL or manual closes that happened between bars.
   RefreshRecoveryHistory();

   IndicatorState s;
   if(!ReadIndicatorState(SignalShift,s))
      return;

   // Conditions can be developed/tested while trading is disabled.
   bool buy_signal        = BuyCondition(s);
   bool sell_signal       = SellCondition(s);
   bool close_buy_signal  = CloseBuyCondition(s);
   bool close_sell_signal = CloseSellCondition(s);

   if(!EnableTrading)
      return;

   // Exit first
   if(close_buy_signal)
      ClosePositionsByType(POSITION_TYPE_BUY);

   if(close_sell_signal)
      ClosePositionsByType(POSITION_TYPE_SELL);

   // Close-first strategy can open the reverse direction on the same bar.
   // Read completed close deals NOW so new direction gets the new loss step.
   if(close_buy_signal || close_sell_signal)
   {
      RefreshRecoveryHistory(true);
      // A same-bar exit may lift TODAY's realized profit past the limit.
      g_daily_realized_valid=false;
   }

   // Check again after normal exits; never reverse/open a new trade after
   // achieving the day's target in the very same candle.
   if(HandleDailyProfitTarget())
      return;

   // Every entry must be supported by exactly one directional signal.
   if(buy_signal == sell_signal)
      return;

   // Exits and SL protection above are NEVER blocked by the sideway filter.
   // Filter initial entry and pyramid additions alike.
   if(IsSidewayMarket(s))
      return;

   if(CountMyPositions() >= MaxPositionsPerSymbol)
      return;

   ENUM_POSITION_TYPE side = buy_signal ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
   int existing_positions = CountMyPositions();

   // Initial entry: use the original BUY/SELL signal logic.
   if(existing_positions == 0)
   {
      OpenMyPosition(side,buy_signal ? "Custom BUY" : "Custom SELL",s);
      return;
   }

   // Add only to a winning side. The BUY/SELL signal must still agree
   // with existing positions (checked in CanAddProfitPosition).
   if(!CanAddProfitPosition(side))
      return;

   bool added = OpenMyPosition(side,buy_signal ? "Pyramid BUY" : "Pyramid SELL",s);
   if(added)
      g_last_pyramid_bar_time = iTime(_Symbol,_Period,0);
}
//+------------------------------------------------------------------+
