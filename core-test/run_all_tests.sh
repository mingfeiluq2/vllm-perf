#!/bin/bash
set -euo pipefail

# =============================================================================
# run_all_tests.sh — GPU Communication & vLLM Benchmark Orchestrator
# =============================================================================
# 任务一：GPU 通信性能测试（gpu-comm-test-*.yaml）—— P2P copy + NCCL all-reduce
# 任务二：vLLM 推理性能测试 TP=2（gpu-pod-*.yaml + vllm-bench-multi.sh）
# 任务三：vLLM 推理性能测试 TP=1
#
# 用法:  bash run_all_tests.sh [选项]
#   --skip-comm    跳过 GPU 通信测试（任务一）
#   --skip-tp2     跳过 vLLM TP=2 基准测试（任务二）
#   --skip-tp1     跳过 vLLM TP=1 基准测试（任务三）
#
# 不要在 benchmark 中途退出；失败时记录并继续下一个测试。
# =============================================================================

# ── 路径常量 ──────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

MODEL_08B="/home/liulei/models/Qwen/Qwen3.5-0.8B"
MODEL_9B="/home/liulei/models/Qwen/Qwen3___5-9B"
TRACE_DIR="/data/home/liulei/TcProject/ctr-container/traces"
RESULT_DIR="${SCRIPT_DIR}/result"

# 指定使用默认 namespace（当前 kubectl context）
NAMESPACE="${NAMESPACE:-default}"

# vllm-bench-multi.sh 路径
BENCH_SCRIPT="${SCRIPT_DIR}/vllm-bench-multi.sh"

# gpu-comm-test YAML 文件
COMM_YAML_KATA="${SCRIPT_DIR}/gpu-comm-test-kata.yaml"
COMM_YAML_RUNC="${SCRIPT_DIR}/gpu-comm-test-runc.yaml"

# gpu-pod YAML 模板
GPU_POD_KATA="${REPO_DIR}/gpu-pod-kata.yaml"
GPU_POD_RUNC="${REPO_DIR}/gpu-pod-runc.yaml"

# ── 变量 ──────────────────────────────────────────────────────────────────────

SKIP_COMM=false
SKIP_TP2=false
SKIP_TP1=false

OVERALL_TIMESTAMP=$(date -u +%Y%m%dT%H%M%SZ)
PASS_COUNT=0
FAIL_COUNT=0
FAIL_LOG=""  # 累计失败详情

# ── 颜色 ──────────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ── 工具函数 ──────────────────────────────────────────────────────────────────

now_sec() { date +%s.%N; }

duration_between() {
    local start="$1" end="$2"
    awk -v start="${start}" -v end="${end}" 'BEGIN {
        if (end < start) { printf "N/A" } else { printf "%.2f", end - start }
    }'
}

log_info()  { echo -e "${CYAN}[INFO]${NC}  $(date '+%H:%M:%S') $*"; }
log_pass()  { echo -e "${GREEN}[PASS]${NC}  $(date '+%H:%M:%S') $*"; }
log_fail()  { echo -e "${RED}[FAIL]${NC}  $(date '+%H:%M:%S') $*"; }
log_step()  { echo -e "${YELLOW}[STEP]${NC} $(date '+%H:%M:%S') $*"; }
log_sect()  { echo ""; echo "═══════════════════════════════════════════════════════════════"; echo -e "${YELLOW}  $*${NC}"; echo "═══════════════════════════════════════════════════════════════"; }

record_result() {
    local name="$1" status="$2" detail="$3"
    if [ "${status}" = "PASS" ]; then
        PASS_COUNT=$((PASS_COUNT + 1))
        log_pass "${name}"
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAIL_LOG="${FAIL_LOG}  ❌ ${name}: ${detail}\n"
        log_fail "${name}: ${detail}"
    fi
}

