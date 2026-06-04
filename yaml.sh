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

python3 "${ROOT}/merge_config.py" "${SRC}" "${SECRETS}" "${MERGED}"

sudo cp /etc/mihomo/ssrdog.yaml "${ROOT}/backup_ssrdog.yaml" 2>/dev/null || true
sudo cp "${MERGED}" /etc/mihomo/ssrdog.yaml

# mihomo uses -d /var/lib/mihomo, so ./ruleset resolves there.
sudo rm -rf /var/lib/mihomo/ruleset
sudo mkdir -p /var/lib/mihomo/ruleset
sudo cp -f "${ROOT}/ruleset/"*.yml /var/lib/mihomo/ruleset/

sudo chown mihomo:mihomo /etc/mihomo/ssrdog.yaml
sudo chown -R mihomo:mihomo /var/lib/mihomo/ruleset
sudo systemctl restart mihomo

cp "${MERGED}" "${ROOT}/ssrdog.yaml"
rm -f "${MERGED}"

echo "deployed: /etc/mihomo/ssrdog.yaml (merged from ssrdog.src.yaml + secrets.yaml)"
