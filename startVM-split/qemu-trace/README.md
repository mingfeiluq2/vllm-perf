# QEMU trace wrapper for Kata qemu-nvidia-gpu

This directory contains a minimal QEMU wrapper for enabling QEMU trace in the
Kata `kata-qemu-nvidia-gpu` runtime by replacing the configured QEMU path with a
drop-in TOML file.

The managed Kata main configuration is:

```bash
/opt/kata/share/defaults/kata-containers/runtimes/qemu-nvidia-gpu/configuration-qemu-nvidia-gpu.toml
```

Do not edit that file directly. The deploy script writes this drop-in instead:

```bash
/opt/kata/share/defaults/kata-containers/runtimes/qemu-nvidia-gpu/config.d/100-qemu-trace.toml
```

## Files

| File | Purpose |
|---|---|
| `qemu-system-x86_64-trace-wrapper` | Calls `/opt/kata/bin/qemu-system-x86_64` and appends `-trace` |
| `qemu-trace-events` | QEMU trace event patterns |
| `deploy-qemu-trace.sh` | Installs the Kata drop-in config |
| `remove-qemu-trace.sh` | Removes the Kata drop-in config |
| `qemu-trace-logs/` | Trace output directory, created automatically |

## Enable trace

```bash
cd qemu-trace
sudo ./deploy-qemu-trace.sh
sudo systemctl restart containerd
```

Then start a Pod with:

```yaml
runtimeClassName: kata-qemu-nvidia-gpu
```

Trace logs are written under:

```bash
./qemu-trace-logs/
```

To collect QEMU trace and strace together from the same QEMU launch, use the
combined wrapper in `../qemu-observe`.

## Disable trace

```bash
cd qemu-trace
sudo ./remove-qemu-trace.sh
sudo systemctl restart containerd
```

This only removes the Kata drop-in config. It does not remove the wrapper,
events file, README, or existing trace logs.

## Verify

```bash
bash -n qemu-system-x86_64-trace-wrapper
bash -n deploy-qemu-trace.sh
bash -n remove-qemu-trace.sh
/opt/kata/bin/qemu-system-x86_64 --version
/opt/kata/bin/qemu-system-x86_64 -trace help | head
```

After starting a Kata Pod:

```bash
ls -lh qemu-trace-logs/
```

If the Pod fails to start, check:

```bash
sudo journalctl -u containerd -n 200 --no-pager
```
