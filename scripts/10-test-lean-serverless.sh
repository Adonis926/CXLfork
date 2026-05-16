#!/bin/bash
set -euo pipefail

WS=${WS:-/home/xtl/cxlfork-ws}
KDIR=${KDIR:-${WS}/kernel/build-6.6.32}
SRC=${SRC:-${WS}/kernel/linux-6.6.32/samples/cxlfork}
DRV=${DRV:-${WS}/kernel/linux-6.6.32/drivers/cxlfork}
VM_DIR=${VM_DIR:-/tmp/mitosis-cxl}
CXL_PHYS=${CXL_PHYS:-0x484000000}
CXL_SIZE=${CXL_SIZE:-0xfb000000}
KEY=${KEY:-210}
DATA_LEN=${DATA_LEN:-8388608}
ITERS=${ITERS:-10}
WARMUP=${WARMUP:-2}

vm0() {
  "${WS}/scripts/ssh-vm0.sh" "$@"
}

vm1() {
  "${WS}/scripts/ssh-vm1.sh" "$@"
}

copy_to_vm() {
  local port=$1

  scp \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -i ~/.ssh/id_ed25519 \
    -P "${port}" \
    "${DRV}/cxlfork_mitosis.ko" \
    "${SRC}/mitosis_cxl_lean_bench" \
    ubuntu@localhost:"${VM_DIR}/"
}

echo "[1/6] building lean serverless benchmark"
make -C "${WS}/kernel/build-6.6.32" M="${DRV}" CONFIG_CXLFORK=m CONFIG_CXLFORK_MITOSIS=m KBUILD_MODPOST_WARN=1 modules
make -C "${SRC}" KDIR="${KDIR}" KBUILD_MODPOST_WARN=1 mitosis_cxl_lean_bench

echo "[2/6] preparing VM directories"
vm0 "sudo pkill -x mitosis_cxl_lean_bench 2>/dev/null || true; mkdir -p '${VM_DIR}'"
vm1 "sudo pkill -x mitosis_cxl_lean_bench 2>/dev/null || true; mkdir -p '${VM_DIR}'"

echo "[3/6] copying module and benchmark"
copy_to_vm 2200
copy_to_vm 2201

echo "[4/6] loading mitosis_cxl module"
vm0 "cd '${VM_DIR}' && sudo rmmod cxlfork_mitosis 2>/dev/null || true; sudo insmod '${VM_DIR}/cxlfork_mitosis.ko' cxl_phys='${CXL_PHYS}' cxl_size='${CXL_SIZE}' || lsmod | grep -q '^cxlfork_mitosis '"
vm1 "cd '${VM_DIR}' && sudo rmmod cxlfork_mitosis 2>/dev/null || true; sudo insmod '${VM_DIR}/cxlfork_mitosis.ko' cxl_phys='${CXL_PHYS}' cxl_size='${CXL_SIZE}' || lsmod | grep -q '^cxlfork_mitosis '"

echo "[5/6] VM0 prepares serverless function checkpoint"
timeout 20 "${WS}/scripts/ssh-vm0.sh" "cd '${VM_DIR}' && sudo timeout 10 ./mitosis_cxl_lean_bench prepare '${KEY}' '${DATA_LEN}'" || true

echo "[6/6] VM1 invokes through lean skeleton runtime"
timeout 120 "${WS}/scripts/ssh-vm1.sh" "cd '${VM_DIR}' && sudo timeout 90 ./mitosis_cxl_lean_bench invoke '${KEY}' '${ITERS}' '${WARMUP}' '${DATA_LEN}'"
