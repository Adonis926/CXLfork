#!/usr/bin/env bash
set -euo pipefail

# One authoritative runner for the restricted CXLfork spawn experiment.
# It reuses start-cxlfork-vms.sh / stop-cxlfork-vms.sh and does not manage any
# QEMU process that is not recorded by those scripts.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CXSP_BACKEND=${CXSP_BACKEND:-file-sim}
CXSP_PROFILE=${CXSP_PROFILE:-$ROOT/config/cxlfork-spawn-real-cxl-103.env}
if [[ $CXSP_BACKEND == real-dax-103 ]]; then
	[[ -r $CXSP_PROFILE ]] || {
		echo "missing real-DAX profile: $CXSP_PROFILE" >&2
		exit 1
	}
	# shellcheck source=/dev/null
	source "$CXSP_PROFILE"
elif [[ $CXSP_BACKEND != file-sim ]]; then
	echo "CXSP_BACKEND must be file-sim or real-dax-103" >&2
	exit 2
fi

# Scale experiments override the real-DAX profile through CXSP_* variables.
# Keeping the profile defaults intact preserves the accepted 16+16-vCPU run.
SMP=${CXSP_SMP:-${SMP:-16}}
VM0_HOST_CPUS=${CXSP_VM0_HOST_CPUS:-${VM0_HOST_CPUS:-}}
VM1_HOST_CPUS=${CXSP_VM1_HOST_CPUS:-${VM1_HOST_CPUS:-}}
VM0_MEMORY_NODE=${CXSP_VM0_MEMORY_NODE:-${VM0_MEMORY_NODE:-${VM_MEMORY_NODE:-}}}
VM1_MEMORY_NODE=${CXSP_VM1_MEMORY_NODE:-${VM1_MEMORY_NODE:-${VM_MEMORY_NODE:-}}}
export SMP VM0_HOST_CPUS VM1_HOST_CPUS VM0_MEMORY_NODE VM1_MEMORY_NODE

WS=${WS:-/home/xtl/cxlfork/cxlfork-repro}
KERNEL_TREE=${KERNEL_TREE:-$WS/kernel/linux-6.6.32}
BUILD_DIR=${BUILD_DIR:-$WS/kernel/build-6.6.32-spawn}
KERNEL_IMAGE=${KERNEL_IMAGE:-${KERNEL:-$BUILD_DIR/arch/x86/boot/bzImage}}
QEMU=${QEMU:-qemu-system-x86_64}
QEMU=$(command -v "$QEMU" 2>/dev/null || printf '%s' "$QEMU")
RESULT_ROOT=${RESULT_ROOT:-$WS/results/cxlfork-spawn}
VM0_PORT=${VM0_PORT:-2200}
VM1_PORT=${VM1_PORT:-2201}
GUEST_PASSWORD=${GUEST_PASSWORD:-123}
BENCH_PORT=${BENCH_PORT:-7100}
CXL_FILE=${CXL_FILE:-/dev/shm/cxlfork_spawn_mem}
HYDRA_SHM_FILE=${HYDRA_SHM_FILE:-/dev/shm/cxlfork_spawn_aux}
CXSP_LANES=${CXSP_LANES:-${PILOT_LANES:-"1 4 16"}}
CXSP_MODES=${CXSP_MODES:-"cxlfork local"}
CXSP_PASSES=${CXSP_PASSES:-${PILOT_PASSES:-3}}
CXSP_WARMUP_SECONDS=${CXSP_WARMUP_SECONDS:-${PILOT_WARMUP:-2}}
CXSP_MEASURE_SECONDS=${CXSP_MEASURE_SECONDS:-${PILOT_SECONDS:-5}}
CHURN_REQUESTS=${CHURN_REQUESTS:-10000}
if [[ $CXSP_BACKEND == real-dax-103 ]]; then
	RUN_ID=${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-103-real-dax}
else
	RUN_ID=${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-91-file-sim}
fi
RESULT_DIR=${2:-$RESULT_ROOT/$RUN_ID}

