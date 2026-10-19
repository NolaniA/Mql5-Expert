//+------------------------------------------------------------------+
//| SMC_TradeX_Prototype.mq5                                          |
//| MT5 Expert Advisor - SMC research prototype                      |
//| IMPORTANT: Adaptation of broad SMC principles, NOT a verified     |
//| transcription of the linked TradeX videos. Backtest on demo.     |
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"
#property description "SMC prototype: BOS+Order Block, Liquidity Sweep+CHoCH, FVG retest"

#include <Trade/Trade.mqh>
CTrade trade;

enum ENUM_SMC_STRATEGY
{
   SMC_BOS_ORDER_BLOCK = 0,   // BOS -> last opposing candle -> retest
   SMC_SWEEP_CHOCH     = 1,   // Liquidity sweep -> structural reversal
   SMC_FVG_RETEST      = 2,   // 3-candle FVG -> retest
   SMC_ANY_SETUP       = 3    // First matching setup (not 3 simultaneous positions)
};

input group "--- Strategy / timeframes ---"
input ENUM_SMC_STRATEGY Strategy = SMC_BOS_ORDER_BLOCK;
input ENUM_TIMEFRAMES EntryTF = PERIOD_M5;
input ENUM_TIMEFRAMES ContextTF = PERIOD_H1;
input bool   UseHTFTrendFilter = false; // Disable for counter-trend tests
input int    SwingStrength = 3;         // Closed bars each side of swing
input int    SwingLookback = 140;
input int    OBLookbackBars = 16;
input int    SetupExpiryBars = 14;
input double SweepBufferPoints = 5.0;
input double BreakBufferPoints = 5.0;
input double StopBufferPoints = 20.0;
input int    ATRPeriod = 14;
input double MinImpulseBodyATR = 0.70;
input double MaxZoneSizeATR = 2.50;

input group "--- Risk / execution ---"
input bool   UseRiskPercent = true;
input double RiskPercent = 0.50;        // Percentage of balance (not equity)
input double FixedLot = 0.01;
input double RewardRisk = 2.0;
input int    MaxSpreadPoints = 0;      // 0 = disabled
input int    SlippagePoints = 20;
input double DailyLossLimitCash = 0;  // 0 = disabled; account currency
input double DailyProfitTargetCash = 0;// 0 = disabled; account currency
input bool   EnableBreakEven = true;
input double BreakEvenAtR = 1.0;
input int    BreakEvenPlusPoints = 0;
input ulong  MagicNumber = 26101535;

input group "--- Session (BROKER SERVER TIME) ---"
input bool   LimitToWeekdays = true;
input bool   UseTradingSession = false;
input int    SessionStartHour = 7;
input int    SessionEndHour = 22;      // Exclusive; 0..24
input bool   ShowSetupZone = true;

struct SMCSetup
{
   bool     active;
   int      direction;           // +1 buy, -1 sell
   int      mode;
   int      barsLeft;
   double   zoneLow;
   double   zoneHigh;
   double   slAnchor;
   double   breakLevel;          // CHoCH level
   datetime timeCreated;
};

SMCSetup g_setup;
datetime g_lastBar = 0;
int g_atrHandle = INVALID_HANDLE;
string g_objPrefix = "SMC_TRX_";

void ResetSetup()
{
   g_setup.active      = false;
   g_setup.direction   = 0;
   g_setup.mode        = -1;
   g_setup.barsLeft    = 0;
   g_setup.zoneLow     = 0.0;
   g_setup.zoneHigh    = 0.0;
   g_setup.slAnchor    = 0.0;
   g_setup.breakLevel  = 0.0;
   g_setup.timeCreated = 0;
}

