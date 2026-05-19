#!/usr/bin/env bash
set -euo pipefail

WS=${WS:-/home/xtl/cxlfork-ws}
KERNEL=${KERNEL:-$WS/kernel/linux-6.6.32-cxlfork}
KBUILD=${KBUILD:-$WS/kernel/build-6.6.32}
CXL_PHYS=${CXL_PHYS:-0x484000000}
CXL_SIZE=${CXL_SIZE:-0xfb000000}
VM_DIR=${VM_DIR:-/tmp/cxlfork}
VM0_PORT=${VM0_PORT:-2200}
VM1_PORT=${VM1_PORT:-2201}
KEY_BASE=${KEY_BASE:-3000}
ITERS=${ITERS:-10}
WARMUP=${WARMUP:-2}
SIZES=${SIZES:-"1048576 8388608 33554432"}
OUT=${OUT:-$WS/results/cxlfork-serverless-$(date +%Y%m%d-%H%M%S).csv}
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

extract_field() {
	local text=$1
	local name=$2

	printf '%s\n' "$text" | sed -n "s/.*${name}=\\([^ ]*\\).*/\\1/p" | tail -1
}

build_artifacts() {
	make -C "$KBUILD" M="$KERNEL/drivers/cxlfork" CONFIG_CXLFORK=m \
		KBUILD_MODPOST_WARN=1 modules >/tmp/cxlfork_bench_module.log
	make -C "$KERNEL/samples/cxlfork" KDIR="$KBUILD" clean all \
		>/tmp/cxlfork_bench_samples.log
}

deploy_one() {
	local port=$1

	vm_ssh "$port" "sudo pkill -x cxlfork_fork_demo 2>/dev/null || true; sudo pkill -x cxlfork_regs_demo 2>/dev/null || true; mkdir -p '$VM_DIR'"
	vm_scp "$port" "$KERNEL/drivers/cxlfork/cxlfork.ko" \
		"$KERNEL/samples/cxlfork/cxlfork_demo" \
		"$KERNEL/samples/cxlfork/cxlfork_fork_demo" \
		"$KERNEL/samples/cxlfork/cxlfork_regs_demo" \
		ubuntu@localhost:"$VM_DIR/"
	vm_ssh "$port" "cd '$VM_DIR' && sudo rmmod cxlfork 2>/dev/null || true; sudo insmod '$VM_DIR/cxlfork.ko' cxl_phys='$CXL_PHYS' cxl_size='$CXL_SIZE'"
}

run_fork_once() {
	local key=$1
	local bytes=$2
	local phase=$3
	local iter=$4
	local prepare_out resume_out verify_out stats_out
	local prepare_ns resume_ns invoke_ns pages regions restored_fds faults

	prepare_out=$(vm_ssh "$VM0_PORT" "cd '$VM_DIR' && sudo ./cxlfork_fork_demo prepare '$key' '$bytes'")
	resume_out=$(vm_ssh "$VM1_PORT" "cd '$VM_DIR' && sudo ./cxlfork_fork_demo resume-child-reopen-fds '$key' '$bytes'")
	verify_out=$(vm_ssh "$VM0_PORT" "cd '$VM_DIR' && sudo ./cxlfork_fork_demo verify-original '$key' '$bytes'")
	stats_out=$(vm_ssh "$VM1_PORT" "cd '$VM_DIR' && sudo ./cxlfork_demo stats '$key'" 2>/dev/null || true)

	prepare_ns=$(extract_field "$prepare_out" "prepare_ns")
	resume_ns=$(extract_field "$resume_out" "resume_ns")
	invoke_ns=$(extract_field "$resume_out" "invoke_ns")
	pages=$(extract_field "$prepare_out" "pages")
	regions=$(extract_field "$prepare_out" "regions")
	restored_fds=$(extract_field "$resume_out" "restored_fds")
	faults=$(extract_field "$stats_out" "faults")
	: "${faults:=NA}"
	: "${invoke_ns:=NA}"

	printf 'cxlfork-full,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
		"$bytes" "$phase" "$iter" "$key" "$prepare_ns" "$resume_ns" \
		"$invoke_ns" "$pages" "$regions" "$restored_fds" "$faults" >>"$OUT"
	printf '[cxlfork-full] bytes=%s phase=%s iter=%s prepare_ns=%s resume_ns=%s invoke_ns=%s pages=%s restored_fds=%s\n' \
		"$bytes" "$phase" "$iter" "$prepare_ns" "$resume_ns" "$invoke_ns" "$pages" "$restored_fds"
	: "$verify_out"
}

run_regs_once() {
	local key=$1
	local phase=$2
	local iter=$3
	local prepare_out resume_out verify_out
	local prepare_ns invoke_ns pages tls

	prepare_out=$(vm_ssh "$VM0_PORT" "cd '$VM_DIR' && sudo ./cxlfork_regs_demo prepare-tls '$key'")
	resume_out=$(vm_ssh "$VM1_PORT" "cd '$VM_DIR' && sudo ./cxlfork_regs_demo resume-child-tls '$key'")
	verify_out=$(vm_ssh "$VM0_PORT" "cd '$VM_DIR' && sudo ./cxlfork_regs_demo verify-original '$key'")

	prepare_ns=$(extract_field "$prepare_out" "prepare_ns")
	invoke_ns=$(extract_field "$resume_out" "invoke_ns")
	pages=$(extract_field "$prepare_out" "pages")
	tls=$(extract_field "$prepare_out" "tls")
	: "${invoke_ns:=NA}"
	printf 'cxlfork-regs-tls,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
		"2097152" "$phase" "$iter" "$key" "$prepare_ns" "NA" "$invoke_ns" "$pages" "1" "NA" "NA" >>"$OUT"
	printf '[cxlfork-regs-tls] phase=%s iter=%s prepare_ns=%s invoke_ns=%s pages=%s tls=%s\n' \
		"$phase" "$iter" "$prepare_ns" "$invoke_ns" "$pages" "$tls"
	: "$resume_out" "$verify_out"
}

main() {
	local key=$KEY_BASE
	local size i phase

	mkdir -p "$(dirname "$OUT")"
	cd "$KERNEL"
	echo "[1/5] building CXLfork benchmark artifacts"
	build_artifacts
	echo "[2/5] deploying to VM0/VM1"
	deploy_one "$VM0_PORT"
	deploy_one "$VM1_PORT"

	echo "benchmark,bytes,phase,iter,key,prepare_ns,resume_ns,invoke_ns,pages,regions,restored_fds,faults" >"$OUT"

	echo "[3/5] running CXLfork serverless-style full path"
	for size in $SIZES; do
		for ((i = 0; i < WARMUP; i++)); do
			run_fork_once "$key" "$size" warmup "$i"
			key=$((key + 1))
		done
		for ((i = 0; i < ITERS; i++)); do
			run_fork_once "$key" "$size" measured "$i"
			key=$((key + 1))
		done
	done

	echo "[4/5] running pt_regs+TLS resume microbenchmark"
	for ((i = 0; i < WARMUP; i++)); do
		run_regs_once "$key" warmup "$i"
		key=$((key + 1))
	done
	for ((i = 0; i < ITERS; i++)); do
		run_regs_once "$key" measured "$i"
		key=$((key + 1))
	done

	echo "[5/5] results written to $OUT"
	vm_ssh "$VM0_PORT" "mkdir -p '$VM_DIR/results'"
	vm_scp "$VM0_PORT" "$OUT" ubuntu@localhost:"$VM_DIR/results/" >/dev/null || true
}

main "$@"
