#!/usr/bin/env bash
set -euo pipefail

DROP_IN="/opt/kata/share/defaults/kata-containers/runtimes/qemu-nvidia-gpu/config.d/100-qemu-observe.toml"

if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: please run with sudo/root because Kata config.d is root-owned." >&2
  exit 1
fi

rm -f "$DROP_IN"

echo "Removed Kata QEMU observe drop-in:"
echo "  $DROP_IN"
echo
echo "Restart containerd to apply it:"
echo "  sudo systemctl restart containerd"