int OnInit()
{
   if(SwingStrength < 1 || SwingLookback < 25 || OBLookbackBars < 2 ||
      SetupExpiryBars < 1 || ATRPeriod < 1 || RewardRisk < 1.0 ||
      (UseRiskPercent && (RiskPercent <= 0.0 || RiskPercent > 2.0)) ||
      (!UseRiskPercent && FixedLot <= 0.0) ||
      SessionStartHour < 0 || SessionStartHour > 23 ||
      SessionEndHour < 0 || SessionEndHour > 24 ||
      BreakEvenAtR <= 0.0 || MaxSpreadPoints < 0)
   {
      Print("Invalid EA input(s); check Strategy Tester Inputs.");
      return INIT_PARAMETERS_INCORRECT;
   }

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);
   trade.SetTypeFillingBySymbol(_Symbol);
   g_atrHandle = iATR(_Symbol, EntryTF, ATRPeriod);
   if(g_atrHandle == INVALID_HANDLE)
      return INIT_FAILED;

   ResetSetup();
   g_lastBar = iTime(_Symbol, EntryTF, 0);
   g_objPrefix = "SMC_TRX_" + (string)MagicNumber + "_";
   Print("SMC research prototype initialized. Mode=", EnumToString(Strategy),
         ". It has not been verified against the full source videos.");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(g_atrHandle != INVALID_HANDLE)
      IndicatorRelease(g_atrHandle);
   ObjectsDeleteAll(0, g_objPrefix);
   Comment("");
}

bool LoadBars(ENUM_TIMEFRAMES tf, const int count, MqlRates &bars[])
{
   ArraySetAsSeries(bars, true);
   int copied = CopyRates(_Symbol, tf, 0, count, bars);
   ArraySetAsSeries(bars, true);
   return copied >= count;
}

bool IsSwing(const MqlRates &bars[], const int length,
             const int idx, const int strength, const bool highSwing)
{
   if(idx - strength < 1 || idx + strength >= length)
      return false;
   double val = highSwing ? bars[idx].high : bars[idx].low;
   for(int k = 1; k <= strength; ++k)
   {
      if(highSwing)
      {
         if(val <= bars[idx-k].high || val <= bars[idx+k].high)
            return false;
      }
      else
      {
         if(val >= bars[idx-k].low || val >= bars[idx+k].low)
            return false;
      }
   }
   return true;
}

// Returns latest *confirmed* swing. start>=2+strength prevents
// current breakout candle from redefining an older swing.
double FindSwing(const MqlRates &bars[], const int length,
                 const bool highSwing, const int start)
{
   int begin = MathMax(start, SwingStrength + 1);
   for(int i = begin; i < length - SwingStrength; ++i)
   {
      if(IsSwing(bars, length, i, SwingStrength, highSwing))
         return highSwing ? bars[i].high : bars[i].low;
   }
   return 0.0;
}

int HTFTrend()
{
   MqlRates bars[];
   const int want = MathMax(80, SwingLookback);
   if(!LoadBars(ContextTF, want, bars))
      return 0;
   double high1=0.0, high2=0.0, low1=0.0, low2=0.0;
   for(int i=SwingStrength+1; i<want-SwingStrength; ++i)
   {
      if(IsSwing(bars,want,i,SwingStrength,true))
      {
         if(high1 == 0.0) high1=bars[i].high;
         else if(high2 == 0.0) high2=bars[i].high;
      }
      if(IsSwing(bars,want,i,SwingStrength,false))
      {
         if(low1 == 0.0) low1=bars[i].low;
         else if(low2 == 0.0) low2=bars[i].low;
      }
      if(high2 != 0.0 && low2 != 0.0) break;
   }
   if(high2 == 0.0 || low2 == 0.0) return 0;
   if(high1 > high2 && low1 > low2) return 1;
   if(high1 < high2 && low1 < low2) return -1;
   return 0;
}

bool PassTrendFilter(const int direction)
{
   return !UseHTFTrendFilter || HTFTrend() == direction;
}

double ATRClosed()
{
   double b[];
   if(CopyBuffer(g_atrHandle, 0, 1, 1, b) != 1)
      return 0.0;
   return b[0];
}

bool ZoneSizeOK(const double lo, const double hi, const double atr)
{
   if(atr <= 0.0 || lo <= 0.0 || hi <= lo) return false;
   return (hi - lo) <= atr * MaxZoneSizeATR;
}

