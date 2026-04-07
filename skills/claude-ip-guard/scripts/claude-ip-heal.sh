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

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

file_contains() {
  local needle="$1"
  local file="$2"
  if has_cmd rg; then
    rg -q --fixed-strings "$needle" "$file"
  else
    grep -Fq -- "$needle" "$file"
  fi
}

list_yaml_files() {
  local dir="$1"
  [[ -d "$dir" ]] || return 0
  if has_cmd rg; then
    rg --files "$dir" -g '*.yaml'
  else
    find "$dir" -type f -name '*.yaml' | sort
  fi
}

patch_file() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  if ! file_contains "Claude-Residential" "$file"; then
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

harden_file() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  local tmp
  tmp="$(mktemp)"

  awk -v ip="$TARGET_IP" '
  BEGIN {
    direct_rule = "IP-CIDR," ip "/32,DIRECT,no-resolve"
    seen_direct = 0
    seen_curl = 0
  }
  {
    line = $0

    # Persist safe mode in generated configs.
    if (line ~ /^mode:[[:space:]]*global[[:space:]]*$/) {
      line = "mode: rule"
    }

    # Remove conflicting Claude-domain routes that may send traffic to non-Claude groups.
    if (index(line, "DOMAIN-SUFFIX,anthropic.com,🔥ChatGPT") > 0 ||
        index(line, "DOMAIN-SUFFIX,claude.ai,🔥ChatGPT") > 0 ||
        index(line, "DOMAIN-SUFFIX,claude.com,🔥ChatGPT") > 0 ||
        index(line, "DOMAIN-SUFFIX,clau.de,🔥ChatGPT") > 0) {
      next
    }

    # Keep Claude routing focused on core domains to reduce residential endpoint load.
    if (index(line, "DOMAIN-SUFFIX,sentry.io,Claude") > 0 ||
        index(line, "DOMAIN-SUFFIX,statsigapi.net,Claude") > 0 ||
        index(line, "DOMAIN-SUFFIX,featureassets.org,Claude") > 0 ||
        index(line, "DOMAIN-SUFFIX,prodregistryv2.org,Claude") > 0 ||
        index(line, "DOMAIN-SUFFIX,featuregates.org,Claude") > 0 ||
        index(line, "DOMAIN,api.segment.io,Claude") > 0 ||
        index(line, "DOMAIN,cdn.growthbook.io,Claude") > 0) {
      next
    }

    # De-duplicate managed rules if they already exist multiple times.
    if (index(line, direct_rule) > 0) {
      if (seen_direct) next
      seen_direct = 1
    }
    if (index(line, "PROCESS-NAME,curl,Claude") > 0) {
      if (seen_curl) next
      seen_curl = 1
    }

    print line

    # Ensure curl-based checks are always routed into Claude group.
    if (!seen_curl && index(line, "DOMAIN-SUFFIX,ping0.cc,Claude") > 0) {
      match(line, /^[[:space:]]*/)
      indent = substr(line, 1, RLENGTH)
      if (line ~ /'\''[[:space:]]*$/) {
        print indent "- '\''PROCESS-NAME,curl,Claude'\''"
      } else {
        print indent "- PROCESS-NAME,curl,Claude"
      }
      seen_curl = 1
    }

    # Ensure outbound connection to residential SOCKS endpoint never gets re-proxied.
    if (!seen_direct && index(line, "IP-CIDR6,2607:6bc0::/48,Claude,no-resolve") > 0) {
      match(line, /^[[:space:]]*/)
      indent = substr(line, 1, RLENGTH)
      if (line ~ /'\''[[:space:]]*$/) {
        print indent "- '\''" direct_rule "'\''"
      } else {
        print indent "- " direct_rule
      }
      seen_direct = 1
    }
  }
  ' "$file" > "$tmp"

  if ! cmp -s "$file" "$tmp"; then
    mv "$tmp" "$file"
    log "hardened: $file"
  else
    rm -f "$tmp"
    log "already-hardened: $file"
  fi

  # Ensure curl rule exists in the effective final rules block.
  perl -0777 -i -pe '
    s/(rules:\n- DOMAIN,ifconfig\.me,Claude\n- DOMAIN-SUFFIX,ping0\.cc,Claude\n)
      (?!- PROCESS-NAME,curl,Claude\n)
     /$1- PROCESS-NAME,curl,Claude\n/sx
  ' "$file"

  # Keep fail-closed option available in Claude selector.
  perl -0777 -i -pe '
    s/(name:\s*Claude\s*\n\s*type:\s*select\s*\n\s*proxies:\s*\n\s*-\s*Claude-Residential\s*\n)
      (?!\s*-\s*REJECT\s*\n)
     /$1  - REJECT\n/sx
  ' "$file"

  # Ensure the residential endpoint bypasses TUN routing recursion.
  perl -i -pe '
    s/^(\s*)route-exclude-address:\s*\[\]\s*$/$1route-exclude-address:\n$1- '"$TARGET_IP"'\/32/mg
  ' "$file"
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

  # Enforce rule mode every run so global-mode regressions do not reappear.
  curl --unix-socket "$SOCK" -s -X PATCH -H 'Content-Type: application/json' \
    -d '{"mode":"rule"}' http://localhost/configs >/dev/null || true

  # Ensure TUN stays enabled, otherwise terminal traffic bypasses Clash entirely.
  curl --unix-socket "$SOCK" -s -X PATCH -H 'Content-Type: application/json' \
    -d '{"tun":{"enable":true}}' http://localhost/configs >/dev/null || true

  # Never route the residential SOCKS endpoint back into TUN/proxy chain.
  curl --unix-socket "$SOCK" -s -X PATCH -H 'Content-Type: application/json' \
    -d "{\"tun\":{\"enable\":true,\"route-exclude-address\":[\"$TARGET_IP/32\"]}}" http://localhost/configs >/dev/null || true

  # Ensure Claude group points to Claude-Residential
  curl --unix-socket "$SOCK" -s -X PUT -H 'Content-Type: application/json' \
    -d '{"name":"Claude-Residential"}' http://localhost/proxies/Claude >/dev/null || true

  # Keep default traffic on normal proxy pool; Claude traffic is handled by Claude rules.
  curl --unix-socket "$SOCK" -s -X PUT -H 'Content-Type: application/json' \
    -d '{"name":"♻️自动选择"}' http://localhost/proxies/狗狗加速.com >/dev/null || true

  # If someone switches to global later, avoid sending all traffic into residential proxy.
  curl --unix-socket "$SOCK" -s -X PUT -H 'Content-Type: application/json' \
    -d '{"name":"狗狗加速.com"}' http://localhost/proxies/GLOBAL >/dev/null || true
}

