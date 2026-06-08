#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

RUNTIME_NAME="kata"
DEFAULT_POD_YAML="${REPO_ROOT}/gpu-pod-kata.yaml"
POD_NAME="gpu-pod-kata"
PERF_MODE_FILE="${SCRIPT_DIR}/perf-bench-kata-mode"
PERF_STAT_EVENTS_FILE="${SCRIPT_DIR}/perf-bench-kata-stat-events"
PERF_RECORD_EVENT_FILE="${SCRIPT_DIR}/perf-bench-kata-record-event"
BENCH_CONFIG_FILE="${BENCH_CONFIG_FILE:-${SCRIPT_DIR}/perf-bench-kata-bench-config}"

source "${SCRIPT_DIR}/perf-bench-common.sh"
