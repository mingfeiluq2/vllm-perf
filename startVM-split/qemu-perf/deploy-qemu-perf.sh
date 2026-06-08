#!/usr/bin/env bash
set -euo pipefail

KATA_CONFIG_D="/opt/kata/share/defaults/kata-containers/runtimes/qemu-nvidia-gpu/config.d"
DROP_IN="${KATA_CONFIG_D}/100-qemu-perf.toml"
OBSERVE_DROP_IN="${KATA_CONFIG_D}/100-qemu-observe.toml"
STRACE_DROP_IN="${KATA_CONFIG_D}/100-qemu-strace.toml"
TRACE_DROP_IN="${KATA_CONFIG_D}/100-qemu-trace.toml"
REAL_QEMU="/usr/bin/qemu-system-x86_64"
PERF="/usr/bin/perf"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="${SCRIPT_DIR}/qemu-system-x86_64-perf-wrapper"
MODE_FILE="${SCRIPT_DIR}/qemu-perf-mode"
STAT_EVENTS_FILE="${SCRIPT_DIR}/qemu-perf-stat-events"
RECORD_EVENT_FILE="${SCRIPT_DIR}/qemu-perf-record-event"
LOG_DIR="${SCRIPT_DIR}/qemu-perf-logs"

if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: please run with sudo/root because Kata config.d is root-owned." >&2
  exit 1
fi

if [[ ! -x "$REAL_QEMU" ]]; then
  echo "ERROR: real QEMU not found or not executable: $REAL_QEMU" >&2
  exit 1
fi

if [[ ! -x "$PERF" ]]; then
  echo "ERROR: perf not found or not executable: $PERF" >&2
  exit 1
fi

if [[ ! -f "$WRAPPER" ]]; then
  echo "ERROR: wrapper not found: $WRAPPER" >&2
  exit 1
fi

for config_file in "$MODE_FILE" "$STAT_EVENTS_FILE" "$RECORD_EVENT_FILE"; do
  if [[ ! -f "$config_file" ]]; then
    echo "ERROR: config file not found: $config_file" >&2
    exit 1
  fi
done

if [[ ! -d "$KATA_CONFIG_D" ]]; then
  echo "ERROR: Kata config.d not found: $KATA_CONFIG_D" >&2
  exit 1
fi

chmod +x "$WRAPPER"
mkdir -p "$LOG_DIR"
rm -f "$OBSERVE_DROP_IN" "$STRACE_DROP_IN" "$TRACE_DROP_IN"

cat > "$DROP_IN" <<EOF
[hypervisor.qemu]
path = "$WRAPPER"
valid_hypervisor_paths = [
  "$REAL_QEMU",
  "$WRAPPER",
]
EOF

echo "Installed Kata QEMU perf drop-in:"
echo "  $DROP_IN"
echo
echo "Removed conflicting QEMU observe/strace/trace drop-ins if they existed:"
echo "  $OBSERVE_DROP_IN"
echo "  $STRACE_DROP_IN"
echo "  $TRACE_DROP_IN"
echo
echo "Restart containerd to apply it:"
echo "  sudo systemctl restart containerd"
