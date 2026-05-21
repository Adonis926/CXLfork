#!/usr/bin/env bash
set -euo pipefail

WS=${WS:-/home/xtl/cxlfork-ws}
KBUILD=${KBUILD:-$WS/kernel/build-6.6.32}
CXLFORK_KERNEL=${CXLFORK_KERNEL:-$WS/kernel/linux-6.6.32-cxlfork}
MITOSIS_KERNEL=${MITOSIS_KERNEL:-$WS/kernel/linux-6.6.32}
FUNCTIONS_SRC=${FUNCTIONS_SRC:-$WS/mitosis-core/exp/fork-functions}
COMMON_SRC=${COMMON_SRC:-$WS/mitosis-core/exp/common}
CXL_PHYS=${CXL_PHYS:-0x484000000}
CXL_SIZE=${CXL_SIZE:-0xfb000000}
CLEAR_CXL_MB=${CLEAR_CXL_MB:-1152}
VM0_PORT=${VM0_PORT:-2200}
VM1_PORT=${VM1_PORT:-2201}
CXLFORK_DIR=${CXLFORK_DIR:-/tmp/cxlfork}
MITOSIS_DIR=${MITOSIS_DIR:-/tmp/mitosis-cxl}
PY_DIR=${PY_DIR:-/tmp/cxlfork-original}
KEY_BASE=${KEY_BASE:-13000}
ITERS=${ITERS:-5}
WARMUP=${WARMUP:-1}
VM=${VM:-vm0}
WORKLOADS=${WORKLOADS:-"json:4194304 linpack:2097152 pyaes:4194304 chameleon:8388608 compression:8388608"}
OUT=${OUT:-$WS/results/original-python-functions-$(date +%Y%m%d-%H%M%S).csv}
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)

vm_port() {
	if [[ "$1" == "vm1" ]]; then
		printf '%s\n' "$VM1_PORT"
	else
		printf '%s\n' "$VM0_PORT"
	fi
}

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

	vm_ssh_port "$port" "rm -rf '$PY_DIR' && mkdir -p '$PY_DIR/fork-functions' '$PY_DIR/common'"
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
	vm_scp_port "$port" "$COMMON_SRC/"*.py "$WS/scripts/original_python_runner.py" \
		ubuntu@localhost:"$PY_DIR/common/" >/dev/null
}

build_and_deploy() {
	local port

	if [[ "$CLEAR_CXL_MB" != "0" ]]; then
		dd if=/dev/zero of=/dev/shm/cxl_mem bs=1M count="$CLEAR_CXL_MB" conv=notrunc status=none
	fi

	make -C "$KBUILD" M="$CXLFORK_KERNEL/drivers/cxlfork" CONFIG_CXLFORK=m \
		KBUILD_MODPOST_WARN=1 modules >/tmp/cxlfork_original_cxlfork_module.log
	make -C "$CXLFORK_KERNEL/samples/cxlfork" KDIR="$KBUILD" clean all \
		>/tmp/cxlfork_original_cxlfork_samples.log
	make -C "$KBUILD" M="$MITOSIS_KERNEL/drivers/cxlfork" CONFIG_CXLFORK=m \
		CONFIG_CXLFORK_MITOSIS=m KBUILD_MODPOST_WARN=1 modules >/tmp/cxlfork_original_mitosis_module.log
	make -C "$MITOSIS_KERNEL/samples/cxlfork" KDIR="$KBUILD" KBUILD_MODPOST_WARN=1 \
		mitosis_cxl_forkctl mitosis_cxl_lean_bench >/tmp/cxlfork_original_mitosis_samples.log

	for port in "$VM0_PORT" "$VM1_PORT"; do
		vm_ssh_port "$port" "mkdir -p '$CXLFORK_DIR'"
		vm_scp_port "$port" "$CXLFORK_KERNEL/drivers/cxlfork/cxlfork.ko" \
			"$CXLFORK_KERNEL/samples/cxlfork/cxlfork_demo" \
			"$CXLFORK_KERNEL/samples/cxlfork/cxlfork_workload_bench" \
			ubuntu@localhost:"$CXLFORK_DIR/" >/dev/null
		vm_ssh_port "$port" "cd '$CXLFORK_DIR' && sudo rmmod cxlfork 2>/dev/null || true; sudo insmod '$CXLFORK_DIR/cxlfork.ko' cxl_phys='$CXL_PHYS' cxl_size='$CXL_SIZE'"
		copy_tree_to_vm "$port"
	done

	port=$(vm_port "$VM")
	vm_ssh_port "$port" "mkdir -p '$MITOSIS_DIR'"
	vm_scp_port "$port" "$MITOSIS_KERNEL/drivers/cxlfork/cxlfork_mitosis.ko" \
		"$MITOSIS_KERNEL/samples/cxlfork/mitosis_cxl_forkctl" \
		"$MITOSIS_KERNEL/samples/cxlfork/mitosis_cxl_lean_bench" \
		ubuntu@localhost:"$MITOSIS_DIR/" >/dev/null
	vm_ssh_port "$port" "cd '$MITOSIS_DIR' && sudo rmmod cxlfork_mitosis 2>/dev/null || true; sudo insmod '$MITOSIS_DIR/cxlfork_mitosis.ko' cxl_phys='$CXL_PHYS' cxl_size='$CXL_SIZE'"
}

csv_header() {
	printf 'design,benchmark,workload,bytes,iters,warmup,key,prepare_ns,restore_ns,page_fault_ns,execution_ns,total_ns,p50_ns,p90_ns,p99_ns,pages,faults,notes\n'
}

