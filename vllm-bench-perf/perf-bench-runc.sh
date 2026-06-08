#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

RUNTIME_NAME="runc"
DEFAULT_POD_YAML="${REPO_ROOT}/gpu-pod-runc.yaml"
POD_NAME="gpu-pod-runc"
PERF_MODE_FILE="${SCRIPT_DIR}/perf-bench-runc-mode"
PERF_STAT_EVENTS_FILE="${SCRIPT_DIR}/perf-bench-runc-stat-events"
PERF_RECORD_EVENT_FILE="${SCRIPT_DIR}/perf-bench-runc-record-event"
BENCH_CONFIG_FILE="${BENCH_CONFIG_FILE:-${SCRIPT_DIR}/perf-bench-runc-bench-config}"

source "${SCRIPT_DIR}/perf-bench-common.sh"
