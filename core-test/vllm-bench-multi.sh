#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_BASE_DIR="${SCRIPT_DIR}/perf-logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# --- Pod 参数 ---
POD_NAME="${POD_NAME:-}"
POD_NAMESPACE="${POD_NAMESPACE:-}"
CONTAINER_NAME="${CONTAINER_NAME:-}"
POD_WAIT_TIMEOUT="${POD_WAIT_TIMEOUT:-300}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-600}"

# --- Benchmark 参数 ---
CONCURRENCY_LEVELS_RAW="${CONCURRENCY_LEVELS:-1 2 4 8 16 32 64}"
BENCH_BACKEND="${BENCH_BACKEND:-openai}"
BENCH_PORT="${BENCH_PORT:-8000}"
BENCH_ENDPOINT="${BENCH_ENDPOINT:-/v1/completions}"
BENCH_MODEL="${BENCH_MODEL:-/model}"
BENCH_DATASET_NAME="${BENCH_DATASET_NAME:-random}"
BENCH_INPUT_LEN="${BENCH_INPUT_LEN:-1024}"
BENCH_OUTPUT_LEN="${BENCH_OUTPUT_LEN:-128}"
BENCH_NUM_PROMPTS="${BENCH_NUM_PROMPTS:-1000}"
BENCH_REQUEST_RATE="${BENCH_REQUEST_RATE:-inf}"
BENCH_TOKENIZER="${BENCH_TOKENIZER:-/home/liulei/models/Qwen/Qwen3___5-9B/}"
BENCH_NO_PROXY="${BENCH_NO_PROXY:-*}"

# 每轮 benchmark 后冷却间隔 (秒)
COOLDOWN="${COOLDOWN:-5}"

# --- 工具函数 ---
now_sec() {
    date +%s.%N
}

duration_between() {
    local start="$1"
    local end="$2"

    awk -v start="${start}" -v end="${end}" 'BEGIN {
        if (end < start) {
            printf "N/A"
        } else {
            printf "%.2f", end - start
        }
    }'
}

sanitize_filename_token() {
    local value="$1"

    printf '%s' "${value}" | tr -c 'A-Za-z0-9_.-' '_'
}

require_non_empty() {
    local name="$1"
    local value="${!name}"

    if [ -z "${value}" ]; then
        echo "错误: ${name} 不能为空"
        exit 1
    fi
}

get_current_namespace() {
    local namespace

    namespace=$(kubectl config view --minify --output 'jsonpath={..namespace}' 2>/dev/null || true)
    if [ -n "${namespace}" ]; then
        printf '%s\n' "${namespace}"
    else
        printf 'default\n'
    fi
}

record_timepoint() {
    local key="$1"
    local description="$2"
    local epoch
    local elapsed
    local local_time

    epoch=$(now_sec)
    elapsed=$(duration_between "${SCRIPT_START}" "${epoch}")
    local_time=$(date '+%Y-%m-%d %H:%M:%S %z')
    description="${description//$'\t'/ }"

    printf "%s\t%s\t%s\t%s\t%s\n" "${key}" "${epoch}" "${elapsed}" "${local_time}" "${description}" >> "${TIMEPOINTS_FILE}"
}

print_timepoints_summary() {
    local key
    local epoch
    local elapsed
    local local_time
    local description

    echo ""
    echo "============================================================"
    echo "==> 阶段时间点"
    echo "============================================================"
    printf "  %-24s %-12s %-26s %s\n" "key" "elapsed(s)" "local_time" "description"

    while IFS=$'\t' read -r key epoch elapsed local_time description; do
        [ "${key}" = "key" ] && continue
        printf "  %-24s %-12s %-26s %s\n" "${key}" "${elapsed}" "${local_time}" "${description}"
    done < "${TIMEPOINTS_FILE}"
}

