//+------------------------------------------------------------------+
//| HedgeRecoveryEMA_SafetyHardened.mq5                    |
//| Separate UP/DOWN lot ladders; EMA decides Recovery/Continuation   |
//+------------------------------------------------------------------+
#property strict
#property version   "3.00"

#include <Trade/Trade.mqh>
CTrade trade;

//====================================================
// INPUT
//====================================================
input group "01 | LOT MANAGEMENT"
input double Lot                 = 0.01;
input double LotStep             = 0.01; 
input double LotRatio            = 3.0;   // safer default; original was 500
input int    MaxLevelsPerSide    = 0;     // 0 = unlimited (not recommended)  
input double MaxTotalLots       = 0;  // 0 = unlimited (not recommended) 

input group "02 | RANGE AND EMA"
input int    DistancePoints      = 500;
input int    EMAFastPeriod       = 8;
input int    EMASlowPeriod       = 21;

input group "03 | EXECUTION"
input ulong  MagicNumber         = 26092901;
input ulong  DeviationPoints     = 20;
input int    MaxSpreadPoints      = 0;   // 0 = OFF; filter is for entries only
input int    FreeMarginReservePct = 20;  // margin buffer; 0 = no reserve
input int    CooldownSeconds      = 60;  // wait after TP close; 0 = OFF

input group "04 | TAKE PROFIT"
input double FixedBasketTP        = 10.0; // Account currency; EA basket only

input group "05 | EMERGENCY RISK CONTROL"
input double MaxBasketLossPercent = 5.0;  // % of Balance; 0 = OFF
input double MaxBasketLossMoney   = 0.0;  // Account currency; 0 = OFF
input int    SafetyResetNonce     = 0;   // increment once per manual reset while flat

//====================================================
// GLOBAL STATE
//====================================================
int  up_level          = 0; 
int  down_level        = 0;   
bool initial           = true;
bool closing_all       = false;
bool trade_paused      = false;
bool safety_halt       = false;
datetime next_entry_time = 0;
string pause_reason    = "";

int handle_ema_fast    = INVALID_HANDLE;
int handle_ema_slow    = INVALID_HANDLE;

string PANEL_PREFIX    = "HRE2_PANEL_";
string state_key       = "";

double last_buy_lot    = 0.0;
double last_sell_lot   = 0.0;

//+------------------------------------------------------------------+
//| Lot helpers                                                       |
//+------------------------------------------------------------------+
int GetVolumeDigits()
{
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0.0) return 2;
   int digits = 0;
   while(step < 1.0 && digits < 8) { step *= 10.0; digits++; }
   return digits;
}

double NormalizeLot(double volume)
{
   // Do NOT silently clamp an oversized order to broker max volume.
   // Silent clamping can drastically change BUY/SELL hedge ratios.
   double min_lot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double max_lot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lot_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(lot_step <= 0.0 || min_lot <= 0.0 || max_lot < min_lot ||
      !MathIsValidNumber(volume) || volume < min_lot - 1e-9 || volume > max_lot + 1e-9)
      return 0.0;

   // Floor instead of round: the EA must never raise requested exposure.
   double normalized = MathFloor(volume / lot_step + 1e-8) * lot_step;
   normalized = NormalizeDouble(normalized, GetVolumeDigits());
   if(normalized < min_lot - 1e-9 || normalized > max_lot + 1e-9)
      return 0.0;
   return normalized;
}

//+------------------------------------------------------------------+
//| Position helpers (only current symbol and MagicNumber)           |
//+------------------------------------------------------------------+
bool SelectOwnPosition(ulong ticket)
{
   if(ticket == 0 || !PositionSelectByTicket(ticket)) return false;
   if(PositionGetString(POSITION_SYMBOL) != _Symbol) return false;
   if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber) return false;
   return true;
}

void GetPositionStats(int &count, int &buy_count, int &sell_count,
                      double &buy_lots, double &sell_lots,
                      double &lowest, double &highest, double &floating)
{
   count = 0; buy_count = 0; sell_count = 0;
   buy_lots = 0.0; sell_lots = 0.0;
   lowest = DBL_MAX; highest = -DBL_MAX;
   floating = 0.0;

   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!SelectOwnPosition(ticket)) continue;
      count++;
      double volume = PositionGetDouble(POSITION_VOLUME);
      double price  = PositionGetDouble(POSITION_PRICE_OPEN);
      lowest        = MathMin(lowest, price);
      highest       = MathMax(highest, price);
      floating     += PositionGetDouble(POSITION_PROFIT)
                   +  PositionGetDouble(POSITION_SWAP);

      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
      {
         buy_count++;
         buy_lots += volume;
      }
      else
      {
         sell_count++;
         sell_lots += volume;
      }
   }
   if(count == 0) { lowest = 0.0; highest = 0.0; }
}

