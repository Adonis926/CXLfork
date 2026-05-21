#!/usr/bin/env bash
set -euo pipefail

WS=${WS:-/home/xtl/cxlfork-ws}
FUNCTIONS_SRC=${FUNCTIONS_SRC:-$WS/mitosis-core/exp/fork-functions}
COMMON_SRC=${COMMON_SRC:-$WS/mitosis-core/exp/common}
KBUILD=${KBUILD:-$WS/kernel/build-6.6.32}
CXLFORK_KERNEL=${CXLFORK_KERNEL:-$WS/kernel/linux-6.6.32-cxlfork}
CXL_PHYS=${CXL_PHYS:-0x484000000}
CXL_SIZE=${CXL_SIZE:-0xfb000000}
LOCAL_PORT=${LOCAL_PORT:-2202}
VM0_PORT=${VM0_PORT:-2200}
VM1_PORT=${VM1_PORT:-2201}
LOCAL_DIR=${LOCAL_DIR:-/tmp/cxlfork-amplified-local}
CXLFORK_DIR=${CXLFORK_DIR:-/tmp/cxlfork-amplified-cxl}
PY_DIR=${PY_DIR:-/tmp/cxlfork-amplified-python}
ROOTFS_DIR=${ROOTFS_DIR:-/tmp/cxlfork-rootfs}
PYTHON_USER_SITE=${PYTHON_USER_SITE:-/home/ubuntu/.local/lib/python3.12/site-packages}
CONTAINER_MODE=${CONTAINER_MODE:-lean}
KEY_BASE=${KEY_BASE:-61000}
ITERS=${ITERS:-5}
WARMUP=${WARMUP:-1}
WORKLOADS=${WORKLOADS:-"json:4194304 pyaes:4194304 chameleon:8388608 compression:8388608"}
STATE_SIZES=${STATE_SIZES:-"4194304 16777216 67108864"}
MODES=${MODES:-"read dirty"}
OUT=${OUT:-$WS/results/amplified-serverless-$(date +%Y%m%d-%H%M%S).csv}
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

	printf '%s\n' "$text" | awk -v name="$name" '
		{
			for (i = 1; i <= NF; i++) {
				if (index($i, name "=") == 1) {
					sub("^[^=]*=", "", $i)
					value = $i
				}
			}
		}
		END { if (value != "") print value }
	'
}

copy_tree() {
	local port=$1

	vm_ssh "$port" "sudo rm -rf '$PY_DIR' && mkdir -p '$PY_DIR/fork-functions' '$PY_DIR/common'"
	for workload_entry in $WORKLOADS; do
		local workload=${workload_entry%%:*}
		vm_ssh "$port" "mkdir -p '$PY_DIR/fork-functions/$workload'"
		vm_scp "$port" "$FUNCTIONS_SRC/$workload/function.py" "$FUNCTIONS_SRC/$workload/function_bench.py" \
			ubuntu@localhost:"$PY_DIR/fork-functions/$workload/" >/dev/null
		if [[ -f "$FUNCTIONS_SRC/$workload/linux.json" ]]; then
			vm_scp "$port" "$FUNCTIONS_SRC/$workload/linux.json" \
				ubuntu@localhost:"$PY_DIR/fork-functions/$workload/" >/dev/null
		fi
		for input_dir in "$FUNCTIONS_SRC/$workload"/"$workload"-*; do
			if [[ -d "$input_dir" ]]; then
				vm_scp "$port" -r "$input_dir" ubuntu@localhost:"$PY_DIR/fork-functions/$workload/" >/dev/null
			fi
		done
	done
	vm_scp "$port" "$COMMON_SRC/"*.py \
		"$WS/scripts/cxlfork_python_worker.py" \
		"$WS/scripts/local_fork_python_worker.py" \
		"$WS/scripts/cxlfork_container_worker.sh" \
		"$WS/scripts/cxlfork_lean_exec" \
		ubuntu@localhost:"$PY_DIR/common/" >/dev/null
}

build_and_deploy() {
	local port

	make -C "$KBUILD" M="$CXLFORK_KERNEL/drivers/cxlfork" CONFIG_CXLFORK=m \
		KBUILD_MODPOST_WARN=1 modules >/tmp/cxlfork_amplified_module.log
	gcc -O2 -Wall -Wextra -o "$WS/scripts/cxlfork_lean_exec" \
		"$WS/scripts/cxlfork_lean_exec.c" "$WS/scripts/cxlfork_lean_container.c" \
		>/tmp/cxlfork_amplified_lean_build.log 2>&1
	for port in "$VM0_PORT" "$VM1_PORT"; do
		vm_ssh "$port" "mkdir -p '$CXLFORK_DIR'"
		vm_scp "$port" "$CXLFORK_KERNEL/drivers/cxlfork/cxlfork.ko" ubuntu@localhost:"$CXLFORK_DIR/" >/dev/null
		vm_ssh "$port" "cd '$CXLFORK_DIR' && sudo rmmod cxlfork 2>/dev/null || true; sudo insmod '$CXLFORK_DIR/cxlfork.ko' cxl_phys='$CXL_PHYS' cxl_size='$CXL_SIZE' && sudo chmod 666 /dev/cxlfork"
		copy_tree "$port"
	done
	copy_tree "$LOCAL_PORT"
}

worker_cmd() {
	local cmd=$*

	if [[ "$CONTAINER_MODE" == "lean" ]]; then
		printf "sudo env PYTHON_USER_SITE='%s' CXLFORK_CGROUP_ROOT=/sys/fs/cgroup/cxlfork-bench ./cxlfork_lean_exec rootfs-cached amplified-%s '%s' -- %s" \
			"$PYTHON_USER_SITE" "$RANDOM" "$ROOTFS_DIR" "$cmd"
	elif [[ "$CONTAINER_MODE" == "process" ]]; then
		printf "./cxlfork_container_worker.sh process -- %s" "$cmd"
	else
		printf "PYTHON_USER_SITE='%s' ./cxlfork_container_worker.sh namespace -- %s" "$PYTHON_USER_SITE" "$cmd"
	fi
}

