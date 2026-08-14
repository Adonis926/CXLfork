#!/usr/bin/env bash
set -euo pipefail

# One authoritative runner for the restricted CXLfork spawn experiment.
# It reuses start-cxlfork-vms.sh / stop-cxlfork-vms.sh and does not manage any
# QEMU process that is not recorded by those scripts.

WS=${WS:-/home/xtl/cxlfork/cxlfork-repro}
KERNEL_TREE=${KERNEL_TREE:-$WS/kernel/linux-6.6.32}
BUILD_DIR=${BUILD_DIR:-$WS/kernel/build-6.6.32-spawn}
KERNEL_IMAGE=${KERNEL_IMAGE:-$BUILD_DIR/arch/x86/boot/bzImage}
RESULT_ROOT=${RESULT_ROOT:-$WS/results/cxlfork-spawn}
VM0_PORT=${VM0_PORT:-2200}
VM1_PORT=${VM1_PORT:-2201}
GUEST_PASSWORD=${GUEST_PASSWORD:-123}
BENCH_PORT=${BENCH_PORT:-7100}
CXL_FILE=${CXL_FILE:-/dev/shm/cxlfork_spawn_mem}
HYDRA_SHM_FILE=${HYDRA_SHM_FILE:-/dev/shm/cxlfork_spawn_aux}
PILOT_LANES=${PILOT_LANES:-"1 4 16"}
PILOT_PASSES=${PILOT_PASSES:-3}
PILOT_WARMUP=${PILOT_WARMUP:-2}
PILOT_SECONDS=${PILOT_SECONDS:-5}
CHURN_REQUESTS=${CHURN_REQUESTS:-10000}
RUN_ID=${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-91-file-sim}
RESULT_DIR=${2:-$RESULT_ROOT/$RUN_ID}

BENCH=$KERNEL_TREE/tools/testing/selftests/cxlfork/cxlfork_spawn_bench
SELFTEST=$KERNEL_TREE/tools/testing/selftests/cxlfork/cxlfork_test
SSH_OPTIONS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
	-o LogLevel=ERROR -o ConnectTimeout=3)
slot_ready=0
server_running=0
vms_started=0
KEY=0
GENERATION=0
STATE_CHECKSUM=0

log()
{
	printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" |
		tee -a "$RESULT_DIR/controller.log"
}

guest()
{
	local port=$1
	shift
	sshpass -p "$GUEST_PASSWORD" ssh -p "$port" "${SSH_OPTIONS[@]}" \
		ubuntu@127.0.0.1 "$@"
}

guest_root()
{
	local port=$1
	local command=$2
	local quoted

	printf -v quoted '%q' "$command"
	guest "$port" "printf '%s\\n' '$GUEST_PASSWORD' | sudo -S -p '' bash -lc $quoted"
}

copy_to_guest()
{
	local port=$1 source=$2 destination=$3
	sshpass -p "$GUEST_PASSWORD" scp -P "$port" "${SSH_OPTIONS[@]}" \
		"$source" "ubuntu@127.0.0.1:$destination"
}

copy_from_guest()
{
	local port=$1 source=$2 destination=$3
	sshpass -p "$GUEST_PASSWORD" scp -P "$port" "${SSH_OPTIONS[@]}" \
		"ubuntu@127.0.0.1:$source" "$destination"
}

wait_for_guest()
{
	local port=$1
	for _ in $(seq 1 120); do
		if guest "$port" true >/dev/null 2>&1; then
			return 0
		fi
		sleep 1
	done
	echo "guest SSH timeout: port=$port" >&2
	return 1
}

stop_server()
{
	if (( ! server_running )); then
		return
	fi
	guest_root "$VM1_PORT" \
		'if test -f /tmp/cxsp-server.pid; then pid=$(cat /tmp/cxsp-server.pid); kill "$pid" 2>/dev/null || true; for i in $(seq 1 30); do kill -0 "$pid" 2>/dev/null || break; sleep .1; done; rm -f /tmp/cxsp-server.pid; fi' \
		>/dev/null 2>&1 || true
	server_running=0
}

