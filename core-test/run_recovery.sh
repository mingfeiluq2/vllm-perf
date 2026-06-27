#!/bin/bash
set -euo pipefail

# Recovery: run only remaining tests after initial partial run.
# Completed:  Task 2 kata/0.8B TP=2, kata/9B TP=2
# Remaining:  Task 2 runc/0.8B TP=2, runc/9B TP=2
#             Task 3 all 4 combos

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BENCH_SCRIPT="${SCRIPT_DIR}/vllm-bench-multi.sh"
RESULT_DIR="${SCRIPT_DIR}/result"
MODEL_08B="/home/liulei/models/Qwen/Qwen3.5-0.8B"
MODEL_9B="/home/liulei/models/Qwen/Qwen3___5-9B"
GPU_POD_KATA="${REPO_DIR}/gpu-pod-kata.yaml"
GPU_POD_RUNC="${REPO_DIR}/gpu-pod-runc.yaml"
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

get_pod_ip() {
    kubectl -n "${NAMESPACE}" get pod "$1" -o jsonpath='{.status.podIP}' 2>/dev/null || echo ""
}

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
        sleep 5
    done
}

gen_yaml() {
    local src="$1" mp="$2" tp="$3" pn="$4" gr="$5" f
    f=$(mktemp /tmp/gpu-pod-XXXXXX.yaml)
    cp "${src}" "${f}"
    sed -i "s|/home/liulei/models/Qwen/Qwen3.5-0.8B|${mp}|g" "${f}"
    sed -i "s|/home/liulei/models/Qwen/Qwen3___5-9B|${mp}|g" "${f}" 2>/dev/null || true
    sed -i "s/^    name: gpu-pod-.*/    name: ${pn}/" "${f}"
    sed -i "s/--tensor-parallel-size [0-9]/--tensor-parallel-size ${tp}/" "${f}"
    sed -i "s|\(${gr}\): [0-9]*|\1: ${tp}|g" "${f}"
    if [ "${tp}" = "1" ]; then
        sed -i 's/cpu: "16"/cpu: "8"/' "${f}"
        sed -i 's/memory: "[0-9]*Gi"/memory: "32Gi"/' "${f}"
    fi
    echo "${f}"
}

write_metadata() {
    local dir="$1" rt="$2" md="$3" tp="$4"
    mkdir -p "${dir}"
    cat > "${dir}/metadata.txt" <<EOF
test_type=vllm-bench
runtime=${rt}
model=${md}
tensor_parallel=${tp}
gpu_count=${tp}
timestamp_utc=${OVERALL_TIMESTAMP}
pod_name=gpu-pod-${rt}
namespace=${NAMESPACE}
node=server
EOF
}

run_bench() {
    local runtime="$1" model="$2" tp="$3"
    local mp ml gr st

    if [ "${model}" = "9b" ]; then
        mp="${MODEL_9B}"; ml="9B"
    else
        mp="${MODEL_08B}"; ml="0.8B"
    fi

    if [ "${runtime}" = "kata" ]; then
        gr="nvidia.com/pgpu"; st="${GPU_POD_KATA}"
    else
        gr="nvidia.com/gpu"; st="${GPU_POD_RUNC}"
    fi

    local pod_name="gpu-pod-${runtime}"
    local label="[TP=${tp}] ${runtime} / ${ml}"

    echo ""
    echo "=============================================="
    echo "  ${label}"
    echo "=============================================="

    delete_pod "${pod_name}"

    local yf
    yf=$(gen_yaml "${st}" "${mp}" "${tp}" "${pod_name}" "${gr}")
    log_info "Temp YAML: ${yf}"

    if ! kubectl -n "${NAMESPACE}" apply -f "${yf}" 2>&1; then
        log_fail "${label}: kubectl apply failed"
        rm -f "${yf}"; FAILED=$((FAILED + 1)); return 1
    fi

    if ! wait_pod_running "${pod_name}" 600; then
        log_fail "${label}: pod not running"
        kubectl -n "${NAMESPACE}" describe pod "${pod_name}" 2>/dev/null || true
        delete_pod "${pod_name}"; rm -f "${yf}"; FAILED=$((FAILED + 1)); return 1
    fi

    local ip
    ip=$(get_pod_ip "${pod_name}")
    if [ -z "${ip}" ]; then
        log_fail "${label}: no IP"; delete_pod "${pod_name}"; rm -f "${yf}"
        FAILED=$((FAILED + 1)); return 1
    fi
    log_info "Pod IP: ${ip}"

    if ! wait_vllm_health "${pod_name}" 1200 "${ip}"; then
        log_fail "${label}: vLLM health timeout"
        kubectl -n "${NAMESPACE}" logs "${pod_name}" --tail=30 2>/dev/null || true
        delete_pod "${pod_name}"; rm -f "${yf}"; FAILED=$((FAILED + 1)); return 1
    fi

    local rdir="${RESULT_DIR}/tp${tp}-${tp}gpu-${model}/${runtime}"
    mkdir -p "${rdir}"
    kubectl -n "${NAMESPACE}" logs "${pod_name}" --timestamps > "${rdir}/vllm_startup.log" 2>&1 || true
    write_metadata "${rdir}" "${runtime}" "${ml}" "${tp}"
    log_info "Startup log saved: ${rdir}/vllm_startup.log (lines: $(wc -l < "${rdir}/vllm_startup.log"))"

    export POD_NAME="${pod_name}"
    export POD_NAMESPACE="${NAMESPACE}"
    export BENCH_TOKENIZER="${mp}/"

    log_info "Running vllm-bench-multi.sh..."
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

    local bd
    bd=$(ls -td "${SCRIPT_DIR}/perf-logs/pod-bench_${NAMESPACE}_${pod_name}_"* 2>/dev/null | head -1)
    if [ -n "${bd}" ] && [ -d "${bd}" ]; then
        cp -a "${bd}" "${rdir}/benchmark/" 2>/dev/null || true
        log_info "Results: ${rdir}/benchmark/"
    fi

    rm -f "${yf}"
    delete_pod "${pod_name}"
    return 0
}

# ---- Main ----

# Task 2 remaining: runc/0.8B, runc/9B TP=2
for model in 08b 9b; do
    run_bench "runc" "${model}" "2"
done

# Task 3 all: kata/0.8B, kata/9B, runc/0.8B, runc/9B TP=1
for runtime in kata runc; do
    for model in 08b 9b; do
        run_bench "${runtime}" "${model}" "1"
    done
done

echo ""
echo "=============================================="
echo "  Recovery Complete"
echo "=============================================="
echo "  Failed: ${FAILED}"
echo "  Results: ${RESULT_DIR}"
find "${RESULT_DIR}" -maxdepth 2 -type d -name "tp*" | sort
echo "  Finished at $(date)"
exit ${FAILED}