int CountOwnPositions()
{
   int n = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
      if(SelectOwnPosition(PositionGetTicket(i))) n++;
   return n;
}

//+------------------------------------------------------------------+
//| EMA: use completed candle (shift = 1)                             |
//+------------------------------------------------------------------+
bool GetEMAValue(double &fast, double &slow)
{
   if(handle_ema_fast == INVALID_HANDLE || handle_ema_slow == INVALID_HANDLE)
      return false;
   double a[1], b[1];
   if(CopyBuffer(handle_ema_fast, 0, 1, 1, a) != 1) return false;
   if(CopyBuffer(handle_ema_slow, 0, 1, 1, b) != 1) return false;
   fast = a[0];
   slow = b[0];
   return (MathIsValidNumber(fast) && MathIsValidNumber(slow));
}

int GetTrend(double fast, double slow)
{
   if(fast > slow) return 1;    // EMA BUY
   if(fast < slow) return -1;   // EMA SELL
   return 0;
}

//+------------------------------------------------------------------+
//| Each boundary has its OWN independent lot progression.           |
//| first UP or DOWN: Lot + 1*LotStep                                 |
//| second UP or DOWN: Lot + 2*LotStep                                |
//| Trend leg is scaled by LotRatio; opposite leg is the hedge.      |
//+------------------------------------------------------------------+
void CalculatePairLots(int side_level, int trend,
                       double &buy_volume, double &sell_volume)
{
   double base = NormalizeLot(Lot + LotStep * (side_level + 1));
   buy_volume  = NormalizeLot((trend == 1) ? base * LotRatio : base);
   sell_volume = NormalizeLot((trend == -1) ? base * LotRatio : base);
}

//+------------------------------------------------------------------+
//| Persist counters for chart/terminal restarts                      |
//+------------------------------------------------------------------+
void SaveState()
{
   GlobalVariableSet(state_key + "UP",    (double)up_level);
   GlobalVariableSet(state_key + "DOWN",  (double)down_level);
   GlobalVariableSet(state_key + "CLOSE", closing_all ? 1.0 : 0.0);
   if(safety_halt) GlobalVariableSet(state_key + "HALT", 1.0);
   else            GlobalVariableDel(state_key + "HALT");
   if(next_entry_time > 0)
      GlobalVariableSet(state_key + "NEXT", (double)next_entry_time);
   else GlobalVariableDel(state_key + "NEXT");
}

void ResetCycle()
{
   up_level        = 0;
   down_level      = 0;
   initial         = true;
   closing_all     = false;
   trade_paused    = false;
   pause_reason    = "";
   last_buy_lot    = NormalizeLot(Lot);
   last_sell_lot   = NormalizeLot(Lot);
   GlobalVariableDel(state_key + "UP");
   GlobalVariableDel(state_key + "DOWN");
   GlobalVariableDel(state_key + "CLOSE");
   GlobalVariableDel(state_key + "OPEN");
   // HALT and NEXT survive a cycle reset AND terminal restart.
   if(safety_halt) GlobalVariableSet(state_key + "HALT", 1.0);
   else            GlobalVariableDel(state_key + "HALT");
   if(next_entry_time > 0)
      GlobalVariableSet(state_key + "NEXT", (double)next_entry_time);
   else GlobalVariableDel(state_key + "NEXT");
   PrintFormat("RESET CYCLE | halted=%s | next_entry=%s",
               safety_halt ? "YES" : "NO", TimeToString(next_entry_time,TIME_DATE|TIME_SECONDS));
}

void EnterEmergencyClose(string reason);

