#!/usr/bin/env python3
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import socketserver
import urllib.error
import urllib.parse
import urllib.request
from collections import Counter
from dataclasses import dataclass, asdict
from http.server import BaseHTTPRequestHandler
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent
INDEX_FILE = BASE_DIR / "index.html"

IPV4_RE = re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}\b")

PROVIDERS = [
    ("ifconfig-ip", "https://ifconfig.me/ip"),
    ("ifconfig", "https://ifconfig.me"),
    ("ifconfig-json", "https://ifconfig.me/all.json"),
]


@dataclass
class ProbeResult:
    name: str
    url: str
    ok: bool
    ip: str | None
    error: str | None
    latency_ms: int | None


def is_valid_ipv4(ip: str) -> bool:
    parts = ip.split(".")
    if len(parts) != 4:
        return False
    try:
        return all(0 <= int(part) <= 255 for part in parts)
    except ValueError:
        return False


def extract_ipv4(text: str) -> str | None:
    match = IPV4_RE.search(text)
    if not match:
        return None
    candidate = match.group(0)
    return candidate if is_valid_ipv4(candidate) else None


def fetch_ip(name: str, url: str, timeout: float = 6.0) -> ProbeResult:
    start = dt.datetime.now(dt.UTC)
    request = urllib.request.Request(
        url,
        headers={
            "User-Agent": "Claude-IP-Monitor/1.0",
            "Accept": "text/plain, application/json;q=0.9, */*;q=0.8",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as resp:
            body = resp.read(2048).decode("utf-8", errors="replace")
        ip = extract_ipv4(body)
        latency_ms = int((dt.datetime.now(dt.UTC) - start).total_seconds() * 1000)
        if not ip:
            return ProbeResult(name=name, url=url, ok=False, ip=None, error="no_ipv4_in_response", latency_ms=latency_ms)
        return ProbeResult(name=name, url=url, ok=True, ip=ip, error=None, latency_ms=latency_ms)
    except urllib.error.HTTPError as exc:
        return ProbeResult(name=name, url=url, ok=False, ip=None, error=f"http_{exc.code}", latency_ms=None)
    except urllib.error.URLError as exc:
        return ProbeResult(name=name, url=url, ok=False, ip=None, error=f"network_{exc.reason}", latency_ms=None)
    except TimeoutError:
        return ProbeResult(name=name, url=url, ok=False, ip=None, error="timeout", latency_ms=None)
    except Exception as exc:  # noqa: BLE001
        return ProbeResult(name=name, url=url, ok=False, ip=None, error=f"error_{type(exc).__name__}", latency_ms=None)


def build_status(expected_ip: str | None) -> dict:
    probes = [fetch_ip(name, url) for name, url in PROVIDERS]
    valid_ips = [p.ip for p in probes if p.ok and p.ip]

    consensus_ip = None
    confidence = 0
    if valid_ips:
        counts = Counter(valid_ips)
        consensus_ip, confidence = counts.most_common(1)[0]

    risk_level = "medium"
    actions: list[str] = []

    if not valid_ips:
        overall = "fail"
        message = "All providers failed."
        risk_level = "high"
        actions = [
            "暂停登录 Claude，先检查 Clash Verge 是否在线",
            "执行 claude-ip-enforce 后再重试",
            "若持续失败，检查网络与订阅节点状态",
        ]
    elif expected_ip:
        if consensus_ip == expected_ip:
            overall = "pass"
            message = f"Matched expected IP: {expected_ip}"
            risk_level = "low"
            actions = [
                "当前固定IP正常，可继续使用",
            ]
        else:
            overall = "fail"
            message = f"IP mismatch. Current: {consensus_ip}, Expected: {expected_ip}"
            risk_level = "high"
            actions = [
                "当前IP不在白名单，先不要登录 Claude",
                "在 Clash 中确认 Claude 组选择 Claude-Residential",
                "执行 claude-ip-enforce <YOUR_STATIC_IP> <YOUR_PORT> 并刷新页面",
            ]
    else:
        overall = "warn"
        message = "Expected IP not set. Showing current consensus only."
        risk_level = "medium"
        actions = [
            "先设置目标IP，才能判断是否安全",
        ]

    return {
        "timestamp": dt.datetime.now().isoformat(timespec="seconds"),
        "expected_ip": expected_ip,
        "consensus_ip": consensus_ip,
        "confidence": confidence,
        "ok_count": len(valid_ips),
        "total_count": len(probes),
        "overall": overall,
        "message": message,
        "risk_level": risk_level,
        "actions": actions,
        "probes": [asdict(p) for p in probes],
    }


class Handler(BaseHTTPRequestHandler):
    default_expected_ip = os.environ.get("EXPECTED_IP", "")

    def log_message(self, fmt: str, *args) -> None:
        return

    def _send_json(self, status: int, payload: dict) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_file(self, path: Path, content_type: str) -> None:
        if not path.exists():
            self.send_error(404, "Not Found")
            return
        data = path.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self) -> None:  # noqa: N802
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == "/" or parsed.path == "/index.html":
            self._send_file(INDEX_FILE, "text/html; charset=utf-8")
            return

        if parsed.path == "/api/status":
            query = urllib.parse.parse_qs(parsed.query)
            expected = query.get("expected", [self.default_expected_ip])[0].strip()
            expected = expected if is_valid_ipv4(expected) else None
            self._send_json(200, build_status(expected))
            return

        self._send_json(404, {"error": "not_found"})


class ThreadingHTTPServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    allow_reuse_address = True


def main() -> None:
    parser = argparse.ArgumentParser(description="Local IP monitor web server")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--expected", default="", help="Expected fixed IP")
    args = parser.parse_args()

    if args.expected and not is_valid_ipv4(args.expected):
        raise SystemExit("--expected must be a valid IPv4")

    Handler.default_expected_ip = args.expected
    with ThreadingHTTPServer((args.host, args.port), Handler) as httpd:
        print(f"IP monitor running at http://{args.host}:{args.port}")
        httpd.serve_forever()


if __name__ == "__main__":
    main()
