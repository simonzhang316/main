#!/usr/bin/env bash
set -euo pipefail

TARGET_IP="${1:-${CLAUDE_STATIC_IP:-}}"
TARGET_PORT="${2:-${CLAUDE_STATIC_PORT:-}}"
BASE="${CLASH_VERGE_BASE:-$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev}"
SOCK="${CLASH_SOCK:-/tmp/verge/verge-mihomo.sock}"
TS="$(date +%Y%m%d-%H%M%S)"

log() { printf '[claude-ip-heal] %s\n' "$*"; }
warn() { printf '[claude-ip-heal] WARN: %s\n' "$*" >&2; }
err() { printf '[claude-ip-heal] ERROR: %s\n' "$*" >&2; }

patch_file() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  if ! rg -q "Claude-Residential" "$file"; then
    return 0
  fi

  cp "$file" "$file.bak-$TS"
  local tmp
  tmp="$(mktemp)"

  awk -v ip="$TARGET_IP" -v port="$TARGET_PORT" '
  function indent_of(s,   n) { match(s, /^ */); return RLENGTH }
  {
    line = $0

    # Inline map style: { name: "Claude-Residential", server: ..., port: ..., ... }
    if (line ~ /Claude-Residential/ && line ~ /server:[^,}]+/ && line ~ /port:[0-9]+/) {
      gsub(/server:[[:space:]]*[^,}]+/, "server: " ip, line)
      gsub(/port:[[:space:]]*[0-9]+/, "port: " port, line)
      gsub(/,[[:space:]]*dialer-proxy:[[:space:]]*\x27?Claude-Tunnel\x27?/, "", line)
      gsub(/,[[:space:]]*dialer-proxy:[[:space:]]*\"?Claude-Tunnel\"?/, "", line)
      print line
      next
    }

    # Start of block map for Claude-Residential
    if (line ~ /^[[:space:]]*-[[:space:]]*name:[[:space:]]*\x27?Claude-Residential\x27?[[:space:]]*$/ ||
        line ~ /^[[:space:]]*name:[[:space:]]*\x27?Claude-Residential\x27?[[:space:]]*$/ ||
        line ~ /^[[:space:]]*-[[:space:]]*name:[[:space:]]*\"?Claude-Residential\"?[[:space:]]*$/ ||
        line ~ /^[[:space:]]*name:[[:space:]]*\"?Claude-Residential\"?[[:space:]]*$/) {
      in_block = 1
      block_indent = indent_of($0)
      print line
      next
    }

    if (in_block == 1) {
      cur_indent = indent_of($0)

      # End block when dedent to same/less indent and line is a new key/list item
      if ($0 !~ /^[[:space:]]*$/ && $0 !~ /^[[:space:]]*#/ && cur_indent <= block_indent &&
          $0 !~ /^[[:space:]]*server:/ && $0 !~ /^[[:space:]]*port:/ && $0 !~ /^[[:space:]]*dialer-proxy:/) {
        in_block = 0
      }
    }

    if (in_block == 1) {
      if ($0 ~ /^[[:space:]]*server:[[:space:]]*/) {
        sub(/server:[[:space:]]*.*/, "server: " ip, line)
        print line
        next
      }
      if ($0 ~ /^[[:space:]]*port:[[:space:]]*[0-9]+/) {
        sub(/port:[[:space:]]*[0-9]+/, "port: " port, line)
        print line
        next
      }
      if ($0 ~ /^[[:space:]]*dialer-proxy:[[:space:]]*\x27?Claude-Tunnel\x27?[[:space:]]*$/ ||
          $0 ~ /^[[:space:]]*dialer-proxy:[[:space:]]*\"?Claude-Tunnel\"?[[:space:]]*$/) {
        next
      }
    }

    print line
  }
  ' "$file" > "$tmp"

  if ! cmp -s "$file" "$tmp"; then
    mv "$tmp" "$file"
    log "patched: $file"
  else
    rm -f "$tmp"
    log "no-change: $file"
  fi
}

reload_core() {
  if [[ ! -S "$SOCK" ]]; then
    warn "clash socket not found at $SOCK; skip runtime reload"
    return 0
  fi

  local core_cfg="$BASE/clash-verge.yaml"
  if [[ -f "$core_cfg" ]]; then
    curl --unix-socket "$SOCK" -s -X PUT -H 'Content-Type: application/json' \
      -d "{\"path\":\"$core_cfg\",\"force\":true}" http://localhost/configs >/dev/null || true
  fi

  # Ensure Claude group points to Claude-Residential
  curl --unix-socket "$SOCK" -s -X PUT -H 'Content-Type: application/json' \
    -d '{"name":"Claude-Residential"}' http://localhost/proxies/Claude >/dev/null || true
}

check_ip() {
  local ip1 ip2
  ip1="$(curl -4 -s --max-time 10 ifconfig.me | tr -d '\r\n' || true)"
  ip2="$(curl -4 -s --max-time 10 ping0.cc/ip | tr -d '\r\n' || true)"
  log "ifconfig.me=$ip1"
  log "ping0.cc/ip=$ip2"

  if [[ -z "$ip1" || -z "$ip2" ]]; then
    err "IP check failed (empty response)."
    return 2
  fi
  if [[ "$ip1" != "$ip2" ]]; then
    err "IP sources mismatch."
    return 3
  fi
  if [[ "$ip1" != "$TARGET_IP" ]]; then
    err "IP is $ip1, expected $TARGET_IP."
    return 4
  fi

  log "OK: static residential IP restored ($TARGET_IP)."
  return 0
}

main() {
  if [[ -z "$TARGET_IP" || -z "$TARGET_PORT" ]]; then
    err "Target IP/port missing. Usage: claude-ip-heal <ip> <port> or set CLAUDE_STATIC_IP/CLAUDE_STATIC_PORT."
    exit 11
  fi

  log "target=$TARGET_IP:$TARGET_PORT"
  log "base=$BASE"

  local files=()
  [[ -f "$BASE/clash-verge.yaml" ]] && files+=("$BASE/clash-verge.yaml")
  [[ -f "$BASE/clash-verge-check.yaml" ]] && files+=("$BASE/clash-verge-check.yaml")
  if [[ -d "$BASE/profiles" ]]; then
    while IFS= read -r f; do files+=("$f"); done < <(rg --files "$BASE/profiles" -g '*.yaml')
  fi

  if [[ ${#files[@]} -eq 0 ]]; then
    err "No Clash Verge config files found under $BASE"
    exit 10
  fi

  for f in "${files[@]}"; do
    patch_file "$f"
  done

  reload_core
  sleep 1
  check_ip
}

main "$@"
