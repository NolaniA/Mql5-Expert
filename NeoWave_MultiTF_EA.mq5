//+------------------------------------------------------------------+
//|                                         NeoWave_MultiTF_EA.mq5  |
//| Independent NeoWave-inspired Wave-3 engines per timeframe       |
//+------------------------------------------------------------------+
#property strict
#property version "2.00"
#include <Trade/Trade.mqh>
CTrade trade;

struct Pivot { datetime time; double price; int type; };

input group "Independent engines"
input bool InpUseM1=true;
input bool InpUseM5=true;
input bool InpUseM15=true;
input bool InpUseM30=true;
input bool InpUseH1=true;
input bool InpUseH4=true;
input bool InpUseD1=true;

input group "Monowave pattern"
input int InpPivotStrength=3;
input int InpScanBars=300;
input int InpMinWaveBars=3;
input int InpATRPeriod=14;
input double InpMinWaveATR=1.0;
input double InpMinRetrace=0.382;
input double InpMaxRetrace=0.786;
input double InpMinTimeRatio=0.382;
input double InpMaxTimeRatio=2.618;
input double InpProjection=1.618;
input double InpMinimumRR=1.5;
input double InpStopBufferATR=0.25;
input bool InpUseOwnTFTrend=true;
input int InpTrendEMA=50;

input group "Risk"
input bool InpUseRiskSizing=true;
input double InpRiskPerTF=0.20;
input double InpFixedLot=0.01;
input int InpMaxSpreadPoints=0;
input int InpDeviationPoints=20;
input ulong InpBaseMagic=261000;
input int InpMaxTotalTradesPerDay=6;
input double InpMaxDailyLossPercent=1.0;

#define TF_COUNT 7
ENUM_TIMEFRAMES TFs[TF_COUNT]={PERIOD_M1,PERIOD_M5,PERIOD_M15,PERIOD_M30,PERIOD_H1,PERIOD_H4,PERIOD_D1};
string TFNames[TF_COUNT]={"M1","M5","M15","M30","H1","H4","D1"};
bool enabled[TF_COUNT];
int atrHandle[TF_COUNT];
int emaHandle[TF_COUNT];
datetime lastBar[TF_COUNT];
datetime lastSetup[TF_COUNT];

//+------------------------------------------------------------------+
bool ReadValue(int handle,int shift,double &value)
{
   double b[1];
   if(handle==INVALID_HANDLE || CopyBuffer(handle,0,shift,1,b)!=1) return false;
   value=b[0]; return true;
}

bool IsNewBar(int n)
{
   datetime t=iTime(_Symbol,TFs[n],0);
   if(t==0 || t==lastBar[n]) return false;
   lastBar[n]=t; return true;
}

bool PivotHigh(const MqlRates &r[],int s)
{
   for(int j=1;j<=InpPivotStrength;j++)
      if(r[s].high<=r[s-j].high || r[s].high<r[s+j].high) return false;
   return true;
}

bool PivotLow(const MqlRates &r[],int s)
{
   for(int j=1;j<=InpPivotStrength;j++)
      if(r[s].low>=r[s-j].low || r[s].low>r[s+j].low) return false;
   return true;
}

void AddPivot(Pivot &p[],Pivot &x)
{
   int n=ArraySize(p);
   if(n==0){ ArrayResize(p,1); p[0]=x; return; }
   if(p[n-1].type==x.type)
   {
      bool extreme=x.type==1 ? x.price>p[n-1].price : x.price<p[n-1].price;
      if(extreme) p[n-1]=x;
      return;
   }
   ArrayResize(p,n+1); p[n]=x;
}

bool BuildPivots(const MqlRates &r[],Pivot &p[])
{
   ArrayResize(p,0);
   int total=ArraySize(r);
   for(int s=total-InpPivotStrength-1;s>=InpPivotStrength+1;s--)
   {
      bool hi=PivotHigh(r,s), lo=PivotLow(r,s);
      if(!hi && !lo) continue;
      Pivot x; x.time=r[s].time;
      if(hi && lo){ int n=ArraySize(p); x.type=n==0?1:-p[n-1].type; }
      else x.type=hi?1:-1;
      x.price=x.type==1?r[s].high:r[s].low;
      AddPivot(p,x);
   }
   return ArraySize(p)>=3;
}

