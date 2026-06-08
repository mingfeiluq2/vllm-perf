#!/bin/bash

# Common implementation for perf-bench-kata.sh and perf-bench-runc.sh.
# Entry scripts set runtime-specific variables before sourcing this file.

SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
REPO_ROOT="${REPO_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}"

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

trim_whitespace() {
    sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

strip_matching_quotes() {
    local value="$1"

    if [ "${#value}" -ge 2 ]; then
        if { [ "${value:0:1}" = '"' ] && [ "${value: -1}" = '"' ]; } ||
            { [ "${value:0:1}" = "'" ] && [ "${value: -1}" = "'" ]; }; then
            value="${value:1:${#value}-2}"
        fi
    fi

    printf '%s\n' "${value}"
}

load_bench_config() {
    local file="$1"
    local line=""
    local key=""
    local value=""

    if [ ! -f "${file}" ]; then
        return 0
    fi

    while IFS= read -r line || [ -n "${line}" ]; do
        line=$(printf '%s' "${line}" | trim_whitespace)

        [ -z "${line}" ] && continue
        case "${line}" in
            \#*) continue ;;
        esac

        if [ "${line#*=}" = "${line}" ]; then
            echo "警告: 忽略无效 benchmark 配置行: ${line}" >&2
            continue
        fi

        key=$(printf '%s' "${line%%=*}" | trim_whitespace)
        value=$(printf '%s' "${line#*=}" | trim_whitespace)
        value=$(strip_matching_quotes "${value}")

        case "${key}" in
            BENCH_BACKEND) CONFIG_BENCH_BACKEND="${value}" ;;
            BENCH_MODEL) CONFIG_BENCH_MODEL="${value}" ;;
            BENCH_TOKENIZER) CONFIG_BENCH_TOKENIZER="${value}" ;;
            BENCH_DATASET_NAME) CONFIG_BENCH_DATASET_NAME="${value}" ;;
            BENCH_INPUT_LEN) CONFIG_BENCH_INPUT_LEN="${value}" ;;
            BENCH_OUTPUT_LEN) CONFIG_BENCH_OUTPUT_LEN="${value}" ;;
            BENCH_NUM_PROMPTS) CONFIG_BENCH_NUM_PROMPTS="${value}" ;;
            BENCH_REQUEST_RATE) CONFIG_BENCH_REQUEST_RATE="${value}" ;;
            BENCH_MAX_CONCURRENCY) CONFIG_BENCH_MAX_CONCURRENCY="${value}" ;;
            BENCH_ENDPOINT) CONFIG_BENCH_ENDPOINT="${value}" ;;
            BENCH_PORT) CONFIG_BENCH_PORT="${value}" ;;
            BENCH_NO_PROXY) CONFIG_BENCH_NO_PROXY="${value}" ;;
            *) echo "警告: 忽略未知 benchmark 配置项: ${key}" >&2 ;;
        esac
    done < "${file}"
}

require_non_empty() {
    local name="$1"
    local value="${!name}"

    if [ -z "${value}" ]; then
        echo "错误: ${name} 不能为空"
        exit 1
    fi
}

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
    if [ -n "${PERF_STAT_PID}" ]; then
        sudo kill -INT "${PERF_STAT_PID}" 2>/dev/null || true
        wait "${PERF_STAT_PID}" 2>/dev/null || true
        PERF_STAT_PID=""
    fi

    if [ -n "${PERF_RECORD_PID}" ]; then
        sudo kill -INT "${PERF_RECORD_PID}" 2>/dev/null || true
        wait "${PERF_RECORD_PID}" 2>/dev/null || true
        PERF_RECORD_PID=""
    fi
}

