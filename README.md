# vllm-perf

在 Kata QEMU 虚拟机与原生 runc 两种运行时下，对 GPU vLLM 推理 Pod 进行 `perf` CPU 性能采样对比。

## 脚本

| 脚本 | 运行时 | Pod YAML | Pod 名称 |
|------|--------|----------|-----------|
| `perf-kata-start.sh` | `kata-qemu-nvidia-gpu` | `gpu-pod-kata.yaml` | `gpu-pod-kata` |
| `perf-runc-start.sh` | `nvidia` (runc) | `gpu-pod-runc.yaml` | `gpu-pod-runc` |
| `vllm-start-perf/perf-startup-kata.sh` | `kata-qemu-nvidia-gpu` | `gpu-pod-kata.yaml` | `gpu-pod-kata` |
| `vllm-start-perf/perf-startup-runc.sh` | `nvidia` (runc) | `gpu-pod-runc.yaml` | `gpu-pod-runc` |
| `vllm-bench-perf/perf-bench-kata.sh` | `kata-qemu-nvidia-gpu` | `gpu-pod-kata.yaml` | `gpu-pod-kata` |
| `vllm-bench-perf/perf-bench-runc.sh` | `nvidia` (runc) | `gpu-pod-runc.yaml` | `gpu-pod-runc` |
| `core-test/verify-cpu-pin-sched-overhead.sh` | 已运行 Pod | 不启动 Pod | 由 Pod IP 自动定位 |

除 `core-test/verify-cpu-pin-sched-overhead.sh` 只观测已运行 Pod 外，其余 perf 脚本会自动启动 Pod、通过 cgroup v2 定位 Pod 进程、运行 perf 采样，并在退出时自动清理 Pod。`vllm-start-perf/perf-startup-*.sh` 可使用 `PERF_MODE=none` 只测启动耗时，不启动 perf；`vllm-bench-perf/perf-bench-*.sh` 会在 vLLM 服务 ready 后从宿主机运行 `vllm bench serve`，perf 只覆盖 benchmark 执行窗口。

## GPU 绑定到 vfio-pci

`bind-gpu-vfio.sh` 用于在宿主机侧把指定 NVIDIA GPU 及其音频函数从当前驱动解绑，并绑定到 `vfio-pci`。脚本会先关闭常见显示管理器，再检查目标 GPU 的 `/dev/nvidia${GPU_INDEX}` 以及该 GPU BDF 对应的 `/dev/dri/card*`、`/dev/dri/renderD*` 是否有进程占用；一旦发现占用，会打印 `fuser -v` 信息并终止，不会继续解绑。

```bash
GPU_INDEX=0 \
GPU_BDF=0000:2a:00.0 \
GPU_AUDIO_BDF=0000:2a:00.1 \
./bind-gpu-vfio.sh
```

可用环境变量：

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `GPU_INDEX` | `0` | `nvidia-smi` / `/dev/nvidiaX` 使用的 GPU index |
| `GPU_BDF` | `0000:2a:00.0` | GPU PCI BDF，建议使用完整小写格式 |
| `GPU_AUDIO_BDF` | `0000:2a:00.1` | GPU 音频函数 PCI BDF |
| `VFIO_DEVS` | `${GPU_BDF} ${GPU_AUDIO_BDF}` | 要绑定到 `vfio-pci` 的 PCI 设备列表 |
| `STOP_DISPLAY_MANAGER` | `1` | 是否先停止 `gdm`、`lightdm`、`sddm` |
| `DISABLE_PERSISTENCE` | `1` | 是否执行 `nvidia-smi -i ${GPU_INDEX} -pm 0` |

## Kata QEMU VFIO trace wrapper

`startVM-split/kata-qemu-vfio-traced/` 提供一个 `qemu-system-x86_64` wrapper，用于把 Kata `kata-qemu-nvidia-gpu` 启动 VM 时的真实 QEMU 调用记录下来，并追加 QEMU `-trace` 参数采集 VFIO/GPU 设备挂载相关事件。

典型用途是定位 startVM 阶段 NVIDIA GPU VFIO attach、PCI BAR、MSI/MSI-X、KVM、memory region 等路径上的耗时瓶颈。

部署方式是向 `/opt/kata/share/defaults/kata-containers/runtimes/qemu-nvidia-gpu/conf.d/` 写入专用 override TOML，指定 `[hypervisor.qemu].path` 为 wrapper。

