//+------------------------------------------------------------------+
//|                    XAU_EMA_PA_BuyScalp_v1.40.mq5                 |
//| BUY-only scalping: EMA bullish regime + Price Action entry       |
//| Short individual TP, no per-position SL, equity protection       |
//+------------------------------------------------------------------+
#property version   "1.40"
#property strict

#include <Trade/Trade.mqh>
CTrade trade;

//==================================================================
// INPUTS
//==================================================================
input group "Trade Settings"
input double          LotSize                 = 0.01;
input ulong           MagicNumber             = 260913;
input ENUM_TIMEFRAMES SignalTimeframe         = PERIOD_M1;
input int             TakeProfitPoints        = 150;
input int             MaxPositions            = 3;
input int             MaxSpreadPoints         = 0;      // 0 = disable
input int             SlippagePoints          = 30;

input group "EMA Trend"
input int             FastEMAPeriod           = 9;
input int             SlowEMAPeriod           = 21;
input bool            RequireFreshCross       = false;

input group "Price Action"
input bool            UseBullishEngulfing     = true;
input bool            UseBullishPinBar        = true;
input bool            UseBullishBreakout      = true;

input double          PinBarWickBodyRatio     = 1.50;
input double          MinBodyPoints           = 20;

input int             PullbackTolerancePoints = 100;
input bool            AllowBreakoutWithoutPullback = true;

input group "Safety"
input bool            UseEquityProtection     = true;
input double          MaxDrawdownPercent      = 5.0;
input bool            StopTradingAfterGuard   = true;

input bool            UseMaxHoldingTime       = false;
input int             MaxHoldingMinutes       = 60;

input group "Diagnostics"
input bool            EnableDebugLog          = true;


//==================================================================
// GLOBALS
//==================================================================
int fastHandle = INVALID_HANDLE;
int slowHandle = INVALID_HANDLE;

datetime lastBarTime   = 0;
datetime lastStatusLog = 0;

bool tradingBlocked    = false;
bool equityGuardActive = false;
bool hedgingAccount    = false;
bool buyMode           = false;


