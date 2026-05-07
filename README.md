# clash-verge

这是 Clash Verge + Claude 家宽 IP 的独立项目目录（canonical location）。

## 目录结构

- `skills/claude-ip-guard/`
  - Claude IP 守卫 skill、配置说明、修复脚本
- `ip-monitor/`
  - 本地 IP 监控页（`127.0.0.1:8765`）

## 常用命令

```bash
# 启动本地监控页
/Users/zhangxinran/Projects/clash-verge/ip-monitor/start_ip_monitor.sh <EXPECTED_IP>

# 停止本地监控页
/Users/zhangxinran/Projects/clash-verge/ip-monitor/stop_ip_monitor.sh

# 修复家宽 IP 漂移
/Users/zhangxinran/Projects/clash-verge/skills/claude-ip-guard/scripts/claude-ip-heal.sh <EXPECTED_IP> <EXPECTED_PORT>
```

## 备注

本目录是当前唯一维护位置。
