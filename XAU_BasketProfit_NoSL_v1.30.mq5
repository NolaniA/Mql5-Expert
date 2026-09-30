//+------------------------------------------------------------------+
//|                              XAU_BasketProfit_NoSL_v1.30.mq5           |
//|  Basket-profit EA: keep adding EMA entries until basket profits |
//|  No SL. Closes all EA positions when basket target is reached.   |
//+------------------------------------------------------------------+
#property version   "1.30"
#property strict

#include <Trade/Trade.mqh>
CTrade trade;

//==================================================================
// INPUTS
//==================================================================
input group "Trade Settings"
input double          LotSize                  = 0.01;
input ulong           MagicNumber              = 260913;
input ENUM_TIMEFRAMES SignalTimeframe          = PERIOD_M1;
input int             MaxPositions             = 0;     // 0 = unlimited (hedging)
input int             MaxSpreadPoints          = 0;     // 0 = disable filter
input int             SlippagePoints           = 30;

input group "Basket Profit"
input double          BasketProfitTargetMoney  = 1.00;  // account currency
input bool            UseIndividualTP          = false; // false = basket close only
input int             TakeProfitPoints         = 150;   // used only when UseIndividualTP=true

input group "Entry Signal"
input int             FastEMAPeriod           = 9;
input int             SlowEMAPeriod           = 21;
input bool            RequireCandleConfirm    = false;

input group "Safety (no position SL)"
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
int      fastHandle       = INVALID_HANDLE;
int      slowHandle       = INVALID_HANDLE;
datetime lastBarTime      = 0;
datetime lastStatusLog    = 0;

