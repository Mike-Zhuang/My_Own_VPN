# 部署检查清单

## 实施前

- 确认云安全组只新增 WireGuard UDP 端口，不改现有 SSH 策略。
- 记录当前监听端口：

```bash
ss -tulpen
```

- 备份 iptables：

```bash
iptables-save > /root/iptables-before-wireguard-$(date +%F-%H%M%S).rules
```

- 记录 forwarding 状态：

```bash
sysctl net.ipv4.ip_forward net.ipv6.conf.all.forwarding
```

## WireGuard

- 安装依赖：

```bash
apt update
apt install -y wireguard qrencode
```

- 配置文件放在 `/etc/wireguard/wg0.conf`，权限设置为 `600`。
- 只追加必要 NAT/forwarding 规则，不执行 `iptables -F`。
- 启动服务：

```bash
systemctl enable wg-quick@wg0
systemctl start wg-quick@wg0
```

## 验证

- 服务状态：

```bash
systemctl status wg-quick@wg0
wg show
sysctl net.ipv4.ip_forward
```

- 端口监听：

```bash
ss -ulpen | grep 41194
```

- 客户端连通：

```bash
ping 10.66.0.1
```

- full-tunnel 模式下确认出口 IP 为服务器公网出口。
- management-only 模式下确认日常海外网络不被接管。

## 回滚

- 停止 WireGuard：

```bash
systemctl stop wg-quick@wg0
systemctl disable wg-quick@wg0
```

- 如转发规则异常，使用实施前备份恢复；不要清空整套 iptables。
