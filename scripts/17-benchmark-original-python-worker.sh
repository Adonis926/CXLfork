#!/usr/bin/env bash
set -euo pipefail

WS=${WS:-/home/xtl/cxlfork-ws}
KBUILD=${KBUILD:-$WS/kernel/build-6.6.32}
CXLFORK_KERNEL=${CXLFORK_KERNEL:-$WS/kernel/linux-6.6.32-cxlfork}
FUNCTIONS_SRC=${FUNCTIONS_SRC:-$WS/mitosis-core/exp/fork-functions}
COMMON_SRC=${COMMON_SRC:-$WS/mitosis-core/exp/common}
CXL_PHYS=${CXL_PHYS:-0x484000000}
CXL_SIZE=${CXL_SIZE:-0xfb000000}
CLEAR_CXL_MB=${CLEAR_CXL_MB:-1152}
VM0_PORT=${VM0_PORT:-2200}
VM1_PORT=${VM1_PORT:-2201}
CXLFORK_DIR=${CXLFORK_DIR:-/tmp/cxlfork}
PY_DIR=${PY_DIR:-/tmp/cxlfork-original-worker}
KEY_BASE=${KEY_BASE:-30000}
ITERS=${ITERS:-5}
WARMUP=${WARMUP:-1}
WORKLOADS=${WORKLOADS:-"json:4194304 linpack:2097152 pyaes:4194304 chameleon:8388608 compression:8388608"}
OUT=${OUT:-$WS/results/original-python-worker-$(date +%Y%m%d-%H%M%S).csv}
CONTAINER_MODE=${CONTAINER_MODE:-process}
PYTHON_USER_SITE=${PYTHON_USER_SITE:-/home/ubuntu/.local/lib/python3.12/site-packages}
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)

vm_ssh_port() {
	local port=$1
	shift
	ssh "${SSH_OPTS[@]}" -p "$port" ubuntu@localhost "$@"
}

