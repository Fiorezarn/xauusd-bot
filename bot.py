"""
XAUUSD Spot-style Paper Trading Bot
====================================
Mode default: PAPER (simulasi). Tidak ada jaminan untung.
Untuk live, sambungkan ke broker forex (MT5 / OANDA / dll).
"""

from __future__ import annotations

import argparse
import json
import time
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

import numpy as np
import pandas as pd
import yfinance as yf

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

@dataclass
class Config:
    symbol: str = "GC=F"  # Gold futures proxy di Yahoo (mendekati XAUUSD)
    interval: str = "15m"  # 15m | 1h | 1d
    lookback_days: int = 5
    fast_ma: int = 9
    slow_ma: int = 21
    rsi_period: int = 14
    rsi_oversold: float = 35.0
    rsi_overbought: float = 65.0
    take_profit_pct: float = 0.4  # % dari entry
    stop_loss_pct: float = 0.25  # % dari entry
    trailing_stop_pct: float = 0.2  # aktif setelah TP level setengah tercapai
    position_size_usd: float = 1000.0  # notional per trade (paper)
    starting_balance: float = 10_000.0
    poll_seconds: int = 60
    mode: str = "paper"  # paper | backtest
    state_file: str = "state.json"
    trades_file: str = "trades.csv"


# ---------------------------------------------------------------------------
# Indicators
# ---------------------------------------------------------------------------

def ema(series: pd.Series, period: int) -> pd.Series:
    return series.ewm(span=period, adjust=False).mean()


def rsi(series: pd.Series, period: int = 14) -> pd.Series:
    delta = series.diff()
    gain = delta.clip(lower=0.0)
    loss = -delta.clip(upper=0.0)
    avg_gain = gain.ewm(alpha=1 / period, min_periods=period, adjust=False).mean()
    avg_loss = loss.ewm(alpha=1 / period, min_periods=period, adjust=False).mean()
    rs = avg_gain / avg_loss.replace(0, np.nan)
    return 100 - (100 / (1 + rs))


def enrich(df: pd.DataFrame, cfg: Config) -> pd.DataFrame:
    out = df.copy()
    out["fast"] = ema(out["Close"], cfg.fast_ma)
    out["slow"] = ema(out["Close"], cfg.slow_ma)
    out["rsi"] = rsi(out["Close"], cfg.rsi_period)
    out["signal"] = 0
    # Buy: fast crosses above slow + RSI not overbought
    cross_up = (out["fast"] > out["slow"]) & (out["fast"].shift(1) <= out["slow"].shift(1))
    cross_dn = (out["fast"] < out["slow"]) & (out["fast"].shift(1) >= out["slow"].shift(1))
    out.loc[cross_up & (out["rsi"] < cfg.rsi_overbought), "signal"] = 1
    out.loc[cross_dn | (out["rsi"] > cfg.rsi_overbought), "signal"] = -1
    return out


# ---------------------------------------------------------------------------
# Data
# ---------------------------------------------------------------------------

def fetch_ohlc(cfg: Config) -> pd.DataFrame:
    """Ambil OHLC emas via Yahoo Finance (GC=F sebagai proxy XAUUSD)."""
    ticker = yf.Ticker(cfg.symbol)
    df = ticker.history(period=f"{cfg.lookback_days}d", interval=cfg.interval, auto_adjust=True)
    if df.empty:
        raise RuntimeError(f"Tidak ada data untuk {cfg.symbol}. Cek koneksi / symbol.")
    df = df[["Open", "High", "Low", "Close", "Volume"]].dropna()
    return df


# ---------------------------------------------------------------------------
# Paper broker
# ---------------------------------------------------------------------------

@dataclass
class Position:
    side: str  # long
    entry: float
    size_oz: float  # qty emas (oz) = notional / entry
    entry_time: str
    stop: float
    take: float
    peak: float