void RestoreState()
{
   safety_halt = GlobalVariableCheck(state_key + "HALT") &&
                 GlobalVariableGet(state_key + "HALT") > 0.5;
   if(GlobalVariableCheck(state_key + "NEXT"))
      next_entry_time = (datetime)GlobalVariableGet(state_key + "NEXT");
   if(CountOwnPositions() == 0)
   {
      // Terminal may have stopped after the last Close, but before
      // saving the post-close cooldown. Preserve cooldown across restart.
      if(GlobalVariableCheck(state_key + "CLOSE") &&
         GlobalVariableGet(state_key + "CLOSE") > 0.5 &&
         next_entry_time < TimeCurrent()+CooldownSeconds)
         next_entry_time = TimeCurrent()+CooldownSeconds;
      ResetCycle();
      return;
   }
   initial = false;
   if(GlobalVariableCheck(state_key + "OPEN") &&
      GlobalVariableGet(state_key + "OPEN") > 0.5)
   {
      // Terminal crashed between BUY and SELL, or before confirming pair.
      EnterEmergencyClose("RESTART DURING HEDGE PAIR");
      return;
   }
   bool has_up   = GlobalVariableCheck(state_key + "UP");
   bool has_down = GlobalVariableCheck(state_key + "DOWN");
   if(has_up)   up_level   = (int)GlobalVariableGet(state_key + "UP");
   if(has_down) down_level = (int)GlobalVariableGet(state_key + "DOWN");
   if(GlobalVariableCheck(state_key + "CLOSE"))
      closing_all = (GlobalVariableGet(state_key + "CLOSE") > 0.5);

   // Backup recovery from broker's comments: "HRE U3 BUY" / "HRE D2 SELL".
   int detected_up = 0, detected_down = 0;
   bool known_comment = false;
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      if(!SelectOwnPosition(PositionGetTicket(i))) continue;
      string comment = PositionGetString(POSITION_COMMENT);
      if(StringFind(comment, "HRE INIT") == 0) known_comment = true;
      if(StringFind(comment, "HRE U") == 0)
      {
         known_comment = true;
         detected_up = MathMax(detected_up, (int)StringToInteger(StringSubstr(comment, 5)));
      }
      if(StringFind(comment, "HRE D") == 0)
      {
         known_comment = true;
         detected_down = MathMax(detected_down, (int)StringToInteger(StringSubstr(comment, 5)));
      }
   }
   up_level   = MathMax(up_level, detected_up);
   down_level = MathMax(down_level, detected_down);

   if(!has_up && !has_down && !known_comment)
   {
      trade_paused = true;
      pause_reason = "OLD BASKET: COUNTERS UNKNOWN";
      Print("RECOVERY PAUSED: existing positions have no saved counters.");
      // Do not persist fabricated zero counters for a legacy basket.
      // A subsequent restart must also remain paused for safety.
      return;
   }
   SaveState();
   PrintFormat("RESTORED: UP=%d DOWN=%d CLOSING=%s",
               up_level, down_level, closing_all ? "YES" : "NO");
}


//+------------------------------------------------------------------+
//| Rate-limit repeated entry rejections                              |
//+------------------------------------------------------------------+
void LogEntryBlock(string message)
{
   static datetime last_log=0;
   static string last_message="";
   datetime now=TimeCurrent();
   if(message!=last_message || now-last_log>=60)
   {
      Print(message);
      last_log=now;
      last_message=message;
   }
}

//+------------------------------------------------------------------+
//| Safety, integrity, and pre-order checks                            |
//+------------------------------------------------------------------+
void EnterEmergencyClose(string reason)
{
   if(!safety_halt || !closing_all)
      Print("EMERGENCY STOP: " + reason + " | closing basket and halting new entries");
   safety_halt = true;
   closing_all = true;
   pause_reason = reason;
   SaveState();
}

// Pair health: +1 = all comments grouped into balanced BUY/SELL pairs;
//               0 = unknown/missing comments (pause new entries);
//              -1 = confirmed missing hedge counterpart (emergency close).
int PairHealth()
{
   int n,bc,sc; double bl,sl,lo,hi,pf;
   GetPositionStats(n,bc,sc,bl,sl,lo,hi,pf);
   if(n==0) return 1;
   if(bc!=sc) return -1;

   for(int i=0;i<PositionsTotal();i++)
   {
      ulong id=PositionGetTicket(i);
      if(!SelectOwnPosition(id)) continue;
      string c=PositionGetString(POSITION_COMMENT);
      int len=StringLen(c);
      if(len < 8 || StringFind(c,"HRE ")!=0) return 0;
      bool is_buy=StringSubstr(c,len-4)==" BUY";
      bool is_sell=StringSubstr(c,len-5)==" SELL";
      if(!is_buy && !is_sell) return 0;
      string key=StringSubstr(c,0,len-(is_buy?4:5));
      int group_buy=0,group_sell=0;
      for(int j=0;j<PositionsTotal();j++)
      {
         ulong other=PositionGetTicket(j);
         if(!SelectOwnPosition(other)) continue;
         string oc=PositionGetString(POSITION_COMMENT);
         if(oc==key+" BUY") group_buy++;
         if(oc==key+" SELL") group_sell++;
      }
      if(group_buy!=group_sell) return -1;
   }
   return 1;
}

