//+------------------------------------------------------------------+
//| XAUUSD_TelegramExec.mq5                                          |
//| Eksekusi sinyal VPS ke MT5. VPS tidak menjalankan MetaTrader.    |
//| Magic 26093001. Bukan jaminan untung. Uji di akun DEMO dulu.     |
//|                                                                  |
//| Lot mengikuti equity dan jarak SL. Layer memakai ATR, bukan jarak |
//| dollar tetap. Basket ditutup dari net profit. Bukan jaminan      |
//| untung. Uji di akun DEMO dulu.                                   |
//+------------------------------------------------------------------+
#property copyright "XAUUSD Telegram Exec"
#property version   "2.20"
#property strict
#property description "Eksekusi sinyal VPS dengan risiko basket, layer ATR, dan proteksi margin."

#include <Trade/Trade.mqh>

enum ENUM_LOT_MODE
  {
   LOT_FIXED        = 0, // Fixed
   LOT_BALANCE      = 1, // BalanceBased
   LOT_EQUITY       = 2, // EquityBased
   LOT_RISK_PERCENT = 3  // RiskPercent
  };

enum ENUM_LAYER_TRIGGER
  {
   TRIG_FAVORABLE = 0, // FavorableMove
   TRIG_PULLBACK  = 1, // Pullback
   TRIG_ATR       = 2, // ATR
   TRIG_DISABLED  = 3  // Disabled
  };

enum ENUM_LAYER_LOT
  {
   LAYER_SAME = 0, // SameLot
   LAYER_RISK = 1, // RiskBased
   LAYER_MILD = 2  // MildMultiplier
  };

enum ENUM_BASKET_TP
  {
   BASKET_TP_MONEY  = 0, // FixedMoney
   BASKET_TP_EQUITY = 1, // EquityPercent
   BASKET_TP_RISK   = 2  // RiskMultiple
  };

input group "=== Sinyal ==="
input string InpSignalUrl             = "";                 // URL feed, contoh http://IP:8787/signal
input string InpSignalToken           = "";                 // MT5_SIGNAL_TOKEN
input int    InpPollSeconds           = 5;                  // Jeda cek sinyal (detik)
input int    InpMaxSignalAgeSec       = 180;                // Abaikan sinyal yang lebih tua dari ini

input group "=== Order ==="
input string         InpSymbol        = "XAUUSD";           // Symbol Valetax
input long           InpMagic         = 26093001;           // Magic number
input int            InpMaxSlippagePts = 50;                // Slippage maksimum (points)
input int            InpMaxSpread     = 100;                // MaxSpread (points, 0 = mati)

input group "=== Money management ==="
input ENUM_LOT_MODE  InpLotMode       = LOT_RISK_PERCENT;   // Mode lot
input double         InpLot           = 0.01;               // Lot Fixed
input double         InpBaseLot       = 0.01;               // Lot dasar Balance/Equity
input double         InpBaseCapital   = 100.0;              // Modal acuan, dalam mata uang akun
input double         InpRiskPerBasketPercent = 1.0;         // Risiko target per basket (% equity)
input double         InpMaxRiskPerBasketPercent = 1.5;      // Batas keras risiko basket (% equity)

input group "=== Layering ==="
input bool           InpEnableLayering = true;              // Aktifkan layer
input int            InpMaxLayers      = 3;                 // Maksimum posisi per basket
input ENUM_LAYER_TRIGGER InpLayerTriggerMode = TRIG_ATR;    // LayerTriggerMode
input double         InpLayerATRMultiplier = 1.0;           // Jarak layer, pengali ATR
input ENUM_LAYER_LOT InpLayerLotMode  = LAYER_RISK;         // Mode lot layer
input double         InpMildMultiplier = 1.25;              // Pengali ringan (1.00-1.35)
input int            InpAtrPeriod      = 14;                // Periode ATR M15

input group "=== Basket ==="
input ENUM_BASKET_TP InpBasketTPMode   = BASKET_TP_EQUITY;  // BasketTPMode
input double         InpBasketTPPercent = 1.0;              // BasketTPPercent, % equity awal basket
input double         InpBasketTPMoney  = 1.0;               // Target FixedMoney, mata uang akun
input double         InpBasketTPMultiple = 1.0;             // Pengali risiko untuk RiskMultiple
input double         InpBasketSLPercent = 2.0;              // BasketSLPercent, % equity awal basket
input int            InpBasketCooldownMinutes = 30;         // Jeda setelah basket SL (0 = sinyal berikutnya saja)
input bool           InpEnableBreakEven = true;             // EnableBreakEven
input double         InpBreakEvenTriggerPercent = 0.50;     // BreakEvenTriggerPercent
input int            InpBreakEvenOffset = 20;               // BreakEvenOffset (points)
input bool           InpEnableBasketTrailing = false;       // EnableBasketTrailing
input double         InpBasketTrailStart = 1.0;             // BasketTrailStart, mata uang akun
input double         InpBasketTrailDistance = 0.30;         // BasketTrailDistance, mata uang akun

input group "=== Proteksi ==="
input double         InpDailyLossLimitPercent = 2.0;        // DailyLossLimitPercent
input bool           InpCloseOnDailyLoss = true;            // Tutup basket saat batas harian kena
input double         InpMaxDrawdownPercent = 8.0;           // MaxDrawdownPercent dari puncak equity
input int            InpProtectionResetID = 0;              // Ganti angka ini untuk reset proteksi drawdown
input double         InpMinMarginLevel  = 300.0;            // MinMarginLevel
input double         InpEmergencyMarginLevel = 200.0;       // EmergencyMarginLevel
input bool           InpCloseOnEmergency = true;            // Tutup basket saat margin darurat
input double         InpMinimumFreeMarginPercent = 50.0;    // MinimumFreeMarginPercent

CTrade   trade;
string   lastDoneId = "";
string   lastLoggedSkip = "";
int      gAtrHandle = INVALID_HANDLE;
bool     gUseLayering = false;
bool     gMarginModeChecked = false;
int      gMaxLayers = 1;
double   gRiskPct = 1.0;
double   gMaxRiskPct = 1.5;
double   gMild = 1.25;
bool     gBusy = false;
datetime gNextEntry = 0;
datetime gNextClose = 0;
datetime gNextRepair = 0;
datetime gPanelAt = 0;
string   gLogKey = "";
datetime gLogAt = 0;

string   gBasketId = "";
int      gDirection = 0;
double   gSl = 0.0;
double   gTp = 0.0;
double   gEntry = 0.0;
double   gBaseLot = 0.0;
double   gStartEquity = 0.0;
double   gLastLayerPrice = 0.0;
double   gExtreme = 0.0;
double   gPeakNet = 0.0;
double   gTrailPeak = 0.0;
bool     gTrailArmed = false;
bool     gBreakEvenDone = false;
datetime gBasketOpened = 0;
double   gLastNet = 0.0;

int      gStatCount = 0;
double   gStatVolume = 0.0;
double   gStatFloat = 0.0;
double   gStatSwap = 0.0;
double   gStatComm = 0.0;
double   gStatNet = 0.0;
double   gStatAvg = 0.0;
double   gStatDd = 0.0;
datetime gCommCacheAt = 0;
double   gCommCache = 0.0;

int      gDayKey = 0;
double   gDayStartEquity = 0.0;
double   gPeakEquity = 0.0;
double   gInitialBalance = 0.0;
datetime gLastRiskSave = 0;
bool     gDailyLatched = false;
bool     gDdLatched = false;
bool     gMarginBlocked = false;
bool     gMarginEmergency = false;
datetime gCooldownUntil = 0;
datetime gEmergencyUntil = 0;
int      gSavedResetId = 0;
bool     gHasSavedReset = false;
datetime gNextProtect = 0;
string   gFeedAction = "";
string   gFeedId = "";
datetime gFeedSeen = 0;
long     gFeedTs = 0;
string   gFailId = "";
int      gFailCount = 0;
bool     gLockOwned = false;
datetime gLockBeat = 0;