cleanup() {
    local status=$?
    set +e

    echo ""
    echo "==> 清理中..."

    [ -n "${MAIN_LOG_PID}" ] && kill "${MAIN_LOG_PID}" 2>/dev/null || true
    stop_perf

    if [ "${POD_APPLIED}" = "1" ]; then
        if [ "${KEEP_POD}" = "1" ] || { [ "${status}" -ne 0 ] && [ "${KEEP_POD_ON_ERROR}" = "1" ]; }; then
            echo "==> 保留 Pod: ${POD_NAME}"
            echo "    退出状态: ${status}，可用 KEEP_POD=0 KEEP_POD_ON_ERROR=0 恢复失败时自动删除"
        else
            echo "==> 删除 Pod: ${POD_NAME}"
            kubectl delete -f "${POD_YAML}" --ignore-not-found=true --wait=false 2>/dev/null || true
        fi
    else
        echo "==> Pod 未由本次脚本启动，跳过删除"
    fi

    return "${status}" 2>/dev/null || exit "${status}"
}

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
        --call-graph dwarf,32768 \
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

start_perf() {
    record_timepoint "perf_start" "开始 perf ${PERF_MODE} 测量"

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
        none)
            ;;
    esac
}

print_perf_results() {
    if [ "${PERF_MODE}" = "stat" ] || [ "${PERF_MODE}" = "all" ]; then
        echo "--- perf stat 结果 ---"
        if [ -f "${STAT_OUTPUT}" ]; then
            cat "${STAT_OUTPUT}"
            echo ""
            echo "--- 关键指标摘要 ---"
            grep -E "seconds time elapsed|instructions|cycles|cache-misses|branch-misses|cpu-migrations" "${STAT_OUTPUT}" 2>/dev/null || true
        else
            echo "    (perf stat 输出文件未生成)"
        fi
        echo ""
    fi

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
}

build_bench_command() {
    BENCH_CMD=(
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
        --request-rate "${BENCH_REQUEST_RATE}"
        --save-result
        --result-dir "${LOG_DIR}"
        --result-filename "$(basename "${BENCH_RESULT_JSON}")"
    )

    if [ -n "${BENCH_TOKENIZER}" ]; then
        BENCH_CMD+=(--tokenizer "${BENCH_TOKENIZER}")
    fi

    if [ -n "${BENCH_MAX_CONCURRENCY}" ]; then
        BENCH_CMD+=(--max-concurrency "${BENCH_MAX_CONCURRENCY}")
    fi
}

run_benchmark() {
    local bench_status=0
    local bench_run_cmd=()

    build_bench_command

    if [ -n "${BENCH_NO_PROXY}" ]; then
        bench_run_cmd=(env "NO_PROXY=${BENCH_NO_PROXY}" "no_proxy=${BENCH_NO_PROXY}" "${BENCH_CMD[@]}")
    else
        bench_run_cmd=("${BENCH_CMD[@]}")
    fi

    echo "==> 启动 vLLM benchmark"
    echo "    benchmark 日志: ${BENCH_LOG}"
    echo "    benchmark JSON: ${BENCH_RESULT_JSON}"
    echo "    NO_PROXY: ${BENCH_NO_PROXY}"
    printf "    命令:"
    printf " %q" "${bench_run_cmd[@]}"
    printf "\n"
    echo ""

    BENCH_START=$(now_sec)
    record_timepoint "bench_start" "开始执行 vllm bench serve"
    set +e
    "${bench_run_cmd[@]}" > >(tee -a "${BENCH_LOG}") 2>&1
    bench_status=$?
    set -e
    BENCH_END=$(now_sec)
    record_timepoint "bench_end" "vllm bench serve 结束，退出码 ${bench_status}"
    BENCH_TIME=$(duration_between "${BENCH_START}" "${BENCH_END}")

    return "${bench_status}"
}

for required_var in RUNTIME_NAME DEFAULT_POD_YAML POD_NAME PERF_MODE_FILE PERF_STAT_EVENTS_FILE PERF_RECORD_EVENT_FILE BENCH_CONFIG_FILE; do
    if [ -z "${!required_var:-}" ]; then
        echo "错误: 缺少 runtime 配置变量: ${required_var}" >&2
        exit 1
    fi
done

