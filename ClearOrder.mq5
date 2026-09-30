//+------------------------------------------------------------------+
//|                                                   ClearOrder.mq5 |
//|                                  Copyright 2025, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "1.00"

#include <ea_trade_function.mqh>
#include <Trade\Trade.mqh>
CTrade trade;



//--- INPUT PARAMETERS
input double RiskPerTrade            = 1.0; 
input double RR                      = 2.0; 
input double MaxDrawdown             = 25.0;
input int    MaxPosition             = 4;
input double StopLossPips            = 100;
input int    TailingPips             = 1500;
input double PercentTrailing         = 1;
input double LockGap                 = 0.1;      
input double ProfitStepStart         = 0.2;
input double TightenSL_Points        = 10;
input double RSI_Trend_Threshold     = 55;
input int    EMA_Period              = 50;
input ENUM_TIMEFRAMES   CalSidewayTf = PERIOD_M5;
input int    CalSidewayBar           = 20;
input int    OrderHold               = 1;


//double Sideway_high, Sideway_low;
int          prev_order      =  0;
int          prev_position   =  0;
static int   last_report_day = -1, last_report_hour = -1;
//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
//---
   
//---
   return(INIT_SUCCEEDED);
  }
//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
//---
   
  }
//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
//---
      //---CHECK DATE TIME TRADE
      if(!IsTradingSession())return;
      
      
      CheckAndDeleteOldestPending();
  }
//+------------------------------------------------------------------+