check_required_commands() {
    local cmd

    for cmd in kubectl curl vllm; do
        if ! command -v "${cmd}" >/dev/null 2>&1; then
            echo "错误: 缺少依赖命令 '${cmd}'"
            exit 1
        fi
    done
}

resolve_container_name() {
    local names
    local count

    if [ -n "${CONTAINER_NAME}" ]; then
        if ! kubectl -n "${POD_NAMESPACE}" get pod "${POD_NAME}" \
            -o jsonpath="{.spec.containers[?(@.name==\"${CONTAINER_NAME}\")].name}" | grep -Fxq "${CONTAINER_NAME}"; then
            echo "错误: Pod ${POD_NAMESPACE}/${POD_NAME} 中不存在容器: ${CONTAINER_NAME}"
            exit 1
        fi
        return 0
    fi

    names=$(kubectl -n "${POD_NAMESPACE}" get pod "${POD_NAME}" \
        -o jsonpath='{range .spec.containers[*]}{.name}{"\n"}{end}')

    if printf '%s\n' "${names}" | grep -qx 'cuda-container'; then
        CONTAINER_NAME="cuda-container"
        return 0
    fi

    count=$(printf '%s\n' "${names}" | sed '/^$/d' | wc -l)
    if [ "${count}" -eq 1 ]; then
        CONTAINER_NAME=$(printf '%s\n' "${names}" | sed '/^$/d' | head -n 1)
        return 0
    fi

    echo "错误: Pod ${POD_NAMESPACE}/${POD_NAME} 有多个容器，请显式设置 CONTAINER_NAME"
    echo "容器列表:"
    printf '  %s\n' ${names}
    exit 1
}

wait_for_pod_running() {
    local start
    local elapsed
    local phase

    echo -n "==> 等待 Pod Running"
    start=$(now_sec)
    while true; do
        phase=$(kubectl -n "${POD_NAMESPACE}" get pod "${POD_NAME}" \
            -o jsonpath='{.status.phase}' 2>/dev/null || true)

        if [ "${phase}" = "Running" ]; then
            echo ""
            echo "    Pod 已 Running: $(duration_between "${start}" "$(now_sec)")s"
            record_timepoint "pod_running" "Pod phase 为 Running"
            return 0
        fi

        if [ "${phase}" = "Failed" ] || [ "${phase}" = "Succeeded" ]; then
            echo ""
            echo "错误: Pod 已结束，状态: ${phase}"
            kubectl -n "${POD_NAMESPACE}" describe pod "${POD_NAME}" 2>/dev/null || true
            exit 1
        fi

        elapsed=$(duration_between "${start}" "$(now_sec)")
        if [ "$(printf '%.0f' "${elapsed}")" -ge "${POD_WAIT_TIMEOUT}" ]; then
            echo ""
            echo "错误: Pod 在 ${POD_WAIT_TIMEOUT}s 内未进入 Running，当前状态: ${phase:-Unknown}"
            kubectl -n "${POD_NAMESPACE}" describe pod "${POD_NAME}" 2>/dev/null || true
            exit 1
        fi

        echo -n "."
        sleep 1
    done
}

wait_for_health() {
    local start
    local elapsed
    local health_url="http://${POD_IP}:${BENCH_PORT}/health"

    echo -n "==> 等待 vLLM 服务就绪 (${health_url})"
    start=$(now_sec)
    record_timepoint "health_wait_start" "开始等待 /health"

    while true; do
        if curl --noproxy '*' -s --fail --max-time 3 "${health_url}" >/dev/null 2>&1; then
            echo ""
            echo "    vLLM 服务已就绪: $(duration_between "${start}" "$(now_sec)")s"
            record_timepoint "vllm_ready" "vLLM /health 返回成功"
            return 0
        fi

        elapsed=$(duration_between "${start}" "$(now_sec)")
        if [ "$(printf '%.0f' "${elapsed}")" -ge "${HEALTH_TIMEOUT}" ]; then
            echo ""
            echo "错误: vLLM 在 ${HEALTH_TIMEOUT}s 内未就绪"
            echo "最后几行 Pod 日志:"
            kubectl -n "${POD_NAMESPACE}" logs "${POD_NAME}" -c "${CONTAINER_NAME}" --tail=40 2>/dev/null || true
            exit 1
        fi

        echo -n "."
        sleep 2
    done
}