//+------------------------------------------------------------------+
//| INIT                                                             |
//+------------------------------------------------------------------+
int OnInit()
{
   //===============================================================
   // VALIDATE INPUT
   //===============================================================
   if(LotSize <= 0.0)
   {
      Print("INIT ERROR: LotSize must be > 0");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(TakeProfitPoints <= 0)
   {
      Print("INIT ERROR: TakeProfitPoints must be > 0");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(MaxPositions < 1)
   {
      Print("INIT ERROR: MaxPositions must be >= 1");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(FastEMAPeriod < 1)
   {
      Print("INIT ERROR: FastEMAPeriod must be >= 1");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(SlowEMAPeriod <= FastEMAPeriod)
   {
      Print("INIT ERROR: SlowEMAPeriod must > FastEMAPeriod");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(PinBarWickBodyRatio <= 0.0)
   {
      Print("INIT ERROR: PinBarWickBodyRatio invalid");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(MinBodyPoints < 0.0)
   {
      Print("INIT ERROR: MinBodyPoints invalid");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(PullbackTolerancePoints < 0)
   {
      Print("INIT ERROR: PullbackTolerancePoints invalid");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(MaxSpreadPoints < 0)
   {
      Print("INIT ERROR: MaxSpreadPoints invalid");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(SlippagePoints < 0)
   {
      Print("INIT ERROR: SlippagePoints invalid");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(UseEquityProtection &&
      MaxDrawdownPercent <= 0.0)
   {
      Print("INIT ERROR: MaxDrawdownPercent invalid");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(UseMaxHoldingTime &&
      MaxHoldingMinutes <= 0)
   {
      Print("INIT ERROR: MaxHoldingMinutes invalid");
      return INIT_PARAMETERS_INCORRECT;
   }


   //===============================================================
   // SELECT SYMBOL
   //===============================================================
   if(!SymbolSelect(_Symbol, true))
   {
      Print(
         "INIT ERROR: Cannot select symbol ",
         _Symbol,
         " error=",
         GetLastError()
      );

      return INIT_FAILED;
   }


   //===============================================================
   // CREATE EMA
   //===============================================================
   fastHandle = iMA(
      _Symbol,
      SignalTimeframe,
      FastEMAPeriod,
      0,
      MODE_EMA,
      PRICE_CLOSE
   );

   slowHandle = iMA(
      _Symbol,
      SignalTimeframe,
      SlowEMAPeriod,
      0,
      MODE_EMA,
      PRICE_CLOSE
   );


   if(
      fastHandle == INVALID_HANDLE ||
      slowHandle == INVALID_HANDLE
   )
   {
      Print(
         "INIT ERROR: Cannot create EMA handles. error=",
         GetLastError()
      );

      if(fastHandle != INVALID_HANDLE)
         IndicatorRelease(fastHandle);

      if(slowHandle != INVALID_HANDLE)
         IndicatorRelease(slowHandle);

      return INIT_FAILED;
   }


   //===============================================================
   // CTRADE
   //===============================================================
   trade.SetExpertMagicNumber(MagicNumber);

   trade.SetDeviationInPoints(
      SlippagePoints
   );

   trade.SetTypeFillingBySymbol(
      _Symbol
   );

   trade.SetAsyncMode(false);


   //===============================================================
   // ACCOUNT MODE
   //===============================================================
   ENUM_ACCOUNT_MARGIN_MODE marginMode =
      (ENUM_ACCOUNT_MARGIN_MODE)
      AccountInfoInteger(
         ACCOUNT_MARGIN_MODE
      );

   hedgingAccount =
      (
         marginMode ==
         ACCOUNT_MARGIN_MODE_RETAIL_HEDGING
      );


   //===============================================================
   // RESET
   //===============================================================
   tradingBlocked    = false;
   equityGuardActive = false;

   buyMode     = false;
   lastBarTime = 0;


   //===============================================================
   // LOG
   //===============================================================
   Print("==================================================");

   Print(
      "EA READY: XAU_EMA_PA_BuyScalp v1.40"
   );

   Print(
      "BUY ONLY | TF=",
      EnumToString(SignalTimeframe),
      " FastEMA=",
      FastEMAPeriod,
      " SlowEMA=",
      SlowEMAPeriod,
      " TP=",
      TakeProfitPoints,
      " points"
   );

   Print(
      "Price Action | Engulf=",
      UseBullishEngulfing,
      " PinBar=",
      UseBullishPinBar,
      " Breakout=",
      UseBullishBreakout
   );

   Print(
      "RequireFreshCross=",
      RequireFreshCross,
      " MaxPositions=",
      MaxPositions
   );

   Print(
      "AccountMode=",
      hedgingAccount
      ? "HEDGING"
      : "NETTING/EXCHANGE"
   );

   Print("==================================================");


   return INIT_SUCCEEDED;
}


//+------------------------------------------------------------------+
//| DEINIT                                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(fastHandle != INVALID_HANDLE)
   {
      IndicatorRelease(fastHandle);
      fastHandle = INVALID_HANDLE;
   }

   if(slowHandle != INVALID_HANDLE)
   {
      IndicatorRelease(slowHandle);
      slowHandle = INVALID_HANDLE;
   }
}


//+------------------------------------------------------------------+
//| ON TICK                                                          |
//+------------------------------------------------------------------+
void OnTick()
{
   //===============================================================
   // SAFETY
   //===============================================================
   ApplyEquityProtection();

   CloseExpiredPositions();


   if(tradingBlocked)
   {
      LogStatus(
         "NO TRADE: tradingBlocked=true"
      );

      return;
   }


   if(equityGuardActive)
   {
      LogStatus(
         "NO TRADE: equity protection active"
      );

      return;
   }


   if(!TradeEnvironmentAllowed())
      return;


   //===============================================================
   // NEW BAR
   //===============================================================
   datetime currentBar =
      iTime(
         _Symbol,
         SignalTimeframe,
         0
      );


   if(currentBar <= 0)
   {
      LogStatus(
         "NO TRADE: cannot read bar time"
      );

      return;
   }


   if(currentBar == lastBarTime)
      return;


   //===============================================================
   // CHECK SETUP
   //===============================================================
   bool freshBullCross = false;

   bool trendBullish = false;

   bool paSignal = false;

   string paName = "";


   if(
      !EvaluateSetup(
         freshBullCross,
         trendBullish,
         paSignal,
         paName
      )
   )
   {
      return;
   }


   //===============================================================
   // PROCESS BAR ONLY ONCE
   //===============================================================
   lastBarTime = currentBar;


   //===============================================================
   // EMA TREND OFF
   //===============================================================
   if(!trendBullish)
   {
      buyMode = false;


      if(EnableDebugLog)
      {
         Print(
            "BUY MODE OFF: Fast EMA <= Slow EMA"
         );
      }


      return;
   }


   //===============================================================
   // EMA CROSS UP
   //===============================================================
   if(freshBullCross)
   {
      buyMode = true;


      if(EnableDebugLog)
      {
         Print(
            "EMA BULL CROSS: BUY MODE ON"
         );
      }
   }
   else
   {
      //============================================================
      // ไม่บังคับว่าต้องเป็นแท่ง crossover เท่านั้น
      // Fast EMA > Slow EMA ก็หา BUY ต่อได้
      //============================================================
      if(!RequireFreshCross)
      {
         buyMode = true;
      }
   }


   //===============================================================
   // WAIT CROSS
   //===============================================================
   if(!buyMode)
   {
      if(EnableDebugLog)
      {
         Print(
            "NO ENTRY: waiting for fresh EMA bullish cross"
         );
      }


      return;
   }


   //===============================================================
   // WAIT PRICE ACTION
   //===============================================================
   if(!paSignal)
   {
      if(EnableDebugLog)
      {
         Print(
            "NO ENTRY: EMA bullish but no bullish Price Action"
         );
      }


      return;
   }


   //===============================================================
   // MAX POSITION
   //===============================================================
   int currentPositions =
      CountMyPositions();


   int maxPositions =
      EffectiveMaxPositions();


   if(currentPositions >= maxPositions)
   {
      if(EnableDebugLog)
      {
         Print(
            "NO ENTRY: MaxPositions reached | current=",
            currentPositions,
            " max=",
            maxPositions
         );
      }


      return;
   }


   //===============================================================
   // SPREAD
   //===============================================================
   if(!SpreadIsAllowed())
      return;


   //===============================================================
   // BUY
   //===============================================================
   if(EnableDebugLog)
   {
      Print(
         "BUY SETUP: EMA bullish + PA=",
         paName
      );
   }


   OpenBuy(paName);
}


//+------------------------------------------------------------------+
//| CHECK EMA + PRICE ACTION                                         |
//+------------------------------------------------------------------+
bool EvaluateSetup(
   bool &freshBullCross,
   bool &trendBullish,
   bool &paSignal,
   string &paName
)
{
   freshBullCross = false;

   trendBullish = false;

   paSignal = false;

   paName = "";


   //===============================================================
   // CHECK HANDLE
   //===============================================================
   if(
      fastHandle == INVALID_HANDLE ||
      slowHandle == INVALID_HANDLE
   )
   {
      LogStatus(
         "DATA ERROR: invalid EMA handle"
      );

      return false;
   }


   //===============================================================
   // CHECK INDICATOR DATA
   //===============================================================
   if(
      BarsCalculated(fastHandle) < 3 ||
      BarsCalculated(slowHandle) < 3
   )
   {
      LogStatus(
         "DATA WAIT: EMA not ready"
      );

      return false;
   }


   //===============================================================
   // BUFFER
   //===============================================================
   double fast[2];

   double slow[2];

   MqlRates rates[3];


   ResetLastError();


   //===============================================================
   // EMA
   //
   // start = 1
   //
   // Fast[0] = shift 2
   // Fast[1] = shift 1
   //===============================================================
   int fastCopied =
      CopyBuffer(
         fastHandle,
         0,
         1,
         2,
         fast
      );


   int slowCopied =
      CopyBuffer(
         slowHandle,
         0,
         1,
         2,
         slow
      );


   //===============================================================
   // CANDLE
   //
   // rates[0] = shift 3
   // rates[1] = shift 2
   // rates[2] = shift 1
   //===============================================================
   int rateCopied =
      CopyRates(
         _Symbol,
         SignalTimeframe,
         1,
         3,
         rates
      );


   if(
      fastCopied != 2 ||
      slowCopied != 2 ||
      rateCopied != 3
   )
   {
      LogStatus(
         StringFormat(
            "DATA ERROR: Copy failed | fast=%d slow=%d rates=%d error=%d",
            fastCopied,
            slowCopied,
            rateCopied,
            GetLastError()
         )
      );


      return false;
   }


   //===============================================================
   // EMA VALUE
   //===============================================================
   double fastPrev = fast[0];

   double fastNow = fast[1];


   double slowPrev = slow[0];

   double slowNow = slow[1];


   //===============================================================
   // CANDLE
   //===============================================================
   MqlRates prev =
      rates[1];


   MqlRates now =
      rates[2];


   //===============================================================
   // TREND
   //===============================================================
   trendBullish =
      fastNow > slowNow;


   //===============================================================
   // EMA CROSS UP
   //
   // Previous:
   // EMA Fast <= EMA Slow
   //
   // Current closed candle:
   // EMA Fast > EMA Slow
   //===============================================================
   freshBullCross =
      (
         fastPrev <= slowPrev &&
         fastNow > slowNow
      );


   //===============================================================
   // PRICE ACTION
   //===============================================================
   bool engulf = false;

   bool pinbar = false;

   bool breakout = false;


   if(UseBullishEngulfing)
   {
      engulf =
         IsBullishEngulfing(
            now,
            prev
         );
   }


   if(UseBullishPinBar)
   {
      pinbar =
         IsBullishPinBar(
            now
         );
   }


   if(UseBullishBreakout)
   {
      breakout =
         IsBullishBreakout(
            now,
            prev
         );
   }


   //===============================================================
   // CHECK PULLBACK TO EMA FAST
   //===============================================================
   bool nearFastEMA = true;


   if(PullbackTolerancePoints > 0)
   {
      double tolerance =
         PullbackTolerancePoints *
         _Point;


      nearFastEMA =
         (
            now.low <=
            fastNow + tolerance
            &&
            now.high >=
            fastNow - tolerance
         );
   }


   //===============================================================
   // ENGULF / PIN BAR
   //
   // ต้องอยู่ใกล้ EMA
   //===============================================================
   bool paPullbackSignal =
      (
         nearFastEMA &&
         (
            engulf ||
            pinbar
         )
      );


   //===============================================================
   // BREAKOUT
   //===============================================================
   bool paBreakoutSignal =
      (
         breakout &&
         (
            AllowBreakoutWithoutPullback ||
            nearFastEMA
         )
      );


   //===============================================================
   // FINAL PA
   //===============================================================
   paSignal =
      (
         trendBullish &&
         (
            paPullbackSignal ||
            paBreakoutSignal
         )
      );


   //===============================================================
   // PRICE ACTION NAME
   //===============================================================
   if(paSignal)
   {
      if(
         engulf &&
         nearFastEMA
      )
      {
         paName =
            "Bullish Engulfing";
      }
      else
      if(
         pinbar &&
         nearFastEMA
      )
      {
         paName =
            "Bullish Pin Bar";
      }
      else
      if(breakout)
      {
         paName =
            "Bullish Breakout";
      }
      else
      {
         paName =
            "Bullish PA";
      }
   }


   //===============================================================
   // DEBUG
   //===============================================================
   if(EnableDebugLog)
   {
      Print(
         "SETUP CHECK | time=",
         TimeToString(
            now.time,
            TIME_DATE |
            TIME_MINUTES
         ),

         " FastNow=",
         DoubleToString(
            fastNow,
            _Digits
         ),

         " SlowNow=",
         DoubleToString(
            slowNow,
            _Digits
         ),

         " FreshCross=",
         freshBullCross,

         " TrendBull=",
         trendBullish,

         " NearEMA=",
         nearFastEMA,

         " Engulf=",
         engulf,

         " Pin=",
         pinbar,

         " Breakout=",
         breakout,

         " PA=",
         paSignal
      );
   }


   return true;
}


//+------------------------------------------------------------------+
//| BULLISH ENGULFING                                                |
//+------------------------------------------------------------------+
bool IsBullishEngulfing(
   const MqlRates &now,
   const MqlRates &prev
)
{
   //===============================================================
   // BODY SIZE
   //===============================================================
   double bodyPoints =
      MathAbs(
         now.close -
         now.open
      )
      /
      _Point;


   if(bodyPoints < MinBodyPoints)
      return false;


   //===============================================================
   // CURRENT = BULLISH
   //===============================================================
   bool nowBull =
      now.close >
      now.open;


   //===============================================================
   // PREVIOUS = BEARISH
   //===============================================================
   bool prevBear =
      prev.close <
      prev.open;


   if(
      !nowBull ||
      !prevBear
   )
   {
      return false;
   }


   //===============================================================
   // ENGULF PREVIOUS BODY
   //===============================================================
   bool engulf =
      (
         now.open <=
         prev.close
         &&
         now.close >=
         prev.open
      );


   return engulf;
}


//+------------------------------------------------------------------+
//| BULLISH PIN BAR                                                  |
//+------------------------------------------------------------------+
bool IsBullishPinBar(
   const MqlRates &bar
)
{
   //===============================================================
   // BODY
   //===============================================================
   double body =
      MathAbs(
         bar.close -
         bar.open
      );


   //===============================================================
   // LOWER WICK
   //===============================================================
   double lowerWick =
      MathMin(
         bar.open,
         bar.close
      )
      -
      bar.low;


   //===============================================================
   // UPPER WICK
   //===============================================================
   double upperWick =
      bar.high
      -
      MathMax(
         bar.open,
         bar.close
      );


   //===============================================================
   // RANGE
   //===============================================================
   double range =
      bar.high -
      bar.low;


   if(range <= 0.0)
      return false;


   //===============================================================
   // MIN BODY
   //===============================================================
   if(
      body / _Point <
      MinBodyPoints
   )
   {
      return false;
   }


   //===============================================================
   // PREVENT ZERO
   //===============================================================
   double safeBody =
      MathMax(
         body,
         _Point
      );


   //===============================================================
   // LONG LOWER WICK
   //===============================================================
   bool strongLowerWick =
      lowerWick >=
      safeBody *
      PinBarWickBodyRatio;


   //===============================================================
   // LOWER WICK > UPPER
   //===============================================================
   bool lowerDominates =
      lowerWick >
      upperWick;


   //===============================================================
   // CLOSE UPPER 40%
   //===============================================================
   bool closesHigh =
      bar.close >=
      (
         bar.low +
         range * 0.60
      );


   //===============================================================
   // BULLISH CLOSE
   //===============================================================
   bool bullishClose =
      bar.close >
      bar.open;


   return (
      strongLowerWick &&
      lowerDominates &&
      closesHigh &&
      bullishClose
   );
}


//+------------------------------------------------------------------+
//| BULLISH BREAKOUT                                                 |
//+------------------------------------------------------------------+
bool IsBullishBreakout(
   const MqlRates &now,
   const MqlRates &prev
)
{
   //===============================================================
   // BODY
   //===============================================================
   double bodyPoints =
      MathAbs(
         now.close -
         now.open
      )
      /
      _Point;


   if(bodyPoints < MinBodyPoints)
      return false;


   //===============================================================
   // CURRENT BULLISH
   // AND CLOSE > PREVIOUS HIGH
   //===============================================================
   return (
      now.close >
      now.open
      &&
      now.close >
      prev.high
   );
}


//+------------------------------------------------------------------+
//| OPEN BUY                                                         |
//+------------------------------------------------------------------+
bool OpenBuy(
   string setupName
)
{
   //===============================================================
   // GET TICK
   //===============================================================
   MqlTick tick;


   if(
      !SymbolInfoTick(
         _Symbol,
         tick
      )
   )
   {
      Print(
         "BUY ERROR: cannot read tick"
      );

      return false;
   }


   if(
      tick.ask <= 0.0 ||
      tick.bid <= 0.0
   )
   {
      Print(
         "BUY ERROR: invalid tick"
      );

      return false;
   }


   //===============================================================
   // VOLUME
   //===============================================================
   double volume =
      NormalizeVolume(
         LotSize
      );


   if(volume <= 0.0)
   {
      Print(
         "BUY ERROR: invalid volume"
      );

      return false;
   }


   //===============================================================
   // TP
   //===============================================================
   double tp =
      CalculateBuyTP(
         tick
      );


   if(tp <= tick.bid)
   {
      Print(
         "BUY ERROR: invalid TP | bid=",
         DoubleToString(
            tick.bid,
            _Digits
         ),
         " tp=",
         DoubleToString(
            tp,
            _Digits
         )
      );


      return false;
   }


   //===============================================================
   // SEND BUY
   //===============================================================
   ResetLastError();


   bool requestOK =
      trade.Buy(
         volume,
         _Symbol,
         0.0,
         0.0,     // NO STOP LOSS
         tp,
         "EMA+PA BUY"
      );


   uint retcode =
      trade.ResultRetcode();


   //===============================================================
   // CHECK RESULT
   //===============================================================
   if(
      !requestOK ||
      !TradeRetcodeSuccessful(
         retcode
      )
   )
   {
      PrintTradeFailure(
         "BUY",
         requestOK
      );


      return false;
   }


   //===============================================================
   // SUCCESS
   //===============================================================
   Print(
      "BUY OPENED | setup=",
      setupName,

      " deal=",
      trade.ResultDeal(),

      " order=",
      trade.ResultOrder(),

      " volume=",
      DoubleToString(
         trade.ResultVolume(),
         2
      ),

      " price=",
      DoubleToString(
         trade.ResultPrice(),
         _Digits
      ),

      " tp=",
      DoubleToString(
         tp,
         _Digits
      ),

      " retcode=",
      retcode,

      " ",
      trade.ResultRetcodeDescription()
   );


   return true;
}


//+------------------------------------------------------------------+
//| CALCULATE BUY TP                                                 |
//+------------------------------------------------------------------+
double CalculateBuyTP(
   const MqlTick &tick
)
{
   //===============================================================
   // BROKER STOP LEVEL
   //===============================================================
   int stopsLevel =
      (int)
      SymbolInfoInteger(
         _Symbol,
         SYMBOL_TRADE_STOPS_LEVEL
      );


   //===============================================================
   // REQUEST TP
   //===============================================================
   double requestedTP =
      tick.ask +
      TakeProfitPoints *
      _Point;


   //===============================================================
   // MINIMUM TP ALLOWED
   //===============================================================
   double minimumTP =
      tick.bid +
      (
         stopsLevel + 1
      )
      *
      _Point;


   //===============================================================
   // USE FURTHEST
   //===============================================================
   double tp =
      MathMax(
         requestedTP,
         minimumTP
      );


   return NormalizePriceUp(
      tp
   );
}


//+------------------------------------------------------------------+
//| NORMALIZE PRICE                                                  |
//+------------------------------------------------------------------+
double NormalizePriceUp(
   double price
)
{
   double tickSize =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_TRADE_TICK_SIZE
      );


   if(tickSize <= 0.0)
   {
      tickSize = _Point;
   }


   double steps =
      MathCeil(
         (
            price /
            tickSize
         )
         -
         1e-10
      );


   double result =
      steps *
      tickSize;


   return NormalizeDouble(
      result,
      _Digits
   );
}


//+------------------------------------------------------------------+
//| COUNT EA POSITIONS                                               |
//+------------------------------------------------------------------+
int CountMyPositions()
{
   int count = 0;


   for(
      int i = PositionsTotal() - 1;
      i >= 0;
      i--
   )
   {
      ulong ticket =
         PositionGetTicket(
            i
         );


      if(ticket == 0)
         continue;


      if(
         PositionGetString(
            POSITION_SYMBOL
         )
         !=
         _Symbol
      )
      {
         continue;
      }


      if(
         (ulong)
         PositionGetInteger(
            POSITION_MAGIC
         )
         !=
         MagicNumber
      )
      {
         continue;
      }


      count++;
   }


   return count;
}


//+------------------------------------------------------------------+
//| EFFECTIVE MAX POSITION                                           |
//+------------------------------------------------------------------+
int EffectiveMaxPositions()
{
   //===============================================================
   // NETTING = ONE POSITION PER SYMBOL
   //===============================================================
   if(!hedgingAccount)
   {
      return 1;
   }


   return MaxPositions;
}


//+------------------------------------------------------------------+
//| SPREAD FILTER                                                    |
//+------------------------------------------------------------------+
bool SpreadIsAllowed()
{
   //===============================================================
   // DISABLED
   //===============================================================
   if(MaxSpreadPoints <= 0)
      return true;


   MqlTick tick;


   if(
      !SymbolInfoTick(
         _Symbol,
         tick
      )
   )
   {
      Print(
         "NO TRADE: cannot read spread"
      );


      return false;
   }


   if(
      tick.ask <= 0 ||
      tick.bid <= 0
   )
   {
      return false;
   }


   //===============================================================
   // SPREAD POINT
   //===============================================================
   double spreadPoints =
      (
         tick.ask -
         tick.bid
      )
      /
      _Point;


   //===============================================================
   // TOO HIGH
   //===============================================================
   if(
      spreadPoints >
      MaxSpreadPoints
   )
   {
      if(EnableDebugLog)
      {
         Print(
            "NO TRADE: spread=",
            DoubleToString(
               spreadPoints,
               1
            ),
            " > max=",
            MaxSpreadPoints
         );
      }


      return false;
   }


   return true;
}


//+------------------------------------------------------------------+
//| NORMALIZE VOLUME                                                 |
//+------------------------------------------------------------------+
double NormalizeVolume(
   double requestedVolume
)
{
   //===============================================================
   // SYMBOL VOLUME
   //===============================================================
   double minLot =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_VOLUME_MIN
      );


   double maxLot =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_VOLUME_MAX
      );


   double step =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_VOLUME_STEP
      );


   if(
      minLot <= 0.0 ||
      maxLot <= 0.0
   )
   {
      return 0.0;
   }


   //===============================================================
   // LIMIT
   //===============================================================
   double volume =
      MathMax(
         minLot,
         MathMin(
            maxLot,
            requestedVolume
         )
      );


   //===============================================================
   // STEP
   //===============================================================
   if(step > 0.0)
   {
      double steps =
         MathFloor(
            (
               (
                  volume -
                  minLot
               )
               /
               step
            )
            +
            1e-9
         );


      volume =
         minLot +
         steps *
         step;
   }


   volume =
      MathMax(
         minLot,
         MathMin(
            maxLot,
            volume
         )
      );


   return NormalizeDouble(
      volume,
      8
   );
}


//+------------------------------------------------------------------+
//| CHECK TRADING ENVIRONMENT                                        |
//+------------------------------------------------------------------+
bool TradeEnvironmentAllowed()
{
   //===============================================================
   // TERMINAL
   //===============================================================
   if(
      !TerminalInfoInteger(
         TERMINAL_TRADE_ALLOWED
      )
   )
   {
      LogStatus(
         "NO TRADE: Algo Trading disabled"
      );


      return false;
   }


   //===============================================================
   // EA
   //===============================================================
   if(
      !MQLInfoInteger(
         MQL_TRADE_ALLOWED
      )
   )
   {
      LogStatus(
         "NO TRADE: EA trading permission disabled"
      );


      return false;
   }


   //===============================================================
   // ACCOUNT
   //===============================================================
   if(
      !AccountInfoInteger(
         ACCOUNT_TRADE_ALLOWED
      )
   )
   {
      LogStatus(
         "NO TRADE: account trading disabled"
      );


      return false;
   }


   //===============================================================
   // EXPERT
   //===============================================================
   if(
      !AccountInfoInteger(
         ACCOUNT_TRADE_EXPERT
      )
   )
   {
      LogStatus(
         "NO TRADE: Expert trading disabled"
      );


      return false;
   }


   //===============================================================
   // SYMBOL TRADE MODE
   //===============================================================
   ENUM_SYMBOL_TRADE_MODE mode =
      (ENUM_SYMBOL_TRADE_MODE)
      SymbolInfoInteger(
         _Symbol,
         SYMBOL_TRADE_MODE
      );


   //===============================================================
   // BUY NOT ALLOWED
   //===============================================================
   if(
      mode ==
      SYMBOL_TRADE_MODE_DISABLED
      ||
      mode ==
      SYMBOL_TRADE_MODE_CLOSEONLY
      ||
      mode ==
      SYMBOL_TRADE_MODE_SHORTONLY
   )
   {
      LogStatus(
         "NO TRADE: symbol does not allow BUY"
      );


      return false;
   }


   return true;
}


//+------------------------------------------------------------------+
//| EQUITY PROTECTION                                                |
//+------------------------------------------------------------------+
void ApplyEquityProtection()
{
   //===============================================================
   // DISABLED
   //===============================================================
   if(!UseEquityProtection)
      return;


   if(tradingBlocked)
      return;


   //===============================================================
   // ACCOUNT
   //===============================================================
   double balance =
      AccountInfoDouble(
         ACCOUNT_BALANCE
      );


   double equity =
      AccountInfoDouble(
         ACCOUNT_EQUITY
      );


   if(balance <= 0.0)
      return;


   //===============================================================
   // DRAWDOWN %
   //===============================================================
   double drawdown =
      (
         balance -
         equity
      )
      /
      balance
      *
      100.0;


   //===============================================================
   // TRIGGER
   //===============================================================
   if(
      drawdown >=
      MaxDrawdownPercent
   )
   {
      if(!equityGuardActive)
      {
         Print(
            "EQUITY GUARD | DD=",
            DoubleToString(
               drawdown,
               2
            ),
            "% limit=",
            DoubleToString(
               MaxDrawdownPercent,
               2
            ),
            "%"
         );
      }


      equityGuardActive = true;


      //============================================================
      // CLOSE EA POSITIONS
      //============================================================
      CloseAllMyPositions(
         "EQUITY GUARD"
      );


      //============================================================
      // BLOCK EA
      //============================================================
      if(StopTradingAfterGuard)
      {
         tradingBlocked = true;


         Print(
            "TRADING BLOCKED until EA reinitialization"
         );
      }


      return;
   }


   //===============================================================
   // RELEASE GUARD
   //===============================================================
   if(
      equityGuardActive &&
      !StopTradingAfterGuard
   )
   {
      equityGuardActive = false;


      Print(
         "EQUITY GUARD RELEASED"
      );
   }
}


//+------------------------------------------------------------------+
//| CLOSE MAX HOLDING                                                |
//+------------------------------------------------------------------+
void CloseExpiredPositions()
{
   //===============================================================
   // DISABLED
   //===============================================================
   if(
      !UseMaxHoldingTime ||
      MaxHoldingMinutes <= 0
   )
   {
      return;
   }


   datetime now =
      TimeCurrent();


   //===============================================================
   // LOOP POSITIONS
   //===============================================================
   for(
      int i = PositionsTotal() - 1;
      i >= 0;
      i--
   )
   {
      ulong ticket =
         PositionGetTicket(
            i
         );


      if(ticket == 0)
         continue;


      //============================================================
      // SYMBOL
      //============================================================
      if(
         PositionGetString(
            POSITION_SYMBOL
         )
         !=
         _Symbol
      )
      {
         continue;
      }


      //============================================================
      // MAGIC
      //============================================================
      if(
         (ulong)
         PositionGetInteger(
            POSITION_MAGIC
         )
         !=
         MagicNumber
      )
      {
         continue;
      }


      //============================================================
      // OPEN TIME
      //============================================================
      datetime openTime =
         (datetime)
         PositionGetInteger(
            POSITION_TIME
         );


      //============================================================
      // NOT EXPIRED
      //============================================================
      if(
         (long)
         (
            now -
            openTime
         )
         <
         (long)
         MaxHoldingMinutes *
         60
      )
      {
         continue;
      }


      //============================================================
      // CLOSE
      //============================================================
      ClosePositionByTicket(
         ticket,
         "MAX HOLDING TIME"
      );
   }
}


//+------------------------------------------------------------------+
//| CLOSE ALL                                                        |
//+------------------------------------------------------------------+
void CloseAllMyPositions(
   string reason
)
{
   for(
      int i = PositionsTotal() - 1;
      i >= 0;
      i--
   )
   {
      ulong ticket =
         PositionGetTicket(
            i
         );


      if(ticket == 0)
         continue;


      //============================================================
      // SYMBOL
      //============================================================
      if(
         PositionGetString(
            POSITION_SYMBOL
         )
         !=
         _Symbol
      )
      {
         continue;
      }


      //============================================================
      // MAGIC
      //============================================================
      if(
         (ulong)
         PositionGetInteger(
            POSITION_MAGIC
         )
         !=
         MagicNumber
      )
      {
         continue;
      }


      //============================================================
      // CLOSE
      //============================================================
      ClosePositionByTicket(
         ticket,
         reason
      );
   }
}


//+------------------------------------------------------------------+
//| CLOSE POSITION                                                   |
//+------------------------------------------------------------------+
bool ClosePositionByTicket(
   ulong ticket,
   string reason
)
{
   ResetLastError();


   bool requestOK =
      trade.PositionClose(
         ticket
      );


   uint retcode =
      trade.ResultRetcode();


   //===============================================================
   // FAILED
   //===============================================================
   if(
      !requestOK ||
      !TradeRetcodeSuccessful(
         retcode
      )
   )
   {
      Print(
         "CLOSE ERROR | ticket=",
         ticket,
         " reason=",
         reason,
         " retcode=",
         retcode,
         " ",
         trade.ResultRetcodeDescription(),
         " lastError=",
         GetLastError()
      );


      return false;
   }


   //===============================================================
   // SUCCESS
   //===============================================================
   Print(
      "POSITION CLOSED | ticket=",
      ticket,
      " reason=",
      reason
   );


   return true;
}


//+------------------------------------------------------------------+
//| CHECK TRADE RESULT                                               |
//+------------------------------------------------------------------+
bool TradeRetcodeSuccessful(
   uint retcode
)
{
   return (
      retcode ==
      TRADE_RETCODE_DONE
      ||
      retcode ==
      TRADE_RETCODE_DONE_PARTIAL
      ||
      retcode ==
      TRADE_RETCODE_PLACED
   );
}


//+------------------------------------------------------------------+
//| PRINT TRADE ERROR                                                |
//+------------------------------------------------------------------+
void PrintTradeFailure(
   string side,
   bool requestOK
)
{
   Print(
      side,

      " FAILED | requestOK=",
      requestOK,

      " retcode=",
      trade.ResultRetcode(),

      " description=",
      trade.ResultRetcodeDescription(),

      " brokerComment=",
      trade.ResultComment(),

      " bid=",
      DoubleToString(
         trade.ResultBid(),
         _Digits
      ),

      " ask=",
      DoubleToString(
         trade.ResultAsk(),
         _Digits
      ),

      " lastError=",
      GetLastError()
   );
}


//+------------------------------------------------------------------+
//| LOG                                                              |
//+------------------------------------------------------------------+
void LogStatus(
   string message
)
{
   if(!EnableDebugLog)
      return;


   datetime now =
      TimeCurrent();


   //===============================================================
   // PREVENT JOURNAL SPAM
   //===============================================================
   if(
      now == 0 ||
      lastStatusLog == 0 ||
      now - lastStatusLog >= 10
   )
   {
      Print(
         message
      );


      lastStatusLog =
         now;
   }
}
//+------------------------------------------------------------------+