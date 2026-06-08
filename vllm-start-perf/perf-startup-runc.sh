#!/bin/bash
set -euo pipefail

# ============================================================
# 配置
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

read_first_config_value() {
    local file="$1"
    local default_value="$2"
    local value=""

    if [ -f "${file}" ]; then
        value=$(sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "${file}" | head -n 1)
    fi

    if [ -n "${value}" ]; then
        printf '%s\n' "${value}"
    else
        printf '%s\n' "${default_value}"
    fi
}

POD_YAML=${POD_YAML:-"${REPO_ROOT}/gpu-pod-runc.yaml"}
POD_NAME="gpu-pod-runc"
CONTAINER_NAME=${CONTAINER_NAME:-cuda-container}
PERF_MODE_FILE="${SCRIPT_DIR}/perf-startup-runc-mode"
PERF_STAT_EVENTS_FILE="${SCRIPT_DIR}/perf-startup-runc-stat-events"
PERF_RECORD_EVENT_FILE="${SCRIPT_DIR}/perf-startup-runc-record-event"
DEFAULT_PERF_MODE=$(read_first_config_value "${PERF_MODE_FILE}" "record")
DEFAULT_PERF_STAT_EVENTS=$(read_first_config_value "${PERF_STAT_EVENTS_FILE}" "cycles,instructions,cache-references,cache-misses,branch-misses,context-switches,cpu-migrations,page-faults")
DEFAULT_PERF_RECORD_EVENT=$(read_first_config_value "${PERF_RECORD_EVENT_FILE}" "cycles")
PERF_MODE=${PERF_MODE:-${DEFAULT_PERF_MODE}}
PERF_STAT_EVENTS=${PERF_STAT_EVENTS:-${DEFAULT_PERF_STAT_EVENTS}}
PERF_RECORD_EVENT=${PERF_RECORD_EVENT:-${DEFAULT_PERF_RECORD_EVENT}}
LOG_DIR="${SCRIPT_DIR}/perf-logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="${LOG_DIR}/perf_startup_runc_${TIMESTAMP}.log"
TIMEPOINTS_FILE="${LOG_DIR}/timepoints_startup_runc_${TIMESTAMP}.tsv"
STAT_OUTPUT="${LOG_DIR}/perf_startup_runc_stat_${TIMESTAMP}.txt"
RECORD_FILE="${LOG_DIR}/perf_startup_runc_record_${TIMESTAMP}.data"
VLLM_LOG="${LOG_DIR}/vllm_startup_runc_${TIMESTAMP}.log"
CGROUP_ROOT=${CGROUP_ROOT:-/sys/fs/cgroup}
STARTUP_TIMEOUT=${STARTUP_TIMEOUT:-600}
KEEP_POD=${KEEP_POD:-0}
KEEP_POD_ON_ERROR=${KEEP_POD_ON_ERROR:-1}
MAIN_LOG_PID=""
PERF_STAT_PID=""
PERF_RECORD_PID=""
SCRIPT_START_TIME=""


# ============================================================
# 清理函数
# ============================================================
cleanup() {
    local status=$?
    set +e

    echo ""
    echo "==> 清理中..."

    # 停止 kubectl logs
    [ -n "${MAIN_LOG_PID}" ] && kill "${MAIN_LOG_PID}" 2>/dev/null || true

    stop_perf

    if [ "${KEEP_POD}" = "1" ] || { [ "${status}" -ne 0 ] && [ "${KEEP_POD_ON_ERROR}" = "1" ]; }; then
        echo "==> 保留 Pod: ${POD_NAME}"
        echo "    退出状态: ${status}，可用 KEEP_POD=0 KEEP_POD_ON_ERROR=0 恢复失败时自动删除"
    else
        # 删除 Pod
        echo "==> 删除 Pod: ${POD_NAME}"
        kubectl delete -f "${POD_YAML}" --ignore-not-found=true --wait=false 2>/dev/null || true
    fi

    return "${status}" 2>/dev/null || exit "${status}"
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
    printf "%.2f" "$(awk "BEGIN {printf \"%.2f\", $(now_sec) - ${start}}")"
}

duration_between() {
    local start="$1"
    local end="$2"

    if [ -z "${start}" ] || [ -z "${end}" ]; then
        printf "N/A"
        return 0
    fi

    awk -v start="${start}" -v end="${end}" 'BEGIN {
        if (end < start) {
            printf "N/A"
        } else {
            printf "%.2f", end - start
        }
    }'
}

