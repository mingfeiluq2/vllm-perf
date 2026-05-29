# perf-startup-runc.sh 设计文档

## 摘要

编写 `perf-startup-runc.sh`，测量 vLLM 服务在 runc 容器中的完整启动周期（从 Pod 创建到服务就绪），使用 `perf stat` + `perf record` 采集启动期间的 CPU 性能计数器。测量范围限定为 Pod 的 cgroup，cgroup 路径通过容器 PID 反推得到。

## 测量范围

- **起点**: `kubectl apply -f gpu-pod-runc.yaml`
- **终点**: vLLM `/health` 端点返回 HTTP 200
- **范围**: Pod 级 cgroup（所有容器进程）
## 测量模式

通过环境变量 `PERF_MODE` 选择，默认 `stat`。

| 模式 | PERF_MODE | perf stat | perf record | 用途 |
|------|-----------|-----------|-------------|------|
| A | `stat` | 是 | 否 | 稳定计数器，作为最终性能数字 |
| B | `record` | 否 | 是 | 火焰图 / profile 分析 |
| C | `all` | 是 | 是 | 仅探索用，不作为最终性能数字 |

## 启动阶段分解

```
T_apply ─[1]─> T_created ─[2]─> T_scheduled ─[3]─> T_running ─[4]─> T_ready
        API创建      调度分配      容器创建+启动     vLLM模型加载+服务就绪
|<── 阶段1: K8s调度分解 ───>|              |<── 阶段2: vLLM就绪 ──>|
|<──────────────── 总启动时间 ────────────────────────────────────>|
```

### K8s 调度子阶段

| 子阶段 | 起点 | 终点 | 检测方式 |
|--------|------|------|----------|
| 1. API 提交 | `kubectl apply` | Pod 对象可见 | 轮询 `kubectl get pod` 直到返回非 NotFound |
| 2. 调度分配 | Pod 可见 | 节点已分配 | 轮询 `.spec.nodeName` 非空 |
| 3. 容器启动 | 节点已分配 | Pod Running | 轮询 `.status.phase == "Running"` |

### vLLM 就绪阶段

| 阶段 | 起点 | 终点 | 检测方式 |
|------|------|------|----------|
| 4. vLLM 就绪 | Pod Running | `/health` 200 | 轮询 `curl http://<POD_IP>:8000/health` |

### 结果摘要输出

```
--- 启动耗时分解 ---
  API 提交:      X.Xs
  调度分配:      X.Xs
  容器启动:      X.Xs
  K8s 调度合计:  X.Xs
  vLLM 就绪:     X.Xs
  总启动时间:    X.Xs
```

## 脚本流程

```
1.  准备工作（创建日志目录、检查依赖、Trap cleanup）
2.  记录 T_apply；启动 Pod (kubectl apply)
3.  轮询 kubectl get pod 直至返回非 NotFound → 记录 T_created
    计算子阶段1 = T_created - T_apply
4.  轮询 .spec.nodeName 非空 → 记录 T_scheduled
    计算子阶段2 = T_scheduled - T_created
5.  轮询 .status.phase == "Running" → 记录 T_running
    计算子阶段3 = T_running - T_scheduled
    计算阶段1合计 = T_running - T_apply
6.  获取容器 PID
    - 通过 crictl inspect 获取 sandbox 内第一个容器的 PID
7.  获取 POD_IP (kubectl get pod -o jsonpath)
8.  启动 kubectl logs -f 重定向到 vllm 启动日志文件
9.  PID 反推 cgroup
    - 读取 /proc/<PID>/cgroup
    - 去掉前导 "0::" 和末尾容器 scope 段，得到 pod 级路径
10. 后台启动 perf stat（目标: sleep 86400）
    - 如 PERF_RECORD=1，同时启动 perf record
11. 轮询 curl http://<POD_IP>:8000/health → 记录 T_ready
    计算子阶段4 = T_ready - T_running
    计算总启动时间 = T_ready - T_apply
    - 间隔 2s，每次超时 3s，最长等待 STARTUP_TIMEOUT 秒（默认 600）
12. kill sleep 进程 → perf 自然退出
13. 停止 kubectl logs
14. 输出结果摘要
15. cleanup 删除 Pod
```

## PID → Cgroup 反推逻辑

```bash
# /proc/<PID>/cgroup 内容示例 (cgroup v2)
# 0::/kubepods.slice/kubepods-podabc123.slice/cri-containerd-def456.scope

get_pod_cgroup_from_pid() {
    local pid="$1"
    local cgroup_line
    cgroup_line=$(cat "/proc/${pid}/cgroup" 2>/dev/null)
    # 格式: 0::/path/to/pod.slice/container.scope
    local full_path="${cgroup_line#0::}"
    # /kubepods.slice/.../cri-containerd-xxx.scope
    # 去掉 app 级子 cgroup，保留 pod 级
    dirname "${full_path}"
}
```

## 就绪检测

```bash
while ! curl -s --max-time 3 "http://${POD_IP}:8000/health" >/dev/null 2>&1; do
    elapsed=$((SECONDS - start_ts))
    if [ "$elapsed" -ge "$STARTUP_TIMEOUT" ]; then
        echo "错误: vLLM 启动超时 (${STARTUP_TIMEOUT}s)"
        exit 1
    fi
    sleep 2
done
```

## Perf 命令

### perf stat（始终执行）
```bash
sudo perf stat \
    -a \
    -e cycles,instructions,cache-references,cache-misses,branch-misses \
    -e context-switches,cpu-migrations,page-faults \
    --cgroup "${CGROUP_PATH}" \
    -o "${PERF_STAT_OUTPUT}" \
    -- sleep 86400 &
```

### perf record（PERF_RECORD=1 时）
```bash
sudo perf record \
    -a -g \
    -e cycles \
    --cgroup "${CGROUP_PATH}" \
    -o "${RECORD_FILE}" \
    -- sleep 86400 &
```

## 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `PERF_MODE` | `stat` | 测量模式: `stat` / `record` / `all` |
| `CGROUP_ROOT` | `/sys/fs/cgroup` | cgroup v2 根目录 |
| `STARTUP_TIMEOUT` | `600` | 等 vLLM ready 的最大秒数 |

## 输出文件

| 文件路径 | 内容 |
|----------|------|
| `perf-logs/perf_startup_<ts>.log` | 脚本完整输出（stdout+stderr） |
| `perf-logs/perf_startup_stat_<ts>.txt` | perf stat 原始输出 |
| `perf-logs/perf_startup_record_<ts>.data` | perf record 采样数据 |
| `perf-logs/vllm_startup_<ts>.log` | vLLM 容器启动日志 |

## 依赖

- `kubectl`、`crictl`、`curl`、`perf`、`sudo`
- 系统使用 cgroup v2
- `/run/containerd/containerd.sock` 可访问（sudo）

## 错误处理

- Pod 120s 内未 Running → 打印 describe 后退出
- crictl 获取 PID 失败 → 报错退出
- cgroup 路径不存在 → 报错退出
- vLLM 超时未就绪 → 报错退出
- 任何错误时 trap 清理 Pod
