#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_LOG_DIR="${SCRIPT_DIR}/qemu-strace-logs"
PATTERN='(/dev/vfio|anon_inode:\[vfio-device\]|kvm-vfio|VFIO_|vfio|IOMMU_)'

if [[ "$#" -eq 0 ]]; then
  set -- "$DEFAULT_LOG_DIR"
fi

if command -v rg >/dev/null 2>&1; then
  exec rg --no-heading --line-number --with-filename --ignore-case "$PATTERN" "$@"
fi

exec grep -RInE "$PATTERN" "$@"
