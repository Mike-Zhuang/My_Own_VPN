#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_NAME="$(basename "$0")"
readonly START_TIME="$(date +%s)"

REPO_URL="${REPO_URL:-https://github.com/Mike-Zhuang/My_Own_VPN.git}"
BRANCH="${BRANCH:-main}"
REPO_MAIN_REF="${REPO_MAIN_REF:-refs/heads/main}"
REPO_DIR="${REPO_DIR:-/opt/chinavpn-public-site}"
WEB_ROOT="${WEB_ROOT:-/www/wwwroot/chinavpn.mikezhuang.cn}"
PUBLIC_DIR="${PUBLIC_DIR:-public}"
LOCK_FILE="${LOCK_FILE:-/tmp/chinavpn-public-site-sync.lock}"
GIT_TIMEOUT_SECONDS="${GIT_TIMEOUT_SECONDS:-45}"
DEPLOY_PUBLIC_FILES="${DEPLOY_PUBLIC_FILES:-0}"
DEPLOY_WGDASHBOARD="${DEPLOY_WGDASHBOARD:-1}"
PANEL_SERVICE="${PANEL_SERVICE:-wgdashboard}"
WGDASHBOARD_VENDOR_DIR="${WGDASHBOARD_VENDOR_DIR:-vendor/wgdashboard/src}"
WGDASHBOARD_TARGET_DIR="${WGDASHBOARD_TARGET_DIR:-/opt/wgdashboard}"
WGDASHBOARD_STATE_DIR="${WGDASHBOARD_STATE_DIR:-/var/lib/chinavpn}"
REPO_CANDIDATES=(
  "https://gh-proxy.com/https://github.com/Mike-Zhuang/My_Own_VPN.git"
  "https://gitproxy.click/https://github.com/Mike-Zhuang/My_Own_VPN.git"
  "$REPO_URL"
)

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

pickSource() {
  local sourceUrl remoteHash

  for sourceUrl in "${REPO_CANDIDATES[@]}"; do
    remoteHash="$(timeout "${GIT_TIMEOUT_SECONDS}s" git ls-remote "$sourceUrl" "$REPO_MAIN_REF" 2>/dev/null | awk 'NR==1{print $1}')"
    if [[ -n "$remoteHash" ]]; then
      printf '%s|%s' "$sourceUrl" "$remoteHash"
      return 0
    fi
  done

  return 1
}

prepareRepo() {
  local picked sourceUrl remoteHash localHash fetchHash

  picked="$(pickSource)" || fail '没有可用的 gitproxy/GitHub 源，拒绝同步。'
  sourceUrl="${picked%%|*}"
  remoteHash="${picked##*|}"
  logInfo "Git 源：${sourceUrl}"
  logInfo "远端版本：${remoteHash}"

  if [[ -d "${REPO_DIR}/.git" ]]; then
    logInfo "发现已有仓库：${REPO_DIR}"
    git config --global --add safe.directory "$REPO_DIR" >/dev/null 2>&1 || true
    git -C "$REPO_DIR" remote set-url origin "$sourceUrl"
    localHash="$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null || true)"
    git -C "$REPO_DIR" reset --hard HEAD
    git -C "$REPO_DIR" clean -fd
    timeout "${GIT_TIMEOUT_SECONDS}s" git -C "$REPO_DIR" fetch --depth 1 --prune origin "$BRANCH"
    fetchHash="$(git -C "$REPO_DIR" rev-parse "origin/${BRANCH}")"
    if [[ "$localHash" == "$fetchHash" ]]; then
      logInfo "已是最新版本：${fetchHash}"
    fi
    git -C "$REPO_DIR" checkout -B "$BRANCH" "origin/${BRANCH}" --force
    git -C "$REPO_DIR" reset --hard "origin/${BRANCH}"
    git -C "$REPO_DIR" clean -fd
  else
    logInfo "首次克隆仓库到：${REPO_DIR}"
    rm -rf "$REPO_DIR"
    mkdir -p "$(dirname "$REPO_DIR")"
    timeout "${GIT_TIMEOUT_SECONDS}s" git clone --depth 1 --branch "$BRANCH" "$sourceUrl" "$REPO_DIR"
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

  if [[ "$DEPLOY_PUBLIC_FILES" != "1" ]]; then
    logInfo '当前使用 WGDashboard 自带前端，跳过静态公网文件同步。'
    return 0
  fi

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

hashDirectory() {
  local directoryPath="$1"

  [[ -d "$directoryPath" ]] || return 1
  find "$directoryPath" -type f \
    ! -path '*/node_modules/*' \
    ! -path '*/dist/*' \
    ! -path '*/.vite/*' \
    -print0 \
    | sort -z \
    | xargs -0 sha256sum \
    | sha256sum \
    | awk '{print $1}'
}

buildFrontendIfNeeded() {
  local sourceDir="$1"
  local stateFile="${WGDASHBOARD_STATE_DIR}/frontend-source.sha256"
  local currentHash previousHash

  if ! command -v npm >/dev/null 2>&1; then
    fail '需要构建 WGDashboard 前端，但服务器缺少 npm。'
  fi

  mkdir -p "$WGDASHBOARD_STATE_DIR"
  currentHash="$(
    {
      hashDirectory "${sourceDir}/static/app"
      hashDirectory "${sourceDir}/static/client"
    } | sha256sum | awk '{print $1}'
  )"
  previousHash="$(cat "$stateFile" 2>/dev/null || true)"

  if [[ "$currentHash" == "$previousHash" && -d "${sourceDir}/static/dist/WGDashboardAdmin" ]]; then
    logInfo 'WGDashboard 前端源码无变化，跳过 build。'
    return 0
  fi

  logInfo '构建 WGDashboard 管理端前端。'
  (cd "${sourceDir}/static/app" && npm ci && npm run build)

  logInfo '构建 WGDashboard Client 前端。'
  (cd "${sourceDir}/static/client" && npm ci && npm run build)

  printf '%s\n' "$currentHash" > "$stateFile"
}