vm_scp_port() {
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

copy_tree_to_vm() {
	local port=$1

	vm_ssh_port "$port" "sudo rm -rf '$PY_DIR' && mkdir -p '$PY_DIR/fork-functions' '$PY_DIR/common'"
	for workload_entry in $WORKLOADS; do
		local workload=${workload_entry%%:*}
		vm_ssh_port "$port" "mkdir -p '$PY_DIR/fork-functions/$workload'"
		vm_scp_port "$port" "$FUNCTIONS_SRC/$workload/function.py" "$FUNCTIONS_SRC/$workload/function_bench.py" \
			ubuntu@localhost:"$PY_DIR/fork-functions/$workload/" >/dev/null
		if [[ -f "$FUNCTIONS_SRC/$workload/linux.json" ]]; then
			vm_scp_port "$port" "$FUNCTIONS_SRC/$workload/linux.json" \
				ubuntu@localhost:"$PY_DIR/fork-functions/$workload/" >/dev/null
		fi
		for input_dir in "$FUNCTIONS_SRC/$workload"/"$workload"-*; do
			if [[ -d "$input_dir" ]]; then
				vm_scp_port "$port" -r "$input_dir" \
					ubuntu@localhost:"$PY_DIR/fork-functions/$workload/" >/dev/null
			fi
		done
	done
	vm_scp_port "$port" "$COMMON_SRC/"*.py "$WS/scripts/cxlfork_python_worker.py" "$WS/scripts/cxlfork_container_worker.sh" \
		ubuntu@localhost:"$PY_DIR/common/" >/dev/null
}

build_and_deploy() {
	local port

	if [[ "$CLEAR_CXL_MB" != "0" ]]; then
		dd if=/dev/zero of=/dev/shm/cxl_mem bs=1M count="$CLEAR_CXL_MB" conv=notrunc status=none
	fi

	make -C "$KBUILD" M="$CXLFORK_KERNEL/drivers/cxlfork" CONFIG_CXLFORK=m \
		KBUILD_MODPOST_WARN=1 modules >/tmp/cxlfork_original_worker_module.log

	for port in "$VM0_PORT" "$VM1_PORT"; do
		vm_ssh_port "$port" "mkdir -p '$CXLFORK_DIR'"
		vm_scp_port "$port" "$CXLFORK_KERNEL/drivers/cxlfork/cxlfork.ko" \
			ubuntu@localhost:"$CXLFORK_DIR/" >/dev/null
		vm_ssh_port "$port" "cd '$CXLFORK_DIR' && sudo rmmod cxlfork 2>/dev/null || true; sudo insmod '$CXLFORK_DIR/cxlfork.ko' cxl_phys='$CXL_PHYS' cxl_size='$CXL_SIZE' && sudo chmod 666 /dev/cxlfork"
		copy_tree_to_vm "$port"
	done
}

csv_header() {
	printf 'design,benchmark,workload,bytes,iters,warmup,key,prepare_ns,restore_ns,page_fault_ns,execution_ns,total_ns,p50_ns,p90_ns,p99_ns,pages,faults,notes\n'
}

worker_cmd() {
	local mode=$1
	shift
	local cmd=$*

	if [[ "$mode" == "namespace" ]]; then
		printf "PYTHON_USER_SITE='%s' ./cxlfork_container_worker.sh namespace -- %s" \
			"$PYTHON_USER_SITE" "$cmd"
	elif [[ "$mode" == "cgroup" ]]; then
		printf "./cxlfork_container_worker.sh cgroup -- %s" "$cmd"
	elif [[ "$mode" == "rootfs" ]]; then
		printf "PYTHON_USER_SITE='%s' ./cxlfork_container_worker.sh rootfs -- %s" \
			"$PYTHON_USER_SITE" "$cmd"
	else
		printf "./cxlfork_container_worker.sh process -- %s" "$cmd"
	fi
}

benchmark_name() {
	if [[ "$CONTAINER_MODE" == "namespace" ]]; then
		printf 'original-python-worker-namespace'
	elif [[ "$CONTAINER_MODE" == "cgroup" ]]; then
		printf 'original-python-worker-cgroup'
	elif [[ "$CONTAINER_MODE" == "rootfs" ]]; then
		printf 'original-python-worker-rootfs'
	else
		printf 'original-python-worker'
	fi
}

benchmark_note() {
	if [[ "$CONTAINER_MODE" == "namespace" ]]; then
		printf 'original Python worker runs in fresh pid/mount/uts/ipc namespaces and invokes CXLfork prepare/resume'
	elif [[ "$CONTAINER_MODE" == "cgroup" ]]; then
		printf 'original Python worker runs in a cgroup v2 leaf and invokes CXLfork prepare/resume'
	elif [[ "$CONTAINER_MODE" == "rootfs" ]]; then
		printf 'original Python worker runs in fresh namespaces with chroot/bind rootfs and cgroup v2 leaf'
	else
		printf 'original Python worker invokes CXLfork prepare/resume; fixed working-set pages are restored over shared CXL'
	fi
}

run_one() {
	local workload=$1
	local bytes=$2
	local key=$3
	local prep_out resume_out
	local prep_cmd resume_cmd
	local prepare_ns restore_ns fault_ns exec_ns total_ns p50_ns p90_ns p99_ns pages faults

	prep_cmd=$(worker_cmd "$CONTAINER_MODE" "python3 ./cxlfork_python_worker.py prepare --root '$PY_DIR/fork-functions' --workload '$workload' --key '$key' --bytes '$bytes' --warmup '$WARMUP'")
	resume_cmd=$(worker_cmd "$CONTAINER_MODE" "python3 ./cxlfork_python_worker.py resume --root '$PY_DIR/fork-functions' --workload '$workload' --key '$key' --bytes '$bytes' --iters '$ITERS' --warmup '$WARMUP'")
	prep_out=$(vm_ssh_port "$VM0_PORT" "cd '$PY_DIR/common' && $prep_cmd")
	resume_out=$(vm_ssh_port "$VM1_PORT" "cd '$PY_DIR/common' && $resume_cmd")

	prepare_ns=$(extract_field "$prep_out" prepare_ns)
	restore_ns=$(extract_field "$resume_out" restore_ns)
	fault_ns=$(extract_field "$resume_out" fault_ns)
	exec_ns=$(extract_field "$resume_out" execution_ns)
	p50_ns=$(extract_field "$resume_out" p50_ns)
	p90_ns=$(extract_field "$resume_out" p90_ns)
	p99_ns=$(extract_field "$resume_out" p99_ns)
	pages=$(extract_field "$resume_out" pages)
	faults=$(extract_field "$resume_out" faults)
	total_ns=$((restore_ns + fault_ns + exec_ns))

	printf 'CXLfork,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
		"$(benchmark_name)" \
		"$workload" "$bytes" "$ITERS" "$WARMUP" "$key" "$prepare_ns" "$restore_ns" "$fault_ns" "$exec_ns" \
		"$total_ns" "$p50_ns" "$p90_ns" "$p99_ns" "$pages" "$faults" \
		"$(benchmark_note)" >>"$OUT"

	printf '[%s] workload=%s prepare_ns=%s restore_ns=%s fault_ns=%s execution_ns=%s total_ns=%s\n' \
		"$(benchmark_name)" "$workload" "$prepare_ns" "$restore_ns" "$fault_ns" "$exec_ns" "$total_ns"
}

main() {
	local key=$KEY_BASE
	local entry workload bytes

	mkdir -p "$(dirname "$OUT")"
	csv_header >"$OUT"
	build_and_deploy
	for entry in $WORKLOADS; do
		workload=${entry%%:*}
		bytes=${entry#*:}
		run_one "$workload" "$bytes" "$key"
		key=$((key + 10))
	done
	echo "results=$OUT"
}

main "$@"