bool     tradingBlocked   = false;
bool     equityGuardActive = false;
bool     hedgingAccount   = false;

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- Validate inputs
   if(LotSize <= 0.0)
   {
      Print("INIT ERROR: LotSize must be > 0");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(UseIndividualTP && TakeProfitPoints <= 0)
   {
      Print("INIT ERROR: TakeProfitPoints must be > 0 when UseIndividualTP=true");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(MaxPositions < 0)
   {
      Print("INIT ERROR: MaxPositions cannot be negative");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(BasketProfitTargetMoney <= 0.0)
   {
      Print("INIT ERROR: BasketProfitTargetMoney must be > 0");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(FastEMAPeriod < 1 || SlowEMAPeriod <= FastEMAPeriod)
   {
      Print("INIT ERROR: Require SlowEMAPeriod > FastEMAPeriod >= 1");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(MaxSpreadPoints < 0 || SlippagePoints < 0)
   {
      Print("INIT ERROR: Spread/slippage values cannot be negative");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(UseEquityProtection && MaxDrawdownPercent <= 0.0)
   {
      Print("INIT ERROR: MaxDrawdownPercent must be > 0");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(UseMaxHoldingTime && MaxHoldingMinutes <= 0)
   {
      Print("INIT ERROR: MaxHoldingMinutes must be > 0");
      return INIT_PARAMETERS_INCORRECT;
   }

   //--- Ensure current symbol is selected
   if(!SymbolSelect(_Symbol, true))
   {
      Print("INIT ERROR: Cannot select symbol ", _Symbol,
            " | error=", GetLastError());
      return INIT_FAILED;
   }

   //--- Create indicator handles
   fastHandle = iMA(_Symbol,
                    SignalTimeframe,
                    FastEMAPeriod,
                    0,
                    MODE_EMA,
                    PRICE_CLOSE);

   slowHandle = iMA(_Symbol,
                    SignalTimeframe,
                    SlowEMAPeriod,
                    0,
                    MODE_EMA,
                    PRICE_CLOSE);

   if(fastHandle == INVALID_HANDLE || slowHandle == INVALID_HANDLE)
   {
      Print("INIT ERROR: Cannot create EMA handles | error=", GetLastError());

      if(fastHandle != INVALID_HANDLE)
         IndicatorRelease(fastHandle);

      if(slowHandle != INVALID_HANDLE)
         IndicatorRelease(slowHandle);

      return INIT_FAILED;
   }

   //--- Trade configuration
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetAsyncMode(false);

   //--- Detect account position mode
   ENUM_ACCOUNT_MARGIN_MODE marginMode =
      (ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE);

   hedgingAccount = (marginMode == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING);

   tradingBlocked    = false;
   equityGuardActive = false;
   lastBarTime       = 0;

   Print("==================================================");
   Print("EA READY: XAU_BasketProfit_NoSL v1.30");
   Print("Symbol=", _Symbol,
         " | TF=", EnumToString(SignalTimeframe),
         " | FastEMA=", FastEMAPeriod,
         " | SlowEMA=", SlowEMAPeriod,
         " | BasketTarget=", DoubleToString(BasketProfitTargetMoney, 2),
         " | IndividualTP=", UseIndividualTP ? "ON" : "OFF");
   Print("Account mode=", hedgingAccount ? "HEDGING" : "NETTING/EXCHANGE");
   Print("Point=", DoubleToString(_Point, _Digits),
         " | TickSize=", DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE), _Digits),
         " | StopsLevel=", (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL));

   if(!hedgingAccount)
   {
      Print("INFO: NETTING/EXCHANGE account.");
      Print("Repeated entries will add/reduce/reverse the single symbol position.");
      Print("MaxPositions is only enforced on HEDGING accounts.");
   }

   Print("==================================================");

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
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
//| Expert tick                                                      |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- Safety management runs on every tick
   ApplyEquityProtection();
   CloseExpiredPositions();

   if(tradingBlocked)
   {
      LogStatus("NO TRADE: tradingBlocked=true");
      return;
   }

   if(equityGuardActive)
   {
      LogStatus("NO TRADE: equity protection is active");
      return;
   }

   if(!TradeEnvironmentAllowed())
      return;

   //===============================================================
   // BASKET EXIT
   // Close ALL EA positions as soon as the combined floating
   // profit reaches the requested money target.
   //===============================================================
   int    positionCount = CountMyPositions();
   double basketProfit  = GetMyBasketProfit();

   if(positionCount > 0 && basketProfit >= BasketProfitTargetMoney)
   {
      Print("BASKET TARGET HIT | positions=", positionCount,
            " profit=", DoubleToString(basketProfit, 2),
            " target=", DoubleToString(BasketProfitTargetMoney, 2));

      CloseAllMyPositions("BASKET PROFIT");

      // Do not immediately reopen on the same tick.
      return;
   }

   //===============================================================
   // ENTRY
   // Keep adding a new entry on every new signal bar while the
   // basket has not yet reached the profit target.
   //===============================================================
   datetime currentBar = iTime(_Symbol, SignalTimeframe, 0);

   if(currentBar <= 0)
   {
      LogStatus("NO TRADE: cannot read current bar time");
      return;
   }

   if(currentBar == lastBarTime)
      return;

   int signal = 0;

   // If data are not ready, retry during this same bar.
   if(!GetEntrySignal(signal))
      return;

   lastBarTime = currentBar;

   if(signal == 0)
   {
      if(EnableDebugLog)
         Print("NO ENTRY: no EMA signal | basketProfit=",
               DoubleToString(basketProfit, 2));
      return;
   }

   // MaxPositions = 0 means unlimited.
   // Position count is meaningful for separate positions only
   // on HEDGING accounts. Netting accounts keep one symbol position.
   if(hedgingAccount &&
      MaxPositions > 0 &&
      positionCount >= MaxPositions)
   {
      if(EnableDebugLog)
         Print("NO ENTRY: MaxPositions reached | current=",
               positionCount,
               " max=", MaxPositions,
               " basketProfit=", DoubleToString(basketProfit, 2));
      return;
   }

   if(!SpreadIsAllowed())
      return;

   if(!DirectionAllowed(signal))
      return;

   if(EnableDebugLog)
   {
      Print("BASKET STATUS | positions=", positionCount,
            " profit=", DoubleToString(basketProfit, 2),
            " target=", DoubleToString(BasketProfitTargetMoney, 2),
            " | adding next entry");
   }

   if(signal == 1)
   {
      if(EnableDebugLog)
         Print("ENTRY SIGNAL: BUY");

      OpenBuy();
   }
   else if(signal == -1)
   {
      if(EnableDebugLog)
         Print("ENTRY SIGNAL: SELL");

      OpenSell();
   }
}

//+------------------------------------------------------------------+
//| Read the CLOSED candle directly: shift = 1                       |
//+------------------------------------------------------------------+
bool GetEntrySignal(int &signal)
{
   signal = 0;

   if(fastHandle == INVALID_HANDLE || slowHandle == INVALID_HANDLE)
   {
      LogStatus("DATA ERROR: invalid EMA handle");
      return false;
   }

   int fastBars = BarsCalculated(fastHandle);
   int slowBars = BarsCalculated(slowHandle);

   if(fastBars < 2 || slowBars < 2)
   {
      LogStatus(StringFormat(
         "DATA WAIT: EMA not ready | fastBars=%d slowBars=%d",
         fastBars, slowBars
      ));
      return false;
   }

   double   fast[1];
   double   slow[1];
   MqlRates rate[1];

   ResetLastError();

   int fastCopied = CopyBuffer(fastHandle, 0, 1, 1, fast);
   int slowCopied = CopyBuffer(slowHandle, 0, 1, 1, slow);
   int rateCopied = CopyRates(_Symbol, SignalTimeframe, 1, 1, rate);

   if(fastCopied != 1 || slowCopied != 1 || rateCopied != 1)
   {
      int err = GetLastError();

      LogStatus(StringFormat(
         "DATA ERROR: Copy failed | fast=%d slow=%d rates=%d error=%d",
         fastCopied, slowCopied, rateCopied, err
      ));

      return false;
   }

   double fastEMA = fast[0];
   double slowEMA = slow[0];

   bool bullishCandle = rate[0].close > rate[0].open;
   bool bearishCandle = rate[0].close < rate[0].open;

   //--- Direction logic:
   //--- BUY  when EMA Fast > EMA Slow and closed price > Fast EMA
   //--- SELL when EMA Fast < EMA Slow and closed price < Fast EMA
   bool buySignal  = (fastEMA > slowEMA &&
                      rate[0].close > fastEMA);

   bool sellSignal = (fastEMA < slowEMA &&
                      rate[0].close < fastEMA);

   if(RequireCandleConfirm)
   {
      buySignal  = buySignal  && bullishCandle;
      sellSignal = sellSignal && bearishCandle;
   }

   if(EnableDebugLog)
   {
      Print("SIGNAL CHECK | time=",
            TimeToString(rate[0].time, TIME_DATE|TIME_MINUTES),
            " | O=", DoubleToString(rate[0].open, _Digits),
            " C=", DoubleToString(rate[0].close, _Digits),
            " | Fast=", DoubleToString(fastEMA, _Digits),
            " Slow=", DoubleToString(slowEMA, _Digits),
            " | BUY=", buySignal,
            " SELL=", sellSignal);
   }

   if(buySignal)
      signal = 1;
   else if(sellSignal)
      signal = -1;

   return true;
}

//+------------------------------------------------------------------+
//| Open BUY                                                         |
//+------------------------------------------------------------------+
bool OpenBuy()
{
   MqlTick tick;

   if(!SymbolInfoTick(_Symbol, tick) || tick.ask <= 0 || tick.bid <= 0)
   {
      Print("BUY ERROR: invalid tick data");
      return false;
   }

   double volume = NormalizeVolume(LotSize);

   if(volume <= 0)
   {
      Print("BUY ERROR: normalized volume <= 0");
      return false;
   }

   double tp = 0.0;

   if(UseIndividualTP)
   {
      tp = CalculateBuyTP(tick);

      if(tp <= tick.bid)
      {
         Print("BUY ERROR: invalid TP | bid=",
               DoubleToString(tick.bid, _Digits),
               " tp=", DoubleToString(tp, _Digits));
         return false;
      }
   }

   ResetLastError();

   bool requestOK = trade.Buy(
      volume,
      _Symbol,
      0.0,
      0.0,       // NO STOP LOSS
      tp,        // 0 = basket close only
      "Basket BUY"
   );

   uint retcode = trade.ResultRetcode();

   if(!requestOK || !TradeRetcodeSuccessful(retcode))
   {
      PrintTradeFailure("BUY", requestOK);
      return false;
   }

   Print("BUY OPENED | deal=", trade.ResultDeal(),
         " order=", trade.ResultOrder(),
         " volume=", DoubleToString(trade.ResultVolume(), 2),
         " price=", DoubleToString(trade.ResultPrice(), _Digits),
         " tp=", DoubleToString(tp, _Digits),
         " retcode=", retcode,
         " ", trade.ResultRetcodeDescription());

   return true;
}

//+------------------------------------------------------------------+
//| Open SELL                                                        |
//+------------------------------------------------------------------+
bool OpenSell()
{
   MqlTick tick;

   if(!SymbolInfoTick(_Symbol, tick) || tick.ask <= 0 || tick.bid <= 0)
   {
      Print("SELL ERROR: invalid tick data");
      return false;
   }

   double volume = NormalizeVolume(LotSize);

   if(volume <= 0)
   {
      Print("SELL ERROR: normalized volume <= 0");
      return false;
   }

   double tp = 0.0;

   if(UseIndividualTP)
   {
      tp = CalculateSellTP(tick);

      if(tp <= 0 || tp >= tick.ask)
      {
         Print("SELL ERROR: invalid TP | ask=",
               DoubleToString(tick.ask, _Digits),
               " tp=", DoubleToString(tp, _Digits));
         return false;
      }
   }

   ResetLastError();

   bool requestOK = trade.Sell(
      volume,
      _Symbol,
      0.0,
      0.0,       // NO STOP LOSS
      tp,        // 0 = basket close only
      "Basket SELL"
   );

   uint retcode = trade.ResultRetcode();

   if(!requestOK || !TradeRetcodeSuccessful(retcode))
   {
      PrintTradeFailure("SELL", requestOK);
      return false;
   }

   Print("SELL OPENED | deal=", trade.ResultDeal(),
         " order=", trade.ResultOrder(),
         " volume=", DoubleToString(trade.ResultVolume(), 2),
         " price=", DoubleToString(trade.ResultPrice(), _Digits),
         " tp=", DoubleToString(tp, _Digits),
         " retcode=", retcode,
         " ", trade.ResultRetcodeDescription());

   return true;
}

//+------------------------------------------------------------------+
//| Calculate safe BUY TP                                            |
//| BUY TP must remain sufficiently above current Bid.               |
//+------------------------------------------------------------------+
double CalculateBuyTP(const MqlTick &tick)
{
   int stopsLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);

   double requestedTP = tick.ask + TakeProfitPoints * _Point;
   double minimumTP   = tick.bid + (stopsLevel + 1) * _Point;

   double tp = MathMax(requestedTP, minimumTP);

   return NormalizePriceUp(tp);
}

//+------------------------------------------------------------------+
//| Calculate safe SELL TP                                           |
//| SELL TP must remain sufficiently below current Ask.              |
//+------------------------------------------------------------------+
double CalculateSellTP(const MqlTick &tick)
{
   int stopsLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);

   double requestedTP = tick.bid - TakeProfitPoints * _Point;
   double maximumTP   = tick.ask - (stopsLevel + 1) * _Point;

   double tp = MathMin(requestedTP, maximumTP);

   return NormalizePriceDown(tp);
}

//+------------------------------------------------------------------+
//| Normalize price upward to broker tick size                       |
//+------------------------------------------------------------------+
double NormalizePriceUp(double price)
{
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tickSize <= 0.0)
      tickSize = _Point;

   double steps = MathCeil((price / tickSize) - 1e-10);
   double value = steps * tickSize;

   return NormalizeDouble(value, _Digits);
}

//+------------------------------------------------------------------+
//| Normalize price downward to broker tick size                     |
//+------------------------------------------------------------------+
double NormalizePriceDown(double price)
{
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tickSize <= 0.0)
      tickSize = _Point;

   double steps = MathFloor((price / tickSize) + 1e-10);
   double value = steps * tickSize;

   return NormalizeDouble(value, _Digits);
}

