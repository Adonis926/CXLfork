#!/usr/bin/env bash
set -euo pipefail

WS=${WS:-/home/xtl/cxlfork-ws}
KERNEL=${KERNEL:-$WS/kernel/linux-6.6.32-cxlfork}
KBUILD=${KBUILD:-$WS/kernel/build-6.6.32}
CXL_PHYS=${CXL_PHYS:-0x484000000}
CXL_SIZE=${CXL_SIZE:-0xfb000000}
VM0_PORT=${VM0_PORT:-2200}
VM1_PORT=${VM1_PORT:-2201}
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)

vm_ssh() {
	local port=$1
	shift
	ssh "${SSH_OPTS[@]}" -p "$port" ubuntu@localhost "$@"
}

vm_scp() {
	local port=$1
	shift
	scp -P "$port" "${SSH_OPTS[@]}" "$@"
}

build_artifacts() {
	make -C "$KBUILD" M="$KERNEL/drivers/cxlfork" CONFIG_CXLFORK=m \
		KBUILD_MODPOST_WARN=1 modules
	make -C "$KERNEL/samples/cxlfork" KDIR="$KBUILD" clean all
}

deploy_one() {
	local port=$1

	vm_ssh "$port" "mkdir -p /tmp/cxlfork"
	vm_scp "$port" "$KERNEL/drivers/cxlfork/cxlfork.ko" \
		"$KERNEL/samples/cxlfork/cxlfork_demo" \
		"$KERNEL/samples/cxlfork/cxlfork_fork_demo" \
		"$KERNEL/samples/cxlfork/cxlfork_context_demo" \
		"$KERNEL/samples/cxlfork/cxlfork_regs_demo" \
		ubuntu@localhost:/tmp/cxlfork/
	vm_ssh "$port" "sudo rmmod cxlfork 2>/dev/null || true; sudo insmod /tmp/cxlfork/cxlfork.ko cxl_phys=$CXL_PHYS cxl_size=$CXL_SIZE"
}

run_demo() {
	local port=$1
	shift
	vm_ssh "$port" "sudo /tmp/cxlfork/cxlfork_demo $*"
}

run_fork_demo() {
	local port=$1
	shift
	vm_ssh "$port" "sudo /tmp/cxlfork/cxlfork_fork_demo $*"
}

run_context_demo() {
	local port=$1
	shift
	vm_ssh "$port" "sudo /tmp/cxlfork/cxlfork_context_demo $*"
}

run_regs_demo() {
	local port=$1
	shift
	vm_ssh "$port" "sudo /tmp/cxlfork/cxlfork_regs_demo $*"
}

main() {
	local key_base=${1:-970}
	local len=${2:-1048576}
	local key_shared=$key_base
	local key_cow=$((key_base + 1))
	local key_multi=$((key_base + 2))
	local key_fork=$((key_base + 3))
	local key_context=$((key_base + 4))
	local key_apply_mm=$((key_base + 5))
	local key_reopen_fds=$((key_base + 6))
	local key_regs=$((key_base + 7))

	cd "$KERNEL"
	build_artifacts
	deploy_one "$VM0_PORT"
	deploy_one "$VM1_PORT"

	echo "[1/8] direct shared CXL mapping mutates checkpoint"
	run_demo "$VM0_PORT" checkpoint "$key_shared" "$len"
	run_demo "$VM1_PORT" restore-shared-write "$key_shared" "$len"
	run_demo "$VM0_PORT" restore-first "$key_shared" "$len" 0xfeedfacecafebeef

	echo "[2/8] shared CXL read + private write COW"
	run_demo "$VM0_PORT" checkpoint "$key_cow" "$len"
	run_demo "$VM1_PORT" restore-shared-cow "$key_cow" "$len"
	run_demo "$VM0_PORT" restore-first "$key_cow" "$len" 0xc001f00d00000000

	echo "[3/8] multi-VMA shared CXL read + private write COW"
	run_demo "$VM0_PORT" checkpoint-multi "$key_multi" "$len"
	run_demo "$VM1_PORT" restore-multi-shared-cow "$key_multi" "$len"
	run_demo "$VM1_PORT" restore-multi-shared-cow "$key_multi" "$len"
	run_demo "$VM1_PORT" stats "$key_multi"

	echo "[4/8] fork-style prepare/resume into a child PID"
	run_fork_demo "$VM0_PORT" prepare "$key_fork" "$len"
	run_fork_demo "$VM1_PORT" resume-child "$key_fork" "$len"
	run_fork_demo "$VM0_PORT" verify-original "$key_fork" "$len"

	echo "[5/8] restored user register/stack context in a child PID"
	run_context_demo "$VM0_PORT" prepare "$key_context"
	run_context_demo "$VM1_PORT" resume-child "$key_context"
	run_context_demo "$VM0_PORT" verify-original "$key_context"

	echo "[6/8] apply serialized mm/task state in child resume path"
	run_fork_demo "$VM0_PORT" prepare "$key_apply_mm" "$len"
	run_fork_demo "$VM1_PORT" resume-child-apply-mm "$key_apply_mm" "$len"
	run_fork_demo "$VM0_PORT" verify-original "$key_apply_mm" "$len"

	echo "[7/8] reopen path-backed fd state in child resume path"
	run_fork_demo "$VM0_PORT" prepare "$key_reopen_fds" "$len"
	run_fork_demo "$VM1_PORT" resume-child-reopen-fds "$key_reopen_fds" "$len"
	run_fork_demo "$VM0_PORT" verify-original "$key_reopen_fds" "$len"

	echo "[8/8] apply restored pt_regs to syscall return path"
	run_regs_demo "$VM0_PORT" prepare "$key_regs"
	run_regs_demo "$VM1_PORT" resume-child "$key_regs"
	run_regs_demo "$VM0_PORT" verify-original "$key_regs"

	echo "cxlfork kernel prototype tests passed"
}

main "$@"