save_pod_yaml() {
    echo "==> 保存 benchmark 前 Pod YAML"
    kubectl -n "${POD_NAMESPACE}" get pod "${POD_NAME}" -o yaml > "${POD_YAML_FILE}"
    echo "    ${POD_YAML_FILE}"
    record_timepoint "pod_yaml_saved" "保存 Pod YAML"
}

save_pod_logs() {
    echo "==> 保存 benchmark 前 Pod 日志"

    if kubectl -n "${POD_NAMESPACE}" logs "${POD_NAME}" -c "${CONTAINER_NAME}" --timestamps > "${POD_PRE_BENCH_LOG}" 2>&1; then
        echo "    ${POD_PRE_BENCH_LOG}"
    else
        echo "警告: 获取 Pod 日志失败，错误输出已保存到: ${POD_PRE_BENCH_LOG}"
    fi
    record_timepoint "pod_log_saved" "保存 benchmark 前 Pod 日志"
}

run_one_concurrency() {
    local concurrency="$1"
    local result_dir="${RUN_DIR}/c${concurrency}"
    local bench_log="${result_dir}/vllm_bench.log"
    local result_json="${result_dir}/vllm_bench.json"
    local bench_start
    local bench_end
    local bench_time
    local bench_status
    local bench_run_cmd=()
    local status_text

    mkdir -p "${result_dir}"

    echo ""
    echo "--- max-concurrency=${concurrency} ---"
    echo "    开始时间: $(date)"
    echo "    benchmark 日志: ${bench_log}"
    echo "    benchmark JSON: ${result_json}"

    bench_run_cmd=(
        vllm bench serve
        --backend "${BENCH_BACKEND}"
        --host "${POD_IP}"
        --port "${BENCH_PORT}"
        --endpoint "${BENCH_ENDPOINT}"
        --model "${BENCH_MODEL}"
        --dataset-name "${BENCH_DATASET_NAME}"
        --input-len "${BENCH_INPUT_LEN}"
        --output-len "${BENCH_OUTPUT_LEN}"
        --num-prompts "${BENCH_NUM_PROMPTS}"
        --max-concurrency "${concurrency}"
        --request-rate "${BENCH_REQUEST_RATE}"
        --save-result
        --result-dir "${result_dir}"
        --result-filename "$(basename "${result_json}")"
    )

    if [ -n "${BENCH_TOKENIZER}" ]; then
        bench_run_cmd+=(--tokenizer "${BENCH_TOKENIZER}")
    fi

    if [ -n "${BENCH_NO_PROXY}" ]; then
        bench_run_cmd=(env "NO_PROXY=${BENCH_NO_PROXY}" "no_proxy=${BENCH_NO_PROXY}" "${bench_run_cmd[@]}")
    fi

    printf "    命令:"
    printf " %q" "${bench_run_cmd[@]}"
    printf "\n"

    bench_start=$(now_sec)
    record_timepoint "bench_c${concurrency}_start" "开始 benchmark max-concurrency=${concurrency}"

    set +e
    "${bench_run_cmd[@]}" > >(tee -a "${bench_log}") 2>&1
    bench_status=$?
    set -e

    bench_end=$(now_sec)
    bench_time=$(duration_between "${bench_start}" "${bench_end}")
    record_timepoint "bench_c${concurrency}_end" "结束 benchmark max-concurrency=${concurrency}，退出码 ${bench_status}"

    if [ "${bench_status}" -ne 0 ]; then
        status_text="FAIL"
        echo "    c${concurrency} FAILED (退出码: ${bench_status}, 耗时: ${bench_time}s)"
    else
        status_text="PASS"
        echo "    c${concurrency} OK (耗时: ${bench_time}s)"
    fi

    printf "%s,%s,%s,%s,%s,%s,%s,%s\n" \
        "${concurrency}" \
        "${bench_start}" \
        "${bench_end}" \
        "${bench_time}" \
        "${bench_status}" \
        "${status_text}" \
        "${result_json}" \
        "${bench_log}" >> "${SUMMARY_CSV}"

    if [ -f "${result_json}" ]; then
        echo "    结果: ${result_json}"
    fi

    return "${bench_status}"
}

