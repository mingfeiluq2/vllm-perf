# Kata QEMU GPUDirect clique wrapper

本目录为 `kata-qemu-nvidia-gpu` runtime 提供一个 QEMU path wrapper。它保留真实的
`/opt/kata/bin/qemu-system-x86_64`，并在 Kata 绑定 NVIDIA 显示类 VFIO GPU 时为
对应的 `-device vfio-pci,...` 参数追加：

```text
x-nv-gpudirect-clique=0
```

同一个 Kata VM 内缺少显式 clique 配置的 GPU 因此会使用 clique `0`。如果参数已经
包含 `x-nv-gpudirect-clique`，wrapper 会保留原值，并将设备 BDF 和现有值写入
stderr，不会重复添加或覆盖。

## 设备识别

wrapper 从 `vfio-pci` 参数的 `host=` 字段取得宿主机 PCI BDF，并读取：

- `/sys/bus/pci/devices/<BDF>/vendor`，必须为 `0x10de`；
- `/sys/bus/pci/devices/<BDF>/class`，必须以 `0x03` 开头。

因此 NVIDIA 音频功能、其他厂商的 VFIO 设备和非 VFIO 设备不会被修改。如果参数
缺少 `host=`，或者 sysfs 中的 vendor/class 无法读取，wrapper 会输出警告并原样
转发该设备参数。

## 文件

| 文件 | 用途 |
|---|---|
| `qemu-system-x86_64-gpudirect-clique-wrapper` | 修改匹配的 QEMU `-device` 参数并执行真实 QEMU |
| `deploy-qemu-gpudirect-clique.sh` | 安装 Kata `config.d` path drop-in |
| `remove-qemu-gpudirect-clique.sh` | 删除本 wrapper 的 drop-in |

## 部署

部署脚本不会替换真实 QEMU。它在以下默认目录写入
`100-qemu-gpudirect-clique.toml`：

```text
/opt/kata/share/defaults/kata-containers/runtimes/qemu-nvidia-gpu/config.d
```

同一 runtime 只能启用一个 QEMU path wrapper。如果其他 `.toml` 已经在
`[hypervisor.qemu]` 中设置 `path`，部署脚本会报告冲突文件并退出，不会覆盖现有
perf、strace、trace 或 observe wrapper。

```bash
cd startVM-split/qemu-gpudirect-clique
sudo ./deploy-qemu-gpudirect-clique.sh
sudo systemctl restart containerd
```

重启 containerd 后，需要删除并重新创建 Kata Pod；现有 QEMU 进程不会改变。如果
Kata drop-in 目录不同，可通过 `KATA_CONFIG_D` 覆盖：

```bash
sudo KATA_CONFIG_D=/path/to/config.d ./deploy-qemu-gpudirect-clique.sh
```

## 验证

在宿主机检查新建 Kata VM 的 QEMU 命令行：

```bash
pid=$(pgrep -f '^.*/qemu-system-x86_64.*sandbox-' | head -n 1)
tr '\0' '\n' < "/proc/${pid}/cmdline" | grep 'vfio-pci'
```

每个目标 GPU 的参数应包含 `x-nv-gpudirect-clique=0`。wrapper 自身的注入或保留
信息会写入 containerd 日志。还可以在 Pod 内检查 GPU P2P：

```bash
nvidia-smi topo -p2p r
python3 -c 'import torch; print(torch.cuda.can_device_access_peer(0, 1))'
```

该 QEMU 属性只描述 GPUDirect P2P DMA clique，不能让物理拓扑或宿主机原本不支持
P2P 的 GPU 获得 P2P 能力。

## 本地参数测试

`QEMU_GPUDIRECT_REAL_QEMU` 和 `QEMU_GPUDIRECT_PCI_SYSFS_ROOT` 可用于无 VM 的参数
测试。例如准备包含 `vendor`、`class` 文件的临时 PCI sysfs 后运行：

```bash
QEMU_GPUDIRECT_REAL_QEMU=/bin/echo \
QEMU_GPUDIRECT_PCI_SYSFS_ROOT=/tmp/fake-pci \
./qemu-system-x86_64-gpudirect-clique-wrapper \
  -machine q35 \
  -device 'vfio-pci,host=0000:01:00.0,bus=rp0'
```

## 卸载

```bash
cd startVM-split/qemu-gpudirect-clique
sudo ./remove-qemu-gpudirect-clique.sh
sudo systemctl restart containerd
```

卸载脚本只删除 `100-qemu-gpudirect-clique.toml`，不会删除 wrapper 或修改其他
drop-in。重启 containerd 后仍需重新创建 Kata Pod。
