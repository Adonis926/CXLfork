#!/bin/bash
set -euo pipefail

WS=/home/xtl/cxlfork-ws
CXL_SHM=/dev/shm/cxl_mem
USE_CUSTOM_KERNEL=${USE_CUSTOM_KERNEL:-1}
KERNEL_IMAGE=${KERNEL_IMAGE:-${WS}/kernel/build-6.6.32/arch/x86/boot/bzImage}
KERNEL_APPEND=${KERNEL_APPEND:-"root=/dev/vda1 rw console=ttyS0 earlyprintk=ttyS0 nokaslr net.ifnames=0 cxlfork.cxl_phys=0x484000000 cxlfork.cxl_size=0xfb000000"}

SEED_CDROM="-drive file=${WS}/cloudinit/vm0-seed.iso,media=cdrom,if=virtio,format=raw,readonly=on"
KERNEL_BOOT=()
if [[ "${USE_CUSTOM_KERNEL}" == "1" ]]; then
  [[ -f "${KERNEL_IMAGE}" ]] || { echo "missing kernel: ${KERNEL_IMAGE}" >&2; exit 1; }
  KERNEL_BOOT=(-kernel "${KERNEL_IMAGE}" -append "${KERNEL_APPEND}")
fi

qemu-system-x86_64 \
  -name vm0 \
  -machine q35,accel=kvm,nvdimm=on \
  -cpu host \
  -smp 16,sockets=1,cores=16,threads=1 \
  -m 16G,slots=1,maxmem=20G \
  -object memory-backend-file,id=cxlmem,share=on,mem-path=${CXL_SHM},size=4G \
  -device nvdimm,id=cxldev,memdev=cxlmem,label-size=16M \
  -drive file=${WS}/images/vm0.qcow2,if=virtio,cache=writeback,format=qcow2 \
  ${SEED_CDROM} \
  "${KERNEL_BOOT[@]}" \
  -netdev user,id=mgmt,hostfwd=tcp::2200-:22 \
  -device virtio-net-pci,netdev=mgmt,mac=52:54:00:12:00:01 \
  -netdev socket,id=data,mcast=230.0.0.1:1234 \
  -device virtio-net-pci,netdev=data,mac=52:54:00:12:01:01 \
  -serial file:${WS}/logs/vm0-console.log \
  -monitor unix:${WS}/sockets/vm0-monitor.sock,server,nowait \
  -pidfile ${WS}/pids/vm0.pid \
  -display none \
  -daemonize

echo "[VM0 started] SSH: ssh -p 2200 ubuntu@10.0.16.104"
echo "[Kernel] $([[ "${USE_CUSTOM_KERNEL}" == "1" ]] && echo "${KERNEL_IMAGE}" || echo guest default)"
echo "[Console log] tail -f ${WS}/logs/vm0-console.log"

