#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_NAME="$(basename "$0")"
readonly START_TIME="$(date +%s)"

REPO_URL="${REPO_URL:-https://github.com/Mike-Zhuang/My_Own_VPN.git}"
BRANCH="${BRANCH:-main}"
REPO_DIR="${REPO_DIR:-/opt/chinavpn-public-site}"
WEB_ROOT="${WEB_ROOT:-/www/wwwroot/chinavpn.mikezhuang.cn}"
PUBLIC_DIR="${PUBLIC_DIR:-public}"
LOCK_FILE="${LOCK_FILE:-/tmp/chinavpn-public-site-sync.lock}"

logInfo() {
  printf '[%s] [%s] %s\n' "$(date '+%F %T')" "$SCRIPT_NAME" "$1"
}

fail() {
  printf '[%s] [%s] ERROR: %s\n' "$(date '+%F %T')" "$SCRIPT_NAME" "$1" >&2
  exit 1
}

requireCommand() {
  local commandName="$1"

  command -v "$commandName" >/dev/null 2>&1 || fail "缺少命令：${commandName}"
}

acquireLock() {
  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    logInfo '上一次同步仍在运行，本次跳过。'
    exit 0
  fi
}

prepareRepo() {
  if [[ -d "${REPO_DIR}/.git" ]]; then
    logInfo "发现已有仓库：${REPO_DIR}"
    git -C "$REPO_DIR" fetch --prune origin "$BRANCH"
    git -C "$REPO_DIR" reset --hard "origin/${BRANCH}"
    git -C "$REPO_DIR" clean -fd
  else
    logInfo "首次克隆仓库到：${REPO_DIR}"
    rm -rf "$REPO_DIR"
    mkdir -p "$(dirname "$REPO_DIR")"
    git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$REPO_DIR"
  fi
}

runSafetyCheck() {
  if [[ -x "${REPO_DIR}/scripts/check-secrets.sh" ]]; then
    logInfo '执行敏感信息检查。'
    git -C "$REPO_DIR" status --short
    (cd "$REPO_DIR" && ./scripts/check-secrets.sh)
  else
    fail '找不到 scripts/check-secrets.sh，拒绝同步。'
  fi
}

deployPublicFiles() {
  local sourceDir="${REPO_DIR}/${PUBLIC_DIR}"
  local commitHash

  [[ -d "$sourceDir" ]] || fail "找不到公网目录：${sourceDir}"
  [[ -f "${sourceDir}/index.html" ]] || fail "找不到入口文件：${sourceDir}/index.html"

  mkdir -p "$WEB_ROOT"

  logInfo "同步 ${sourceDir}/ 到 ${WEB_ROOT}/"
  rsync -a --delete --exclude='.*' "${sourceDir}/" "${WEB_ROOT}/"

  commitHash="$(git -C "$REPO_DIR" rev-parse --short HEAD)"
  {
    printf 'deployedAt=%s\n' "$(date '+%F %T')"
    printf 'repo=%s\n' "$REPO_URL"
    printf 'branch=%s\n' "$BRANCH"
    printf 'commit=%s\n' "$commitHash"
  } > "${WEB_ROOT}/deploy-info.txt"

  logInfo "部署完成，当前 commit：${commitHash}"
}

main() {
  local duration

  logInfo '开始同步公网状态页。'
  logInfo "仓库：${REPO_URL}"
  logInfo "分支：${BRANCH}"
  logInfo "网站目录：${WEB_ROOT}"

  requireCommand git
  requireCommand rsync
  requireCommand flock
  acquireLock
  prepareRepo
  runSafetyCheck
  deployPublicFiles

  duration=$(( $(date +%s) - START_TIME ))
  logInfo "同步任务结束，耗时 ${duration}s。"
}

main "$@"