check_required_commands

require_non_empty POD_NAME

if [ -z "${POD_NAMESPACE}" ]; then
    POD_NAMESPACE=$(get_current_namespace)
fi

read -r -a CONCURRENCY_LEVELS <<< "${CONCURRENCY_LEVELS_RAW}"
if [ "${#CONCURRENCY_LEVELS[@]}" -eq 0 ]; then
    echo "错误: CONCURRENCY_LEVELS 不能为空"
    exit 1
fi
LAST_CONCURRENCY_INDEX=$((${#CONCURRENCY_LEVELS[@]} - 1))
LAST_CONCURRENCY="${CONCURRENCY_LEVELS[${LAST_CONCURRENCY_INDEX}]}"

for var in BENCH_BACKEND BENCH_MODEL BENCH_DATASET_NAME BENCH_INPUT_LEN BENCH_OUTPUT_LEN BENCH_NUM_PROMPTS BENCH_REQUEST_RATE BENCH_ENDPOINT BENCH_PORT; do
    require_non_empty "${var}"
done

SAFE_NAMESPACE=$(sanitize_filename_token "${POD_NAMESPACE}")
SAFE_POD_NAME=$(sanitize_filename_token "${POD_NAME}")
RUN_DIR="${LOG_BASE_DIR}/pod-bench_${SAFE_NAMESPACE}_${SAFE_POD_NAME}_${TIMESTAMP}"
MAIN_LOG="${RUN_DIR}/run.log"
TIMEPOINTS_FILE="${RUN_DIR}/timepoints.tsv"
POD_YAML_FILE="${RUN_DIR}/pod.yaml"
POD_PRE_BENCH_LOG="${RUN_DIR}/pod_pre_bench.log"
SUMMARY_CSV="${RUN_DIR}/summary.csv"

mkdir -p "${RUN_DIR}"

exec > >(tee -a "${MAIN_LOG}")
exec 2>&1

SCRIPT_START=$(now_sec)
printf "key\tepoch\telapsed_since_start_sec\tlocal_time\tdescription\n" > "${TIMEPOINTS_FILE}"
record_timepoint "script_start" "脚本开始"
printf "concurrency,start_epoch,end_epoch,duration_sec,exit_code,status,result_json,bench_log\n" > "${SUMMARY_CSV}"

echo "==> $(date) 开始单 Pod 多并发 vLLM benchmark"
echo "    Pod: ${POD_NAMESPACE}/${POD_NAME}"
echo "    并发度: ${CONCURRENCY_LEVELS[*]}"
echo "    输出目录: ${RUN_DIR}"
echo "    Benchmark 参数:"
echo "      backend=${BENCH_BACKEND}"
echo "      port=${BENCH_PORT}"
echo "      endpoint=${BENCH_ENDPOINT}"
echo "      model=${BENCH_MODEL}"
echo "      dataset=${BENCH_DATASET_NAME}"
echo "      input-len=${BENCH_INPUT_LEN}"
echo "      output-len=${BENCH_OUTPUT_LEN}"
echo "      num-prompts=${BENCH_NUM_PROMPTS}"
echo "      request-rate=${BENCH_REQUEST_RATE}"
echo "      tokenizer=${BENCH_TOKENIZER}"
echo "      no-proxy=${BENCH_NO_PROXY}"
echo ""

if ! kubectl -n "${POD_NAMESPACE}" get pod "${POD_NAME}" -o name >/dev/null 2>&1; then
    echo "错误: Pod 不存在或不可访问: ${POD_NAMESPACE}/${POD_NAME}"
    exit 1
fi

resolve_container_name
echo "    容器: ${CONTAINER_NAME}"

NODE_NAME=$(kubectl -n "${POD_NAMESPACE}" get pod "${POD_NAME}" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)
POD_PHASE=$(kubectl -n "${POD_NAMESPACE}" get pod "${POD_NAME}" -o jsonpath='{.status.phase}' 2>/dev/null || true)
POD_IP=$(kubectl -n "${POD_NAMESPACE}" get pod "${POD_NAME}" -o jsonpath='{.status.podIP}' 2>/dev/null || true)

echo "    节点: ${NODE_NAME:-未分配}"
echo "    当前状态: ${POD_PHASE:-Unknown}"
echo "    当前 Pod IP: ${POD_IP:-未分配}"
record_timepoint "pod_found" "Pod 对象可访问"

wait_for_pod_running

POD_IP=$(kubectl -n "${POD_NAMESPACE}" get pod "${POD_NAME}" -o jsonpath='{.status.podIP}' 2>/dev/null || true)
if [ -z "${POD_IP}" ]; then
    echo "错误: 无法获取 Pod IP"
    exit 1
fi
echo "==> Pod IP: ${POD_IP}"
record_timepoint "pod_ip_ready" "获取 Pod IP: ${POD_IP}"

wait_for_health
save_pod_yaml
save_pod_logs

SCRIPT_BENCH_START=$(now_sec)
FAIL_COUNT=0

for concurrency in "${CONCURRENCY_LEVELS[@]}"; do
    if run_one_concurrency "${concurrency}"; then
        :
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi

    if [ "${concurrency}" != "${LAST_CONCURRENCY}" ]; then
        sleep "${COOLDOWN}"
    fi
done

SCRIPT_END=$(now_sec)
record_timepoint "script_end" "脚本主流程结束"

echo ""
echo "============================================================"
echo "==> Benchmark 汇总"
echo "============================================================"
echo "  Pod: ${POD_NAMESPACE}/${POD_NAME}"
echo "  Pod IP: ${POD_IP}"
echo "  总耗时: $(duration_between "${SCRIPT_START}" "${SCRIPT_END}")s"
echo "  Benchmark 总窗口: $(duration_between "${SCRIPT_BENCH_START}" "${SCRIPT_END}")s"
echo "  失败轮数: ${FAIL_COUNT}/${#CONCURRENCY_LEVELS[@]}"
echo ""

while IFS=, read -r concurrency start_epoch end_epoch duration exit_code status result_json bench_log; do
    [ "${concurrency}" = "concurrency" ] && continue
    printf "  c%-6s %-4s exit=%-4s duration=%ss result=%s\n" \
        "${concurrency}" "${status}" "${exit_code}" "${duration}" "${result_json}"
done < "${SUMMARY_CSV}"

print_timepoints_summary

echo ""
echo "--- 输出文件 ---"
echo "  运行目录:       ${RUN_DIR}"
echo "  主日志:         ${MAIN_LOG}"
echo "  时间点 TSV:     ${TIMEPOINTS_FILE}"
echo "  Pod YAML:       ${POD_YAML_FILE}"
echo "  benchmark 前日志: ${POD_PRE_BENCH_LOG}"
echo "  汇总 CSV:       ${SUMMARY_CSV}"
echo ""

if [ "${FAIL_COUNT}" -gt 0 ]; then
    echo "错误: ${FAIL_COUNT}/${#CONCURRENCY_LEVELS[@]} 轮 benchmark 失败"
    exit 1
fi

echo "==> $(date) 单 Pod 多并发 benchmark 完成"