//+------------------------------------------------------------------+
//| Count positions belonging to this EA                             |
//+------------------------------------------------------------------+
int CountMyPositions()
{
   int count = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);

      if(ticket == 0)
         continue;

      string symbol = PositionGetString(POSITION_SYMBOL);
      ulong  magic  = (ulong)PositionGetInteger(POSITION_MAGIC);

      if(symbol == _Symbol && magic == MagicNumber)
         count++;
   }

   return count;
}

//+------------------------------------------------------------------+
//| Combined floating profit for this EA basket                      |
//+------------------------------------------------------------------+
double GetMyBasketProfit()
{
   double total = 0.0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);

      if(ticket == 0)
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;

      total += PositionGetDouble(POSITION_PROFIT);
      total += PositionGetDouble(POSITION_SWAP);
   }

   return total;
}

//+------------------------------------------------------------------+
//| Spread filter                                                    |
//+------------------------------------------------------------------+
bool SpreadIsAllowed()
{
   if(MaxSpreadPoints <= 0)
      return true;

   MqlTick tick;

   if(!SymbolInfoTick(_Symbol, tick) || tick.ask <= 0 || tick.bid <= 0)
   {
      Print("NO TRADE: cannot read spread");
      return false;
   }

   double spreadPoints = (tick.ask - tick.bid) / _Point;

   if(spreadPoints > MaxSpreadPoints)
   {
      if(EnableDebugLog)
      {
         Print("NO TRADE: spread too high | spread=",
               DoubleToString(spreadPoints, 1),
               " max=", MaxSpreadPoints);
      }

      return false;
   }

   return true;
}

