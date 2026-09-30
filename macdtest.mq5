//+------------------------------------------------------------------+
//|                                                     macdtest.mq5 |
//|                                  Copyright 2025, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "1.00"
//--- Global handle
int macdHandle;

//+------------------------------------------------------------------+
//| Initialization                                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   macdHandle = iMACD(_Symbol, PERIOD_CURRENT, 12, 26, 9, PRICE_CLOSE);
   if(macdHandle == INVALID_HANDLE)
     {
      Print("Failed to create MACD handle. Error: ", GetLastError());
      return(INIT_FAILED);
     }
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| OnTick: check for MACD crossover                                 |
//+------------------------------------------------------------------+
void OnTick()
  {
   double macdBuffer[2], signalBuffer[2];

   // Copy last two values (index 1 = previous bar, 0 = current bar)
   if(CopyBuffer(macdHandle, 0, 0, 2, macdBuffer) < 0 ||
      CopyBuffer(macdHandle, 1, 0, 2, signalBuffer) < 0)
     {
      Print("Failed to copy MACD data. Error: ", GetLastError());
      return;
     }

   // Crossover logic
   bool macdCrossUp = macdBuffer[1] < signalBuffer[1] && macdBuffer[0] > signalBuffer[0];
   bool macdCrossDown = macdBuffer[1] > signalBuffer[1] && macdBuffer[0] < signalBuffer[0];

   if(macdCrossUp)
     {
      Print("MACD Crossed Up: BUY Signal");
      // Place buy order logic here
     }
   else if(macdCrossDown)
     {
      Print("MACD Crossed Down: SELL Signal");
      // Place sell order logic here
     }
  }

//+------------------------------------------------------------------+
//| Deinitialization                                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(macdHandle != INVALID_HANDLE)
      IndicatorRelease(macdHandle);
  }
