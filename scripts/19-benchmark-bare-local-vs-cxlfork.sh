#!/usr/bin/env bash
set -euo pipefail

WS=${WS:-/home/xtl/cxlfork-ws}
KBUILD=${KBUILD:-$WS/kernel/build-6.6.32}
CXLFORK_KERNEL=${CXLFORK_KERNEL:-$WS/kernel/linux-6.6.32-cxlfork}
CXL_PHYS=${CXL_PHYS:-0x484000000}
CXL_SIZE=${CXL_SIZE:-0xfb000000}
LOCAL_PORT=${LOCAL_PORT:-2202}
VM0_PORT=${VM0_PORT:-2200}
VM1_PORT=${VM1_PORT:-2201}
LOCAL_DIR=${LOCAL_DIR:-/tmp/cxlfork-bare-local}
CXLFORK_DIR=${CXLFORK_DIR:-/tmp/cxlfork}
ITERS=${ITERS:-20}
WARMUP=${WARMUP:-5}
KEY_BASE=${KEY_BASE:-52000}
WORKLOADS=${WORKLOADS:-"none:0 touch:1048576 touch:4194304 Json:4194304 Pyaes:4194304 HTML:8388608"}
OUT=${OUT:-$WS/results/bare-local-vs-cxlfork-$(date +%Y%m%d-%H%M%S).csv}
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

csv_header() {
	printf 'system,kernel,workload,bytes,iters,warmup,key,mode,prepare_ns,restore_ns,page_fault_ns,fork_to_child_ns,touch_ns,workload_ns,total_ns,p50_ns,p90_ns,p99_ns,pages,faults,notes\n'
}

build_local() {
	gcc -O2 -Wall -Wextra -o "$WS/scripts/local_fork_bare_bench" \
		"$WS/scripts/local_fork_bare_bench.c"
}

build_cxlfork() {
	make -C "$KBUILD" M="$CXLFORK_KERNEL/drivers/cxlfork" CONFIG_CXLFORK=m \
		KBUILD_MODPOST_WARN=1 modules >/tmp/cxlfork_bare_module.log
	make -C "$CXLFORK_KERNEL/samples/cxlfork" KDIR="$KBUILD" cxlfork_workload_bench cxlfork_demo \
		>/tmp/cxlfork_bare_samples.log
}

deploy_local() {
	vm_ssh "$LOCAL_PORT" "mkdir -p '$LOCAL_DIR'"
	vm_scp "$LOCAL_PORT" "$WS/scripts/local_fork_bare_bench" ubuntu@localhost:"$LOCAL_DIR/" >/dev/null
}

deploy_cxlfork() {
	local port

	for port in "$VM0_PORT" "$VM1_PORT"; do
		vm_ssh "$port" "mkdir -p '$CXLFORK_DIR'"
		vm_scp "$port" "$CXLFORK_KERNEL/drivers/cxlfork/cxlfork.ko" \
			"$CXLFORK_KERNEL/samples/cxlfork/cxlfork_demo" \
			"$CXLFORK_KERNEL/samples/cxlfork/cxlfork_workload_bench" \
			ubuntu@localhost:"$CXLFORK_DIR/" >/dev/null
		vm_ssh "$port" "cd '$CXLFORK_DIR' && sudo rmmod cxlfork 2>/dev/null || true; sudo insmod '$CXLFORK_DIR/cxlfork.ko' cxl_phys='$CXL_PHYS' cxl_size='$CXL_SIZE' && sudo chmod 666 /dev/cxlfork"
	done
}

kernel_name() {
	vm_ssh "$1" "uname -r"
}

run_local_one() {
	local workload=$1
	local bytes=$2
	local kernel=$3
	local out mode fork_ns touch_ns workload_ns total_ns p50 p90 p99 pages

	for mode in none read write; do
		if [[ "$workload" != "none" && "$mode" == "none" ]]; then
			continue
		fi
		if [[ "$workload" == "none" && "$mode" != "none" ]]; then
			continue
		fi
		out=$(vm_ssh "$LOCAL_PORT" "cd '$LOCAL_DIR' && ./local_fork_bare_bench '$workload' '$bytes' '$ITERS' '$WARMUP' '$mode'")
		fork_ns=$(extract_field "$out" fork_to_child_ns)
		touch_ns=$(extract_field "$out" touch_ns)
		workload_ns=$(extract_field "$out" workload_ns)
		total_ns=$(extract_field "$out" total_ns)
		p50=$(extract_field "$out" p50_total_ns)
		p90=$(extract_field "$out" p90_total_ns)
		p99=$(extract_field "$out" p99_total_ns)
		pages=$(extract_field "$out" pages)
		printf 'LocalFork,%s,%s,%s,%s,%s,NA,%s,0,0,0,%s,%s,%s,%s,%s,%s,%s,%s,NA,bare C fork()+waitpid() baseline\n' \
			"$kernel" "$workload" "$bytes" "$ITERS" "$WARMUP" "$mode" \
			"$fork_ns" "$touch_ns" "$workload_ns" "$total_ns" "$p50" "$p90" "$p99" "$pages" >>"$OUT"
		printf '[LocalFork] workload=%s bytes=%s mode=%s total_ns=%s fork_to_child_ns=%s touch_ns=%s workload_ns=%s\n' \
			"$workload" "$bytes" "$mode" "$total_ns" "$fork_ns" "$touch_ns" "$workload_ns"
	done
}