//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpSignalUrl == "" || InpSignalToken == "")
     {
      Print("Isi InpSignalUrl dan InpSignalToken.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpMagic == 0)
     {
      Print("Magic number tidak boleh 0. Posisi manual tidak boleh disentuh.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpMaxSignalAgeSec < 1)
     {
      Print("InpMaxSignalAgeSec harus minimal 1.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpRiskPerBasketPercent <= 0.0 || InpMaxRiskPerBasketPercent <= 0.0)
     {
      Print("Risiko basket harus lebih dari 0.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpMaxRiskPerBasketPercent + 1e-8 < InpRiskPerBasketPercent)
     {
      Print("MaxRiskPerBasketPercent harus lebih besar atau sama dengan RiskPerBasketPercent.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpRiskPerBasketPercent > 10.0 || InpMaxRiskPerBasketPercent > 10.0)
     {
      Print("Risiko per basket ditolak di atas 10% equity.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpLotMode == LOT_FIXED && InpLot <= 0.0)
     {
      Print("Mode Fixed membutuhkan InpLot lebih dari 0.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if((InpLotMode == LOT_BALANCE || InpLotMode == LOT_EQUITY) &&
      (InpBaseLot <= 0.0 || InpBaseCapital <= 0.0))
     {
      Print("Mode Balance/Equity membutuhkan InpBaseLot dan InpBaseCapital lebih dari 0.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpDailyLossLimitPercent < 0.0 || InpDailyLossLimitPercent > 50.0 ||
      InpMaxDrawdownPercent < 0.0 || InpMaxDrawdownPercent > 80.0 ||
      InpBasketSLPercent <= 0.0 || InpBasketSLPercent > 20.0)
     {
      Print("Parameter drawdown atau BasketSLPercent di luar batas yang diizinkan.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpBasketTPMode == BASKET_TP_EQUITY && (InpBasketTPPercent <= 0.0 || InpBasketTPPercent > 20.0))
     {
      Print("BasketTPPercent harus di antara 0 dan 20.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpBasketTPMode == BASKET_TP_MONEY && InpBasketTPMoney <= 0.0)
     {
      Print("BasketTPMoney harus lebih dari 0.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpBasketTPMode == BASKET_TP_RISK && InpBasketTPMultiple <= 0.0)
     {
      Print("BasketTPMultiple harus lebih dari 0.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpMinMarginLevel <= 0.0 || InpEmergencyMarginLevel <= 0.0 ||
      InpEmergencyMarginLevel >= InpMinMarginLevel)
     {
      Print("EmergencyMarginLevel harus lebih kecil dari MinMarginLevel.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpMinimumFreeMarginPercent < 0.0 || InpMinimumFreeMarginPercent >= 100.0)
     {
      Print("MinimumFreeMarginPercent harus di antara 0 dan 100.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(!SymbolSelect(InpSymbol, true))
     {
      Print("Symbol tidak ada di Market Watch: ", InpSymbol);
      return INIT_FAILED;
     }

   gRiskPct = InpRiskPerBasketPercent;
   gMaxRiskPct = InpMaxRiskPerBasketPercent;
   gMild = InpMildMultiplier;
   if(gMild < 1.0)
      gMild = 1.0;
   if(gMild > 1.35)
      gMild = 1.35;
   if(MathAbs(gMild - InpMildMultiplier) > 1e-8)
      Print("MildMultiplier dibatasi ke ", DoubleToString(gMild, 2),
            ". Pengali tidak boleh menjadi martingale.");

   gUseLayering = false;
   gMaxLayers = 1;
   if(InpEnableLayering && InpLayerTriggerMode != TRIG_DISABLED)
     {
      if(InpLayerATRMultiplier <= 0.0)
        {
         Print("LayerATRMultiplier harus lebih dari 0 saat layering aktif.");
         return INIT_PARAMETERS_INCORRECT;
        }
      if(InpAtrPeriod < 1 || InpAtrPeriod > 200)
        {
         Print("InpAtrPeriod harus di antara 1 dan 200.");
         return INIT_PARAMETERS_INCORRECT;
        }
      gMaxLayers = InpMaxLayers;
      if(gMaxLayers < 2)
        {
         Print("MaxLayers kurang dari 2. Layering tidak dipakai.");
         gMaxLayers = 1;
        }
      else
        {
         if(gMaxLayers > 5)
           {
            Print("MaxLayers dibatasi menjadi 5.");
            gMaxLayers = 5;
           }
         gUseLayering = true;
        }
     }

   if(gUseLayering)
     {
      gAtrHandle = iATR(InpSymbol, PERIOD_M15, InpAtrPeriod);
      if(gAtrHandle == INVALID_HANDLE)
        {
         Print("ATR tidak tersedia. Layering dimatikan, entri sinyal tetap jalan.");
         gUseLayering = false;
         gMaxLayers = 1;
        }
     }
   if(InpMaxRiskPerBasketPercent > 3.0)
      Print("Peringatan: batas risiko basket di atas 3% equity memperbesar drawdown.");

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpMaxSlippagePts);
   trade.SetTypeFillingBySymbol(InpSymbol);
   trade.SetAsyncMode(false);

   if(!AcquireInstance())
     {
      Print("EA dengan magic yang sama sudah berjalan di chart lain. Instance ini tidak membuka posisi.");
      return INIT_FAILED;
     }

   lastDoneId = LoadLastId();
   LoadRiskState();
   ApplyProtectionReset();
   LoadBasket();
   EnsureDayAnchor(true);
   EnsureLayeringMode();
   RebuildBasketState();
   EvaluateProtection();

   EventSetTimer(MathMax(InpPollSeconds, 1));
   PrintSummary();
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   SaveRiskState();
   ReleaseInstance();
   if(gAtrHandle != INVALID_HANDLE)
      IndicatorRelease(gAtrHandle);
   Comment("");
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   KeepInstance();
   if(!gLockOwned)
      return;
   ManagePositions();
   UpdatePanel();
  }

//+------------------------------------------------------------------+
void OnTimer()
  {
   KeepInstance();
   if(!gLockOwned)
      return;
   ManagePositions();
   PollSignal();
   UpdatePanel();
  }

//+------------------------------------------------------------------+
void PrintSummary()
  {
   string cur = AccountInfoString(ACCOUNT_CURRENCY);
   Print("Telegram exec 2.20 | magic=", InpMagic,
         " symbol=", InpSymbol,
         " currency=", cur,
         " mode=", LotModeName(),
         " risk=", DoubleToString(gRiskPct, 2), "%",
         " maxRisk=", DoubleToString(gMaxRiskPct, 2), "%",
         " layer=", TriggerName(),
         " atrX=", DoubleToString(InpLayerATRMultiplier, 2),
         " maxLayers=", gMaxLayers,
         " layerLot=", LayerLotName(),
         " contract=", DoubleToString(SymbolInfoDouble(InpSymbol, SYMBOL_TRADE_CONTRACT_SIZE), 2),
         " tickSize=", DoubleToString(SymbolInfoDouble(InpSymbol, SYMBOL_TRADE_TICK_SIZE), 8),
         " tickValue=", DoubleToString(SymbolInfoDouble(InpSymbol, SYMBOL_TRADE_TICK_VALUE), 8),
         " volMin=", DoubleToString(SymbolInfoDouble(InpSymbol, SYMBOL_VOLUME_MIN), 4),
         " volStep=", DoubleToString(SymbolInfoDouble(InpSymbol, SYMBOL_VOLUME_STEP), 4),
         " volMax=", DoubleToString(SymbolInfoDouble(InpSymbol, SYMBOL_VOLUME_MAX), 4));
   string upper = cur;
   StringToUpper(upper);
   if(upper == "USC" || upper == "CENT" || StringFind(upper, "CENT") >= 0)
     {
      Print("Akun cent terdeteksi. Perhitungan risiko memakai ", cur,
            ". RiskPercent tidak perlu konversi manual.");
      if((InpLotMode == LOT_BALANCE || InpLotMode == LOT_EQUITY) && InpBaseCapital < 1000.0)
         Print("Peringatan: InpBaseCapital untuk akun cent biasanya dalam sen. Contoh 100 USD = 10000 USC.");
      if(InpEnableBasketTrailing && InpBasketTrailStart < 50.0)
         Print("Peringatan: BasketTrailStart dan BasketTrailDistance di akun cent memakai USC, bukan USD.");
     }
   if(InpLotMode != LOT_RISK_PERCENT && InpLayerLotMode == LAYER_RISK)
      Print("LayerLotMode RiskBased memakai jatah risiko basket. Lot Fixed/Balance/Equity tidak dipakai untuk ukuran layer.");
  }

//+------------------------------------------------------------------+
string LotModeName()
  {
   if(InpLotMode == LOT_FIXED) return "Fixed";
   if(InpLotMode == LOT_BALANCE) return "BalanceBased";
   if(InpLotMode == LOT_EQUITY) return "EquityBased";
   return "RiskPercent";
  }

//+------------------------------------------------------------------+
string LayerLotName()
  {
   if(InpLayerLotMode == LAYER_SAME) return "SameLot";
   if(InpLayerLotMode == LAYER_MILD) return "MildMultiplier";
   return "RiskBased";
  }

//+------------------------------------------------------------------+
string TriggerName()
  {
   if(!gUseLayering || InpLayerTriggerMode == TRIG_DISABLED) return "Disabled";
   if(InpLayerTriggerMode == TRIG_FAVORABLE) return "FavorableMove";
   if(InpLayerTriggerMode == TRIG_PULLBACK) return "Pullback";
   return "ATR";
  }

//+------------------------------------------------------------------+
string IdPath()
  {
   return "xauusd_tg_last_id.txt";
  }

//+------------------------------------------------------------------+
string BasketPath()
  {
   return "xauusd_tg_basket_" + IntegerToString(InpMagic) + ".txt";
  }

//+------------------------------------------------------------------+
string RiskPath()
  {
   return "xauusd_tg_risk_" + IntegerToString(InpMagic) + ".txt";
  }

//+------------------------------------------------------------------+
string LockName()
  {
   return "xauusd_tg_lock_" + IntegerToString(InpMagic);
  }

//+------------------------------------------------------------------+
string LockBeatName()
  {
   return LockName() + "_beat";
  }

//+------------------------------------------------------------------+
bool AcquireInstance()
  {
   double token = (double)ChartID();
   double now = (double)TimeLocal();
   if(GlobalVariableCheck(LockName()))
     {
      double owner = GlobalVariableGet(LockName());
      double stamp = GlobalVariableCheck(LockBeatName()) ? GlobalVariableGet(LockBeatName()) : 0.0;
      if(owner != token && (now - stamp) <= 20.0)
         return false;
      if(owner != token && !GlobalVariableSetOnCondition(LockName(), token, owner))
         return false;
     }
   else
     {
      GlobalVariableSet(LockName(), token);
      if(GlobalVariableGet(LockName()) != token)
         return false;
     }
   GlobalVariableSet(LockBeatName(), now);
   gLockOwned = true;
   gLockBeat = TimeCurrent();
   return true;
  }

//+------------------------------------------------------------------+
void KeepInstance()
  {
   if(!gLockOwned)
      return;
   if(GlobalVariableGet(LockName()) != (double)ChartID())
     {
      gLockOwned = false;
      return;
     }
   if((TimeCurrent() - gLockBeat) < 5)
      return;
   GlobalVariableSet(LockBeatName(), (double)TimeLocal());
   gLockBeat = TimeCurrent();
  }

//+------------------------------------------------------------------+
void ReleaseInstance()
  {
   if(!gLockOwned)
      return;
   if(GlobalVariableGet(LockName()) == (double)ChartID())
     {
      GlobalVariableDel(LockName());
      GlobalVariableDel(LockBeatName());
     }
   gLockOwned = false;
  }

//+------------------------------------------------------------------+
void LogThrottled(const string key, const string message)
  {
   if(key == gLogKey && (TimeCurrent() - gLogAt) < 30)
      return;
   gLogKey = key;
   gLogAt = TimeCurrent();
   Print(message);
  }

//+------------------------------------------------------------------+
bool SplitKv(const string line, string &key, string &val)
  {
   string text = line;
   StringTrimLeft(text);
   StringTrimRight(text);
   if(text == "")
      return false;
   int pos = StringFind(text, "=");
   if(pos <= 0)
      return false;
   key = StringSubstr(text, 0, pos);
   val = StringSubstr(text, pos + 1);
   StringTrimLeft(key);
   StringTrimRight(key);
   StringTrimLeft(val);
   StringTrimRight(val);
   return (key != "");
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
void LoadBasket()
  {
   int handle = FileOpen(BasketPath(), FILE_READ | FILE_TXT | FILE_COMMON | FILE_ANSI);
   if(handle == INVALID_HANDLE)
      return;
   while(!FileIsEnding(handle))
     {
      string key, val;
      if(!SplitKv(FileReadString(handle), key, val))
         continue;
      if(key == "id")
         gBasketId = val;
      else if(key == "dir")
         gDirection = (int)StringToInteger(val);
      else if(key == "sl")
         gSl = StringToDouble(val);
      else if(key == "tp")
         gTp = StringToDouble(val);
      else if(key == "entry")
         gEntry = StringToDouble(val);
      else if(key == "base")
         gBaseLot = StringToDouble(val);
      else if(key == "startEq")
         gStartEquity = StringToDouble(val);
      else if(key == "last")
         gLastLayerPrice = StringToDouble(val);
      else if(key == "extreme")
         gExtreme = StringToDouble(val);
      else if(key == "peakNet")
         gPeakNet = StringToDouble(val);
      else if(key == "trailPeak")
         gTrailPeak = StringToDouble(val);
      else if(key == "trailOn")
         gTrailArmed = (StringToInteger(val) != 0);
      else if(key == "be")
         gBreakEvenDone = (StringToInteger(val) != 0);
      else if(key == "opened")
         gBasketOpened = (datetime)StringToInteger(val);
     }
   FileClose(handle);
  }

//+------------------------------------------------------------------+
void SaveBasket()
  {
   int handle = FileOpen(BasketPath(), FILE_WRITE | FILE_TXT | FILE_COMMON | FILE_ANSI);
   if(handle == INVALID_HANDLE)
     {
      Print("Gagal simpan state basket: ", GetLastError());
      return;
     }
   FileWriteString(handle, "id=" + gBasketId + "\n");
   FileWriteString(handle, "dir=" + IntegerToString(gDirection) + "\n");
   FileWriteString(handle, "sl=" + DoubleToString(gSl, 8) + "\n");
   FileWriteString(handle, "tp=" + DoubleToString(gTp, 8) + "\n");
   FileWriteString(handle, "entry=" + DoubleToString(gEntry, 8) + "\n");
   FileWriteString(handle, "base=" + DoubleToString(gBaseLot, 8) + "\n");
   FileWriteString(handle, "startEq=" + DoubleToString(gStartEquity, 2) + "\n");
   FileWriteString(handle, "last=" + DoubleToString(gLastLayerPrice, 8) + "\n");
   FileWriteString(handle, "extreme=" + DoubleToString(gExtreme, 8) + "\n");
   FileWriteString(handle, "peakNet=" + DoubleToString(gPeakNet, 2) + "\n");
   FileWriteString(handle, "trailPeak=" + DoubleToString(gTrailPeak, 2) + "\n");
   FileWriteString(handle, "trailOn=" + IntegerToString(gTrailArmed ? 1 : 0) + "\n");
   FileWriteString(handle, "be=" + IntegerToString(gBreakEvenDone ? 1 : 0) + "\n");
   FileWriteString(handle, "opened=" + IntegerToString((long)gBasketOpened) + "\n");
   FileClose(handle);
  }

//+------------------------------------------------------------------+
void ClearBasket()
  {
   gBasketId = "";
   gDirection = 0;
   gSl = 0.0;
   gTp = 0.0;
   gEntry = 0.0;
   gBaseLot = 0.0;
   gStartEquity = 0.0;
   gLastLayerPrice = 0.0;
   gExtreme = 0.0;
   gPeakNet = 0.0;
   gTrailPeak = 0.0;
   gTrailArmed = false;
   gBreakEvenDone = false;
   gBasketOpened = 0;
   gLastNet = 0.0;
   gStatCount = 0;
   gStatVolume = 0.0;
   gStatFloat = 0.0;
   gStatSwap = 0.0;
   gStatComm = 0.0;
   gStatNet = 0.0;
   gStatAvg = 0.0;
   gStatDd = 0.0;
   FileDelete(BasketPath(), FILE_COMMON);
  }

//+------------------------------------------------------------------+
void LoadRiskState()
  {
   int handle = FileOpen(RiskPath(), FILE_READ | FILE_TXT | FILE_COMMON | FILE_ANSI);
   if(handle == INVALID_HANDLE)
      return;
   while(!FileIsEnding(handle))
     {
      string key, val;
      if(!SplitKv(FileReadString(handle), key, val))
         continue;
      if(key == "day")
         gDayKey = (int)StringToInteger(val);
      else if(key == "start")
         gDayStartEquity = StringToDouble(val);
      else if(key == "peak")
         gPeakEquity = StringToDouble(val);
      else if(key == "initial")
         gInitialBalance = StringToDouble(val);
      else if(key == "dailyLatch")
         gDailyLatched = (StringToInteger(val) != 0);
      else if(key == "ddLatch")
         gDdLatched = (StringToInteger(val) != 0);
      else if(key == "cooldown")
         gCooldownUntil = (datetime)StringToInteger(val);
      else if(key == "emergency")
         gEmergencyUntil = (datetime)StringToInteger(val);
      else if(key == "reset")
        {
         gSavedResetId = (int)StringToInteger(val);
         gHasSavedReset = true;
        }
     }
   FileClose(handle);
  }

//+------------------------------------------------------------------+
bool SaveRiskState()
  {
   int handle = FileOpen(RiskPath(), FILE_WRITE | FILE_TXT | FILE_COMMON | FILE_ANSI);
   if(handle == INVALID_HANDLE)
     {
      Print("Gagal simpan state risiko: ", GetLastError());
      return false;
     }
   FileWriteString(handle, "day=" + IntegerToString(gDayKey) + "\n");
   FileWriteString(handle, "start=" + DoubleToString(gDayStartEquity, 2) + "\n");
   FileWriteString(handle, "peak=" + DoubleToString(gPeakEquity, 2) + "\n");
   FileWriteString(handle, "initial=" + DoubleToString(gInitialBalance, 2) + "\n");
   FileWriteString(handle, "dailyLatch=" + IntegerToString(gDailyLatched ? 1 : 0) + "\n");
   FileWriteString(handle, "ddLatch=" + IntegerToString(gDdLatched ? 1 : 0) + "\n");
   FileWriteString(handle, "cooldown=" + IntegerToString((long)gCooldownUntil) + "\n");
   FileWriteString(handle, "emergency=" + IntegerToString((long)gEmergencyUntil) + "\n");
   FileWriteString(handle, "reset=" + IntegerToString(gSavedResetId) + "\n");
   FileClose(handle);
   gLastRiskSave = TimeCurrent();
   gHasSavedReset = true;
   return true;
  }

//+------------------------------------------------------------------+
void ApplyProtectionReset()
  {
   if(!gHasSavedReset)
     {
      gSavedResetId = InpProtectionResetID;
      if(gInitialBalance <= 0.0)
         gInitialBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      SaveRiskState();
      return;
     }
   if(gSavedResetId == InpProtectionResetID)
      return;
   gDdLatched = false;
   gSavedResetId = InpProtectionResetID;
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity > 0.0)
      gPeakEquity = equity;
   SaveRiskState();
   Print("Proteksi MaxDrawdown di-reset. Puncak equity dikunci ulang di ", DoubleToString(gPeakEquity, 2),
         ". Biarkan InpProtectionResetID pada angka yang baru.");
  }

//+------------------------------------------------------------------+
int DayKey()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   return dt.year * 10000 + dt.mon * 100 + dt.day;
  }

//+------------------------------------------------------------------+
datetime TodayStart()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dt.hour = 0;
   dt.min = 0;
   dt.sec = 0;
   return StructToTime(dt);
  }

//+------------------------------------------------------------------+
bool SumTodayFlows(double &closedPnl, double &externalFlow)
  {
   closedPnl = 0.0;
   externalFlow = 0.0;
   if(!HistorySelect(TodayStart(), TimeCurrent()))
      return false;
   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
     {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0)
         continue;
      long dtype = HistoryDealGetInteger(deal, DEAL_TYPE);
      double profit = HistoryDealGetDouble(deal, DEAL_PROFIT);
      if(dtype == DEAL_TYPE_BUY || dtype == DEAL_TYPE_SELL)
        {
         closedPnl += profit;
         closedPnl += HistoryDealGetDouble(deal, DEAL_SWAP);
         closedPnl += HistoryDealGetDouble(deal, DEAL_COMMISSION);
        }
      else if(dtype == DEAL_TYPE_BALANCE || dtype == DEAL_TYPE_CREDIT ||
              dtype == DEAL_TYPE_CHARGE || dtype == DEAL_TYPE_CORRECTION ||
              dtype == DEAL_TYPE_BONUS)
         externalFlow += profit;
     }
   return true;
  }

//+------------------------------------------------------------------+
double EstimateDayStartEquity()
  {
   double closed = 0.0;
   double flow = 0.0;
   if(!SumTodayFlows(closed, flow))
      return AccountInfoDouble(ACCOUNT_EQUITY);
   double start = AccountInfoDouble(ACCOUNT_BALANCE) - closed - flow;
   if(start <= 0.0)
      return AccountInfoDouble(ACCOUNT_EQUITY);
   return start;
  }

//+------------------------------------------------------------------+
void EnsureDayAnchor(const bool force)
  {
   int today = DayKey();
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   bool dayChanged = (gDayKey != today);

   if(!dayChanged && gDayStartEquity > 0.0)
     {
      if(gInitialBalance <= 0.0)
         gInitialBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      if(equity > gPeakEquity && !gDdLatched)
        {
         gPeakEquity = equity;
         if(force || (TimeCurrent() - gLastRiskSave) >= 60)
            SaveRiskState();
        }
      return;
     }
   if(dayChanged)
      gDailyLatched = false;
   if(!force && gDayStartEquity <= 0.0 && (TimeCurrent() - gLastRiskSave) < 30)
      return;

   // Pergantian hari saat EA masih jalan memakai equity saat itu.
   // EA yang baru menempel di hari baru menghitung ulang dari history.
   if(!force && gDayKey != 0 && dayChanged && equity > 0.0)
      gDayStartEquity = equity;
   else
      gDayStartEquity = EstimateDayStartEquity();

   gDayKey = today;
   if(gInitialBalance <= 0.0)
      gInitialBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(!gDdLatched && (gPeakEquity <= 0.0 || equity > gPeakEquity))
      gPeakEquity = equity;
   SaveRiskState();
  }

//+------------------------------------------------------------------+
void EnsureLayeringMode()
  {
   if(gMarginModeChecked)
      return;
   if(AccountInfoInteger(ACCOUNT_LOGIN) == 0)
      return;
   gMarginModeChecked = true;
   if(!gUseLayering)
      return;
   long mode = AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   if(mode != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
     {
      gUseLayering = false;
      gMaxLayers = 1;
      Print("Akun bukan hedging. Layering dimatikan. Satu posisi memakai jatah risiko basket.");
     }
  }

//+------------------------------------------------------------------+
bool OurTicket(const ulong ticket)
  {
   if(ticket == 0 || !PositionSelectByTicket(ticket))
      return false;
   if(PositionGetString(POSITION_SYMBOL) != InpSymbol)
      return false;
   if(PositionGetInteger(POSITION_MAGIC) != InpMagic)
      return false;
   long kind = PositionGetInteger(POSITION_TYPE);
   return (kind == POSITION_TYPE_BUY || kind == POSITION_TYPE_SELL);
  }

//+------------------------------------------------------------------+
int CountOurPositions()
  {
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(OurTicket(PositionGetTicket(i)))
         count++;
     }
   return count;
  }

//+------------------------------------------------------------------+
int BasketDirection(bool &mixed)
  {
   mixed = false;
   int dir = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!OurTicket(PositionGetTicket(i)))
         continue;
      int one = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
      if(dir == 0)
         dir = one;
      else if(dir != one)
        {
         mixed = true;
         return 0;
        }
     }
   return dir;
  }

//+------------------------------------------------------------------+
double BasketFloating()
  {
   double sum = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!OurTicket(PositionGetTicket(i)))
         continue;
      sum += PositionGetDouble(POSITION_PROFIT);
      sum += PositionGetDouble(POSITION_SWAP);
     }
   return sum;
  }

//+------------------------------------------------------------------+
bool WorstOpen(double &price)
  {
   bool found = false;
   price = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!OurTicket(PositionGetTicket(i)))
         continue;
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      if(!found)
        {
         price = open;
         found = true;
         continue;
        }
      if(gDirection > 0)
         price = MathMin(price, open);
      else
         price = MathMax(price, open);
     }
   return found;
  }

//+------------------------------------------------------------------+
double EarliestVolume()
  {
   datetime oldest = 0;
   double volume = 0.0;
   bool found = false;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!OurTicket(PositionGetTicket(i)))
         continue;
      datetime opened = (datetime)PositionGetInteger(POSITION_TIME);
      if(!found || opened < oldest)
        {
         oldest = opened;
         volume = PositionGetDouble(POSITION_VOLUME);
         found = true;
        }
     }
   return volume;
  }

//+------------------------------------------------------------------+
datetime EarliestOpenTime()
  {
   datetime oldest = 0;
   bool found = false;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!OurTicket(PositionGetTicket(i)))
         continue;
      datetime opened = (datetime)PositionGetInteger(POSITION_TIME);
      if(!found || opened < oldest)
        {
         oldest = opened;
         found = true;
        }
     }
   return found ? oldest : 0;
  }

//+------------------------------------------------------------------+
bool ForeignNetPosition()
  {
   if(AccountInfoInteger(ACCOUNT_MARGIN_MODE) == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
      return false;
   if(!PositionSelect(InpSymbol))
      return false;
   if(PositionGetInteger(POSITION_MAGIC) == InpMagic)
      return false;
   return true;
  }

//+------------------------------------------------------------------+
void RebuildBasketState()
  {
   int count = CountOurPositions();
   if(count <= 0)
     {
      if(gDirection != 0 || gBasketId != "")
         ClearBasket();
      return;
     }
   if(count > gMaxLayers)
      LogThrottled("cap", "Posisi EA ini lebih banyak dari MaxLayers. Layer baru diblokir sampai jumlahnya turun.");

   bool mixed = false;
   int dir = BasketDirection(mixed);
   if(mixed || dir == 0)
     {
      gDirection = 0;
      LogThrottled("mixed", "Posisi EA ini campur arah. Layer dihentikan. Sinyal close tetap bisa menutupnya.");
      return;
     }

   bool repaired = false;
   if(gDirection == 0)
     {
      gDirection = dir;
      repaired = true;
     }
   datetime oldest = EarliestOpenTime();
   if(oldest > 0 && (gBasketOpened <= 0 || gBasketOpened > oldest))
     {
      gBasketOpened = oldest;
      repaired = true;
     }
   if(gSl <= 0.0 || gTp <= 0.0 || gBaseLot <= 0.0 || gBasketId == "" || gStartEquity <= 0.0)
     {
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong ticket = PositionGetTicket(i);
         if(!OurTicket(ticket))
            continue;
         if(gSl <= 0.0)
            gSl = PositionGetDouble(POSITION_SL);
         if(gTp <= 0.0)
            gTp = PositionGetDouble(POSITION_TP);
         if(gEntry <= 0.0)
            gEntry = PositionGetDouble(POSITION_PRICE_OPEN);
         break;
        }
      if(gBaseLot <= 0.0)
         gBaseLot = EarliestVolume();
      if(gBasketId == "")
         gBasketId = "recovered";
      if(gStartEquity <= 0.0)
        {
         RefreshBasketStats();
         gStartEquity = AccountInfoDouble(ACCOUNT_EQUITY) - gStatNet;
         if(gStartEquity <= 0.0)
            gStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
        }
      if(gLastLayerPrice <= 0.0 && !NewestOpen(gLastLayerPrice))
         gLastLayerPrice = gEntry;
      if(gExtreme <= 0.0)
         gExtreme = gLastLayerPrice;
      repaired = true;
      Print("Basket dipulihkan setelah restart. SL=", gSl, " TP=", gTp, " lotDasar=", gBaseLot,
            " equityAwal=", gStartEquity);
     }
   if(repaired)
      SaveBasket();
  }

//+------------------------------------------------------------------+
void RecoverBasket()
  {
   RebuildBasketState();
  }

//+------------------------------------------------------------------+
bool NewestOpen(double &price)
  {
   datetime newest = 0;
   bool found = false;
   price = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!OurTicket(PositionGetTicket(i)))
         continue;
      datetime opened = (datetime)PositionGetInteger(POSITION_TIME);
      if(!found || opened >= newest)
        {
         newest = opened;
         price = PositionGetDouble(POSITION_PRICE_OPEN);
         found = true;
        }
     }
   return found;
  }

//+------------------------------------------------------------------+
bool MoneyLoss(const ENUM_ORDER_TYPE type, const double volume,
               const double price, const double sl, double &loss)
  {
   loss = 0.0;
   if(volume <= 0.0 || price <= 0.0 || sl <= 0.0)
      return false;
   if(type == ORDER_TYPE_BUY && !(sl < price))
      return false;
   if(type == ORDER_TYPE_SELL && !(price < sl))
      return false;

   double profit = 0.0;
   if(OrderCalcProfit(type, InpSymbol, volume, price, sl, profit) && profit < 0.0)
     {
      loss = -profit;
      return true;
     }

   double tickSize = SymbolInfoDouble(InpSymbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(InpSymbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize <= 0.0 || tickValue <= 0.0)
      return false;
   loss = (MathAbs(price - sl) / tickSize) * tickValue * volume;
   return (loss > 0.0);
  }

//+------------------------------------------------------------------+
bool BasketPotentialLoss(double &loss)
  {
   loss = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!OurTicket(PositionGetTicket(i)))
         continue;
      double sl = PositionGetDouble(POSITION_SL);
      if(sl <= 0.0)
         sl = gSl;
      ENUM_ORDER_TYPE type = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
                             ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      double one = 0.0;
      if(!MoneyLoss(type, PositionGetDouble(POSITION_VOLUME),
                    PositionGetDouble(POSITION_PRICE_OPEN), sl, one))
         return false;
      loss += one;
     }
   return true;
  }

//+------------------------------------------------------------------+
double TargetMoney()
  {
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity <= 0.0)
      return 0.0;
   return equity * gRiskPct / 100.0;
  }

//+------------------------------------------------------------------+
double HardMoney()
  {
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity <= 0.0)
      return 0.0;
   return equity * gMaxRiskPct / 100.0;
  }

//+------------------------------------------------------------------+
double LayerWeight(const int index)
  {
   if(InpLayerLotMode != LAYER_MILD)
      return 1.0;
   return 1.0 + (gMild - 1.0) * index;
  }

//+------------------------------------------------------------------+
double WeightSum(const int total)
  {
   double sum = 0.0;
   for(int i = 0; i < total; i++)
      sum += LayerWeight(i);
   if(sum <= 0.0)
      return 1.0;
   return sum;
  }

//+------------------------------------------------------------------+
double MoneyCapForNextLayer(const int count)
  {
   double used = 0.0;
   if(!BasketPotentialLoss(used))
      return 0.0;
   double remainingTarget = TargetMoney() - used;
   double remainingHard = HardMoney() - used;
   double remaining = MathMin(remainingTarget, remainingHard);
   if(remaining <= 0.0)
      return 0.0;

   int slots = gMaxLayers - count;
   if(slots <= 0)
      return 0.0;
   if(!gUseLayering || gMaxLayers <= 1 || InpLayerLotMode == LAYER_RISK)
      return remaining / slots;
   if(InpLayerLotMode == LAYER_MILD)
      return MathMin(remaining, TargetMoney() * LayerWeight(count) / WeightSum(gMaxLayers));
   return MathMin(remaining, TargetMoney() / gMaxLayers);
  }

//+------------------------------------------------------------------+
int VolumeDigits(const double step)
  {
   if(step <= 0.0)
      return 2;
   for(int digits = 0; digits <= 8; digits++)
     {
      double scaled = step * MathPow(10.0, digits);
      if(MathAbs(scaled - MathRound(scaled)) < 1e-4)
         return digits;
     }
   return 2;
  }

//+------------------------------------------------------------------+
double OurVolume()
  {
   double sum = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!OurTicket(PositionGetTicket(i)))
         continue;
      sum += PositionGetDouble(POSITION_VOLUME);
     }
   return sum;
  }

//+------------------------------------------------------------------+
double FloorLot(const double requested)
  {
   double step = SymbolInfoDouble(InpSymbol, SYMBOL_VOLUME_STEP);
   double minLot = SymbolInfoDouble(InpSymbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(InpSymbol, SYMBOL_VOLUME_MAX);
   if(step <= 0.0 || requested <= 0.0 || minLot <= 0.0)
      return 0.0;

   double lot = requested;
   if(maxLot > 0.0 && lot > maxLot)
      lot = maxLot;
   double limit = SymbolInfoDouble(InpSymbol, SYMBOL_VOLUME_LIMIT);
   if(limit > 0.0)
     {
      double room = limit - OurVolume();
      if(room < minLot)
         return 0.0;
      if(lot > room)
         lot = room;
     }

   int digits = VolumeDigits(step);
   double steps = MathFloor(lot / step + 1e-4);
   lot = NormalizeDouble(steps * step, digits);
   if(lot + (step * 0.5) < minLot)
      return 0.0;
   if(maxLot > 0.0 && lot > maxLot)
      lot = NormalizeDouble(MathFloor(maxLot / step + 1e-4) * step, digits);
   if(lot + (step * 0.5) < minLot)
      return 0.0;
   return lot;
  }

//+------------------------------------------------------------------+
bool MarginAllows(const ENUM_ORDER_TYPE type, const double price, const double lot)
  {
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double margin = AccountInfoDouble(ACCOUNT_MARGIN);
   double free = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double level = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
   if(balance <= 0.0 && equity <= 0.0)
      return false;
   if(margin > 0.0 && level > 0.0 && level + 1e-6 < InpMinMarginLevel)
      return false;
   if(margin > 0.0 && level > 0.0 && level <= InpEmergencyMarginLevel + 1e-6)
      return false;

   double need = 0.0;
   if(!OrderCalcMargin(type, InpSymbol, lot, price, need) || need < 0.0)
      return false;
   if(need > free)
      return false;
   double projectedMargin = margin + need;
   if(projectedMargin <= 0.0)
      return false;
   double projectedLevel = equity / projectedMargin * 100.0;
   if(projectedLevel + 1e-6 < InpMinMarginLevel)
      return false;
   double projectedFree = free - need;
   if(equity > 0.0 && (projectedFree / equity * 100.0) + 1e-6 < InpMinimumFreeMarginPercent)
      return false;
   return true;
  }

//+------------------------------------------------------------------+
double ShrinkLot(const ENUM_ORDER_TYPE type, const double price, const double sl,
                 const double requested, const double moneyCap)
  {
   if(requested <= 0.0 || moneyCap <= 0.0)
      return 0.0;
   double lossOne = 0.0;
   if(!MoneyLoss(type, 1.0, price, sl, lossOne) || lossOne <= 0.0)
      return 0.0;

   double lot = FloorLot(MathMin(requested, moneyCap / lossOne));
   if(lot <= 0.0)
      return 0.0;

   double loss = 0.0;
   if(!MoneyLoss(type, lot, price, sl, loss))
      return 0.0;
   if(loss > moneyCap)
     {
      double step = SymbolInfoDouble(InpSymbol, SYMBOL_VOLUME_STEP);
      lot = FloorLot(lot - step);
      if(lot <= 0.0 || !MoneyLoss(type, lot, price, sl, loss) || loss > moneyCap)
         return 0.0;
     }
   if(MarginAllows(type, price, lot))
      return lot;

   double need = 0.0;
   if(!OrderCalcMargin(type, InpSymbol, lot, price, need) || need <= 0.0)
      return 0.0;
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double margin = AccountInfoDouble(ACCOUNT_MARGIN);
   double freeRoom = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double maxNeed = freeRoom - equity * InpMinimumFreeMarginPercent / 100.0;
   if(maxNeed < 0.0)
      maxNeed = 0.0;
   if(InpMinMarginLevel > 0.0)
     {
      double byLevel = equity * 100.0 / InpMinMarginLevel - margin;
      if(byLevel < maxNeed)
         maxNeed = byLevel;
     }
   if(maxNeed <= 0.0)
      return 0.0;
   lot = FloorLot(lot * (maxNeed / need) * 0.98);
   if(lot <= 0.0 || !MoneyLoss(type, lot, price, sl, loss) || loss > moneyCap)
      return 0.0;
   if(!MarginAllows(type, price, lot))
      return 0.0;
   return lot;
  }

//+------------------------------------------------------------------+
double UnitLot(const int count)
  {
   if(count > 0 && gBaseLot > 0.0 && InpLayerLotMode == LAYER_SAME)
      return gBaseLot;
   double unit = InpLot;
   if(InpLotMode == LOT_BALANCE)
      unit = InpBaseLot * AccountInfoDouble(ACCOUNT_BALANCE) / InpBaseCapital;
   else if(InpLotMode == LOT_EQUITY)
      unit = InpBaseLot * AccountInfoDouble(ACCOUNT_EQUITY) / InpBaseCapital;
   if(InpLayerLotMode == LAYER_MILD)
     {
      double base = (count > 0 && gBaseLot > 0.0) ? gBaseLot : unit;
      unit = base * LayerWeight(count);
     }
   return unit;
  }

//+------------------------------------------------------------------+
bool UseRiskSizing()
  {
   return (InpLotMode == LOT_RISK_PERCENT || InpLayerLotMode == LAYER_RISK);
  }

//+------------------------------------------------------------------+
double ComputeLot(const ENUM_ORDER_TYPE type, const double price, const double sl, const int count)
  {
   EnsureLayeringMode();
   double moneyCap = MoneyCapForNextLayer(count);
   if(moneyCap <= 0.0)
      return 0.0;
   double requested = 0.0;
   if(UseRiskSizing())
     {
      double lossOne = 0.0;
      if(!MoneyLoss(type, 1.0, price, sl, lossOne) || lossOne <= 0.0)
         return 0.0;
      requested = moneyCap / lossOne;
      if(InpLayerLotMode == LAYER_SAME && count > 0 && gBaseLot > 0.0)
         requested = gBaseLot;
     }
   else
      requested = UnitLot(count);
   return ShrinkLot(type, price, sl, requested, moneyCap);
  }

//+------------------------------------------------------------------+
bool TradingAllowed()
  {
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
      return false;
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
      return false;
   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
      return false;
   return true;
  }

//+------------------------------------------------------------------+
bool EntryAllowed(const ENUM_ORDER_TYPE type)
  {
   if(!TradingAllowed())
      return false;
   long mode = SymbolInfoInteger(InpSymbol, SYMBOL_TRADE_MODE);
   if(mode == SYMBOL_TRADE_MODE_FULL)
      return true;
   if(mode == SYMBOL_TRADE_MODE_LONGONLY && type == ORDER_TYPE_BUY)
      return true;
   if(mode == SYMBOL_TRADE_MODE_SHORTONLY && type == ORDER_TYPE_SELL)
      return true;
   return false;
  }

//+------------------------------------------------------------------+
bool SpreadOk()
  {
   if(InpMaxSpread <= 0)
      return true;
   int spread = (int)SymbolInfoInteger(InpSymbol, SYMBOL_SPREAD);
   return (spread <= InpMaxSpread);
  }

//+------------------------------------------------------------------+
double MinStopDistance()
  {
   double point = SymbolInfoDouble(InpSymbol, SYMBOL_POINT);
   int stops = (int)SymbolInfoInteger(InpSymbol, SYMBOL_TRADE_STOPS_LEVEL);
   int freeze = (int)SymbolInfoInteger(InpSymbol, SYMBOL_TRADE_FREEZE_LEVEL);
   return MathMax(stops, freeze) * point;
  }

//+------------------------------------------------------------------+
bool SignalLevelsOk(const string action, const double entry, const double sl, const double tp)
  {
   if(entry <= 0.0 || sl <= 0.0 || tp <= 0.0)
      return false;
   if(action == "buy")
      return (sl < entry && entry < tp);
   if(action == "sell")
      return (tp < entry && entry < sl);
   return false;
  }

//+------------------------------------------------------------------+
void CloseOurPositions()
  {
   trade.SetExpertMagicNumber(InpMagic);
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(!OurTicket(ticket))
         continue;
      if(!trade.PositionClose(ticket))
         Print("Close gagal #", ticket, " ", trade.ResultRetcodeDescription());
      else
         Print("Close #", ticket);
     }
  }

//+------------------------------------------------------------------+
void RefreshBasketStats()
  {
   gStatCount = 0;
   gStatVolume = 0.0;
   gStatFloat = 0.0;
   gStatSwap = 0.0;
   gStatAvg = 0.0;
   double weighted = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!OurTicket(PositionGetTicket(i)))
         continue;
      double volume = PositionGetDouble(POSITION_VOLUME);
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      gStatCount++;
      gStatVolume += volume;
      gStatFloat += PositionGetDouble(POSITION_PROFIT);
      gStatSwap += PositionGetDouble(POSITION_SWAP);
      weighted += open * volume;
     }
   if(gStatVolume > 0.0)
      gStatAvg = weighted / gStatVolume;

   if(gStatCount > 0 && (gCommCacheAt == 0 || (TimeCurrent() - gCommCacheAt) >= 5))
     {
      gCommCache = 0.0;
      datetime from = gBasketOpened;
      if(from <= 0)
         from = TimeCurrent() - 86400;
      if(HistorySelect(from, TimeCurrent()))
        {
         int total = HistoryDealsTotal();
         for(int i = 0; i < total; i++)
           {
            ulong deal = HistoryDealGetTicket(i);
            if(deal == 0)
               continue;
            if(HistoryDealGetInteger(deal, DEAL_MAGIC) != InpMagic)
               continue;
            if(HistoryDealGetString(deal, DEAL_SYMBOL) != InpSymbol)
               continue;
            if((datetime)HistoryDealGetInteger(deal, DEAL_TIME) < from)
               continue;
            gCommCache += HistoryDealGetDouble(deal, DEAL_COMMISSION);
           }
        }
      gCommCacheAt = TimeCurrent();
     }
   gStatComm = (gStatCount > 0) ? gCommCache : 0.0;
   gStatNet = gStatFloat + gStatSwap + gStatComm;
   if(gStatCount > 0)
     {
      if(gStatNet > gPeakNet)
         gPeakNet = gStatNet;
      gLastNet = gStatNet;
     }
   gStatDd = (gPeakNet > gStatNet) ? (gPeakNet - gStatNet) : 0.0;
  }

//+------------------------------------------------------------------+
double CurrentAtr()
  {
   if(gAtrHandle == INVALID_HANDLE)
      return 0.0;
   double buffer[];
   ArraySetAsSeries(buffer, true);
   if(CopyBuffer(gAtrHandle, 0, 1, 1, buffer) != 1)
      return 0.0;
   if(buffer[0] <= 0.0)
      return 0.0;
   return buffer[0];
  }

//+------------------------------------------------------------------+
double BasketTargetMoney()
  {
   double base = gStartEquity;
   if(base <= 0.0)
      base = AccountInfoDouble(ACCOUNT_EQUITY);
   if(InpBasketTPMode == BASKET_TP_MONEY)
      return InpBasketTPMoney;
   if(InpBasketTPMode == BASKET_TP_RISK)
      return base * gRiskPct / 100.0 * InpBasketTPMultiple;
   return base * InpBasketTPPercent / 100.0;
  }

//+------------------------------------------------------------------+
double BasketStopMoney()
  {
   double base = gStartEquity;
   if(base <= 0.0)
      base = AccountInfoDouble(ACCOUNT_EQUITY);
   return base * InpBasketSLPercent / 100.0;
  }

//+------------------------------------------------------------------+
void StartCooldown()
  {
   if(InpBasketCooldownMinutes <= 0)
      return;
   datetime until = TimeCurrent() + (datetime)InpBasketCooldownMinutes * 60;
   if(until <= gCooldownUntil)
      return;
   gCooldownUntil = until;
   SaveRiskState();
   Print("Cooldown entri baru sampai ", TimeToString(gCooldownUntil, TIME_DATE | TIME_MINUTES));
  }

//+------------------------------------------------------------------+
void ReadMarginState()
  {
   double margin = AccountInfoDouble(ACCOUNT_MARGIN);
   double level = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
   gMarginBlocked = false;
   gMarginEmergency = false;
   if(margin > 0.0 && level > 0.0)
     {
      if(level < InpMinMarginLevel)
         gMarginBlocked = true;
      if(level <= InpEmergencyMarginLevel)
         gMarginEmergency = true;
     }
  }

//+------------------------------------------------------------------+
bool ProtectionBlocksEntry()
  {
   ReadMarginState();
   if(gDailyLatched || gDdLatched)
      return true;
   if(gMarginBlocked || gMarginEmergency)
      return true;
   if(TimeCurrent() < gCooldownUntil)
      return true;
   if(TimeCurrent() < gEmergencyUntil)
      return true;
   return false;
  }

//+------------------------------------------------------------------+
bool SignalStructureOk(const int direction)
  {
   if(direction == 0 || gSl <= 0.0 || gTp <= 0.0)
      return false;
   MqlTick tick;
   if(!SymbolInfoTick(InpSymbol, tick))
      return false;
   if(direction > 0)
      return (tick.bid > gSl && tick.ask < gTp);
   return (tick.ask < gSl && tick.bid > gTp);
  }

//+------------------------------------------------------------------+
void UpdateExtreme(const MqlTick &tick)
  {
   if(gDirection == 0)
      return;
   if(gExtreme <= 0.0)
     {
      gExtreme = (gDirection > 0) ? tick.bid : tick.ask;
      return;
     }
   if(gDirection > 0 && tick.bid > gExtreme)
      gExtreme = tick.bid;
   if(gDirection < 0 && (gExtreme <= 0.0 || tick.ask < gExtreme))
      gExtreme = tick.ask;
  }

//+------------------------------------------------------------------+
bool LayerTriggerReady()
  {
   double need = CurrentAtr() * InpLayerATRMultiplier;
   if(need <= 0.0)
     {
      LogThrottled("atr", "Layer ditolak. ATR belum siap, jadi jarak layer tidak diukur dengan dollar tetap.");
      return false;
     }
   if(gLastLayerPrice <= 0.0 && !NewestOpen(gLastLayerPrice))
      return false;

   MqlTick tick;
   if(!SymbolInfoTick(InpSymbol, tick))
      return false;
   UpdateExtreme(tick);

   bool ready = false;
   if(gDirection > 0)
     {
      if(InpLayerTriggerMode == TRIG_FAVORABLE)
         ready = (tick.ask >= gLastLayerPrice + need);
      else if(InpLayerTriggerMode == TRIG_PULLBACK)
         ready = ((gExtreme - gLastLayerPrice) >= need &&
                  (gExtreme - tick.ask) >= need &&
                  tick.ask + 1e-8 >= gLastLayerPrice);
      else
         ready = ((gLastLayerPrice - tick.ask) >= need);
     }
   else
     {
      if(InpLayerTriggerMode == TRIG_FAVORABLE)
         ready = (tick.bid <= gLastLayerPrice - need);
      else if(InpLayerTriggerMode == TRIG_PULLBACK)
         ready = ((gLastLayerPrice - gExtreme) >= need &&
                  (tick.bid - gExtreme) >= need &&
                  tick.bid <= gLastLayerPrice + 1e-8);
      else
         ready = ((tick.bid - gLastLayerPrice) >= need);
     }

   if(!ready && gStatNet < 0.0)
      LogThrottled("avg", "Layer tidak dibuka hanya karena posisi sedang rugi. Syarat " + TriggerName() + " belum terpenuhi.");
   return ready;
  }

//+------------------------------------------------------------------+
void RepairMissingStops()
  {
   if(gDirection == 0 || gSl <= 0.0)
      return;
   if(TimeCurrent() < gNextRepair)
      return;
   bool tried = false;
   int digits = (int)SymbolInfoInteger(InpSymbol, SYMBOL_DIGITS);
   double sl = NormalizeDouble(gSl, digits);
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(!OurTicket(ticket))
         continue;
      if(PositionGetDouble(POSITION_SL) > 0.0)
         continue;
      tried = true;
      trade.SetExpertMagicNumber(InpMagic);
      if(!trade.PositionModify(ticket, sl, 0.0))
         Print("Gagal memasang SL #", ticket, " ", trade.ResultRetcodeDescription());
     }
   if(tried)
      gNextRepair = TimeCurrent() + 10;
  }

