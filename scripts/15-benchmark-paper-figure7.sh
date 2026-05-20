#!/usr/bin/env bash
set -euo pipefail

WS=${WS:-/home/xtl/cxlfork-ws}
KBUILD=${KBUILD:-$WS/kernel/build-6.6.32}
CXLFORK_KERNEL=${CXLFORK_KERNEL:-$WS/kernel/linux-6.6.32-cxlfork}
MITOSIS_KERNEL=${MITOSIS_KERNEL:-$WS/kernel/linux-6.6.32}
CXL_PHYS=${CXL_PHYS:-0x484000000}
CXL_SIZE=${CXL_SIZE:-0xfb000000}
VM0_PORT=${VM0_PORT:-2200}
VM1_PORT=${VM1_PORT:-2201}
CXLFORK_DIR=${CXLFORK_DIR:-/tmp/cxlfork}
MITOSIS_DIR=${MITOSIS_DIR:-/tmp/mitosis-cxl}
KEY_BASE=${KEY_BASE:-7000}
ITERS=${ITERS:-5}
WARMUP=${WARMUP:-1}
VM=${VM:-vm0}
WORKLOADS=${WORKLOADS:-"Float:1048576 Linpack:2097152 Json:4194304 Pyaes:4194304 Chameleon:8388608 HTML:8388608 Cnn:16777216 Rnn:16777216 BFS:33554432 Bert:33554432"}
OUT=${OUT:-$WS/results/paper-figure7-$(date +%Y%m%d-%H%M%S).csv}
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

ns_now() {
	date +%s%N
}

percentile_idx() {
	local n=$1
	local pct=$2
	local idx=$((n * pct / 100))

	if ((idx >= n)); then
		idx=$((n - 1))
	fi
	printf '%s\n' "$idx"
}

summarize_samples() {
	local samples=$1
	local sorted count sum min max p50 p90 p99 avg

	sorted=$(printf '%s\n' "$samples" | awk 'NF {print $1}' | sort -n)
	count=$(printf '%s\n' "$sorted" | awk 'NF {n++} END {print n+0}')
	if ((count == 0)); then
		printf '0,NA,NA,NA,NA,NA\n'
		return
	fi
	sum=$(printf '%s\n' "$sorted" | awk '{s+=$1} END {printf "%.0f", s}')
	min=$(printf '%s\n' "$sorted" | head -1)
	max=$(printf '%s\n' "$sorted" | tail -1)
	p50=$(printf '%s\n' "$sorted" | awk -v idx="$(percentile_idx "$count" 50)" 'NR==idx+1 {print; exit}')
	p90=$(printf '%s\n' "$sorted" | awk -v idx="$(percentile_idx "$count" 90)" 'NR==idx+1 {print; exit}')
	p99=$(printf '%s\n' "$sorted" | awk -v idx="$(percentile_idx "$count" 99)" 'NR==idx+1 {print; exit}')
	avg=$((sum / count))
	printf '%s,%s,%s,%s,%s,%s\n' "$count" "$avg" "$p50" "$p90" "$p99" "$max"
}

csv_header() {
	printf 'design,benchmark,workload,bytes,phase,iters,warmup,key,prepare_ns,restore_ns,page_fault_ns,execution_ns,total_ns,p50_ns,p90_ns,p99_ns,pages,faults,local_memory_est_bytes,notes\n'
}

append_row() {
	printf '%s\n' "$*" >>"$OUT"
}

build_cxlfork() {
	make -C "$KBUILD" M="$CXLFORK_KERNEL/drivers/cxlfork" CONFIG_CXLFORK=m \
		KBUILD_MODPOST_WARN=1 modules >/tmp/cxlfork_paper_cxlfork_module.log
	make -C "$CXLFORK_KERNEL/samples/cxlfork" KDIR="$KBUILD" clean all \
		>/tmp/cxlfork_paper_cxlfork_samples.log
}

deploy_cxlfork() {
	local port

	for port in "$VM0_PORT" "$VM1_PORT"; do
		vm_ssh_port "$port" "sudo pkill -x cxlfork_fork_demo 2>/dev/null || true; mkdir -p '$CXLFORK_DIR'"
		vm_scp_port "$port" \
			"$CXLFORK_KERNEL/drivers/cxlfork/cxlfork.ko" \
			"$CXLFORK_KERNEL/samples/cxlfork/cxlfork_demo" \
			"$CXLFORK_KERNEL/samples/cxlfork/cxlfork_fork_demo" \
			ubuntu@localhost:"$CXLFORK_DIR/" >/dev/null
		vm_ssh_port "$port" "cd '$CXLFORK_DIR' && sudo rmmod cxlfork 2>/dev/null || true; sudo insmod '$CXLFORK_DIR/cxlfork.ko' cxl_phys='$CXL_PHYS' cxl_size='$CXL_SIZE'"
	done
}

