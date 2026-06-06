#!/usr/bin/env bash
set -euo pipefail

KATA_CONFIG_D="/opt/kata/share/defaults/kata-containers/runtimes/qemu-nvidia-gpu/config.d"
DROP_IN="${KATA_CONFIG_D}/100-qemu-observe.toml"
STRACE_DROP_IN="${KATA_CONFIG_D}/100-qemu-strace.toml"
TRACE_DROP_IN="${KATA_CONFIG_D}/100-qemu-trace.toml"
# REAL_QEMU="/opt/kata/bin/qemu-system-x86_64"
REAL_QEMU="/usr/bin/qemu-system-x86_64"
STRACE="/usr/bin/strace"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="${SCRIPT_DIR}/qemu-system-x86_64-observe-wrapper"
STRACE_FILTER_FILE="${SCRIPT_DIR}/qemu-strace-filter"
TRACE_EVENTS="${SCRIPT_DIR}/qemu-trace-events"
LOG_DIR="${SCRIPT_DIR}/qemu-observe-logs"

if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: please run with sudo/root because Kata config.d is root-owned." >&2
  exit 1
fi

if [[ ! -x "$REAL_QEMU" ]]; then
  echo "ERROR: real QEMU not found or not executable: $REAL_QEMU" >&2
  exit 1
fi

if [[ ! -x "$STRACE" ]]; then
  echo "ERROR: strace not found or not executable: $STRACE" >&2
  exit 1
fi

if [[ ! -f "$WRAPPER" ]]; then
  echo "ERROR: wrapper not found: $WRAPPER" >&2
  exit 1
fi

if [[ ! -f "$STRACE_FILTER_FILE" ]]; then
  echo "ERROR: strace filter file not found: $STRACE_FILTER_FILE" >&2
  exit 1
fi

if [[ ! -f "$TRACE_EVENTS" ]]; then
  echo "ERROR: QEMU trace events file not found: $TRACE_EVENTS" >&2
  exit 1
fi

if [[ ! -d "$KATA_CONFIG_D" ]]; then
  echo "ERROR: Kata config.d not found: $KATA_CONFIG_D" >&2
  exit 1
fi

chmod +x "$WRAPPER"
mkdir -p "$LOG_DIR"
rm -f "$STRACE_DROP_IN" "$TRACE_DROP_IN"

cat > "$DROP_IN" <<EOF
[hypervisor.qemu]
path = "$WRAPPER"
valid_hypervisor_paths = [
  "$REAL_QEMU",
  "$WRAPPER",
]
EOF

echo "Installed Kata QEMU observe drop-in:"
echo "  $DROP_IN"
echo
echo "Removed conflicting QEMU strace/trace drop-ins if they existed:"
echo "  $STRACE_DROP_IN"
echo "  $TRACE_DROP_IN"
echo
echo "Restart containerd to apply it:"
echo "  sudo systemctl restart containerd"