//+------------------------------------------------------------------+
bool CloseBasket(const string reason, const bool cooldown)
  {
   if(TimeCurrent() < gNextClose)
      return false;
   Print(reason);
   CloseOurPositions();
   gNextClose = TimeCurrent() + 5;
   if(CountOurPositions() != 0)
      return false;
   ClearBasket();
   if(cooldown)
      StartCooldown();
   return true;
  }

//+------------------------------------------------------------------+
bool CheckDailyLoss()
  {
   if(gDailyLatched)
      return true;
   if(InpDailyLossLimitPercent <= 0.0 || gDayStartEquity <= 0.0)
      return false;
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity >= gDayStartEquity)
      return false;
   double lossPct = (gDayStartEquity - equity) / gDayStartEquity * 100.0;
   if(lossPct < InpDailyLossLimitPercent)
      return false;
   gDailyLatched = true;
   if(!SaveRiskState())
      LogThrottled("riskfile", "Batas rugi harian aktif, tetapi file proteksi gagal disimpan. Entri tetap ditahan.");
   Print("Batas rugi harian tercapai: ", DoubleToString(lossPct, 2),
         "%. Entri baru berhenti sampai hari broker berikutnya.");
   return true;
  }

//+------------------------------------------------------------------+
bool CheckDrawdown()
  {
   if(gDdLatched)
      return true;
   if(InpMaxDrawdownPercent <= 0.0 || gPeakEquity <= 0.0)
      return false;
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity >= gPeakEquity)
      return false;
   double dd = (gPeakEquity - equity) / gPeakEquity * 100.0;
   if(dd < InpMaxDrawdownPercent)
      return false;
   gDdLatched = true;
   if(!SaveRiskState())
      LogThrottled("riskfile", "MaxDrawdown aktif, tetapi file proteksi gagal disimpan. Entri tetap ditahan.");
   Print("MaxDrawdown tercapai: ", DoubleToString(dd, 2),
         "%. Entri baru tetap mati sampai InpProtectionResetID diganti.");
   return true;
  }

