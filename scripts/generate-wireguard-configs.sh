#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_NAME="$(basename "$0")"
readonly OUTPUT_SERVER_DIR="server-secrets"
readonly OUTPUT_CLIENT_DIR="client-configs"
readonly OUTPUT_QR_DIR="qr-codes"

loadEnv() {
  if [[ -f ".env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source ".env"
    set +a
  fi
}

requireCommand() {
  local commandName="$1"

  if ! command -v "$commandName" >/dev/null 2>&1; then
    printf '缺少命令：%s\n' "$commandName" >&2
    exit 1
  fi
}

requireValue() {
  local valueName="$1"
  local value="${!valueName:-}"

  if [[ -z "$value" ]]; then
    printf '缺少环境变量：%s。请复制 .env.example 为 .env 后填写。\n' "$valueName" >&2
    exit 1
  fi
}

normalizeDeviceName() {
  local rawName="$1"
  local normalizedName

  normalizedName="$(printf '%s' "$rawName" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9-]+/-/g; s/^-+//; s/-+$//')"

  if [[ -z "$normalizedName" ]]; then
    printf '设备名无效，请使用英文、数字或短横线。\n' >&2
    exit 1
  fi

  printf '%s' "$normalizedName"
}

nextClientIp() {
  local index="$1"
  local lastOctet=$((index + 1))

  if (( lastOctet < 2 || lastOctet > 254 )); then
    printf '客户端序号超出范围：%s\n' "$index" >&2
    exit 1
  fi

  printf '10.66.0.%s' "$lastOctet"
}

writeServerConfig() {
  local serverPrivateKey="$1"
  local clientPublicKey="$2"
  local clientIp="$3"
  local deviceName="$4"

  cat > "${OUTPUT_SERVER_DIR}/wg0.conf.example" <<EOF
[Interface]
Address = ${SERVER_VPN_IP}/24
ListenPort = ${VPN_PORT}
PrivateKey = ${serverPrivateKey}
PostUp = iptables -A FORWARD -i wg0 -o ${NETWORK_INTERFACE} -j ACCEPT; iptables -A FORWARD -i ${NETWORK_INTERFACE} -o wg0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT; iptables -t nat -A POSTROUTING -s ${VPN_CIDR} -o ${NETWORK_INTERFACE} -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -o ${NETWORK_INTERFACE} -j ACCEPT; iptables -D FORWARD -i ${NETWORK_INTERFACE} -o wg0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT; iptables -t nat -D POSTROUTING -s ${VPN_CIDR} -o ${NETWORK_INTERFACE} -j MASQUERADE

# ${deviceName}
[Peer]
PublicKey = ${clientPublicKey}
AllowedIPs = ${clientIp}/32
EOF
}

writeClientConfigs() {
  local clientPrivateKey="$1"
  local serverPublicKey="$2"
  local clientIp="$3"
  local deviceName="$4"

  cat > "${OUTPUT_CLIENT_DIR}/${deviceName}-full-tunnel.conf" <<EOF
[Interface]
PrivateKey = ${clientPrivateKey}
Address = ${clientIp}/32
DNS = ${DNS_SERVERS}
MTU = ${MTU}

[Peer]
PublicKey = ${serverPublicKey}
Endpoint = ${SERVER_ENDPOINT}:${VPN_PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

  cat > "${OUTPUT_CLIENT_DIR}/${deviceName}-management-only.conf" <<EOF
[Interface]
PrivateKey = ${clientPrivateKey}
Address = ${clientIp}/32
DNS = ${DNS_SERVERS}
MTU = ${MTU}

[Peer]
PublicKey = ${serverPublicKey}
Endpoint = ${SERVER_ENDPOINT}:${VPN_PORT}
AllowedIPs = ${VPN_CIDR}
PersistentKeepalive = 25
EOF
}

writeQrCodes() {
  local deviceName="$1"

  if command -v qrencode >/dev/null 2>&1; then
    qrencode -o "${OUTPUT_QR_DIR}/${deviceName}-full-tunnel-qr.png" < "${OUTPUT_CLIENT_DIR}/${deviceName}-full-tunnel.conf"
    qrencode -o "${OUTPUT_QR_DIR}/${deviceName}-management-only-qr.png" < "${OUTPUT_CLIENT_DIR}/${deviceName}-management-only.conf"
  fi
}

main() {
  local rawDeviceName="${1:-}"
  local deviceName
  local clientIndex="${2:-1}"
  local clientIp
  local serverPrivateKey
  local serverPublicKey
  local clientPrivateKey
  local clientPublicKey

  if [[ -z "$rawDeviceName" ]]; then
    printf '用法：%s <device-name> [client-index]\n' "$SCRIPT_NAME" >&2
    exit 1
  fi

  loadEnv
  requireCommand wg
  requireValue SERVER_ENDPOINT
  requireValue VPN_PORT
  requireValue VPN_CIDR
  requireValue SERVER_VPN_IP
  requireValue NETWORK_INTERFACE
  requireValue DNS_SERVERS
  requireValue MTU

  deviceName="$(normalizeDeviceName "$rawDeviceName")"
  clientIp="$(nextClientIp "$clientIndex")"

  mkdir -p "$OUTPUT_SERVER_DIR" "$OUTPUT_CLIENT_DIR" "$OUTPUT_QR_DIR"
  chmod 700 "$OUTPUT_SERVER_DIR" "$OUTPUT_CLIENT_DIR" "$OUTPUT_QR_DIR"

  serverPrivateKey="$(wg genkey)"
  serverPublicKey="$(printf '%s' "$serverPrivateKey" | wg pubkey)"
  clientPrivateKey="$(wg genkey)"
  clientPublicKey="$(printf '%s' "$clientPrivateKey" | wg pubkey)"

  writeServerConfig "$serverPrivateKey" "$clientPublicKey" "$clientIp" "$deviceName"
  writeClientConfigs "$clientPrivateKey" "$serverPublicKey" "$clientIp" "$deviceName"
  writeQrCodes "$deviceName"

  chmod 600 "${OUTPUT_SERVER_DIR}/wg0.conf.example" "${OUTPUT_CLIENT_DIR}/${deviceName}-full-tunnel.conf" "${OUTPUT_CLIENT_DIR}/${deviceName}-management-only.conf"

  printf '已生成配置到被忽略目录。请不要把这些文件提交到 Git。\n'
  printf '服务端配置模板：%s\n' "${OUTPUT_SERVER_DIR}/wg0.conf.example"
  printf '客户端配置：%s, %s\n' "${OUTPUT_CLIENT_DIR}/${deviceName}-full-tunnel.conf" "${OUTPUT_CLIENT_DIR}/${deviceName}-management-only.conf"
}

main "$@"