start_server()
{
	local mode=$1 generation=$2 log_name=$3
	local command

	stop_server
	command="rm -f /tmp/cxsp-server.log /tmp/cxsp-server.pid; nohup /usr/local/bin/cxlfork_spawn_bench server $mode 192.168.91.11 $BENCH_PORT $KEY $generation $STATE_CHECKSUM >/tmp/cxsp-server.log 2>&1 & echo \$! >/tmp/cxsp-server.pid"
	guest_root "$VM1_PORT" "$command"
	server_running=1
	for _ in $(seq 1 50); do
		if guest "$VM1_PORT" grep -q server-ready /tmp/cxsp-server.log; then
			guest "$VM1_PORT" cat /tmp/cxsp-server.log \
				>"$RESULT_DIR/logs/$log_name-server-start.log"
			return 0
		fi
		sleep .1
	done
	guest "$VM1_PORT" cat /tmp/cxsp-server.log >&2 || true
	return 1
}

cleanup()
{
	local status=$?
	set +e
	stop_server
	if (( slot_ready )); then
		guest_root "$VM0_PORT" "/usr/local/bin/cxlfork_spawn_bench release $KEY $GENERATION" \
			>>"$RESULT_DIR/logs/release.log" 2>&1
		slot_ready=0
	fi
	if (( vms_started )); then
		"$WS/scripts/stop-cxlfork-vms.sh" cxl \
			>>"$RESULT_DIR/logs/vm-stop.log" 2>&1
		vms_started=0
	fi
	if (( status )); then
		printf '%s failed status=%d result_dir=%s\n' \
			"$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$status" "$RESULT_DIR" |
			tee -a "$RESULT_DIR/controller.log" >&2
	fi
	exit "$status"
}

build_selftests()
{
	mkdir -p "$BUILD_DIR/kselftest-uapi/include/linux"
	cp "$KERNEL_TREE/include/uapi/linux/cxlfork.h" \
		"$BUILD_DIR/kselftest-uapi/include/linux/cxlfork.h"
	make -C "$KERNEL_TREE/tools/testing/selftests/cxlfork" clean >/dev/null
	make -C "$KERNEL_TREE/tools/testing/selftests/cxlfork" \
		KHDR_INCLUDES="-I$BUILD_DIR/kselftest-uapi/include" -j"$(nproc)"
	# lib.mk uses an absolute OUTPUT target for the all-target, which bypasses
	# this program's target-specific static flags.  Re-link the benchmark via
	# its explicit target so both VMs receive a self-contained identical ELF.
	rm -f "$BENCH"
	make -C "$KERNEL_TREE/tools/testing/selftests/cxlfork" \
		KHDR_INCLUDES="-I$BUILD_DIR/kselftest-uapi/include" \
		cxlfork_spawn_bench
	test -x "$BENCH" -a -x "$SELFTEST"
	file "$BENCH" | grep -q 'statically linked'
}

capture_manifest()
{
	{
		echo "run_id=$RUN_ID"
		echo "backend=file-simulated-cxl"
		echo "host=$(hostname)"
		echo "date_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
		echo "kernel_image=$KERNEL_IMAGE"
		sha256sum "$KERNEL_IMAGE" "$BENCH"
		git -C "$WS" rev-parse HEAD
		git -C "$KERNEL_TREE" rev-parse HEAD
		git -C "$WS" status --short
		git -C "$KERNEL_TREE" status --short
		uname -a
		lscpu
		df -h /dev/shm "$WS"
	} >"$RESULT_DIR/manifest.txt"
}

deploy()
{
	local host_hash

	host_hash=$(sha256sum "$BENCH" | awk '{print $1}')
	for port in "$VM0_PORT" "$VM1_PORT"; do
		copy_to_guest "$port" "$BENCH" /tmp/cxlfork_spawn_bench
		copy_to_guest "$port" "$SELFTEST" /tmp/cxlfork_test
		guest_root "$port" \
			'install -m 0755 /tmp/cxlfork_spawn_bench /tmp/cxlfork_test /usr/local/bin/'
		test "$(guest "$port" sha256sum /usr/local/bin/cxlfork_spawn_bench |
			awk '{print $1}')" = "$host_hash"
	done
	guest_root "$VM0_PORT" \
		'ip addr flush dev eth1; ip addr add 192.168.91.10/24 dev eth1; ip link set eth1 up'
	guest_root "$VM1_PORT" \
		'ip addr flush dev eth1; ip addr add 192.168.91.11/24 dev eth1; ip link set eth1 up'
	guest "$VM0_PORT" ping -c 2 -W 1 192.168.91.11 \
		>"$RESULT_DIR/logs/direct-network.log"
}