record_timepoint() {
    local key="$1"
    local description="$2"
    local epoch
    local elapsed
    local local_time

    epoch=$(now_sec)
    elapsed=$(duration_between "${SCRIPT_START_TIME}" "${epoch}")
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
    printf "  %-28s %-12s %-26s %s\n" "key" "elapsed(s)" "local_time" "description"

    while IFS=$'\t' read -r key epoch elapsed local_time description; do
        [ "${key}" = "key" ] && continue
        printf "  %-28s %-12s %-26s %s\n" "${key}" "${elapsed}" "${local_time}" "${description}"
    done < "${TIMEPOINTS_FILE}"

    echo ""
}

stop_perf() {
    [ -n "${PERF_STAT_PID}" ] && sudo kill -INT "${PERF_STAT_PID}" 2>/dev/null || true
    [ -n "${PERF_RECORD_PID}" ] && sudo kill -INT "${PERF_RECORD_PID}" 2>/dev/null || true
    [ -n "${PERF_STAT_PID}" ] && wait "${PERF_STAT_PID}" 2>/dev/null || true
    [ -n "${PERF_RECORD_PID}" ] && wait "${PERF_RECORD_PID}" 2>/dev/null || true
}

pod_event_seen() {
    local reason="$1"
    local field_selector="involvedObject.kind=Pod,involvedObject.name=${POD_NAME}"
    local event_name

    if [ -n "${POD_UID:-}" ]; then
        field_selector="${field_selector},involvedObject.uid=${POD_UID}"
    fi

    event_name=$(kubectl get events \
        --field-selector "${field_selector}" \
        -o "jsonpath={range .items[?(@.reason==\"${reason}\")]}{.metadata.name}{\"\\n\"}{end}" \
        2>/dev/null | head -1 || true)

    [ -n "${event_name}" ]
}

poll_runtime_events() {
    if [ -z "${T_PULLED}" ] && pod_event_seen "Pulled"; then
        T_PULLED=$(now_sec)
        record_timepoint "event_pulled" "Kubernetes 事件 Pulled"
    fi

    if [ -z "${T_CONTAINER_CREATED}" ] && pod_event_seen "Created"; then
        T_CONTAINER_CREATED=$(now_sec)
        record_timepoint "event_container_created" "Kubernetes 事件 Created"
    fi

    if [ -z "${T_CONTAINER_STARTED}" ] && pod_event_seen "Started"; then
        T_CONTAINER_STARTED=$(now_sec)
        record_timepoint "event_container_started" "Kubernetes 事件 Started"
    fi
}

# ============================================================
# Pod UID/QoS → cgroup 路径
# ============================================================
get_pod_cgroup_path() {
    local pod_uid="$1"
    local qos_class="$2"
    local pod_uid_systemd="${pod_uid//-/_}"
    local systemd_path=""
    local cgroupfs_path=""

    case "${qos_class}" in
        Guaranteed)
            systemd_path="/kubepods.slice/kubepods-pod${pod_uid_systemd}.slice"
            cgroupfs_path="/kubepods/pod${pod_uid}"
            ;;
        Burstable)
            systemd_path="/kubepods.slice/kubepods-burstable.slice/kubepods-burstable-pod${pod_uid_systemd}.slice"
            cgroupfs_path="/kubepods/burstable/pod${pod_uid}"
            ;;
        BestEffort)
            systemd_path="/kubepods.slice/kubepods-besteffort.slice/kubepods-besteffort-pod${pod_uid_systemd}.slice"
            cgroupfs_path="/kubepods/besteffort/pod${pod_uid}"
            ;;
        *)
            echo "错误: 无法识别 Pod QoS: ${qos_class}" >&2
            return 1
            ;;
    esac

    for path in "${systemd_path}" "${cgroupfs_path}"; do
        if [ -d "${CGROUP_ROOT}${path}" ]; then
            echo "${path}"
            return 0
        fi
    done

    echo "错误: 未找到 Pod cgroup" >&2
    echo "    Pod UID: ${pod_uid}" >&2
    echo "    QoS: ${qos_class}" >&2
    echo "    尝试路径:" >&2
    echo "      ${CGROUP_ROOT}${systemd_path}" >&2
    echo "      ${CGROUP_ROOT}${cgroupfs_path}" >&2
    return 1
}

# ============================================================
# 准备工作
# ============================================================
mkdir -p "${LOG_DIR}"
SCRIPT_START_TIME=$(now_sec)
printf "key\tepoch\telapsed_since_start_sec\tlocal_time\tdescription\n" > "${TIMEPOINTS_FILE}"
record_timepoint "script_start" "脚本开始"

