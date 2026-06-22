#!/usr/bin/env bash
# Ubuntu 24.04: Postfix 邮件中转（本机客户端 → VPS:587 → smtp.gmail.com）
# 在 VPS 上以 root 运行:
#   RELAY_USER=relay RELAY_PASS='你的中继密码' \
#   GMAIL_USER='you@gmail.com' GMAIL_APP_PASS='Google应用专用密码' \
#   bash vps-smtp-relay.sh
set -euo pipefail

RELAY_USER="${RELAY_USER:-}"
RELAY_PASS="${RELAY_PASS:-}"
GMAIL_USER="${GMAIL_USER:-}"
GMAIL_APP_PASS="${GMAIL_APP_PASS:-}"
RELAY_MODE="${RELAY_MODE:-gmail}"   # gmail | direct
SUBMISSION_PORT="${SUBMISSION_PORT:-587}"

if [[ "${EUID}" -ne 0 ]]; then
  echo "error: run as root" >&2
  exit 1
fi

if [[ -z "${RELAY_USER}" || -z "${RELAY_PASS}" ]]; then
  cat >&2 <<'EOF'
error: missing RELAY_USER / RELAY_PASS

用法（必须一行，或先 export）:
  RELAY_USER=relay RELAY_PASS='xxx' GMAIL_USER='a@gmail.com' GMAIL_APP_PASS='yyy' bash vps-smtp-relay.sh

或:
  export RELAY_USER=relay RELAY_PASS='xxx' GMAIL_USER='a@gmail.com' GMAIL_APP_PASS='yyy'
  bash vps-smtp-relay.sh
EOF
  exit 1
fi

if [[ "${RELAY_MODE}" == "gmail" && ( -z "${GMAIL_USER}" || -z "${GMAIL_APP_PASS}" ) ]]; then
  echo "error: gmail mode requires GMAIL_USER and GMAIL_APP_PASS (Google 应用专用密码)" >&2
  exit 1
fi

VPS_IP="$(hostname -I | awk '{print $1}')"
HOSTNAME_FQDN="$(hostname -f 2>/dev/null || hostname)"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq postfix libsasl2-modules libsasl2-modules-db sasl2-bin openssl ufw

mkdir -p /etc/ssl/postfix
if [[ ! -f /etc/ssl/postfix/smtp.key ]]; then
  openssl req -new -x509 -days 3650 -nodes \
    -out /etc/ssl/postfix/smtp.crt \
    -keyout /etc/ssl/postfix/smtp.key \
    -subj "/CN=${VPS_IP}"
  chmod 600 /etc/ssl/postfix/smtp.key
fi

# 客户端登录 VPS 用的账号（sasldb，realm = VPS IP）
saslpasswd2 -d -u "${VPS_IP}" "${RELAY_USER}" 2>/dev/null || true
echo "${RELAY_PASS}" | saslpasswd2 -p -c -u "${VPS_IP}" "${RELAY_USER}"
chown postfix:postfix /etc/sasldb2
chmod 660 /etc/sasldb2

mkdir -p /etc/postfix/sasl
cat > /etc/postfix/sasl/smtpd.conf <<'EOF'
pwcheck_method: auxprop
auxprop_plugin: sasldb
mech_list: PLAIN LOGIN
EOF

postconf -e "myhostname = ${HOSTNAME_FQDN}"
postconf -e "myorigin = /etc/mailname"
postconf -e "inet_interfaces = all"
postconf -e "inet_protocols = ipv4"
postconf -e "smtpd_tls_cert_file = /etc/ssl/postfix/smtp.crt"
postconf -e "smtpd_tls_key_file = /etc/ssl/postfix/smtp.key"
postconf -e "smtpd_tls_security_level = may"
postconf -e "smtpd_sasl_auth_enable = yes"
postconf -e "smtpd_sasl_type = cyrus"
postconf -e "smtpd_sasl_path = smtpd"
postconf -e "smtpd_sasl_security_options = noanonymous"
postconf -e "smtpd_sasl_local_domain = ${VPS_IP}"
postconf -e "broken_sasl_auth_clients = yes"
postconf -e "smtpd_relay_restrictions = permit_sasl_authenticated,reject_unauth_destination"
postconf -e "smtpd_recipient_restrictions = permit_sasl_authenticated,reject_unauth_destination"

if [[ "${RELAY_MODE}" == "gmail" ]]; then
  postconf -e "relayhost = [smtp.gmail.com]:587"
  postconf -e "smtp_sasl_auth_enable = yes"
  postconf -e "smtp_sasl_security_options = noanonymous"
  postconf -e "smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd"
  postconf -e "smtp_use_tls = yes"
  postconf -e "smtp_tls_security_level = encrypt"
  postconf -e "smtp_tls_CAfile = /etc/ssl/certs/ca-certificates.crt"
  printf '%s\n' "[smtp.gmail.com]:587 ${GMAIL_USER}:${GMAIL_APP_PASS}" > /etc/postfix/sasl_passwd
  chmod 600 /etc/postfix/sasl_passwd
  postmap /etc/postfix/sasl_passwd
else
  postconf -X relayhost 2>/dev/null || true
fi

# 启用 submission（587），显式传入 SASL realm
python3 - "${VPS_IP}" <<'PY'
import re, sys
from pathlib import Path
vps_ip = sys.argv[1]
block = f"""submission inet n       -       n       -       -       smtpd
  -o syslog_name=postfix/submission
  -o smtpd_tls_security_level=encrypt
  -o smtpd_sasl_auth_enable=yes
  -o smtpd_sasl_type=cyrus
  -o smtpd_sasl_path=smtpd
  -o smtpd_sasl_local_domain={vps_ip}
  -o smtpd_relay_restrictions=permit_sasl_authenticated,reject
  -o milter_macro_daemon_name=ORIGINATING
"""
path = Path("/etc/postfix/master.cf")
text = path.read_text()
if re.search(r"^submission inet", text, re.M):
    text = re.sub(r"^submission inet.*?(?=\n\S|\Z)", block.strip(), text, count=1, flags=re.S | re.M)
else:
    text = text.rstrip() + "\n\n" + block
path.write_text(text)
PY

echo "sasldb users: $(sasldblistusers2 -f /etc/sasldb2 2>/dev/null || echo '(empty)')"

systemctl enable postfix
systemctl restart postfix

ufw allow "${SUBMISSION_PORT}/tcp" 2>/dev/null || true
ufw allow OpenSSH 2>/dev/null || true
ufw --force enable 2>/dev/null || true

echo ""
echo "============================================"
echo " Postfix relay ready on ${VPS_IP}:${SUBMISSION_PORT}"
echo "============================================"
echo ""
echo "邮件客户端配置:"
echo "  SMTP 服务器: ${VPS_IP}"
echo "  端口:        ${SUBMISSION_PORT}"
echo "  加密:        STARTTLS（接受自签证书）"
echo "  用户名:      ${RELAY_USER}"
echo "  密码:        (你设置的 RELAY_PASS)"
if [[ "${RELAY_MODE}" == "gmail" ]]; then
  echo "  发件身份:    ${GMAIL_USER}（经 VPS 转发到 Gmail）"
fi
echo ""
echo "自测（在 VPS 上）:"
echo "  apt-get install -y swaks"
echo "  swaks --to test@gmail.com --from ${GMAIL_USER:-${RELAY_USER}@localhost} \\"
echo "    --server 127.0.0.1 --port ${SUBMISSION_PORT} --tls \\"
echo "    --auth LOGIN --auth-user ${RELAY_USER} --auth-password '<RELAY_PASS>' \\"
echo "    --header 'Subject: relay test'"
echo ""
