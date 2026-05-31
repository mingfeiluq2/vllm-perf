# vllm-perf

在 Kata QEMU 虚拟机与原生 runc 两种运行时下，对 GPU vLLM 推理 Pod 进行 `perf` CPU 性能采样对比。

## 脚本

| 脚本 | 运行时 | Pod YAML | Pod 名称 |
|------|--------|----------|-----------|
| `perf-kata-start.sh` | `kata-qemu-nvidia-gpu` | `gpu-pod-kata.yaml` | `gpu-pod-kata` |
| `perf-runc-start.sh` | `nvidia` (runc) | `gpu-pod-runc.yaml` | `gpu-pod-runc` |
| `perf-startup-kata.sh` | `kata-qemu-nvidia-gpu` | `gpu-pod-kata.yaml` | `gpu-pod-kata` |
| `perf-startup-runc.sh` | `nvidia` (runc) | `gpu-pod-runc.yaml` | `gpu-pod-runc` |

这些脚本会自动启动 Pod、通过 cgroup v2 定位 Pod 进程、运行 perf 采样，并在退出时自动清理 Pod。

## 常规采样环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `PERF_DURATION` | `30` | perf 采样时长（秒） |
| `PERF_RECORD` | `0` | 是否执行 `perf record`（1=是） |
| `CGROUP_ROOT` | `/sys/fs/cgroup` | cgroup v2 根目录 |

## 使用方式

```bash
# Kata – 默认 30 秒 perf stat
./perf-kata-start.sh

# runc – 60 秒采样 + perf record
PERF_DURATION=60 PERF_RECORD=1 ./perf-runc-start.sh
```

## 前置依赖

- `kubectl`（可操作目标集群）
- `perf`（通常由 `linux-tools` 包提供）
- `sudo`（NOPASSWD，perf 需要 root 权限）
- `curl`（仅 `perf-startup-*.sh` 用于检测 `/health`）
- 系统使用 **cgroup v2**

## 常规采样输出

- 实时输出到 stdout，同时保存到 `perf-logs/perf_<timestamp>.log`
- 开启 `PERF_RECORD=1` 时，调用栈采样数据保存到 `perf-logs/perf_record_<timestamp>.data`

## 补充

`gpu-pod-bench.yaml` 是一个独立的 vLLM throughput benchmark Pod 定义（运行 `vllm bench throughput`），不参与 perf 采样流程。

## 启动性能测量

`perf-startup-kata.sh` 和 `perf-startup-runc.sh` 测量 vLLM 服务从 Pod 创建到服务就绪的完整启动周期。

### 阶段分解

| 子阶段 | 起点 | 终点 |
|--------|------|------|
| API 提交 | `kubectl apply` | Pod 对象可见 |
| 调度分配 | Pod 可见 | 节点已分配 |
| 容器启动 | 节点已分配 | Pod Running |
| vLLM 就绪 | Pod Running | `/health` 200 |

### Perf 测量模式

| 模式 | 命令 | 用途 |
|------|------|------|
| `record`（默认） | `./perf-startup-runc.sh` 或 `./perf-startup-kata.sh` | 火焰图 / profile |
| `stat` | `PERF_MODE=stat ./perf-startup-runc.sh` | 稳定 CPU 计数器 |
| `all` | `PERF_MODE=all ./perf-startup-runc.sh` | 同时启用 stat + record |

Kata 启动测量把上述命令中的 `perf-startup-runc.sh` 替换为 `perf-startup-kata.sh` 即可。

### 时间分解

`perf-startup-kata.sh` 与 `perf-startup-runc.sh` 共享一致的 4 阶段分解：

| 阶段 | 子阶段 | 含义 |
|------|--------|------|
| API / Scheduler | 1. Pod 对象创建 | `kubectl apply` → Pod visible |
| | 2. Scheduler 绑定 | Pod visible → `spec.nodeName` 分配 |
| Node / Runtime | 3. 节点侧 Pod 启动 | `Scheduled` → `Running` |
| | 3.1 Scheduled → Pulled | kubelet 接收、CreatePodSandbox、runtime、CNI、镜像检查 |
| | 3.2 Pulled → Created | CreateContainer |
| | 3.3 Created → Started | StartContainer |
| | 3.4 Started → Running | kubelet 状态上报 / Pod phase 更新 |
| App | 4. vLLM 就绪 | `Running` → `/health` 200 |

### 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `PERF_MODE` | `record` | 测量模式: `record` / `stat` / `all` |
| `STARTUP_TIMEOUT` | `600` | 等 vLLM ready 的最大秒数 |
| `KEEP_POD` | `0` | 正常结束时保留 Pod（1=保留） |
| `KEEP_POD_ON_ERROR` | `1` | 异常退出时保留 Pod 用于诊断 |
| `CONTAINER_NAME` | `cuda-container` | 容器名称 |