POD_YAML=${POD_YAML:-"${DEFAULT_POD_YAML}"}
CONTAINER_NAME=${CONTAINER_NAME:-cuda-container}
DEFAULT_PERF_MODE=$(read_first_config_value "${PERF_MODE_FILE}" "record")
DEFAULT_PERF_STAT_EVENTS=$(read_first_config_value "${PERF_STAT_EVENTS_FILE}" "cycles,instructions,cache-references,cache-misses,branch-misses,context-switches,cpu-migrations,page-faults")
DEFAULT_PERF_RECORD_EVENT=$(read_first_config_value "${PERF_RECORD_EVENT_FILE}" "cycles")
PERF_MODE=${PERF_MODE:-${DEFAULT_PERF_MODE}}
PERF_STAT_EVENTS=${PERF_STAT_EVENTS:-${DEFAULT_PERF_STAT_EVENTS}}
PERF_RECORD_EVENT=${PERF_RECORD_EVENT:-${DEFAULT_PERF_RECORD_EVENT}}

load_bench_config "${BENCH_CONFIG_FILE}"

BENCH_BACKEND=${BENCH_BACKEND-${CONFIG_BENCH_BACKEND:-openai}}
BENCH_MODEL=${BENCH_MODEL-${CONFIG_BENCH_MODEL:-/model}}
BENCH_TOKENIZER=${BENCH_TOKENIZER-${CONFIG_BENCH_TOKENIZER:-/home/liulei/models/Qwen/Qwen3___5-9B}}
BENCH_DATASET_NAME=${BENCH_DATASET_NAME-${CONFIG_BENCH_DATASET_NAME:-random}}
BENCH_INPUT_LEN=${BENCH_INPUT_LEN-${CONFIG_BENCH_INPUT_LEN:-1024}}
BENCH_OUTPUT_LEN=${BENCH_OUTPUT_LEN-${CONFIG_BENCH_OUTPUT_LEN:-128}}
BENCH_NUM_PROMPTS=${BENCH_NUM_PROMPTS-${CONFIG_BENCH_NUM_PROMPTS:-1000}}
BENCH_REQUEST_RATE=${BENCH_REQUEST_RATE-${CONFIG_BENCH_REQUEST_RATE:-inf}}
BENCH_MAX_CONCURRENCY=${BENCH_MAX_CONCURRENCY-${CONFIG_BENCH_MAX_CONCURRENCY:-}}
BENCH_ENDPOINT=${BENCH_ENDPOINT-${CONFIG_BENCH_ENDPOINT:-/v1/completions}}
BENCH_PORT=${BENCH_PORT-${CONFIG_BENCH_PORT:-8000}}
BENCH_NO_PROXY=${BENCH_NO_PROXY-${CONFIG_BENCH_NO_PROXY:-*}}

LOG_DIR="${SCRIPT_DIR}/perf-logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="${LOG_DIR}/perf_bench_${RUNTIME_NAME}_${TIMESTAMP}.log"
TIMEPOINTS_FILE="${LOG_DIR}/timepoints_bench_${RUNTIME_NAME}_${TIMESTAMP}.tsv"
STAT_OUTPUT="${LOG_DIR}/perf_bench_${RUNTIME_NAME}_stat_${TIMESTAMP}.txt"
RECORD_FILE="${LOG_DIR}/perf_bench_${RUNTIME_NAME}_record_${TIMESTAMP}.data"
VLLM_LOG="${LOG_DIR}/vllm_serve_${RUNTIME_NAME}_${TIMESTAMP}.log"
BENCH_LOG="${LOG_DIR}/vllm_bench_${RUNTIME_NAME}_${TIMESTAMP}.log"
BENCH_RESULT_JSON="${LOG_DIR}/vllm_bench_${RUNTIME_NAME}_${TIMESTAMP}.json"
CGROUP_ROOT=${CGROUP_ROOT:-/sys/fs/cgroup}
STARTUP_TIMEOUT=${STARTUP_TIMEOUT:-600}
KEEP_POD=${KEEP_POD:-0}
KEEP_POD_ON_ERROR=${KEEP_POD_ON_ERROR:-1}
POD_APPLIED=0
MAIN_LOG_PID=""
PERF_STAT_PID=""
PERF_RECORD_PID=""
BENCH_TIME="N/A"
SCRIPT_START_TIME=$(now_sec)

