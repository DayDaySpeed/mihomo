#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${ROOT}/ssrdog.src.yaml"
SECRETS="${ROOT}/secrets.yaml"
MERGED="${ROOT}/ssrdog.merged.yaml"
CHINAMAX="${ROOT}/ruleset/ChinaMax.yml"
CHINAMAX_URL="https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/ChinaMax/ChinaMax_Classical.yaml"

if [[ ! -f "${SRC}" ]]; then
  echo "error: base config not found: ${SRC}" >&2
  exit 1
fi

if [[ ! -f "${SECRETS}" ]]; then
  echo "error: secrets file not found: ${SECRETS}" >&2
  echo "hint: cp secrets.yaml.example secrets.yaml" >&2
  exit 1
fi

if [[ ! -f "${CHINAMAX}" ]] || [[ "${UPDATE_CHINAMAX:-}" == "1" ]]; then
  echo "fetching ChinaMax.yml ..."
  curl -fsSL -o "${CHINAMAX}.tmp" "${CHINAMAX_URL}"
  mv "${CHINAMAX}.tmp" "${CHINAMAX}"
fi

VENV_PY="${ROOT}/.venv/bin/python3"
if [[ ! -x "${VENV_PY}" ]]; then
  echo "creating venv and installing dependencies ..."
  python3 -m venv "${ROOT}/.venv"
  "${ROOT}/.venv/bin/pip" install -r "${ROOT}/requirements.txt"
fi

# 上次 sudo 中断可能留下 root 属主的 merged 文件
if [[ -f "${MERGED}" && ! -w "${MERGED}" ]]; then
  sudo rm -f "${MERGED}"
fi

"${VENV_PY}" "${ROOT}/merge_config.py" "${SRC}" "${SECRETS}" "${MERGED}"

sudo cp /etc/mihomo/ssrdog.yaml "${ROOT}/backup_ssrdog.yaml" 2>/dev/null || true
sudo cp "${MERGED}" /etc/mihomo/ssrdog.yaml

# mihomo uses -d /var/lib/mihomo, so ./ruleset resolves there.
sudo rm -rf /var/lib/mihomo/ruleset
sudo mkdir -p /var/lib/mihomo/ruleset
sudo cp -f "${ROOT}/ruleset/"*.yml /var/lib/mihomo/ruleset/

# geosite:cn 依赖 GeoSite.dat；GitHub 自动下载常超时，优先从本地复制完整文件
MIHOMO_DIR="/var/lib/mihomo"
GEOSITE_MIN_BYTES=1000000
install_geosite() {
  local src="$1"
  if [[ -f "${src}" ]] && [[ "$(stat -c%s "${src}")" -ge "${GEOSITE_MIN_BYTES}" ]]; then
    sudo cp -f "${src}" "${MIHOMO_DIR}/GeoSite.dat"
    sudo chown mihomo:mihomo "${MIHOMO_DIR}/GeoSite.dat"
    echo "installed GeoSite.dat from ${src}"
    return 0
  fi
  return 1
}
if [[ ! -f "${MIHOMO_DIR}/GeoSite.dat" ]] || [[ "$(stat -c%s "${MIHOMO_DIR}/GeoSite.dat" 2>/dev/null || echo 0)" -lt "${GEOSITE_MIN_BYTES}" ]]; then
  install_geosite "${HOME}/.config/mihomo/GeoSite.dat" \
    || install_geosite "${ROOT}/geodata/GeoSite.dat" \
    || echo "warning: GeoSite.dat missing or incomplete; mihomo may fail on geosite:cn rules" >&2
fi

sudo chown mihomo:mihomo /etc/mihomo/ssrdog.yaml
sudo chown -R mihomo:mihomo /var/lib/mihomo/ruleset
sudo systemctl restart mihomo

# 系统 DNS 走 Mihomo（1053），否则 resolved 会返回 AAAA 绕过 fake-ip
sudo mkdir -p /etc/systemd/resolved.conf.d
sudo tee /etc/systemd/resolved.conf.d/mihomo-dns.conf >/dev/null <<'EOF'
[Resolve]
DNS=127.0.0.1:1053
FallbackDNS=
DNSOverTLS=no
DNSSEC=no
EOF
sudo systemctl restart systemd-resolved 2>/dev/null || true
sudo resolvectl flush-caches 2>/dev/null || true

cp "${MERGED}" "${ROOT}/ssrdog.yaml"
rm -f "${MERGED}" 2>/dev/null || sudo rm -f "${MERGED}"

echo "deployed: /etc/mihomo/ssrdog.yaml (merged from ssrdog.src.yaml + secrets.yaml)"
