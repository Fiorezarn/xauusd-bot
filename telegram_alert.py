"""
Alert Telegram XAUUSD — kapan BUY dan kapan SELL.
Kirim ke bot @Rezaaaagoldbot. Bukan jaminan untung.
"""

from __future__ import annotations

import json
import os
import threading
import time
import traceback
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
import pandas as pd
import yfinance as yf

from signal_feed import SignalFeed

ROOT = Path(__file__).resolve().parent
ENV_FILE = ROOT / ".env"
SUBS_FILE = ROOT / "subscribers.json"
STATE_FILE = ROOT / "alert_state.json"

SYMBOL = "GC=F"
INTERVAL = "15m"
LOOKBACK = "5d"
FAST = 9
SLOW = 21
RSI_PERIOD = 14
RSI_OB = 65.0
# Jarak sama. TP 0,40% lebih jauh dari gerak biasa candle 15 menit,
# jadi harga lebih sering menyentuh SL 0,25% lebih dulu.
TP_PCT = 0.25
SL_PCT = 0.25
POLL_MARKET_SEC = 30
# Ganti keduanya setiap ada perubahan aturan, supaya user dapat kabar sekali.
UPDATE_ID = "2026-09-28-tp-sl"
UPDATE_TEXT = (
    "Update sinyal XAUUSD\n\n"
    "TP sekarang sama dengan SL, masing-masing 0,25%.\n"
    "BUY dilewati jika candle sinyal sudah menyentuh area SL.\n"
    "Posisi hanya ditutup saat TP atau SL kena.\n\n"
    "Laporan tetap sama: kalau TP ya TP, kalau SL ya SL."
)


def load_env_value(key: str, default: str = "") -> str:
    # File .env diutamakan supaya nilai bot lain di environment tidak kepakai.
    if ENV_FILE.exists():
        for line in ENV_FILE.read_text().splitlines():
            if line.startswith(f"{key}="):
                value = line.split("=", 1)[1].strip()
                if value:
                    return value
    return os.environ.get(key, default).strip()


def load_token() -> str:
    token = load_env_value("TELEGRAM_BOT_TOKEN")
    if token:
        return token
    raise SystemExit("TELEGRAM_BOT_TOKEN tidak ada")


TOKEN = load_token()
API = f"https://api.telegram.org/bot{TOKEN}"
FEED: SignalFeed | None = None


def api(method: str, payload: dict | None = None, timeout: int = 35) -> dict:
    data = None
    headers = {}
    if payload is not None:
        data = urllib.parse.urlencode(payload).encode()
        headers["Content-Type"] = "application/x-www-form-urlencoded"
    req = urllib.request.Request(f"{API}/{method}", data=data, headers=headers)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        body = json.loads(resp.read().decode())
    if not body.get("ok"):
        raise RuntimeError(f"Telegram {method} gagal: {body}")
    return body["result"]


def send(chat_id: int, text: str) -> None:
    api(
        "sendMessage",
        {
            "chat_id": str(chat_id),
            "text": text,
            "disable_web_page_preview": "true",
        },
    )


def load_json(path: Path, default):
    if not path.exists():
        return default
    try:
        return json.loads(path.read_text())
    except json.JSONDecodeError:
        return default


def save_json(path: Path, data) -> None:
    path.write_text(json.dumps(data, indent=2))


def ema(series: pd.Series, period: int) -> pd.Series:
    return series.ewm(span=period, adjust=False).mean()


def rsi(series: pd.Series, period: int) -> pd.Series:
    delta = series.diff()
    gain = delta.clip(lower=0.0)
    loss = -delta.clip(upper=0.0)
    avg_gain = gain.ewm(alpha=1 / period, min_periods=period, adjust=False).mean()
    avg_loss = loss.ewm(alpha=1 / period, min_periods=period, adjust=False).mean()
    rs = avg_gain / avg_loss.replace(0, np.nan)
    return 100 - (100 / (1 + rs))


def fetch_spot() -> float:
    """Harga spot XAUUSD. GC=F (futures Yahoo) biasanya puluhan dolar di atas chart MT5."""
    req = urllib.request.Request(
        "https://forex-data-feed.swissquote.com/public-quotes/bboquotes/instrument/XAU/USD",
        headers={"User-Agent": "Mozilla/5.0"},
    )
    with urllib.request.urlopen(req, timeout=20) as resp:
        data = json.loads(resp.read().decode())
    quote = data[0]["spreadProfilePrices"][0]
    px = (float(quote["bid"]) + float(quote["ask"])) / 2
    if px < 1000:
        raise RuntimeError(f"harga spot tidak masuk akal: {px}")
    return px