echo "==> $(date) 开始 vLLM 启动性能测量"
echo "    Pod: ${POD_NAME}"
echo "    Pod YAML: ${POD_YAML}"
echo "    Perf 模式: ${PERF_MODE}"
echo "    Perf 模式配置: ${PERF_MODE_FILE}"
echo "    Perf stat 事件配置: ${PERF_STAT_EVENTS_FILE}"
echo "    Perf record 事件配置: ${PERF_RECORD_EVENT_FILE}"
echo "    日志文件: ${LOG_FILE}"
echo ""

# 验证 PERF_MODE
case "${PERF_MODE}" in
    stat|record|all)
        PERF_ENABLED=1
        ;;
    none)
        PERF_ENABLED=0
        ;;
    *) echo "错误: 无效的 PERF_MODE '${PERF_MODE}'，可选: stat / record / all / none"; exit 1 ;;
esac

# 检查依赖
REQUIRED_CMDS="kubectl curl"
if [ "${PERF_ENABLED}" = "1" ]; then
    REQUIRED_CMDS="${REQUIRED_CMDS} perf sudo"
fi

for cmd in ${REQUIRED_CMDS}; do
    if ! command -v $cmd &>/dev/null; then
        echo "错误: 缺少依赖命令 '$cmd'"
        exit 1
    fi
done

if [ "${PERF_ENABLED}" = "1" ]; then
    # 检查 sudo 无密码访问
    if ! sudo -n true 2>/dev/null; then
        echo "错误: sudo 需要无密码访问（用于 perf）"
        exit 1
    fi

    # 检查 cgroup v2
    if [ ! -f "${CGROUP_ROOT}/cgroup.controllers" ]; then
        echo "错误: ${CGROUP_ROOT} 不是 cgroup v2 根目录"
        exit 1
    fi

    # 检查 perf 权限
    if ! perf stat true 2>/dev/null; then
        echo "提示: perf 可能权限不足，请以 root 运行或调整 /proc/sys/kernel/perf_event_paranoid"
    fi
fi

# 输出到 stdout + 日志文件
exec > >(tee -a "${LOG_FILE}")
exec 2>&1

# ============================================================
# 阶段 1: API / Scheduler
# ============================================================
T_APPLY=$(now_sec)
record_timepoint "pod_apply_start" "开始 kubectl apply"
echo "==> [T_apply] 启动 Pod"
if [ ! -f "${POD_YAML}" ]; then
    echo "错误: Pod YAML 文件不存在: ${POD_YAML}"
    exit 1
fi
kubectl apply -f "${POD_YAML}"

# 1. Pod 对象创建 (kubectl apply → Pod visible)
echo -n "==> [1] 等待 Pod 对象创建"
for i in $(seq 1 60); do
    if kubectl get pod "${POD_NAME}" -o name &>/dev/null; then
        T_CREATED=$(now_sec)
        POD_UID=$(kubectl get pod "${POD_NAME}" -o jsonpath='{.metadata.uid}' 2>/dev/null || true)
        if [ -z "${POD_UID}" ]; then
            echo ""
            echo "错误: 无法获取 Pod UID，请检查 Pod 是否存在: ${POD_NAME}"
            exit 1
        fi
        SUB1_TIME=$(elapsed_since "${T_APPLY}")
        echo ""
        echo "    Pod 对象已创建: ${SUB1_TIME}s"
        record_timepoint "pod_visible" "Pod 对象可见"
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

# 2. Scheduler 绑定 (Pod visible → spec.nodeName/Scheduled)
echo -n "==> [2] 等待 Scheduler 绑定"
for i in $(seq 1 60); do
    node=$(kubectl get pod "${POD_NAME}" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)
    if [ -n "${node}" ]; then
        T_SCHEDULED=$(now_sec)
        SUB2_TIME=$(elapsed_since "${T_CREATED}")
        echo ""
        echo "    已分配到节点 ${node}: ${SUB2_TIME}s"
        record_timepoint "pod_scheduled" "Pod 已调度到节点 ${node}"
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