mkdir -p "${LOG_DIR}"

exec > >(tee -a "${LOG_FILE}")
exec 2>&1

trap cleanup EXIT

printf "key\tepoch\telapsed_since_start_sec\tlocal_time\tdescription\n" > "${TIMEPOINTS_FILE}"
record_timepoint "script_start" "脚本开始"

echo "==> $(date) 开始 vLLM benchmark perf 测量"
echo "    Runtime: ${RUNTIME_NAME}"
echo "    Pod: ${POD_NAME}"
echo "    Pod YAML: ${POD_YAML}"
echo "    容器: ${CONTAINER_NAME}"
echo "    Perf 模式: ${PERF_MODE}"
echo "    Perf 模式配置: ${PERF_MODE_FILE}"
echo "    Perf stat 事件配置: ${PERF_STAT_EVENTS_FILE}"
echo "    Perf record 事件配置: ${PERF_RECORD_EVENT_FILE}"
echo "    Benchmark 配置: ${BENCH_CONFIG_FILE}"
echo "    日志文件: ${LOG_FILE}"
echo ""
echo "--- Benchmark 参数 ---"
echo "    BENCH_BACKEND=${BENCH_BACKEND}"
echo "    BENCH_MODEL=${BENCH_MODEL}"
echo "    BENCH_TOKENIZER=${BENCH_TOKENIZER}"
echo "    BENCH_DATASET_NAME=${BENCH_DATASET_NAME}"
echo "    BENCH_INPUT_LEN=${BENCH_INPUT_LEN}"
echo "    BENCH_OUTPUT_LEN=${BENCH_OUTPUT_LEN}"
echo "    BENCH_NUM_PROMPTS=${BENCH_NUM_PROMPTS}"
echo "    BENCH_REQUEST_RATE=${BENCH_REQUEST_RATE}"
echo "    BENCH_MAX_CONCURRENCY=${BENCH_MAX_CONCURRENCY}"
echo "    BENCH_ENDPOINT=${BENCH_ENDPOINT}"
echo "    BENCH_PORT=${BENCH_PORT}"
echo "    BENCH_NO_PROXY=${BENCH_NO_PROXY}"
echo ""

case "${PERF_MODE}" in
    stat|record|all)
        PERF_ENABLED=1
        ;;
    none)
        PERF_ENABLED=0
        ;;
    *) echo "错误: 无效的 PERF_MODE '${PERF_MODE}'，可选: stat / record / all / none"; exit 1 ;;
esac

for var in BENCH_BACKEND BENCH_MODEL BENCH_DATASET_NAME BENCH_INPUT_LEN BENCH_OUTPUT_LEN BENCH_NUM_PROMPTS BENCH_REQUEST_RATE BENCH_ENDPOINT BENCH_PORT; do
    require_non_empty "${var}"
done

REQUIRED_CMDS="kubectl curl vllm"
if [ "${PERF_ENABLED}" = "1" ]; then
    REQUIRED_CMDS="${REQUIRED_CMDS} perf sudo"
fi

for cmd in ${REQUIRED_CMDS}; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
        echo "错误: 缺少依赖命令 '${cmd}'"
        exit 1
    fi
done

if [ "${PERF_ENABLED}" = "1" ]; then
    if ! sudo -n true 2>/dev/null; then
        echo "错误: sudo 需要无密码访问（用于 perf）"
        exit 1
    fi

    if [ ! -f "${CGROUP_ROOT}/cgroup.controllers" ]; then
        echo "错误: ${CGROUP_ROOT} 不是 cgroup v2 根目录"
        exit 1
    fi

    if ! perf stat true 2>/dev/null; then
        echo "提示: perf 可能权限不足，请以 root 运行或调整 /proc/sys/kernel/perf_event_paranoid"
    fi
fi