void DrawSetupZone()
{
   if(!ShowSetupZone || !g_setup.active) return;
   ObjectsDeleteAll(0, g_objPrefix);
   string name = g_objPrefix + "zone";
   int seconds = PeriodSeconds(EntryTF);
   if(seconds <= 0) seconds=300;
   datetime endTime = iTime(_Symbol,EntryTF,0) + seconds*SetupExpiryBars;
   if(!ObjectCreate(0,name,OBJ_RECTANGLE,0,
                    g_setup.timeCreated,g_setup.zoneHigh,endTime,g_setup.zoneLow))
      return;
   ObjectSetInteger(0,name,OBJPROP_COLOR,
                    g_setup.direction == 1 ? clrDodgerBlue : clrOrangeRed);
   ObjectSetInteger(0,name,OBJPROP_FILL,true);
   ObjectSetInteger(0,name,OBJPROP_BACK,true);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ChartRedraw(0);
}

void CreateSetup(const int mode, const int direction,
                 const double low, const double high,
                 const double anchor, const double trigger,
                 const datetime created)
{
   ResetSetup();
   g_setup.active=true;
   g_setup.mode=mode;
   g_setup.direction=direction;
   g_setup.zoneLow=low;
   g_setup.zoneHigh=high;
   g_setup.slAnchor=anchor;
   g_setup.breakLevel=trigger;
   g_setup.barsLeft=SetupExpiryBars;
   g_setup.timeCreated=created;
   DrawSetupZone();
   PrintFormat("SMC setup %d dir %d zone %.5f - %.5f trigger %.5f",
               mode,direction,low,high,trigger);
}

// Strategy 1: closed-candle BOS; approximate last opposite candle as OB.
bool FindBOSOrderBlock(const MqlRates &bars[], const int n, const double atr)
{
   double hh=FindSwing(bars,n,true,2+SwingStrength);
   double ll=FindSwing(bars,n,false,2+SwingStrength);
   int dir=0;
   if(hh > 0.0 && bars[2].close <= hh &&
      bars[1].close > hh + BreakBufferPoints*_Point) dir=1;
   else if(ll > 0.0 && bars[2].close >= ll &&
      bars[1].close < ll - BreakBufferPoints*_Point) dir=-1;
   if(dir == 0 || !PassTrendFilter(dir)) return false;

   int far = MathMin(OBLookbackBars+1,n-1);
   for(int i=2; i<=far; ++i)
   {
      bool opposite = (dir==1) ? (bars[i].close < bars[i].open)
                               : (bars[i].close > bars[i].open);
      if(!opposite) continue;
      if(!ZoneSizeOK(bars[i].low,bars[i].high,atr)) continue;
      CreateSetup(SMC_BOS_ORDER_BLOCK,dir,bars[i].low,bars[i].high,
                  dir==1 ? bars[i].low : bars[i].high,0.0,bars[i].time);
      return true;
   }
   return false;
}

// Strategy 2: wick sweep of a previously confirmed swing,
// then wait for a subsequent CLOSED candle to break the opposite swing.
bool FindSweepCHoCH(const MqlRates &bars[], const int n)
{
   double hh=FindSwing(bars,n,true,2+SwingStrength);
   double ll=FindSwing(bars,n,false,2+SwingStrength);
   if(hh<=0.0 || ll<=0.0) return false;

   const double buffer=SweepBufferPoints*_Point;
   if(bars[1].low < ll - buffer && bars[1].close > ll &&
      PassTrendFilter(1))
   {
      CreateSetup(SMC_SWEEP_CHOCH,1,ll,bars[1].high,
                  bars[1].low,hh,bars[1].time);
      return true;
   }
   if(bars[1].high > hh + buffer && bars[1].close < hh &&
      PassTrendFilter(-1))
   {
      CreateSetup(SMC_SWEEP_CHOCH,-1,bars[1].low,hh,
                  bars[1].high,ll,bars[1].time);
      return true;
   }
   return false;
}

// Strategy 3: 3-closed-candle FVG: bullish low[1] > high[3];
// bearish high[1] < low[3]. Requires impulsive middle candle.
bool FindFVG(const MqlRates &bars[], const int n, const double atr)
{
   if(n < 5 || atr<=0) return false;
   double body=MathAbs(bars[2].close-bars[2].open);
   if(body < atr*MinImpulseBodyATR) return false;

   if(bars[2].close > bars[2].open &&
      bars[1].low > bars[3].high && PassTrendFilter(1) &&
      ZoneSizeOK(bars[3].high,bars[1].low,atr))
   {
      CreateSetup(SMC_FVG_RETEST,1,bars[3].high,bars[1].low,
                  bars[3].high,0.0,bars[3].time);
      return true;
   }
   if(bars[2].close < bars[2].open &&
      bars[1].high < bars[3].low && PassTrendFilter(-1) &&
      ZoneSizeOK(bars[1].high,bars[3].low,atr))
   {
      CreateSetup(SMC_FVG_RETEST,-1,bars[1].high,bars[3].low,
                  bars[3].low,0.0,bars[3].time);
      return true;
   }
   return false;
}

