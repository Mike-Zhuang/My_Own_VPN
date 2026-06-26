#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_NAME="$(basename "$0")"

printInfo() {
  printf '[%s] %s\n' "$SCRIPT_NAME" "$1"
}

collectFiles() {
  git ls-files --cached --others --exclude-standard
}

isAllowedIp() {
  local ipAddress="$1"
  local firstOctet secondOctet

  IFS='.' read -r firstOctet secondOctet _ _ <<< "$ipAddress"

  case "$ipAddress" in
    0.0.0.0|127.*|10.*|192.168.*|223.5.5.5|119.29.29.29)
      return 0
      ;;
  esac

  if [[ "$firstOctet" == "172" ]] && (( 10#$secondOctet >= 16 && 10#$secondOctet <= 31 )); then
    return 0
  fi

  return 1
}

scanIpAddresses() {
  local filePath="$1"
  local ipAddress

  while IFS= read -r ipAddress; do
    if ! isAllowedIp "$ipAddress"; then
      printf '发现疑似公网 IP，请确认是否已脱敏：%s (%s)\n' "$filePath" "$ipAddress" >&2
      return 1
    fi
  done < <(grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' "$filePath" || true)
}

scanFile() {
  local filePath="$1"

  [[ -f "$filePath" ]] || return 0

  if grep -nE 'BEGIN (RSA |OPENSSH |EC |PRIVATE )?PRIVATE KEY|ssh-(rsa|ed25519)[[:space:]][A-Za-z0-9+/]{80,}' "$filePath" >/dev/null; then
    printf '发现疑似密钥内容：%s\n' "$filePath" >&2
    return 1
  fi

  # WireGuard 私钥通常是 44 字符 base64；只匹配真实值，避免模板字段名误报。
  if grep -nE '(PrivateKey|PresharedKey)[[:space:]]*=[[:space:]]*[A-Za-z0-9+/]{43}=' "$filePath" >/dev/null; then
    printf '发现疑似 WireGuard 密钥：%s\n' "$filePath" >&2
    return 1
  fi

  # 第三方 vendor 源码会包含官方文档里的示例 IP；继续扫描密钥，但跳过公网 IP 脱敏检查。
  case "$filePath" in
    vendor/wgdashboard/*)
      return 0
      ;;
  esac

  scanIpAddresses "$filePath"
}

main() {
  local failed=0
  local filePath

  while IFS= read -r filePath; do
    scanFile "$filePath" || failed=1
  done < <(collectFiles)

  if [[ "$failed" -ne 0 ]]; then
    printf '敏感信息检查失败，请移除密钥、真实配置或真实基础设施信息后再提交。\n' >&2
    exit 1
  fi

  printInfo '敏感信息检查通过。'
}

main "$@"