bool CheckEntryBudget(double buy_lot,double sell_lot)
{
   if(buy_lot<=0.0 || sell_lot<=0.0)
   {
      LogEntryBlock("ENTRY BLOCKED: invalid lot/min-max broker volume/lot step");
      return false;
   }
   int n,bc,sc; double bl,sl,lo,hi,pf;
   GetPositionStats(n,bc,sc,bl,sl,lo,hi,pf);
   if(MaxTotalLots>0.0 && bl+sl+buy_lot+sell_lot>MaxTotalLots+1e-8)
   {
      LogEntryBlock("ENTRY BLOCKED: total lots limit reached");
      return false;
   }
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick) || tick.ask<=0.0 || tick.bid<=0.0 ||
      tick.ask<tick.bid || _Point<=0.0)
   {
      LogEntryBlock("ENTRY BLOCKED: invalid quote");
      return false;
   }
   // Conservative: MQL5 OrderCalcMargin ignores current positions and
   // hedged margin offsets, so this can reject orders brokers might accept.
   double buy_margin=0.0,sell_margin=0.0;
   if(!OrderCalcMargin(ORDER_TYPE_BUY,_Symbol,buy_lot,tick.ask,buy_margin) ||
      !OrderCalcMargin(ORDER_TYPE_SELL,_Symbol,sell_lot,tick.bid,sell_margin))
   {
      LogEntryBlock("ENTRY BLOCKED: margin estimate failed");
      return false;
   }
   double free_margin=AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double needed=(buy_margin+sell_margin);
   double usable=free_margin*(100.0-FreeMarginReservePct)/100.0;
   if(!MathIsValidNumber(needed) || needed<0.0 || usable<needed)
   {
      LogEntryBlock("ENTRY BLOCKED: low free margin");
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| Spread filter: ENTRY ONLY (INITIAL and RECOVERY/CONTINUATION).      |
//| 0 = disabled. High spread never blocks Basket TP / Close All.      |
//+------------------------------------------------------------------+
bool CanOpenBySpread()
{
   if(MaxSpreadPoints == 0) return true;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick) ||
      tick.bid <= 0.0 || tick.ask <= 0.0 || tick.ask < tick.bid || _Point <= 0.0)
      return false; // No usable quote: do not open a new hedge pair.

   double spread_points = (tick.ask - tick.bid) / _Point;
   if(spread_points <= (double)MaxSpreadPoints + 1e-7) return true;

   // Avoid flooding the Experts log on every tick when spread is wide.
   static datetime last_log_time = 0;
   datetime now = TimeCurrent();
   if(last_log_time == 0 || now - last_log_time >= 60)
   {
      PrintFormat("SPREAD FILTER: new entry skipped | spread=%.1f pts > max=%d pts",
                  spread_points, MaxSpreadPoints);
      last_log_time = now;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Trades: check server retcode, not only CTrade's boolean           |
//+------------------------------------------------------------------+
bool TradeFilled(bool sent, string label)
{
   uint rc = trade.ResultRetcode();
   if(sent && rc == TRADE_RETCODE_DONE) return true;
   PrintFormat("%s FAILED: retcode=%u (%s)",
               label, rc, trade.ResultRetcodeDescription());
   return false;
}

// Close just the BUY created by this call if SELL cannot open.
bool RollbackBuy(ulong opening_order_ticket, string buy_comment)
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(!SelectOwnPosition(ticket)) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE)!=POSITION_TYPE_BUY) continue;
      ulong identifier=(ulong)PositionGetInteger(POSITION_IDENTIFIER);
      if(ticket!=opening_order_ticket && identifier!=opening_order_ticket &&
         PositionGetString(POSITION_COMMENT)!=buy_comment) continue;
      bool sent=trade.PositionClose(ticket);
      if(TradeFilled(sent,"ROLLBACK BUY")) return true;
   }
   return false;
}

