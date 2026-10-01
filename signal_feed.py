"""Sinyal terakhir bot XAUUSD, untuk dieksekusi MT5.

Isi sinyal sama dengan pesan Telegram:

    XAUUSD BUY
    Entry: ...
    TP: ...
    SL: ...

    XAUUSD SELL
    Entry: ...
    TP: ...
    SL: ...

Untuk SELL, TP ada di bawah entry dan SL di atas entry.

Lot tidak dikirim ke broker dari sini. Lot tetap diatur di Expert Advisor.
"""

from __future__ import annotations

import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from hmac import compare_digest


def build_command(
    action: str,
    entry: float = 0.0,
    tp: float = 0.0,
    sl: float = 0.0,
    signal_id: str = "",
    ts: int | None = None,
) -> dict:
    if action not in ("none", "buy", "sell", "close"):
        raise ValueError(f"action tidak dikenal: {action}")
    if action == "buy":
        if not (sl < entry < tp):
            raise ValueError(f"BUY butuh SL < Entry < TP, dapat sl={sl} entry={entry} tp={tp}")
        if entry < 1000:
            raise ValueError(f"harga XAUUSD tidak masuk akal: {entry}")
    if action == "sell":
        if not (tp < entry < sl):
            raise ValueError(f"SELL butuh TP < Entry < SL, dapat tp={tp} entry={entry} sl={sl}")
        if entry < 1000:
            raise ValueError(f"harga XAUUSD tidak masuk akal: {entry}")
    now = int(time.time()) if ts is None else int(ts)
    return {
        "id": signal_id,
        "action": action,
        "symbol": "XAUUSD",
        "entry": round(float(entry), 2),
        "tp": round(float(tp), 2),
        "sl": round(float(sl), 2),
        "ts": now,
    }


class SignalFeed:
    def __init__(self, token: str, port: int = 8787, host: str = "0.0.0.0") -> None:
        self.token = token.strip()
        self.port = port
        self.host = host
        self._lock = threading.Lock()
        self._command = build_command("none", signal_id="", ts=0)
        self._httpd: ThreadingHTTPServer | None = None

    def snapshot(self) -> dict:
        with self._lock:
            return dict(self._command)

    def publish_none(self) -> None:
        self._set(build_command("none"))

    def publish_buy(
        self,
        entry: float,
        tp: float,
        sl: float,
        signal_id: str | None = None,
        ts: int | None = None,
    ) -> None:
        stamp = int(time.time()) if ts is None else int(ts)
        self._set(
            build_command(
                "buy",
                entry=entry,
                tp=tp,
                sl=sl,
                signal_id=signal_id or f"buy-{stamp}",
                ts=stamp,
            )
        )

    def publish_sell(
        self,
        entry: float,
        tp: float,
        sl: float,
        signal_id: str | None = None,
        ts: int | None = None,
    ) -> None:
        stamp = int(time.time()) if ts is None else int(ts)
        self._set(
            build_command(
                "sell",
                entry=entry,
                tp=tp,
                sl=sl,
                signal_id=signal_id or f"sell-{stamp}",
                ts=stamp,
            )
        )

    def publish_close(self, label: str, entry: float = 0.0, tp: float = 0.0, sl: float = 0.0) -> None:
        stamp = int(time.time())
        self._set(
            build_command(
                "close",
                entry=entry,
                tp=tp,
                sl=sl,
                signal_id=f"close-{label}-{stamp}",
                ts=stamp,
            )
        )

    def _set(self, command: dict) -> None:
        with self._lock:
            self._command = command
        print(
            f"[mt5] {command['action']} id={command['id']} "
            f"entry={command['entry']} tp={command['tp']} sl={command['sl']}",
            flush=True,
        )

    def start(self) -> None:
        if not self.token:
            print("[mt5] MT5_SIGNAL_TOKEN kosong, feed tidak dinyalakan", flush=True)
            return
        feed = self

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self) -> None:
                if self.path.split("?", 1)[0] != "/signal":
                    self.send_error(404)
                    return
                given = self.headers.get("X-Signal-Token", "")
                if not compare_digest(given, feed.token):
                    self.send_error(401)
                    return
                body = json.dumps(feed.snapshot(), separators=(",", ":")).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, fmt: str, *args) -> None:
                return

        self._httpd = ThreadingHTTPServer((self.host, self.port), Handler)
        self.port = int(self._httpd.server_address[1])
        threading.Thread(target=self._httpd.serve_forever, name="mt5-signal", daemon=True).start()
        print(f"[mt5] feed siap di http://{self.host}:{self.port}/signal", flush=True)
