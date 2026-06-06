#!/usr/bin/env bash
set -euo pipefail

KATA_CONFIG_D="/opt/kata/share/defaults/kata-containers/runtimes/qemu-nvidia-gpu/config.d"
DROP_IN="${KATA_CONFIG_D}/100-qemu-trace.toml"
REAL_QEMU="/opt/kata/bin/qemu-system-x86_64"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="${SCRIPT_DIR}/qemu-system-x86_64-trace-wrapper"
TRACE_DIR="${SCRIPT_DIR}/qemu-trace-logs"

if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: please run with sudo/root because Kata config.d is root-owned." >&2
  exit 1
fi

if [[ ! -x "$REAL_QEMU" ]]; then
  echo "ERROR: real QEMU not found or not executable: $REAL_QEMU" >&2
  exit 1
fi

if [[ ! -f "$WRAPPER" ]]; then
  echo "ERROR: wrapper not found: $WRAPPER" >&2
  exit 1
fi

if [[ ! -d "$KATA_CONFIG_D" ]]; then
  echo "ERROR: Kata config.d not found: $KATA_CONFIG_D" >&2
  exit 1
fi

chmod +x "$WRAPPER"
mkdir -p "$TRACE_DIR"

cat > "$DROP_IN" <<EOF
[hypervisor.qemu]
path = "$WRAPPER"
valid_hypervisor_paths = [
  "$REAL_QEMU",
  "$WRAPPER",
]
EOF

echo "Installed Kata QEMU trace drop-in:"
echo "  $DROP_IN"
echo
echo "Restart containerd to apply it:"
echo "  sudo systemctl restart containerd"
