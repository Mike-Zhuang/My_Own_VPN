#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_NAME="$(basename "$0")"

main() {
  printf '[%s] 当前监听端口：\n' "$SCRIPT_NAME"
  ss -tulpen

  printf '\n[%s] 当前 forwarding：\n' "$SCRIPT_NAME"
  sysctl net.ipv4.ip_forward net.ipv6.conf.all.forwarding

  printf '\n[%s] WireGuard 状态：\n' "$SCRIPT_NAME"
  if command -v wg >/dev/null 2>&1; then
    wg show || true
  else
    printf '未安装 wg 命令。\n'
  fi

  printf '\n[%s] iptables 摘要：\n' "$SCRIPT_NAME"
  iptables -S | sed -n '1,120p'
  iptables -t nat -S | sed -n '1,120p'
}

main "$@"