# 3. Node / Runtime 阶段 (Scheduled → Pod Running)
T_PULLED=""
T_CONTAINER_CREATED=""
T_CONTAINER_STARTED=""
echo -n "==> [3] 等待节点侧 Pod 启动"
for i in $(seq 1 300); do
    poll_runtime_events
    status=$(kubectl get pod "${POD_NAME}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
    if [ "$status" = "Running" ]; then
        T_RUNNING=$(now_sec)
        SUB3_TIME=$(elapsed_since "${T_SCHEDULED}")
        echo ""
        echo "    Pod 已 Running: ${SUB3_TIME}s"
        record_timepoint "pod_running" "Pod phase 为 Running"
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
SUB3_1_TIME=$(duration_between "${T_SCHEDULED}" "${T_PULLED}")
SUB3_2_TIME=$(duration_between "${T_PULLED}" "${T_CONTAINER_CREATED}")
SUB3_3_TIME=$(duration_between "${T_CONTAINER_CREATED}" "${T_CONTAINER_STARTED}")
SUB3_4_TIME=$(duration_between "${T_CONTAINER_STARTED}" "${T_RUNNING}")

# ============================================================
# 阶段 2 准备: 获取 cgroup、Pod IP、启动日志
# ============================================================
echo ""
if [ "${PERF_ENABLED}" = "1" ]; then
    echo "==> 定位 Pod cgroup"
    record_timepoint "cgroup_lookup_start" "开始定位 Pod cgroup"
    QOS_CLASS=$(kubectl get pod "${POD_NAME}" -o jsonpath='{.status.qosClass}' 2>/dev/null || true)
    if [ -z "${POD_UID}" ] || [ -z "${QOS_CLASS}" ]; then
        echo "错误: 无法获取 Pod UID/QoS，请检查 Pod 是否存在: ${POD_NAME}"
        exit 1
    fi

    CGROUP_PATH=$(get_pod_cgroup_path "${POD_UID}" "${QOS_CLASS}")
    CGROUP_FULL="${CGROUP_ROOT}${CGROUP_PATH}"
    echo "    Pod UID: ${POD_UID}"
    echo "    QoS: ${QOS_CLASS}"
    echo "    cgroup 路径: ${CGROUP_PATH}"
    record_timepoint "cgroup_lookup_done" "Pod cgroup 已定位: ${CGROUP_PATH}"
else
    echo "==> 跳过 Pod cgroup 定位: PERF_MODE=none"
fi

echo "==> 获取 Pod IP"
POD_IP=$(kubectl get pod "${POD_NAME}" -o jsonpath='{.status.podIP}' 2>/dev/null)
if [ -z "${POD_IP}" ]; then
    echo "错误: 无法获取 Pod IP"
    exit 1
fi
echo "    Pod IP: ${POD_IP}"
record_timepoint "pod_ip_ready" "获取 Pod IP: ${POD_IP}"

if [ "${PERF_ENABLED}" = "1" ]; then
    if [ ! -d "${CGROUP_FULL}" ]; then
        echo "错误: cgroup 路径不存在: ${CGROUP_FULL}"
        exit 1
    fi
    echo "    cgroup 路径已验证: ${CGROUP_FULL}"
fi

echo "==> 启动 vLLM 日志捕获"
kubectl logs -f "${POD_NAME}" -c "${CONTAINER_NAME}" > "${VLLM_LOG}" 2>&1 &
MAIN_LOG_PID=$!
echo "    日志 PID: ${MAIN_LOG_PID}"
echo "    日志文件: ${VLLM_LOG}"
record_timepoint "vllm_log_follow_start" "开始 kubectl logs -f"

# ============================================================
# 阶段 2: 启动 perf 并按模式选择 stat / record
# ============================================================
echo ""
if [ "${PERF_ENABLED}" = "1" ]; then
    echo "==> 启动 perf 测量"
    echo "    模式: ${PERF_MODE}"
    echo "    注意: perf 测量起点为 cgroup 解析完成后，K8s 调度阶段不在覆盖范围"
    echo ""
else
    echo "==> 跳过 perf 测量: PERF_MODE=none"
    echo ""
fi

start_perf_stat() {
    echo "--- 启动 perf stat ---"
    echo "    事件: ${PERF_STAT_EVENTS}"
    sudo perf stat \
        -a \
        -e "${PERF_STAT_EVENTS}" \
        --cgroup "${CGROUP_PATH}" \
        -o "${STAT_OUTPUT}" &
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
    echo "    事件: ${PERF_RECORD_EVENT}"
    sudo perf record \
        -a -g \
        -e "${PERF_RECORD_EVENT}" \
        --cgroup "${CGROUP_PATH}" \
        -o "${RECORD_FILE}" &
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
        record_timepoint "perf_start" "开始 perf stat 测量"
        start_perf_stat
        ;;
    record)
        record_timepoint "perf_start" "开始 perf record 测量"
        start_perf_record
        ;;
    all)
        record_timepoint "perf_start" "开始 perf all 测量"
        start_perf_stat
        start_perf_record
        ;;
    none)
        ;;
