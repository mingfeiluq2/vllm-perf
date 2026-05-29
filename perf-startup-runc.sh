#!/bin/bash
set -euo pipefail

# ============================================================
# 配置
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
POD_YAML="${SCRIPT_DIR}/gpu-pod-runc.yaml"
POD_NAME="gpu-pod-runc"
PERF_MODE=${PERF_MODE:-stat}
LOG_DIR="${SCRIPT_DIR}/perf-logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="${LOG_DIR}/perf_startup_${TIMESTAMP}.log"
STAT_OUTPUT="${LOG_DIR}/perf_startup_stat_${TIMESTAMP}.txt"
RECORD_FILE="${LOG_DIR}/perf_startup_record_${TIMESTAMP}.data"
VLLM_LOG="${LOG_DIR}/vllm_startup_${TIMESTAMP}.log"
CGROUP_ROOT=${CGROUP_ROOT:-/sys/fs/cgroup}
STARTUP_TIMEOUT=${STARTUP_TIMEOUT:-600}
MAIN_LOG_PID=""
PERF_STAT_PID=""
PERF_RECORD_PID=""


# ============================================================
# 清理函数
# ============================================================
cleanup() {
    echo ""
    echo "==> 清理中..."

    # 停止 kubectl logs
    [ -n "${MAIN_LOG_PID}" ] && kill "${MAIN_LOG_PID}" 2>/dev/null || true

    # 停止 perf（SIGINT 使 perf 输出结果后退出）
    [ -n "${PERF_STAT_PID}" ] && sudo kill -INT "${PERF_STAT_PID}" 2>/dev/null || true
    [ -n "${PERF_RECORD_PID}" ] && sudo kill -INT "${PERF_RECORD_PID}" 2>/dev/null || true

    # 等待 perf 子进程退出
    [ -n "${PERF_STAT_PID}" ] && wait "${PERF_STAT_PID}" 2>/dev/null || true
    [ -n "${PERF_RECORD_PID}" ] && wait "${PERF_RECORD_PID}" 2>/dev/null || true

    # 删除 Pod
    echo "==> 删除 Pod: ${POD_NAME}"
    kubectl delete -f "${POD_YAML}" --ignore-not-found=true --wait=false 2>/dev/null || true
}
trap cleanup EXIT

# ============================================================
# 计时工具 — 从 epoch 秒转为可读格式
# ============================================================
now_sec() {
    date +%s.%N
}

elapsed_since() {
    local start="$1"
    local end
    end=$(now_sec)
    printf "%.2f" "$(echo "${end} - ${start}" | bc -l 2>/dev/null || awk "BEGIN {printf \"%.2f\", ${end} - ${start}}")"
}

# ============================================================
# PID → Cgroup 反推
# ============================================================
get_container_pid() {
    local pod_name="$1"
    local sandbox_id
    sandbox_id=$(sudo crictl pods --name "${pod_name}" -q 2>/dev/null)
    if [ -z "${sandbox_id}" ]; then
        echo "错误: 未找到 Pod sandbox: ${pod_name}" >&2
        return 1
    fi

    local cid
    for cid in $(sudo crictl ps --pod "${sandbox_id}" --state Running -q 2>/dev/null); do
        local pid
        pid=$(sudo crictl inspect "${cid}" 2>/dev/null | sed -n 's/.*"pid": \([0-9]\+\).*/\1/p' | head -1)
        if [ -n "${pid}" ] && [ "${pid}" -gt 1 ] && [ -d "/proc/${pid}" ]; then
            local cname
            cname=$(sudo crictl inspect "${cid}" 2>/dev/null | sed -n 's/.*"name": "\([^"]*\)".*/\1/p' | head -1)
            if [ "${cname}" = "cuda-container" ]; then
                printf '%s\n' "${pid}"
                return 0
            fi
        fi
    done

    echo "错误: 未找到运行中容器的 PID" >&2
    return 1
}

