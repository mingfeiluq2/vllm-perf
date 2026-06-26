#!/usr/bin/env bash
set -euo pipefail

KATA_CONFIG_D="${KATA_CONFIG_D:-/opt/kata/share/defaults/kata-containers/runtimes/qemu-nvidia-gpu/config.d}"
DROP_IN="${KATA_CONFIG_D}/100-qemu-gpudirect-clique.toml"

if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: run this script as root because Kata config.d is root-owned" >&2
    exit 1
fi

rm -f "${DROP_IN}"

echo "Removed Kata QEMU GPUDirect clique drop-in:"
echo "  ${DROP_IN}"
echo
echo "Restart containerd and recreate the Kata Pod to apply the removal:"
echo "  sudo systemctl restart containerd"
