#!/usr/bin/env bash
set -euo pipefail

readonly WG_CONFIG_SOURCE="${WG_CONFIG_SOURCE:-server-secrets/wg0.conf.example}"
readonly WG_CONFIG_TARGET="/etc/wireguard/wg0.conf"
readonly SYSCTL_CONFIG="/etc/sysctl.d/99-wireguard-forward.conf"

requireRoot() {
  if [[ "${EUID}" -ne 0 ]]; then
    printf '请在服务器上使用 root 执行该脚本。\n' >&2
    exit 1
  fi
}

requireConfig() {
  if [[ ! -f "$WG_CONFIG_SOURCE" ]]; then
    printf '找不到 WireGuard 配置：%s\n' "$WG_CONFIG_SOURCE" >&2
    printf '请先生成配置，并在部署前人工复核。\n' >&2
    exit 1
  fi
}

backupState() {
  local backupTime

  backupTime="$(date +%F-%H%M%S)"
  ss -tulpen > "/root/ports-before-wireguard-${backupTime}.txt"
  iptables-save > "/root/iptables-before-wireguard-${backupTime}.rules"
  sysctl net.ipv4.ip_forward net.ipv6.conf.all.forwarding > "/root/sysctl-before-wireguard-${backupTime}.txt"
}

installPackages() {
  apt update
  apt install -y wireguard qrencode
}

enableForwarding() {
  printf 'net.ipv4.ip_forward=1\n' > "$SYSCTL_CONFIG"
  sysctl --system
}

installConfig() {
  install -d -m 700 /etc/wireguard
  install -m 600 "$WG_CONFIG_SOURCE" "$WG_CONFIG_TARGET"
}

startService() {
  systemctl enable wg-quick@wg0
  systemctl restart wg-quick@wg0
  systemctl --no-pager --full status wg-quick@wg0
  wg show
}

main() {
  requireRoot
  requireConfig
  backupState
  installPackages
  enableForwarding
  installConfig
  startService
}

main "$@"
