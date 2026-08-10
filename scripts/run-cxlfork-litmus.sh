#!/usr/bin/env bash
set -euo pipefail

WS=${WS:-/home/xtl/cxlfork/cxlfork-repro}
QEMU=${QEMU:-qemu-system-x86_64}
KERNEL=${KERNEL:-$WS/kernel/linux-6.6.32}
KBUILD=${KBUILD:-$WS/kernel/build-6.6.32}
VM0_PORT=${VM0_PORT:-2200}
VM1_PORT=${VM1_PORT:-2201}
ROUNDS=${ROUNDS:-10}
ITERATIONS=${ITERATIONS:-100000}
TIMEOUT_MS=${TIMEOUT_MS:-30000}
REMOTE_BIN=${REMOTE_BIN:-/tmp/cxlfork_litmus}
OUT=${OUT:-/tmp/cxlfork_litmus.log}
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
if [[ -n ${SSH_KEY:-} ]]; then
	SSH_OPTS+=(-o IdentitiesOnly=yes -i "$SSH_KEY")
fi

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
	local text=$1 name=$2
	awk -v name="$name" '{ for (i = 1; i <= NF; i++) if (index($i, name "=") == 1) { sub("^[^=]*=", "", $i); print $i; exit } }' <<<"$text"
}

require_field() {
	local text=$1 name=$2 expected=$3 actual
	actual=$(field "$text" "$name")
	if [[ "$actual" != "$expected" ]]; then
		echo "litmus assertion failed field=$name expected=$expected actual=${actual:-missing}" >&2
		exit 1
	fi
}

run_pair() {
	local op=$1 run_id=$2 role0_port=$3 role1_port=$4
	local p0 p1

	p0=$(mktemp)
	p1=$(mktemp)
	vm_ssh "$role1_port" "sudo '$REMOTE_BIN' run '$op' 1 '$run_id' '$ITERATIONS' '$TIMEOUT_MS'" >"$p1" 2>&1 &
	local pid1=$!
	vm_ssh "$role0_port" "sudo '$REMOTE_BIN' run '$op' 0 '$run_id' '$ITERATIONS' '$TIMEOUT_MS'" >"$p0" 2>&1 &
	local pid0=$!
	if ! wait "$pid0"; then cat "$p0" >&2; exit 1; fi
	if ! wait "$pid1"; then cat "$p1" >&2; exit 1; fi
	cat "$p0" "$p1" >>"$OUT"
	rm -f "$p0" "$p1"
}

reset_run() {
	local run_id=$1
	vm_ssh "$VM0_PORT" "sudo '$REMOTE_BIN' reset '$run_id'" >>"$OUT"
}

query_run() {
	local run_id=$1
	vm_ssh "$VM0_PORT" "sudo '$REMOTE_BIN' query '$run_id'"
}

main() {
	local binary="$KBUILD/kselftest/cxlfork/cxlfork_litmus"
	local round run_id out

	: >"$OUT"
	{
		echo "host_kernel=$(uname -r)"
		echo "host_cpu=$(LC_ALL=C lscpu | awk -F: '/Model name/ { sub(/^[[:space:]]+/, "", $2); print $2; exit }')"
		"$QEMU" --version | head -1
		vm_ssh "$VM0_PORT" "uname -a; cat /proc/cmdline"
		vm_ssh "$VM1_PORT" "uname -a; cat /proc/cmdline"
	} >>"$OUT"

	if [[ ! -x "$binary" ]]; then
		echo "missing selftest binary: $binary" >&2
		exit 1
	fi
	for port in "$VM0_PORT" "$VM1_PORT"; do
		vm_scp "$port" "$binary" ubuntu@localhost:"$REMOTE_BIN" >/dev/null
		vm_ssh "$port" "chmod 755 '$REMOTE_BIN'"
	done

	for ((round = 0; round < ROUNDS; round++)); do
		run_id=$((1000000 + round * 10 + 1))
		reset_run "$run_id"
		run_pair rmw "$run_id" "$VM0_PORT" "$VM1_PORT"
		out=$(query_run "$run_id")
		echo "$out" >>"$OUT"
		require_field "$out" counter "$((2 * ITERATIONS))"
		require_field "$out" completions 2
		require_field "$out" errors 0

		run_id=$((run_id + 1))
		reset_run "$run_id"
		run_pair message "$run_id" "$VM0_PORT" "$VM1_PORT"
		out=$(query_run "$run_id")
		echo "$out" >>"$OUT"
		require_field "$out" sequence "$ITERATIONS"
		require_field "$out" acknowledgement "$ITERATIONS"
		require_field "$out" completions 2
		require_field "$out" errors 0

		run_id=$((run_id + 1))
		reset_run "$run_id"
		run_pair pingpong "$run_id" "$VM0_PORT" "$VM1_PORT"
		out=$(query_run "$run_id")
		echo "$out" >>"$OUT"
		require_field "$out" token 0
		require_field "$out" completions 2
		require_field "$out" errors 0
		echo "round=$round verify=ok" | tee -a "$OUT"
	done
	echo "CXLFORK_LITMUS_OK rounds=$ROUNDS iterations=$ITERATIONS" | tee -a "$OUT"
}

main "$@"
