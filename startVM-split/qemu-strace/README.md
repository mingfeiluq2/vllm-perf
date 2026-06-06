# QEMU strace wrapper for Kata qemu-nvidia-gpu

This directory contains a minimal strace wrapper for the Kata
`kata-qemu-nvidia-gpu` runtime. It replaces the configured QEMU path with a
wrapper that runs `/opt/kata/bin/qemu-system-x86_64` under `/usr/bin/strace`.

The managed Kata main configuration is:

```bash
/opt/kata/share/defaults/kata-containers/runtimes/qemu-nvidia-gpu/configuration-qemu-nvidia-gpu.toml
```

Do not edit that file directly. The deploy script writes this drop-in instead:

```bash
/opt/kata/share/defaults/kata-containers/runtimes/qemu-nvidia-gpu/config.d/100-qemu-strace.toml
```

## Files

| File | Purpose |
|---|---|
| `qemu-system-x86_64-strace-wrapper` | Runs QEMU under `strace` |
| `qemu-strace-filter` | First valid line becomes the value of `strace -e trace=` |
| `deploy-qemu-strace.sh` | Installs the Kata drop-in config |
| `remove-qemu-strace.sh` | Removes the Kata drop-in config |
| `filter-vfio-strace.sh` | Filters VFIO-related entries from strace logs |
| `qemu-strace-logs/` | strace output directory, created automatically |

## Configure syscall filter

Edit `qemu-strace-filter` to customize the value passed to `strace -e trace=`.
Do not include the `-e trace=` prefix in the file.

The wrapper uses the first non-empty, non-comment line. The default is:

```text
%file,%process,%network,ioctl,mmap,munmap,mprotect
```

## Enable strace

```bash
cd qemu-strace
sudo ./deploy-qemu-strace.sh
sudo systemctl restart containerd
```

Then start a Pod with:

```yaml
runtimeClassName: kata-qemu-nvidia-gpu
```

strace logs are written under:

```bash
./qemu-strace-logs/
```

Because the wrapper uses `strace -ff`, QEMU child processes get separate log
files with pid suffixes.

## Filter VFIO entries

After collecting logs, use:

```bash
./filter-vfio-strace.sh
```

The script scans `qemu-strace-logs/` by default and prints matching lines with
file names and line numbers. You can also pass specific files or directories:

```bash
./filter-vfio-strace.sh qemu-strace-logs/qemu-strace-*.log
```

## Disable strace

```bash
cd qemu-strace
sudo ./remove-qemu-strace.sh
sudo systemctl restart containerd
```

This only removes the Kata drop-in config. It does not remove the wrapper,
filter file, README, or existing strace logs.

## Switching between strace and QEMU trace

Only one QEMU path wrapper should be active at a time. `deploy-qemu-strace.sh`
removes `100-qemu-trace.toml` before installing `100-qemu-strace.toml`.

To collect strace and QEMU trace together from the same QEMU launch, use the
combined wrapper in `../qemu-observe`.

To switch back to QEMU trace:

```bash
cd ../qemu-trace
sudo ./deploy-qemu-trace.sh
sudo systemctl restart containerd
```

## Verify

```bash
bash -n qemu-system-x86_64-strace-wrapper
bash -n deploy-qemu-strace.sh
bash -n remove-qemu-strace.sh
bash -n filter-vfio-strace.sh
/opt/kata/bin/qemu-system-x86_64 --version
/usr/bin/strace -V
./qemu-system-x86_64-strace-wrapper --version
./filter-vfio-strace.sh | head
ls -lh qemu-strace-logs/
```

If the Pod fails to start, check:

```bash
sudo journalctl -u containerd -n 200 --no-pager
```