get_pod_cgroup_from_pid() {
    local pid="$1"
    local cgroup_line
    cgroup_line=$(grep '^0::' "/proc/${pid}/cgroup" 2>/dev/null | head -1)
    if [ -z "${cgroup_line}" ]; then
        echo "错误: 无法读取 /proc/${pid}/cgroup 或非 cgroup v2" >&2
        return 1
    fi

    local full_path="${cgroup_line#0::}"
    if [ -z "${full_path}" ] || [ "${full_path}" = "${cgroup_line}" ]; then
        echo "错误: 意外的 cgroup 格式: ${cgroup_line}" >&2
        return 1
    fi

    dirname "${full_path}"
}

# ============================================================
# 准备工作
# ============================================================
mkdir -p "${LOG_DIR}"

echo "==> $(date) 开始 vLLM 启动性能测量"
echo "    Pod: ${POD_NAME}"
echo "    Perf 模式: ${PERF_MODE}"
echo "    日志文件: ${LOG_FILE}"
echo ""

# 检查依赖
for cmd in kubectl crictl curl perf; do
    if ! command -v $cmd &>/dev/null; then
        echo "错误: 缺少依赖命令 '$cmd'"
        exit 1
    fi
done

# 检查 sudo 无密码访问
if ! sudo -n true 2>/dev/null; then
    echo "错误: sudo 需要无密码访问（用于 crictl / perf）"
    exit 1
fi

# 验证 PERF_MODE
case "${PERF_MODE}" in
    stat|record|all) ;;
    *) echo "错误: 无效的 PERF_MODE '${PERF_MODE}'，可选: stat / record / all"; exit 1 ;;
esac

# 检查 cgroup v2
if [ ! -f "${CGROUP_ROOT}/cgroup.controllers" ]; then
    echo "错误: ${CGROUP_ROOT} 不是 cgroup v2 根目录"
    exit 1
fi

# 检查 perf 权限
if ! perf stat true 2>/dev/null; then
    echo "提示: perf 可能权限不足，请以 root 运行或调整 /proc/sys/kernel/perf_event_paranoid"
fi

# 输出到 stdout + 日志文件
exec > >(tee -a "${LOG_FILE}")
exec 2>&1

# ============================================================
# 阶段 1: K8s 调度（分解为 3 个子阶段）
# ============================================================
T_APPLY=$(now_sec)
echo "==> [T_apply] 启动 Pod"
if [ ! -f "${POD_YAML}" ]; then
    echo "错误: Pod YAML 文件不存在: ${POD_YAML}"
    exit 1
fi
kubectl apply -f "${POD_YAML}"

# 子阶段 1: API 提交 (apply → Pod 对象可见)
echo -n "==> [子阶段1] 等待 Pod 对象创建"
for i in $(seq 1 60); do
    if kubectl get pod "${POD_NAME}" -o name &>/dev/null; then
        T_CREATED=$(now_sec)
        SUB1_TIME=$(elapsed_since "${T_APPLY}")
        echo ""
        echo "    Pod 对象已创建: ${SUB1_TIME}s"
        break
    fi
    if [ "$i" -eq 60 ]; then
        echo ""
        echo "错误: Pod 在 60s 内未创建"
        exit 1
    fi
    echo -n "."
    sleep 1
done

# 子阶段 2: 调度分配 (Pod 可见 → 节点已分配)
echo -n "==> [子阶段2] 等待调度分配节点"
for i in $(seq 1 60); do
    node=$(kubectl get pod "${POD_NAME}" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)
    if [ -n "${node}" ]; then
        T_SCHEDULED=$(now_sec)
        SUB2_TIME=$(elapsed_since "${T_CREATED}")
        echo ""
        echo "    已分配到节点 ${node}: ${SUB2_TIME}s"
        break
    fi
    if [ "$i" -eq 60 ]; then
        echo ""
        echo "错误: Pod 在 60s 内未被调度"
        kubectl describe pod "${POD_NAME}" 2>/dev/null || true
        exit 1
    fi
    echo -n "."
    sleep 1
done

