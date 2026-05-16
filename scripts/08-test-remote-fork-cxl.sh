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
KEY7=${KEY7:-91}
KEY8=${KEY8:-92}
KEY9=${KEY9:-93}
KEY10=${KEY10:-194}
KEY11=${KEY11:-90}
KEY12=${KEY12:-195}
KEY13=${KEY13:-196}
KEY14=${KEY14:-197}
KEY15=${KEY15:-198}
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
    "${SRC}/mitosis_cxl_latency" \
    "${SRC}/mitosis_cxl_forkctl" \
    "${SRC}/mitosis_cxl_fault_bench" \
    "${SRC}/mitosis_cxl_real_resume" \
    "${SRC}/mitosis_cxl_fd_resume" \
    "${SRC}/mitosis_cxl_thread_resume" \
    "${SRC}/mitosis_cxl_pthread_resume" \
    "${SRC}/mitosis_cxl_os_state_resume" \
    ubuntu@localhost:"${VM_DIR}/"
}

echo "[1/7] building remote-fork CXL sample"
make -C "${WS}/kernel/build-6.6.32" M="${DRV}" CONFIG_CXLFORK=m CONFIG_CXLFORK_MITOSIS=m KBUILD_MODPOST_WARN=1 modules
make -C "${SRC}" KDIR="${KDIR}" KBUILD_MODPOST_WARN=1

echo "[2/7] preparing VM directories"
vm0 "sudo pkill -x mitosis_cxl_pid_target 2>/dev/null || true; mkdir -p '${VM_DIR}'"
vm1 "sudo pkill -x mitosis_cxl_pid_target 2>/dev/null || true; mkdir -p '${VM_DIR}'"

echo "[3/7] copying module and test binaries"
copy_to_vm 2200
copy_to_vm 2201

echo "[4/7] loading mitosis_cxl module"
vm0 "cd '${VM_DIR}' && sudo rmmod cxlfork_mitosis 2>/dev/null || true; sudo rmmod mitosis_cxl 2>/dev/null || true; sudo insmod '${VM_DIR}/cxlfork_mitosis.ko' cxl_phys='${CXL_PHYS}' cxl_size='${CXL_SIZE}' || lsmod | grep -q '^cxlfork_mitosis '"
vm1 "cd '${VM_DIR}' && sudo rmmod cxlfork_mitosis 2>/dev/null || true; sudo rmmod mitosis_cxl 2>/dev/null || true; sudo insmod '${VM_DIR}/cxlfork_mitosis.ko' cxl_phys='${CXL_PHYS}' cxl_size='${CXL_SIZE}' || lsmod | grep -q '^cxlfork_mitosis '"

echo "[4.5/7] clearing stale CXL fork descriptors"
vm0 "cd '${VM_DIR}' && for k in '${KEY}' '${KEY2}' '${KEY3}' '${KEY4}' '${KEY5}' '${KEY6}' '${KEY7}' '${KEY8}' '${KEY9}' '${KEY10}' '${KEY11}' '${KEY12}' '${KEY13}' '${KEY14}' '${KEY15}' 199 200 201 210; do sudo ./mitosis_cxl_forkctl release \"\${k}\" 2>/dev/null || true; done"

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

echo "[extra] VM0 measures same-node Mitosis-style lazy-shadow fork latency"
vm0 "cd '${VM_DIR}' && sudo ./mitosis_cxl_latency 90 '${SCAN_REGIONS}' '${SCAN_LENGTH}'"

echo "[extra] VM0/VM1 exercise stable fork_prepare/fork_resume/fork_release API"
vm0 "cd '${VM_DIR}' && rm -f forkctl-target.log forkctl-target.pid && setsid -f sudo ./mitosis_cxl_pid_target '${KEY12}' '${SCAN_REGIONS}' '${SCAN_LENGTH}' '${PID_BASE}' > forkctl-target.log 2>&1 < /dev/null"
vm0 "cd '${VM_DIR}' && for i in \$(seq 1 20); do grep -q 'pid_target pid=' forkctl-target.log 2>/dev/null && break; sleep 0.2; done; cat forkctl-target.log; sed -n 's/.*pid=\\([0-9][0-9]*\\).*/\\1/p' forkctl-target.log > forkctl-target.pid"
vm0 "cd '${VM_DIR}' && sudo ./mitosis_cxl_forkctl prepare '${KEY12}' \$(cat forkctl-target.pid) '${PID_BASE}' \$(( ${PID_BASE} + ${SCAN_REGIONS} * 0x200000000 + ${SCAN_LENGTH} ))"
vm1 "cd '${VM_DIR}' && sudo ./mitosis_cxl_forkctl resume '${KEY12}' --touch"
vm0 "cd '${VM_DIR}' && sudo ./mitosis_cxl_forkctl release '${KEY12}' && sudo kill \$(cat forkctl-target.pid)"

echo "[extra] VM1 benchmarks single-thread remote page fault latency"
vm0 "cd '${VM_DIR}' && rm -f faultbench-target.log faultbench-target.pid && setsid -f sudo ./mitosis_cxl_pid_target '${KEY13}' '${SCAN_REGIONS}' '${SCAN_LENGTH}' '${PID_BASE}' > faultbench-target.log 2>&1 < /dev/null"
vm0 "cd '${VM_DIR}' && for i in \$(seq 1 20); do grep -q 'pid_target pid=' faultbench-target.log 2>/dev/null && break; sleep 0.2; done; cat faultbench-target.log; sed -n 's/.*pid=\\([0-9][0-9]*\\).*/\\1/p' faultbench-target.log > faultbench-target.pid"
vm0 "cd '${VM_DIR}' && sudo ./mitosis_cxl_forkctl prepare '${KEY13}' \$(cat faultbench-target.pid) '${PID_BASE}' \$(( ${PID_BASE} + ${SCAN_REGIONS} * 0x200000000 + ${SCAN_LENGTH} ))"
vm1 "cd '${VM_DIR}' && sudo ./mitosis_cxl_fault_bench '${KEY13}' 1"
vm0 "cd '${VM_DIR}' && sudo ./mitosis_cxl_forkctl release '${KEY13}' && sudo kill \$(cat faultbench-target.pid)"