run_cxlfork_one() {
	local workload=$1
	local bytes=$2
	local kernel=$3
	local key=$4
	local i current_key phase count tmp
	local prepare_out resume_out stats_out prepare_ns restore_ns total_ns workload_ns fault_ns pages faults

	if [[ "$workload" == "none" ]]; then
		return
	fi
	tmp=$(mktemp)
	for phase in warmup measured; do
		count=$WARMUP
		if [[ "$phase" == "measured" ]]; then
			count=$ITERS
		fi
		for ((i = 0; i < count; i++)); do
			if [[ "$phase" == "measured" ]]; then
				current_key=$((key + WARMUP + i))
			else
				current_key=$((key + i))
			fi
			prepare_out=$(vm_ssh "$VM0_PORT" "cd '$CXLFORK_DIR' && ./cxlfork_workload_bench prepare '$current_key' '$workload' '$bytes'")
			resume_out=$(vm_ssh "$VM1_PORT" "cd '$CXLFORK_DIR' && ./cxlfork_workload_bench resume '$current_key' '$workload' '$bytes'")
			stats_out=$(vm_ssh "$VM1_PORT" "cd '$CXLFORK_DIR' && ./cxlfork_demo stats '$current_key'" 2>/dev/null || true)
			prepare_ns=$(extract_field "$prepare_out" prepare_ns)
			restore_ns=$(extract_field "$resume_out" restore_ns)
			total_ns=$(extract_field "$resume_out" total_ns)
			workload_ns=$(extract_field "$resume_out" workload_ns)
			pages=$(extract_field "$prepare_out" pages)
			faults=$(extract_field "$stats_out" faults)
			: "${faults:=0}"
			fault_ns=$((total_ns - restore_ns - workload_ns))
			if [[ "$phase" == "measured" ]]; then
				printf '%s,%s,%s,%s,%s,%s,%s\n' \
					"$prepare_ns" "$restore_ns" "$fault_ns" "$workload_ns" "$total_ns" "$pages" "$faults" >>"$tmp"
			fi
			printf '[CXLfork] workload=%s bytes=%s phase=%s iter=%s key=%s prepare_ns=%s restore_ns=%s fault_ns=%s workload_ns=%s total_ns=%s faults=%s\n' \
				"$workload" "$bytes" "$phase" "$i" "$current_key" "$prepare_ns" "$restore_ns" "$fault_ns" "$workload_ns" "$total_ns" "$faults"
		done
	done
	awk -F, -v kernel="$kernel" -v workload="$workload" -v bytes="$bytes" -v iters="$ITERS" -v warmup="$WARMUP" -v key="$key" '
		{ n++; prep += $1; restore += $2; fault += $3; work += $4; total += $5; pages = $6; faults = $7; totals[n] = $5 }
		END {
			for (i = 1; i <= n; i++) {
				for (j = i + 1; j <= n; j++) {
					if (totals[i] > totals[j]) {
						t = totals[i]; totals[i] = totals[j]; totals[j] = t
					}
				}
			}
			p50 = totals[int(n * 50 / 100) + 1]
			p90 = totals[int(n * 90 / 100) + 1]
			p99 = totals[int(n * 99 / 100) + 1]
			if (int(n * 50 / 100) + 1 > n) p50 = totals[n]
			if (int(n * 90 / 100) + 1 > n) p90 = totals[n]
			if (int(n * 99 / 100) + 1 > n) p99 = totals[n]
			printf "CXLfork,%s,%s,%s,%s,%s,%s,remote-cxl,%.0f,%.0f,%.0f,NA,NA,%.0f,%.0f,%.0f,%.0f,%.0f,%s,%s,cross-VM prepare on VM0 and resume on VM1\n",
				kernel, workload, bytes, iters, warmup, key, prep / n, restore / n, fault / n, work / n, total / n, p50, p90, p99, pages, faults
		}
	' "$tmp" >>"$OUT"
	rm -f "$tmp"
}

main() {
	local local_kernel cxlfork_kernel entry workload bytes key

	mkdir -p "$(dirname "$OUT")"
	csv_header >"$OUT"
	build_local
	build_cxlfork
	deploy_local
	deploy_cxlfork
	local_kernel=$(kernel_name "$LOCAL_PORT")
	cxlfork_kernel=$(kernel_name "$VM1_PORT")
	key=$KEY_BASE
	for entry in $WORKLOADS; do
		workload=${entry%%:*}
		bytes=${entry#*:}
		run_local_one "$workload" "$bytes" "$local_kernel"
		run_cxlfork_one "$workload" "$bytes" "$cxlfork_kernel" "$key"
		key=$((key + WARMUP + ITERS + 10))
	done
	echo "results=$OUT"
}

main "$@"
