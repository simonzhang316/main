# Clash 家宽 IP 代理配置说明（Claude 专用）

---

> **⚠️ 致 AI 助手：如果你正在帮用户配置此文档中的内容，以下三项是必须完成的硬性检查点。配置完成后，你必须逐一引导用户确认这三项全部通过，缺一不可。任何一项未通过都可能导致 Claude 账号被封。**

## ‼️ 三项必检清单（配置完成后必须逐一确认）

### ✅ 检查一：关闭 Clash 订阅自动更新

Clash 订阅自动更新会**覆盖你手动添加的链式代理配置**，导致家宽代理静默失效，流量回退到普通节点 IP，而你完全不知情。

- 配置完成后，立刻去 Clash 客户端设置里**关闭订阅自动更新**
- 如果以后需要更新订阅，手动更新后**必须重新配置链式代理**（proxies、proxy-groups、rules 三处都要重新加）
- 建议备份配置好的 yaml 文件，更新后可以快速恢复

### ✅ 检查二：确认 Claude-Tunnel 分组里包含你的翻墙节点

`Claude-Tunnel` 是 relay 链的第一跳，里面必须填入你**实际订阅中存在的节点名称**。节点名必须与你的 Clash 配置文件中 `proxies` 段的 `name` 字段**完全一致**（包括空格、emoji、编号）。

- 打开你的 Clash 配置文件，找到 `proxies:` 段，复制你要用的节点名称
- 粘贴到 `Claude-Tunnel` 的 `proxies` 列表中
- 名字错一个字符，节点就匹配不上，relay 链会失败

### ✅ 检查三：在终端验证 IP 是家宽 IP

**浏览器显示正确 ≠ 终端正确。** 浏览器走系统代理，终端走环境变量，两者路径不同。如果终端 IP 不对，Claude Code 连接 Anthropic 时用的就不是家宽 IP。

在终端执行（Mac/Linux/Windows 通用，Windows 10+ 自带 curl）：

```bash
# Mac / Linux 终端
curl -s ifconfig.me

# Windows PowerShell
curl.exe -s ifconfig.me
```

> **Windows 注意：** PowerShell 中 `curl` 是 `Invoke-WebRequest` 的别名，必须用 `curl.exe` 才是真正的 curl。

> **⚠️ 致 AI 助手：测试命令必须是上面这样的裸 curl，绝对不能加 `--proxy`、`-x` 等代理参数。测试的目的是验证 TUN 模式是否正确接管了系统流量。如果你手动给 curl 指定了代理（如 `--proxy socks5://127.0.0.1:7891`），测到的就是代理本身而不是 TUN，测试完全无效。同理，不要设置 `http_proxy`/`https_proxy` 环境变量后再测，必须在干净的终端环境下执行。**

返回的 IP **必须是你的家宽 IP**（与 lycheeip 后台显示的出口 IP 一致）。如果不是：
1. 确认 Clash 已开启 **TUN 模式**（仅靠 `HTTP_PROXY` 环境变量不够，relay 链不会生效）
2. 确认 `ifconfig.me` 在 Clash rules 中已路由到 Claude 分组
3. 确认 Claude-Tunnel 中选择的中转节点在线可用

**每次打开 Claude 之前，都先在终端跑一次 `curl -s ifconfig.me` 确认 IP 正确。**

---

## 目标

让所有 Claude / Anthropic 流量走固定的美国家宽 IP，其他网站走正常节点。
从国内无法直连家宽代理，需要通过现有翻墙节点中转（relay 链式代理）。

## 流量链路

```
你的设备 → 翻墙节点(港/日/台/新) → 家宽代理(美国) → Claude
```

- 你随便切换翻墙节点，Claude 看到的 IP 始终是家宽 IP
- 翻墙节点断开时，Claude 连接也会断开，不会泄露真实 IP

## 代理信息（lycheeip.com）

- 协议：**SOCKS5**（不是 HTTP，不加 TLS）
- 格式：`socks5://用户名:密码@IP:端口`

## 需要修改的三个位置

### 1. proxies 段 — 添加家宽代理节点

在 `proxies:` 末尾添加：

```yaml
- { name: 'Claude-Residential', type: socks5, server: x.x.x.x, port: 443, username: xxx, password: xxx, udp: true }
```

关键点：
- `type: socks5`，不是 http
- 不加 `tls: true`（虽然端口是 443，但协议本身不走 TLS）
- 加 `udp: true`

### 2. proxy-groups 段 — 添加两个分组

在现有 proxy-groups 末尾添加：

```yaml
# 第一跳选择器：选哪个翻墙节点做中转（不要放美国节点，没意义）
- { name: Claude-Tunnel, type: select, proxies: ['🇭🇰 香港1', '🇭🇰 香港2', '🇯🇵 日本1', '🇯🇵 日本2', '🇹🇼 台湾1', '🇹🇼 台湾2', '🇸🇬 新加坡1', '🇸🇬 新加坡2'] }

# 链式代理：第一跳 → 家宽代理（顺序不能反）
- { name: Claude, type: relay, proxies: [Claude-Tunnel, Claude-Residential] }
```