bool OwnPositionOpen()
{
   for(int i=PositionsTotal()-1; i>=0; --i)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)==_Symbol &&
         (ulong)PositionGetInteger(POSITION_MAGIC)==MagicNumber)
         return true;
   }
   return false;
}

bool SessionOK()
{
   MqlDateTime t;
   TimeToStruct(TimeCurrent(),t);
   if(LimitToWeekdays && (t.day_of_week==0 || t.day_of_week==6))
      return false;
   if(!UseTradingSession) return true;
   if(SessionStartHour==SessionEndHour) return true;
   if(SessionStartHour<SessionEndHour)
      return t.hour>=SessionStartHour && t.hour<SessionEndHour;
   return t.hour>=SessionStartHour || t.hour<SessionEndHour;
}

double TodayPnL()
{
   datetime now=TimeCurrent();
   MqlDateTime t;
   TimeToStruct(now,t);
   t.hour=0; t.min=0; t.sec=0;
   datetime dayStart=StructToTime(t);
   double pnl=0.0;
   if(HistorySelect(dayStart,now))
   {
      for(int i=HistoryDealsTotal()-1;i>=0;--i)
      {
         ulong deal=HistoryDealGetTicket(i);
         if(deal==0) continue;
         if(HistoryDealGetString(deal,DEAL_SYMBOL)!=_Symbol ||
            (ulong)HistoryDealGetInteger(deal,DEAL_MAGIC)!=MagicNumber) continue;
         // Both entry/exit fees matter; profit on closing deals.
         pnl+=HistoryDealGetDouble(deal,DEAL_PROFIT);
         pnl+=HistoryDealGetDouble(deal,DEAL_SWAP);
         pnl+=HistoryDealGetDouble(deal,DEAL_COMMISSION);
         pnl+=HistoryDealGetDouble(deal,DEAL_FEE);
      }
   }
   for(int i=PositionsTotal()-1;i>=0;--i)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol ||
         (ulong)PositionGetInteger(POSITION_MAGIC)!=MagicNumber) continue;
      pnl+=PositionGetDouble(POSITION_PROFIT);
      pnl+=PositionGetDouble(POSITION_SWAP);
   }
   return pnl;
}

bool RiskLimitsOK()
{
   if(DailyLossLimitCash<=0.0 && DailyProfitTargetCash<=0.0)
      return true;
   double pnl=TodayPnL();
   if(DailyLossLimitCash>0.0 && pnl<=-DailyLossLimitCash) return false;
   if(DailyProfitTargetCash>0.0 && pnl>=DailyProfitTargetCash) return false;
   return true;
}

bool SpreadOK()
{
   if(MaxSpreadPoints==0) return true;
   MqlTick q;
   if(!SymbolInfoTick(_Symbol,q)) return false;
   return (q.ask-q.bid)/_Point <= MaxSpreadPoints;
}

int VolumeDigits(const double step)
{
   for(int digits=0;digits<=8;digits++)
      if(MathAbs(NormalizeDouble(step,digits)-step)<1e-10)
         return digits;
   return 8;
}

// No forced min-lot upsize: if broker's minimum risks too much, skip.
double ComputeLot(const int direction, const double entry, const double sl)
{
   double mn=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double mx=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   if(mn<=0.0 || mx<mn || step<=0.0) return 0.0;
   double raw=FixedLot;
   ENUM_ORDER_TYPE kind=(direction==1 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);

   if(UseRiskPercent)
   {
      double loss1=0.0;
      if(!OrderCalcProfit(kind,_Symbol,1.0,entry,sl,loss1) || loss1>=0)
      {
         Print("OrderCalcProfit failed for position size; no trade.");
         return 0.0;
      }
      raw=(AccountInfoDouble(ACCOUNT_BALANCE)*RiskPercent/100.0)/(-loss1);
   }
   if(raw < mn-1e-9) return 0.0;
   double lot=NormalizeDouble(MathFloor(MathMin(mx,raw)/step+1e-9)*step,
                              VolumeDigits(step));
   if(lot<mn-1e-9) return 0.0;

   double margin=0.0;
   double free=AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   while(lot>=mn-1e-9)
   {
      if(OrderCalcMargin(kind,_Symbol,lot,entry,margin) &&
         margin<=free*0.90)
         return lot;
      lot=NormalizeDouble(lot-step,VolumeDigits(step));
   }
   Print("Insufficient free margin for minimum trade volume.");
   return 0.0;
}

