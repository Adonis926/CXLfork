#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
PROFILE=${PROFILE:-$ROOT/config/real-cxl-103.env}
RUNTIME_ROOT=${RUNTIME_ROOT:-/home/xtl/start/hpca-cxlfork}
DAX_DEV=/dev/dax0.0
DAX_NAME=dax0.0
DAX_SYSFS=/sys/bus/dax/devices/dax0.0
EXPECTED_SIZE=68719476736
EXPECTED_ALIGN=2097152
EXPECTED_HOST=Lux
EXPECTED_KERNEL=6.6.32-shm+
EXCLUSIVE_TOKEN=I_HAVE_EXCLUSIVE_KVM_DAX_103
STATE_DIR=$RUNTIME_ROOT/manifests
STATE_FILE=$STATE_DIR/active-host-state.env
ACL_FILE=$STATE_DIR/active-device.acl
LOCK_FILE=$RUNTIME_ROOT/.dax-admin.lock
ZERO_SOURCE=$ROOT/tools/dax_range_zero.c
ZERO_BINARY=$RUNTIME_ROOT/bin/dax_range_zero

[[ -r "$PROFILE" ]] || { echo "missing profile: $PROFILE" >&2; exit 1; }
# shellcheck source=/dev/null
source "$PROFILE"

QEMU_SHA256=${QEMU_SHA256:-8ac0439e63ae69d73f82160c529687512b621c94ddf70e4ef8bf6237971036c0}
KERNEL_SHA256=${KERNEL_SHA256:-ebc389f912a1ba7bbc9556b23fe136845b000eaced9f227398f99edbfcaea0d0}

die() {
	echo "dax-admin: $*" >&2
	exit 1
}

need_root() {
	[[ ${EUID:-$(id -u)} -eq 0 ]] || die "'$1' must run through sudo -E"
}

require_exclusive_confirmation() {
	[[ ${CXLFORK_EXCLUSIVE_CONFIRM:-} == "$EXCLUSIVE_TOKEN" ]] || die \
		"exclusive gate locked; coordinate the host, then export CXLFORK_EXCLUSIVE_CONFIRM=$EXCLUSIVE_TOKEN"
}

mode() {
	daxctl list -d "$DAX_NAME" | jq -er '.[0].mode'
}

driver() {
	readlink -f "$DAX_SYSFS/driver" 2>/dev/null || echo unavailable
}

port_busy() {
	ss -H -lnt "sport = :$1" | grep -q .
}

qemu_processes() {
	pgrep -af '[q]emu-system.*x86_64' || true
}

device_holders() {
	local device
	for device in /dev/kvm "$DAX_DEV"; do
		if [[ -e "$device" ]]; then
			fuser -v "$device" 2>&1 || true
		fi
	done
}

require_idle_devices() {
	local qemu holders
	qemu=$(qemu_processes)
	holders=$(device_holders)
	[[ -z "$qemu" ]] || die "QEMU is active:\n$qemu"
	[[ -z "$holders" ]] || die "KVM or DAX has active holders:\n$holders"
}

require_geometry() {
	local size align target
	size=$(cat "$DAX_SYSFS/size")
	align=$(cat "$DAX_SYSFS/align")
	target=$(daxctl list -d "$DAX_NAME" | jq -er '.[0].target_node')
	[[ "$size" == "$EXPECTED_SIZE" ]] || die "unexpected DAX size=$size"
	[[ "$align" == "$EXPECTED_ALIGN" ]] || die "unexpected DAX align=$align"
	[[ "$target" == 2 ]] || die "unexpected DAX target_node=$target"
}