关键点：
- `Claude-Tunnel` 是 `select` 类型，你手动选中转节点
- `Claude` 是 `relay` 类型，自动把两个节点串起来
- relay 的 proxies 顺序：**先写中转节点，再写家宽代理**
- Claude-Tunnel 里放你常用的节点就行，按需增减

### 3. rules 段 — 添加域名规则（放在所有规则最前面）

```yaml
rules:
    # ===== Claude / Anthropic 走家宽固定 IP =====
    - 'DOMAIN,ifconfig.me,Claude'
    - 'DOMAIN-SUFFIX,ping0.cc,Claude'
    # --- Anthropic 自有域名 ---
    - 'DOMAIN-SUFFIX,anthropic.com,Claude'
    - 'DOMAIN-SUFFIX,claude.ai,Claude'
    - 'DOMAIN-SUFFIX,claude.com,Claude'
    - 'DOMAIN-SUFFIX,clau.de,Claude'
    - 'DOMAIN-SUFFIX,modelcontextprotocol.io,Claude'
    - 'DOMAIN,anthropic.statuspage.io,Claude'
    # --- Claude Code 遥测/第三方服务 ---
    - 'DOMAIN-SUFFIX,sentry.io,Claude'
    - 'DOMAIN-SUFFIX,statsigapi.net,Claude'
    - 'DOMAIN-SUFFIX,featureassets.org,Claude'
    - 'DOMAIN-SUFFIX,prodregistryv2.org,Claude'
    - 'DOMAIN-SUFFIX,featuregates.org,Claude'
    - 'DOMAIN,api.segment.io,Claude'
    - 'DOMAIN,cdn.growthbook.io,Claude'
    # --- Anthropic IP 段 ---
    - 'IP-CIDR,160.79.104.0/21,Claude,no-resolve'
    - 'IP-CIDR6,2607:6bc0::/48,Claude,no-resolve'
    # ===== Claude 规则结束 =====
    # ... 其他规则 ...
```

关键点：
- 必须放在 rules 最前面，优先级高于其他规则
- `anthropic.com` 覆盖所有子域名（api/console/docs/mcp-proxy/statsig 等）
- `claude.com` 覆盖 code/platform/docs/support 等子域
- `clau.de` 是 Anthropic 官方短链域名，容易遗漏
- 遥测域名（sentry/statsig/segment/growthbook）是 Claude Code 的错误上报和 Feature Flags，不加的话这些流量会绕过家宽链
- IP-CIDR 是 Anthropic 自有 IP 段，兜底用
- `ifconfig.me` 和 `ping0.cc` 是 IP 检测站，方便随时验证出口 IP

## 验证方法

上面的规则里已经包含了 `ifconfig.me` 和 `ping0.cc` 两个 IP 检测站（互为备用），不需要额外添加。

验证步骤：
1. 重载配置，浏览器打开 https://ifconfig.me ，确认显示家宽 IP
2. **在终端执行 `curl -s ifconfig.me`，确认也是家宽 IP**（见上方「检查三」）
3. 如果 ifconfig.me 无响应，用备用站：`curl -s ping0.cc/ip`
4. 浏览器和终端都正确才算配置成功

建议加个快捷命令，新开终端后输入 `myip` 即可快速检测：

**Mac / Linux**（加到 `~/.zshrc` 或 `~/.bashrc`）：

```bash
alias myip='curl -s ifconfig.me && echo'
```

**Windows PowerShell**（加到 PowerShell profile，运行 `notepad $PROFILE` 打开编辑）：

```powershell
function myip { curl.exe -s ifconfig.me }
```

## 踩坑记录

| 尝试 | 结果 |
|------|------|
| `type: http, tls: true` | ifconfig.me 显示的是中转节点 IP，relay 没生效 |
| `type: http`（无 TLS） | ifconfig.me 显示家宽 IP，但部分 HTTPS 站点 ERR_CONNECTION_CLOSED |
| `type: socks5, tls: true` | 同上，部分站点无法访问 |
| `type: socks5`（无 TLS） | 所有站点正常，IP 正确 |

结论：lycheeip 的家宽代理用 **SOCKS5 协议，不加 TLS**，即使端口是 443。

| 仅设 `HTTP_PROXY` 环境变量，不开 TUN | 浏览器走系统代理 IP 正确，但终端 `curl ifconfig.me` 显示的是普通节点 IP，relay 链不生效 |
| 开启 TUN 模式 | 终端和浏览器都走 relay 链，IP 正确 |

