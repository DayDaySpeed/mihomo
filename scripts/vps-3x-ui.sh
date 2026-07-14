#!/usr/bin/env bash
set -euo pipefail

#------------------------------------------------------------------------------
# 3x-ui 一键安装（Ubuntu 24+）
# 节点在面板手动配置；客户端走橙云 + SSL_DOMAIN，不要填 VPS IP
#
#   bash vps-3x-ui.sh                 # 安装 + 签证书（域名 DNS-01 需 CF_TOKEN）
#   bash vps-3x-ui.sh --reconfigure   # 轮换面板端口/路径/密码
#   bash vps-3x-ui.sh --ssl-only      # 仅续签证书
#
# 敏感项：复制 scripts/vps-3x-ui.env.example → vps-3x-ui.env（勿提交），
# 或 export SSL_DOMAIN / SSL_EMAIL / CF_TOKEN 后执行。
#------------------------------------------------------------------------------

readonly INFO_FILE="/root/3x-ui-access.txt"
readonly STATE_FILE="/etc/3x-ui-installer.env"
readonly LOCK_FILE="/var/lock/3x-ui-installer.lock"
readonly INSTALL_URL="https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh"
readonly XUI_BIN="/usr/local/x-ui/x-ui"
readonly TOTAL_STEPS=9

SSL_DOMAIN="${SSL_DOMAIN:-}"
SSL_EMAIL="${SSL_EMAIL:-}"
CF_TOKEN="${CF_TOKEN:-}"

RECONFIGURE=0 FORCE_INSTALL=0 SSL_ONLY=0 SKIP_SSL=0 FORCE_SSL=0
SSL_ISSUED=0 SERVER_IP=""

die() { echo "ERROR: $*" >&2; exit 1; }
step() { echo "[${1}/${TOTAL_STEPS}] ${2}"; }
cert_dir() { echo "/root/cert/${1}"; }

load_env_file() {
  local script_dir f
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  for f in "${script_dir}/vps-3x-ui.env" "/root/vps-3x-ui.env"; do
    if [[ -f "${f}" ]]; then
      # shellcheck disable=SC1090
      source "${f}"
      return 0
    fi
  done
}

restart_xui() {
  systemctl restart x-ui
  sleep 5
}

usage() {
  cat <<'EOF'
Usage: bash vps-3x-ui.sh [options]

  --reconfigure        轮换面板端口/路径/密码
  --force-install      强制重装 3x-ui
  --ssl-only           仅签/更新 Let's Encrypt 证书
  --skip-ssl           跳过证书
  --force-ssl          强制重签证书
  --ssl-domain / --ssl-email / --cf-token
  -h, --help

环境变量（或 vps-3x-ui.env）:
  SSL_DOMAIN   客户端连接域名（橙云）
  SSL_EMAIL    Let's Encrypt 邮箱
  CF_TOKEN     Cloudflare API Token（DNS-01）

3x-ui 安装交互: SSL 选 4（Skip）；Bind 127.0.0.1 选 y
面板: 仅 SSH 隧道；节点在面板里自己加（见 /root/3x-ui-access.txt）

  ssh -N -L 8443:127.0.0.1:<面板端口> root@<VPS>
  浏览器: https://127.0.0.1:8443/<面板路径>/  （有证书后）
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --reconfigure)   RECONFIGURE=1; shift ;;
      --force-install) FORCE_INSTALL=1; shift ;;
      --ssl-only)      SSL_ONLY=1; shift ;;
      --skip-ssl)      SKIP_SSL=1; shift ;;
      --force-ssl)     FORCE_SSL=1; shift ;;
      --ssl-domain|--ssl-email|--cf-token)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        case "$1" in
          --ssl-domain) SSL_DOMAIN="$2" ;;
          --ssl-email)  SSL_EMAIL="$2" ;;
          --cf-token)   CF_TOKEN="$2" ;;
        esac
        shift 2
        ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown option: $1 (try --help)" ;;
    esac
  done
}

require_ssl_config() {
  [[ "${SKIP_SSL}" -eq 1 ]] && return 0
  [[ -n "${SSL_DOMAIN}" && -n "${SSL_EMAIL}" ]] \
    || die "SSL_DOMAIN and SSL_EMAIL required (env, vps-3x-ui.env, or --skip-ssl)"
}

generate_port() {
  local p
  while true; do
    p="$(shuf -i 20000-40000 -n 1)"
    ss -tuln | awk -F: -v port="${p}" '{print $NF}' | grep -qx "${p}" || { echo "${p}"; return; }
  done
}

generate_credentials() {
  if [[ "${RECONFIGURE}" -eq 1 || -z "${PANEL_PORT:-}" ]]; then
    step 3 "Generating panel credentials"
    PANEL_PORT="$(generate_port)"
    PANEL_PATH="$(openssl rand -hex 8)"
    PANEL_USER="admin"
    PANEL_PASS="$(openssl rand -base64 18 | tr -d '\n' | tr '/+' 'ab')"
    return
  fi
  step 3 "Reusing saved panel credentials"
}