//+------------------------------------------------------------------+
//| Normalize lot size to broker limits                              |
//+------------------------------------------------------------------+
double NormalizeVolume(double requestedVolume)
{
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(minLot <= 0.0 || maxLot <= 0.0)
   {
      Print("VOLUME ERROR: invalid broker volume limits");
      return 0.0;
   }

   double volume = MathMax(minLot, MathMin(maxLot, requestedVolume));

   if(step > 0.0)
   {
      double steps = MathFloor(((volume - minLot) / step) + 1e-9);
      volume = minLot + steps * step;
   }

   volume = MathMax(minLot, MathMin(maxLot, volume));

   return NormalizeDouble(volume, 8);
}

//+------------------------------------------------------------------+
//| Check whether trade environment allows new positions             |
//+------------------------------------------------------------------+
bool TradeEnvironmentAllowed()
{
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
   {
      LogStatus("NO TRADE: Algo Trading disabled in terminal");
      return false;
   }

   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
   {
      LogStatus("NO TRADE: EA trading permission disabled");
      return false;
   }

   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
   {
      LogStatus("NO TRADE: account trading is not allowed");
      return false;
   }

   if(!AccountInfoInteger(ACCOUNT_TRADE_EXPERT))
   {
      LogStatus("NO TRADE: Expert Advisor trading is not allowed on account");
      return false;
   }

   ENUM_SYMBOL_TRADE_MODE mode =
      (ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);

   if(mode == SYMBOL_TRADE_MODE_DISABLED)
   {
      LogStatus("NO TRADE: symbol trading is disabled");
      return false;
   }

   if(mode == SYMBOL_TRADE_MODE_CLOSEONLY)
   {
      LogStatus("NO TRADE: symbol is CLOSE-ONLY");
      return false;
   }

   return true;
}