```bash
cd startVM-split/kata-qemu-vfio-traced
sudo ./deploy.sh

# 启动 runtimeClassName: kata-qemu-nvidia-gpu 的 Pod 后查看:
sudo ls -lh /var/log/kata-qemu-vfio-trace/

# 调试完成后恢复:
sudo ./restore.sh
```

如 Kata qemu-nvidia-gpu 的 drop-in 目录不在默认路径，使用 `sudo KATA_CONF_D=/path/to/conf.d ./deploy.sh`。详细参数见 `startVM-split/kata-qemu-vfio-traced/README.md`。

## Kata QEMU perf wrapper

`startVM-split/qemu-perf/` 提供一个 `qemu-system-x86_64` wrapper，用于把 Kata `kata-qemu-nvidia-gpu` 启动 VM 时的真实 QEMU 调用包装到 `perf` 下采集。它和 `qemu-observe` 一样通过 Kata drop-in 覆盖 `[hypervisor.qemu].path`，但采集的是 QEMU 进程启动全程的 CPU profile/counter，而不是 `strace` 或 QEMU `-trace`。

默认使用 `/usr/bin/qemu-system-x86_64` 作为真实 QEMU，`qemu-perf-mode` 默认为 `record`，生成 `perf record` 数据；如需计数器汇总，可把模式切换为 `stat`：

```bash
cd startVM-split/qemu-perf
sudo ./deploy-qemu-perf.sh
sudo systemctl restart containerd

# 启动 runtimeClassName: kata-qemu-nvidia-gpu 的 Pod 后，停止 Pod 或等待 QEMU 退出再查看:
ls -lh qemu-perf-logs/

# 调试完成后恢复:
sudo ./remove-qemu-perf.sh
sudo systemctl restart containerd
```

可编辑 `qemu-perf-mode` 切换 `stat` / `record`，编辑 `qemu-perf-stat-events` 和 `qemu-perf-record-event` 调整采集事件。默认 stat 指标包含 task-clock、fault、cache、KVM tracepoint 和常见文件读取 syscall tracepoint。详细说明见 `startVM-split/qemu-perf/README.md`。

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
- `vllm`（仅 `vllm-bench-perf/perf-bench-*.sh` 需要，用于宿主机运行 `vllm bench serve`）
- `perf`（通常由 `linux-tools` 包提供；仅启用 perf 采样时需要）
- `sudo`（NOPASSWD，perf 需要 root 权限；仅启用 perf 采样时需要）
- `curl`（`vllm-start-perf/perf-startup-*.sh` 和 `vllm-bench-perf/perf-bench-*.sh` 用于检测 `/health`）
- 系统使用 **cgroup v2**（perf 采样和 benchmark cgroup CPU 使用时间保存需要）

## 常规采样输出

- 实时输出到 stdout，同时保存到 `perf-logs/perf_<timestamp>.log`
- 开启 `PERF_RECORD=1` 时，调用栈采样数据保存到 `perf-logs/perf_record_<timestamp>.data`

## perf 输出权限修复

`chmod-perf-files-rw.sh` 用于一键给 perf 输出文件添加 `a+rw` 权限。默认处理：

- `perf-logs/`
- `startVM-split/qemu-perf/qemu-perf-logs/`

```bash
sudo ./chmod-perf-files-rw.sh
```

也可以显式指定目录：

```bash
sudo ./chmod-perf-files-rw.sh perf-logs startVM-split/qemu-perf/qemu-perf-logs
```

## 补充

`gpu-pod-bench.yaml` 是一个独立的 vLLM throughput benchmark Pod 定义（运行 `vllm bench throughput`），不参与 perf 采样流程。

## vLLM benchmark 压测采样

`vllm-bench-perf/perf-bench-kata.sh` 和 `vllm-bench-perf/perf-bench-runc.sh` 会先启动对应的 vLLM serve Pod，等待 `/health` 返回成功，再定位 Pod cgroup。随后脚本读取 benchmark 前的 cgroup v2 `cpu.stat`，启动 perf，通过宿主机执行 `vllm bench serve` 压测 Pod IP，并在 benchmark 命令结束后立即读取 `cpu.stat`、停止 perf、打印 cgroup CPU 使用时间差值。