def fetch_signal() -> dict:
    df = yf.Ticker(SYMBOL).history(period=LOOKBACK, interval=INTERVAL, auto_adjust=True)
    if df.empty or len(df) < SLOW + 5:
        raise RuntimeError("Data harga emas kosong")
    df = df[["Open", "High", "Low", "Close"]].dropna()
    df["fast"] = ema(df["Close"], FAST)
    df["slow"] = ema(df["Close"], SLOW)
    df["rsi"] = rsi(df["Close"], RSI_PERIOD)
    # candle terakhir yang sudah tutup (hindari sinyal berubah-ubah di candle jalan)
    closed = df.iloc[-2]
    prev = df.iloc[-3]
    fast_now = float(closed["fast"])
    slow_now = float(closed["slow"])
    rsi_now = float(closed["rsi"])
    fast_prev = float(prev["fast"])
    slow_prev = float(prev["slow"])
    cross_up = fast_now > slow_now and fast_prev <= slow_prev
    cross_dn = fast_now < slow_now and fast_prev >= slow_prev
    # Jangan BUY kalau candle sinyal sendiri sudah turun sejauh SL.
    # Entry di harga close itu sudah telat: area SL ada di dalam candle yang sama.
    close_px = float(closed["Close"])
    dipped = (close_px - float(closed["Low"])) / close_px * 100
    sl_clear = dipped < SL_PCT

    if cross_up and rsi_now < RSI_OB and sl_clear:
        side = "BUY"
        reason = "EMA 9 memotong ke atas EMA 21, RSI belum jenuh, candle sinyal belum menembus area SL."
    elif cross_up and rsi_now < RSI_OB:
        side = "WAIT"
        reason = "EMA menyilang naik, tapi candle sinyal sudah menyentuh jarak SL. Entry dilewati."
    elif cross_dn:
        side = "SELL"
        reason = "EMA 9 memotong ke bawah EMA 21."
    elif rsi_now >= RSI_OB and fast_now > slow_now:
        side = "SELL"
        reason = f"RSI {rsi_now:.1f} jenuh beli — sebaiknya ambil profit / jangan kejar."
    elif fast_now > slow_now and rsi_now < RSI_OB:
        side = "HOLD_BUY"
        reason = "Tren masih naik (EMA 9 di atas EMA 21). Tahan posisi beli, jangan entry baru di tengah."
    else:
        side = "WAIT"
        reason = "Belum ada sinyal beli. Tunggu EMA 9 memotong ke atas EMA 21."

    spot = fetch_spot()
    return {
        "side": side,
        "price": round(spot, 2),
        "live": round(spot, 2),
        "futures": round(float(df.iloc[-1]["Close"]), 2),
        "reason": reason,
        "sl": round(spot * (1 - SL_PCT / 100), 2),
        "tp": round(spot * (1 + TP_PCT / 100), 2),
    }


def format_entry(sig: dict) -> str:
    return f"XAUUSD BUY\nEntry: {sig['price']:.2f}\nTP: {sig['tp']:.2f}\nSL: {sig['sl']:.2f}"


def format_hit(label: str, level: float) -> str:
    return f"XAUUSD\n{label}: {level:.2f}\nTutup posisi"


def format_status(sig: dict, state: dict) -> str:
    pos = state.get("position")
    if pos:
        return (
            f"XAUUSD BUY\n"
            f"Entry: {pos['entry']:.2f}\n"
            f"TP: {pos['tp']:.2f}\n"
            f"SL: {pos['sl']:.2f}\n"
            f"Harga: {sig['live']:.2f}"
        )
    return f"Belum ada entry.\nHarga: {sig['live']:.2f}"


def subscribers() -> list[int]:
    data = load_json(SUBS_FILE, {"chats": []})
    return [int(x) for x in data.get("chats", [])]


def add_subscriber(chat_id: int) -> bool:
    data = load_json(SUBS_FILE, {"chats": []})
    chats = [int(x) for x in data.get("chats", [])]
    new = chat_id not in chats
    if new:
        chats.append(chat_id)
        save_json(SUBS_FILE, {"chats": chats})
    return new


def broadcast(text: str) -> None:
    for chat_id in subscribers():
        try:
            send(chat_id, text)
        except Exception as exc:
            print(f"[warn] gagal kirim ke {chat_id}: {exc}", flush=True)


def announce_update() -> None:
    """Kabar ke semua user sekali tiap UPDATE_ID berubah. Restart biasa tidak mengirim ulang."""
    state = load_json(STATE_FILE, {})
    if state.get("notified_update") == UPDATE_ID:
        return
    broadcast(UPDATE_TEXT)
    state["notified_update"] = UPDATE_ID
    save_json(STATE_FILE, state)
    print(f"[alert] update dikirim {UPDATE_ID}", flush=True)


