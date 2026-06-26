#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_NAME="$(basename "$0")"

UPSTREAM_REPO="${UPSTREAM_REPO:-https://github.com/WGDashboard/WGDashboard.git}"
UPSTREAM_REF="${UPSTREAM_REF:-main}"
VENDOR_DIR="${VENDOR_DIR:-vendor/wgdashboard}"
GIT_TIMEOUT_SECONDS="${GIT_TIMEOUT_SECONDS:-90}"
WORK_DIR="${WORK_DIR:-$(mktemp -d)}"
REPO_CANDIDATES=(
  "https://gh-proxy.com/${UPSTREAM_REPO}"
  "https://gitproxy.click/${UPSTREAM_REPO}"
  "$UPSTREAM_REPO"
)

logInfo() {
  printf '[%s] [%s] %s\n' "$(date '+%F %T')" "$SCRIPT_NAME" "$1"
}

fail() {
  printf '[%s] [%s] ERROR: %s\n' "$(date '+%F %T')" "$SCRIPT_NAME" "$1" >&2
  exit 1
}

cleanup() {
  if [[ -n "${WORK_DIR:-}" && -d "$WORK_DIR" && "$WORK_DIR" == /tmp/* ]]; then
    rm -rf "$WORK_DIR"
  fi
}

pickSource() {
  local sourceUrl remoteHash

  for sourceUrl in "${REPO_CANDIDATES[@]}"; do
    if command -v timeout >/dev/null 2>&1; then
      remoteHash="$(timeout "${GIT_TIMEOUT_SECONDS}s" git ls-remote "$sourceUrl" "$UPSTREAM_REF" 2>/dev/null | awk 'NR==1{print $1}')"
    else
      remoteHash="$(git ls-remote "$sourceUrl" "$UPSTREAM_REF" 2>/dev/null | awk 'NR==1{print $1}')"
    fi
    if [[ -n "$remoteHash" ]]; then
      printf '%s|%s' "$sourceUrl" "$remoteHash"
      return 0
    fi
  done

  return 1
}

syncVendor() {
  local picked sourceUrl remoteHash cloneDir

  picked="$(pickSource)" || fail '没有可用的 WGDashboard 上游源。'
  sourceUrl="${picked%%|*}"
  remoteHash="${picked##*|}"
  cloneDir="${WORK_DIR}/wgdashboard"

  logInfo "上游源：${sourceUrl}"
  logInfo "上游版本：${remoteHash}"

  rm -rf "$cloneDir"
  if command -v timeout >/dev/null 2>&1; then
    timeout "${GIT_TIMEOUT_SECONDS}s" git clone --depth 1 --branch "$UPSTREAM_REF" "$sourceUrl" "$cloneDir"
  else
    git clone --depth 1 --branch "$UPSTREAM_REF" "$sourceUrl" "$cloneDir"
  fi

  mkdir -p "$(dirname "$VENDOR_DIR")"
  rsync -a --delete \
    --exclude='.git' \
    --exclude='**/node_modules' \
    --exclude='src/db' \
    --exclude='src/log' \
    --exclude='src/venv' \
    --exclude='src/gunicorn.pid' \
    --exclude='src/wg-dashboard.ini' \
    --exclude='src/wg-dashboard.ini.*' \
    --exclude='src/wg-dashboard-oidc-providers.json' \
    "${cloneDir}/" "${VENDOR_DIR}/"

  printf '%s\n' "$remoteHash" > "${VENDOR_DIR}.UPSTREAM_COMMIT"
  {
    printf 'repo=%s\n' "$UPSTREAM_REPO"
    printf 'ref=%s\n' "$UPSTREAM_REF"
  } > "${VENDOR_DIR}.UPSTREAM_SOURCE"

  logInfo "vendor 已更新到 ${remoteHash}。"
}

main() {
  command -v git >/dev/null 2>&1 || fail '缺少 git。'
  command -v rsync >/dev/null 2>&1 || fail '缺少 rsync。'

  trap cleanup EXIT
  syncVendor

  if [[ -x scripts/check-secrets.sh ]]; then
    ./scripts/check-secrets.sh
  fi
}

main "$@"