```bash
# runc: 默认 record 模式，benchmark 参数来自配置文件
./vllm-bench-perf/perf-bench-runc.sh

# Kata: 临时覆盖 benchmark 规模并用 perf stat
PERF_MODE=stat BENCH_NUM_PROMPTS=10 BENCH_REQUEST_RATE=1 ./vllm-bench-perf/perf-bench-kata.sh
```

### Benchmark perf 配置文件

Perf 配置文件读取方式和启动测量一致：每个配置文件使用第一条非空、非注释行，环境变量优先。

| 配置文件 | 默认值 | 说明 |
|------|--------|------|
| `vllm-bench-perf/perf-bench-kata-mode` | `record` | Kata benchmark perf 模式，可选 `stat` / `record` / `all` / `none` |
| `vllm-bench-perf/perf-bench-kata-stat-events` | task-clock/fault/cache/TLB/KVM/syscall 事件 | Kata 传给 `perf stat -e` 的事件列表 |
| `vllm-bench-perf/perf-bench-kata-record-event` | `cycles` | Kata 传给 `perf record -e` 的事件 |
| `vllm-bench-perf/perf-bench-runc-mode` | `record` | runc benchmark perf 模式，可选 `stat` / `record` / `all` / `none` |
| `vllm-bench-perf/perf-bench-runc-stat-events` | cycles/instructions/cache/fault 事件 | runc 传给 `perf stat -e` 的事件列表 |
| `vllm-bench-perf/perf-bench-runc-record-event` | `cycles` | runc 传给 `perf record -e` 的事件 |

`PERF_MODE=none` 只跳过 perf，benchmark 脚本仍会定位 Pod cgroup 并读取 `cpu.stat`，因此仍要求宿主机使用 cgroup v2。

### Benchmark 参数配置

`vllm-bench-perf/perf-bench-kata-bench-config` 和 `vllm-bench-perf/perf-bench-runc-bench-config` 使用 `KEY=VALUE` 格式，忽略空行和以 `#` 开头的注释行。脚本只读取白名单 key，环境变量优先级高于配置文件。

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `BENCH_BACKEND` | `openai` | 传给 `vllm bench serve --backend` |
| `BENCH_MODEL` | `/model` | 传给 `--model`，匹配 Pod 内 `vllm serve /model` |
| `BENCH_TOKENIZER` | `/home/liulei/models/Qwen/Qwen3___5-9B` | 非空时传给 `--tokenizer`，用于宿主机侧 tokenizer 初始化 |
| `BENCH_DATASET_NAME` | `random` | 传给 `--dataset-name` |
| `BENCH_INPUT_LEN` | `1024` | 传给 `--input-len` |
| `BENCH_OUTPUT_LEN` | `128` | 传给 `--output-len` |
| `BENCH_NUM_PROMPTS` | `1000` | 传给 `--num-prompts` |
| `BENCH_REQUEST_RATE` | `inf` | 传给 `--request-rate` |
| `BENCH_MAX_CONCURRENCY` | 空 | 非空时传给 `--max-concurrency` |
| `BENCH_ENDPOINT` | `/v1/completions` | 传给 `--endpoint` |
| `BENCH_PORT` | `8000` | 传给 `--port`，也用于 `/health` 检测 |
| `BENCH_NO_PROXY` | `*` | benchmark 命令的 `NO_PROXY/no_proxy`，避免 Pod IP 请求走宿主机代理 |

### Benchmark 输出

- 完整脚本日志: `vllm-bench-perf/perf-logs/perf_bench_<runtime>_<timestamp>.log`
- 阶段时间点 TSV: `vllm-bench-perf/perf-logs/timepoints_bench_<runtime>_<timestamp>.tsv`
- vLLM 服务日志: `vllm-bench-perf/perf-logs/vllm_serve_<runtime>_<timestamp>.log`
- benchmark stdout/stderr: `vllm-bench-perf/perf-logs/vllm_bench_<runtime>_<timestamp>.log`
- benchmark JSON: `vllm-bench-perf/perf-logs/vllm_bench_<runtime>_<timestamp>.json`
- perf 输出: `perf_bench_<runtime>_stat_<timestamp>.txt` / `perf_bench_<runtime>_record_<timestamp>.data`
- cgroup CPU 使用时间差值: 打印在完整脚本日志中，不额外生成文件；包含 `usage_usec`、`user_usec`、`system_usec` 的 start/end/delta

cgroup CPU time 是 cgroup 内所有 CPU 上的累计使用时间，因此 delta seconds 可能大于 benchmark 的 wall time。