deployWgdashboard() {
  local sourceDir="${REPO_DIR}/${WGDASHBOARD_VENDOR_DIR}"
  local targetDir="$WGDASHBOARD_TARGET_DIR"

  if [[ "$DEPLOY_WGDASHBOARD" != "1" ]]; then
    logInfo '跳过 WGDashboard vendor 部署。'
    return 0
  fi

  [[ -d "$sourceDir" ]] || fail "找不到 WGDashboard vendor 源码：${sourceDir}"
  [[ -f "${sourceDir}/dashboard.py" ]] || fail "找不到 WGDashboard 入口：${sourceDir}/dashboard.py"

  mkdir -p "$targetDir"

  logInfo "同步 WGDashboard 源码到 ${targetDir}/"
  rsync -a --delete \
    --exclude='db/' \
    --exclude='log/' \
    --exclude='venv/' \
    --exclude='__pycache__/' \
    --exclude='*.pyc' \
    --exclude='node_modules/' \
    --exclude='gunicorn.pid' \
    --exclude='wg-dashboard.ini' \
    --exclude='wg-dashboard.ini.*' \
    --exclude='wg-dashboard-oidc-providers.json' \
    --exclude='static/dist/' \
    "${sourceDir}/" "${targetDir}/"

  buildFrontendIfNeeded "$targetDir"
}

restartPanelService() {
  if systemctl list-unit-files "${PANEL_SERVICE}.service" >/dev/null 2>&1; then
    logInfo "重启 ${PANEL_SERVICE} 服务。"
    systemctl restart "$PANEL_SERVICE"
    systemctl is-active "$PANEL_SERVICE"
  fi

  if command -v nginx >/dev/null 2>&1; then
    logInfo '校验 Nginx 配置。'
    nginx -t
    nginx -s reload || true
  fi
}

main() {
  local duration

  logInfo '开始同步公网状态页。'
  logInfo "仓库：${REPO_URL}"
  logInfo "分支：${BRANCH}"
  logInfo "网站目录：${WEB_ROOT}"
  logInfo "面板服务：${PANEL_SERVICE}"
  logInfo "WGDashboard vendor 部署：${DEPLOY_WGDASHBOARD}"

  requireCommand git
  requireCommand rsync
  requireCommand flock
  acquireLock
  prepareRepo
  runSafetyCheck
  deployPublicFiles
  deployWgdashboard
  restartPanelService

  duration=$(( $(date +%s) - START_TIME ))
  logInfo "同步任务结束，耗时 ${duration}s。"
}

main "$@"