bool ExecuteTrade(const int direction, const double slAnchor, const int mode)
{
   if(!SessionOK() || !SpreadOK() || !RiskLimitsOK() || OwnPositionOpen())
      return false;
   MqlTick q;
   if(!SymbolInfoTick(_Symbol,q) || q.bid<=0 || q.ask<=0) return false;
   double entry=(direction==1 ? q.ask : q.bid);
   int stopPoints=(int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   int freezePoints=(int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_FREEZE_LEVEL);
   double minStop=(MathMax(stopPoints,freezePoints)+2)*_Point;
   double sl=0.0;
   if(direction==1)
      sl=MathMin(slAnchor-StopBufferPoints*_Point,q.bid-minStop);
   else
      sl=MathMax(slAnchor+StopBufferPoints*_Point,q.ask+minStop);
   sl=NormalizeDouble(sl,_Digits);
   double riskDist=MathAbs(entry-sl);
   double atr=ATRClosed();
   if(riskDist<=_Point || (atr>0 && riskDist>6.0*atr))
   {
      Print("Entry rejected: SL distance invalid / beyond 6 ATR.");
      return false;
   }
   double tp=(direction==1 ? entry+RewardRisk*riskDist
                           : entry-RewardRisk*riskDist);
   tp=NormalizeDouble(tp,_Digits);
   double lot=ComputeLot(direction,entry,sl);
   if(lot<=0)
   {
      Print("Entry rejected: lot less than min or insufficient margin.");
      return false;
   }
   string comment=(mode==SMC_BOS_ORDER_BLOCK ? "SMC BOS OB" :
                  mode==SMC_SWEEP_CHOCH ? "SMC Sweep CHoCH" : "SMC FVG");
   bool ok=(direction==1 ? trade.Buy(lot,_Symbol,0.0,sl,tp,comment)
                         : trade.Sell(lot,_Symbol,0.0,sl,tp,comment));
   uint retcode=trade.ResultRetcode();
   if(!ok || (retcode!=TRADE_RETCODE_DONE &&
              retcode!=TRADE_RETCODE_DONE_PARTIAL))
   {
      PrintFormat("Trade rejected: retcode=%u detail=%s",retcode,
                  trade.ResultRetcodeDescription());
      return false;
   }
   PrintFormat("SMC EXECUTED %s lot=%.2f entry~%.5f SL=%.5f TP=%.5f",
               direction==1 ? "BUY" : "SELL",lot,entry,sl,tp);
   return true;
}

// A break-even adjustment is independent of new-bar evaluation.
void ManageBreakEven()
{
   if(!EnableBreakEven) return;
   MqlTick q;
   if(!SymbolInfoTick(_Symbol,q)) return;
   double minDist=((int)MathMax(SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL),
                               SymbolInfoInteger(_Symbol,SYMBOL_TRADE_FREEZE_LEVEL))+2)*_Point;
   for(int i=PositionsTotal()-1;i>=0;--i)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol ||
         (ulong)PositionGetInteger(POSITION_MAGIC)!=MagicNumber) continue;
      long type=PositionGetInteger(POSITION_TYPE);
      double open=PositionGetDouble(POSITION_PRICE_OPEN);
      double sl=PositionGetDouble(POSITION_SL);
      double tp=PositionGetDouble(POSITION_TP);
      if(sl<=0) continue;
      if(type==POSITION_TYPE_BUY && sl<open)
      {
         double originalRisk=open-sl;
         double newSL=NormalizeDouble(open+BreakEvenPlusPoints*_Point,_Digits);
         if(q.bid-open>=originalRisk*BreakEvenAtR &&
            newSL<q.bid-minDist && newSL>sl)
         {
            if(!trade.PositionModify(ticket,newSL,tp))
               Print("BE modify failed: ",trade.ResultRetcodeDescription());
         }
      }
      else if(type==POSITION_TYPE_SELL && sl>open)
      {
         double originalRisk=sl-open;
         double newSL=NormalizeDouble(open-BreakEvenPlusPoints*_Point,_Digits);
         if(open-q.ask>=originalRisk*BreakEvenAtR &&
            newSL>q.ask+minDist && newSL<sl)
         {
            if(!trade.PositionModify(ticket,newSL,tp))
               Print("BE modify failed: ",trade.ResultRetcodeDescription());
         }
      }
   }
}

