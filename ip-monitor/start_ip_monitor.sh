#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
HOST="127.0.0.1"
PORT="8765"
EXPECTED_IP="${1:-${CLAUDE_STATIC_IP:-<YOUR_STATIC_IP>}}"

cd "$BASE_DIR"

# Stop previous instance on same port if exists.
OLD_PID="$(lsof -ti tcp:$PORT -sTCP:LISTEN 2>/dev/null || true)"
if [[ -n "$OLD_PID" ]]; then
  kill "$OLD_PID" >/dev/null 2>&1 || true
  sleep 0.5
fi

nohup python3 "$BASE_DIR/ip_monitor_server.py" --host "$HOST" --port "$PORT" --expected "$EXPECTED_IP" \
  > "$BASE_DIR/ip_monitor_server.log" 2>&1 &

echo "IP monitor started: http://$HOST:$PORT"
open "http://$HOST:$PORT" >/dev/null 2>&1 || true