//+------------------------------------------------------------------+
bool CheckMarginProtection()
  {
   ReadMarginState();
   return gMarginEmergency;
  }

//+------------------------------------------------------------------+
void ArmEmergencyPause()
  {
   int minutes = InpBasketCooldownMinutes;
   if(minutes < 30)
      minutes = 30;
   datetime until = TimeCurrent() + (datetime)minutes * 60;
   if(until <= gEmergencyUntil)
      return;
   gEmergencyUntil = until;
   if(!SaveRiskState())
      LogThrottled("riskfile", "Jeda emergency belum tersimpan. Entri tetap ditahan selama EA ini hidup.");
   Print("Emergency close menahan entri baru sampai ", TimeToString(gEmergencyUntil, TIME_DATE | TIME_MINUTES));
  }

//+------------------------------------------------------------------+
void EmergencyCloseAll(const string reason)
  {
   CloseBasket(reason, false);
   ArmEmergencyPause();
  }

//+------------------------------------------------------------------+
void EvaluateProtection()
  {
   if((gDailyLatched || gDdLatched || gEmergencyUntil > TimeCurrent()) &&
      (TimeCurrent() - gLastRiskSave) >= 30)
      SaveRiskState();
   bool daily = CheckDailyLoss();
   bool drawdown = CheckDrawdown();
   bool emergency = CheckMarginProtection();
   if(CountOurPositions() <= 0 || TimeCurrent() < gNextProtect)
      return;
   if(emergency && InpCloseOnEmergency)
     {
      EmergencyCloseAll("Emergency margin <= " + DoubleToString(InpEmergencyMarginLevel, 0) +
                        "%. Basket ditutup sebelum stop-out broker.");
      gNextProtect = TimeCurrent() + 5;
      return;
     }
   if(daily && InpCloseOnDailyLoss)
     {
      CloseBasket("Rugi harian mencapai batas. Basket ditutup.", false);
      gNextProtect = TimeCurrent() + 5;
      return;
     }
   if(drawdown)
     {
      CloseBasket("MaxDrawdown tercapai. Semua posisi EA ini ditutup.", false);
      gNextProtect = TimeCurrent() + 5;
     }
  }

