//+------------------------------------------------------------------+
//| XAUUSD_TelegramExec.mq5                                          |
//| Eksekusi sinyal bot Telegram ke Valetax MT5.                     |
//| Lot tetap. TP dan SL dipakai persis dari sinyal, khusus XAUUSD.  |
//| Uji di akun DEMO dulu. Bukan jaminan untung.                     |
//+------------------------------------------------------------------+
#property copyright "XAUUSD Telegram Exec"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

input group "=== Sinyal ==="
input string InpSignalUrl        = "";          // URL feed, contoh http://IP:8787/signal
input string InpSignalToken      = "";          // MT5_SIGNAL_TOKEN
input int    InpPollSeconds      = 5;           // Jeda cek sinyal (detik)
input int    InpMaxSignalAgeSec  = 180;         // Abaikan BUY yang lebih tua dari ini

input group "=== Order ==="
input string InpSymbol           = "XAUUSD";    // Symbol Valetax
input double InpLot              = 0.01;        // Lot tetap
input long   InpMagic            = 26093001;    // Magic number
input int    InpMaxSlippagePts   = 50;          // Slippage maksimum (points)

CTrade trade;
string lastDoneId = "";
string lastLoggedSkip = "";

//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpSignalUrl == "" || InpSignalToken == "")
     {
      Print("Isi InpSignalUrl dan InpSignalToken.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(!SymbolSelect(InpSymbol, true))
     {
      Print("Symbol tidak ada di Market Watch: ", InpSymbol);
      return INIT_FAILED;
     }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpMaxSlippagePts);
   trade.SetTypeFillingBySymbol(InpSymbol);
   lastDoneId = LoadLastId();
   EventSetTimer(MathMax(InpPollSeconds, 1));
   Print("Telegram exec siap | ", InpSymbol, " lot=", InpLot, " url=", InpSignalUrl);
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
  }

//+------------------------------------------------------------------+
void OnTimer()
  {
   PollSignal();
  }

//+------------------------------------------------------------------+
string IdPath()
  {
   return "xauusd_tg_last_id.txt";
  }

//+------------------------------------------------------------------+
string LoadLastId()
  {
   int handle = FileOpen(IdPath(), FILE_READ | FILE_TXT | FILE_COMMON | FILE_ANSI);
   if(handle == INVALID_HANDLE)
      return "";
   string id = FileReadString(handle);
   FileClose(handle);
   StringTrimLeft(id);
   StringTrimRight(id);
   return id;
  }

//+------------------------------------------------------------------+
void SaveLastId(const string id)
  {
   int handle = FileOpen(IdPath(), FILE_WRITE | FILE_TXT | FILE_COMMON | FILE_ANSI);
   if(handle == INVALID_HANDLE)
     {
      Print("Gagal simpan id sinyal: ", GetLastError());
      return;
     }
   FileWriteString(handle, id);
   FileClose(handle);
   lastDoneId = id;
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
void CloseOurBuys()
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
      if(!trade.PositionClose(ticket))
         Print("Close gagal #", ticket, " ", trade.ResultRetcodeDescription());
      else
         Print("Close BUY #", ticket);
     }
  }

//+------------------------------------------------------------------+
bool JsonString(const string json, const string key, string &value)
  {
   string pattern = "\"" + key + "\":\"";
   int start = StringFind(json, pattern);
   if(start < 0)
      return false;
   start += StringLen(pattern);
   int stop = StringFind(json, "\"", start);
   if(stop < 0)
      return false;
   value = StringSubstr(json, start, stop - start);
   return true;
  }

//+------------------------------------------------------------------+
bool JsonNumber(const string json, const string key, double &value)
  {
   string pattern = "\"" + key + "\":";
   int start = StringFind(json, pattern);
   if(start < 0)
      return false;
   start += StringLen(pattern);
   value = StringToDouble(StringSubstr(json, start));
   return true;
  }

