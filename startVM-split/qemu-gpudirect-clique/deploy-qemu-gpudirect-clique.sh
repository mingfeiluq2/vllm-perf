#!/usr/bin/env bash
set -euo pipefail

KATA_CONFIG_D="${KATA_CONFIG_D:-/opt/kata/share/defaults/kata-containers/runtimes/qemu-nvidia-gpu/config.d}"
DROP_IN="${KATA_CONFIG_D}/100-qemu-gpudirect-clique.toml"
REAL_QEMU="/opt/kata/bin/qemu-system-x86_64"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="${SCRIPT_DIR}/qemu-system-x86_64-gpudirect-clique-wrapper"

has_qemu_path_override() {
    local config="$1"

    awk '
        /^[[:space:]]*\[hypervisor\.qemu\][[:space:]]*(#.*)?$/ {
            in_qemu = 1
            next
        }
        /^[[:space:]]*\[/ {
            in_qemu = 0
        }
        in_qemu && /^[[:space:]]*path[[:space:]]*=/ {
            found = 1
        }
        END {
            exit(found ? 0 : 1)
        }
    ' "${config}"
}

if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: run this script as root because Kata config.d is root-owned" >&2
    exit 1
fi

if [[ ! -x "${REAL_QEMU}" ]]; then
    echo "ERROR: real QEMU not found or not executable: ${REAL_QEMU}" >&2
    exit 1
fi

if [[ ! -x "${WRAPPER}" ]]; then
    echo "ERROR: wrapper not found or not executable: ${WRAPPER}" >&2
    exit 1
fi

if [[ ! -d "${KATA_CONFIG_D}" ]]; then
    echo "ERROR: Kata config.d not found: ${KATA_CONFIG_D}" >&2
    exit 1
fi

conflicts=()
shopt -s nullglob
for config in "${KATA_CONFIG_D}"/*.toml; do
    [[ "${config}" == "${DROP_IN}" ]] && continue
    if has_qemu_path_override "${config}"; then
        conflicts+=("${config}")
    fi
done
shopt -u nullglob

if ((${#conflicts[@]} > 0)); then
    echo "ERROR: another QEMU path wrapper drop-in is active:" >&2
    printf '  %s\n' "${conflicts[@]}" >&2
    echo "Remove or disable it before deploying this wrapper." >&2
    exit 1
fi

tmp_drop_in="$(mktemp "${KATA_CONFIG_D}/.${DROP_IN##*/}.XXXXXX")"
trap 'rm -f "${tmp_drop_in}"' EXIT

cat > "${tmp_drop_in}" <<EOF
[hypervisor.qemu]
path = "${WRAPPER}"
valid_hypervisor_paths = [
  "${REAL_QEMU}",
  "${WRAPPER}",
]
EOF

chmod 0644 "${tmp_drop_in}"
mv -f "${tmp_drop_in}" "${DROP_IN}"
trap - EXIT

echo "Installed Kata QEMU GPUDirect clique drop-in:"
echo "  ${DROP_IN}"
echo
echo "Restart containerd and recreate the Kata Pod to apply it:"
echo "  sudo systemctl restart containerd"
