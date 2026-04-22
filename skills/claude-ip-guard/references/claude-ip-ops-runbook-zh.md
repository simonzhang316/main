# Claude 家宽 IP 运行手册（Clash Verge）

更新时间：2026-04-22

## 目标

- Claude 相关流量始终走家宽出口。
- 日常有可视化监控（网页），同时保留命令行硬校验。
- 发生订阅漂移或节点失效时可以快速恢复。

## 当前推荐职责分工

- 可视化查看：`ping0.cc`（看 IP、ASN、位置、经纬度）。
- 自动判定与拦截：本地守卫脚本 + 本地监控页（不要只依赖单站）。

说明：
- `ping0.cc` 适合人工观察，非常直观。
- 放行/拦截逻辑应以多源结果为准，避免单站异常导致误判。

## 日常开 Claude 前检查

```bash
curl -4 -s ifconfig.me/ip && echo
curl -4 -s ifconfig.me && echo
curl -4 -s ifconfig.me/all.json | rg -o '([0-9]{1,3}\.){3}[0-9]{1,3}' -m 1 && echo
```

判定标准：
- 三个来源至少 2/3 一致再继续。
- 若有单源失败但其余一致，视为源站故障，不视为 IP 漂移。

## 监控页状态解释

常见状态及含义：

1. `安全/通过`
- 多源一致且与目标 IP 一致。

2. `连接异常（缓存）`
- 监控后端短时不可达，页面展示的是上次成功结果。
- 若持续超过 30 秒，重启监控服务再看。

3. `危险/拦截`
- 多源结果与目标 IP 不一致，或置信度不足。
- 在恢复之前，不要登录 Claude。

## 守卫脚本策略要点

- 先校验当前公网 IP 是否目标值。
- 不一致时触发 `claude-ip-heal` 自动修复。
- 修复后再二次核验；仍不一致则拒绝打开 Claude。
- 修复逻辑需要支持 `rg` 缺失场景（自动回退 `grep`）。


## 本地监控启停命令

```bash
# 启动（目标 IP 可按需替换）
/Users/zhangxinran/Scratch/clash-verge/ip-monitor/start_ip_monitor.sh <EXPECTED_IP>

# 停止
/Users/zhangxinran/Scratch/clash-verge/ip-monitor/stop_ip_monitor.sh
```

默认访问地址：`http://127.0.0.1:8765`。

## Clash 组与节点说明

- `Claude` 组用于 Claude 相关规则路由。
- 若界面里看不到 `Codex`，优先检查是否显示为 `Codex-Stable`（等价分组）。
- 主订阅与备份订阅可做双活策略：
  - 主：`mitce`
  - 备：`狗狗加速`
- 建议“长时间失效再切换”，避免频繁抖动。

## 故障恢复顺序（建议严格按顺序）

1. 退出 Claude（桌面端与 CLI）。
2. Clash 确认：`rule` 模式、TUN 开启、IPv6 关闭。
3. 选择 Claude 目标组到家宽链路。
4. 执行：
   ```bash
   claude-ip-heal <EXPECTED_IP> <EXPECTED_PORT>
   ```
5. 再跑三条 `curl` 校验。
6. 校验通过后再打开 Claude。

## 不入库信息（安全要求）

以下仅保留在本地，不写入 git：
- 家宽账号密码
- 订阅 URL 完整参数
- token / cookie / access_key
- 个人邮箱、手机号、真实姓名等可识别信息

## 版本记录

- 2026-04-22：补充 `ping0.cc` 与本地监控分工、连接异常判定、多源一致性策略、`Codex-Stable` 对照说明。