//+------------------------------------------------------------------+
//| Check direction restrictions                                     |
//+------------------------------------------------------------------+
bool DirectionAllowed(int signal)
{
   ENUM_SYMBOL_TRADE_MODE mode =
      (ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);

   if(signal == 1 && mode == SYMBOL_TRADE_MODE_SHORTONLY)
   {
      Print("NO TRADE: BUY blocked because symbol is SHORT-ONLY");
      return false;
   }

   if(signal == -1 && mode == SYMBOL_TRADE_MODE_LONGONLY)
   {
      Print("NO TRADE: SELL blocked because symbol is LONG-ONLY");
      return false;
   }

   return true;
}

//+------------------------------------------------------------------+
//| Equity protection                                                |
//+------------------------------------------------------------------+
void ApplyEquityProtection()
{
   if(!UseEquityProtection)
      return;

   if(tradingBlocked)
      return;

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);

   if(balance <= 0.0)
      return;

   double drawdown = (balance - equity) / balance * 100.0;

   if(drawdown >= MaxDrawdownPercent)
   {
      if(!equityGuardActive)
      {
         Print("EQUITY GUARD TRIGGERED | balance=",
               DoubleToString(balance, 2),
               " equity=", DoubleToString(equity, 2),
               " drawdown=", DoubleToString(drawdown, 2),
               "% limit=", DoubleToString(MaxDrawdownPercent, 2), "%");
      }

      equityGuardActive = true;

      CloseAllMyPositions("EQUITY GUARD");

      if(StopTradingAfterGuard)
      {
         tradingBlocked = true;
         Print("TRADING BLOCKED until EA is reinitialized.");
      }

      return;
   }

   //--- If permanent blocking is disabled, allow trading again
   //--- only after account DD has recovered below the threshold.
   if(equityGuardActive && !StopTradingAfterGuard)
   {
      equityGuardActive = false;

      Print("EQUITY GUARD RELEASED | drawdown=",
            DoubleToString(drawdown, 2), "%");
   }
}