echo "==> [1] 启动 Pod"
if [ ! -f "${POD_YAML}" ]; then
    echo "错误: Pod YAML 文件不存在: ${POD_YAML}"
    exit 1
fi
T_APPLY=$(now_sec)
record_timepoint "pod_apply_start" "开始 kubectl apply"
kubectl apply -f "${POD_YAML}"
POD_APPLIED=1

echo -n "==> [2] 等待 Pod 对象创建"
for i in $(seq 1 60); do
    if kubectl get pod "${POD_NAME}" -o name >/dev/null 2>&1; then
        T_CREATED=$(now_sec)
        POD_UID=$(kubectl get pod "${POD_NAME}" -o jsonpath='{.metadata.uid}' 2>/dev/null || true)
        if [ -z "${POD_UID}" ]; then
            echo ""
            echo "错误: 无法获取 Pod UID，请检查 Pod 是否存在: ${POD_NAME}"
            exit 1
        fi
        echo ""
        echo "    Pod 对象已创建: $(elapsed_since "${T_APPLY}")s"
        record_timepoint "pod_visible" "Pod 对象可见"
        break
    fi
    if [ "${i}" -eq 60 ]; then
        echo ""
        echo "错误: Pod 在 60s 内未创建"
        exit 1
    fi
    echo -n "."
    sleep 1
done

echo -n "==> [3] 等待 Scheduler 绑定"
for i in $(seq 1 60); do
    node=$(kubectl get pod "${POD_NAME}" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)
    if [ -n "${node}" ]; then
        echo ""
        echo "    已分配到节点 ${node}: $(elapsed_since "${T_CREATED}")s"
        record_timepoint "pod_scheduled" "Pod 已调度到节点 ${node}"
        break
    fi
    if [ "${i}" -eq 60 ]; then
        echo ""
        echo "错误: Pod 在 60s 内未被调度"
        kubectl describe pod "${POD_NAME}" 2>/dev/null || true
        exit 1
    fi
    echo -n "."
    sleep 1
done