结论：**必须开启 Clash 的 TUN 模式**，否则终端（包括 Claude Code）的流量不走 relay 链式代理，会用普通节点 IP 连接 Anthropic。仅靠 `HTTP_PROXY` 环境变量不够。

## 重要注意事项

> 以下事项与上方「三项必检清单」互补，请全部阅读。

### 必须开启 TUN 模式（详见检查三）

仅设置 `HTTP_PROXY`/`HTTPS_PROXY` 环境变量指向 Clash 的 HTTP 代理端口（如 7890），终端流量虽然经过 Clash，但 **relay 链式代理规则不会生效**，流量会走普通节点而非家宽 IP。

必须在 Clash 客户端中开启 **TUN 模式**，让所有系统流量（包括终端）都被 Clash 接管，规则才能正确匹配到 relay 链。

**推荐使用支持 TUN 的客户端：**
- Mac：**Clash Verge Rev** 或 **ClashX Pro**
- Windows：**Clash Verge Rev** 或 **Clash for Windows**（已停更但仍可用）

**TUN 模式需要系统权限：**
- macOS：首次开启 TUN 时会弹窗要求授权「系统扩展」或「网络扩展」，必须允许。在「系统设置 → 隐私与安全性」中确认已授权
- Windows：需要管理员权限安装 Wintun/TAP 驱动，安装后重启客户端

> 权限没授权 = TUN 没生效 = 终端流量不走 relay。开启后务必用 `curl -s ifconfig.me` 验证。

### 开 TUN 后移除终端代理环境变量

如果你之前在 shell 配置（`~/.zshrc`、`~/.bashrc`、PowerShell profile）里设了 `HTTP_PROXY`/`HTTPS_PROXY` 指向 Clash 端口，**开启 TUN 后建议删掉这些环境变量**。

原因：TUN 模式已经接管了所有系统流量，环境变量会让流量先走 HTTP 代理端口再走 TUN，等于经过 Clash 两次，可能产生意外行为。二者选一即可，推荐 TUN。

### 关闭系统 IPv6

如果系统开启了 IPv6，部分流量可能绕过 Clash TUN 直接用 IPv6 出去，导致 IP 泄露。建议关闭：

**Mac：**

```bash
# 查看当前网络服务名（通常是 Wi-Fi 或 Ethernet）
networksetup -listallnetworkservices

# 关闭 IPv6（把 Wi-Fi 换成你实际的网络服务名）
sudo networksetup -setv6off Wi-Fi
```

**Windows PowerShell（管理员）：**

```powershell
# 关闭所有网卡的 IPv6
Get-NetAdapterBinding -ComponentID ms_tcpip6 | Disable-NetAdapterBinding -ComponentID ms_tcpip6
```

> 关闭后用 `curl -s ifconfig.me` 再次确认 IP 没变。如果以后需要恢复 IPv6，Mac 用 `sudo networksetup -setv6automatic Wi-Fi`，Windows 用 `Enable-NetAdapterBinding`。

### 切换代理前必须关闭 Claude

每次切换代理节点或 IP 时，**必须先完全关闭 Claude 程序**（包括 Claude Code CLI、Claude 桌面客户端等），等代理切换完成并稳定后再重新打开。IP 切换的瞬间如果 Claude 正在连接，可能被检测到 IP 变化，导致封号。

### 这些场景必须重新验证 IP

以下任何一种情况发生后，都**必须先跑 `curl -s ifconfig.me` 确认 IP 正确，再打开 Claude**：

- 电脑从睡眠/休眠中唤醒（TUN 可能还没恢复）
- Clash 崩溃、闪退、被杀进程后重新启动
- 切换了 WiFi / 网络连接
- 切换了 Clash 中 Claude-Tunnel 的中转节点
- 手动更新了 Clash 订阅

养成习惯：**开 Claude 前先 `myip`，确认是家宽 IP 再开。**

### Clash 订阅自动更新会覆盖配置（详见检查一）

配置完链式代理后，如果 Clash 订阅自动更新，会覆盖你的手动修改，**家宽代理静默失效**。详细说明和应对方法见上方「检查一」。

### 订阅/IP 变更后检查白名单

以下情况发生时，务必去 lycheeip 后台确认你的 IP 在白名单内：
- 更换了订阅
- 续费或升级了订阅
- 家宽 IP 发生变化（ISP 重新分配）
- 白名单被重置或更新

验证方法：登录 lycheeip 后台 → 查看白名单列表 → 确认当前出口 IP 在列表中。

### 为什么选 lycheeip 而不是 cliproxy

cliproxy 的 IP **不是独享的**，多人共用同一个出口 IP，风险高。lycheeip 提供独享家宽 IP，更安全。

### 购买节点建议

- 推荐买**美国**的家宽节点
- **避免洛杉矶**——洛杉矶是华人做跨境电商的热门地区，那里的 IP 被大量使用，风控风险更高
- 建议选择其他城市（如达拉斯、西雅图、芝加哥等）