# 子阶段 3: 容器启动 (节点已分配 → Pod Running)
echo -n "==> [子阶段3] 等待容器启动"
for i in $(seq 1 300); do
    status=$(kubectl get pod "${POD_NAME}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
    if [ "$status" = "Running" ]; then
        T_RUNNING=$(now_sec)
        SUB3_TIME=$(elapsed_since "${T_SCHEDULED}")
        echo ""
        echo "    Pod 已 Running: ${SUB3_TIME}s"
        break
    fi
    if [ "$i" -eq 300 ]; then
        echo ""
        echo "错误: Pod 在 300s 内未进入 Running，当前状态: ${status}"
        kubectl describe pod "${POD_NAME}" 2>/dev/null || true
        exit 1
    fi
    echo -n "."
    sleep 1
done

K8S_TOTAL=$(elapsed_since "${T_APPLY}")

# ============================================================
# 阶段 2 准备: 获取 PID、cgroup、启动日志
# ============================================================
echo ""
echo "==> 获取容器 PID"
CONTAINER_PID=$(get_container_pid "${POD_NAME}")
echo "    容器 PID: ${CONTAINER_PID}"

echo "==> 获取 Pod IP"
POD_IP=$(kubectl get pod "${POD_NAME}" -o jsonpath='{.status.podIP}' 2>/dev/null)
if [ -z "${POD_IP}" ]; then
    echo "错误: 无法获取 Pod IP"
    exit 1
fi
echo "    Pod IP: ${POD_IP}"

echo "==> PID → Cgroup 反推"
CGROUP_PATH=$(get_pod_cgroup_from_pid "${CONTAINER_PID}")
CGROUP_FULL="${CGROUP_ROOT}${CGROUP_PATH}"
echo "    原始 cgroup 行: $(cat /proc/${CONTAINER_PID}/cgroup)"
echo "    反推结果: ${CGROUP_PATH}"

if [ ! -d "${CGROUP_FULL}" ]; then
    echo "错误: cgroup 路径不存在: ${CGROUP_FULL}"
    exit 1
fi
echo "    cgroup 路径已验证: ${CGROUP_FULL}"

echo "==> 启动 vLLM 日志捕获"
kubectl logs -f "${POD_NAME}" -c cuda-container > "${VLLM_LOG}" 2>&1 &
MAIN_LOG_PID=$!
echo "    日志 PID: ${MAIN_LOG_PID}"
echo "    日志文件: ${VLLM_LOG}"

# ============================================================
# 阶段 2: 启动 perf 并按模式选择 stat / record
# ============================================================
echo ""
echo "==> 启动 perf 测量"
echo "    模式: ${PERF_MODE}"
echo "    注意: perf 测量起点为 cgroup 解析完成后，K8s 调度阶段不在覆盖范围"
echo ""

start_perf_stat() {
    echo "--- 启动 perf stat ---"
    sudo perf stat \
        -a \
        -e cycles,instructions,cache-references,cache-misses,branch-misses \
        -e context-switches,cpu-migrations,page-faults \
        --cgroup "${CGROUP_PATH}" \
        -o "${STAT_OUTPUT}" \
        --timeout $((STARTUP_TIMEOUT * 1000)) &
    PERF_STAT_PID=$!
    sleep 0.5
    if ! ps -p "${PERF_STAT_PID}" >/dev/null 2>&1; then
        echo "警告: perf stat 可能启动失败"
    else
        echo "    perf stat PID: ${PERF_STAT_PID}"
    fi
}

start_perf_record() {
    echo "--- 启动 perf record ---"
    sudo perf record \
        -a -g \
        -e cycles \
        --cgroup "${CGROUP_PATH}" \
        -o "${RECORD_FILE}" \
        --timeout $((STARTUP_TIMEOUT * 1000)) &
    PERF_RECORD_PID=$!
    sleep 0.5
    if ! ps -p "${PERF_RECORD_PID}" >/dev/null 2>&1; then
        echo "警告: perf record 可能启动失败"
    else
        echo "    perf record PID: ${PERF_RECORD_PID}"
    fi
}

case "${PERF_MODE}" in
    stat)
        start_perf_stat
        ;;
    record)
        start_perf_record
        ;;
    all)
        start_perf_stat
        start_perf_record
        ;;
esac

