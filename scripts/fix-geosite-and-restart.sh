#!/usr/bin/env bash
# 修复 /var/lib/mihomo/GeoSite.dat 不完整导致 mihomo 无法启动（需 sudo）
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIHOMO_DIR="/var/lib/mihomo"
MIN_BYTES=1000000

pick_geosite() {
  for src in \
    "${ROOT}/geodata/GeoSite.dat" \
    "${HOME}/.config/mihomo/GeoSite.dat"; do
    if [[ -f "${src}" ]] && [[ "$(stat -c%s "${src}")" -ge "${MIN_BYTES}" ]]; then
      echo "${src}"
      return 0
    fi
  done
  echo "error: no complete GeoSite.dat (>= ${MIN_BYTES} bytes) found" >&2
  echo "hint: cp ~/.config/mihomo/GeoSite.dat ${ROOT}/geodata/" >&2
  exit 1
}

SRC="$(pick_geosite)"
echo "installing GeoSite.dat from ${SRC} ..."
sudo cp -f "${SRC}" "${MIHOMO_DIR}/GeoSite.dat"
sudo chown mihomo:mihomo "${MIHOMO_DIR}/GeoSite.dat"
sudo systemctl restart mihomo
sleep 2
if journalctl -u mihomo -n 5 --no-pager | grep -q "Parse config error\|fatal msg"; then
  journalctl -u mihomo -n 10 --no-pager
  exit 1
fi
echo "mihomo restarted; check: systemctl status mihomo"