//+------------------------------------------------------------------+
double NormalizeLot()
  {
   double minLot = SymbolInfoDouble(InpSymbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(InpSymbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(InpSymbol, SYMBOL_VOLUME_STEP);
   if(step <= 0)
      step = 0.01;
   double lot = InpLot;
   if(lot < minLot)
      lot = minLot;
   if(lot > maxLot)
      lot = maxLot;
   lot = MathFloor(lot / step + 1e-8) * step;
   return NormalizeDouble(lot, 2);
  }

//+------------------------------------------------------------------+
bool PlaceBuy(const double slPrice, const double tpPrice)
  {
   double ask = SymbolInfoDouble(InpSymbol, SYMBOL_ASK);
   int digits = (int)SymbolInfoInteger(InpSymbol, SYMBOL_DIGITS);
   double sl = NormalizeDouble(slPrice, digits);
   double tp = NormalizeDouble(tpPrice, digits);
   double point = SymbolInfoDouble(InpSymbol, SYMBOL_POINT);
   int stops = (int)SymbolInfoInteger(InpSymbol, SYMBOL_TRADE_STOPS_LEVEL);
   int freeze = (int)SymbolInfoInteger(InpSymbol, SYMBOL_TRADE_FREEZE_LEVEL);
   double minDist = MathMax(stops, freeze) * point;

   if(!(sl < ask && ask < tp))
     {
      Print("SL/TP tidak cocok dengan harga Valetax. ask=", ask, " sl=", sl, " tp=", tp);
      return false;
     }
   if((ask - sl) < minDist || (tp - ask) < minDist)
     {
      Print("SL/TP lebih dekat dari batas broker. ask=", ask, " sl=", sl, " tp=", tp, " min=", minDist);
      return false;
     }

   double lot = NormalizeLot();
   if(!trade.Buy(lot, InpSymbol, ask, sl, tp, "tg xauusd"))
     {
      Print("BUY gagal: ", trade.ResultRetcodeDescription());
      return false;
     }
   Print("BUY OK @", ask, " SL=", sl, " TP=", tp, " lot=", lot);
   return true;
  }

//+------------------------------------------------------------------+
void PollSignal()
  {
   uchar data[];
   uchar result[];
   string resultHeaders;
   string headers = "X-Signal-Token: " + InpSignalToken + "\r\n";
   int code = WebRequest("GET", InpSignalUrl, headers, 5000, data, result, resultHeaders);
   if(code == -1)
     {
      Print("WebRequest gagal (", GetLastError(), "). Izinkan URL ini di Tools → Options → Expert Advisors: ", InpSignalUrl);
      return;
     }
   if(code != 200)
     {
      Print("Feed sinyal HTTP ", code);
      return;
     }

   string json = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
   string action, id, symbol;
   double entry = 0, tp = 0, sl = 0, ts = 0;
   if(!JsonString(json, "action", action) || !JsonString(json, "id", id))
     {
      Print("JSON sinyal tidak lengkap");
      return;
     }
   JsonString(json, "symbol", symbol);
   JsonNumber(json, "entry", entry);
   JsonNumber(json, "tp", tp);
   JsonNumber(json, "sl", sl);
   JsonNumber(json, "ts", ts);

   if(id == "" || id == lastDoneId)
      return;
   if(symbol != "" && symbol != "XAUUSD")
     {
      Print("Sinyal bukan XAUUSD, dilewati: ", symbol);
      return;
     }

   if(action == "none")
      return;

   if(action == "close")
     {
      CloseOurBuys();
      SaveLastId(id);
      return;
     }

   if(action != "buy")
      return;

   long age = (long)TimeGMT() - (long)ts;
   if(ts <= 0 || age > InpMaxSignalAgeSec)
     {
      if(lastLoggedSkip != id)
        {
         Print("BUY kedaluwarsa, tidak dikejar. id=", id, " umur=", age, "s");
         lastLoggedSkip = id;
        }
      return;
     }

   if(CountOurPositions() > 0)
     {
      Print("Sudah ada posisi XAUUSD, BUY baru dilewati. id=", id);
      SaveLastId(id);
      return;
     }

   if(PlaceBuy(sl, tp))
      SaveLastId(id);
  }
//+------------------------------------------------------------------+
