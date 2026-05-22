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
ITERS=${ITERS:-5}
WARMUP=${WARMUP:-1}
KEY_BASE=${KEY_BASE:-73000}
SIZES=${SIZES:-"4194304 67108864"}
MODES=${MODES:-"read write"}
DIR=${DIR:-/tmp/cxlfork-unified-touch}
OUT=${OUT:-$WS/results/unified-touch-$(date +%Y%m%d-%H%M%S).csv}
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

field() {
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

build() {
	gcc -O2 -Wall -Wextra -I"$CXLFORK_KERNEL/samples/cxlfork" \
		-o "$WS/scripts/unified_touch_bench" "$WS/scripts/unified_touch_bench.c"
	make -C "$KBUILD" M="$CXLFORK_KERNEL/drivers/cxlfork" CONFIG_CXLFORK=m \
		KBUILD_MODPOST_WARN=1 modules >/tmp/cxlfork_unified_module.log
}

deploy() {
	local port

	vm_ssh "$LOCAL_PORT" "mkdir -p '$DIR'"
	vm_scp "$LOCAL_PORT" "$WS/scripts/unified_touch_bench" ubuntu@localhost:"$DIR/" >/dev/null
	for port in "$VM0_PORT" "$VM1_PORT"; do
		vm_ssh "$port" "mkdir -p '$DIR'"
		vm_scp "$port" "$WS/scripts/unified_touch_bench" \
			"$CXLFORK_KERNEL/drivers/cxlfork/cxlfork.ko" \
			ubuntu@localhost:"$DIR/" >/dev/null
		vm_ssh "$port" "cd '$DIR' && sudo rmmod cxlfork 2>/dev/null || true; sudo insmod ./cxlfork.ko cxl_phys='$CXL_PHYS' cxl_size='$CXL_SIZE' && sudo chmod 666 /dev/cxlfork"
	done
}

csv_header() {
	printf 'system,bytes,mode,iters,warmup,key,prepare_ns,fork_to_child_ns,restore_ns,global_restore_ns,touch_ns,total_ns,full_ns,pages,faults,notes\n'
}

run_local() {
	local bytes=$1
	local mode=$2
	local out fork_ns touch_ns total_ns pages

	out=$(vm_ssh "$LOCAL_PORT" "cd '$DIR' && ./unified_touch_bench local '$bytes' '$ITERS' '$WARMUP' '$mode'")
	fork_ns=$(field "$out" fork_to_child_ns)
	touch_ns=$(field "$out" touch_ns)
	total_ns=$(field "$out" total_ns)
	pages=$(field "$out" pages)
	printf 'LocalFork,%s,%s,%s,%s,NA,0,%s,0,0,%s,%s,%s,%s,NA,same volatile per-page touch loop\n' \
		"$bytes" "$mode" "$ITERS" "$WARMUP" "$fork_ns" "$touch_ns" "$total_ns" "$total_ns" "$pages" >>"$OUT"
	printf '[LocalFork] bytes=%s mode=%s fork_ns=%s touch_ns=%s total_ns=%s\n' \
		"$bytes" "$mode" "$fork_ns" "$touch_ns" "$total_ns"
}

run_cxlfork() {
	local bytes=$1
	local mode=$2
	local key=$3
	local prep_out resume_out prepare_ns fork_ns restore_ns touch_ns total_ns full_ns pages faults
	local global_restore_ns

	prep_out=$(vm_ssh "$VM0_PORT" "cd '$DIR' && ./unified_touch_bench prepare '$key' '$bytes'")
	resume_out=$(vm_ssh "$VM1_PORT" "cd '$DIR' && ./unified_touch_bench resume '$key' '$bytes' '$ITERS' '$WARMUP' '$mode'")
	prepare_ns=$(field "$prep_out" prepare_ns)
	pages=$(field "$prep_out" pages)
	fork_ns=$(field "$resume_out" fork_to_child_ns)
	restore_ns=$(field "$resume_out" restore_ns)
	global_restore_ns=$(field "$resume_out" global_restore_ns)
	touch_ns=$(field "$resume_out" touch_ns)
	total_ns=$(field "$resume_out" total_ns)
	faults=$(field "$resume_out" faults)
	full_ns=$((prepare_ns + total_ns))
	printf 'CXLfork,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,shared restore preinstalls read-only CXL PTEs and applies global state\n' \
		"$bytes" "$mode" "$ITERS" "$WARMUP" "$key" "$prepare_ns" "$fork_ns" "$restore_ns" \
		"$global_restore_ns" "$touch_ns" "$total_ns" "$full_ns" "$pages" "$faults" >>"$OUT"
	printf '[CXLfork] bytes=%s mode=%s prepare_ns=%s restore_ns=%s global_restore_ns=%s touch_ns=%s total_ns=%s full_ns=%s faults=%s\n' \
		"$bytes" "$mode" "$prepare_ns" "$restore_ns" "$global_restore_ns" "$touch_ns" "$total_ns" "$full_ns" "$faults"
}

main() {
	local bytes mode key

	mkdir -p "$(dirname "$OUT")"
	csv_header >"$OUT"
	build
	deploy
	key=$KEY_BASE
	for bytes in $SIZES; do
		for mode in $MODES; do
			run_local "$bytes" "$mode"
			run_cxlfork "$bytes" "$mode" "$key"
			key=$((key + 1))
		done
	done
	echo "results=$OUT"
}

main "$@"
