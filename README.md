# vllm-perf

在 Kata QEMU 虚拟机与原生 runc 两种运行时下，对 GPU vLLM 推理 Pod 进行 `perf` CPU 性能采样对比。

## 脚本

| 脚本 | 运行时 | Pod YAML | Pod 名称 |
|------|--------|----------|-----------|
| `perf-kata.sh` | `kata-qemu-nvidia-gpu` | `gpu-pod-kata.yaml` | `gpu-pod-kata` |
| `perf-runc.sh` | `nvidia` (runc) | `gpu-pod-runc.yaml` | `gpu-pod-runc` |

两个脚本会自动启动 Pod、通过 cgroup v2 定位 Pod 进程、运行 perf 采样，并在退出时自动清理 Pod。

## 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `PERF_DURATION` | `30` | perf 采样时长（秒） |
| `PERF_RECORD` | `0` | 是否执行 `perf record`（1=是） |
| `CGROUP_ROOT` | `/sys/fs/cgroup` | cgroup v2 根目录 |

## 使用方式

```bash
# Kata – 默认 30 秒 perf stat
./perf-kata.sh

# runc – 60 秒采样 + perf record
PERF_DURATION=60 PERF_RECORD=1 ./perf-runc.sh
```

## 前置依赖

- `kubectl`（可操作目标集群）
- `perf`（通常由 `linux-tools` 包提供）
- `sudo`（perf 读取硬件计数器需要 root 权限）
- 系统使用 **cgroup v2**

## 输出

- 实时输出到 stdout，同时保存到 `perf-logs/perf_<timestamp>.log`
- 开启 `PERF_RECORD=1` 时，调用栈采样数据保存到 `perf-logs/perf_record_<timestamp>.data`

## 补充

`gpu-pod-bench.yaml` 是一个独立的 vLLM throughput benchmark Pod 定义（运行 `vllm bench throughput`），不参与 perf 采样流程。

## 启动性能测量

`perf-startup-runc.sh` 测量 vLLM 服务从 Pod 创建到服务就绪的完整启动周期。

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
| `stat`（默认） | `./perf-startup-runc.sh` | 稳定 CPU 计数器 |
| `record` | `PERF_MODE=record ./perf-startup-runc.sh` | 火焰图 / profile |
| `all` | `PERF_MODE=all ./perf-startup-runc.sh` | 探索用 |

### 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `PERF_MODE` | `stat` | 测量模式: `stat` / `record` / `all` |
| `STARTUP_TIMEOUT` | `600` | 等 vLLM ready 的最大秒数 |