patch_profiles_state() {
  local file="$BASE/profiles.yaml"
  [[ -f "$file" ]] || return 0

  cp "$file" "$file.bak-$TS"

  perl -0777 -i -pe '
    s/(- name:\s*狗狗加速\.com\s*\n\s*now:\s*).*/${1}♻️自动选择/g;
    s/(- name:\s*GLOBAL\s*\n\s*now:\s*).*/${1}狗狗加速.com/g;
  ' "$file"

  log "state-updated: $file"
}

check_ip() {
  local ip1 ip2
  local proxy_line user pass server port

  local pattern='Claude-Residential.*server: [^,}]+.*port: [0-9]+.*username: [^,}]+.*password: [^,}]+'
  local search_out
  if has_cmd rg; then
    search_out="$(rg -n "$pattern" "$BASE/clash-verge.yaml" "$BASE"/profiles/*.yaml 2>/dev/null || true)"
  else
    search_out="$(grep -En "$pattern" "$BASE/clash-verge.yaml" "$BASE"/profiles/*.yaml 2>/dev/null || true)"
  fi
  proxy_line="$(printf '%s\n' "$search_out" | head -n1 | cut -d: -f2- || true)"

  if [[ -n "$proxy_line" ]]; then
    user="$(printf '%s' "$proxy_line" | sed -E "s/.*username: ([^,}]+).*/\\1/")"
    pass="$(printf '%s' "$proxy_line" | sed -E "s/.*password: ([^,}]+).*/\\1/")"
    server="$(printf '%s' "$proxy_line" | sed -E "s/.*server: ([^,}]+).*/\\1/")"
    port="$(printf '%s' "$proxy_line" | sed -E "s/.*port: ([0-9]+).*/\\1/")"

    # Validate through the residential SOCKS endpoint itself.
    ip1="$(curl -4 -s --max-time 12 --socks5-hostname "$user:$pass@$server:$port" ifconfig.me | tr -d '\r\n' || true)"
    [[ -z "$ip1" ]] && ip1="$(curl -4 -s --max-time 12 --socks5-hostname "$user:$pass@$server:$port" ip.sb | tr -d '\r\n' || true)"
    [[ -z "$ip1" ]] && ip1="$(curl -4 -s --max-time 12 --socks5-hostname "$user:$pass@$server:$port" ping0.cc/ip | tr -d '\r\n' || true)"
    ip2="$(curl -4 -s --max-time 12 --socks5-hostname "$user:$pass@$server:$port" ping0.cc/ip | tr -d '\r\n' || true)"
    [[ -z "$ip2" ]] && ip2="$(curl -4 -s --max-time 12 --socks5-hostname "$user:$pass@$server:$port" ip.sb | tr -d '\r\n' || true)"
    [[ -z "$ip2" ]] && ip2="$ip1"
  else
    # Fallback when credentials are not found in local config files.
    ip1="$(curl -4 -s --max-time 10 ifconfig.me | tr -d '\r\n' || true)"
    [[ -z "$ip1" ]] && ip1="$(curl -4 -s --max-time 10 ip.sb | tr -d '\r\n' || true)"
    [[ -z "$ip1" ]] && ip1="$(curl -4 -s --max-time 10 ping0.cc/ip | tr -d '\r\n' || true)"
    ip2="$(curl -4 -s --max-time 10 ping0.cc/ip | tr -d '\r\n' || true)"
    [[ -z "$ip2" ]] && ip2="$(curl -4 -s --max-time 10 ip.sb | tr -d '\r\n' || true)"
    [[ -z "$ip2" ]] && ip2="$ip1"
  fi

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
    while IFS= read -r f; do files+=("$f"); done < <(list_yaml_files "$BASE/profiles")
  fi

  if [[ ${#files[@]} -eq 0 ]]; then
    err "No Clash Verge config files found under $BASE"
    exit 10
  fi

  for f in "${files[@]}"; do
    patch_file "$f"
    harden_file "$f"
  done

  patch_profiles_state
  reload_core
  sleep 1
  check_ip
}

main "$@"