echo -n "==> [4] 等待 Pod Running"
for i in $(seq 1 300); do
    status=$(kubectl get pod "${POD_NAME}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
    if [ "${status}" = "Running" ]; then
        T_RUNNING=$(now_sec)
        echo ""
        echo "    Pod 已 Running: $(elapsed_since "${T_APPLY}")s"
        record_timepoint "pod_running" "Pod phase 为 Running"
        break
    fi
    if [ "${status}" = "Failed" ] || [ "${status}" = "Succeeded" ]; then
        echo ""
        echo "错误: Pod 已结束，状态: ${status}"
        kubectl describe pod "${POD_NAME}" 2>/dev/null || true
        kubectl logs "${POD_NAME}" -c "${CONTAINER_NAME}" 2>/dev/null || true
        exit 1
    fi
    if [ "${i}" -eq 300 ]; then
        echo ""
        echo "错误: Pod 在 300s 内未进入 Running，当前状态: ${status}"
        kubectl describe pod "${POD_NAME}" 2>/dev/null || true
        exit 1
    fi
    echo -n "."
    sleep 1
done

echo "==> 获取 Pod IP"
POD_IP=$(kubectl get pod "${POD_NAME}" -o jsonpath='{.status.podIP}' 2>/dev/null)
if [ -z "${POD_IP}" ]; then
    echo "错误: 无法获取 Pod IP"
    exit 1
fi
echo "    Pod IP: ${POD_IP}"
record_timepoint "pod_ip_ready" "获取 Pod IP: ${POD_IP}"

echo "==> 启动 vLLM 日志捕获"
kubectl logs -f "${POD_NAME}" -c "${CONTAINER_NAME}" > "${VLLM_LOG}" 2>&1 &
MAIN_LOG_PID=$!
echo "    日志 PID: ${MAIN_LOG_PID}"
echo "    日志文件: ${VLLM_LOG}"
record_timepoint "vllm_log_follow_start" "开始 kubectl logs -f"

echo "==> [5] 等待 vLLM 服务就绪 (curl --noproxy '*' -s --fail --max-time 3 http://${POD_IP}:${BENCH_PORT}/health)"
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

    if curl --noproxy '*' -s --fail --max-time 3 "http://${POD_IP}:${BENCH_PORT}/health" >/dev/null 2>&1; then
        T_READY=$(now_sec)
        echo ""
        echo "    vLLM 服务已就绪: $(duration_between "${T_RUNNING}" "${T_READY}")s"
        record_timepoint "vllm_ready" "vLLM /health 返回成功"
        break
    fi
    echo -n "."
    sleep 2
done

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

    if [ ! -d "${CGROUP_FULL}" ]; then
        echo "错误: cgroup 路径不存在: ${CGROUP_FULL}"
        exit 1
    fi
    echo "    cgroup 路径已验证: ${CGROUP_FULL}"
    record_timepoint "cgroup_lookup_done" "Pod cgroup 已定位: ${CGROUP_PATH}"
else
    echo "==> 跳过 Pod cgroup 定位: PERF_MODE=none"
fi

echo ""
if [ "${PERF_ENABLED}" = "1" ]; then
    echo "==> 启动 perf 测量"
    echo "    模式: ${PERF_MODE}"
    echo "    注意: perf 只覆盖下面的 vllm bench serve 执行窗口"
    start_perf
else
    echo "==> 跳过 perf 测量: PERF_MODE=none"
fi

BENCH_STATUS=0
run_benchmark || BENCH_STATUS=$?

echo ""
if [ "${PERF_ENABLED}" = "1" ]; then
    echo "==> benchmark 结束，停止 perf 测量"
    stop_perf
    record_timepoint "perf_stop" "停止 perf ${PERF_MODE} 测量"
else
    echo "==> 跳过停止 perf 测量: PERF_MODE=none"
fi

[ -n "${MAIN_LOG_PID}" ] && kill "${MAIN_LOG_PID}" 2>/dev/null || true
MAIN_LOG_PID=""

echo ""
echo "============================================================"
echo "==> Benchmark perf 测量摘要"
echo "============================================================"
echo "  Runtime:             ${RUNTIME_NAME}"
echo "  Pod:                 ${POD_NAME}"
echo "  Pod IP:              ${POD_IP}"
echo "  Pod Ready 耗时:       $(duration_between "${T_RUNNING}" "${T_READY}")s"
echo "  Benchmark 耗时:       ${BENCH_TIME}s"
echo "  Benchmark 退出码:     ${BENCH_STATUS}"
echo ""

record_timepoint "script_end" "脚本主流程结束"
print_timepoints_summary

print_perf_results

echo "--- 输出文件 ---"
echo "  完整日志:       ${LOG_FILE}"
echo "  时间点 TSV:     ${TIMEPOINTS_FILE}"
echo "  vLLM 服务日志:  ${VLLM_LOG}"
echo "  benchmark 日志: ${BENCH_LOG}"
echo "  benchmark JSON: ${BENCH_RESULT_JSON}"
if [ "${PERF_MODE}" = "stat" ] || [ "${PERF_MODE}" = "all" ]; then
    echo "  perf stat:      ${STAT_OUTPUT}"
fi
if [ "${PERF_MODE}" = "record" ] || [ "${PERF_MODE}" = "all" ]; then
    echo "  perf record:    ${RECORD_FILE}"
elif [ "${PERF_MODE}" = "stat" ]; then
    echo "  perf record:    未启用（使用 PERF_MODE=record 或 PERF_MODE=all 生成 .data）"
else
    echo "  perf:           未启用（PERF_MODE=none）"
fi
echo ""

if [ "${BENCH_STATUS}" -ne 0 ]; then
    echo "错误: vllm bench serve 失败，退出码: ${BENCH_STATUS}"
    echo "最后几行 benchmark 日志:"
    tail -40 "${BENCH_LOG}" 2>/dev/null || true
    exit "${BENCH_STATUS}"
fi

echo "==> $(date) benchmark perf 测量完成"