@dataclass
class PaperAccount:
    balance: float
    position: Optional[Position] = None
    trades: list = field(default_factory=list)

    def open_long(self, price: float, cfg: Config, when: datetime) -> None:
        if self.position is not None:
            return
        size_oz = cfg.position_size_usd / price
        stop = price * (1 - cfg.stop_loss_pct / 100)
        take = price * (1 + cfg.take_profit_pct / 100)
        self.position = Position(
            side="long",
            entry=price,
            size_oz=size_oz,
            entry_time=when.isoformat(),
            stop=stop,
            take=take,
            peak=price,
        )
        self.trades.append(
            {
                "time": when.isoformat(),
                "action": "BUY",
                "price": round(price, 2),
                "size_oz": round(size_oz, 5),
                "pnl": 0.0,
                "balance": round(self.balance, 2),
            }
        )
        print(f"[BUY ] {when} @ {price:.2f} | SL {stop:.2f} | TP {take:.2f}")

    def close(self, price: float, reason: str, when: datetime) -> None:
        if self.position is None:
            return
        pos = self.position
        pnl = (price - pos.entry) * pos.size_oz
        self.balance += pnl
        self.trades.append(
            {
                "time": when.isoformat(),
                "action": f"SELL ({reason})",
                "price": round(price, 2),
                "size_oz": round(pos.size_oz, 5),
                "pnl": round(pnl, 2),
                "balance": round(self.balance, 2),
            }
        )
        print(
            f"[SELL] {when} @ {price:.2f} | reason={reason} | "
            f"PnL={pnl:+.2f} | balance={self.balance:.2f}"
        )
        self.position = None

    def manage(self, bar: pd.Series, cfg: Config) -> None:
        """Cek TP / SL / trailing pada bar berjalan."""
        if self.position is None:
            return
        pos = self.position
        high = float(bar["High"])
        low = float(bar["Low"])
        close = float(bar["Close"])
        when = bar.name.to_pydatetime() if hasattr(bar.name, "to_pydatetime") else datetime.now(timezone.utc)

        pos.peak = max(pos.peak, high)

        # Trailing: setelah harga naik setengah jalan ke TP, naikkan SL
        half_tp = pos.entry * (1 + (cfg.take_profit_pct / 2) / 100)
        if pos.peak >= half_tp:
            trail = pos.peak * (1 - cfg.trailing_stop_pct / 100)
            pos.stop = max(pos.stop, trail)

        if low <= pos.stop:
            self.close(pos.stop, "stop_loss/trailing", when)
            return
        if high >= pos.take:
            self.close(pos.take, "take_profit", when)
            return

        # Exit sinyal bearish
        if int(bar.get("signal", 0)) == -1:
            self.close(close, "signal_exit", when)


# ---------------------------------------------------------------------------
# Persistence
# ---------------------------------------------------------------------------

def save_state(account: PaperAccount, cfg: Config) -> None:
    payload = {
        "balance": account.balance,
        "position": asdict(account.position) if account.position else None,
        "updated_at": datetime.now(timezone.utc).isoformat(),
    }
    Path(cfg.state_file).write_text(json.dumps(payload, indent=2))
    if account.trades:
        pd.DataFrame(account.trades).to_csv(cfg.trades_file, index=False)


def load_state(cfg: Config) -> PaperAccount:
    path = Path(cfg.state_file)
    if not path.exists():
        return PaperAccount(balance=cfg.starting_balance)
    data = json.loads(path.read_text())
    pos = None
    if data.get("position"):
        pos = Position(**data["position"])
    account = PaperAccount(balance=float(data.get("balance", cfg.starting_balance)), position=pos)
    trades_path = Path(cfg.trades_file)
    if trades_path.exists():
        account.trades = pd.read_csv(trades_path).to_dict("records")
    return account


# ---------------------------------------------------------------------------
# Engines
# ---------------------------------------------------------------------------