bool OpenHedgePosition(double buy_volume, double sell_volume, string comment)
{
   // A hedge pair is an indivisible logical operation, though the broker
   // executes its BUY and SELL as separate real transactions.
   if(safety_halt || closing_all || trade_paused) return false;
   if(!CanOpenBySpread()) return false;
   buy_volume  = NormalizeLot(buy_volume);
   sell_volume = NormalizeLot(sell_volume);
   if(!CheckEntryBudget(buy_volume,sell_volume)) return false;

   int before=CountOwnPositions();
   // Persist before BUY so a terminal crash leaves a detectable marker.
   if(GlobalVariableSet(state_key+"OPEN",1.0)==0)
   {
      LogEntryBlock("ENTRY BLOCKED: cannot persist in-flight hedge marker");
      return false;
   }
   bool sent_buy=trade.Buy(buy_volume,_Symbol,0.0,0.0,0.0,comment+" BUY");
   ulong buy_order_ticket=trade.ResultOrder();
   double buy_filled=trade.ResultVolume();
   if(!TradeFilled(sent_buy,"BUY"))
   {
      if(CountOwnPositions()!=before) EnterEmergencyClose("BUY EXECUTION UNCERTAIN");
      else GlobalVariableDel(state_key+"OPEN");
      return false;
   }
   // Partial/uncertain lots require emergency handling, not a false 'pair ok'.
   double lot_step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   if(buy_filled<=0.0 || MathAbs(buy_filled-buy_volume)>lot_step*0.25)
   {
      EnterEmergencyClose("BUY VOLUME MISMATCH");
      return false;
   }

   // Don't re-check spread after BUY; it would strand the first leg.
   bool sent_sell=trade.Sell(sell_volume,_Symbol,0.0,0.0,0.0,comment+" SELL");
   double sell_filled=trade.ResultVolume();
   bool sell_ok=TradeFilled(sent_sell,"SELL");
   if(!sell_ok || sell_filled<=0.0 || MathAbs(sell_filled-sell_volume)>lot_step*0.25)
   {
      // Rollback where possible; if any exposure differs from before,
      // flatten the whole basket, halt and require explicit user reset.
      bool rollback=RollbackBuy(buy_order_ticket,comment+" BUY");
      if(CountOwnPositions()!=before)
         EnterEmergencyClose("INCOMPLETE HEDGE PAIR");
      else
      {
         GlobalVariableDel(state_key+"OPEN");
         PrintFormat("PAIR FAILED | BUY rolled back=%s | no added exposure",
                     rollback ? "YES" : "NO");
      }
      return false;
   }

   if(CountOwnPositions()!=before+2)
   {
      EnterEmergencyClose("HEDGE POSITION COUNT MISMATCH");
      return false;
   }
   GlobalVariableDel(state_key+"OPEN");
   last_buy_lot=buy_volume;
   last_sell_lot=sell_volume;
   PrintFormat("%s | BUY=%s SELL=%s",comment,
               DoubleToString(buy_volume,GetVolumeDigits()),
               DoubleToString(sell_volume,GetVolumeDigits()));
   return true;
}

bool OpenInitialPosition()
{
   double base = NormalizeLot(Lot);
   if(!OpenHedgePosition(base, base, "HRE INIT")) return false;
   initial = false;
   SaveState();
   return true;
}

// direction: +1 = upper break; -1 = lower break
void OpenRecovery(int direction, int trend)
{
   int current_level = (direction == 1) ? up_level : down_level;
   if(MaxLevelsPerSide > 0 && current_level >= MaxLevelsPerSide)
   {
      // Avoid printing thousands of identical messages on every price tick.
      static datetime last_up_warn_bar = 0;
      static datetime last_down_warn_bar = 0;
      datetime bar_time = iTime(_Symbol, _Period, 0);
      if(direction == 1 && last_up_warn_bar != bar_time)
      {
         PrintFormat("LEVEL LIMIT reached: UP %d", current_level);
         last_up_warn_bar = bar_time;
      }
      else if(direction == -1 && last_down_warn_bar != bar_time)
      {
         PrintFormat("LEVEL LIMIT reached: DOWN %d", current_level);
         last_down_warn_bar = bar_time;
      }
      return;
   }

   // Skip logging a trade signal if spread is currently too wide.
   // OpenHedgePosition checks again just before sending BUY.
   if(!CanOpenBySpread()) return;

   double buy_volume, sell_volume;
   CalculatePairLots(current_level, trend, buy_volume, sell_volume);
   bool countertrend = (direction == -trend);
   string range_side  = (direction == 1) ? "U" : "D";
   string kind = countertrend ? "RECOVERY" : "CONTINUATION";
   string comment = "HRE " + range_side + IntegerToString(current_level+1);

   PrintFormat("SIGNAL %s: EMA=%s, %s BREAK, STEP=%d, BUY=%.2f, SELL=%.2f",
               kind, trend==1 ? "BUY" : "SELL",
               direction==1 ? "UPPER" : "LOWER", current_level+1,
               buy_volume, sell_volume);

   if(!OpenHedgePosition(buy_volume, sell_volume, comment)) return;
   if(direction == 1) up_level++; else down_level++;
   SaveState();
}

