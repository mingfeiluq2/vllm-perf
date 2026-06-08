# QEMU perf wrapper for Kata qemu-nvidia-gpu

This directory contains a QEMU wrapper for the Kata `kata-qemu-nvidia-gpu`
runtime. It replaces the configured QEMU path with a wrapper that runs
`/usr/bin/qemu-system-x86_64` under either `perf stat` or `perf record`.

The managed Kata main configuration is:

```bash
/opt/kata/share/defaults/kata-containers/runtimes/qemu-nvidia-gpu/configuration-qemu-nvidia-gpu.toml
```

Do not edit that file directly. The deploy script writes this drop-in instead:

```bash
/opt/kata/share/defaults/kata-containers/runtimes/qemu-nvidia-gpu/config.d/100-qemu-perf.toml
```

## Files

| File | Purpose |
|---|---|
| `qemu-system-x86_64-perf-wrapper` | Runs QEMU under `perf stat` or `perf record` |
| `qemu-perf-mode` | First valid line selects `stat` or `record` |
| `qemu-perf-stat-events` | First valid line becomes the `perf stat -e` event list |
| `qemu-perf-record-event` | First valid line becomes the `perf record -e` event |
| `deploy-qemu-perf.sh` | Installs the Kata drop-in config |
| `remove-qemu-perf.sh` | Removes the Kata drop-in config |
| `qemu-perf-logs/` | perf output directory, created automatically |

## Configure perf

Edit `qemu-perf-mode` to choose the collection mode. The default is:

```text
record
```

Valid values are:

| Mode | Output |
|---|---|
| `stat` | `qemu-perf-stat-<YYYYmmdd-HHMMSS>-<wrapper-pid>.txt` |
| `record` | `qemu-perf-record-<YYYYmmdd-HHMMSS>-<wrapper-pid>.data` |

Edit `qemu-perf-stat-events` to customize the comma-separated event list passed
to `perf stat -e`. Edit `qemu-perf-record-event` to customize the event passed
to `perf record -e`.

The default `perf stat` events are:

```text
task-clock,context-switches,cpu-migrations,page-faults,minor-faults,major-faults,cycles,instructions,cache-references,cache-misses,kvm:kvm_entry,kvm:kvm_exit,kvm:kvm_userspace_exit,kvm:kvm_page_fault,syscalls:sys_enter_openat,syscalls:sys_enter_newfstatat,syscalls:sys_enter_read,syscalls:sys_enter_pread64,syscalls:sys_enter_preadv
```

`perf stat` is configured as an exit summary. For long-running Pods, the stat
file is complete only after QEMU exits. `perf stat` and `perf record` are
mutually exclusive in this wrapper; switch `qemu-perf-mode` between `stat` and
`record` to choose one collection type per QEMU launch.

## Enable QEMU perf collection

```bash
cd qemu-perf
sudo ./deploy-qemu-perf.sh
sudo systemctl restart containerd
```

Then start a Pod with:

```yaml
runtimeClassName: kata-qemu-nvidia-gpu
```

Logs are written under:

```bash
./qemu-perf-logs/
```

## Interaction with other wrappers

Only one QEMU path wrapper should be active at a time. `deploy-qemu-perf.sh`
removes these conflicting drop-ins before installing `100-qemu-perf.toml`:

```bash
/opt/kata/share/defaults/kata-containers/runtimes/qemu-nvidia-gpu/config.d/100-qemu-observe.toml
/opt/kata/share/defaults/kata-containers/runtimes/qemu-nvidia-gpu/config.d/100-qemu-strace.toml
/opt/kata/share/defaults/kata-containers/runtimes/qemu-nvidia-gpu/config.d/100-qemu-trace.toml
```

## Disable QEMU perf collection

```bash
cd qemu-perf
sudo ./remove-qemu-perf.sh
sudo systemctl restart containerd
```

This only removes the Kata drop-in config. It does not remove the wrapper,
config files, README, or existing perf output.

## Verify

```bash
bash -n qemu-system-x86_64-perf-wrapper
bash -n deploy-qemu-perf.sh
bash -n remove-qemu-perf.sh
/usr/bin/perf --version
/usr/bin/qemu-system-x86_64 --version
```

After starting and stopping a Kata Pod:

```bash
ls -lh qemu-perf-logs/
perf report -i qemu-perf-logs/qemu-perf-record-*.data
```

If the Pod fails to start, check perf permissions and containerd logs:

```bash
cat /proc/sys/kernel/perf_event_paranoid
cat /proc/sys/kernel/kptr_restrict
sudo journalctl -u containerd -n 200 --no-pager
```