echo "[extra] VM1 benchmarks concurrent remote page fault latency"
vm0 "cd '${VM_DIR}' && rm -f faultbench-target.log faultbench-target.pid && setsid -f sudo ./mitosis_cxl_pid_target '${KEY14}' '${SCAN_REGIONS}' '${SCAN_LENGTH}' '${PID_BASE}' > faultbench-target.log 2>&1 < /dev/null"
vm0 "cd '${VM_DIR}' && for i in \$(seq 1 20); do grep -q 'pid_target pid=' faultbench-target.log 2>/dev/null && break; sleep 0.2; done; cat faultbench-target.log; sed -n 's/.*pid=\\([0-9][0-9]*\\).*/\\1/p' faultbench-target.log > faultbench-target.pid"
vm0 "cd '${VM_DIR}' && sudo ./mitosis_cxl_forkctl prepare '${KEY14}' \$(cat faultbench-target.pid) '${PID_BASE}' \$(( ${PID_BASE} + ${SCAN_REGIONS} * 0x200000000 + ${SCAN_LENGTH} ))"
vm1 "cd '${VM_DIR}' && sudo ./mitosis_cxl_fault_bench '${KEY14}' 4"
vm0 "cd '${VM_DIR}' && sudo ./mitosis_cxl_forkctl release '${KEY14}' && sudo kill \$(cat faultbench-target.pid)"

echo "[extra] VM0 real-resumes into checkpointed user registers"
vm0 "cd '${VM_DIR}' && sudo ./mitosis_cxl_real_resume '${KEY7}'"


echo "[extra] VM0 prepares a cross-VM real-resume checkpoint"
timeout 20 "${WS}/scripts/ssh-vm0.sh" "cd '${VM_DIR}' && sudo timeout 10 ./mitosis_cxl_real_resume prepare '${KEY10}'" || true

echo "[extra] VM1 resumes VM0 checkpointed registers with CXL remote paging"
timeout 20 "${WS}/scripts/ssh-vm1.sh" "cd '${VM_DIR}' && sudo timeout 10 ./mitosis_cxl_real_resume resume '${KEY10}'"



echo "[extra] VM0 prepares a cross-VM fd checkpoint"
vm1 "echo mitosis-cxl-fd-ok > '${VM_DIR}/fd-${KEY11}.txt'"
timeout 20 "${WS}/scripts/ssh-vm0.sh" "cd '${VM_DIR}' && sudo timeout 10 ./mitosis_cxl_fd_resume prepare '${KEY11}'" || true

echo "[extra] VM1 restores regular-file fd state from CXL"
timeout 20 "${WS}/scripts/ssh-vm1.sh" "cd '${VM_DIR}' && sudo timeout 10 ./mitosis_cxl_fd_resume resume '${KEY11}'"

echo "[extra] VM0 prepares cross-VM fd alias and fs_struct state"
vm1 "mkdir -p '${VM_DIR}/osstate-${KEY15}' && printf '0123456789abcdef\n' > '${VM_DIR}/osstate-${KEY15}/state.txt'"
timeout 20 "${WS}/scripts/ssh-vm0.sh" "cd '${VM_DIR}' && sudo timeout 10 ./mitosis_cxl_os_state_resume prepare '${KEY15}'" || true

echo "[extra] VM1 restores fd alias graph, cwd, and umask state"
timeout 20 "${WS}/scripts/ssh-vm1.sh" "cd '${VM_DIR}' && sudo timeout 10 ./mitosis_cxl_os_state_resume resume '${KEY15}'"

echo "[extra] VM0 prepares a cross-VM non-main thread checkpoint"
timeout 20 "${WS}/scripts/ssh-vm0.sh" "cd '${VM_DIR}' && sudo timeout 10 ./mitosis_cxl_thread_resume prepare '${KEY8}'" || true

echo "[extra] VM1 resumes VM0 non-main thread registers with CXL remote paging"
timeout 20 "${WS}/scripts/ssh-vm1.sh" "cd '${VM_DIR}' && sudo timeout 10 ./mitosis_cxl_thread_resume resume '${KEY8}'"

echo "[extra] VM0 restores a non-main thread register frame"
vm0 "cd '${VM_DIR}' && sudo ./mitosis_cxl_thread_resume '${KEY8}'"


echo "[extra] VM0 prepares a cross-VM pthread TLS checkpoint"
timeout 20 "${WS}/scripts/ssh-vm0.sh" "cd '${VM_DIR}' && sudo timeout 10 ./mitosis_cxl_pthread_resume prepare '${KEY9}'" || true

echo "[extra] VM1 resumes VM0 pthread TLS threads with CXL remote paging"
timeout 20 "${WS}/scripts/ssh-vm1.sh" "cd '${VM_DIR}' && sudo timeout 10 ./mitosis_cxl_pthread_resume resume '${KEY9}'"

echo "[extra] VM0 restores pthread TLS and a non-main thread frame"
vm0 "cd '${VM_DIR}' && sudo ./mitosis_cxl_pthread_resume '${KEY9}'"