//+------------------------------------------------------------------+
//| Close all when this EA's basket P/L reaches FixedBasketTP.       |
//| Only this symbol and MagicNumber are counted and closed.         |
//| Once triggered, finish closing even if remaining P/L falls.      |
//+------------------------------------------------------------------+
bool TryCloseAll()
{
   int n,bc,sc; double bl,sl,lo,hi,floating;
   GetPositionStats(n,bc,sc,bl,sl,lo,hi,floating);
   if(n==0)
   {
      if(closing_all)
      {
         next_entry_time=TimeCurrent()+CooldownSeconds;
         ResetCycle();
      }
      return false;
   }

   if(!closing_all)
   {
      if(PairHealth()<0) EnterEmergencyClose("UNPAIRED HEDGE POSITIONS");
   }
   if(!closing_all)
   {
      double balance=AccountInfoDouble(ACCOUNT_BALANCE);
      bool money_stop=(MaxBasketLossMoney>0.0 && floating<=-MaxBasketLossMoney);
      bool pct_stop=(MaxBasketLossPercent>0.0 && balance>0.0 &&
                     floating<=-balance*MaxBasketLossPercent/100.0);
      if(money_stop || pct_stop)
         EnterEmergencyClose("BASKET MAX LOSS REACHED");
      else if(floating>=FixedBasketTP)
      {
         closing_all=true;
         SaveState();
         PrintFormat("FIXED BASKET TP | FLOAT %.2f >= TARGET %.2f",
                     floating,FixedBasketTP);
      }
      else return false;
   }

   // Closing is never gated by spread, EMA, margin, or safety halt.
   // One pass per tick/timer prevents aggressive repeated requests.
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(!SelectOwnPosition(ticket)) continue;
      bool sent=trade.PositionClose(ticket);
      TradeFilled(sent,"CLOSE #"+IntegerToString((long)ticket));
   }
   if(CountOwnPositions()==0)
   {
      next_entry_time=TimeCurrent()+CooldownSeconds;
      ResetCycle();
   }
   return true;
}

//+------------------------------------------------------------------+
//| PANEL                                                            |
//+------------------------------------------------------------------+
void AddLabel(string id, int y, color c=clrWhite)
{
   string name = PANEL_PREFIX + id;
   if(ObjectFind(0,name)<0) ObjectCreate(0,name,OBJ_LABEL,0,0,0);
   ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,24);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,name,OBJPROP_FONTSIZE,10);
   ObjectSetInteger(0,name,OBJPROP_COLOR,c);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
   ObjectSetString(0,name,OBJPROP_FONT,"Consolas");
}

void PanelText(string id, string value, color c=clrWhite)
{
   string name = PANEL_PREFIX + id;
   ObjectSetString(0,name,OBJPROP_TEXT,value);
   ObjectSetInteger(0,name,OBJPROP_COLOR,c);
}

void CreatePanel()
{
   string bg = PANEL_PREFIX + "BG";
   if(ObjectFind(0,bg)<0) ObjectCreate(0,bg,OBJ_RECTANGLE_LABEL,0,0,0);
   ObjectSetInteger(0,bg,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,bg,OBJPROP_XDISTANCE,10);
   ObjectSetInteger(0,bg,OBJPROP_YDISTANCE,20);
   ObjectSetInteger(0,bg,OBJPROP_XSIZE,420);
   ObjectSetInteger(0,bg,OBJPROP_YSIZE,438);
   ObjectSetInteger(0,bg,OBJPROP_BGCOLOR,clrBlack);
   ObjectSetInteger(0,bg,OBJPROP_COLOR,clrDimGray);
   ObjectSetInteger(0,bg,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,bg,OBJPROP_HIDDEN,true);

   AddLabel("TITLE",    30,clrGold);
   AddLabel("STATUS",   57);
   AddLabel("POSITIONS",79);
   AddLabel("LEVELS",  101);
   AddLabel("TREND",   123);
   AddLabel("EMA",     145);
   AddLabel("RANGE",   167);
   AddLabel("PRICES",  189);
   AddLabel("NEXTUP",  211);
   AddLabel("NEXTDOWN",233);
   AddLabel("LAST",    255);
   AddLabel("TOTAL",   277);
   AddLabel("RATIO",   299);
   AddLabel("ACCOUNT", 321);
   AddLabel("FLOAT",   343);
   AddLabel("BASKETTP",365);
   AddLabel("SPREAD",  387);
   AddLabel("MESSAGE", 409);
   PanelText("TITLE","HEDGE RECOVERY EMA | INDEPENDENT UP/DOWN",clrGold);
}

