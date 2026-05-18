#!/bin/bash
set -euo pipefail

WS=${WS:-/home/xtl/cxlfork-ws}
KDIR=${KDIR:-${WS}/kernel/build-6.6.32}
SRC=${SRC:-${WS}/kernel/linux-6.6.32/samples/cxlfork}
DRV=${DRV:-${WS}/kernel/linux-6.6.32/drivers/cxlfork}
VM_DIR=${VM_DIR:-/tmp/mitosis-cxl}
CXL_PHYS=${CXL_PHYS:-0x484000000}
CXL_SIZE=${CXL_SIZE:-0xfb000000}
KEY=${KEY:-212}
DATA_LEN=${DATA_LEN:-8388608}
ITERS=${ITERS:-10}
WARMUP=${WARMUP:-2}
VM=${VM:-vm0}

vm() {
  if [[ "${VM}" == "vm1" ]]; then
    "${WS}/scripts/ssh-vm1.sh" "$@"
  else
    "${WS}/scripts/ssh-vm0.sh" "$@"
  fi
}

vm_run_logged() {
  local name=$1
  local command=$2
  local log="${VM_DIR}/${name}.log"

  vm "cd '${VM_DIR}' && rm -f '${log}' && sudo sh -c '${command} >${log} 2>&1' && cat '${log}'"
}

copy_to_vm() {
  local port=$1

  scp \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -i ~/.ssh/id_ed25519 \
    -P "${port}" \
    "${DRV}/cxlfork_mitosis.ko" \
    "${SRC}/mitosis_cxl_forkctl" \
    "${SRC}/mitosis_cxl_lean_bench" \
    ubuntu@localhost:"${VM_DIR}/"
}

if [[ "${VM}" == "vm1" ]]; then
  PORT=2201
else
  PORT=2200
fi

echo "[1/6] building local lean serverless benchmark"
make -C "${WS}/kernel/build-6.6.32" M="${DRV}" CONFIG_CXLFORK=m CONFIG_CXLFORK_MITOSIS=m KBUILD_MODPOST_WARN=1 modules
make -C "${SRC}" KDIR="${KDIR}" KBUILD_MODPOST_WARN=1 mitosis_cxl_forkctl mitosis_cxl_lean_bench

echo "[2/6] preparing ${VM} directory"
vm "sudo pkill -x mitosis_cxl_lean_bench 2>/dev/null || true; mkdir -p '${VM_DIR}'"

echo "[3/6] copying module and benchmark to ${VM}"
copy_to_vm "${PORT}"

echo "[4/6] loading mitosis_cxl module on ${VM}"
vm "cd '${VM_DIR}' && sudo rmmod cxlfork_mitosis 2>/dev/null || true; sudo insmod '${VM_DIR}/cxlfork_mitosis.ko' cxl_phys='${CXL_PHYS}' cxl_size='${CXL_SIZE}' || lsmod | grep -q '^cxlfork_mitosis '"

echo "[4.5/6] clearing stale local descriptor"
vm "cd '${VM_DIR}' && sudo ./mitosis_cxl_forkctl release '${KEY}' 2>/dev/null || true"

echo "[5/6] ${VM} prepares same-node serverless function checkpoint"
vm_run_logged "lean_prepare_${KEY}" "./mitosis_cxl_lean_bench prepare ${KEY} ${DATA_LEN}"

echo "[6/6] ${VM} invokes through same-node lean skeleton runtime"
vm_run_logged "lean_invoke_${KEY}" "./mitosis_cxl_lean_bench invoke ${KEY} ${ITERS} ${WARMUP} ${DATA_LEN}"

echo "[extra] ${VM} invokes through same-node precreated lean skeleton pool"
vm_run_logged "lean_pool_${KEY}" "./mitosis_cxl_lean_bench pool ${KEY} ${ITERS} ${WARMUP} ${DATA_LEN}"