bool HasPositionForEngine(int n)
{
   bool hedging=(ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE)==ACCOUNT_MARGIN_MODE_RETAIL_HEDGING;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      if(PositionGetTicket(i)==0 || PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      ulong magic=(ulong)PositionGetInteger(POSITION_MAGIC);
      if(hedging ? magic==InpBaseMagic+(ulong)n : magic>=InpBaseMagic && magic<InpBaseMagic+TF_COUNT)
         return true;
   }
   return false;
}

datetime DayStart()
{
   MqlDateTime d; TimeToStruct(TimeCurrent(),d); d.hour=0; d.min=0; d.sec=0;
   return StructToTime(d);
}

bool DailyLimitsOK()
{
   if(!HistorySelect(DayStart(),TimeCurrent())) return false;
   int entries=0; double pnl=0;
   for(int i=0;i<HistoryDealsTotal();i++)
   {
      ulong d=HistoryDealGetTicket(i); if(d==0 || HistoryDealGetString(d,DEAL_SYMBOL)!=_Symbol) continue;
      ulong m=(ulong)HistoryDealGetInteger(d,DEAL_MAGIC);
      if(m<InpBaseMagic || m>=InpBaseMagic+TF_COUNT) continue;
      ENUM_DEAL_ENTRY e=(ENUM_DEAL_ENTRY)HistoryDealGetInteger(d,DEAL_ENTRY);
      if(e==DEAL_ENTRY_IN || e==DEAL_ENTRY_INOUT) entries++;
      if(e==DEAL_ENTRY_OUT || e==DEAL_ENTRY_OUT_BY || e==DEAL_ENTRY_INOUT)
         pnl+=HistoryDealGetDouble(d,DEAL_PROFIT)+HistoryDealGetDouble(d,DEAL_SWAP)+HistoryDealGetDouble(d,DEAL_COMMISSION);
   }
   if(InpMaxTotalTradesPerDay>0 && entries>=InpMaxTotalTradesPerDay) return false;
   double start=AccountInfoDouble(ACCOUNT_BALANCE)-pnl;
   return InpMaxDailyLossPercent<=0 || pnl>-(start*InpMaxDailyLossPercent/100.0);
}

bool TrendOK(int n,int dir)
{
   if(!InpUseOwnTFTrend) return true;
   double e1,e2; if(!ReadValue(emaHandle[n],1,e1)||!ReadValue(emaHandle[n],2,e2)) return false;
   double c=iClose(_Symbol,TFs[n],1);
   return dir==1 ? c>e1 && e1>e2 : c<e1 && e1<e2;
}

bool WaveValid(Pivot &p0,Pivot &p1,Pivot &p2,int dir,double atr,ENUM_TIMEFRAMES tf,double &w1)
{
   if(dir==1)
   {
      if(p0.type!=-1||p1.type!=1||p2.type!=-1||p2.price<=p0.price) return false;
      w1=p1.price-p0.price;
   }
   else
   {
      if(p0.type!=1||p1.type!=-1||p2.type!=1||p2.price>=p0.price) return false;
      w1=p0.price-p1.price;
   }
   if(w1<InpMinWaveATR*atr) return false;
   double correction=dir==1?p1.price-p2.price:p2.price-p1.price;
   double retrace=correction/w1;
   if(retrace<InpMinRetrace||retrace>InpMaxRetrace) return false;
   long t1=(long)(p1.time-p0.time),t2=(long)(p2.time-p1.time);
   if(t1<=0||t2<=0) return false;
   double ratio=(double)t2/(double)t1;
   int sec=PeriodSeconds(tf);
   return ratio>=InpMinTimeRatio && ratio<=InpMaxTimeRatio &&
          t1/sec>=InpMinWaveBars && t2/sec>=InpMinWaveBars;
}

double NormalizeLots(double lots)
{
   double mn=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN),mx=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double st=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   if(lots<mn) return 0; lots=MathMin(lots,mx);
   if(st>0) lots=MathFloor(lots/st+1e-9)*st;
   return NormalizeDouble(lots,8);
}

double Lots(int dir,double entry,double sl)
{
   if(!InpUseRiskSizing) return NormalizeLots(InpFixedLot);
   double loss; ENUM_ORDER_TYPE type=dir==1?ORDER_TYPE_BUY:ORDER_TYPE_SELL;
   if(!OrderCalcProfit(type,_Symbol,1.0,entry,sl,loss)||MathAbs(loss)<=0) return 0;
   return NormalizeLots(AccountInfoDouble(ACCOUNT_EQUITY)*InpRiskPerTF/100.0/MathAbs(loss));
}