BENCH=$KERNEL_TREE/tools/testing/selftests/cxlfork/cxlfork_spawn_bench
SELFTEST=$KERNEL_TREE/tools/testing/selftests/cxlfork/cxlfork_test
SSH_OPTIONS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
	-o LogLevel=ERROR -o ConnectTimeout=3)
if [[ -n ${SSH_KEY:-} ]]; then
	SSH_OPTIONS+=(-o IdentitiesOnly=yes -i "$SSH_KEY")
fi
slot_ready=0
server_running=0
vms_started=0
real_host_entered=0
real_kvm_loaded=0
governors_saved=0
KEY=0
GENERATION=0
STATE_CHECKSUM=0
REAL_RUNTIME_ROOT=${REAL_RUNTIME_ROOT:-/home/xtl/start/hpca-cxlfork}
REAL_DAX_ADMIN=$WS/scripts/real-cxl-103/dax-admin.sh
REAL_KVM_LOADER=${REAL_KVM_LOADER:-/home/xtl/start/hpca/load-native-kvm.sh}
REAL_LOCK=${REAL_LOCK:-/run/lock/cxlfork-spawn-real-cxl-103.lock}
GOVERNOR_STATE=$RESULT_DIR/host-governors.tsv

log()
{
	printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" |
		tee -a "$RESULT_DIR/controller.log"
}

validate_config()
{
	local lanes mode count0 count1 overlap

	[[ $SMP =~ ^[1-9][0-9]*$ ]] && (( SMP <= 128 )) || {
		echo "SMP must be in 1..128: $SMP" >&2
		return 2
	}

	[[ $CXSP_PASSES =~ ^[1-9][0-9]*$ ]] || {
		echo "CXSP_PASSES must be positive: $CXSP_PASSES" >&2
		return 2
	}
	[[ $CXSP_WARMUP_SECONDS =~ ^[0-9]+$ ]] || {
		echo "CXSP_WARMUP_SECONDS must be non-negative: $CXSP_WARMUP_SECONDS" >&2
		return 2
	}
	[[ $CXSP_MEASURE_SECONDS =~ ^[1-9][0-9]*$ ]] || {
		echo "CXSP_MEASURE_SECONDS must be positive: $CXSP_MEASURE_SECONDS" >&2
		return 2
	}
	for lanes in $CXSP_LANES; do
		[[ $lanes =~ ^[1-9][0-9]*$ ]] && (( lanes <= SMP )) || {
			echo "each CXSP_LANES value must be in 1..SMP ($SMP): $lanes" >&2
			return 2
		}
	done
	[[ -n $CXSP_LANES ]] || {
		echo "CXSP_LANES is empty" >&2
		return 2
	}
	for mode in $CXSP_MODES; do
		[[ $mode == cxlfork || $mode == local ]] || {
			echo "each CXSP_MODES value must be cxlfork or local: $mode" >&2
			return 2
		}
	done
	[[ -n $CXSP_MODES ]] || {
		echo "CXSP_MODES is empty" >&2
		return 2
	}
	if [[ $CXSP_BACKEND == real-dax-103 ]]; then
		[[ -n $VM0_HOST_CPUS && -n $VM1_HOST_CPUS ]] || {
			echo "real-DAX scaling requires both host CPU lists" >&2
			return 2
		}
		count0=$(expand_cpu_list "$VM0_HOST_CPUS" | sort -un | wc -l)
		count1=$(expand_cpu_list "$VM1_HOST_CPUS" | sort -un | wc -l)
		[[ $count0 -eq $SMP && $count1 -eq $SMP ]] || {
			echo "host CPU list size must equal SMP=$SMP: vm0=$count0 vm1=$count1" >&2
			return 2
		}
		overlap=$(comm -12 \
			<(expand_cpu_list "$VM0_HOST_CPUS" | sort -un) \
			<(expand_cpu_list "$VM1_HOST_CPUS" | sort -un) | head -n 1)
		[[ -z $overlap ]] || {
			echo "VM host CPU lists overlap at CPU $overlap" >&2
			return 2
		}
	fi
}

