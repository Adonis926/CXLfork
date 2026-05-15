#!/bin/bash
set -euo pipefail

WS=${WS:-/home/xtl/cxlfork-ws}
KDIR=${KDIR:-${WS}/kernel/build-6.6.32}
SRC=${SRC:-${WS}/kernel/linux-6.6.32/samples/cxlfork}
DRV=${DRV:-${WS}/kernel/linux-6.6.32/drivers/cxlfork}
VM_DIR=${VM_DIR:-/tmp/mitosis-cxl}
CXL_PHYS=${CXL_PHYS:-0x484000000}
CXL_SIZE=${CXL_SIZE:-0xfb000000}
KEY=${KEY:-73}
KEY2=${KEY2:-74}
KEY3=${KEY3:-75}
KEY4=${KEY4:-76}
KEY5=${KEY5:-78}
KEY6=${KEY6:-79}
LENGTH=${LENGTH:-4194304}
SCAN_REGIONS=${SCAN_REGIONS:-8}
SCAN_LENGTH=${SCAN_LENGTH:-1048576}
PID_BASE=${PID_BASE:-0x720000000000}

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
    "${SRC}/mitosis_cxl_parent" \
    "${SRC}/mitosis_cxl_child" \
    "${SRC}/mitosis_cxl_runtime" \
    "${SRC}/mitosis_cxl_pid_target" \
    "${SRC}/mitosis_cxl_pid_prepare" \
    "${SRC}/mitosis_cxl_fork_demo" \
    "${SRC}/mitosis_cxl_regs_demo" \
    ubuntu@localhost:"${VM_DIR}/"
}

echo "[1/7] building remote-fork CXL sample"
make -C "${WS}/kernel/build-6.6.32" M="${DRV}" CONFIG_CXLFORK=m CONFIG_CXLFORK_MITOSIS=m KBUILD_MODPOST_WARN=1 modules
make -C "${SRC}" KDIR="${KDIR}" KBUILD_MODPOST_WARN=1

echo "[2/7] preparing VM directories"
vm0 "mkdir -p '${VM_DIR}'"
vm1 "mkdir -p '${VM_DIR}'"

echo "[3/7] copying module and test binaries"
copy_to_vm 2200
copy_to_vm 2201

echo "[4/7] loading mitosis_cxl module"
vm0 "cd '${VM_DIR}' && sudo rmmod cxlfork_mitosis 2>/dev/null || true; sudo rmmod mitosis_cxl 2>/dev/null || true; sudo insmod '${VM_DIR}/cxlfork_mitosis.ko' cxl_phys='${CXL_PHYS}' cxl_size='${CXL_SIZE}'"
vm1 "cd '${VM_DIR}' && sudo rmmod cxlfork_mitosis 2>/dev/null || true; sudo rmmod mitosis_cxl 2>/dev/null || true; sudo insmod '${VM_DIR}/cxlfork_mitosis.ko' cxl_phys='${CXL_PHYS}' cxl_size='${CXL_SIZE}'"

echo "[5/7] VM0 prepare into shared CXL memory, then mutate parent memory"
vm0 "cd '${VM_DIR}' && sudo ./mitosis_cxl_parent '${KEY}' '${LENGTH}'"

echo "[6/7] VM1 resume, verify snapshot, and write local private pages"
vm1 "cd '${VM_DIR}' && sudo ./mitosis_cxl_child '${KEY}' --write-private"

echo "[7/7] VM1 second resume verifies CXL snapshot was not modified by child writes"
vm1 "cd '${VM_DIR}' && sudo ./mitosis_cxl_child '${KEY}'"

echo "[extra] VM0 prepares a second handler key into a separate descriptor slot"
vm0 "cd '${VM_DIR}' && sudo ./mitosis_cxl_parent '${KEY2}' '${LENGTH}'"

echo "[extra] VM1 restores both handler keys by descriptor lookup"
vm1 "cd '${VM_DIR}' && sudo ./mitosis_cxl_child '${KEY}'"
vm1 "cd '${VM_DIR}' && sudo ./mitosis_cxl_child '${KEY2}'"

echo "[extra] VM0 runtime scans /proc/self/maps into a multi-VMA descriptor"
vm0 "cd '${VM_DIR}' && sudo ./mitosis_cxl_runtime prepare '${KEY3}' '${SCAN_REGIONS}' '${SCAN_LENGTH}'"

echo "[extra] VM1 runtime restores scanned VMAs and verifies private writes"
vm1 "cd '${VM_DIR}' && sudo ./mitosis_cxl_runtime apply '${KEY3}' --write-private"
vm1 "cd '${VM_DIR}' && sudo ./mitosis_cxl_runtime resume '${KEY3}'"

echo "[extra] VM0 checkpoints another process by pid"
vm0 "cd '${VM_DIR}' && rm -f pid-target.log pid-target.pid && setsid -f sudo ./mitosis_cxl_pid_target '${KEY4}' '${SCAN_REGIONS}' '${SCAN_LENGTH}' '${PID_BASE}' > pid-target.log 2>&1 < /dev/null"
vm0 "cd '${VM_DIR}' && for i in \$(seq 1 20); do grep -q 'pid_target pid=' pid-target.log 2>/dev/null && break; sleep 0.2; done; cat pid-target.log; sed -n 's/.*pid=\\([0-9][0-9]*\\).*/\\1/p' pid-target.log > pid-target.pid"
vm0 "cd '${VM_DIR}' && sudo ./mitosis_cxl_pid_prepare '${KEY4}' \$(cat pid-target.pid) '${SCAN_REGIONS}' '${SCAN_LENGTH}' '${PID_BASE}'"
vm0 "cd '${VM_DIR}' && sudo kill \$(cat pid-target.pid)"

echo "[extra] VM1 restores the pid checkpoint descriptor"
vm1 "cd '${VM_DIR}' && sudo ./mitosis_cxl_runtime apply '${KEY4}' --write-private"
vm1 "cd '${VM_DIR}' && sudo ./mitosis_cxl_runtime resume '${KEY4}'"

echo "[extra] VM0 stores fork-like process state with a resume entry"
vm0 "cd '${VM_DIR}' && sudo ./mitosis_cxl_fork_demo prepare '${KEY5}'"

echo "[extra] VM1 resumes through the stored child entry from kernel ioctl return"
vm1 "cd '${VM_DIR}' && sudo ./mitosis_cxl_fork_demo resume-kernel '${KEY5}'"

echo "[extra] VM0 serializes real ptrace register state into CXL"
vm0 "cd '${VM_DIR}' && sudo ./mitosis_cxl_regs_demo capture '${KEY6}'"

echo "[extra] VM1 restores real ptrace register state into a tracee"
vm1 "cd '${VM_DIR}' && sudo ./mitosis_cxl_regs_demo restore '${KEY6}'"
