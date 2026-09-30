"""
Bridge opsional Python ↔ MetaTrader5 (HANYA Windows + MT5 terinstall).

Di server Linux ini paket MetaTrader5 TIDAK bisa jalan.
Untuk Valetax: pakai Expert Advisor di mt5/XAUUSD_Valetax_Bot.mq5

Script ini berguna jika Anda punya VPS/PC Windows dengan MT5 Valetax.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path


def load_env(path: str = "config/valetax.env") -> dict[str, str]:
    env_path = Path(path)
    if not env_path.exists():
        print(f"Buat dulu {path} dari valetax.env.example")
        sys.exit(1)
    data: dict[str, str] = {}
    for line in env_path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        data[k.strip()] = v.strip()
    return data


def main() -> None:
    try:
        import MetaTrader5 as mt5
    except ImportError:
        print("MetaTrader5 hanya tersedia di Windows. Install: pip install MetaTrader5")
        print("Untuk Valetax di setup Anda sekarang: gunakan EA MQL5 (folder mt5/).")
        sys.exit(1)

    cfg = load_env()
    login = int(cfg["MT5_LOGIN"])
    password = cfg["MT5_PASSWORD"]
    server = cfg["MT5_SERVER"]
    path = cfg.get("MT5_PATH") or None

    ok = mt5.initialize(path=path) if path else mt5.initialize()
    if not ok:
        print("initialize gagal:", mt5.last_error())
        sys.exit(1)

    if not mt5.login(login, password=password, server=server):
        print("login Valetax gagal:", mt5.last_error())
        mt5.shutdown()
        sys.exit(1)

    info = mt5.account_info()
    print("Connected:", info.login, info.server, "balance=", info.balance)
    symbol = cfg.get("MT5_SYMBOL", "XAUUSD")
    tick = mt5.symbol_info_tick(symbol)
    if tick:
        print(f"{symbol} bid={tick.bid} ask={tick.ask}")
    else:
        print(f"Symbol {symbol} tidak ditemukan. Cek Market Watch Valetax.")
    mt5.shutdown()


if __name__ == "__main__":
    # Jangan hardcode password di environment production tanpa file env.
    os.chdir(Path(__file__).resolve().parent)
    main()
