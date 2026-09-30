//+------------------------------------------------------------------+
//| XAUUSD_Valetax_Bot.mq5                                           |
//| Strategi EMA sendiri di dalam MT5.                                |
//| Jangan dipasang bersamaan dengan XAUUSD_TelegramExec.mq5.        |
//| WARNING: No profit guarantee. Test on DEMO first.                |
//+------------------------------------------------------------------+
#property copyright "XAUUSD Valetax Bot"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

input group "=== Account / Symbol ==="
// Valetax DEMO | Server: ValetaxIntl-Live7 | Symbol: XAUUSD | Lot: 0.01
input string InpSymbol           = "XAUUSD";   // Symbol Valetax
input long   InpMagic            = 26092401;   // Magic number
input double InpLot              = 0.01;       // Lot size (demo)
input int    InpMaxSlippagePts   = 30;         // Max slippage (points)

input group "=== Strategy ==="
input int    InpFastEMA          = 9;
input int    InpSlowEMA          = 21;
input int    InpRSIPeriod        = 14;
input double InpRSIOverbought    = 65.0;
input ENUM_TIMEFRAMES InpTF      = PERIOD_M15; // Timeframe sinyal

input group "=== Risk ==="
input double InpTakeProfitPct    = 0.40;       // TP % dari harga entry
input double InpStopLossPct      = 0.25;       // SL % dari harga entry
input double InpTrailingPct      = 0.20;       // Trailing % dari peak
input bool   InpUseTrailing      = true;
input bool   InpOnePositionOnly  = true;       // Hanya 1 posisi sekaligus
input bool   InpTradeOnNewBar    = true;       // Sinyal hanya di bar baru

CTrade trade;
datetime lastBarTime = 0;
int handleFast = INVALID_HANDLE;
int handleSlow = INVALID_HANDLE;
int handleRsi  = INVALID_HANDLE;

//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpMaxSlippagePts);
   trade.SetTypeFillingBySymbol(InpSymbol);

   handleFast = iMA(InpSymbol, InpTF, InpFastEMA, 0, MODE_EMA, PRICE_CLOSE);
   handleSlow = iMA(InpSymbol, InpTF, InpSlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   handleRsi  = iRSI(InpSymbol, InpTF, InpRSIPeriod, PRICE_CLOSE);

   if(handleFast == INVALID_HANDLE || handleSlow == INVALID_HANDLE || handleRsi == INVALID_HANDLE)
     {
      Print("Gagal buat indicator handles. Cek symbol: ", InpSymbol);
      return INIT_FAILED;
     }

   Print("XAUUSD Valetax Bot siap | Symbol=", InpSymbol, " Lot=", InpLot,
         " TP%=", InpTakeProfitPct, " SL%=", InpStopLossPct);
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(handleFast != INVALID_HANDLE) IndicatorRelease(handleFast);
   if(handleSlow != INVALID_HANDLE) IndicatorRelease(handleSlow);
   if(handleRsi  != INVALID_HANDLE) IndicatorRelease(handleRsi);
  }

//+------------------------------------------------------------------+
bool IsNewBar()
  {
   datetime t[];
   if(CopyTime(InpSymbol, InpTF, 0, 1, t) < 1)
      return false;
   if(t[0] != lastBarTime)
     {
      lastBarTime = t[0];
      return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
int CountOurPositions()
  {
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != InpSymbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      count++;
     }
   return count;
  }

//+------------------------------------------------------------------+
bool ReadBuffers(double &fast0, double &fast1, double &slow0, double &slow1, double &rsi0)
  {
   double f[], s[], r[];
   ArraySetAsSeries(f, true);
   ArraySetAsSeries(s, true);
   ArraySetAsSeries(r, true);

   if(CopyBuffer(handleFast, 0, 0, 3, f) < 3) return false;
   if(CopyBuffer(handleSlow, 0, 0, 3, s) < 3) return false;
   if(CopyBuffer(handleRsi,  0, 0, 2, r) < 2) return false;

   // index 1 = bar yang baru close (lebih stabil daripada bar 0 yang masih berjalan)
   fast0 = f[1];
   fast1 = f[2];
   slow0 = s[1];
   slow1 = s[2];
   rsi0  = r[1];
   return true;
  }

//+------------------------------------------------------------------+
void ManageTrailing()
  {
   if(!InpUseTrailing)
      return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != InpSymbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      if(PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_BUY)
         continue;

      double entry = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl    = PositionGetDouble(POSITION_SL);
      double tp    = PositionGetDouble(POSITION_TP);
      double bid   = SymbolInfoDouble(InpSymbol, SYMBOL_BID);
      double halfTp = entry * (1.0 + (InpTakeProfitPct / 2.0) / 100.0);

      if(bid < halfTp)
         continue;

      double newSL = bid * (1.0 - InpTrailingPct / 100.0);
      double point = SymbolInfoDouble(InpSymbol, SYMBOL_POINT);
      int    digits = (int)SymbolInfoInteger(InpSymbol, SYMBOL_DIGITS);
      newSL = NormalizeDouble(newSL, digits);

      if(newSL > sl + point)
         trade.PositionModify(ticket, newSL, tp);
     }
  }

//+------------------------------------------------------------------+
void CloseAllBuys(const string reason)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != InpSymbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      if(PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_BUY)
         continue;
      if(trade.PositionClose(ticket))
         Print("Close BUY #", ticket, " reason=", reason);
     }
  }

//+------------------------------------------------------------------+
void OpenBuy()
  {
   if(InpOnePositionOnly && CountOurPositions() > 0)
      return;

   double ask = SymbolInfoDouble(InpSymbol, SYMBOL_ASK);
   int digits = (int)SymbolInfoInteger(InpSymbol, SYMBOL_DIGITS);
   double sl  = NormalizeDouble(ask * (1.0 - InpStopLossPct / 100.0), digits);
   double tp  = NormalizeDouble(ask * (1.0 + InpTakeProfitPct / 100.0), digits);

   if(!trade.Buy(InpLot, InpSymbol, ask, sl, tp, "Valetax XAU bot"))
      Print("BUY gagal: ", trade.ResultRetcodeDescription());
   else
      Print("BUY OK @", ask, " SL=", sl, " TP=", tp, " lot=", InpLot);
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   ManageTrailing();

   if(InpTradeOnNewBar && !IsNewBar())
      return;

   double fast0, fast1, slow0, slow1, rsi0;
   if(!ReadBuffers(fast0, fast1, slow0, slow1, rsi0))
      return;

   bool crossUp = (fast1 <= slow1) && (fast0 > slow0);
   bool crossDn = (fast1 >= slow1) && (fast0 < slow0);

   if(crossUp && rsi0 < InpRSIOverbought)
      OpenBuy();

   if(crossDn || rsi0 > InpRSIOverbought)
      CloseAllBuys("signal_exit");
  }
//+------------------------------------------------------------------+