def handle_message(msg: dict, sig_cache: dict) -> None:
    chat = msg.get("chat") or {}
    chat_id = chat.get("id")
    if chat_id is None:
        return
    text = (msg.get("text") or "").strip()
    cmd = text.split()[0].split("@")[0].lower() if text.startswith("/") else ""

    if cmd in ("/start", "/signal", "/status", ""):
        add_subscriber(int(chat_id))
        try:
            sig = fetch_signal()
            sig_cache.clear()
            sig_cache.update(sig)
        except Exception as exc:
            send(chat_id, f"Belum bisa ambil harga emas: {exc}")
            return
        state = load_json(STATE_FILE, {})
        send(chat_id, "Tidak perlu ketik apa-apa.\nEntry, TP, dan SL saya kirim sendiri.\n\n" + format_status(sig, state))
        return

    send(chat_id, "Tidak perlu ketik apa-apa. Saya kirim sendiri kalau ada entry, TP, atau SL.")


def check_market(last_side: str | None) -> str | None:
    sig = fetch_signal()
    state = load_json(STATE_FILE, {})
    pos = state.get("position")
    side = sig["side"]
    price = sig["live"]

    opened = False
    closed_label = ""
    if pos:
        if price >= pos["tp"]:
            broadcast(format_hit("TP", pos["tp"]))
            print(f"[alert] TP {pos['tp']}", flush=True)
            closed_label = "TP"
            pos = None
        elif price <= pos["sl"]:
            broadcast(format_hit("SL", pos["sl"]))
            print(f"[alert] SL {pos['sl']}", flush=True)
            closed_label = "SL"
            pos = None
    elif side == "BUY" and last_side != "BUY":
        stamp = int(time.time())
        pos = {
            "entry": sig["price"],
            "tp": sig["tp"],
            "sl": sig["sl"],
            "id": f"buy-{stamp}",
            "ts": stamp,
        }
        broadcast(format_entry(sig))
        print(f"[alert] BUY {sig['price']} tp {sig['tp']} sl {sig['sl']}", flush=True)
        opened = True

    if FEED is not None and opened and pos:
        FEED.publish_buy(
            pos["entry"],
            pos["tp"],
            pos["sl"],
            signal_id=pos["id"],
            ts=pos["ts"],
        )
    elif FEED is not None and closed_label:
        FEED.publish_close(closed_label)

    prev = load_json(STATE_FILE, {})
    save_json(
        STATE_FILE,
        {
            "side": side,
            "price": sig["price"],
            "position": pos,
            "at": datetime.now(timezone.utc).isoformat(),
            "notified_update": prev.get("notified_update"),
        },
    )
    return side


def main() -> None:
    me = api("getMe")
    print(f"[ok] bot @{me.get('username')} siap", flush=True)
    api(
        "setMyCommands",
        {
            "commands": json.dumps(
                [
                    {"command": "signal", "description": "Entry, TP, SL"},
                    {"command": "status", "description": "Entry, TP, SL"},
                    {"command": "help", "description": "Bantuan"},
                ]
            )
        },
    )
    try:
        api("deleteWebhook", {"drop_pending_updates": "false"})
    except Exception:
        pass

    offset = 0
    sig_cache: dict = {}
    announce_update()

    global FEED
    feed_port = int(load_env_value("MT5_SIGNAL_PORT", "8787") or "8787")
    FEED = SignalFeed(load_env_value("MT5_SIGNAL_TOKEN"), port=feed_port)
    state = load_json(STATE_FILE, {})
    pos = state.get("position")
    if pos:
        opened_at = state.get("at") or ""
        ts = int(time.time())
        try:
            ts = int(datetime.fromisoformat(opened_at).timestamp())
        except (TypeError, ValueError):
            pass
        ts = int(pos.get("ts") or ts)
        try:
            FEED.publish_buy(
                pos["entry"],
                pos["tp"],
                pos["sl"],
                signal_id=str(pos.get("id") or f"buy-{opened_at or ts}"),
                ts=ts,
            )
        except ValueError as exc:
            print(f"[mt5] posisi tersimpan tidak dikirim: {exc}", flush=True)
            FEED.publish_none()
    else:
        FEED.publish_none()
    FEED.start()

    def market_loop() -> None:
        state = load_json(STATE_FILE, {})
        last_side = state.get("side")
        while True:
            try:
                last_side = check_market(last_side)
            except Exception:
                traceback.print_exc()
            time.sleep(POLL_MARKET_SEC)

    threading.Thread(target=market_loop, daemon=True).start()

    while True:
        try:
            updates = api(
                "getUpdates",
                {"timeout": "25", "offset": str(offset), "allowed_updates": json.dumps(["message"])},
                timeout=40,
            )
            for upd in updates:
                offset = int(upd["update_id"]) + 1
                if "message" in upd:
                    handle_message(upd["message"], sig_cache)
        except Exception:
            traceback.print_exc()
            time.sleep(3)


if __name__ == "__main__":
    main()
