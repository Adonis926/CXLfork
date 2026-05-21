#!/usr/bin/env bash
set -euo pipefail

WS=${WS:-/home/xtl/cxlfork-ws}
FUNCTIONS_SRC=${FUNCTIONS_SRC:-$WS/mitosis-core/exp/fork-functions}
COMMON_SRC=${COMMON_SRC:-$WS/mitosis-core/exp/common}
VM0_PORT=${VM0_PORT:-2200}
PY_DIR=${PY_DIR:-/tmp/cxlfork-local-fork}
ITERS=${ITERS:-5}
WARMUP=${WARMUP:-1}
WORKLOADS=${WORKLOADS:-"json:4194304 linpack:2097152 pyaes:4194304 chameleon:8388608 compression:8388608"}
OUT=${OUT:-$WS/results/local-fork-vs-cxlfork-$(date +%Y%m%d-%H%M%S).csv}
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)

vm_ssh() {
	ssh "${SSH_OPTS[@]}" -p "$VM0_PORT" ubuntu@localhost "$@"
}

vm_scp() {
	scp -P "$VM0_PORT" "${SSH_OPTS[@]}" "$@"
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
	vm_ssh "sudo rm -rf '$PY_DIR' && mkdir -p '$PY_DIR/fork-functions' '$PY_DIR/common'"
	for workload_entry in $WORKLOADS; do
		local workload=${workload_entry%%:*}
		vm_ssh "mkdir -p '$PY_DIR/fork-functions/$workload'"
		vm_scp "$FUNCTIONS_SRC/$workload/function.py" "$FUNCTIONS_SRC/$workload/function_bench.py" \
			ubuntu@localhost:"$PY_DIR/fork-functions/$workload/" >/dev/null
		if [[ -f "$FUNCTIONS_SRC/$workload/linux.json" ]]; then
			vm_scp "$FUNCTIONS_SRC/$workload/linux.json" \
				ubuntu@localhost:"$PY_DIR/fork-functions/$workload/" >/dev/null
		fi
		for input_dir in "$FUNCTIONS_SRC/$workload"/"$workload"-*; do
			if [[ -d "$input_dir" ]]; then
				vm_scp -r "$input_dir" ubuntu@localhost:"$PY_DIR/fork-functions/$workload/" >/dev/null
			fi
		done
	done
	vm_scp "$COMMON_SRC/"*.py "$WS/scripts/local_fork_python_worker.py" \
		ubuntu@localhost:"$PY_DIR/common/" >/dev/null
}

csv_header() {
	printf 'system,benchmark,workload,bytes,iters,warmup,fork_to_child_ns,restore_ns,page_fault_or_touch_ns,execution_ns,total_ns,p50_ns,p90_ns,p99_ns,pages,notes\n'
}

run_one() {
	local workload=$1
	local bytes=$2
	local out fork_ns touch_ns exec_ns total_ns p50 p90 p99 pages

	out=$(vm_ssh "cd '$PY_DIR/common' && python3 ./local_fork_python_worker.py --root '$PY_DIR/fork-functions' --workload '$workload' --bytes '$bytes' --iters '$ITERS' --warmup '$WARMUP'")
	fork_ns=$(extract_field "$out" fork_to_child_ns)
	touch_ns=$(extract_field "$out" touch_ns)
	exec_ns=$(extract_field "$out" execution_ns)
	total_ns=$(extract_field "$out" total_ns)
	p50=$(extract_field "$out" p50_total_ns)
	p90=$(extract_field "$out" p90_total_ns)
	p99=$(extract_field "$out" p99_total_ns)
	pages=$(extract_field "$out" pages)

	printf 'LocalFork,original-python-worker,%s,%s,%s,%s,%s,NA,%s,%s,%s,%s,%s,%s,%s,%s\n' \
		"$workload" "$bytes" "$ITERS" "$WARMUP" "$fork_ns" "$touch_ns" "$exec_ns" "$total_ns" \
		"$p50" "$p90" "$p99" "$pages" "single-VM fork()+COW baseline on VM0" >>"$OUT"
	printf '[LocalFork] workload=%s fork_to_child_ns=%s touch_ns=%s execution_ns=%s total_ns=%s pages=%s\n' \
		"$workload" "$fork_ns" "$touch_ns" "$exec_ns" "$total_ns" "$pages"
}

main() {
	local entry workload bytes

	mkdir -p "$(dirname "$OUT")"
	csv_header >"$OUT"
	copy_tree
	for entry in $WORKLOADS; do
		workload=${entry%%:*}
		bytes=${entry#*:}
		run_one "$workload" "$bytes"
	done
	echo "results=$OUT"
}

main "$@"