enable_bbr() {
  local cfg=/etc/sysctl.d/99-vps-installer.conf
  grep -q 'tcp_congestion_control=bbr' "${cfg}" 2>/dev/null && return 0
  cat > "${cfg}" <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
  sysctl --system >/dev/null 2>&1 || sysctl -p "${cfg}" >/dev/null 2>&1 || true
}

harden_system() {
  apt-get install -y -qq chrony fail2ban 2>/dev/null || true
  systemctl enable chrony fail2ban 2>/dev/null || true
  [[ -f /etc/fail2ban/jail.local ]] && return 0
  cat > /etc/fail2ban/jail.local <<'EOF'
[sshd]
enabled = true
maxretry = 5
bantime = 1h
EOF
  systemctl restart fail2ban 2>/dev/null || true
}

ensure_acme() {
  [[ -x /root/.acme.sh/acme.sh ]] && return 0
  [[ -n "${SSL_EMAIL}" ]] || { echo "[ssl] SSL_EMAIL is empty"; return 1; }
  curl -fsSL https://get.acme.sh | sh -s "email=${SSL_EMAIL}"
  /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt --force >/dev/null
}

cert_valid() {
  local d
  d="$(cert_dir "$1")"
  [[ -f "${d}/fullchain.pem" && -f "${d}/privkey.pem" ]] \
    && openssl x509 -checkend 86400 -noout -in "${d}/fullchain.pem" 2>/dev/null
}

bind_cert() {
  local d
  d="$(cert_dir "$1")"
  "${XUI_BIN}" cert -webCert "${d}/fullchain.pem" -webCertKey "${d}/privkey.pem"
  restart_xui
}

issue_ssl_cert() {
  local domain="${SSL_DOMAIN}" d
  d="$(cert_dir "${domain}")"
  [[ -n "${domain}" && -n "${SSL_EMAIL}" && -x "${XUI_BIN}" ]] \
    || { echo "[ssl] Need SSL_DOMAIN, SSL_EMAIL, x-ui"; return 1; }

  if [[ "${FORCE_SSL}" -eq 0 ]] && cert_valid "${domain}"; then
    echo "[ssl] Reusing cert for ${domain}"
    bind_cert "${domain}"
    return 0
  fi

  ensure_acme || return 1
  mkdir -p "${d}"
  systemctl stop x-ui 2>/dev/null || true

  local ok=0
  if [[ -n "${CF_TOKEN}" ]]; then
    export CF_Token="${CF_TOKEN}"
    /root/.acme.sh/acme.sh --issue --dns dns_cf -d "${domain}" --force && ok=1
  else
    ufw allow 80/tcp >/dev/null 2>&1 || true
    /root/.acme.sh/acme.sh --issue -d "${domain}" --standalone --httpport 80 --force && ok=1
  fi

  if [[ "${ok}" -ne 1 ]]; then
    systemctl start x-ui 2>/dev/null || true
    return 1
  fi

  /root/.acme.sh/acme.sh --install-cert -d "${domain}" \
    --key-file "${d}/privkey.pem" --fullchain-file "${d}/fullchain.pem" \
    --reloadcmd "systemctl restart x-ui"
  chmod 600 "${d}/privkey.pem"
  chmod 644 "${d}/fullchain.pem"
  bind_cert "${domain}"
}

maybe_issue_ssl() {
  if [[ "${SKIP_SSL}" -eq 1 ]]; then
    step 8 "SSL skipped (--skip-ssl)"
    return 0
  fi
  if [[ -z "${SSL_DOMAIN}" || -z "${SSL_EMAIL}" ]]; then
    step 8 "SSL skipped (set SSL_EMAIL)"
    return 0
  fi
  step 8 "Auto SSL for ${SSL_DOMAIN}"
  issue_ssl_cert && SSL_ISSUED=1 \
    || echo "[8/${TOTAL_STEPS}] SSL failed — fix DNS/CF_TOKEN, or add cert in panel"
}

cert_ready() {
  local d
  d="$(cert_dir "${SSL_DOMAIN}")"
  [[ -n "${SSL_DOMAIN}" && -f "${d}/fullchain.pem" && -f "${d}/privkey.pem" ]] \
    && { [[ "${SSL_ISSUED}" -eq 1 ]] || cert_valid "${SSL_DOMAIN}"; }
}

panel_access_scheme() {
  local d
  [[ -n "${SSL_DOMAIN:-}" ]] || { echo http; return; }
  d="$(cert_dir "${SSL_DOMAIN}")"
  [[ -f "${d}/fullchain.pem" && -f "${d}/privkey.pem" ]] && echo https || echo http
}

persist_state() {
  cat > "${STATE_FILE}" <<EOF
PANEL_PORT='${PANEL_PORT}'
PANEL_PATH='${PANEL_PATH}'
PANEL_USER='${PANEL_USER}'
PANEL_PASS='${PANEL_PASS}'
SSL_DOMAIN='${SSL_DOMAIN}'
SSL_EMAIL='${SSL_EMAIL}'
CF_TOKEN='${CF_TOKEN}'
EOF
  chmod 600 "${STATE_FILE}"
}