run_python_exec() {
	local port=$1
	local workload=$2

	vm_ssh_port "$port" "cd '$PY_DIR/common' && python3 ./original_python_runner.py --root '$PY_DIR/fork-functions' --workload '$workload' --iters '$ITERS' --warmup '$WARMUP'"
}

workload_arg_for_c() {
	case "$1" in
		json) printf 'Json\n' ;;
		pyaes) printf 'Pyaes\n' ;;
		chameleon) printf 'HTML\n' ;;
		linpack) printf 'Float\n' ;;
		*) printf 'touch\n' ;;
	esac
}

run_one() {
	local workload=$1
	local bytes=$2
	local key=$3
	local port exec_out c_prep c_resume c_stats m_prep m_split
	local exec_ns p50_ns p90_ns p99_ns
	local c_prepare c_restore c_pf c_pages c_faults c_total
	local m_prepare m_restore m_pf m_pages m_faults m_total c_workload

	port=$(vm_port "$VM")
	exec_out=$(run_python_exec "$VM1_PORT" "$workload")
	exec_ns=$(extract_field "$exec_out" avg_ns)
	p50_ns=$(extract_field "$exec_out" p50_ns)
	p90_ns=$(extract_field "$exec_out" p90_ns)
	p99_ns=$(extract_field "$exec_out" p99_ns)

	c_workload=$(workload_arg_for_c "$workload")
	c_prep=$(vm_ssh_port "$VM0_PORT" "cd '$CXLFORK_DIR' && sudo ./cxlfork_workload_bench prepare '$key' '$c_workload' '$bytes'")
	c_resume=$(vm_ssh_port "$VM1_PORT" "cd '$CXLFORK_DIR' && sudo ./cxlfork_workload_bench resume '$key' '$c_workload' '$bytes'")
	c_stats=$(vm_ssh_port "$VM1_PORT" "cd '$CXLFORK_DIR' && sudo ./cxlfork_demo stats '$key'" 2>/dev/null || true)
	c_prepare=$(extract_field "$c_prep" prepare_ns)
	c_restore=$(extract_field "$c_resume" restore_ns)
	c_pf=$(extract_field "$c_resume" workload_ns)
	c_pages=$(extract_field "$c_prep" pages)
	c_faults=$(extract_field "$c_stats" faults)
	: "${c_faults:=NA}"
	c_total=$((c_restore + c_pf + exec_ns))

	printf 'CXLfork,original-python-composed,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
		"$workload" "$bytes" "$ITERS" "$WARMUP" "$key" "$c_prepare" "$c_restore" "$c_pf" "$exec_ns" "$c_total" \
		"$p50_ns" "$p90_ns" "$p99_ns" "$c_pages" "$c_faults" \
		"original Python handler execution plus CXLfork restore/fault split" >>"$OUT"

	key=$((key + 1))
	vm_ssh_port "$port" "cd '$MITOSIS_DIR' && sudo ./mitosis_cxl_forkctl release '$key' 2>/dev/null || true" >/dev/null
	m_prep=$(vm_ssh_port "$port" "cd '$MITOSIS_DIR' && rm -f prepare-$key.log && sudo sh -c './mitosis_cxl_lean_bench prepare $key $bytes touch >prepare-$key.log 2>&1' && cat prepare-$key.log")
	m_split=$(vm_ssh_port "$port" "cd '$MITOSIS_DIR' && rm -f split-$key.log && start=\$(date +%s%N) && sudo sh -c './mitosis_cxl_forkctl resume $key --touch >split-$key.log 2>&1' && end=\$(date +%s%N) && cat split-$key.log prepare-$key.log && echo split_total_ns=\$((end - start))")
	m_prepare=$(extract_field "$m_prep" prepare_ns)
	m_restore=$(extract_field "$m_split" resume_ns)
	: "${m_restore:=0}"
	m_pages=$(extract_field "$m_prep" pages)
	m_faults=$(extract_field "$m_split" touched_pages)
	: "${m_faults:=NA}"
	local m_split_total
	m_split_total=$(extract_field "$m_split" split_total_ns)
	if [[ -z "$m_split_total" ]]; then
		echo "missing split_total_ns for Mitosis workload=$workload key=$key" >&2
		echo "$m_split" >&2
		return 1
	fi
	m_pf=$(( m_split_total - m_restore ))
	m_total=$((m_restore + m_pf + exec_ns))

	printf 'Mitosis-CXL-local,original-python-composed,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
		"$workload" "$bytes" "$ITERS" "$WARMUP" "$key" "$m_prepare" "$m_restore" "$m_pf" "$exec_ns" "$m_total" \
		"$p50_ns" "$p90_ns" "$p99_ns" "$m_pages" "$m_faults" \
		"original Python handler execution plus Mitosis-CXL restore/fault split" >>"$OUT"

	printf '[original-python] workload=%s exec_ns=%s cxlfork_total=%s mitosis_total=%s\n' \
		"$workload" "$exec_ns" "$c_total" "$m_total"
}

summarize() {
	awk -F, '
		NR > 1 && $1 == "CXLfork" { c[$3] = $12 }
		NR > 1 && $1 == "Mitosis-CXL-local" { m[$3] = $12 }
		END {
			for (w in c)
				if (m[w])
					printf "%s cxlfork_ns=%s mitosis_ns=%s speedup=%.2fx\n", w, c[w], m[w], m[w] / c[w]
		}
	' "$OUT" | sort
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
	summarize
}

main "$@"