bool ConfirmSetupOnClosedCandle(const MqlRates &bars[])
{
   if(!g_setup.active) return false;
   const bool bull=(bars[1].close>bars[1].open);
   const bool bear=(bars[1].close<bars[1].open);
   if(g_setup.mode==SMC_SWEEP_CHOCH)
   {
      return g_setup.direction==1 ?
         (bull && bars[1].close>g_setup.breakLevel &&
          bars[2].close<=g_setup.breakLevel) :
         (bear && bars[1].close<g_setup.breakLevel &&
          bars[2].close>=g_setup.breakLevel);
   }

   bool touched=(bars[1].low<=g_setup.zoneHigh &&
                 bars[1].high>=g_setup.zoneLow);
   if(!touched) return false;
   if(g_setup.mode==SMC_BOS_ORDER_BLOCK)
      return g_setup.direction==1 ?
         (bull && bars[1].close>g_setup.zoneHigh) :
         (bear && bars[1].close<g_setup.zoneLow);
   double mid=0.5*(g_setup.zoneLow+g_setup.zoneHigh);
   return g_setup.direction==1 ? (bull && bars[1].close>mid)
                               : (bear && bars[1].close<mid);
}

void ProcessNewBar()
{
   MqlRates bars[];
   int need=MathMax(SwingLookback+2*SwingStrength+10,
                    OBLookbackBars+2*SwingStrength+30);
   if(!LoadBars(EntryTF,need,bars)) return;
   double atr=ATRClosed();
   if(atr<=0) return;

   if(g_setup.active)
   {
      g_setup.barsLeft--;
      if(g_setup.barsLeft<=0)
         ResetSetup();
      else
      {
         double invalidBuffer=StopBufferPoints*_Point;
         bool invalid=(g_setup.direction==1 ?
            bars[1].close<g_setup.slAnchor-invalidBuffer :
            bars[1].close>g_setup.slAnchor+invalidBuffer);
         if(invalid) ResetSetup();
         else if(ConfirmSetupOnClosedCandle(bars))
         {
            if(ExecuteTrade(g_setup.direction,g_setup.slAnchor,g_setup.mode))
               ResetSetup();
         }
      }
   }
   if(g_setup.active || OwnPositionOpen()) return;
   if(!SessionOK() || !RiskLimitsOK()) return;

   if(Strategy==SMC_BOS_ORDER_BLOCK || Strategy==SMC_ANY_SETUP)
      if(FindBOSOrderBlock(bars,need,atr)) return;
   if(Strategy==SMC_SWEEP_CHOCH || Strategy==SMC_ANY_SETUP)
      if(FindSweepCHoCH(bars,need)) return;
   if(Strategy==SMC_FVG_RETEST || Strategy==SMC_ANY_SETUP)
      FindFVG(bars,need,atr);
}

void OnTick()
{
   ManageBreakEven();
   datetime current=iTime(_Symbol,EntryTF,0);
   if(current==0 || current==g_lastBar) return;
   g_lastBar=current;
   ProcessNewBar();
   Comment("SMC prototype | ",EnumToString(Strategy),
           "\nSetup: ",(g_setup.active ? "WAITING RETEST / BREAK" : "NONE"),
           "\nEA position: ",(OwnPositionOpen() ? "YES" : "NO"),
           "\nToday EA PnL: ",DoubleToString(TodayPnL(),2),
           "\nSource videos' exact rules not verified");
}
//+------------------------------------------------------------------+
