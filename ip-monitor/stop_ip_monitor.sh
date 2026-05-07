#!/usr/bin/env bash
set -euo pipefail
PORT="8765"
PID="$(lsof -ti tcp:$PORT -sTCP:LISTEN 2>/dev/null || true)"
if [[ -z "$PID" ]]; then
  echo "No IP monitor server running on port $PORT"
  exit 0
fi
kill "$PID"
echo "Stopped IP monitor (pid=$PID)"
