# AGENTS.md

## What this repo does

Bash scripts that launch GPU vLLM Pods under Kata QEMU or runc, then attach `perf` via cgroup v2 to sample CPU performance counters. Used for comparing container runtime overhead on GPU inference workloads.

## Script entrypoints

| Actual script | Purpose |
|---|---|
| `perf-kata-start.sh` | Kata QEMU: launch pod → cgroup v2 lookup → perf stat/record |
| `perf-runc-start.sh` | runc: same flow as Kata variant (near-identical, differs only in YAML + pod name) |
| `perf-startup-kata.sh` | Kata QEMU: full startup latency pipeline with 4 sub-phases + perf overlay |
| `perf-startup-runc.sh` | runc: full startup latency pipeline with 4 sub-phases + perf overlay |

`gpu-pod-bench.yaml` is a standalone vLLM throughput benchmark pod — not used by any perf script.

## Environment variables

Duration sampling scripts (`perf-kata-start.sh`, `perf-runc-start.sh`) use: `PERF_DURATION` (sec), `CGROUP_ROOT` (`/sys/fs/cgroup`), `PERF_RECORD` (1=on)

`perf-startup-*.sh` adds: `PERF_MODE` (`stat`/`record`/`all`), `STARTUP_TIMEOUT` (600s), `KEEP_POD`, `KEEP_POD_ON_ERROR`, `CONTAINER_NAME`

## Prerequisites

- **cgroup v2** required — scripts check for `/sys/fs/cgroup/cgroup.controllers`
- **sudo with NOPASSWD** — needed for `perf`
- `kubectl` (target cluster must be reachable), `perf`, `curl`
- All scripts auto-cleanup Pods via `trap cleanup EXIT`

## Hardcoded values (change locally if needed)

- `gpu-pod-runc.yaml`: `nodeName: server`, `CUDA_VISIBLE_DEVICES: "3"`
- All YAMLs: model hostPath is `/home/liulei/models/Qwen/Qwen3___5-9B`
- `perf-kata-start.sh`/`perf-runc-start.sh`: wait timeout is 120s for pod Running; `perf-startup-*.sh` uses 300s

## Documentation conventions

- **每次修改脚本后必须同步更新 `README.md`**，确保文档与实际行为一致。
- **仅当用户明确要求记录教训时才更新 `AGENTS.md`**（例如 `"把这个记入 AGENTS.md"`），不要主动修改。

## No build/test/CI

No linting, formatting, tests, CI, or build system. Changes are verified by dry-run (`bash -n`) or executing against a live cluster.

## Lessons learned: `perf-startup-*.sh`

- If a startup run appears to "terminate" the Pod, first check the script log for `==> 清理中...` and `==> 删除 Pod`. A failed command under `set -euo pipefail` triggers the `trap cleanup EXIT` path, so the Pod may be deleted by the script rather than by Kubernetes or vLLM.
- The historical failure point was `get_container_pid()`: the Pod reached `Running`, but `crictl ps --pod <sandbox> --state Running` did not return the expected `cuda-container`, causing the script to exit and cleanup to delete the Pod.
- The current startup scripts avoid container PID lookup entirely. They read Kubernetes `.metadata.uid` and `.status.qosClass`, then check the expected cgroup v2 systemd/cgroupfs paths under `CGROUP_ROOT`.
- Do not reintroduce `crictl`/`jq` for the startup scripts unless UID/QoS cgroup lookup is proven insufficient on the target node.
- `perf-startup-*.sh` now defaults `KEEP_POD_ON_ERROR=1`; this is intentional. Failed diagnostic runs should preserve the Pod for inspection. Use `KEEP_POD_ON_ERROR=0` only when automatic cleanup on failure is desired.
- `sudo -n true` must pass before running the script. `perf` needs elevated access; otherwise perf attachment can fail before useful data is collected.
- A local agent session may have network or sandbox restrictions that make `kubectl` fail with proxy, EOF, or timeout errors. Distinguish that from a real cluster problem before changing Kubernetes manifests.