run_gates()
{
	local prepared

	guest_root "$VM0_PORT" dmesg >"$RESULT_DIR/logs/vm0-dmesg-before.log"
	guest_root "$VM1_PORT" dmesg >"$RESULT_DIR/logs/vm1-dmesg-before.log"
	guest_root "$VM0_PORT" '/usr/local/bin/cxlfork_test abi' \
		>"$RESULT_DIR/logs/abi.log"
	guest_root "$VM0_PORT" \
		'/usr/local/bin/cxlfork_test v2-lifecycle 0x535041574e10' \
		>"$RESULT_DIR/logs/v2-lifecycle.log"
	KEY=$((0x535000000000 + $(date -u +%s)))
	prepared=$(guest_root "$VM0_PORT" \
		"/usr/local/bin/cxlfork_spawn_bench prepare $KEY")
	printf '%s\n' "$prepared" | tee "$RESULT_DIR/logs/prepare.log"
	GENERATION=$(sed -n 's/.* generation=\([0-9][0-9]*\).*/\1/p' <<<"$prepared")
	STATE_CHECKSUM=$(sed -n 's/.* state_checksum=\([0-9a-fA-F][0-9a-fA-F]*\).*/0x\1/p' <<<"$prepared")
	test -n "$GENERATION" -a -n "$STATE_CHECKSUM"
	slot_ready=1

	start_server cxlfork "$GENERATION" churn
	guest "$VM0_PORT" 'rm -f /tmp/cxsp-churn-lane-*.csv'
	guest "$VM0_PORT" \
		"/usr/local/bin/cxlfork_spawn_bench client-count cxlfork 192.168.91.11 $BENCH_PORT 1 $CHURN_REQUESTS $KEY $GENERATION $STATE_CHECKSUM /tmp/cxsp-churn" |
		tee "$RESULT_DIR/logs/churn-client.log"
	copy_from_guest "$VM0_PORT" /tmp/cxsp-churn-lane-0.csv \
		"$RESULT_DIR/gates/churn-10000.csv"
	guest "$VM0_PORT" rm -f /tmp/cxsp-churn-lane-0.csv
	stop_server
	guest_root "$VM1_PORT" \
		"/usr/local/bin/cxlfork_test inspect $KEY $GENERATION" |
		tee "$RESULT_DIR/logs/post-churn-inspect.log"
	grep -q 'readers=0' "$RESULT_DIR/logs/post-churn-inspect.log"
}

run_pass()
{
	local mode=$1 lanes=$2 pass=$3 generation=$4
	local prefix="/tmp/cxsp-${mode}-${lanes}-${pass}"
	local log_file="$RESULT_DIR/logs/${mode}-${lanes}-pass-${pass}-client.log"
	local output

	guest "$VM0_PORT" "rm -f ${prefix}-lane-*.csv"
	output=$(guest "$VM0_PORT" \
		"/usr/local/bin/cxlfork_spawn_bench client $mode 192.168.91.11 $BENCH_PORT $lanes $PILOT_WARMUP $PILOT_SECONDS $KEY $generation $STATE_CHECKSUM $prefix")
	printf '%s\n' "$output" | tee "$log_file"
	grep -q 'verify=ok' "$log_file"
	for lane in $(seq 0 $((lanes - 1))); do
		copy_from_guest "$VM0_PORT" "${prefix}-lane-${lane}.csv" \
			"$RESULT_DIR/raw/${mode}-${lanes}-pass-${pass}-lane-${lane}.csv"
	done
	guest "$VM0_PORT" "rm -f ${prefix}-lane-*.csv"
}

run_pilot()
{
	local mode lanes pass generation

	for lanes in $PILOT_LANES; do
		for mode in cxlfork local; do
			if [[ $mode == cxlfork ]]; then
				generation=$GENERATION
			else
				generation=0
			fi
			log "pilot begin mode=$mode lanes=$lanes"
			start_server "$mode" "$generation" "$mode-$lanes"
			for pass in $(seq 1 "$PILOT_PASSES"); do
				run_pass "$mode" "$lanes" "$pass" "$generation"
			done
			guest "$VM1_PORT" cat /tmp/cxsp-server.log \
				>"$RESULT_DIR/logs/$mode-$lanes-server-final.log"
			stop_server
		done
	done
}