expand_cpu_list()
{
	local list=$1 item begin end cpu
	local -a items

	IFS=',' read -r -a items <<<"$list"
	for item in "${items[@]}"; do
		if [[ $item =~ ^([0-9]+)-([0-9]+)$ ]]; then
			begin=${BASH_REMATCH[1]}
			end=${BASH_REMATCH[2]}
			(( begin <= end )) || return 2
			for ((cpu = begin; cpu <= end; cpu++)); do
				echo "$cpu"
			done
		elif [[ $item =~ ^[0-9]+$ ]]; then
			echo "$item"
		else
			echo "invalid CPU list item: $item" >&2
			return 2
		fi
	done
}

save_and_set_governors()
{
	local cpu policy governor
	local -A seen=()

	: >"$GOVERNOR_STATE"
	governors_saved=1
	for cpu in $(
		{
			expand_cpu_list "$VM0_HOST_CPUS"
			expand_cpu_list "$VM1_HOST_CPUS"
		} | sort -un
	); do
		policy=$(readlink -f "/sys/devices/system/cpu/cpu$cpu/cpufreq" 2>/dev/null || true)
		[[ -n $policy && -r $policy/scaling_governor ]] || {
			echo "missing cpufreq policy for pinned CPU $cpu" >&2
			return 1
		}
		[[ -z ${seen[$policy]+x} ]] || continue
		seen[$policy]=1
		governor=$(<"$policy/scaling_governor")
		printf '%s\t%s\n' "$policy" "$governor" >>"$GOVERNOR_STATE"
		printf '%s\n' performance >"$policy/scaling_governor"
	done
	while IFS=$'\t' read -r policy governor; do
		[[ $(<"$policy/scaling_governor") == performance ]] || {
			echo "failed to set performance governor: $policy" >&2
			return 1
		}
	done <"$GOVERNOR_STATE"
}

restore_governors()
{
	local policy governor

	(( governors_saved )) || return 0
	while IFS=$'\t' read -r policy governor; do
		[[ -w $policy/scaling_governor ]] || return 1
		printf '%s\n' "$governor" >"$policy/scaling_governor"
	done <"$GOVERNOR_STATE"
	governors_saved=0
}

real_dax_admin()
{
	env PROFILE="$CXSP_PROFILE" RUNTIME_ROOT="$REAL_RUNTIME_ROOT" \
		CXLFORK_EXCLUSIVE_CONFIRM="${CXLFORK_EXCLUSIVE_CONFIRM:-}" \
		"$REAL_DAX_ADMIN" "$@"
}

reset_real_work_images()
{
	local source destination temporary expected actual

	mkdir -p "$WS/images"
	for name in vm0 vm1; do
		if [[ $name == vm0 ]]; then
			source=$VM0_BASE_IMAGE
			expected=$VM0_BASE_IMAGE_SHA256
		else
			source=$VM1_BASE_IMAGE
			expected=$VM1_BASE_IMAGE_SHA256
		fi
		destination=$WS/images/$name.qcow2
		temporary=$destination.cxsp-new
		actual=$(sha256sum "$source" | awk '{print $1}')
		[[ $actual == "$expected" ]] || {
			echo "$name pristine image SHA256 mismatch" >&2
			return 1
		}
		rm -f "$temporary"
		cp --reflink=auto --sparse=always "$source" "$temporary"
		qemu-img check -q "$temporary"
		mv -f "$temporary" "$destination"
	done
}