阶段时间点 TSV 列固定为:

```text
key	epoch	elapsed_since_start_sec	local_time	description
```

## CPU pin 调度开销验证

`core-test/verify-cpu-pin-sched-overhead.sh` 用于验证 CPU pin 后 vLLM 吞吐量上升是否伴随调度开销下降。脚本只观测两个已经运行的 vLLM Pod，不负责切换 CPU pin 状态；传入的目标必须是 Pod IP，而不是 Service IP。脚本会通过 `kubectl get pod -A -o json` 反查 Pod UID/QoS，定位 cgroup v2 路径，在每轮 `vllm bench serve` 窗口内运行 `sudo perf stat -a --cgroup <pod-cgroup>`。

```bash
cd core-test

BASELINE_TARGETS="nopin=10.244.0.125" \
PINNED_TARGETS="pin=10.244.0.126" \
./verify-cpu-pin-sched-overhead.sh
```

常用环境变量：

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `BASELINE_TARGETS` | 必填 | CPU pin 前目标，格式 `label=podIP`，可多个空格分隔 |
| `PINNED_TARGETS` | 必填 | CPU pin 后目标，格式 `label=podIP`，可多个空格分隔 |
| `CONCURRENCY_LEVELS` | `1 2 4 8 16 32 64` | 依次测试的 `--max-concurrency` |
| `REPEATS` | `3` | 每个并发度、每个目标重复次数 |
| `COOLDOWN` | `5` | 每轮 benchmark 后冷却秒数 |
| `CGROUP_ROOT` | `/sys/fs/cgroup` | cgroup v2 根目录 |
| `PERF_EVENTS` | task-clock/context-switches/cpu-migrations 等 | 传给 `perf stat -e` 的事件列表；不可用 tracepoint 会自动跳过 |
| `MIN_THROUGHPUT_GAIN_PCT` | `5` | 判定吞吐提升的最小百分比 |
| `MIN_SCHED_DROP_PCT` | `10` | 判定单位 token 调度开销下降的最小百分比 |

`BENCH_BACKEND`、`BENCH_PORT`、`BENCH_ENDPOINT`、`BENCH_MODEL`、`BENCH_DATASET_NAME`、`BENCH_INPUT_LEN`、`BENCH_OUTPUT_LEN`、`BENCH_NUM_PROMPTS`、`BENCH_REQUEST_RATE`、`BENCH_TOKENIZER`、`BENCH_NO_PROXY` 与 `core-test/vllm-bench-multi.sh` 默认值一致，其中 `BENCH_NO_PROXY` 默认为 `*`，避免 Pod IP 请求走本机代理。

输出目录为 `core-test/perf-logs/cpu-pin-sched-verify/<timestamp>/`，包含：

- `verify_cpu_pin_sched_overhead_<timestamp>.log`: 完整运行日志
- `runs.jsonl`: 每轮 benchmark 的原始指标
- `summary.csv`: 按 target/concurrency 聚合后的 CSV
- `summary.md`: baseline 与 pinned 的并发度对比和最终结论
- 每轮子目录中的 `vllm_bench.json`、`perf_stat.csv`、`cpu.stat.before.txt`、`cpu.stat.after.txt`、`cpuset.cpus.effective.txt`、`cgroup.procs.txt`

判定逻辑使用 `output_token_throughput` 作为主吞吐指标；调度开销使用 `context-switches / 1k output tokens`、`cpu-migrations / 1k output tokens`、`system_cpu_usec / 1k output tokens`。当吞吐提升达到阈值，并且三个主调度指标中至少两个可用指标达到下降阈值时，`summary.md` 会输出“支持调度开销下降假设”。

## 启动性能测量

`vllm-start-perf/perf-startup-kata.sh` 和 `vllm-start-perf/perf-startup-runc.sh` 测量 vLLM 服务从 Pod 创建到服务就绪的完整启动周期。脚本默认从仓库根目录读取 `gpu-pod-kata.yaml` / `gpu-pod-runc.yaml`，也可以用 `POD_YAML=/path/to/pod.yaml` 覆盖。

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
| `record`（默认） | `./vllm-start-perf/perf-startup-runc.sh` 或 `./vllm-start-perf/perf-startup-kata.sh` | 火焰图 / profile |
| `stat` | `PERF_MODE=stat ./vllm-start-perf/perf-startup-runc.sh` | 稳定 CPU 计数器 |
| `all` | `PERF_MODE=all ./vllm-start-perf/perf-startup-runc.sh` | 同时启用 stat + record |
| `none` | `PERF_MODE=none ./vllm-start-perf/perf-startup-runc.sh` | 只测启动耗时，不启动 perf |

