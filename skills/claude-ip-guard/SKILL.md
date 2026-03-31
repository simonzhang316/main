---
name: claude-ip-guard
description: Use when configuring Claude to run through a fixed residential IP via Clash Verge and enforcing pre-launch IP verification to avoid login risk from IP drift.
---

# Claude IP Guard

## Overview

This skill standardizes a safe Claude workflow:
- Route Claude traffic through a fixed residential IP in Clash Verge.
- Verify terminal egress IP before opening Claude.
- Block app launch when IP is wrong.

Important: On modern Mihomo cores, `relay` is removed. Use `dialer-proxy` chaining instead.

## When To Use

- Claude/Anthropic login verification loops or frequent risk checks.
- Egress IP changes after sleep, network switches, or node switches.
- Need a one-click safe launch gate.

## One-Time Setup

### 1) Clash chain (Mihomo-compatible)

```yaml
prepend-proxies:
  - { name: 'Claude-Residential', type: socks5, server: x.x.x.x, port: 443, username: xxx, password: xxx, udp: true, dialer-proxy: Claude-Tunnel }

prepend-proxy-groups:
  - name: Claude-Tunnel
    type: select
    proxies: ['🇸🇬15新加坡-专线(AnyTLS)', '🇸🇬24新加坡-专线(AnyTLS)', '🇦🇺19澳洲-专线(AnyTLS)']
  - name: Claude
    type: select
    proxies: [Claude-Residential]

prepend-rules:
  - DOMAIN,ifconfig.me,Claude
  - DOMAIN-SUFFIX,ping0.cc,Claude
  - DOMAIN-SUFFIX,anthropic.com,Claude
  - DOMAIN-SUFFIX,claude.ai,Claude
  - DOMAIN-SUFFIX,claude.com,Claude
  - DOMAIN-SUFFIX,clau.de,Claude
  - DOMAIN-SUFFIX,modelcontextprotocol.io,Claude
  - DOMAIN,anthropic.statuspage.io,Claude
  - DOMAIN-SUFFIX,sentry.io,Claude
  - DOMAIN-SUFFIX,statsigapi.net,Claude
  - DOMAIN-SUFFIX,featureassets.org,Claude
  - DOMAIN-SUFFIX,prodregistryv2.org,Claude
  - DOMAIN-SUFFIX,featuregates.org,Claude
  - DOMAIN,api.segment.io,Claude
  - DOMAIN,cdn.growthbook.io,Claude
  - IP-CIDR,160.79.104.0/21,Claude,no-resolve
  - IP-CIDR6,2607:6bc0::/48,Claude,no-resolve
```

### 2) Runtime hard requirements

- Mode: `rule`
- TUN: `enable: true`
- IPv6: `false`
- Subscription auto-update: disabled
- Remove shell `HTTP_PROXY/HTTPS_PROXY` env exports when using TUN

## Verification Gate (Must Pass)

Run in a clean terminal:

```bash
curl -s ifconfig.me && echo
curl -s ping0.cc/ip && echo
```

Both must return the same fixed residential IP (for example `38.45.149.73`).

Optional deep check (Clash unix socket):

```bash
curl --unix-socket /tmp/verge/verge-mihomo.sock -s http://localhost/configs | rg '"mode"|"ipv6"'
curl --unix-socket /tmp/verge/verge-mihomo.sock -s http://localhost/proxies/Claude-Tunnel | rg '"now"'
```

## Safe Launch Guard

Add to `~/.zshrc`:

```bash
openclaude() {
  local expected_ip="${CLAUDE_EXPECTED_IP:-38.45.149.73}"
  local current_ip
  current_ip="$(curl -4 -s --max-time 8 ifconfig.me | tr -d '\r\n')"
  echo "Current IP: ${current_ip:-<empty>}"

  [[ -z "$current_ip" ]] && echo "IP check failed. Claude not opened." && return 1
  [[ "$current_ip" != "$expected_ip" ]] && echo "IP mismatch (expected $expected_ip). Claude not opened." && return 1

  echo "IP verified ($current_ip). Opening Claude..."
  open -a "Claude"
}
```

Usage:

```bash
openclaude
```

## Optional One-Click App Button

Create `Open Claude Safe.app` with AppleScript:

```applescript
on run
    set expectedIP to "38.45.149.73"
    set currentIP to do shell script "/usr/bin/curl -4 -s --max-time 8 ifconfig.me | /usr/bin/tr -d '\\r\\n'"
    if currentIP is not expectedIP then
        display alert "Claude Guard" message "IP mismatch: " & currentIP & " (expected " & expectedIP & ")" as warning
        return
    end if
    do shell script "/usr/bin/open -a 'Claude'"
end run
```

## Operating Rules

- Never switch proxy nodes while Claude is open.
- If network changes (sleep wake, Wi-Fi switch, Clash restart), close Claude, re-check IP, then reopen.
- Before every Claude launch, pass the verification gate first.

## Fast Recovery

If IP suddenly becomes non-residential (for example `112.*`):

1. Quit Claude completely.
2. Ensure Clash mode is `rule`, TUN on, IPv6 off.
3. Re-select `Claude-Tunnel` to a working SG/AU node.
4. Re-run the two `curl` checks.
5. Reopen Claude only after IP matches expected value.