csv_header() {
	printf 'system,benchmark,workload,state_bytes,mode,iters,warmup,key,prepare_ns,restore_ns,page_state_ns,execution_ns,total_ns,p50_ns,p90_ns,p99_ns,pages,faults,notes\n'
}

run_local() {
	local workload=$1
	local bytes=$2
	local mode=$3
	local out fork_ns touch_ns exec_ns total_ns p50 p90 p99 pages write_arg notes

	write_arg=
	notes="open-source Mitosis fork-functions handler plus read-mostly prewarmed state"
	if [[ "$mode" == "dirty" ]]; then
		write_arg=--write-pages
		notes="open-source Mitosis fork-functions handler plus dirty per-page invocation state to amplify local COW"
	fi
	out=$(vm_ssh "$LOCAL_PORT" "cd '$PY_DIR/common' && python3 ./local_fork_python_worker.py --root '$PY_DIR/fork-functions' --workload '$workload' --bytes '$bytes' --iters '$ITERS' --warmup '$WARMUP' $write_arg")
	fork_ns=$(extract_field "$out" fork_to_child_ns)
	touch_ns=$(extract_field "$out" touch_ns)
	exec_ns=$(extract_field "$out" execution_ns)
	total_ns=$(extract_field "$out" total_ns)
	p50=$(extract_field "$out" p50_total_ns)
	p90=$(extract_field "$out" p90_total_ns)
	p99=$(extract_field "$out" p99_total_ns)
	pages=$(extract_field "$out" pages)
	printf 'LocalFork,amplified-open-serverless,%s,%s,%s,%s,%s,NA,0,0,%s,%s,%s,%s,%s,%s,%s,NA,%s\n' \
		"$workload" "$bytes" "$mode" "$ITERS" "$WARMUP" "$touch_ns" "$exec_ns" "$total_ns" \
		"$p50" "$p90" "$p99" "$pages" "$notes" >>"$OUT"
	printf '[LocalFork] workload=%s state=%s mode=%s touch_ns=%s exec_ns=%s total_ns=%s\n' \
		"$workload" "$bytes" "$mode" "$touch_ns" "$exec_ns" "$total_ns"
}

run_cxlfork() {
	local workload=$1
	local bytes=$2
	local mode=$3
	local key=$4
	local prep_cmd resume_cmd prep_out resume_out
	local dirty_arg prepare_ns restore_ns fault_ns exec_ns total_ns p50 p90 p99 pages faults notes

	dirty_arg=
	notes="cross-VM CXLfork with open-source Mitosis fork-functions handler plus read-mostly state"
	if [[ "$mode" == "dirty" ]]; then
		dirty_arg=--dirty-pages
		notes="cross-VM CXLfork with open-source Mitosis fork-functions handler plus dirty per-page state"
	fi
	prep_cmd=$(worker_cmd "python3 ./cxlfork_python_worker.py prepare --root '$PY_DIR/fork-functions' --workload '$workload' --key '$key' --bytes '$bytes' --warmup '$WARMUP'")
	resume_cmd=$(worker_cmd "python3 ./cxlfork_python_worker.py resume --root '$PY_DIR/fork-functions' --workload '$workload' --key '$key' --bytes '$bytes' --iters '$ITERS' --warmup '$WARMUP' $dirty_arg")
	prep_out=$(vm_ssh "$VM0_PORT" "cd '$PY_DIR/common' && $prep_cmd")
	resume_out=$(vm_ssh "$VM1_PORT" "cd '$PY_DIR/common' && $resume_cmd")
	prepare_ns=$(extract_field "$prep_out" prepare_ns)
	restore_ns=$(extract_field "$resume_out" restore_ns)
	fault_ns=$(extract_field "$resume_out" fault_ns)
	exec_ns=$(extract_field "$resume_out" execution_ns)
	p50=$(extract_field "$resume_out" p50_ns)
	p90=$(extract_field "$resume_out" p90_ns)
	p99=$(extract_field "$resume_out" p99_ns)
	pages=$(extract_field "$resume_out" pages)
	faults=$(extract_field "$resume_out" faults)
	total_ns=$((restore_ns + fault_ns + exec_ns))
	printf 'CXLfork,amplified-open-serverless,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
		"$workload" "$bytes" "$mode" "$ITERS" "$WARMUP" "$key" "$prepare_ns" "$restore_ns" \
		"$fault_ns" "$exec_ns" "$total_ns" "$p50" "$p90" "$p99" "$pages" "$faults" "$notes" >>"$OUT"
	printf '[CXLfork] workload=%s state=%s mode=%s prepare_ns=%s restore_ns=%s state_ns=%s exec_ns=%s total_ns=%s\n' \
		"$workload" "$bytes" "$mode" "$prepare_ns" "$restore_ns" "$fault_ns" "$exec_ns" "$total_ns"
}

main() {
	local workload_entry workload base_bytes state mode key

	mkdir -p "$(dirname "$OUT")"
	csv_header >"$OUT"
	build_and_deploy
	key=$KEY_BASE
	for workload_entry in $WORKLOADS; do
		workload=${workload_entry%%:*}
		base_bytes=${workload_entry#*:}
		for state in $STATE_SIZES; do
			for mode in $MODES; do
				run_local "$workload" "$state" "$mode"
				run_cxlfork "$workload" "$state" "$mode" "$key"
				key=$((key + 1))
			done
		done
	done
	echo "results=$OUT"
}

main "$@"