//+------------------------------------------------------------------+
void ManageBreakEven()
  {
   if(!InpEnableBreakEven || gBreakEvenDone || gStatCount <= 0 || gStatAvg <= 0.0 || gStartEquity <= 0.0)
      return;
   double trigger = gStartEquity * InpBreakEvenTriggerPercent / 100.0;
   if(trigger <= 0.0 || gStatNet < trigger)
      return;

   MqlTick tick;
   if(!SymbolInfoTick(InpSymbol, tick))
      return;
   double point = SymbolInfoDouble(InpSymbol, SYMBOL_POINT);
   double minDist = MinStopDistance();
   if(minDist < point)
      minDist = point;
   double offset = MathMax(InpBreakEvenOffset, 0) * point;
   int digits = (int)SymbolInfoInteger(InpSymbol, SYMBOL_DIGITS);
   bool pending = false;
   trade.SetExpertMagicNumber(InpMagic);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(!OurTicket(ticket))
         continue;
      long kind = PositionGetInteger(POSITION_TYPE);
      double curSl = PositionGetDouble(POSITION_SL);
      double be = (kind == POSITION_TYPE_BUY) ? (gStatAvg + offset) : (gStatAvg - offset);
      be = NormalizeDouble(be, digits);
      if(kind == POSITION_TYPE_BUY)
        {
         if(curSl > 0.0 && be <= curSl + point * 0.1)
            continue;
         if((tick.bid - be) < minDist || be >= tick.bid)
           {
            pending = true;
            continue;
           }
        }
      else
        {
         if(curSl > 0.0 && be >= curSl - point * 0.1)
            continue;
         if((be - tick.ask) < minDist || be <= tick.ask)
           {
            pending = true;
            continue;
           }
        }
      if(!trade.PositionModify(ticket, be, 0.0))
        {
         pending = true;
         LogThrottled("be", "Break-even ditunda. SL terlalu dekat untuk broker: " + trade.ResultRetcodeDescription());
        }
     }
   if(!pending)
     {
      gBreakEvenDone = true;
      SaveBasket();
      Print("Break-even basket dipasang di sekitar harga rata-rata ", DoubleToString(gStatAvg, digits));
     }
  }