summarize()
{
	python3 - "$RESULT_DIR" "$PILOT_SECONDS" <<'PY'
import csv, glob, math, os, re, statistics, sys

root, seconds = sys.argv[1], float(sys.argv[2])
pattern = re.compile(r'/(cxlfork|local)-(\d+)-pass-(\d+)-lane-(\d+)\.csv$')
rows = []
for path in sorted(glob.glob(os.path.join(root, 'raw', '*.csv'))):
    match = pattern.search(path)
    if not match:
        raise SystemExit(f'unexpected raw filename: {path}')
    mode, lanes, run_pass, lane = match.groups()
    with open(path, newline='') as handle:
        for row in csv.DictReader(handle):
            row = dict(row)
            row['configured_lanes'] = lanes
            row['pass'] = run_pass
            rows.append(row)
if not rows:
    raise SystemExit('no raw samples')

raw_fields = ['configured_lanes', 'pass'] + list(rows[0])[:-2]
with open(os.path.join(root, 'raw.csv.tmp'), 'w', newline='') as handle:
    writer = csv.DictWriter(handle, fieldnames=raw_fields)
    writer.writeheader()
    writer.writerows(rows)
os.replace(os.path.join(root, 'raw.csv.tmp'), os.path.join(root, 'raw.csv'))

pass_rows = []
for (mode, lanes, run_pass) in sorted({
        (r['mode'], int(r['configured_lanes']), int(r['pass'])) for r in rows}):
    count = sum(1 for r in rows if r['mode'] == mode and
                int(r['configured_lanes']) == lanes and int(r['pass']) == run_pass)
    pass_rows.append({'mode': mode, 'lanes': lanes, 'pass': run_pass,
                      'operations': count, 'duration_s': seconds,
                      'throughput_ops_s': count / seconds})
with open(os.path.join(root, 'passes.csv'), 'w', newline='') as handle:
    writer = csv.DictWriter(handle, fieldnames=pass_rows[0])
    writer.writeheader(); writer.writerows(pass_rows)

metrics = [
    'rtt_ns', 'vm0_residual_ns', 'target_total_ns', 'request_dispatch_ns',
    'activation_ns', 'exit_wait_ns', 'fork_parent_return_ns',
    'fork_to_child_ns', 'child_setup_ns', 'restore_wall_ns',
    'kernel_restore_ns', 'continuation_ns', 'kernel_core_ns',
    'capsule_validate_ns', 'activation_commit_ns', 'lock_wait_ns',
    'lifecycle_ns', 'manifest_validate_ns', 'checksum_validate_ns',
    'vma_create_ns', 'upper_pt_alloc_ns', 'shared_leaf_attach_ns',
    'kernel_other_ns']

def percentile(values, p):
    values = sorted(values)
    position = (len(values) - 1) * p
    low = math.floor(position); high = math.ceil(position)
    if low == high:
        return values[low]
    return values[low] + (values[high] - values[low]) * (position - low)

summary = []
groups = sorted({(r['mode'], int(r['configured_lanes'])) for r in rows})
for mode, lanes in groups:
    selected = [r for r in rows if r['mode'] == mode and
                int(r['configured_lanes']) == lanes]
    for metric in metrics:
        if mode == 'local' and metric in {
                'restore_wall_ns', 'kernel_restore_ns', 'kernel_core_ns',
                'capsule_validate_ns', 'activation_commit_ns', 'lock_wait_ns',
                'lifecycle_ns', 'manifest_validate_ns', 'checksum_validate_ns',
                'vma_create_ns', 'upper_pt_alloc_ns', 'shared_leaf_attach_ns',
                'kernel_other_ns'}:
            summary.append({'mode': mode, 'lanes': lanes, 'metric': metric,
                            'n': 0, 'mean': 'NA', 'p50': 'NA', 'p95': 'NA',
                            'p99': 'NA', 'stddev': 'NA'})
            continue
        values = [float(r[metric]) for r in selected]
        summary.append({'mode': mode, 'lanes': lanes, 'metric': metric,
                        'n': len(values), 'mean': statistics.fmean(values),
                        'p50': percentile(values, .50),
                        'p95': percentile(values, .95),
                        'p99': percentile(values, .99) if len(values) >= 1000 else 'NA',
                        'stddev': statistics.pstdev(values)})
with open(os.path.join(root, 'summary.csv'), 'w', newline='') as handle:
    writer = csv.DictWriter(handle, fieldnames=summary[0])
    writer.writeheader(); writer.writerows(summary)

# Exact, non-overlapping target-level accounting is a hard validity gate.
for row in rows:
    target = int(row['target_total_ns'])
    outer = sum(int(row[name]) for name in
                ('request_dispatch_ns', 'activation_ns', 'exit_wait_ns'))
    if target != outer:
        raise SystemExit(f'outer accounting mismatch request={row["request_id"]}')
    activation = int(row['activation_ns'])
    inner = sum(int(row[name]) for name in
                ('fork_to_child_ns', 'child_setup_ns', 'restore_wall_ns',
                 'continuation_ns'))
    if activation != inner:
        raise SystemExit(f'activation accounting mismatch request={row["request_id"]}')
print(f'summarized samples={len(rows)} groups={len(groups)} verify=ok')
PY
}

