#!/bin/bash
set -euo pipefail

WS=${WS:-/home/xtl/cxlfork-ws}
KDIR=${KDIR:-${WS}/kernel/build-6.6.32}
SRC=${SRC:-${WS}/kernel/linux-6.6.32/samples/cxlfork}
VM_DIR=${VM_DIR:-/tmp/mitosis-cxl}
CXL_PHYS=${CXL_PHYS:-0x484000000}
CXL_SIZE=${CXL_SIZE:-0xfb000000}
KEY=${KEY:-73}
LENGTH=${LENGTH:-4194304}

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
    "${SRC}/mitosis_cxl.ko" \
    "${SRC}/mitosis_cxl_parent" \
    "${SRC}/mitosis_cxl_child" \
    ubuntu@localhost:"${VM_DIR}/"
}

echo "[1/7] building remote-fork CXL sample"
make -C "${SRC}" KDIR="${KDIR}" KBUILD_MODPOST_WARN=1

echo "[2/7] preparing VM directories"
vm0 "mkdir -p '${VM_DIR}'"
vm1 "mkdir -p '${VM_DIR}'"

echo "[3/7] copying module and test binaries"
copy_to_vm 2200
copy_to_vm 2201

echo "[4/7] loading mitosis_cxl module"
vm0 "cd '${VM_DIR}' && sudo rmmod mitosis_cxl 2>/dev/null || true; sudo insmod '${VM_DIR}/mitosis_cxl.ko' cxl_phys='${CXL_PHYS}' cxl_size='${CXL_SIZE}'"
vm1 "cd '${VM_DIR}' && sudo rmmod mitosis_cxl 2>/dev/null || true; sudo insmod '${VM_DIR}/mitosis_cxl.ko' cxl_phys='${CXL_PHYS}' cxl_size='${CXL_SIZE}'"

echo "[5/7] VM0 prepare into shared CXL memory, then mutate parent memory"
vm0 "cd '${VM_DIR}' && sudo ./mitosis_cxl_parent '${KEY}' '${LENGTH}'"

echo "[6/7] VM1 resume, verify snapshot, and write local private pages"
vm1 "cd '${VM_DIR}' && sudo ./mitosis_cxl_child '${KEY}' --write-private"

echo "[7/7] VM1 second resume verifies CXL snapshot was not modified by child writes"
vm1 "cd '${VM_DIR}' && sudo ./mitosis_cxl_child '${KEY}'"