Kata 启动测量把上述命令中的 `vllm-start-perf/perf-startup-runc.sh` 替换为 `vllm-start-perf/perf-startup-kata.sh` 即可。

### 启动 perf 配置文件

`vllm-start-perf/perf-startup-kata.sh` 和 `vllm-start-perf/perf-startup-runc.sh` 支持和 `startVM-split/qemu-perf/` 类似的配置文件读取方式：每个配置文件使用第一条非空、非注释行。环境变量仍然优先，可临时覆盖配置文件。

| 配置文件 | 默认值 | 说明 |
|------|--------|------|
| `vllm-start-perf/perf-startup-kata-mode` | `record` | Kata 默认测量模式，可选 `stat` / `record` / `all` / `none` |
| `vllm-start-perf/perf-startup-kata-stat-events` | task-clock/fault/cache/TLB/KVM/syscall 事件 | Kata 传给 `perf stat -e` 的事件列表 |
| `vllm-start-perf/perf-startup-kata-record-event` | `cycles` | Kata 传给 `perf record -e` 的事件 |
| `vllm-start-perf/perf-startup-runc-mode` | `record` | runc 默认测量模式，可选 `stat` / `record` / `all` / `none` |
| `vllm-start-perf/perf-startup-runc-stat-events` | cycles/instructions/cache/fault 事件 | runc 传给 `perf stat -e` 的事件列表 |
| `vllm-start-perf/perf-startup-runc-record-event` | `cycles` | runc 传给 `perf record -e` 的事件 |

### Kata 容器 Started 后提前退出

`vllm-start-perf/perf-startup-kata.sh` 可只测到容器出现 Kubernetes `Started` 事件，不继续启动 perf、捕获日志、获取 Pod IP 或等待 vLLM `/health`。

```bash
EXIT_AFTER_CONTAINER_STARTED=1 ./vllm-start-perf/perf-startup-kata.sh
```

该模式正常退出，Pod 清理仍由 `KEEP_POD` 控制；默认 `KEEP_POD=0` 会删除 Pod。

### 时间分解

`vllm-start-perf/perf-startup-kata.sh` 与 `vllm-start-perf/perf-startup-runc.sh` 共享一致的 4 阶段分解：

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
| `POD_YAML` | 仓库根目录的 `gpu-pod-*.yaml` | 覆盖启动测量使用的 Pod YAML |
| `PERF_MODE` | 对应 `vllm-start-perf/perf-startup-*-mode` 或 `record` | 测量模式: `record` / `stat` / `all` / `none` |
| `PERF_STAT_EVENTS` | 对应 `vllm-start-perf/perf-startup-*-stat-events` | 覆盖 `perf stat -e` 事件列表 |
| `PERF_RECORD_EVENT` | 对应 `vllm-start-perf/perf-startup-*-record-event` | 覆盖 `perf record -e` 事件 |
| `STARTUP_TIMEOUT` | `600` | 等 vLLM ready 的最大秒数 |
| `EXIT_AFTER_CONTAINER_STARTED` | `0` | 仅 `vllm-start-perf/perf-startup-kata.sh` 使用；1=容器 Started 后立即结束，不启动 perf |
| `KEEP_POD` | `0` | 正常结束时保留 Pod（1=保留） |
| `KEEP_POD_ON_ERROR` | `1` | 异常退出时保留 Pod 用于诊断 |
| `CONTAINER_NAME` | `cuda-container` | 容器名称 |

### 启动测量输出

- 完整脚本日志: `vllm-start-perf/perf-logs/perf_startup_<runtime>_<timestamp>.log`
- 阶段时间点 TSV: `vllm-start-perf/perf-logs/timepoints_startup_<runtime>_<timestamp>.tsv`
- vLLM 启动日志: `vllm-start-perf/perf-logs/vllm_startup_<runtime>_<timestamp>.log`
- perf 输出: `perf_startup_<runtime>_stat_<timestamp>.txt` / `perf_startup_<runtime>_record_<timestamp>.data`

阶段时间点 TSV 列固定为:

```text
key	epoch	elapsed_since_start_sec	local_time	description
```