//+------------------------------------------------------------------+
void ManageTrailing()
  {
   static datetime nextSave = 0;
   if(!InpEnableBasketTrailing || gStatCount <= 0)
      return;
   if(InpBasketTrailStart <= 0.0 || InpBasketTrailDistance <= 0.0)
      return;
   if(gStatNet >= InpBasketTrailStart && gStatNet >= gTrailPeak)
     {
      bool first = !gTrailArmed;
      gTrailArmed = true;
      gTrailPeak = gStatNet;
      if(first || TimeCurrent() >= nextSave)
        {
         SaveBasket();
         nextSave = TimeCurrent() + 10;
        }
     }
   if(gTrailArmed && gStatNet <= (gTrailPeak - InpBasketTrailDistance))
      CloseBasket("Trailing basket. Net profit mundur dari puncak " + DoubleToString(gTrailPeak, 2) +
                  " ke " + DoubleToString(gStatNet, 2) + ".", false);
  }

//+------------------------------------------------------------------+
bool OpenMarket(const int direction, const double slPrice, const double tpPrice,
                const string signalId, const double signalEntry, const bool isFirst)
  {
   if(!CanOpenPosition(direction, isFirst))
      return false;

   ENUM_ORDER_TYPE type = (direction > 0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   MqlTick tick;
   if(!SymbolInfoTick(InpSymbol, tick))
      return false;
   if(tick.ask <= 0.0 || tick.bid <= 0.0)
      return false;

   int digits = (int)SymbolInfoInteger(InpSymbol, SYMBOL_DIGITS);
   double sl = NormalizeDouble(slPrice, digits);
   double tp = NormalizeDouble(tpPrice, digits);
   double price = (direction > 0) ? tick.ask : tick.bid;
   double minDist = MinStopDistance();

   if(direction > 0)
     {
      if(!(sl < price && price < tp))
        {
         LogThrottled("geom", "BUY ditolak. Harga Valetax harus berada di antara SL dan TP sinyal.");
         return false;
        }
      if((price - sl) < minDist || (tp - price) < minDist)
        {
         LogThrottled("stops", "BUY ditolak. SL/TP sinyal lebih dekat dari batas broker.");
         gNextEntry = TimeCurrent() + 20;
         NoteOrderReject(isFirst, signalId);
         return false;
        }
     }
   else
     {
      if(!(tp < price && price < sl))
        {
         LogThrottled("geom", "SELL ditolak. Harga Valetax harus berada di antara TP dan SL sinyal.");
         return false;
        }
      if((price - tp) < minDist || (sl - price) < minDist)
        {
         LogThrottled("stops", "SELL ditolak. SL/TP sinyal lebih dekat dari batas broker.");
         gNextEntry = TimeCurrent() + 20;
         NoteOrderReject(isFirst, signalId);
         return false;
        }
     }

   int count = CountOurPositions();
   if(count >= gMaxLayers)
      return false;

   double lot = CalculateLotSize(type, price, sl, count);
   if(lot <= 0.0 || !ValidateRisk(type, price, sl, lot, count) || !OrderPrecheck(type, lot, price, sl))
     {
      double minLot = SymbolInfoDouble(InpSymbol, SYMBOL_VOLUME_MIN);
      double minLoss = 0.0;
      bool hasMinLoss = MoneyLoss(type, minLot, price, sl, minLoss);
      LogThrottled("lot", "Order dibatalkan sebelum OrderSend. Lot tidak dinaikkan paksa. "
                   + "Batas layer=" + DoubleToString(MoneyCapForNextLayer(count), 2)
                   + " " + AccountInfoString(ACCOUNT_CURRENCY)
                   + (hasMinLoss ? (", risiko lot minimum=" + DoubleToString(minLoss, 2)) : "")
                   + ".");
      gNextEntry = TimeCurrent() + 20;
      NoteOrderReject(isFirst, signalId);
      return false;
     }

   double loss = 0.0;
   if(!MoneyLoss(type, lot, price, sl, loss))
     {
      LogThrottled("loss", "Potensi rugi tidak bisa dihitung. Order dibatalkan.");
      NoteOrderReject(isFirst, signalId);
      return false;
     }

   double equityBefore = AccountInfoDouble(ACCOUNT_EQUITY);
   string comment = "tgL" + IntegerToString(count);
   gBusy = true;
   trade.SetExpertMagicNumber(InpMagic);
   bool ok = (direction > 0)
             ? trade.Buy(lot, InpSymbol, price, sl, 0.0, comment)
             : trade.Sell(lot, InpSymbol, price, sl, 0.0, comment);
   gBusy = false;
   gNextEntry = TimeCurrent() + (ok ? 5 : 20);
   if(!ok)
     {
      LogThrottled("send", (direction > 0 ? "BUY gagal: " : "SELL gagal: ") + trade.ResultRetcodeDescription());
      NoteOrderReject(isFirst, signalId);
      return false;
     }

   double filled = lot;
   ulong deal = trade.ResultDeal();
   if(deal != 0 && HistoryDealSelect(deal))
     {
      double dealVolume = HistoryDealGetDouble(deal, DEAL_VOLUME);
      if(dealVolume > 0.0)
         filled = dealVolume;
     }

   if(isFirst || gBaseLot <= 0.0)
      gBaseLot = filled;
   if(isFirst || gStartEquity <= 0.0)
      gStartEquity = equityBefore;
   if(isFirst || gBasketOpened <= 0)
      gBasketOpened = TimeCurrent();
   gDirection = direction;
   gSl = sl;
   gTp = tp;
   gLastLayerPrice = price;
   gExtreme = price;
   if(isFirst)
     {
      gPeakNet = 0.0;
      gTrailPeak = 0.0;
      gTrailArmed = false;
      gBreakEvenDone = false;
     }
   if(signalEntry > 0.0)
      gEntry = signalEntry;
   if(signalId != "")
      gBasketId = signalId;
   SaveBasket();

   double used = 0.0;
   BasketPotentialLoss(used);
   Print((direction > 0 ? "BUY" : "SELL"),
         " OK layer ", count + 1, "/", gMaxLayers,
         " @", DoubleToString(price, digits),
         " SL=", DoubleToString(sl, digits),
         " TP sinyal=", DoubleToString(tp, digits),
         " lot=", DoubleToString(filled, VolumeDigits(SymbolInfoDouble(InpSymbol, SYMBOL_VOLUME_STEP))),
         " risikoOrder=", DoubleToString(loss, 2),
         " potensiBasket=", DoubleToString(used, 2),
         " ", AccountInfoString(ACCOUNT_CURRENCY),
         " equityAwal=", DoubleToString(gStartEquity, 2));
   return true;
  }

//+------------------------------------------------------------------+
void CalculateBasketStats()
  {
   RefreshBasketStats();
  }

//+------------------------------------------------------------------+
bool CheckBasketSL()
  {
   double stopMoney = BasketStopMoney();
   if(stopMoney <= 0.0 || gStatNet > -stopMoney)
      return false;
   CloseBasket("Basket SL tercapai. Net " + DoubleToString(gStatNet, 2) +
               ". Averaging dihentikan sampai cooldown atau sinyal berikutnya.", true);
   return true;
  }

//+------------------------------------------------------------------+
bool CheckBasketTP()
  {
   MqlTick tick;
   if(!SymbolInfoTick(InpSymbol, tick))
      return false;
   double target = BasketTargetMoney();
   if(target > 0.0 && gStatNet >= target)
     {
      CloseBasket("Basket TP tercapai. Net " + DoubleToString(gStatNet, 2) +
                  " dari equity awal " + DoubleToString(gStartEquity, 2) + ". State basket di-reset.", false);
      return true;
     }
   if(gDirection > 0 && gTp > 0.0 && tick.bid >= gTp)
     {
      CloseBasket("Harga menyentuh TP sinyal. Seluruh basket ditutup.", false);
      return true;
     }
   if(gDirection < 0 && gTp > 0.0 && tick.ask <= gTp)
     {
      CloseBasket("Harga menyentuh TP sinyal. Seluruh basket ditutup.", false);
      return true;
     }
   if(gDirection > 0 && gSl > 0.0 && tick.bid <= gSl)
     {
      CloseBasket("Harga menyentuh SL sinyal. Seluruh basket ditutup.", true);
      return true;
     }
   if(gDirection < 0 && gSl > 0.0 && tick.ask >= gSl)
     {
      CloseBasket("Harga menyentuh SL sinyal. Seluruh basket ditutup.", true);
      return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
void ManageBasketTrailing()
  {
   ManageTrailing();
  }

//+------------------------------------------------------------------+
void ManageExits()
  {
   CalculateBasketStats();
   if(CountOurPositions() <= 0)
     {
      if(gDirection != 0 || gBasketId != "")
        {
         if(gLastNet <= 0.0 && gBasketOpened != 0)
            StartCooldown();
         ClearBasket();
        }
      return;
     }

   MqlTick tick;
   if(SymbolInfoTick(InpSymbol, tick))
      UpdateExtreme(tick);

   if(CheckBasketSL())
      return;
   if(CheckBasketTP())
      return;

   ManageBasketTrailing();
   ManageBreakEven();
  }

//+------------------------------------------------------------------+
bool FeedStillMatches()
  {
   if(gDirection == 0 || gBasketId == "" || gFeedId == "" || gFeedAction == "")
      return false;
   int stale = MathMax(InpPollSeconds * 3, 30);
   if(gFeedTs <= 0 || gFeedSeen <= 0 || (TimeCurrent() - gFeedSeen) > stale)
      return false;
   if(gFeedId != gBasketId)
      return false;
   if(gDirection > 0)
      return (gFeedAction == "buy");
   return (gFeedAction == "sell");
  }

//+------------------------------------------------------------------+
bool VolumeIsValid(const double lot)
  {
   double step = SymbolInfoDouble(InpSymbol, SYMBOL_VOLUME_STEP);
   double minLot = SymbolInfoDouble(InpSymbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(InpSymbol, SYMBOL_VOLUME_MAX);
   if(lot <= 0.0 || step <= 0.0 || minLot <= 0.0)
      return false;
   if(lot + 1e-8 < minLot)
      return false;
   if(maxLot > 0.0 && lot > maxLot + 1e-8)
      return false;
   double steps = lot / step;
   return (MathAbs(steps - MathRound(steps)) <= 1e-3);
  }

//+------------------------------------------------------------------+
ENUM_ORDER_TYPE_FILLING FillingMode()
  {
   int filling = (int)SymbolInfoInteger(InpSymbol, SYMBOL_FILLING_MODE);
   if((filling & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK)
      return ORDER_FILLING_FOK;
   if((filling & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC)
      return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN;
  }

//+------------------------------------------------------------------+
bool OrderPrecheck(const ENUM_ORDER_TYPE type, const double lot, const double price, const double sl)
  {
   if(!VolumeIsValid(lot))
     {
      LogThrottled("volume", "Volume tidak valid untuk broker. Order tidak dikirim.");
      return false;
     }
   MqlTradeRequest request;
   MqlTradeCheckResult check;
   ZeroMemory(request);
   ZeroMemory(check);
   request.action = TRADE_ACTION_DEAL;
   request.symbol = InpSymbol;
   request.volume = lot;
   request.type = type;
   request.price = price;
   request.sl = sl;
   request.tp = 0.0;
   request.deviation = InpMaxSlippagePts;
   request.magic = InpMagic;
   request.type_filling = FillingMode();
   if(OrderCheck(request, check))
      return true;
   LogThrottled("check", "OrderCheck menolak order " + IntegerToString((int)check.retcode) + " " + check.comment);
   return false;
  }

//+------------------------------------------------------------------+
double CalculateLotSize(const ENUM_ORDER_TYPE type, const double price, const double sl, const int count)
  {
   return ComputeLot(type, price, sl, count);
  }

//+------------------------------------------------------------------+
bool ValidateRisk(const ENUM_ORDER_TYPE type, const double price, const double sl,
                  const double lot, const int count)
  {
   if(!VolumeIsValid(lot))
      return false;
   double loss = 0.0;
   if(!MoneyLoss(type, lot, price, sl, loss))
      return false;
   double cap = MoneyCapForNextLayer(count);
   if(cap <= 0.0 || loss > cap + 1e-6)
      return false;
   double used = 0.0;
   if(!BasketPotentialLoss(used))
      return false;
   if((used + loss) > HardMoney() + 1e-6)
      return false;
   return MarginAllows(type, price, lot);
  }

//+------------------------------------------------------------------+
bool CanOpenPosition(const int direction, const bool isFirst)
  {
   if(!gLockOwned || gBusy)
      return false;
   if(TimeCurrent() < gNextEntry)
      return false;
   if(direction != 1 && direction != -1)
      return false;
   if(ProtectionBlocksEntry())
     {
      LogThrottled("pause", "Entri ditahan proteksi, margin rendah, cooldown, atau emergency.");
      return false;
     }
   if(AccountInfoDouble(ACCOUNT_EQUITY) <= 0.0)
      return false;
   ENUM_ORDER_TYPE type = (direction > 0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   if(!EntryAllowed(type))
     {
      LogThrottled("trade", "Trading tidak diizinkan terminal, akun, atau symbol.");
      return false;
     }
   if(!SpreadOk())
     {
      LogThrottled(isFirst ? "spread" : "spread-layer", "Spread melebihi MaxSpread. Tidak ada entri.");
      return false;
     }
   if(ForeignNetPosition())
     {
      LogThrottled("foreign", "Posisi manual atau EA lain ada di symbol ini pada akun netting. EA tidak menambah dan tidak menutupnya.");
      return false;
     }
   int count = CountOurPositions();
   if(count >= gMaxLayers)
     {
      LogThrottled("cap", "Batas MaxLayers tercapai. Tidak ada posisi baru.");
      return false;
     }
   if(isFirst && count > 0)
      return false;
   if(!isFirst && (!gUseLayering || count <= 0))
      return false;
   return true;
  }

//+------------------------------------------------------------------+
bool CanAddLayer()
  {
   if(!gUseLayering || gDirection == 0 || gSl <= 0.0 || gTp <= 0.0)
      return false;
   int count = CountOurPositions();
   if(count <= 0 || count >= gMaxLayers)
      return false;
   if(!FeedStillMatches())
     {
      LogThrottled("feed", "Layer ditahan. Feed VPS putus, timeout, restart, atau arah sinyal sudah berubah.");
      return false;
     }
   if(!CanOpenPosition(gDirection, false))
      return false;
   if(!SignalStructureOk(gDirection))
     {
      LogThrottled("dir", "Layer ditolak. Arah sinyal sudah tidak valid terhadap SL/TP.");
      return false;
     }
   return LayerTriggerReady();
  }

//+------------------------------------------------------------------+
void NoteOrderReject(const bool isFirst, const string signalId)
  {
   if(!isFirst || signalId == "")
      return;
   if(gFailId != signalId)
     {
      gFailId = signalId;
      gFailCount = 0;
     }
   gFailCount++;
   if(gFailCount < 3)
      return;
   Print("Sinyal yang sama ditolak 3 kali. ID ditutup supaya EA tidak mengulang order tanpa batas. id=", signalId);
   SaveLastId(signalId);
   gFailCount = 0;
  }

//+------------------------------------------------------------------+
void ManageLayers()
  {
   if(!CanAddLayer())
      return;
   OpenMarket(gDirection, gSl, gTp, gBasketId, gEntry, false);
  }

//+------------------------------------------------------------------+
void ManagePositions()
  {
   if(gBusy)
      return;
   EnsureLayeringMode();
   EnsureDayAnchor(false);
   RecoverBasket();
   RepairMissingStops();
   EvaluateProtection();
   ManageExits();
   ManageLayers();
  }

//+------------------------------------------------------------------+
string PauseText()
  {
   if(!TradingAllowed())
      return "trading terminal mati";
   if(gDdLatched)
      return "proteksi MaxDrawdown, ganti ProtectionResetID";
   if(gDailyLatched)
      return "proteksi rugi harian sampai besok";
   if(TimeCurrent() < gEmergencyUntil)
      return "jeda setelah emergency close";
   if(gMarginEmergency)
      return "emergency margin";
   if(gMarginBlocked)
      return "margin di bawah MinMarginLevel";
   if(TimeCurrent() < gCooldownUntil)
      return "cooldown setelah basket SL";
   if(CountOurPositions() > 0)
      return "basket aktif";
   return "menunggu sinyal";
  }

//+------------------------------------------------------------------+
void UpdatePanel()
  {
   if(TimeCurrent() == gPanelAt)
      return;
   gPanelAt = TimeCurrent();
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double margin = AccountInfoDouble(ACCOUNT_MARGIN);
   double level = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
   string levelText = (margin > 0.0) ? DoubleToString(level, 0) + "%" : "n/a";
   string cur = AccountInfoString(ACCOUNT_CURRENCY);
   string text = "XAUUSD Telegram Exec 2.20\n";
   text += LotModeName() + " | " + TriggerName() + " " + LayerLotName()
           + " " + IntegerToString(gStatCount) + "/" + IntegerToString(gMaxLayers) + "\n";
   text += "Equity " + DoubleToString(equity, 2) + " " + cur
           + " | bebas " + DoubleToString(AccountInfoDouble(ACCOUNT_MARGIN_FREE), 2)
           + " | margin " + levelText + "\n";
   text += "Net " + DoubleToString(gStatNet, 2)
           + " | float " + DoubleToString(gStatFloat, 2)
           + " | swap " + DoubleToString(gStatSwap, 2)
           + " | comm " + DoubleToString(gStatComm, 2) + "\n";
   text += "Volume " + DoubleToString(gStatVolume, 2)
           + " | avg " + DoubleToString(gStatAvg, (int)SymbolInfoInteger(InpSymbol, SYMBOL_DIGITS))
           + " | DD basket " + DoubleToString(gStatDd, 2) + "\n";
   text += "Status: " + PauseText();
   Comment(text);
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
void PollSignal()
  {
   uchar data[];
   uchar result[];
   string resultHeaders;
   string headers = "X-Signal-Token: " + InpSignalToken + "\r\n";
   int code = WebRequest("GET", InpSignalUrl, headers, 5000, data, result, resultHeaders);
   if(code == -1)
     {
      LogThrottled("web", "WebRequest gagal (" + IntegerToString(GetLastError())
                   + "). Izinkan URL ini di Tools -> Options -> Expert Advisors: " + InpSignalUrl);
      return;
     }
   if(code != 200)
     {
      LogThrottled("http", "Feed sinyal HTTP " + IntegerToString(code));
      return;
     }

   string json = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
   string action, id, symbol;
   double entry = 0.0, tp = 0.0, sl = 0.0, ts = 0.0;
   if(!JsonString(json, "action", action) || !JsonString(json, "id", id))
     {
      LogThrottled("json", "JSON sinyal tidak lengkap");
      return;
     }
   JsonString(json, "symbol", symbol);
   JsonNumber(json, "entry", entry);
   JsonNumber(json, "tp", tp);
   JsonNumber(json, "sl", sl);
   JsonNumber(json, "ts", ts);
   if(symbol != "" && symbol != "XAUUSD")
     {
      Print("Sinyal bukan XAUUSD, dilewati: ", symbol);
      return;
     }
   gFeedAction = action;
   gFeedId = id;
   gFeedTs = (long)ts;
   gFeedSeen = TimeCurrent();

   if(id == "" || id == lastDoneId)
      return;
   if(action == "none")
      return;

   if(action == "close")
     {
      CloseOurPositions();
      if(CountOurPositions() == 0)
        {
         ClearBasket();
         SaveLastId(id);
        }
      else
         LogThrottled("close", "Close Telegram belum selesai. Hanya posisi magic ini yang ditutup, lalu dicoba lagi.");
      return;
     }

   if(action != "buy" && action != "sell")
      return;

   long age = (long)TimeGMT() - (long)ts;
   if(ts <= 0.0 || age > InpMaxSignalAgeSec)
     {
      if(lastLoggedSkip != id)
        {
         Print("Sinyal kedaluwarsa, tidak dikejar. id=", id, " umur=", age, "s");
         lastLoggedSkip = id;
        }
      return;
     }

   if(!SignalLevelsOk(action, entry, sl, tp))
     {
      Print("Struktur SL/TP sinyal ditolak. id=", id, " entry=", entry, " sl=", sl, " tp=", tp);
      SaveLastId(id);
      return;
     }

   if(ProtectionBlocksEntry())
     {
      LogThrottled("pause-signal", "Sinyal baru ditahan proteksi. id=" + id);
      return;
     }

   if(CountOurPositions() > 0)
     {
      Print("Basket masih terbuka. Sinyal baru tidak menambah posisi. id=", id);
      SaveLastId(id);
      return;
     }

   int direction = (action == "sell") ? -1 : 1;
   if(OpenMarket(direction, sl, tp, id, entry, true))
      SaveLastId(id);
  }
//+------------------------------------------------------------------+
