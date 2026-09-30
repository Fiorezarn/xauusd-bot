import json
import urllib.error
import urllib.request

from signal_feed import SignalFeed, build_command


def test_buy_levels_match_telegram_sample():
    cmd = build_command(
        "buy",
        entry=4190.78,
        tp=4201.26,
        sl=4180.31,
        signal_id="buy-sample",
        ts=1,
    )
    assert cmd["symbol"] == "XAUUSD"
    assert cmd["action"] == "buy"
    assert cmd["entry"] == 4190.78
    assert cmd["tp"] == 4201.26
    assert cmd["sl"] == 4180.31


def test_buy_rejects_inverted_stops():
    try:
        build_command("buy", entry=4190.78, tp=4180.31, sl=4201.26)
    except ValueError:
        return
    raise AssertionError("SL di atas TP harus ditolak")


def test_http_requires_token_and_returns_levels():
    feed = SignalFeed("rahasia-uji", port=0, host="127.0.0.1")
    feed.publish_buy(4190.78, 4201.26, 4180.31, signal_id="buy-1", ts=10)
    feed.start()
    assert feed._httpd is not None
    port = feed._httpd.server_address[1]
    url = f"http://127.0.0.1:{port}/signal"
    try:
        try:
            urllib.request.urlopen(url, timeout=2)
            raise AssertionError("tanpa token harus ditolak")
        except urllib.error.HTTPError as exc:
            assert exc.code == 401
        req = urllib.request.Request(url, headers={"X-Signal-Token": "rahasia-uji"})
        with urllib.request.urlopen(req, timeout=2) as resp:
            data = json.loads(resp.read().decode())
        assert data["action"] == "buy"
        assert data["symbol"] == "XAUUSD"
        assert data["tp"] == 4201.26
        assert data["sl"] == 4180.31
    finally:
        feed._httpd.shutdown()


if __name__ == "__main__":
    test_buy_levels_match_telegram_sample()
    test_buy_rejects_inverted_stops()
    test_http_requires_token_and_returns_levels()
    print("ok")