void UpdatePanel()
{
   int n, bc, sc; double bl, sl, lo, hi, profit;
   GetPositionStats(n,bc,sc,bl,sl,lo,hi,profit);

   double fast = 0.0, slow = 0.0;
   bool ema_ok = GetEMAValue(fast,slow);
   int trend = ema_ok ? GetTrend(fast,slow) : 0;
   string trend_name = trend==1 ? "BUY" : (trend==-1 ? "SELL" : "WAIT");
   color trend_color = trend==1 ? clrLime : (trend==-1 ? clrTomato : clrSilver);

   MqlTick tick; ZeroMemory(tick);
   SymbolInfoTick(_Symbol,tick);
   string mode = closing_all ? "CLOSING ALL" :
                  (safety_halt ? "SAFETY HALT" :
                  (trade_paused ? "PAUSED" :
                  (n==0 && TimeCurrent()<next_entry_time ? "COOLDOWN" :
                  (n==0 ? "WAIT INITIAL" : "RUNNING"))));

   double next_up_buy=0,next_up_sell=0,next_down_buy=0,next_down_sell=0;
   if(trend!=0)
   {
      CalculatePairLots(up_level,trend,next_up_buy,next_up_sell);
      CalculatePairLots(down_level,trend,next_down_buy,next_down_sell);
   }
   int vd = GetVolumeDigits();
   PanelText("STATUS", "STATUS     : " + mode, (trade_paused||safety_halt) ? clrTomato : clrWhite);
   PanelText("POSITIONS", "POSITION   : " + IntegerToString(n) + " BUY="+
             IntegerToString(bc)+" SELL="+IntegerToString(sc));
   PanelText("LEVELS", "UP / DOWN  : " + IntegerToString(up_level) + " / " + IntegerToString(down_level));
   PanelText("TREND", "EMA TREND  : " + trend_name, trend_color);
   PanelText("EMA", "EMA " + IntegerToString(EMAFastPeriod) + "/" + IntegerToString(EMASlowPeriod) +
             " : " + DoubleToString(fast,_Digits) + " / " + DoubleToString(slow,_Digits));
   PanelText("RANGE", "HIGH / LOW : " + DoubleToString(hi,_Digits) + " / " + DoubleToString(lo,_Digits));
   PanelText("PRICES", "ASK / BID  : " + DoubleToString(tick.ask,_Digits) + " / " + DoubleToString(tick.bid,_Digits));
   string up_kind = trend==-1 ? "RECOVERY" : "CONTINUE";
   string down_kind=trend==1 ? "RECOVERY" : "CONTINUE";
   PanelText("NEXTUP", "NEXT UP   ["+up_kind+"] B:"+DoubleToString(next_up_buy,vd)+" S:"+DoubleToString(next_up_sell,vd));
   PanelText("NEXTDOWN", "NEXT DOWN ["+down_kind+"] B:"+DoubleToString(next_down_buy,vd)+" S:"+DoubleToString(next_down_sell,vd));
   PanelText("LAST", "LAST LOT   : BUY "+DoubleToString(last_buy_lot,vd)+" SELL "+DoubleToString(last_sell_lot,vd));
   PanelText("TOTAL", "TOTAL LOT  : BUY "+DoubleToString(bl,vd)+" SELL "+DoubleToString(sl,vd));
   PanelText("RATIO", "TREND/HEDGE: "+DoubleToString(LotRatio,2)+" / 1.00");
   PanelText("ACCOUNT", "BAL / EQ   : "+DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE),2)+
             " / "+DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY),2));
   PanelText("FLOAT", "EA FLOAT   : "+DoubleToString(profit,2), profit>=0 ? clrLime : clrTomato);
   PanelText("BASKETTP", "BASKET TP  : "+DoubleToString(FixedBasketTP,2)+" "+
              AccountInfoString(ACCOUNT_CURRENCY), clrGold);
   double spread_pts = (_Point > 0.0 && tick.ask > 0.0 && tick.bid > 0.0 && tick.ask >= tick.bid)
                       ? (tick.ask - tick.bid) / _Point : -1.0;
   string spread_now = spread_pts >= 0.0 ? DoubleToString(spread_pts,1) : "N/A";
   string spread_max = MaxSpreadPoints == 0 ? "OFF" : IntegerToString(MaxSpreadPoints);
   color spread_color = MaxSpreadPoints == 0 ? clrSilver :
                        (spread_pts < 0.0 || spread_pts > MaxSpreadPoints + 1e-7 ? clrTomato : clrLime);
   PanelText("SPREAD", "SPREAD     : " + spread_now + " pts / MAX " + spread_max,
             spread_color);
   string msg = safety_halt ? "SAFETY HALT: increase SafetyResetNonce" :
                (trade_paused ? pause_reason :
                (closing_all ? "Closing remaining EA positions" :
                (TimeCurrent()<next_entry_time ? "Next: "+TimeToString(next_entry_time,TIME_SECONDS) :
                "Step per boundary = "+DoubleToString(LotStep,vd))));
   PanelText("MESSAGE",msg,(trade_paused||safety_halt)?clrTomato:clrSilver);
   ChartRedraw();
}

