#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/perf-logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# --- 可配置参数 ---
IPS=("10.244.0.151" "10.244.0.144")
CONCURRENCY_LEVELS=(1 2 4 8 16 32 64)

# Benchmark 参数
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

mkdir -p "${LOG_DIR}"

MAIN_LOG="${LOG_DIR}/vllm_bench_multi_${TIMESTAMP}.log"
exec > >(tee -a "${MAIN_LOG}")
exec 2>&1

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

# --- 健康检查 ---
echo "==> $(date) 开始多 IP 多并发 vLLM benchmark"
echo "    IP 列表: ${IPS[*]}"
echo "    并发度: ${CONCURRENCY_LEVELS[*]}"
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
echo ""

for ip in "${IPS[@]}"; do
    echo -n "==> 健康检查 http://${ip}:${BENCH_PORT}/health ... "
    if curl --noproxy '*' -s --fail --max-time 5 "http://${ip}:${BENCH_PORT}/health" >/dev/null 2>&1; then
        echo "OK"
    else
        echo "FAIL"
        echo "错误: IP ${ip} 不可达，请确认 vLLM 服务正在运行"
        exit 1
    fi
done

echo ""

# --- 对单个 IP 依次跑所有并发度 ---
benchmark_one_ip() {
    local ip="$1"
    local ip_result_dir="${LOG_DIR}/${ip}"
    local ip_log="${LOG_DIR}/vllm_bench_${ip}_${TIMESTAMP}.log"
    local overall_start
    local overall_end
    local status=0

    mkdir -p "${ip_result_dir}"

    {
        echo "==> [${ip}] 开始 benchmark 序列: $(date)"
        overall_start=$(now_sec)

        for c in "${CONCURRENCY_LEVELS[@]}"; do
            local bench_start
            local bench_end
            local bench_time
            local result_json="${ip_result_dir}/c${c}.json"

            echo ""
            echo "--- [${ip}] max-concurrency=${c} ---"
            echo "    开始时间: $(date)"

            bench_start=$(now_sec)

            set +e
            env NO_PROXY="${BENCH_NO_PROXY}" no_proxy="${BENCH_NO_PROXY}" \
                vllm bench serve \
                --backend "${BENCH_BACKEND}" \
                --host "${ip}" \
                --port "${BENCH_PORT}" \
                --endpoint "${BENCH_ENDPOINT}" \
                --model "${BENCH_MODEL}" \
                --dataset-name "${BENCH_DATASET_NAME}" \
                --input-len "${BENCH_INPUT_LEN}" \
                --output-len "${BENCH_OUTPUT_LEN}" \
                --num-prompts "${BENCH_NUM_PROMPTS}" \
                --max-concurrency "${c}" \
                --request-rate "${BENCH_REQUEST_RATE}" \
                --tokenizer "${BENCH_TOKENIZER}" \
                --save-result \
                --result-dir "${ip_result_dir}" \
                --result-filename "$(basename "${result_json}")"
            local bench_status=$?
            set -e

            bench_end=$(now_sec)
            bench_time=$(duration_between "${bench_start}" "${bench_end}")

            if [ "${bench_status}" -ne 0 ]; then
                echo "    [${ip}] c${c} FAILED (退出码: ${bench_status}, 耗时: ${bench_time}s)"
                status=1
            else
                echo "    [${ip}] c${c} OK (耗时: ${bench_time}s)"
            fi

            if [ -f "${result_json}" ]; then
                echo "    结果: ${result_json}"
            fi

            sleep "${COOLDOWN}"
        done

        overall_end=$(now_sec)
        echo ""
        echo "==> [${ip}] benchmark 序列结束: $(date)"
        echo "    总耗时: $(duration_between "${overall_start}" "${overall_end}")s"

        return "${status}"
    } > >(tee -a "${ip_log}") 2>&1
}

SCRIPT_START=$(now_sec)

declare -A IP_STATUS
FAIL_COUNT=0

for ip in "${IPS[@]}"; do
    echo "==> 开始测试 IP: ${ip}"
    if benchmark_one_ip "${ip}"; then
        IP_STATUS["${ip}"]=0
        echo "    [${ip}] 完成"
    else
        IP_STATUS["${ip}"]=$?
        FAIL_COUNT=$((FAIL_COUNT + 1))
        echo "    [${ip}] 失败 (退出码: ${IP_STATUS[${ip}]})"
    fi
    echo ""
done

SCRIPT_END=$(now_sec)

echo ""
echo "============================================================"
echo "==> Benchmark 汇总"
echo "============================================================"
echo "  总耗时: $(duration_between "${SCRIPT_START}" "${SCRIPT_END}")s"
echo ""

for ip in "${IPS[@]}"; do
    s="${IP_STATUS[${ip}]}"
    if [ "${s}" -eq 0 ]; then
        echo "  [${ip}] PASS"
    else
        echo "  [${ip}] FAIL (退出码: ${s})"
    fi
done

echo ""
echo "--- 输出文件 ---"
echo "  主日志: ${MAIN_LOG}"
for ip in "${IPS[@]}"; do
    echo "  ${ip}:"
    for c in "${CONCURRENCY_LEVELS[@]}"; do
        echo "    c${c}: ${LOG_DIR}/${ip}/c${c}.json"
    done
done
echo ""

if [ "${FAIL_COUNT}" -gt 0 ]; then
    echo "错误: ${FAIL_COUNT}/${#IPS[@]} 个 IP 的 benchmark 失败"
    exit 1
fi

echo "==> $(date) 多 IP 多并发 benchmark 完成"
