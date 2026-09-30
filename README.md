# XAUUSD Bot — Valetax MT5

Broker: **Valetax** · Platform: **MetaTrader 5** · Pair: **XAUUSD**

### Setting akun Anda
| Item | Nilai |
|------|--------|
| Mode | **DEMO** |
| Server | **ValetaxIntl-Live7** |
| Symbol | **XAUUSD** |
| Lot | **0.01** |

> Tidak ada jaminan untung. Tetap uji di DEMO dulu sebelum Live.

## Eksekusi sinyal Telegram

Bot Telegram tetap yang menentukan Entry, TP, dan SL. MT5 hanya membeli XAUUSD dengan angka itu, lot tetap **0.01**.

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
   - `InpLot` = `0.01`
   - `InpSymbol` = `XAUUSD`
6. Centang **Allow Algo Trading**
7. Tools → Options → Expert Advisors → centang **Allow WebRequest**, lalu tambahkan URL yang sama persis dengan `InpSignalUrl`
8. Tekan **Algo Trading** di toolbar sampai hijau

BUY hanya diambil jika sinyal masih baru (paling lama 3 menit) dan EA sedang jalan. TP dan SL di order sama dengan pesan bot. Saat bot mengirim TP atau SL, EA menutup posisi yang masih terbuka.

### 4. Parameter EA

| Input | Default | Arti |
|-------|---------|------|
| `InpLot` | 0.01 | Lot tetap |
| `InpSymbol` | XAUUSD | Harus sama dengan Market Watch Valetax |
| `InpSignalUrl` | kosong | Alamat feed sinyal |
| `InpMaxSignalAgeSec` | 180 | BUY yang lebih tua dari ini tidak dikejar |

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
4. Lot yang diinginkan (contoh 0.01)

**Jangan kirim password trading** di chat.
