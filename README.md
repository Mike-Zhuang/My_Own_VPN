# 自用回国 VPN 安全仓库

这个仓库只保存脱敏文档、模板和辅助脚本。真实服务器 IP、SSH 端口、WireGuard 私钥、客户端配置、二维码和运维交接细节都不得提交到 Git。

## 目标

- 使用 WireGuard 搭建个人自用 VPN，让海外设备按需使用中国大陆出口网络。
- 保持部署轻量，适合低带宽小规模设备使用。
- 公网页面只作为低权限状态入口；真正的设备管理、密钥生成和配置下载必须走 VPN 内网或服务器本机。

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

## 公网页面边界

`chinavpn.mikezhuang.cn` 可以作为低权限入口，但不应暴露完整 WireGuard 管理能力。公网入口只展示服务说明、状态提示和登录保护；新增设备、删除设备、下载配置等操作必须限制在 VPN 内网。

## 宝塔自动同步公网状态页

在宝塔计划任务里创建 Shell 脚本任务，执行：

```bash
bash /opt/chinavpn-public-site/scripts/bt-auto-sync-public-site.sh
```

建议频率与其他站点一致：每小时第 0 分钟开始，每隔 10 分钟执行一次。脚本会在宝塔执行日志中输出同步过程，只把仓库里的 `public/` 同步到网站目录，不同步密钥、配置或运维文档。

## 风险提醒

- 自建 VPN 不等于匿名网络。云厂商和运营商仍可能看到连接元数据。
- 不要公开共享或售卖该服务。
- 设备丢失后应立即撤销对应 WireGuard peer。
- 不要为了方便把管理面板直接暴露到公网。