esac

# ============================================================
# 阶段 2 继续: vLLM 就绪检测
# ============================================================
echo ""
echo "==> 等待 vLLM 服务就绪 (curl --noproxy '*' -s --fail --max-time 3 http://${POD_IP}:8000/health)"
HEALTH_START=$(now_sec)
record_timepoint "health_wait_start" "开始等待 /health"
while true; do
    elapsed=$(elapsed_since "${HEALTH_START}")
    if [ "$(printf '%.0f' "${elapsed}")" -ge "${STARTUP_TIMEOUT}" ]; then
        echo ""
        echo "错误: vLLM 在 ${STARTUP_TIMEOUT}s 内未就绪"
        echo "最后几行日志:"
        tail -20 "${VLLM_LOG}" 2>/dev/null || true
        exit 1
    fi

    if curl --noproxy '*' -s --fail --max-time 3 "http://${POD_IP}:8000/health" >/dev/null 2>&1; then
        T_READY=$(now_sec)
        echo ""
        echo "    vLLM 服务已就绪!"
        record_timepoint "vllm_ready" "vLLM /health 返回成功"
        break
    fi
    echo -n "."
    sleep 2
done

SUB4_TIME=$(elapsed_since "${T_RUNNING}")
TOTAL_TIME=$(elapsed_since "${T_APPLY}")

echo ""
if [ "${PERF_ENABLED}" = "1" ]; then
    echo "==> 停止 perf 测量"
    stop_perf
    record_timepoint "perf_stop" "停止 perf ${PERF_MODE} 测量"
else
    echo "==> 跳过停止 perf 测量: PERF_MODE=none"
fi

# 停止日志捕获
[ -n "${MAIN_LOG_PID}" ] && kill "${MAIN_LOG_PID}" 2>/dev/null || true
record_timepoint "script_end" "脚本主流程结束"

echo ""
echo "============================================================"
echo "==> 启动耗时分解"
echo "============================================================"
echo ""
echo "--- API / Scheduler 阶段 ---"
echo "  1. Pod 对象创建:              ${SUB1_TIME}s  kubectl apply -> Pod visible"
echo "  2. Scheduler 绑定:            ${SUB2_TIME}s  Pod visible -> spec.nodeName/Scheduled"
echo ""
echo "--- Node / Runtime 阶段 ---"
echo "  3. 节点侧 Pod 启动总耗时:      ${SUB3_TIME}s  Scheduled -> Pod Running"
echo "     3.1 Scheduled -> Pulled:    ${SUB3_1_TIME}s  kubelet 接收、CreatePodSandbox、runC、CNI、镜像检查"
echo "     3.2 Pulled -> Created:      ${SUB3_2_TIME}s  CreateContainer"
echo "     3.3 Created -> Started:     ${SUB3_3_TIME}s  StartContainer"
echo "     3.4 Started -> Running:     ${SUB3_4_TIME}s  kubelet 状态上报 / Pod phase 更新"
echo ""
echo "--- App 阶段 ---"
echo "  4. vLLM 就绪:                 ${SUB4_TIME}s  Pod Running -> /health OK"
echo ""
echo "--- 总计 ---"
echo "  总启动时间:       ${TOTAL_TIME}s"
echo "  K8s+Runtime:      ${K8S_TOTAL}s"
echo ""

print_timepoints_summary

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
echo "  时间点 TSV: ${TIMEPOINTS_FILE}"
echo "  启动日志:   ${VLLM_LOG}"
if [ "${PERF_MODE}" = "stat" ] || [ "${PERF_MODE}" = "all" ]; then
    echo "  perf stat:  ${STAT_OUTPUT}"
fi
if [ "${PERF_MODE}" = "record" ] || [ "${PERF_MODE}" = "all" ]; then
    echo "  perf record: ${RECORD_FILE}"
elif [ "${PERF_MODE}" = "stat" ]; then
    echo "  perf record: 未启用（使用 PERF_MODE=record 或 PERF_MODE=all 生成 .data）"
else
    echo "  perf:        未启用（PERF_MODE=none）"
fi
echo ""
echo "==> $(date) 测量完成"