require_system_ram_removable() {
	local states=() removable=() blocks=() used
	shopt -s nullglob
	blocks=(/sys/devices/system/node/node2/memory[0-9]*)
	shopt -u nullglob
	[[ ${#blocks[@]} -eq 31 ]] || die "expected 31 node2 memory blocks, found ${#blocks[@]}"
	local block
	for block in "${blocks[@]}"; do
		states+=("$(cat "$block/state")")
		removable+=("$(cat "$block/removable")")
		grep -qw Movable "$block/valid_zones" || die "${block##*/} is outside the Movable zone"
	done
	[[ $(printf '%s\n' "${states[@]}" | sort -u) == online ]] || die "not all node2 blocks are online"
	[[ $(printf '%s\n' "${removable[@]}" | sort -u) == 1 ]] || die "not all node2 blocks are removable"
	used=$(awk '/MemUsed:/ {print $4}' /sys/devices/system/node/node2/meminfo)
	[[ "$used" == 0 ]] || die "node2 is in use: MemUsed=${used}kB"
}

system_ram_has_offline_blocks() {
	local blocks=() block

	shopt -s nullglob
	blocks=(/sys/devices/system/node/node2/memory[0-9]*)
	shopt -u nullglob
	[[ ${#blocks[@]} -eq 31 ]] || return 0
	for block in "${blocks[@]}"; do
		[[ $(cat "$block/state") == online ]] || return 0
	done
	return 1
}

require_gvm_disabled() {
	local parameter value
	for parameter in \
		gvm_irq_enabled gvm_irq_userspace_forwarding gvm_perf_collect \
		gvm_perf_log gvm_private_access_sampling gvm_private_hot_log \
		gvm_private_huge_ept gvm_private_migration_enabled; do
		if [[ -r /sys/module/kvm/parameters/$parameter ]]; then
			value=$(cat "/sys/module/kvm/parameters/$parameter")
			[[ "$value" == N ]] || die "KVM parameter $parameter=$value (expected N)"
		fi
	done
	[[ $(cat /sys/module/kvm_intel/parameters/ept) == Y ]] || die "KVM EPT is disabled"
}

require_asset() {
	local expected=$1 path=$2 actual
	[[ -r "$path" ]] || die "missing asset: $path"
	actual=$(sha256sum "$path" | awk '{print $1}')
	[[ "$actual" == "$expected" ]] || die "SHA256 mismatch: $path ($actual)"
}

require_assets() {
	require_asset "$QEMU_SHA256" "$QEMU"
	require_asset "$KERNEL_SHA256" "$KERNEL"
	if [[ -n ${VM0_IMAGE_SHA256:-} ]]; then
		require_asset "$VM0_IMAGE_SHA256" "$WS/images/vm0.qcow2"
	fi
	if [[ -n ${VM1_IMAGE_SHA256:-} ]]; then
		require_asset "$VM1_IMAGE_SHA256" "$WS/images/vm1.qcow2"
	fi
	if [[ -n ${VM0_BASE_IMAGE:-} ]]; then
		require_asset "$VM0_BASE_IMAGE_SHA256" "$VM0_BASE_IMAGE"
	fi
	if [[ -n ${VM1_BASE_IMAGE:-} ]]; then
		require_asset "$VM1_BASE_IMAGE_SHA256" "$VM1_BASE_IMAGE"
	fi
	local image
	for image in "$WS/images/vm0.qcow2" "$WS/images/vm1.qcow2"; do
		[[ -r "$image" ]] || die "missing work image: $image"
		qemu-img check -q "$image" || die "qemu-img check failed: $image"
	done
}

require_ports_free() {
	local port
	for port in "$VM0_PORT" "$VM1_PORT" "$VM1_CONTROL_PORT"; do
		if port_busy "$port"; then
			die "TCP port $port is busy"
		fi
	done
	return 0
}

common_preflight() {
	[[ $(hostname -s) == "$EXPECTED_HOST" ]] || die "expected host $EXPECTED_HOST, found $(hostname -s)"
	[[ $(uname -r) == "$EXPECTED_KERNEL" ]] || die "expected kernel $EXPECTED_KERNEL, found $(uname -r)"
	command -v daxctl >/dev/null || die "daxctl is missing"
	command -v jq >/dev/null || die "jq is missing"
	[[ -d "$DAX_SYSFS" ]] || die "missing $DAX_SYSFS"
	require_geometry
	require_idle_devices
	require_ports_free
	require_gvm_disabled
	require_assets
	case $(mode) in
		system-ram)
			[[ $(driver) == */kmem ]] || die "system-ram mode is not using kmem"
			require_system_ram_removable
			;;
		devdax)
			[[ $(driver) == */device_dax ]] || die "devdax mode is not using device_dax"
			[[ -c "$DAX_DEV" ]] || die "$DAX_DEV is not a character device"
			;;
		*) die "unsupported dax mode: $(mode)" ;;
	esac
}

show_status() {
	echo "host=$(hostname -s) kernel=$(uname -r) dax_mode=$(mode) dax_driver=$(driver)"
	daxctl list -d "$DAX_NAME" -M
	echo "qemu_processes:"
	qemu_processes
	echo "device_holders:"
	device_holders
	echo "tcp_ports:"
	ss -H -lntp "( sport = :$VM0_PORT or sport = :$VM1_PORT or sport = :$VM1_CONTROL_PORT )" || true
	echo "login_sessions:"
	who || true
	if [[ -f "$STATE_FILE" ]]; then
		echo "active_state=$STATE_FILE"
		sed -n '1,20p' "$STATE_FILE"
	else
		echo "active_state=none"
	fi
}

run_preflight() {
	common_preflight
	show_status
	require_exclusive_confirmation
	echo "preflight=ok exclusive_confirmation=present"
}

record_host_state() {
	mkdir -p "$STATE_DIR"
	[[ ! -e "$STATE_FILE" ]] || die "active state already exists: $STATE_FILE"
	getfacl -p "$DAX_DEV" >"$ACL_FILE" 2>/dev/null || : >"$ACL_FILE"
	{
		printf 'recorded_utc=%q\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
		printf 'original_mode=%q\n' "$(mode)"
		printf 'original_driver=%q\n' "$(driver)"
		printf 'host_kernel=%q\n' "$(uname -r)"
		printf 'qemu_sha256=%q\n' "$(sha256sum "$QEMU" | awk '{print $1}')"
	} >"$STATE_FILE"
	daxctl list -d "$DAX_NAME" -M >"$STATE_DIR/active-dax-before.json"
}

enter_devdax() {
	need_root enter
	require_exclusive_confirmation
	common_preflight
	record_host_state
	if [[ $(mode) == system-ram ]]; then
		daxctl reconfigure-device "$DAX_NAME" --mode=devdax --force
	fi
	[[ $(mode) == devdax ]] || die "failed to enter devdax mode"
	[[ $(driver) == */device_dax ]] || die "device_dax driver is not active"
	[[ -c "$DAX_DEV" ]] || die "$DAX_DEV was not created"
	setfacl -m u:xtl:rw "$DAX_DEV"
	daxctl list -d "$DAX_NAME" -M >"$STATE_DIR/active-dax-devdax.json"
	echo "enter=ok dax_mode=devdax acl_user_xtl=rw"
}

build_zero_helper() {
	mkdir -p "$(dirname "$ZERO_BINARY")"
	if [[ ! -x "$ZERO_BINARY" || "$ZERO_SOURCE" -nt "$ZERO_BINARY" ]]; then
		gcc -O2 -Wall -Wextra -Werror -std=c11 "$ZERO_SOURCE" -o "$ZERO_BINARY"
	fi
}

zero_reserved_range() {
	need_root zero
	require_exclusive_confirmation
	common_preflight
	[[ $(mode) == devdax ]] || die "zero requires devdax mode"
	build_zero_helper
	"$ZERO_BINARY" "$DAX_DEV" 4294967296 8589934592 ZERO-CXLFORK-MR-4G-12G
}

restore_host() {
	need_root restore
	require_exclusive_confirmation
	require_idle_devices
	[[ -r "$STATE_FILE" ]] || die "no recorded host state: $STATE_FILE"
	# shellcheck source=/dev/null
	source "$STATE_FILE"
	setfacl -x u:xtl "$DAX_DEV" 2>/dev/null || true
	if [[ "$original_mode" == system-ram && $(mode) != system-ram ]]; then
		daxctl reconfigure-device "$DAX_NAME" --mode=system-ram --force
		# reconfigure-device normally onlines every block itself.  Calling
		# online-memory again returns nonzero on daxctl 77 and used to abort
		# state/ACL cleanup even though all 31 blocks were already online.
		if system_ram_has_offline_blocks; then
			daxctl online-memory "$DAX_NAME"
		fi
	elif [[ "$original_mode" != system-ram && "$original_mode" != devdax ]]; then
		die "unsupported recorded original mode: $original_mode"
	fi
	[[ $(mode) == "$original_mode" ]] || die "restore mode mismatch: $(mode) != $original_mode"
	if [[ "$original_mode" == system-ram ]]; then
		require_system_ram_removable
	fi
	mv "$STATE_FILE" "$STATE_FILE.restored.$(date -u +%Y%m%dT%H%M%SZ)"
	[[ ! -s "$ACL_FILE" ]] || setfacl --restore="$ACL_FILE"
	rm -f "$ACL_FILE"
	echo "restore=ok dax_mode=$original_mode"
}

usage() {
	echo "usage: $0 {status|preflight|enter|zero|restore}" >&2
	exit 2
}

command=${1:-}
if [[ "$command" == status ]]; then
	show_status
	exit 0
fi

mkdir -p "$(dirname "$LOCK_FILE")"
exec 9>"$LOCK_FILE"
flock -n 9 || die "another dax-admin command is active"

case "$command" in
	preflight) need_root preflight; run_preflight ;;
	enter) enter_devdax ;;
	zero) zero_reserved_range ;;
	restore) restore_host ;;
	*) usage ;;
esac