build_mitosis() {
	make -C "$KBUILD" M="$MITOSIS_KERNEL/drivers/cxlfork" CONFIG_CXLFORK=m \
		CONFIG_CXLFORK_MITOSIS=m KBUILD_MODPOST_WARN=1 modules >/tmp/cxlfork_paper_mitosis_module.log
	make -C "$MITOSIS_KERNEL/samples/cxlfork" KDIR="$KBUILD" KBUILD_MODPOST_WARN=1 \
		mitosis_cxl_forkctl mitosis_cxl_lean_bench >/tmp/cxlfork_paper_mitosis_samples.log
}

deploy_mitosis_local() {
	local port

	port=$(vm_port "$VM")
	vm_ssh_port "$port" "sudo pkill -x mitosis_cxl_lean_bench 2>/dev/null || true; mkdir -p '$MITOSIS_DIR'"
	vm_scp_port "$port" \
		"$MITOSIS_KERNEL/drivers/cxlfork/cxlfork_mitosis.ko" \
		"$MITOSIS_KERNEL/samples/cxlfork/mitosis_cxl_forkctl" \
		"$MITOSIS_KERNEL/samples/cxlfork/mitosis_cxl_lean_bench" \
		ubuntu@localhost:"$MITOSIS_DIR/" >/dev/null
	vm_ssh_port "$port" "cd '$MITOSIS_DIR' && sudo rmmod cxlfork_mitosis 2>/dev/null || true; sudo insmod '$MITOSIS_DIR/cxlfork_mitosis.ko' cxl_phys='$CXL_PHYS' cxl_size='$CXL_SIZE'"
}

run_cxlfork_workload() {
	local workload=$1
	local bytes=$2
	local key=$3
	local i phase prepare_out resume_out stats_out
	local prepare_ns restore_ns total_ns pages faults local_est

	for phase in warmup measured; do
		local count=$WARMUP
		if [[ "$phase" == "measured" ]]; then
			count=$ITERS
		fi
		for ((i = 0; i < count; i++)); do
			prepare_out=$(vm_ssh_port "$VM0_PORT" "cd '$CXLFORK_DIR' && sudo ./cxlfork_fork_demo prepare '$key' '$bytes'")
			resume_out=$(vm_ssh_port "$VM1_PORT" "cd '$CXLFORK_DIR' && sudo ./cxlfork_fork_demo resume-child-reopen-fds '$key' '$bytes'")
			vm_ssh_port "$VM0_PORT" "cd '$CXLFORK_DIR' && sudo ./cxlfork_fork_demo verify-original '$key' '$bytes'" >/dev/null
			stats_out=$(vm_ssh_port "$VM1_PORT" "cd '$CXLFORK_DIR' && sudo ./cxlfork_demo stats '$key'" 2>/dev/null || true)
			prepare_ns=$(extract_field "$prepare_out" prepare_ns)
			restore_ns=$(extract_field "$resume_out" resume_ns)
			total_ns=$(extract_field "$resume_out" invoke_ns)
			pages=$(extract_field "$prepare_out" pages)
			faults=$(extract_field "$stats_out" faults)
			: "${faults:=NA}"
			local_est=4096
			append_row "CXLfork,figure7-synthetic,$workload,$bytes,$phase,1,0,$key,$prepare_ns,$restore_ns,$((total_ns - restore_ns)),0,$total_ns,$total_ns,$total_ns,$total_ns,$pages,$faults,$local_est,restore+faults measured; execution payload is page-touch proxy"
			printf '[CXLfork] workload=%s phase=%s iter=%s prepare_ns=%s restore_ns=%s total_ns=%s faults=%s\n' \
				"$workload" "$phase" "$i" "$prepare_ns" "$restore_ns" "$total_ns" "$faults"
			key=$((key + 1))
		done
	done
}

