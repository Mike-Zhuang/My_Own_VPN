# 自用回国 VPN 安全仓库

这个仓库保存脱敏文档、模板、辅助脚本，以及当前自用的 WGDashboard vendor 源码。真实服务器 IP、SSH 端口、WireGuard 私钥、客户端配置、二维码、运行时数据库和运维交接细节都不得提交到 Git。

## 目标

- 使用 WireGuard 搭建个人自用 VPN，让海外设备按需使用中国大陆出口网络。
- 保持部署轻量，适合低带宽小规模设备使用。
- 公网管理面板使用 WGDashboard，并通过强密码与后续 MFA 控制访问。

## 默认架构

- 协议：WireGuard UDP
- 默认端口：`41194/udp`
- VPN 网段：`10.66.0.0/24`
- 服务端 VPN 地址：`10.66.0.1`
- 默认 MTU：`1280`
- 客户端模式：
  - `full-tunnel`：全局流量走 VPN。
  - `management-only`：只访问 VPN 内网和管理地址。

## 仓库安全规则

- `PLAN.md` 是本地交接文档，可能包含真实基础设施信息，默认被忽略。
- `.env`、`*.key`、`*.pem`、`*.conf`、`client-configs/`、`server-secrets/`、二维码图片等都被忽略。
- 模板文件使用 `.example` 后缀，例如 `.env.example` 或 `*.conf.example`。
- 提交前运行：

```bash
./scripts/check-secrets.sh
```

## 本地生成配置

先复制示例环境文件：

```bash
cp .env.example .env
```

编辑 `.env` 后生成服务端和客户端模板：

```bash
./scripts/generate-wireguard-configs.sh device-one
```

生成结果会写入被忽略目录：

- `server-secrets/`
- `client-configs/`
- `qr-codes/`

## 部署顺序

1. 先在服务器备份当前端口、iptables 和 sysctl 状态。
2. 安装 WireGuard 与二维码工具。
3. 开启 IPv4 forwarding。
4. 追加必要 NAT/forwarding 规则，不清空已有 iptables。
5. 启动 `wg-quick@wg0`。
6. 用一台设备验证 full-tunnel 与 management-only 两种模式。
7. 稳定后再上线只读公网页或 VPN 内网管理面板。

## WGDashboard 前端与上游更新

WGDashboard 源码放在：

```text
vendor/wgdashboard/
```

这个目录来自上游 `WGDashboard/WGDashboard`。当前上游版本记录在：

```text
vendor/wgdashboard.UPSTREAM_COMMIT
vendor/wgdashboard.UPSTREAM_SOURCE
```

以后如果要改面板 UI，优先修改：

```text
vendor/wgdashboard/src/static/app/
```

宝塔同步任务会把 `vendor/wgdashboard/src/` 部署到服务器 `/opt/wgdashboard`，保留服务器本地的 `wg-dashboard.ini`、数据库、日志和 venv。前端源码变化时会自动执行 `npm ci && npm run build`。

GitHub Actions 会定时运行 `.github/workflows/update-wgdashboard-vendor.yml`，检查 WGDashboard 上游更新并创建更新 PR。这样服务器不需要直接拉 WGDashboard 官方仓库，只需要继续通过 gitproxy 拉取本仓库。

手动检查上游更新时可以运行：

```bash
./scripts/update-wgdashboard-vendor.sh
```

该脚本会优先尝试 gitproxy，再回退到 GitHub 直连。

## 宝塔自动同步

在宝塔计划任务里创建 Shell 脚本任务，执行：

```bash
/usr/bin/flock -n /tmp/chinavpn-sync.lock /usr/local/bin/chinavpn-sync-deploy.sh
```

建议频率与其他站点一致：每小时第 0 分钟开始，每隔 10 分钟执行一次。脚本会在宝塔执行日志中输出同步过程：

- 通过 gitproxy 拉取本仓库。
- 运行敏感信息检查。
- 部署 `vendor/wgdashboard/src/` 到 `/opt/wgdashboard`。
- 按需构建 WGDashboard 前端。
- 重启 `wgdashboard` 并校验 Nginx。

## 风险提醒

- 自建 VPN 不等于匿名网络。云厂商和运营商仍可能看到连接元数据。
- 不要公开共享或售卖该服务。
- 设备丢失后应立即撤销对应 WireGuard peer。
- 不要为了方便把管理面板直接暴露到公网。