main()
{
	if [[ ${1:-} != run || $# -gt 2 ]]; then
		echo "usage: $0 run [RESULT_DIR]" >&2
		exit 2
	fi
	mkdir -p "$RESULT_DIR"/{raw,logs,gates}
	touch "$RESULT_DIR/controller.log"
	trap cleanup EXIT INT TERM
	log "build selftests"
	test -s "$KERNEL_IMAGE"
	build_selftests
	capture_manifest

	# Clean only the project VMs recorded by the existing scoped pidfiles.
	if guest "$VM1_PORT" true >/dev/null 2>&1; then
		guest_root "$VM1_PORT" \
			'if test -f /tmp/cxsp-server.pid; then kill $(cat /tmp/cxsp-server.pid) 2>/dev/null || true; fi' \
			>/dev/null 2>&1 || true
	fi
	"$WS/scripts/stop-cxlfork-vms.sh" cxl \
		>"$RESULT_DIR/logs/pre-run-stop.log" 2>&1 || true
	rm -f "$CXL_FILE" "$HYDRA_SHM_FILE"
	log "start fresh VM0/VM1"
	env KERNEL="$KERNEL_IMAGE" CXL_FILE="$CXL_FILE" \
		HYDRA_SHM_FILE="$HYDRA_SHM_FILE" SMP=16 MEM=16G \
		VM0_HOST_CPUS=48-63 VM1_HOST_CPUS=64-79 VM_MEMORY_NODE=1 \
		"$WS/scripts/start-cxlfork-vms.sh" cxl |
		tee "$RESULT_DIR/logs/vm-start.log"
	vms_started=1
	wait_for_guest "$VM0_PORT"
	wait_for_guest "$VM1_PORT"
	deploy
	run_gates
	run_pilot
	summarize | tee "$RESULT_DIR/logs/summarize.log"

	guest_root "$VM0_PORT" dmesg >"$RESULT_DIR/logs/vm0-dmesg-after.log"
	guest_root "$VM1_PORT" dmesg >"$RESULT_DIR/logs/vm1-dmesg-after.log"
	if grep -E 'BUG:|WARNING:|Oops:|general protection fault|KASAN:|cxlfork.*(fail|error)' \
		"$RESULT_DIR/logs/vm0-dmesg-after.log" \
		"$RESULT_DIR/logs/vm1-dmesg-after.log" \
		>"$RESULT_DIR/logs/dmesg-errors.log"; then
		echo "dmesg error signature found" >&2
		exit 1
	fi
	: >"$RESULT_DIR/logs/dmesg-errors.log"

	guest_root "$VM0_PORT" \
		"/usr/local/bin/cxlfork_spawn_bench release $KEY $GENERATION" |
		tee "$RESULT_DIR/logs/release.log"
	slot_ready=0
	"$WS/scripts/stop-cxlfork-vms.sh" cxl |
		tee "$RESULT_DIR/logs/vm-stop.log"
	vms_started=0
	find "$RESULT_DIR" -type f ! -name SHA256SUMS -print0 | sort -z |
		xargs -0 sha256sum >"$RESULT_DIR/SHA256SUMS"
	log "complete result_dir=$RESULT_DIR"
	trap - EXIT INT TERM
}

main "$@"
