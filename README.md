# XAUUSD Bot — Valetax MT5

Broker: **Valetax** · Platform: **MetaTrader 5** · Pair: **XAUUSD**

### Setting akun Anda
| Item | Nilai |
|------|--------|
| Mode | **DEMO** |
| Server | **ValetaxIntl-Live7** |
| Symbol | **XAUUSD** |
| Lot | **dihitung dari equity dan jarak SL** |

> Tidak ada jaminan untung. Tetap uji di DEMO dulu sebelum Live.

## Eksekusi sinyal Telegram

Bot Telegram tetap yang menentukan arah, Entry, TP, dan SL. MT5 mengeksekusi XAUUSD dengan angka itu. Ukuran lot dihitung ulang dari equity saat itu dan jarak SL, lalu dibatasi risiko basket. Bukan jaminan untung.

Pasang `mt5/XAUUSD_TelegramExec.mq5` di chart XAUUSD. Jangan pasang bersamaan dengan `XAUUSD_Valetax_Bot.mq5` (EA itu punya sinyal sendiri).

Terminal MT5 Valetax harus sudah terbuka dan login. Posisi yang sama lalu terlihat di aplikasi ponsel.

## Setup Valetax MT5 (langkah demi langkah)

### 1. Download MT5 Valetax
Dari [valetax.com/trading-platforms](https://valetax.com/trading-platforms/) pilih server yang sama dengan akun Anda, misalnya:
- Live 2 / Live 3 / Live 5 / Live 7 / Live 8

### 2. Login akun trading (DEMO)
Di MT5 → **File → Login to Trade Account**:
- **Login** = nomor akun DEMO
- **Password** = password trading
- **Server** = `ValetaxIntl-Live7`

### 3. Pasang EA eksekusi Telegram
1. Salin `mt5/XAUUSD_TelegramExec.mq5` ke `File → Open Data Folder → MQL5 → Experts`
2. Navigator → klik kanan **Experts** → **Refresh**, lalu compile
3. Buka chart **XAUUSD**
4. Drag EA `XAUUSD_TelegramExec` ke chart
5. Isi:
   - `InpSignalUrl` = `http://ALAMAT-SERVER:8787/signal`
   - `InpSignalToken` = nilai `MT5_SIGNAL_TOKEN` di `.env`
   - `InpSymbol` = `XAUUSD`
   - `InpLotMode` = `RiskPercent` (default)
   - `InpRiskPerBasketPercent` = `1.0`
   - `InpMaxRiskPerBasketPercent` = `1.5`
6. Centang **Allow Algo Trading**
7. Tools → Options → Expert Advisors → centang **Allow WebRequest**, lalu tambahkan URL yang sama persis dengan `InpSignalUrl`
8. Tekan **Algo Trading** di toolbar sampai hijau

BUY dan SELL hanya diambil jika sinyal masih baru (paling lama 3 menit), struktur SL/TP valid, dan EA sedang jalan. Satu sinyal membuka satu basket. Untuk SELL, TP ada di bawah entry dan SL di atas entry. SL posisi mengikuti sinyal. Keluarnya basket memakai net profit, dan seluruh posisi dalam siklus itu ditutup bersamaan. Sinyal `close` menutup posisi magic EA ini saja.

Lot dihitung ulang dari equity saat order dikirim: risiko uang = equity x persentase, lot = risiko uang / kerugian per lot sampai SL. Equity naik, batas risiko ikut naik. Equity turun, lot ikut turun.

Pada akun cent, saldo sering tampil dalam USC. `RiskPercent`, target basket, dan batas rugi memakai mata uang akun. Equity 10000 USC dengan target 1% berarti profit basket 100 USC. Jika lot minimum broker sudah lebih besar daripada batas risiko, EA tidak membuka order.

### 4. Parameter EA

| Input | Default | Arti |
|-------|---------|------|
| `InpLotMode` | RiskPercent | Fixed, BalanceBased, EquityBased, atau RiskPercent |
| `InpLot` | 0.01 | Dipakai hanya pada mode Fixed |
| `InpBaseLot` / `InpBaseCapital` | 0.01 / 100 | Skala mode Balance dan Equity, dalam mata uang akun |
| `InpRiskPerBasketPercent` | 1.0 | Target risiko satu basket, persen equity |
| `InpMaxRiskPerBasketPercent` | 1.5 | Batas keras. Layer baru ditolak jika potensi rugi melewati ini |
| `InpEnableLayering` | true | Layer tambahan, bukan otomatis saat posisi rugi |
| `InpMaxLayers` | 3 | Paling banyak 5 posisi per basket |
| `InpLayerTriggerMode` | ATR | FavorableMove, Pullback, ATR, atau Disabled |
| `InpLayerATRMultiplier` | 1.0 | Jarak antar layer, dalam kelipatan ATR M15 |
| `InpLayerLotMode` | RiskBased | SameLot, RiskBased, atau MildMultiplier |
| `InpMildMultiplier` | 1.25 | Pengali linear, dibatasi 1.00–1.35 |
| `InpBasketTPMode` | EquityPercent | FixedMoney, EquityPercent, atau RiskMultiple |
| `InpBasketTPPercent` | 1.0 | Target net profit, persen dari equity saat basket dimulai |
| `InpBasketSLPercent` | 2.0 | Batas net loss basket, lalu cooldown |
| `InpBasketCooldownMinutes` | 30 | Jeda entri baru setelah basket SL. 0 = sinyal berikutnya saja |
| `InpEnableBreakEven` | true | Geser SL ke sekitar harga rata-rata setelah profit cukup |
| `InpBreakEvenTriggerPercent` | 0.50 | Net profit pemicu break-even, persen equity awal basket |
| `InpBreakEvenOffset` | 20 | Jarak SL dari harga rata-rata, dalam points |
| `InpEnableBasketTrailing` | false | Trailing memakai net profit, angka dalam mata uang akun |
| `InpDailyLossLimitPercent` | 2.0 | Berhenti sampai hari broker berikutnya. State tetap tersimpan |
| `InpMaxDrawdownPercent` | 8.0 | Dari puncak equity. Reset dengan mengganti `InpProtectionResetID` |
| `InpMinMarginLevel` | 300 | Tolak order baru di bawah level ini |
| `InpEmergencyMarginLevel` | 200 | Tutup basket sebelum stop-out broker |
| `InpMinimumFreeMarginPercent` | 50 | Free margin minimum dibanding equity setelah order |
| `InpMaxSpread` | 100 | Spread maksimum dalam points. Di atas ini tidak ada entri |
| `InpSymbol` | XAUUSD | Harus sama dengan Market Watch Valetax |
| `InpMagic` | 26093001 | Hanya posisi magic ini yang dikelola |
| `InpSignalUrl` | kosong | Alamat feed sinyal |
| `InpMaxSignalAgeSec` | 180 | Sinyal yang lebih tua dari ini tidak dikejar |

Jika symbol di Valetax bertuliskan `XAUUSDm` / `XAUUSD.` dll, ubah `InpSymbol` sesuai.

## File di project

```
xauusd-bot/
├── mt5/XAUUSD_TelegramExec.mq5  ← pasang ini di Valetax MT5
├── mt5/XAUUSD_Valetax_Bot.mq5   ← sinyal EMA sendiri, jangan dipasang bersamaan
├── bot.py                       ← backtest/paper (Yahoo GC=F)
├── mt5_bridge.py                ← cek koneksi (Windows saja)
└── config/valetax.env.example   ← template kredensial (jangan share)
```

## Backtest/paper di server ini (tanpa MT5)

```bash
cd /root/projects/xauusd-bot
source .venv/bin/activate
python bot.py --mode backtest --interval 1h
```

## Yang saya butuhkan dari Anda (tanpa password)

Balas dengan data ini saja supaya setting bisa dipastikan:

1. Akun **Demo** atau **Live**?
2. Nama **server** persis (dari Member Area)
3. Nama **symbol emas** di Market Watch (XAUUSD / XAUUSDm / …)
4. Mata uang akun di MT5 (USD atau USC untuk akun cent)

**Jangan kirim password trading** di chat.
