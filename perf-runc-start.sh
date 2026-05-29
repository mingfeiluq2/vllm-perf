#!/bin/bash
set -euo pipefail

# ============================================================
# 配置
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
POD_YAML="${SCRIPT_DIR}/gpu-pod-runc.yaml"
POD_NAME="gpu-pod-runc"
PERF_DURATION=${PERF_DURATION:-30}          # perf 采样时长（秒），可通过环境变量覆盖
PERF_RECORD=${PERF_RECORD:-0}               # 是否做 perf record（1=是），默认只做 perf stat
LOG_DIR="${SCRIPT_DIR}/perf-logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="${LOG_DIR}/perf_${TIMESTAMP}.log"
CGROUP_ROOT=${CGROUP_ROOT:-/sys/fs/cgroup}

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
            printf '%s\n' "${path}"
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
# 清理函数
# ============================================================
cleanup() {
    echo "==> 清理 Pod: ${POD_NAME}"
    kubectl delete -f "${POD_YAML}" --ignore-not-found=true --wait=false 2>/dev/null || true
}
trap cleanup EXIT

# ============================================================
# 准备工作
# ============================================================
mkdir -p "${LOG_DIR}"

echo "==> $(date) 开始 perf 测量"
echo "    Pod: ${POD_NAME}"
echo "    采样时长: ${PERF_DURATION}s"
echo "    日志文件: ${LOG_FILE}"
echo ""

# 检查依赖
for cmd in kubectl perf; do
    if ! command -v $cmd &>/dev/null; then
        echo "错误: 缺少依赖命令 '$cmd'"
        exit 1
    fi
done

# 检查 perf 权限
if ! perf stat true 2>/dev/null; then
    echo "提示: perf 可能权限不足，请以 root 运行或调整 /proc/sys/kernel/perf_event_paranoid"
fi

# ============================================================
# 1. 启动 Pod
# ============================================================
echo "==> 启动 Pod"
kubectl apply -f "${POD_YAML}"

# 轮询等待 Running
echo -n "==> 等待 Pod 就绪"
for i in $(seq 1 120); do
    status=$(kubectl get pod "${POD_NAME}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
    if [ "$status" = "Running" ]; then
        echo ""
        echo "    Pod 已进入 Running 状态"
        break
    fi
    if [ "$i" -eq 120 ]; then
        echo ""
        echo "错误: Pod 在 120 秒内未进入 Running 状态，当前状态: ${status}"
        kubectl describe pod "${POD_NAME}" 2>/dev/null || true
        exit 1
    fi
    echo -n "."
    sleep 1
done

# ============================================================
# 2. 获取 Pod cgroup v2 路径
# ============================================================
echo ""
echo "==> 定位 Pod cgroup"

if [ ! -f "${CGROUP_ROOT}/cgroup.controllers" ]; then
    echo "错误: ${CGROUP_ROOT} 不是 cgroup v2 根目录，请确认系统使用 cgroup v2"
    exit 1
fi

pod_info=$(kubectl get pod "${POD_NAME}" -o jsonpath='{.metadata.uid}{" "}{.status.qosClass}' 2>/dev/null || true)
POD_UID="${pod_info%% *}"
QOS_CLASS="${pod_info##* }"
if [ -z "${POD_UID}" ] || [ -z "${QOS_CLASS}" ] || [ "${POD_UID}" = "${QOS_CLASS}" ]; then
    echo "错误: 无法获取 Pod UID/QoS，请检查 Pod 是否存在: ${POD_NAME}"
    exit 1
fi

CGROUP_PATH=$(get_pod_cgroup_path "${POD_UID}" "${QOS_CLASS}")
echo "    Pod UID: ${POD_UID}"
echo "    QoS: ${QOS_CLASS}"
echo "    Pod Cgroup: ${CGROUP_PATH}"

# ============================================================
# 3. 运行 perf
# ============================================================
echo ""
echo "============================================================"
echo "==> 开始 perf 测量（${PERF_DURATION}s）"
echo "============================================================"

# 输出到 stdout + 日志文件
exec > >(tee -a "${LOG_FILE}")
exec 2>&1

# perf stat — 基础计数器
echo ""
echo "--- perf stat ---"
sudo perf stat \
    -a \
    -e cycles,instructions,cache-references,cache-misses,branch-misses \
    -e context-switches,cpu-migrations,page-faults \
    --cgroup "${CGROUP_PATH}" \
    --timeout $((PERF_DURATION * 1000)) \
    2>&1 || echo "perf stat 失败（可能需要 root）"

# perf record — 采样调用栈（可选）
if [ "${PERF_RECORD}" = "1" ]; then
    echo ""
    echo "--- perf record ---"
    RECORD_FILE="${LOG_DIR}/perf_record_${TIMESTAMP}.data"
    sudo perf record \
        -a \
        -g \
        -e cycles \
        --cgroup "${CGROUP_PATH}" \
        -o "${RECORD_FILE}" \
        -- sleep "${PERF_DURATION}" \
        2>&1 || echo "perf record 失败（可能需要 root）"

    if [ -f "${RECORD_FILE}" ]; then
        echo "    record 数据已保存到: ${RECORD_FILE}"
    fi
fi

echo ""
echo "==> $(date) 测量完成"
echo "    日志已保存到: ${LOG_FILE}"