prepare_real_host()
{
	[[ ${EUID:-$(id -u)} -eq 0 ]] || {
		echo "real-dax-103 runs must be started through sudo -E" >&2
		return 1
	}
	[[ ${CXLFORK_EXCLUSIVE_CONFIRM:-} == I_HAVE_EXCLUSIVE_KVM_DAX_103 ]] || {
		echo "real-DAX exclusive confirmation is missing" >&2
		return 1
	}
	[[ $(hostname -s) == Lux ]] || {
		echo "real-dax-103 is restricted to host Lux" >&2
		return 1
	}
	mkdir -p "$(dirname "$REAL_LOCK")"
	exec 8>"$REAL_LOCK"
	flock -n 8 || {
		echo "another CXLfork-spawn real-DAX run holds $REAL_LOCK" >&2
		return 1
	}
	if pgrep -af '[q]emu-system.*x86_64' >"$RESULT_DIR/logs/preflight-qemu.log"; then
		echo "QEMU is already running; refusing to switch KVM or use DAX" >&2
		cat "$RESULT_DIR/logs/preflight-qemu.log" >&2
		return 1
	fi
	if [[ -d /sys/module/kvm || -e /dev/kvm ]]; then
		echo "KVM was already loaded; refusing to replace an unknown host profile" >&2
		return 1
	fi
	reset_real_work_images
	"$REAL_KVM_LOADER" >"$RESULT_DIR/logs/kvm-load.log" 2>&1
	real_kvm_loaded=1
	real_dax_admin preflight >"$RESULT_DIR/logs/dax-preflight.log" 2>&1
	real_dax_admin enter >"$RESULT_DIR/logs/dax-enter.log" 2>&1
	real_host_entered=1
	real_dax_admin zero >"$RESULT_DIR/logs/dax-zero.log" 2>&1
	save_and_set_governors
}

restore_real_host()
{
	local status=0

	if (( governors_saved )); then
		restore_governors >>"$RESULT_DIR/logs/host-restore.log" 2>&1 || status=1
	fi
	if (( real_host_entered )); then
		if real_dax_admin restore >>"$RESULT_DIR/logs/host-restore.log" 2>&1; then
			real_host_entered=0
		else
			status=1
		fi
	fi
	if (( real_kvm_loaded )); then
		if modprobe -r kvm_intel kvm >>"$RESULT_DIR/logs/host-restore.log" 2>&1; then
			real_kvm_loaded=0
		else
			status=1
		fi
	fi
	return "$status"
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
	local cleanup_failed=0
	trap - EXIT INT TERM
	set +e
	stop_server
	if (( slot_ready )); then
		guest_root "$VM0_PORT" "/usr/local/bin/cxlfork_spawn_bench release $KEY $GENERATION" \
			>>"$RESULT_DIR/logs/release.log" 2>&1 || cleanup_failed=1
		slot_ready=0
	fi
	if (( vms_started )); then
		"$WS/scripts/stop-cxlfork-vms.sh" cxl \
			>>"$RESULT_DIR/logs/vm-stop.log" 2>&1 || cleanup_failed=1
		vms_started=0
	fi
	if [[ $CXSP_BACKEND == real-dax-103 ]]; then
		restore_real_host || cleanup_failed=1
	fi
	if (( cleanup_failed && status == 0 )); then
		status=1
	fi
	if (( status )); then
		printf '%s failed status=%d result_dir=%s\n' \
			"$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$status" "$RESULT_DIR" |
			tee -a "$RESULT_DIR/controller.log" >&2
	fi
	if [[ ${EUID:-$(id -u)} -eq 0 && -n ${SUDO_USER:-} && -d $RESULT_DIR ]]; then
		chown -R "$SUDO_USER":"$(id -gn "$SUDO_USER")" "$RESULT_DIR"
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
	mkdir -p "$BUILD_DIR/kselftest/cxlfork"
	cp "$KERNEL_TREE/tools/testing/selftests/cxlfork/cxlfork_litmus" \
		"$BUILD_DIR/kselftest/cxlfork/cxlfork_litmus"
}