//+------------------------------------------------------------------+
//| START / TICK / STOP                                              |
//+------------------------------------------------------------------+
int OnInit()
{
   if((ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE)
      != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
   {
      Print("ERROR: Hedging account required");
      return INIT_FAILED;
   }
   if(Lot<=0.0 || LotStep<=0.0 || LotRatio<1.0 || DistancePoints<=0 ||
      EMAFastPeriod<=0 || EMASlowPeriod<=0 || EMAFastPeriod==EMASlowPeriod ||
       MaxLevelsPerSide<0 || MaxTotalLots<0.0 || FixedBasketTP<=0.0 ||
       MaxSpreadPoints<0 || FreeMarginReservePct<0 || FreeMarginReservePct>=100 ||
       CooldownSeconds<0 || MaxBasketLossPercent<0.0 || MaxBasketLossPercent>100.0 ||
       MaxBasketLossMoney<0.0 || SafetyResetNonce<0)
   {
      Print("ERROR: Invalid EA input values");
      return INIT_PARAMETERS_INCORRECT;
   }

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(DeviationPoints);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetAsyncMode(false);

   handle_ema_fast = iMA(_Symbol,_Period,EMAFastPeriod,0,MODE_EMA,PRICE_CLOSE);
   handle_ema_slow = iMA(_Symbol,_Period,EMASlowPeriod,0,MODE_EMA,PRICE_CLOSE);
   if(handle_ema_fast==INVALID_HANDLE || handle_ema_slow==INVALID_HANDLE)
   {
      Print("ERROR: EMA indicator handles not available");
      if(handle_ema_fast!=INVALID_HANDLE) IndicatorRelease(handle_ema_fast);
      if(handle_ema_slow!=INVALID_HANDLE) IndicatorRelease(handle_ema_slow);
      return INIT_FAILED;
   }

   state_key = "HRE_" + IntegerToString((long)AccountInfoInteger(ACCOUNT_LOGIN)) +
               "_" + _Symbol + "_" + IntegerToString((long)MagicNumber) + "_";
   last_buy_lot = NormalizeLot(Lot);
   last_sell_lot= NormalizeLot(Lot);
   RestoreState();
   int last_nonce = GlobalVariableCheck(state_key+"NONCE") ?
                    (int)GlobalVariableGet(state_key+"NONCE") : 0;
   if(SafetyResetNonce>last_nonce)
   {
      if(CountOwnPositions()==0)
      {
         safety_halt=false;
         GlobalVariableDel(state_key+"HALT");
         GlobalVariableSet(state_key+"NONCE",(double)SafetyResetNonce);
         PrintFormat("Safety halt cleared using new nonce %d",SafetyResetNonce);
      }
      else Print("SafetyResetNonce ignored until positions are flat");
   }
   if(!EventSetTimer(5)) Print("WARNING: Could not enable 5s close retry timer");
   CreatePanel();
   UpdatePanel();
   Print("EA START | independent UP/DOWN ladders | EMA closed candle");
   return INIT_SUCCEEDED;
}

void OnTick()
{
   // Always process exits first, independently of entry filters.
   if(TryCloseAll()) { UpdatePanel(); return; }

   int n,bc,sc; double bl,sl,low,high,profit;
   GetPositionStats(n,bc,sc,bl,sl,low,high,profit);
   if(n==0)
   {
      if(!initial || trade_paused) ResetCycle();
      if(safety_halt || TimeCurrent()<next_entry_time)
      { UpdatePanel(); return; }
      if(initial) OpenInitialPosition();
      UpdatePanel();
      return;
   }

   // Detect positions that were manually closed or left after interrupted pair.
   int pair_health=PairHealth();
   if(pair_health<0)
   {
      EnterEmergencyClose("UNPAIRED HEDGE POSITIONS");
      TryCloseAll();
      UpdatePanel();
      return;
   }
   if(pair_health==0 && !trade_paused)
   {
      trade_paused=true;
      pause_reason="HEDGE COMMENTS UNKNOWN - REVIEW";
      Print(pause_reason);
   }
   if(safety_halt || trade_paused) { UpdatePanel(); return; }

   double fast=0.0,slow=0.0;
   if(!GetEMAValue(fast,slow)) { UpdatePanel(); return; }
   int trend=GetTrend(fast,slow);
   if(trend==0) { UpdatePanel(); return; }
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick) || tick.ask<=0.0 || tick.bid<=0.0 ||
      tick.ask<tick.bid) { UpdatePanel(); return; }
   double distance=DistancePoints*_Point;

   // Recovery levels advance only if a fully executed hedge pair exists.
   if(tick.ask+distance<=low) OpenRecovery(-1,trend);
   else if(tick.bid-distance>=high) OpenRecovery(1,trend);
   UpdatePanel();
}

void OnTimer()
{
   if(closing_all || CountOwnPositions()>0) TryCloseAll();
   UpdatePanel();
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   if(handle_ema_fast!=INVALID_HANDLE) IndicatorRelease(handle_ema_fast);
   if(handle_ema_slow!=INVALID_HANDLE) IndicatorRelease(handle_ema_slow);
   ObjectsDeleteAll(0,PANEL_PREFIX);
   ChartRedraw();
}
//+------------------------------------------------------------------+