def run_backtest(cfg: Config) -> None:
    print(f"=== BACKTEST XAUUSD proxy ({cfg.symbol}) interval={cfg.interval} ===")
    df = enrich(fetch_ohlc(cfg), cfg)
    account = PaperAccount(balance=cfg.starting_balance)

    for ts, row in df.iterrows():
        account.manage(row, cfg)
        if account.position is None and int(row["signal"]) == 1:
            when = ts.to_pydatetime() if hasattr(ts, "to_pydatetime") else datetime.now(timezone.utc)
            account.open_long(float(row["Close"]), cfg, when)

    # Tutup posisi terbuka di close terakhir
    if account.position is not None:
        last = df.iloc[-1]
        when = df.index[-1].to_pydatetime()
        account.close(float(last["Close"]), "end_of_backtest", when)

    save_state(account, cfg)
    wins = sum(1 for t in account.trades if t["action"].startswith("SELL") and t["pnl"] > 0)
    losses = sum(1 for t in account.trades if t["action"].startswith("SELL") and t["pnl"] <= 0)
    closed = wins + losses
    ret = account.balance - cfg.starting_balance
    print("\n--- Hasil ---")
    print(f"Balance akhir : {account.balance:.2f} USD")
    print(f"Net PnL       : {ret:+.2f} USD ({ret / cfg.starting_balance * 100:+.2f}%)")
    print(f"Trades tutup  : {closed} | win {wins} | loss {losses}")
    if closed:
        print(f"Win rate      : {wins / closed * 100:.1f}%")
    print(f"Detail trade  : {cfg.trades_file}")


def run_paper_loop(cfg: Config) -> None:
    print(f"=== PAPER LIVE LOOP XAUUSD proxy ({cfg.symbol}) ===")
    print("Ctrl+C untuk berhenti. Tidak ada jaminan untung.\n")
    account = load_state(cfg)

    while True:
        try:
            df = enrich(fetch_ohlc(cfg), cfg)
            row = df.iloc[-1]
            account.manage(row, cfg)
            if account.position is None and int(row["signal"]) == 1:
                when = datetime.now(timezone.utc)
                account.open_long(float(row["Close"]), cfg, when)
            save_state(account, cfg)

            pos_txt = "FLAT"
            if account.position:
                p = account.position
                pos_txt = f"LONG @{p.entry:.2f} SL={p.stop:.2f} TP={p.take:.2f}"
            print(
                f"{datetime.now().strftime('%H:%M:%S')} | "
                f"price={float(row['Close']):.2f} RSI={float(row['rsi']):.1f} | "
                f"{pos_txt} | bal={account.balance:.2f}"
            )
            time.sleep(cfg.poll_seconds)
        except KeyboardInterrupt:
            print("\nDihentikan user.")
            save_state(account, cfg)
            break
        except Exception as exc:  # noqa: BLE001
            print(f"Error: {exc}. Retry dalam {cfg.poll_seconds}s...")
            time.sleep(cfg.poll_seconds)


def parse_args() -> Config:
    p = argparse.ArgumentParser(description="XAUUSD paper trading bot")
    p.add_argument("--mode", choices=["paper", "backtest"], default="backtest")
    p.add_argument("--interval", default="15m", help="15m, 1h, 1d")
    p.add_argument("--tp", type=float, default=0.4, help="Take profit %")
    p.add_argument("--sl", type=float, default=0.25, help="Stop loss %")
    p.add_argument("--balance", type=float, default=10_000.0)
    p.add_argument("--size", type=float, default=1000.0, help="Notional USD per trade")
    p.add_argument("--poll", type=int, default=60)
    args = p.parse_args()
    return Config(
        mode=args.mode,
        interval=args.interval,
        take_profit_pct=args.tp,
        stop_loss_pct=args.sl,
        starting_balance=args.balance,
        position_size_usd=args.size,
        poll_seconds=args.poll,
    )


def main() -> None:
    cfg = parse_args()
    if cfg.mode == "backtest":
        # Backtest butuh history lebih panjang
        if cfg.interval in ("15m", "5m"):
            cfg.lookback_days = 7
        elif cfg.interval == "1h":
            cfg.lookback_days = 30
        else:
            cfg.lookback_days = 180
        run_backtest(cfg)
    else:
        run_paper_loop(cfg)


if __name__ == "__main__":
    main()