# ============================================================
# 阶段 2 继续: vLLM 就绪检测
# ============================================================
echo ""
echo "==> 等待 vLLM 服务就绪 (curl http://${POD_IP}:8000/health)"
HEALTH_START=$(now_sec)
while true; do
    elapsed=$(elapsed_since "${HEALTH_START}")
    if [ "$(printf '%.0f' "${elapsed}")" -ge "${STARTUP_TIMEOUT}" ]; then
        echo ""
        echo "错误: vLLM 在 ${STARTUP_TIMEOUT}s 内未就绪"
        echo "最后几行日志:"
        tail -20 "${VLLM_LOG}" 2>/dev/null || true
        exit 1
    fi

    if curl -s --fail --max-time 3 "http://${POD_IP}:8000/health" >/dev/null 2>&1; then
        T_READY=$(now_sec)
        echo ""
        echo "    vLLM 服务已就绪!"
        break
    fi
    echo -n "."
    sleep 2
done

SUB4_TIME=$(elapsed_since "${T_RUNNING}")
TOTAL_TIME=$(elapsed_since "${T_APPLY}")

echo ""
echo "==> 停止 perf 测量"
# SIGINT 使 perf 输出结果后优雅退出
[ -n "${PERF_STAT_PID}" ] && sudo kill -INT "${PERF_STAT_PID}" 2>/dev/null || true
[ -n "${PERF_RECORD_PID}" ] && sudo kill -INT "${PERF_RECORD_PID}" 2>/dev/null || true

# 等待 perf 进程退出
[ -n "${PERF_STAT_PID}" ] && wait "${PERF_STAT_PID}" 2>/dev/null || true
[ -n "${PERF_RECORD_PID}" ] && wait "${PERF_RECORD_PID}" 2>/dev/null || true

# 停止日志捕获
[ -n "${MAIN_LOG_PID}" ] && kill "${MAIN_LOG_PID}" 2>/dev/null || true

echo ""
echo "============================================================"
echo "==> 启动耗时分解"
echo "============================================================"
echo ""
echo "--- K8s 调度子阶段 ---"
echo "  1. API 提交:      ${SUB1_TIME}s"
echo "  2. 调度分配:      ${SUB2_TIME}s"
echo "  3. 容器启动:      ${SUB3_TIME}s"
echo "  K8s 调度合计:     ${K8S_TOTAL}s"
echo ""
echo "--- vLLM 就绪阶段 ---"
echo "  4. vLLM 就绪:     ${SUB4_TIME}s"
echo ""
echo "--- 总计 ---"
echo "  总启动时间:       ${TOTAL_TIME}s"
echo ""

# perf stat 结果
if [ "${PERF_MODE}" = "stat" ] || [ "${PERF_MODE}" = "all" ]; then
    echo "--- perf stat 结果 ---"
    if [ -f "${STAT_OUTPUT}" ]; then
        cat "${STAT_OUTPUT}"
        echo ""
        # 提取关键指标
        echo "--- 关键指标摘要 ---"
        grep -E "seconds time elapsed|instructions|cycles|cache-misses|branch-misses|cpu-migrations" "${STAT_OUTPUT}" 2>/dev/null || true
    else
        echo "    (perf stat 输出文件未生成)"
    fi
    echo ""
fi

# perf record 结果
if [ "${PERF_MODE}" = "record" ] || [ "${PERF_MODE}" = "all" ]; then
    echo "--- perf record 结果 ---"
    if [ -f "${RECORD_FILE}" ]; then
        echo "    record 数据已保存到: ${RECORD_FILE}"
        RECORD_SIZE=$(du -h "${RECORD_FILE}" 2>/dev/null | cut -f1)
        echo "    文件大小: ${RECORD_SIZE}"
    else
        echo "    (perf record 数据文件未生成)"
    fi
    echo ""
fi

echo "--- 输出文件 ---"
echo "  完整日志:   ${LOG_FILE}"
echo "  启动日志:   ${VLLM_LOG}"
echo "  perf stat:  ${STAT_OUTPUT}"
echo "  perf record: ${RECORD_FILE}"
echo ""
echo "==> $(date) 测量完成"