capture_manifest()
{
	{
		echo "run_id=$RUN_ID"
		echo "backend=$CXSP_BACKEND"
		echo "workload=restricted-cxlfork-v4-remote-spawn"
		echo "modes=$CXSP_MODES"
		echo "lanes=$CXSP_LANES"
		echo "smp_per_vm=$SMP"
		echo "total_guest_vcpus=$((2 * SMP))"
		echo "vm0_host_cpus=$VM0_HOST_CPUS"
		echo "vm1_host_cpus=$VM1_HOST_CPUS"
		echo "vm0_memory_node=${VM0_MEMORY_NODE:-none}"
		echo "vm1_memory_node=${VM1_MEMORY_NODE:-none}"
		echo "passes=$CXSP_PASSES"
		echo "warmup_seconds=$CXSP_WARMUP_SECONDS"
		echo "measure_seconds=$CXSP_MEASURE_SECONDS"
		echo "churn_requests=$CHURN_REQUESTS"
		echo "host=$(hostname)"
		echo "date_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
		echo "kernel_image=$KERNEL_IMAGE"
		sha256sum "$KERNEL_IMAGE" "$BENCH" "$SELFTEST" "$QEMU" \
			"$WS/images/vm0.qcow2" "$WS/images/vm1.qcow2" \
			"$WS/cloudinit/vm0-seed.iso" "$WS/cloudinit/vm1-seed.iso"
		printf 'main_git_head='
		git -C "$WS" rev-parse HEAD
		printf 'kernel_git_head='
		git -C "$KERNEL_TREE" rev-parse HEAD
		echo "git_status_scope=tracked-files-only; kselftest ELF files are generated outputs"
		git -C "$WS" status --short --untracked-files=no
		git -C "$KERNEL_TREE" status --short --untracked-files=no
		uname -a
		lscpu
		numactl --hardware 2>/dev/null || true
		df -h /dev/shm "$WS"
		if [[ $CXSP_BACKEND == real-dax-103 ]]; then
			echo "cxl_extent=[${CXL_BACKEND_OFFSET},$CXL_BACKEND_SIZE]"
			echo "hydra_extent_mapped_but_unused=[${HYDRA_BACKEND_OFFSET},${HYDRA_SHM_SIZE}]"
			daxctl list -d dax0.0 -M
			lspci -nn -s d4:00.0 -vv 2>/dev/null || true
			for parameter in ept eptad; do
				printf 'kvm_intel_%s=' "$parameter"
				cat "/sys/module/kvm_intel/parameters/$parameter"
			done
			for parameter in tdp_mmu gvm_irq_enabled gvm_irq_userspace_forwarding; do
				[[ -r /sys/module/kvm/parameters/$parameter ]] || continue
				printf 'kvm_%s=' "$parameter"
				cat "/sys/module/kvm/parameters/$parameter"
			done
		fi
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

capture_guest_topology()
{
	local port name

	for entry in "vm0:$VM0_PORT" "vm1:$VM1_PORT"; do
		name=${entry%%:*}
		port=${entry##*:}
		guest_root "$port" \
			'uname -a; cat /proc/cmdline; nproc; ls -l /dev/cxlfork; dmesg | grep -Ei "cxlfork|nvdimm|e820" | tail -n 120' \
			>"$RESULT_DIR/logs/$name-topology.log"
		grep -q 'cxlfork.cxl_phys=0x484000000' "$RESULT_DIR/logs/$name-topology.log"
		grep -q 'cxlfork.cxl_size=0xfb000000' "$RESULT_DIR/logs/$name-topology.log"
		grep -q '/dev/cxlfork' "$RESULT_DIR/logs/$name-topology.log"
		grep -qx "$SMP" "$RESULT_DIR/logs/$name-topology.log"
	done
}

run_atomic_litmus()
{
	[[ $CXSP_BACKEND == real-dax-103 ]] || return 0
	env WS="$WS" QEMU="$QEMU" KBUILD="$BUILD_DIR" \
		VM0_PORT="$VM0_PORT" VM1_PORT="$VM1_PORT" SSH_KEY="${SSH_KEY:-}" \
		GUEST_PASSWORD="$GUEST_PASSWORD" \
		OUT="$RESULT_DIR/gates/cross-vm-litmus.log" \
		ROUNDS="${LITMUS_ROUNDS:-10}" ITERATIONS="${LITMUS_ITERATIONS:-100000}" \
		"$WS/scripts/run-cxlfork-litmus.sh"
	grep -q 'CXLFORK_LITMUS_OK' "$RESULT_DIR/gates/cross-vm-litmus.log"
}

validate_shared_pfn_proof()
{
	local proof shared_leaf current_leaf shared_data current_data

	proof=$(grep -m1 'event=shared-pfn-proof.*verify=ok' \
		"$RESULT_DIR/logs/churn-client.log")
	shared_leaf=$(sed -n 's/.* shared_leaf_pfn=\([0-9][0-9]*\).*/\1/p' <<<"$proof")
	current_leaf=$(sed -n 's/.* current_pmd_pfn=\([0-9][0-9]*\).*/\1/p' <<<"$proof")
	shared_data=$(sed -n 's/.* shared_data_pfn=\([0-9][0-9]*\).*/\1/p' <<<"$proof")
	current_data=$(sed -n 's/.* current_data_pfn=\([0-9][0-9]*\).*/\1/p' <<<"$proof")
	[[ -n $shared_leaf && $shared_leaf != 0 && $shared_leaf == "$current_leaf" ]]
	[[ -n $shared_data && $shared_data != 0 && $shared_data == "$current_data" ]]
	printf '%s\n' "$proof" >"$RESULT_DIR/gates/shared-pfn-proof.log"
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
	validate_shared_pfn_proof
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
		"/usr/local/bin/cxlfork_spawn_bench client $mode 192.168.91.11 $BENCH_PORT $lanes $CXSP_WARMUP_SECONDS $CXSP_MEASURE_SECONDS $KEY $generation $STATE_CHECKSUM $prefix")
	printf '%s\n' "$output" | tee "$log_file"
	grep -q 'verify=ok' "$log_file"
	for lane in $(seq 0 $((lanes - 1))); do
		copy_from_guest "$VM0_PORT" "${prefix}-lane-${lane}.csv" \
			"$RESULT_DIR/raw/${mode}-${lanes}-pass-${pass}-lane-${lane}.csv"
	done
	guest "$VM0_PORT" "rm -f ${prefix}-lane-*.csv"
}

run_matrix()
{
	local mode lanes pass generation

	for lanes in $CXSP_LANES; do
		for mode in $CXSP_MODES; do
			if [[ $mode == cxlfork ]]; then
				generation=$GENERATION
			else
				generation=0
			fi
			log "matrix begin mode=$mode lanes=$lanes"
			start_server "$mode" "$generation" "$mode-$lanes"
			for pass in $(seq 1 "$CXSP_PASSES"); do
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
	python3 - "$RESULT_DIR" "$CXSP_MEASURE_SECONDS" <<'PY'
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
    path = 'remote-cxlfork' if mode == 'cxlfork' else 'remote-target-local'
    throughput = count / seconds
    pass_rows.append({'mode': mode, 'path': path, 'lanes': lanes, 'pass': run_pass,
                      'operations': count, 'duration_s': seconds,
                      'throughput_ops_s': throughput,
                      'remote_spawn_lps': throughput})
with open(os.path.join(root, 'passes.csv'), 'w', newline='') as handle:
    writer = csv.DictWriter(handle, fieldnames=pass_rows[0])
    writer.writeheader(); writer.writerows(pass_rows)

throughput_summary = []
for mode, lanes in sorted({(r['mode'], int(r['lanes'])) for r in pass_rows}):
    selected = [float(r['remote_spawn_lps']) for r in pass_rows
                if r['mode'] == mode and int(r['lanes']) == lanes]
    throughput_summary.append({
        'mode': mode,
        'path': 'remote-cxlfork' if mode == 'cxlfork' else 'remote-target-local',
        'lanes': lanes,
        'passes': len(selected),
        'mean_lps': statistics.fmean(selected),
        'stddev_lps': statistics.pstdev(selected),
        'min_lps': min(selected),
        'max_lps': max(selected),
    })
with open(os.path.join(root, 'throughput-summary.csv'), 'w', newline='') as handle:
    writer = csv.DictWriter(handle, fieldnames=throughput_summary[0])
    writer.writeheader(); writer.writerows(throughput_summary)

metrics = [
    'rtt_ns', 'vm0_residual_ns', 'target_total_ns', 'request_dispatch_ns',
    'activation_ns', 'exit_wait_ns', 'fork_parent_return_ns',
    'fork_to_child_ns', 'child_setup_ns', 'restore_wall_ns',
    'kernel_restore_ns', 'continuation_ns', 'kernel_core_ns',
    'capsule_validate_ns', 'activation_commit_ns', 'lock_wait_ns',
    'lifecycle_ns', 'manifest_validate_ns', 'checksum_validate_ns',
    'vma_create_ns', 'upper_pt_alloc_ns', 'shared_leaf_attach_ns',
    'kernel_other_ns']

v3_valid_bits = {
    'lock_wait_ns': 0, 'lifecycle_ns': 1, 'manifest_validate_ns': 2,
    'checksum_validate_ns': 4, 'vma_create_ns': 6,
    'upper_pt_alloc_ns': 7, 'shared_leaf_attach_ns': 8,
    'kernel_other_ns': 18,
}

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
        if (metric in v3_valid_bits and 'kernel_valid_mask' in selected[0] and
                all(not (int(r['kernel_valid_mask']) &
                         (1 << v3_valid_bits[metric])) for r in selected)):
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
    # The latest V4 benchmark exports capability, validity and path masks for
    # every restore. They prevent unsupported buckets from being interpreted
    # as real zero-cost mechanisms.
    if row['mode'] == 'cxlfork':
        for name in ('kernel_supported_mask', 'kernel_valid_mask',
                     'kernel_path_mask'):
            if name not in row or not row[name] or int(row[name], 0) == 0:
                raise SystemExit(f'missing {name} request={row["request_id"]}')
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
	validate_config
	log "build selftests"
	test -s "$KERNEL_IMAGE"
	build_selftests

	# Clean only the project VMs recorded by the existing scoped pidfiles.
	if guest "$VM1_PORT" true >/dev/null 2>&1; then
		guest_root "$VM1_PORT" \
			'if test -f /tmp/cxsp-server.pid; then kill $(cat /tmp/cxsp-server.pid) 2>/dev/null || true; fi' \
			>/dev/null 2>&1 || true
	fi
	"$WS/scripts/stop-cxlfork-vms.sh" cxl \
		>"$RESULT_DIR/logs/pre-run-stop.log" 2>&1 || true
	if [[ $CXSP_BACKEND == real-dax-103 ]]; then
		log "prepare exclusive real-DAX host"
		KERNEL_SHA256=$(sha256sum "$KERNEL_IMAGE" | awk '{print $1}')
		export KERNEL_SHA256
		prepare_real_host
	else
		rm -f "$CXL_FILE" "$HYDRA_SHM_FILE"
	fi
	capture_manifest
	log "start fresh VM0/VM1"
	vms_started=1
	if [[ $CXSP_BACKEND == real-dax-103 ]]; then
		env KERNEL="$KERNEL_IMAGE" "$WS/scripts/start-cxlfork-vms.sh" cxl |
			tee "$RESULT_DIR/logs/vm-start.log"
	else
		env KERNEL="$KERNEL_IMAGE" CXL_FILE="$CXL_FILE" \
			HYDRA_SHM_FILE="$HYDRA_SHM_FILE" SMP=16 MEM=16G \
			VM0_HOST_CPUS=48-63 VM1_HOST_CPUS=64-79 VM_MEMORY_NODE=1 \
			"$WS/scripts/start-cxlfork-vms.sh" cxl |
			tee "$RESULT_DIR/logs/vm-start.log"
	fi
	wait_for_guest "$VM0_PORT"
	wait_for_guest "$VM1_PORT"
	deploy
	capture_guest_topology
	run_atomic_litmus
	run_gates
	run_matrix
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
	if [[ $CXSP_BACKEND == real-dax-103 ]]; then
		restore_real_host
	fi
	log "complete result_dir=$RESULT_DIR"
	(
		cd "$RESULT_DIR"
		find . -type f ! -name SHA256SUMS -print0 | sort -z |
			xargs -0 sha256sum >SHA256SUMS
	)
	if [[ ${EUID:-$(id -u)} -eq 0 && -n ${SUDO_USER:-} ]]; then
		chown -R "$SUDO_USER":"$(id -gn "$SUDO_USER")" "$RESULT_DIR"
	fi
	trap - EXIT INT TERM
}

main "$@"