wait_for_pod_succeeded() {
    local pod="$1" timeout="$2" phase
    local start; start=$(now_sec)
    log_info "等待 Pod ${pod} Succeeded（超时 ${timeout}s）"
    while true; do
        phase=$(kubectl -n "${NAMESPACE}" get pod "${pod}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        if [ "${phase}" = "Succeeded" ]; then
            log_info "Pod ${pod} 已完成，耗时 $(duration_between "${start}" "$(now_sec)")s"
            return 0
        fi
        if [ "${phase}" = "Failed" ]; then
            log_fail "Pod ${pod} 失败"
            return 1
        fi
        if [ "$(printf '%.0f' "$(duration_between "${start}" "$(now_sec)")")" -ge "${timeout}" ]; then
            log_fail "Pod ${pod} 超时（${timeout}s），当前状态: ${phase}"
            return 1
        fi
        sleep 5
    done
}

wait_for_pod_running() {
    local pod="$1" timeout="$2" phase
    local start; start=$(now_sec)
    log_info "等待 Pod ${pod} Running（超时 ${timeout}s）"
    while true; do
        phase=$(kubectl -n "${NAMESPACE}" get pod "${pod}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        if [ "${phase}" = "Running" ]; then
            log_info "Pod ${pod} 已 Running，耗时 $(duration_between "${start}" "$(now_sec)")s"
            return 0
        fi
        if [ "${phase}" = "Failed" ] || [ "${phase}" = "Succeeded" ]; then
            log_fail "Pod ${pod} 已结束，状态: ${phase}"
            return 1
        fi
        if [ "$(printf '%.0f' "$(duration_between "${start}" "$(now_sec)")")" -ge "${timeout}" ]; then
            log_fail "Pod ${pod} 超时（${timeout}s），当前状态: ${phase:-Unknown}"
            return 1
        fi
        sleep 5
    done
}

wait_for_vllm_health() {
    local pod="$1" timeout="$2" pod_ip="$3"
    local start; start=$(now_sec)
    local health_url="http://${pod_ip}:8000/health"
    log_info "等待 vLLM /health（${health_url}，超时 ${timeout}s）"
    while true; do
        if curl --noproxy '*' -s --fail --max-time 3 "${health_url}" >/dev/null 2>&1; then
            log_info "vLLM 已就绪，耗时 $(duration_between "${start}" "$(now_sec)")s"
            return 0
        fi
        if [ "$(printf '%.0f' "$(duration_between "${start}" "$(now_sec)")")" -ge "${timeout}" ]; then
            log_fail "vLLM 超时（${timeout}s），最后 30 行日志："
            kubectl -n "${NAMESPACE}" logs "${pod}" --tail=30 2>/dev/null || true
            return 1
        fi
        sleep 5
    done
}

delete_pod() {
    local pod="$1"
    log_info "删除 Pod ${pod}"
    kubectl -n "${NAMESPACE}" delete pod "${pod}" --ignore-not-found --wait=true --timeout=60s 2>/dev/null || true
    # 确保完全删除
    local start; start=$(now_sec)
    while kubectl -n "${NAMESPACE}" get pod "${pod}" -o name >/dev/null 2>&1; do
        if [ "$(printf '%.0f' "$(duration_between "${start}" "$(now_sec)")")" -ge 60 ]; then
            log_fail "无法在 60s 内删除 Pod ${pod}"
            return 1
        fi
        sleep 2
    done
    log_info "Pod ${pod} 已删除"
}

get_pod_ip() {
    local pod="$1"
    kubectl -n "${NAMESPACE}" get pod "${pod}" -o jsonpath='{.status.podIP}' 2>/dev/null || echo ""
}

# 生成临时 YAML：修改模型路径和 TP
generate_temp_yaml() {
    local template="$1" model_path="$2" tp="$3" pod_name="$4"
    local gpu_resource_name="$5"  # nvidia.com/pgpu 或 nvidia.com/gpu
    local temp_file
    temp_file="$(mktemp /tmp/gpu-pod-XXXXXX.yaml)"

    cp "${template}" "${temp_file}"

    # 替换模型 hostPath
    local orig_model_path
    if echo "${template}" | grep -q "kata"; then
        orig_model_path="/home/liulei/models/Qwen/Qwen3.5-0.8B"
    else
        orig_model_path="/home/liulei/models/Qwen/Qwen3.5-0.8B"
    fi
    sed -i "s|${orig_model_path}|${model_path}|g" "${temp_file}"

    # 替换 pod name
    sed -i "s/^    name: gpu-pod-.*/    name: ${pod_name}/" "${temp_file}"

    # 替换 tensor-parallel-size
    sed -i "s/--tensor-parallel-size [0-9]/--tensor-parallel-size ${tp}/" "${temp_file}"

    # 替换 GPU 数量（使用 | 作为 sed 分隔符避免 / 冲突）
    sed -i "s|\(${gpu_resource_name}\): [0-9]*|\1: ${tp}|g" "${temp_file}"

    echo "${temp_file}"
}

# 创建 metadata.txt
write_metadata() {
    local dir="$1" test_type="$2" runtime="$3" model="$4" tp="$5" gpu_count="$6" pod_name="$7"
    mkdir -p "${dir}"
    cat > "${dir}/metadata.txt" <<EOF
test_type=${test_type}
runtime=${runtime}
model=${model}
tensor_parallel=${tp}
gpu_count=${gpu_count}
timestamp_utc=${OVERALL_TIMESTAMP}
pod_name=${pod_name}
namespace=${NAMESPACE}
node=server
host=$(hostname)
EOF
}

# ── 任务一：GPU 通信测试 ───────────────────────────────────────────────────────

run_gpu_comm_test() {
    local runtime="$1"
    local yaml_file pod_name

    if [ "${runtime}" = "kata" ]; then
        yaml_file="${COMM_YAML_KATA}"
        pod_name="gpu-comm-test-kata"
    else
        yaml_file="${COMM_YAML_RUNC}"
        pod_name="gpu-comm-test-runc"
    fi

    log_sect "[任务一] GPU 通信测试 — ${runtime}"

    # 清理旧 Pod
    delete_pod "${pod_name}" || true

    # 启动 Pod
    log_info "部署 ${pod_name}"
    if ! kubectl -n "${NAMESPACE}" apply -f "${yaml_file}" 2>&1; then
        record_result "gpu-comm-${runtime}" "FAIL" "apply 失败"
        return 1
    fi

    # 等待完成
    if ! wait_for_pod_succeeded "${pod_name}" 900; then
        kubectl -n "${NAMESPACE}" describe pod "${pod_name}" 2>/dev/null || true
        kubectl -n "${NAMESPACE}" logs "${pod_name}" --tail=50 2>/dev/null || true
        record_result "gpu-comm-${runtime}" "FAIL" "Pod 未完成"
        delete_pod "${pod_name}" || true
        return 1
    fi

    # 从 trace 目录收集结果
    local latest_dir
    latest_dir=$(find "${TRACE_DIR}/gpu-comm" -maxdepth 1 -type d -name "${runtime}_*" -printf '%T@\t%p\n' 2>/dev/null | sort -n | tail -1 | cut -f2)
    if [ -z "${latest_dir}" ] || [ ! -d "${latest_dir}" ]; then
        # 尝试查找最新创建的目录
        latest_dir=$(ls -td "${TRACE_DIR}/gpu-comm/${runtime}_"* 2>/dev/null | head -1)
    fi

    if [ -z "${latest_dir}" ] || [ ! -d "${latest_dir}" ]; then
        record_result "gpu-comm-${runtime}" "FAIL" "未找到输出目录 ${TRACE_DIR}/gpu-comm/${runtime}_*/"
        delete_pod "${pod_name}" || true
        return 1
    fi

    # 复制结果到 result 目录
    local result_subdir="${RESULT_DIR}/gpu-comm-${OVERALL_TIMESTAMP}/${runtime}"
    mkdir -p "${result_subdir}"
    cp -a "${latest_dir}/"* "${result_subdir}/" 2>/dev/null || true

    # 写入 metadata
    write_metadata "${result_subdir}" "gpu-comm" "${runtime}" "N/A" "N/A" "2" "${pod_name}"

    log_info "结果已复制到 ${result_subdir}"
    ls -la "${result_subdir}/"

    # 删除 Pod
    delete_pod "${pod_name}" || true

    record_result "gpu-comm-${runtime}" "PASS" ""
}

# ── 任务二 & 三：vLLM Benchmark ───────────────────────────────────────────────

run_vllm_bench() {
    local runtime="$1"   # kata | runc
    local model="$2"     # 08b | 9b
    local tp="$3"        # 1 | 2

    local model_path gpu_resource pod_template model_label gpu_count
    local bench_label

    if [ "${model}" = "9b" ]; then
        model_path="${MODEL_9B}"
        model_label="9B"
    else
        model_path="${MODEL_08B}"
        model_label="0.8B"
    fi

    if [ "${runtime}" = "kata" ]; then
        gpu_resource="nvidia.com/pgpu"
        pod_template="${GPU_POD_KATA}"
    else
        gpu_resource="nvidia.com/gpu"
        pod_template="${GPU_POD_RUNC}"
    fi

    gpu_count="${tp}"  # TP = GPU 数量
    local model_label_lc
    model_label_lc=$(echo "${model_label}" | tr '[:upper:]' '[:lower:]')
    local pod_name="gpu-pod-${runtime}-tp${tp}-${model_label_lc}"
    # 简化: 清理可能存在的旧 pod
    local safe_pod_name="gpu-pod-${runtime}"

    if [ "${tp}" = "2" ]; then
        bench_label="[任务二] vLLM TP=2 — ${runtime} / ${model_label}"
    else
        bench_label="[任务三] vLLM TP=1 — ${runtime} / ${model_label}"
    fi

    log_sect "${bench_label}"

    # 清理旧 Pod
    delete_pod "${safe_pod_name}" || true

    # 生成临时 YAML
    local temp_yaml
    temp_yaml=$(generate_temp_yaml "${pod_template}" "${model_path}" "${tp}" "${safe_pod_name}" "${gpu_resource}")
    log_info "使用临时 YAML: ${temp_yaml}"

    # 调整 CPU/Memory（TP=1 时可以适当减少）
    if [ "${tp}" = "1" ]; then
        # TP=1 时只请求 1 GPU，CPU/Memory 也可以降低
        sed -i 's/cpu: "16"/cpu: "8"/' "${temp_yaml}"
        if [ "${runtime}" = "kata" ]; then
            sed -i 's/memory: "56Gi"/memory: "32Gi"/' "${temp_yaml}"
        else
            sed -i 's/memory: "64Gi"/memory: "32Gi"/' "${temp_yaml}"
        fi
    fi

    # 启动 Pod
    log_info "部署 Pod ${safe_pod_name}"
    if ! kubectl -n "${NAMESPACE}" apply -f "${temp_yaml}" 2>&1; then
        record_result "${bench_label}" "FAIL" "kubectl apply 失败"
        rm -f "${temp_yaml}"
        return 1
    fi

    # 等待 Pod Running
    local wait_running_timeout=600
    if ! wait_for_pod_running "${safe_pod_name}" ${wait_running_timeout}; then
        kubectl -n "${NAMESPACE}" describe pod "${safe_pod_name}" 2>/dev/null || true
        record_result "${bench_label}" "FAIL" "Pod 未 Running"
        delete_pod "${safe_pod_name}" || true
        rm -f "${temp_yaml}"
        return 1
    fi

    # 等待 vLLM health
    local pod_ip
    local max_health_wait=1200  # 9B 模型加载可能较慢
    local health_wait_start; health_wait_start=$(now_sec)

    # 先获取 Pod IP
    pod_ip=$(get_pod_ip "${safe_pod_name}")
    if [ -z "${pod_ip}" ]; then
        record_result "${bench_label}" "FAIL" "无法获取 Pod IP"
        delete_pod "${safe_pod_name}" || true
        rm -f "${temp_yaml}"
        return 1
    fi
    log_info "Pod IP: ${pod_ip}"

    # 等待 vLLM health
    if ! wait_for_vllm_health "${safe_pod_name}" ${max_health_wait} "${pod_ip}"; then
        record_result "${bench_label}" "FAIL" "vLLM /health 超时"
        delete_pod "${safe_pod_name}" || true
        rm -f "${temp_yaml}"
        return 1
    fi

    # ★ 捕获并保存 vLLM 启动日志（从 Pod 开始到 Health Check 通过）
    #   这是 vLLM 启动过程日志（含模型加载），不含后续服务请求日志
    local result_base_dir="${RESULT_DIR}/tp${tp}-${gpu_count}gpu-${model_label_lc}/${runtime}"
    mkdir -p "${result_base_dir}"
    local startup_log="${result_base_dir}/vllm_startup.log"
    kubectl -n "${NAMESPACE}" logs "${safe_pod_name}" --timestamps > "${startup_log}" 2>&1 || true
    log_info "启动日志已保存: ${startup_log} ($(wc -l < "${startup_log}") 行)"

    # 写入 metadata
    write_metadata "${result_base_dir}" "vllm-bench" "${runtime}" "${model_label}" "${tp}" "${gpu_count}" "${safe_pod_name}"

    # 运行 vllm-bench-multi.sh
    log_info "开始运行 vllm-bench-multi.sh..."
    local bench_start; bench_start=$(now_sec)

    # 设置环境变量
    export POD_NAME="${safe_pod_name}"
    export POD_NAMESPACE="${NAMESPACE}"
    export BENCH_TOKENIZER="${model_path}/"

    # 在 TP=1 时可能需要调整 concurrency（单 GPU 可能不如双 GPU 能承受高并发）
    # 但保持默认 1,2,4,8,16,32,64

    set +e
    if bash "${BENCH_SCRIPT}" 2>&1; then
        local bench_status="PASS"
    else
        local bench_status="FAIL"
    fi
    set -e

    local bench_duration; bench_duration=$(duration_between "${bench_start}" "$(now_sec)")
    log_info "vllm-bench-multi.sh 耗时: ${bench_duration}s，状态: ${bench_status}"

    # 将 benchmark 结果复制到 result 目录
    # vllm-bench-multi.sh 输出在 core-test/perf-logs/pod-bench_<namespace>_<pod>_<timestamp>/
    local latest_bench_dir
    latest_bench_dir=$(ls -td "${SCRIPT_DIR}/perf-logs/pod-bench_${NAMESPACE}_${safe_pod_name}_"* 2>/dev/null | head -1)
    if [ -n "${latest_bench_dir}" ] && [ -d "${latest_bench_dir}" ]; then
        log_info "复制 benchmark 结果: ${latest_bench_dir} → ${result_base_dir}/benchmark/"
        cp -a "${latest_bench_dir}" "${result_base_dir}/benchmark/"
        log_info "Benchmark 结果已保存"
    else
        log_fail "未找到 vllm-bench-multi.sh 的输出目录"
    fi

    # 删除临时 YAML
    rm -f "${temp_yaml}"

    # 删除 Pod（不再需要）
    delete_pod "${safe_pod_name}" || true

    record_result "${bench_label}" "${bench_status}" ""
}

# ── 打印汇总 ──────────────────────────────────────────────────────────────────

print_summary() {
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║                    测试汇总                                 ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
    echo "  开始时间: ${OVERALL_TIMESTAMP}"
    echo "  总耗时:   $(duration_between "${START_TIME}" "$(now_sec)")s"
    echo ""
    echo "  通过: ${GREEN}${PASS_COUNT}${NC}    失败: ${RED}${FAIL_COUNT}${NC}"
    echo ""

    if [ -n "${FAIL_LOG}" ]; then
        echo "  失败详情:"
        echo -e "${FAIL_LOG}"
    fi

    echo ""
    echo "  Result 目录: ${RESULT_DIR}"
    echo "  Result 树:"
    (
        find "${RESULT_DIR}" -maxdepth 2 -type d -name "gpu-comm-*" 2>/dev/null | sort
        find "${RESULT_DIR}" -maxdepth 2 -type d -name "tp*-*gpu-*" 2>/dev/null | sort
    ) | while IFS= read -r d; do
        echo "    ${d}/"
    done || true
    echo ""
}

# ── 主入口 ────────────────────────────────────────────────────────────────────

main() {
    # 解析参数
    for arg in "$@"; do
        case "${arg}" in
            --skip-comm) SKIP_COMM=true ;;
            --skip-tp2)  SKIP_TP2=true ;;
            --skip-tp1)  SKIP_TP1=true ;;
            *) log_fail "未知参数: ${arg}"; exit 1 ;;
        esac
    done

    # 检查依赖
    for cmd in kubectl curl sed; do
        if ! command -v "${cmd}" >/dev/null 2>&1; then
            log_fail "缺少依赖: ${cmd}"
            exit 1
        fi
    done

    # 检查 YAML 是否存在
    for f in "${COMM_YAML_KATA}" "${COMM_YAML_RUNC}" "${GPU_POD_KATA}" "${GPU_POD_RUNC}" "${BENCH_SCRIPT}"; do
        if [ ! -f "${f}" ]; then
            log_fail "文件不存在: ${f}"
            exit 1
        fi
    done

    # 创建 result 目录
    mkdir -p "${RESULT_DIR}"

    log_sect "开始三项 GPU 性能测试（${OVERALL_TIMESTAMP}）"
    echo "  Test 1 (GPU Comm):  $([ "${SKIP_COMM}" = true ] && echo 'SKIP' || echo 'ENABLED')"
    echo "  Test 2 (TP=2):      $([ "${SKIP_TP2}" = true ] && echo 'SKIP' || echo 'ENABLED')"
    echo "  Test 3 (TP=1):      $([ "${SKIP_TP1}" = true ] && echo 'SKIP' || echo 'ENABLED')"
    echo ""

    # ── 任务一：GPU 通信测试 ──────────────────────────────────────────────
    if [ "${SKIP_COMM}" = false ]; then
        run_gpu_comm_test "kata"
        run_gpu_comm_test "runc"
    else
        log_info "跳过 GPU 通信测试（--skip-comm）"
    fi

    # ── 任务二：vLLM TP=2 ──────────────────────────────────────────────────
    if [ "${SKIP_TP2}" = false ]; then
        for runtime in kata runc; do
            for model in 08b 9b; do
                run_vllm_bench "${runtime}" "${model}" "2"
            done
        done
    else
        log_info "跳过 vLLM TP=2 测试（--skip-tp2）"
    fi

    # ── 任务三：vLLM TP=1 ──────────────────────────────────────────────────
    if [ "${SKIP_TP1}" = false ]; then
        for runtime in kata runc; do
            for model in 08b 9b; do
                run_vllm_bench "${runtime}" "${model}" "1"
            done
        done
    else
        log_info "跳过 vLLM TP=1 测试（--skip-tp1）"
    fi

    # ── 汇总 ───────────────────────────────────────────────────────────────
    print_summary
}

START_TIME=$(now_sec)
main "$@"
