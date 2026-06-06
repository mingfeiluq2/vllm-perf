# Combined QEMU strace and trace wrapper for Kata qemu-nvidia-gpu

This directory contains a QEMU wrapper for the Kata `kata-qemu-nvidia-gpu`
runtime that collects both Linux `strace` output and QEMU `-trace` output from
the same QEMU launch.

The wrapper runs `/opt/kata/bin/qemu-system-x86_64` under `/usr/bin/strace` and
also passes QEMU these options:

```bash
-trace events=<qemu-trace-events>,file=<qemu-trace-log> -msg timestamp=on
```

The managed Kata main configuration is:

```bash
/opt/kata/share/defaults/kata-containers/runtimes/qemu-nvidia-gpu/configuration-qemu-nvidia-gpu.toml
```

Do not edit that file directly. The deploy script writes this drop-in instead:

```bash
/opt/kata/share/defaults/kata-containers/runtimes/qemu-nvidia-gpu/config.d/100-qemu-observe.toml
```

## Files

| File | Purpose |
|---|---|
| `qemu-system-x86_64-observe-wrapper` | Runs QEMU under `strace` and enables QEMU `-trace` |
| `qemu-strace-filter` | First valid line becomes the value of `strace -e trace=` |
| `qemu-trace-events` | QEMU trace event patterns |
| `deploy-qemu-observe.sh` | Installs the combined Kata drop-in config |
| `remove-qemu-observe.sh` | Removes the combined Kata drop-in config |
| `qemu-observe-logs/` | Combined output directory, created automatically |

## Configure filters

Edit `qemu-strace-filter` to customize the value passed to `strace -e trace=`.
Do not include the `-e trace=` prefix in the file. The wrapper uses the first
non-empty, non-comment line.

Edit `qemu-trace-events` to customize QEMU event patterns passed to
`-trace events=...`.

## Enable combined collection

```bash
cd qemu-observe
sudo ./deploy-qemu-observe.sh
sudo systemctl restart containerd
```

Then start a Pod with:

```yaml
runtimeClassName: kata-qemu-nvidia-gpu
```

Logs are written under:

```bash
./qemu-observe-logs/
```

Each QEMU launch gets a shared run id in both file names:

```text
qemu-strace-<YYYYmmdd-HHMMSS>-<wrapper-pid>.log
qemu-trace-<YYYYmmdd-HHMMSS>-<wrapper-pid>.log
```

## Interaction with single-mode wrappers

Only one QEMU path wrapper should be active at a time. `deploy-qemu-observe.sh`
removes these conflicting drop-ins before installing `100-qemu-observe.toml`:

```bash
/opt/kata/share/defaults/kata-containers/runtimes/qemu-nvidia-gpu/config.d/100-qemu-strace.toml
/opt/kata/share/defaults/kata-containers/runtimes/qemu-nvidia-gpu/config.d/100-qemu-trace.toml
```

## Disable combined collection

```bash
cd qemu-observe
sudo ./remove-qemu-observe.sh
sudo systemctl restart containerd
```

This only removes the Kata drop-in config. It does not remove the wrapper,
filter file, events file, README, or existing logs.

## Verify

```bash
bash -n qemu-system-x86_64-observe-wrapper
bash -n deploy-qemu-observe.sh
bash -n remove-qemu-observe.sh
/opt/kata/bin/qemu-system-x86_64 --version
/opt/kata/bin/qemu-system-x86_64 -trace help | head
/usr/bin/strace -V
```

After starting a Kata Pod:

```bash
ls -lh qemu-observe-logs/
```

If the Pod fails to start, check:

```bash
sudo journalctl -u containerd -n 200 --no-pager
```
