#!/bin/bash
set -euo pipefail

# Benchmark Qwen3.5-27B with TP=2, kata vs runc
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BENCH_SCRIPT="${SCRIPT_DIR}/vllm-bench-multi.sh"
RESULT_DIR="${SCRIPT_DIR}/result"
MODEL_27B="/home/liulei/models/Qwen/Qwen3.5-27B"
NAMESPACE="${NAMESPACE:-default}"
OVERALL_TIMESTAMP=$(date -u +%Y%m%dT%H%M%SZ)
FAILED=0

log_info() { echo "[INFO] $(date '+%H:%M:%S') $*"; }
log_fail() { echo "[FAIL] $(date '+%H:%M:%S') $*"; }

delete_pod() {
    local pod="$1"
    kubectl -n "${NAMESPACE}" delete pod "${pod}" --ignore-not-found --wait=true --timeout=60s 2>/dev/null || true
    for i in $(seq 1 30); do
        kubectl -n "${NAMESPACE}" get pod "${pod}" -o name >/dev/null 2>&1 || return 0
        sleep 2
    done
}

get_pod_ip() { kubectl -n "${NAMESPACE}" get pod "$1" -o jsonpath='{.status.podIP}' 2>/dev/null || echo ""; }

wait_pod_running() {
    local pod="$1" to="$2" phase start
    start=$(date +%s.%N)
    while true; do
        phase=$(kubectl -n "${NAMESPACE}" get pod "${pod}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        if [ "${phase}" = "Running" ]; then return 0; fi
        if [ "${phase}" = "Failed" ] || [ "${phase}" = "Succeeded" ]; then return 1; fi
        local now; now=$(date +%s.%N)
        if [ "$(printf '%.0f' "$(echo "${now} - ${start}" | bc)")" -ge "${to}" ]; then return 1; fi
        sleep 5
    done
}

wait_vllm_health() {
    local pod="$1" to="$2" ip="$3" start
    local url="http://${ip}:8000/health"
    start=$(date +%s.%N)
    while true; do
        if curl --noproxy '*' -s --fail --max-time 3 "${url}" >/dev/null 2>&1; then return 0; fi
        local now; now=$(date +%s.%N)
        if [ "$(printf '%.0f' "$(echo "${now} - ${start}" | bc)")" -ge "${to}" ]; then return 1; fi
        sleep 10
    done
}

write_metadata() {
    local dir="$1" rt="$2" tp="$3"
    mkdir -p "${dir}"
    cat > "${dir}/metadata.txt" <<EOF
test_type=vllm-bench
runtime=${rt}
model=27B
tensor_parallel=${tp}
gpu_count=${tp}
timestamp_utc=${OVERALL_TIMESTAMP}
pod_name=gpu-pod-${rt}
namespace=${NAMESPACE}
node=server
EOF
}

run_bench() {
    local runtime="$1"
    local template gr pn

    if [ "${runtime}" = "kata" ]; then
        template="${REPO_DIR}/gpu-pod-kata.yaml"
        gr="nvidia.com/pgpu"
        pn="gpu-pod-kata"
    else
        template="${REPO_DIR}/gpu-pod-runc.yaml"
        gr="nvidia.com/gpu"
        pn="gpu-pod-runc"
    fi

    local label="[TP=2] ${runtime} / 27B"
    local tp="2"

    echo ""
    echo "=============================================="
    echo "  ${label}"
    echo "=============================================="

    delete_pod "${pn}"

    # Generate temp YAML
    local yf; yf=$(mktemp /tmp/gpu-pod-XXXXXX.yaml)
    cp "${template}" "${yf}"
    sed -i "s|/home/liulei/models/Qwen/Qwen3.5-0.8B|${MODEL_27B}|g" "${yf}"
    sed -i "s|/home/liulei/models/Qwen/Qwen3___5-9B|${MODEL_27B}|g" "${yf}" 2>/dev/null || true
    sed -i "s/^    name: gpu-pod-.*/    name: ${pn}/" "${yf}"
    sed -i "s/--tensor-parallel-size [0-9]/--tensor-parallel-size ${tp}/" "${yf}"
    sed -i "s|\(${gr}\): [0-9]*|\1: ${tp}|g" "${yf}"

    # Keep memory at original values (56Gi for kata, 64Gi for runc) to avoid OOM
    log_info "Temp YAML: ${yf}"

    if ! kubectl -n "${NAMESPACE}" apply -f "${yf}" 2>&1; then
        log_fail "${label}: kubectl apply failed"
        rm -f "${yf}"; FAILED=$((FAILED + 1)); return 1
    fi

    # Wait for pod running (longer timeout for kata VM creation)
    if ! wait_pod_running "${pn}" 600; then
        log_fail "${label}: pod not running"
        kubectl -n "${NAMESPACE}" describe pod "${pn}" 2>/dev/null | tail -20
        delete_pod "${pn}"; rm -f "${yf}"; FAILED=$((FAILED + 1)); return 1
    fi

    local ip; ip=$(get_pod_ip "${pn}")
    if [ -z "${ip}" ]; then
        log_fail "${label}: no IP"; delete_pod "${pn}"; rm -f "${yf}"
        FAILED=$((FAILED + 1)); return 1
    fi
    log_info "Pod IP: ${ip}"

    # 27B model takes longer to load - 30 min timeout
    if ! wait_vllm_health "${pn}" 1800 "${ip}"; then
        log_fail "${label}: vLLM health timeout"
        kubectl -n "${NAMESPACE}" logs "${pn}" --tail=50 2>/dev/null || true
        delete_pod "${pn}"; rm -f "${yf}"; FAILED=$((FAILED + 1)); return 1
    fi

    # Save startup log
    local rdir="${RESULT_DIR}/tp2-2gpu-27b/${runtime}"
    mkdir -p "${rdir}"
    kubectl -n "${NAMESPACE}" logs "${pn}" --timestamps > "${rdir}/vllm_startup.log" 2>&1 || true
    write_metadata "${rdir}" "${runtime}" "${tp}"
    log_info "Startup log saved: ${rdir}/vllm_startup.log ($(wc -l < "${rdir}/vllm_startup.log") lines)"

    # Run benchmark
    export POD_NAME="${pn}"
    export POD_NAMESPACE="${NAMESPACE}"
    export BENCH_TOKENIZER="${MODEL_27B}/"
    export CONCURRENCY_LEVELS="1 2 4 8"  # Reduced due to 27B model memory pressure

    log_info "Running vllm-bench-multi.sh (concurrency: 1 2 4 8)..."
    set +e
    bash "${BENCH_SCRIPT}" 2>&1
    local bs=$?
    set -e

    if [ "${bs}" -eq 0 ]; then
        log_info "Benchmark PASS"
    else
        log_fail "Benchmark FAIL (exit=${bs})"
        FAILED=$((FAILED + 1))
    fi

    # Copy results
    local bd; bd=$(ls -td "${SCRIPT_DIR}/perf-logs/pod-bench_${NAMESPACE}_${pn}_"* 2>/dev/null | head -1)
    if [ -n "${bd}" ] && [ -d "${bd}" ]; then
        cp -a "${bd}" "${rdir}/benchmark/" 2>/dev/null || true
        log_info "Results: ${rdir}/benchmark/"
    fi

    rm -f "${yf}"
    delete_pod "${pn}"
}

echo "=============================================="
echo "  Qwen3.5-27B TP=2 Benchmark"
echo "  Started: $(date)"
echo "=============================================="

# Run kata first, then runc
run_bench "kata"
run_bench "runc"

echo ""
echo "=============================================="
echo "  27B TP=2 Complete"
echo "=============================================="
echo "  Failed: ${FAILED}"
echo "  Results: ${RESULT_DIR}/tp2-2gpu-27b/"
echo "  Finished at $(date)"
exit ${FAILED}