run_mitosis_workload() {
	local workload=$1
	local bytes=$2
	local key=$3
	local port prepare_out invoke_out pool_out split_out
	local prepare_ns os_prepare_ns pages total_ns p50_ns p90_ns p99_ns restore_ns
	local split_begin split_end split_total split_fault_ns touched local_est

	port=$(vm_port "$VM")
	vm_ssh_port "$port" "cd '$MITOSIS_DIR' && sudo ./mitosis_cxl_forkctl release '$key' 2>/dev/null || true" >/dev/null
	prepare_out=$(vm_ssh_port "$port" "cd '$MITOSIS_DIR' && rm -f prepare-$key.log && sudo sh -c './mitosis_cxl_lean_bench prepare $key $bytes >prepare-$key.log 2>&1' && cat prepare-$key.log")
	invoke_out=$(vm_ssh_port "$port" "cd '$MITOSIS_DIR' && rm -f invoke-$key.log && sudo sh -c './mitosis_cxl_lean_bench invoke $key $ITERS $WARMUP $bytes >invoke-$key.log 2>&1' && cat invoke-$key.log")
	pool_out=$(vm_ssh_port "$port" "cd '$MITOSIS_DIR' && rm -f pool-$key.log && sudo sh -c './mitosis_cxl_lean_bench pool $key $ITERS $WARMUP $bytes >pool-$key.log 2>&1' && cat pool-$key.log")
	split_out=$(vm_ssh_port "$port" "cd '$MITOSIS_DIR' && rm -f split-$key.log && start=\$(date +%s%N) && sudo sh -c './mitosis_cxl_forkctl resume $key --touch >split-$key.log 2>&1' && end=\$(date +%s%N) && cat split-$key.log && echo split_total_ns=\$((end - start))")

	prepare_ns=$(extract_field "$prepare_out" prepare_ns)
	os_prepare_ns=$(extract_field "$prepare_out" os_prepare_ns)
	pages=$(extract_field "$prepare_out" pages)
	total_ns=$(extract_field "$invoke_out" avg_ns)
	p50_ns=$(extract_field "$invoke_out" p50_ns)
	p90_ns=$(extract_field "$invoke_out" p90_ns)
	p99_ns=$(extract_field "$invoke_out" p99_ns)
	restore_ns=$(extract_field "$split_out" resume_ns)
	touched=$(extract_field "$split_out" touched_pages)
	split_total=$(extract_field "$split_out" split_total_ns)
	split_fault_ns=$((split_total - restore_ns))
	local_est=$((touched * 4096))

	append_row "Mitosis-CXL-local,figure7-synthetic,$workload,$bytes,measured,$ITERS,$WARMUP,$key,$prepare_ns,$restore_ns,$split_fault_ns,NA,$total_ns,$p50_ns,$p90_ns,$p99_ns,$pages,$touched,$local_est,lean invoke total; split uses forkctl resume --touch same-node"
	printf '[Mitosis-CXL-local] workload=%s prepare_ns=%s restore_ns=%s split_fault_ns=%s total_avg_ns=%s pages=%s\n' \
		"$workload" "$prepare_ns" "$restore_ns" "$split_fault_ns" "$total_ns" "$pages"

	total_ns=$(extract_field "$pool_out" avg_ns)
	p50_ns=$(extract_field "$pool_out" p50_ns)
	p90_ns=$(extract_field "$pool_out" p90_ns)
	p99_ns=$(extract_field "$pool_out" p99_ns)
	append_row "Mitosis-CXL-local-pool,figure7-synthetic,$workload,$bytes,measured,$ITERS,$WARMUP,$key,$prepare_ns,$restore_ns,$split_fault_ns,NA,$total_ns,$p50_ns,$p90_ns,$p99_ns,$pages,$touched,$local_est,precreated skeleton pool; split uses forkctl resume --touch same-node"
}

summarize_csv() {
	awk -F, '
		NR == 1 { next }
		$5 == "measured" && $13 != "NA" {
			k = $1 "/" $3 "/" $4
			n[k]++
			total[k] += $13
			restore[k] += ($10 == "NA" ? 0 : $10)
			fault[k] += ($11 == "NA" ? 0 : $11)
			pages[k] = $17
			faults[k] = $18
		}
		END {
			for (k in n)
				printf "%s n=%d avg_total_ns=%.0f avg_restore_ns=%.0f avg_page_fault_ns=%.0f pages=%s faults=%s\n",
					k, n[k], total[k] / n[k], restore[k] / n[k], fault[k] / n[k], pages[k], faults[k]
		}
	' "$OUT" | sort
}

main() {
	local key=$KEY_BASE
	local entry workload bytes

	mkdir -p "$(dirname "$OUT")"
	csv_header >"$OUT"

	echo "[1/5] build CXLfork and Mitosis-CXL benchmark artifacts"
	build_cxlfork
	build_mitosis

	echo "[2/5] deploy CXLfork to VM0/VM1"
	deploy_cxlfork

	echo "[3/5] deploy Mitosis-CXL local baseline to ${VM}"
	deploy_mitosis_local

	echo "[4/5] run paper-shaped synthetic workloads"
	for entry in $WORKLOADS; do
		workload=${entry%%:*}
		bytes=${entry#*:}
		run_cxlfork_workload "$workload" "$bytes" "$key"
		key=$((key + WARMUP + ITERS + 1))
		run_mitosis_workload "$workload" "$bytes" "$key"
		key=$((key + 1))
	done

	echo "[5/5] results written to $OUT"
	summarize_csv
}

main "$@"