write_access_info() {
  local scheme=http
  cert_ready && scheme=https

  cat > "${INFO_FILE}" <<EOF
3x-ui — access summary (nodes: configure manually in panel)

Strategy: clients use ${SSL_DOMAIN} behind Cloudflare orange cloud — NOT VPS IP.

--- Cloudflare (do this first) ---
  DNS A/AAAA  ${SSL_DOMAIN} -> ${SERVER_IP}   proxied (orange cloud) ON
  Network -> WebSockets ON
  SSL/TLS -> Full (strict) after origin cert exists

--- Panel (SSH tunnel only) ---
  user: ${PANEL_USER}
  pass: ${PANEL_PASS}
  path: /${PANEL_PATH}
  ssh -N -L 8443:127.0.0.1:${PANEL_PORT} root@${SERVER_IP}
  open: ${scheme}://127.0.0.1:8443/${PANEL_PATH}/

--- Manual inbound (example: VLESS + WebSocket + CDN) ---
  In panel: Inbounds -> Add -> VLESS, port 443, listen 0.0.0.0 or empty
  Transport: WebSocket, path e.g. /ray$(shuf -i 100000-999999 -n 1)
  TLS on panel inbound: OFF (Cloudflare terminates TLS at edge)
  Add client UUID in panel; export QR/link from panel

  Client must use:
    Address:  ${SSL_DOMAIN}     (never ${SERVER_IP})
    Port:     443
    TLS/SNI:  ${SSL_DOMAIN}
    Host:     ${SSL_DOMAIN}
    Network:  ws + your path

Origin cert (for CF Full strict / optional panel):
  domain: ${SSL_DOMAIN}
  files:  $(cert_dir "${SSL_DOMAIN}")/fullchain.pem

VPS IP (DNS only, do not put in client): ${SERVER_IP}

Commands:
  bash vps-3x-ui.sh --reconfigure
  bash vps-3x-ui.sh --ssl-only
EOF
  chmod 600 "${INFO_FILE}"
}

apply_panel_settings() {
  "${XUI_BIN}" setting -username "${PANEL_USER}" -password "${PANEL_PASS}" >/dev/null
  "${XUI_BIN}" setting -port "${PANEL_PORT}" >/dev/null
  "${XUI_BIN}" setting -webBasePath "${PANEL_PATH}" >/dev/null
}

configure_firewall() {
  local old="${OLD_PANEL_PORT:-}"
  ufw allow 22/tcp >/dev/null
  ufw allow 80/tcp >/dev/null
  ufw allow 443/tcp >/dev/null
  echo "  panel :${PANEL_PORT} localhost only (SSH tunnel)"
  [[ -n "${old}" && "${old}" != "${PANEL_PORT}" ]] \
    && ufw delete allow "${old}/tcp" >/dev/null 2>&1 || true
  ufw --force enable >/dev/null
}

#==============================================================================
# 主流程
#==============================================================================

load_env_file
[[ -f "${STATE_FILE}" ]] && source "${STATE_FILE}"
parse_args "$@"
require_ssl_config

[[ "${EUID}" -eq 0 ]] || die "Run as root: sudo bash vps-3x-ui.sh"
[[ "${SSL_ONLY}" -eq 1 ]] && { issue_ssl_cert || exit 1; exit 0; }

exec 9>"${LOCK_FILE}"
flock -n 9 || die "Another installer is running"

step 1 "Dependencies + BBR + hardening"
apt-get update -qq
apt-get install -y -qq curl openssl ufw socat cron chrony fail2ban
enable_bbr
harden_system

if [[ "${FORCE_INSTALL}" -eq 1 || ! -x "${XUI_BIN}" ]]; then
  step 2 "Installing 3x-ui (installer: SSL=4, bind 127.0.0.1=y)"
  bash <(curl -fsSL "${INSTALL_URL}")
else
  step 2 "3x-ui already installed"
fi
[[ -x "${XUI_BIN}" ]] || die "x-ui missing"

OLD_PANEL_PORT="${PANEL_PORT:-}"
generate_credentials

step 4 "Panel settings"
apply_panel_settings

step 5 "Restart x-ui"
systemctl enable x-ui >/dev/null
restart_xui

step 6 "Firewall"
configure_firewall

step 7 "Save state"
SERVER_IP="$(curl -4fsS https://ifconfig.co 2>/dev/null || hostname -I | awk '{print $1}')"
persist_state
write_access_info

maybe_issue_ssl

step 9 "Done — add inbounds in panel"
persist_state
write_access_info

cat <<EOF

==============================================
Nodes: add manually in panel (see ${INFO_FILE})
Client address: ${SSL_DOMAIN} via orange cloud (not VPS IP)
Panel tunnel:   ssh -N -L 8443:127.0.0.1:${PANEL_PORT} root@${SERVER_IP}
Panel URL:      $(panel_access_scheme)://127.0.0.1:8443/${PANEL_PATH}/
==============================================
EOF