void EvaluateEngine(int n)
{
   if(!enabled[n]||!IsNewBar(n)||HasPositionForEngine(n)||!DailyLimitsOK()) return;
   int need=MathMax(InpScanBars,InpPivotStrength*2+20);
   MqlRates r[]; ArraySetAsSeries(r,true);
   if(CopyRates(_Symbol,TFs[n],0,need,r)<need) return;
   double atr; if(!ReadValue(atrHandle[n],1,atr)||atr<=0) return;
   Pivot p[]; if(!BuildPivots(r,p)) return;
   int count=ArraySize(p); Pivot p0,p1,p2;
   p0=p[count-3];p1=p[count-2];p2=p[count-1];
   int dir=0; if(p0.type==-1&&p1.type==1&&p2.type==-1)dir=1;
   if(p0.type==1&&p1.type==-1&&p2.type==1)dir=-1;
   if(dir==0||p2.time==lastSetup[n]||!TrendOK(n,dir)) return;
   double w1; if(!WaveValid(p0,p1,p2,dir,atr,TFs[n],w1)) return;
   bool breakout=dir==1?r[2].close<=p1.price&&r[1].close>p1.price:r[2].close>=p1.price&&r[1].close<p1.price;
   if(!breakout) return;
   if(InpMaxSpreadPoints>0 && (SymbolInfoDouble(_Symbol,SYMBOL_ASK)-SymbolInfoDouble(_Symbol,SYMBOL_BID))/_Point>InpMaxSpreadPoints) return;
   double entry=dir==1?SymbolInfoDouble(_Symbol,SYMBOL_ASK):SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double sl=dir==1?p2.price-InpStopBufferATR*atr:p2.price+InpStopBufferATR*atr;
   double tp=dir==1?p2.price+InpProjection*w1:p2.price-InpProjection*w1;
   double minStop=(double)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL)*_Point;
   if(dir==1&&entry-sl<minStop)sl=entry-minStop;
   if(dir==-1&&sl-entry<minStop)sl=entry+minStop;
   double risk=MathAbs(entry-sl),reward=dir==1?tp-entry:entry-tp;
   if(risk<=0||reward/risk<InpMinimumRR) return;
   sl=NormalizeDouble(sl,_Digits); tp=NormalizeDouble(tp,_Digits);
   double volume=Lots(dir,entry,sl); if(volume<=0) return;
   trade.SetExpertMagicNumber(InpBaseMagic+(ulong)n);
   string comment="NeoW3 "+TFNames[n];
   bool sent=dir==1?trade.Buy(volume,_Symbol,0,sl,tp,comment):trade.Sell(volume,_Symbol,0,sl,tp,comment);
   if(sent) lastSetup[n]=p2.time; else Print(comment," failed: ",trade.ResultRetcodeDescription());
}

int OnInit()
{
   if(InpPivotStrength<1||InpScanBars<50||InpATRPeriod<2||InpTrendEMA<2||
      InpRiskPerTF<=0||InpRiskPerTF>0.25||InpMinimumRR<1.0) return INIT_PARAMETERS_INCORRECT;
   enabled[0]=InpUseM1;enabled[1]=InpUseM5;enabled[2]=InpUseM15;
   enabled[3]=InpUseM30;enabled[4]=InpUseH1;enabled[5]=InpUseH4;enabled[6]=InpUseD1;
   for(int n=0;n<TF_COUNT;n++)
   {
      atrHandle[n]=INVALID_HANDLE;emaHandle[n]=INVALID_HANDLE;lastSetup[n]=0;
      lastBar[n]=iTime(_Symbol,TFs[n],0); if(!enabled[n])continue;
      atrHandle[n]=iATR(_Symbol,TFs[n],InpATRPeriod);
      if(InpUseOwnTFTrend)emaHandle[n]=iMA(_Symbol,TFs[n],InpTrendEMA,0,MODE_EMA,PRICE_CLOSE);
      if(atrHandle[n]==INVALID_HANDLE||(InpUseOwnTFTrend&&emaHandle[n]==INVALID_HANDLE))return INIT_FAILED;
   }
   trade.SetDeviationInPoints(InpDeviationPoints);trade.SetTypeFillingBySymbol(_Symbol);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   for(int n=0;n<TF_COUNT;n++){if(atrHandle[n]!=INVALID_HANDLE)IndicatorRelease(atrHandle[n]);if(emaHandle[n]!=INVALID_HANDLE)IndicatorRelease(emaHandle[n]);}
}

void OnTick()
{
   for(int n=0;n<TF_COUNT;n++) EvaluateEngine(n);
}
//+------------------------------------------------------------------+
