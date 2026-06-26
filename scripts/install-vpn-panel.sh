#!/usr/bin/env bash
set -euo pipefail

APP_DIR="${APP_DIR:-/opt/chinavpn-public-site}"
ENV_FILE="${ENV_FILE:-/etc/chinavpn-panel.env}"
SERVICE_FILE="/etc/systemd/system/chinavpn-panel.service"
NGINX_SITE="/www/server/panel/vhost/nginx/chinavpn.mikezhuang.cn.conf"
PANEL_PORT="${PANEL_PORT:-18443}"
SSL_CERT="${SSL_CERT:-/etc/letsencrypt/live/chinavpn.mikezhuang.cn/fullchain.pem}"
SSL_KEY="${SSL_KEY:-/etc/letsencrypt/live/chinavpn.mikezhuang.cn/privkey.pem}"

requireRoot() {
  if [[ "${EUID}" -ne 0 ]]; then
    printf '请使用 root 执行。\n' >&2
    exit 1
  fi
}

requireEnv() {
  if [[ ! -f "$ENV_FILE" ]]; then
    printf '缺少环境文件：%s\n' "$ENV_FILE" >&2
    exit 1
  fi
}

installService() {
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=ChinaVPN public management panel
After=network-online.target wg-quick@wg0.service
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${APP_DIR}
EnvironmentFile=${ENV_FILE}
ExecStart=/usr/bin/python3 -m uvicorn app.vpn_panel:app --host 127.0.0.1 --port ${PANEL_PORT}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable chinavpn-panel
  systemctl restart chinavpn-panel
}

installNginx() {
  local backupPath="${NGINX_SITE}.bak.$(date +%F-%H%M%S)"
  if [[ -f "$NGINX_SITE" ]]; then
    cp "$NGINX_SITE" "$backupPath"
  fi
  if [[ -f "$SSL_CERT" && -f "$SSL_KEY" ]]; then
    cat > "$NGINX_SITE" <<EOF
server {
    listen 80;
    server_name chinavpn.mikezhuang.cn;

    location ^~ /.well-known/acme-challenge/ {
        root /www/wwwroot/chinavpn.mikezhuang.cn;
        try_files \$uri =404;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }

    access_log /www/wwwlogs/chinavpn.mikezhuang.cn.log;
    error_log /www/wwwlogs/chinavpn.mikezhuang.cn.error.log;
}

server {
    listen 443 ssl http2;
    server_name chinavpn.mikezhuang.cn;

    ssl_certificate ${SSL_CERT};
    ssl_certificate_key ${SSL_KEY};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;

    location / {
        proxy_pass http://127.0.0.1:${PANEL_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 60s;
    }

    access_log /www/wwwlogs/chinavpn.mikezhuang.cn.log;
    error_log /www/wwwlogs/chinavpn.mikezhuang.cn.error.log;
}
EOF
  else
    cat > "$NGINX_SITE" <<EOF
server {
    listen 80;
    server_name chinavpn.mikezhuang.cn;

    location ^~ /.well-known/acme-challenge/ {
        root /www/wwwroot/chinavpn.mikezhuang.cn;
        try_files \$uri =404;
    }

    location / {
        proxy_pass http://127.0.0.1:${PANEL_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 60s;
    }

    access_log /www/wwwlogs/chinavpn.mikezhuang.cn.log;
    error_log /www/wwwlogs/chinavpn.mikezhuang.cn.error.log;
}
EOF
  fi
  nginx -t
  nginx -s reload
}

main() {
  requireRoot
  requireEnv
  installService
  installNginx
  systemctl --no-pager --full status chinavpn-panel
}

main "$@"