//+------------------------------------------------------------------+
//| Close positions held too long                                    |
//+------------------------------------------------------------------+
void CloseExpiredPositions()
{
   if(!UseMaxHoldingTime || MaxHoldingMinutes <= 0)
      return;

   datetime now = TimeCurrent();

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);

      if(ticket == 0)
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;

      datetime openTime =
         (datetime)PositionGetInteger(POSITION_TIME);

      if((long)(now - openTime) < (long)MaxHoldingMinutes * 60)
         continue;

      if(!ClosePositionByTicket(ticket, "MAX HOLDING TIME"))
      {
         Print("Timed close failed for position #", ticket);
      }
   }
}

//+------------------------------------------------------------------+
//| Close all positions belonging to this EA                         |
//+------------------------------------------------------------------+
void CloseAllMyPositions(string reason = "CLOSE ALL")
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);

      if(ticket == 0)
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;

      ClosePositionByTicket(ticket, reason);
   }
}

//+------------------------------------------------------------------+
//| Close one position with result validation                        |
//+------------------------------------------------------------------+
bool ClosePositionByTicket(ulong ticket, string reason)
{
   ResetLastError();

   bool requestOK = trade.PositionClose(ticket);
   uint retcode   = trade.ResultRetcode();

   if(!requestOK || !TradeRetcodeSuccessful(retcode))
   {
      Print("CLOSE ERROR | ticket=", ticket,
            " reason=", reason,
            " requestOK=", requestOK,
            " retcode=", retcode,
            " ", trade.ResultRetcodeDescription(),
            " lastError=", GetLastError());

      return false;
   }

   Print("POSITION CLOSED | ticket=", ticket,
         " reason=", reason,
         " retcode=", retcode,
         " ", trade.ResultRetcodeDescription());

   return true;
}

//+------------------------------------------------------------------+
//| Trade retcodes treated as successful                             |
//+------------------------------------------------------------------+
bool TradeRetcodeSuccessful(uint retcode)
{
   return (
      retcode == TRADE_RETCODE_DONE ||
      retcode == TRADE_RETCODE_DONE_PARTIAL ||
      retcode == TRADE_RETCODE_PLACED
   );
}

//+------------------------------------------------------------------+
//| Print complete trade failure information                         |
//+------------------------------------------------------------------+
void PrintTradeFailure(string side, bool requestOK)
{
   Print(side,
         " FAILED | requestOK=", requestOK,
         " retcode=", trade.ResultRetcode(),
         " description=", trade.ResultRetcodeDescription(),
         " deal=", trade.ResultDeal(),
         " order=", trade.ResultOrder(),
         " brokerComment=", trade.ResultComment(),
         " bid=", DoubleToString(trade.ResultBid(), _Digits),
         " ask=", DoubleToString(trade.ResultAsk(), _Digits),
         " lastError=", GetLastError());
}

//+------------------------------------------------------------------+
//| Throttled status logger                                          |
//+------------------------------------------------------------------+
void LogStatus(string message)
{
   if(!EnableDebugLog)
      return;

   datetime now = TimeCurrent();

   // Prevent the Journal from being flooded on every tick.
   if(now == 0 || lastStatusLog == 0 || now - lastStatusLog >= 10)
   {
      Print(message);
      lastStatusLog = now;
   }
}
//+------------------------------------------------------------------+
