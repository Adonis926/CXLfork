#!/usr/bin/env bash
set -Eeuo pipefail

# One controller for the six-system OpenWhisk state-action evaluation.
# Existing HPCA and CXLfork launchers remain authoritative for VM/KVM/DAX
# setup.  This file only provisions an isolated disk, drives one tuple at a
# time, validates the guest result, resumes interrupted campaigns, and calls
# the Python collector for final summaries.

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
DEFAULT_PROFILE=$ROOT/config/openwhisk-state-action-eval-103.env
[[ -r $DEFAULT_PROFILE ]] || DEFAULT_PROFILE=$SCRIPT_DIR/openwhisk-state-action-eval-103.env
PROFILE=${OWE_PROFILE:-$DEFAULT_PROFILE}
[[ -r $PROFILE ]] || { echo "missing profile: $PROFILE" >&2; exit 1; }
# shellcheck source=/dev/null
source "$PROFILE"

HPCA_DIR=/home/xtl/start/hpca
HPCA_KILL=$HPCA_DIR/kill-gvm.sh
CXLFORK_START=$ROOT/scripts/start-cxlfork-vms.sh
CXLFORK_STOP=$ROOT/scripts/stop-cxlfork-vms.sh
DAX_ADMIN=$ROOT/scripts/real-cxl-103/dax-admin.sh
PORTER=$ROOT/cxlporter
GUEST_ROOT=/root/openwhisk-state-action-eval
LOCK=/run/lock/openwhisk-state-action-eval.lock
BOOT_TIMEOUT=${OWE_BOOT_TIMEOUT:-300}
RUN_TIMEOUT=${OWE_RUN_TIMEOUT:-7200}
MAX_ATTEMPTS=${OWE_MAX_ATTEMPTS:-3}
SSH_KEY=/home/xtl/start/hpca-cxlfork/keys/id_ed25519
declare -a SYSTEMS=(cohort no-tiering starfish native-cxl native-dram cxlfork)
declare -a SELECTED_VCPUS=()
CAMPAIGN=""
CURRENT_ATTEMPT=""
OWN_RUNTIME=""

log()
{
	local line
	line="$(date -u +%FT%TZ) $*"
	printf '%s\n' "$line"
	[[ -z ${CAMPAIGN:-} || ! -d $CAMPAIGN ]] || printf '%s\n' "$line" >>"$CAMPAIGN/controller.log"
}

die()
{
	log "ERROR: $*" >&2
	exit 1
}

usage()
{
	cat <<EOF
Usage:
  $0 preflight
  sudo -E $0 provision
  sudo -E $0 run CAMPAIGN [8 16 32 64 80]
  $0 status CAMPAIGN
  $0 summarize CAMPAIGN

Internal guest entry points (do not run on the host):
  $0 guest-standard SYSTEM VCPUS REP TOKEN
  $0 guest-cxlfork VCPUS REP TOKEN

The run command is resumable.  Set OWE_EXCLUSIVE_CONFIRM=$OWE_EXCLUSIVE_TOKEN
only after reserving an exclusive KVM/DAX window.  A CAMPAIGN/STOP file pauses
the controller safely between fresh-boot tuples.
EOF
}

require_root()
{
	[[ ${EUID:-$(id -u)} -eq 0 ]] || exec sudo -E bash "$0" "$@"
}

require_exclusive()
{
	[[ ${OWE_EXCLUSIVE_CONFIRM:-} == "$OWE_EXCLUSIVE_TOKEN" ]] ||
		die "exclusive gate is locked; set OWE_EXCLUSIVE_CONFIRM=$OWE_EXCLUSIVE_TOKEN after reserving Lux"
}

sha_is()
{
	local expected=$1 path=$2 actual
	[[ -r $path ]] || die "missing asset: $path"
	actual=$(sha256sum "$path" | awk '{print $1}')
	[[ $actual == "$expected" ]] || die "SHA256 mismatch: $path ($actual)"
}

jdk_manifest()
{
	(cd "$1" && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | awk '{print $1}')
}

qemus()
{
	pgrep -af '[q]emu-system.*x86_64' || true
}

ports_busy()
{
	ss -lntH 2>/dev/null | awk '$4 ~ /:(2200|2201|2301|3233|3433|4444|4445|5555|7100)$/ {print}'
}

preflight_common()
{
	local command dax
	[[ $(hostname -s) == "$OWE_HOST" ]] || die "this profile is restricted to $OWE_HOST"
	for command in awk bash cp curl daxctl df dmesg find flock fuser grep jq losetup \
		mount mountpoint nc pgrep qemu-img qemu-nbd sha256sum sshpass ss tar timeout umount; do
		command -v "$command" >/dev/null || die "missing command: $command"
	done
	[[ -x $HPCA_KILL && -x $CXLFORK_START && -x $CXLFORK_STOP && -x $DAX_ADMIN ]] ||
		die "an authoritative launcher is missing"
	dax=$(daxctl list -d dax0.0 2>/dev/null) || die "cannot inspect dax0.0"
	grep -q '"mode":"devdax"' <<<"$dax" || die "dax0.0 is not devdax"
	[[ -z $(qemus) ]] || { qemus >&2; die "QEMU is already active"; }
	[[ -z $(ports_busy) ]] || { ports_busy >&2; die "an experiment port is occupied"; }
	if fuser /dev/dax0.0 >/dev/null 2>&1; then
		die "/dev/dax0.0 has an active holder"
	fi
	(( $(getconf _NPROCESSORS_ONLN) >= 96 )) || die "at least 96 online host CPUs are required"
}

preflight_assets()
{
	sha_is "$OWE_JAR_SHA256" "$OWE_ASSET_ROOT/openwhisk.jar"
	sha_is "$OWE_WSK_SHA256" "$OWE_ASSET_ROOT/wsk"
	[[ -x $OWE_ASSET_ROOT/jdk-11/bin/java ]] || die "missing JDK 11 asset"
	[[ $(jdk_manifest "$OWE_ASSET_ROOT/jdk-11") == "$OWE_JDK_MANIFEST_SHA256" ]] ||
		die "JDK 11 content manifest changed"
	[[ -x $PORTER/state-action-http && -x $PORTER/state-action-capsule &&
	   -x $PORTER/cxlporter-paper && -x $PORTER/cxlfork-ghost-agent ]] ||
		die "C workload binaries are not built in $PORTER"
	[[ -x $PORTER/openwhisk/scripts/state_action_benchmark.py ]] ||
		die "state-action collector is missing"
}

preflight()
{
	preflight_common
	preflight_assets
	printf 'PREFLIGHT_OK host=%s dax=devdax systems=%s vcpus=%s\n' \
		"$OWE_HOST" "${SYSTEMS[*]}" "$OWE_VCPUS"
}

make_guest_bundle()
{
	local bundle=$OWE_ROOT/staging/openwhisk-state-action-eval
	install -d -m 0755 "$OWE_ROOT/staging"
	rm -rf "$bundle"
	install -d -m 0755 "$bundle"
	cp -a "$OWE_ASSET_ROOT/jdk-11" "$bundle/jdk-11"
	install -m 0644 "$OWE_ASSET_ROOT/openwhisk.jar" "$bundle/openwhisk.jar"
	install -m 0755 "$OWE_ASSET_ROOT/wsk" "$bundle/wsk"
	install -m 0755 "$PORTER/state-action-http" "$bundle/state-action-http"
	install -m 0755 "$PORTER/state-action-capsule" "$bundle/state-action-capsule"
	install -m 0755 "$PORTER/cxlporter-paper" "$bundle/cxlporter-paper"
	install -m 0755 "$PORTER/cxlfork-ghost-agent" "$bundle/cxlfork-ghost-agent"
	install -m 0644 "$PORTER/docker/Dockerfile.state-action" "$bundle/Dockerfile.state-action"
	install -m 0644 "$PORTER/docker/Dockerfile.ghost-state-action" "$bundle/Dockerfile.ghost-state-action"
	install -m 0755 "$PORTER/openwhisk/scripts/state_action_benchmark.py" "$bundle/state_action_benchmark.py"
	install -m 0755 "$0" "$bundle/run-openwhisk-state-action-eval.sh"
	install -m 0644 "$PROFILE" "$bundle/openwhisk-state-action-eval-103.env"
	printf 'function main(args) { return {unexpected: true}; }\n' >"$bundle/cxlfork-placeholder.js"
	(
		cd "$bundle"
		find . -type f ! -name ASSET_MANIFEST.sha256 -print0 | sort -z |
			xargs -0 sha256sum >ASSET_MANIFEST.sha256
	)
}

find_free_nbd()
{
	local device
	modprobe nbd max_part=16
	for device in /dev/nbd{0..15}; do
		[[ -b $device ]] || continue
		[[ ! -s /sys/block/${device##*/}/pid ]] && { printf '%s\n' "$device"; return; }
	done
	return 1
}

install_bundle_raw()
{
	local disk=$1 bundle=$2 loop mount_dir
	mount_dir=$(mktemp -d /run/owe-raw.XXXXXX)
	loop=$(losetup --find --show -Pf "$disk")
	trap 'mountpoint -q "$mount_dir" && umount "$mount_dir" || true; losetup -d "$loop" 2>/dev/null || true; rmdir "$mount_dir" 2>/dev/null || true' RETURN
	for _ in {1..50}; do [[ -b ${loop}p1 ]] && break; sleep .1; done
	[[ -b ${loop}p1 ]] || die "raw guest partition did not appear"
	mount "${loop}p1" "$mount_dir"
	rm -rf "$mount_dir/root/openwhisk-state-action-eval"
	cp -a "$bundle" "$mount_dir/root/openwhisk-state-action-eval"
	sync
	umount "$mount_dir"
	losetup -d "$loop"
	rmdir "$mount_dir"
	trap - RETURN
}

install_bundle_qcow2()
{
	local disk=$1 bundle=$2 nbd mount_dir
	nbd=$(find_free_nbd) || die "no free nbd device"
	mount_dir=$(mktemp -d /run/owe-qcow.XXXXXX)
	qemu-nbd --connect="$nbd" "$disk"
	trap 'mountpoint -q "$mount_dir" && umount "$mount_dir" || true; qemu-nbd --disconnect "$nbd" >/dev/null 2>&1 || true; rmdir "$mount_dir" 2>/dev/null || true' RETURN
	for _ in {1..50}; do [[ -b ${nbd}p1 ]] && break; sleep .1; done
	[[ -b ${nbd}p1 ]] || die "qcow2 guest partition did not appear"
	mount "${nbd}p1" "$mount_dir"
	rm -rf "$mount_dir/root/openwhisk-state-action-eval"
	cp -a "$bundle" "$mount_dir/root/openwhisk-state-action-eval"
	sync
	umount "$mount_dir"
	qemu-nbd --disconnect "$nbd" >/dev/null
	rmdir "$mount_dir"
	trap - RETURN
}

provision()
{
	require_exclusive
	preflight_common
	preflight_assets
	install -d -m 0755 "$OWE_ROOT" "$OWE_RESULT_ROOT" "$OWE_ASSET_ROOT" \
		"$(dirname "$OWE_SSI_DISK")" "$OWE_CXL_WS/images" "$OWE_CXL_WS/cloudinit"
	make_guest_bundle
	if [[ ! -f $OWE_SSI_DISK ]]; then
		log "create isolated SSI disk from $OWE_SSI_BASE_DISK"
		cp --reflink=auto --sparse=always "$OWE_SSI_BASE_DISK" "$OWE_SSI_DISK.new"
		mv "$OWE_SSI_DISK.new" "$OWE_SSI_DISK"
	fi
	[[ $(qemu-img info --output=json "$OWE_SSI_DISK" | jq -r .format) == raw ]] ||
		die "isolated SSI disk is not raw"
	[[ $(qemu-img info --output=json "$OWE_SSI_DISK" | jq -r '.["virtual-size"]') -eq 21474836480 ]] ||
		die "isolated SSI disk is not 20 GiB"
	install_bundle_raw "$OWE_SSI_DISK" "$OWE_ROOT/staging/openwhisk-state-action-eval"

	local name base
	for name in vm0 vm1; do
		base="/home/xtl/start/hpca-cxlfork/images/paper-${name}.qcow2"
		[[ -r $base ]] || die "missing CXLfork paper base: $base"
		if [[ ! -f $OWE_CXL_WS/images/$name.qcow2 ]]; then
			qemu-img create -q -f qcow2 -F qcow2 -b "$base" "$OWE_CXL_WS/images/$name.qcow2"
		fi
		qemu-img check -q "$OWE_CXL_WS/images/$name.qcow2"
		install_bundle_qcow2 "$OWE_CXL_WS/images/$name.qcow2" \
			"$OWE_ROOT/staging/openwhisk-state-action-eval"
	done
	ln -sfn /home/xtl/start/hpca-cxlfork/cloudinit/vm0-seed-91.iso "$OWE_CXL_WS/cloudinit/vm0-seed.iso"
	ln -sfn /home/xtl/start/hpca-cxlfork/cloudinit/vm1-seed-91.iso "$OWE_CXL_WS/cloudinit/vm1-seed.iso"
	chown -R xtl:xtl "$OWE_ROOT"
	log "provision complete root=$OWE_ROOT ssi_disk=$OWE_SSI_DISK cxl_ws=$OWE_CXL_WS"
}

guest_verify_bundle()
{
	cd "$GUEST_ROOT"
	sha256sum -c --quiet ASSET_MANIFEST.sha256
	[[ $(nproc) -eq $1 ]] || { echo "guest nproc=$(nproc), expected=$1" >&2; return 1; }
}

guest_stop_openwhisk()
{
	pkill -f '[o]penwhisk-standalone.*\.jar' 2>/dev/null || true
	for _ in {1..30}; do pgrep -f '[o]penwhisk-standalone.*\.jar' >/dev/null || break; sleep 1; done
	docker ps -aq --filter name=wsk | xargs -r docker rm -f >/dev/null
	docker ps -aq --filter ancestor=state-action:eval-v1 | xargs -r docker rm -f >/dev/null
}

guest_start_openwhisk()
{
	local mode=$1 frontend=$2 target=$3 output=$4 cxl_host=${5:-127.0.0.1}
	local enabled=false start end
	[[ $mode == cxlfork ]] && enabled=true
	guest_stop_openwhisk
	install -d -m 0755 "$output"
	start=$(date +%s%N)
	CXLPORTER_ENABLED=$enabled CXLPORTER_HOST=$cxl_host CXLPORTER_PORT=$OWE_CXLPORTER_PORT \
		nohup taskset -c "$frontend" "$GUEST_ROOT/jdk-11/bin/java" \
		-Dwhisk.standalone.host.name=127.0.0.1 \
		-Dwhisk.standalone.host.ip=172.17.0.1 \
		-Dwhisk.standalone.host.internal=172.17.0.1 \
		-Dwhisk.config.limits-actions-invokes-perMinute=1000000 \
		-Dwhisk.config.limits-actions-invokes-concurrent=1000 \
		-Dwhisk.container-factory.container-args.extra-args.cpuset-cpus.0="$target" \
		-jar "$GUEST_ROOT/openwhisk.jar" --no-browser --no-ui --port "$OWE_OPENWHISK_PORT" \
		>"$output/openwhisk.log" 2>&1 &
	echo $! >"$output/openwhisk.pid"
	for _ in $(seq 1 300); do
		curl -fsS "http://127.0.0.1:$OWE_OPENWHISK_PORT/api/v1" >/dev/null 2>&1 && break
		kill -0 "$(cat "$output/openwhisk.pid")" 2>/dev/null || {
			tail -200 "$output/openwhisk.log" >&2; return 1;
		}
		sleep 1
	done
	curl -fsS "http://127.0.0.1:$OWE_OPENWHISK_PORT/api/v1" >/dev/null
	end=$(date +%s%N)
	printf '{"openwhisk_start_ns":%s,"frontend_cpus":"%s","target_cpus":"%s","mode":"%s"}\n' \
		"$((end - start))" "$frontend" "$target" "$mode" >"$output/bootstrap.json"
	"$GUEST_ROOT/wsk" property set --apihost "http://127.0.0.1:$OWE_OPENWHISK_PORT" >/dev/null
	"$GUEST_ROOT/wsk" property set --auth "$OWE_AUTH" >/dev/null
	"$GUEST_ROOT/wsk" -i action list >/dev/null
}

guest_collect()
{
	local mode=$1 system=$2 vcpus=$3 rep=$4 action=$5 scenario=$6 target=$7 output=$8
	shift 8
	"$GUEST_ROOT/state_action_benchmark.py" \
		--mode "$mode" --system "$system" --vcpus "$vcpus" --rep "$rep" \
		--action "$action" --scenario "$scenario" --target-cpus "$target" \
		--apihost "http://127.0.0.1:$OWE_OPENWHISK_PORT" --auth "$OWE_AUTH" \
		--output "$output" "$@"
}

guest_standard()
{
	local system=$1 vcpus=$2 rep=$3 token=$4 half frontend target output deploy_start deploy_end
	half=$((vcpus / 2)); frontend="0-$((half - 1))"; target="$half-$((vcpus - 1))"
	guest_verify_bundle "$vcpus"
	output=/root/openwhisk-state-action-results/$token
	rm -rf "$output"; install -d -m 0755 "$output"
	docker build --pull=false -q -f "$GUEST_ROOT/Dockerfile.state-action" \
		-t state-action:eval-v1 "$GUEST_ROOT" >"$output/docker-image-id.txt"
	guest_start_openwhisk standard "$frontend" "$target" "$output"
	deploy_start=$(date +%s%N)
	"$GUEST_ROOT/wsk" -i action update state_action_cold --docker state-action:eval-v1 \
		--memory 128 --timeout 300000 --logsize 0 --concurrency 1 \
		--annotation bench-force-cold true >/dev/null
	deploy_end=$(date +%s%N)
	printf '{"action_deploy_ns":%s}\n' "$((deploy_end - deploy_start))" >"$output/deploy.json"
	guest_collect standard-cold "$system" "$vcpus" "$rep" state_action_cold sequential "$target" \
		"$output/cold-sequential" --requests "$OWE_SEQUENTIAL_REQUESTS" --concurrency 1
	guest_collect standard-cold "$system" "$vcpus" "$rep" state_action_cold throughput "$target" \
		"$output/cold-throughput" --duration "$OWE_THROUGHPUT_SECONDS" --concurrency "$half"
	if [[ $vcpus -eq $OWE_WARM_REFERENCE_VCPU ]]; then
		"$GUEST_ROOT/wsk" -i action update state_action_warm --docker state-action:eval-v1 \
			--memory 128 --timeout 300000 --logsize 0 --concurrency 1 >/dev/null
		guest_collect standard-warm "$system" "$vcpus" "$rep" state_action_warm sequential "$target" \
			"$output/warm-sequential" --requests "$OWE_SEQUENTIAL_REQUESTS" --concurrency 1 --warmup 1
	fi
	docker inspect state-action:eval-v1 >"$output/docker-image.json"
	uname -a >"$output/uname.txt"; lscpu >"$output/lscpu.txt"; docker version >"$output/docker-version.txt"
	dmesg >"$output/guest-dmesg.txt"
	kill "$(cat "$output/openwhisk.pid")" 2>/dev/null || true
	tar -C "$(dirname "$output")" -cf "/root/$token.tar" "$token"
	echo "guest_standard_complete token=$token system=$system vcpus=$vcpus rep=$rep"
}

guest_cxlfork()
{
	local vcpus=$1 rep=$2 token=$3 target output deploy_start deploy_end
	target="0-$((vcpus / 2 - 1))"
	guest_verify_bundle "$((vcpus / 2))"
	output=/root/openwhisk-state-action-results/$token
	rm -rf "$output"; install -d -m 0755 "$output"
	guest_start_openwhisk cxlfork "$target" "$target" "$output" 192.168.250.2
	deploy_start=$(date +%s%N)
	"$GUEST_ROOT/wsk" -i action update state_action_cxlfork "$GUEST_ROOT/cxlfork-placeholder.js" \
		--kind nodejs:20 --memory 128 --timeout 300000 --logsize 0 --concurrency 1 \
		--annotation cxlfork true --annotation cxlfork-owner paper \
		--annotation cxlfork-function state-action --annotation cxlfork-version v1 >/dev/null
	deploy_end=$(date +%s%N)
	printf '{"action_deploy_ns":%s}\n' "$((deploy_end - deploy_start))" >"$output/deploy.json"
	guest_collect cxlfork cxlfork "$vcpus" "$rep" state_action_cxlfork sequential "$target" \
		"$output/cold-sequential" --requests "$OWE_SEQUENTIAL_REQUESTS" --concurrency 1
	guest_collect cxlfork cxlfork "$vcpus" "$rep" state_action_cxlfork throughput "$target" \
		"$output/cold-throughput" --duration "$OWE_THROUGHPUT_SECONDS" --concurrency "$((vcpus / 2))"
	uname -a >"$output/uname.txt"; lscpu >"$output/lscpu.txt"; dmesg >"$output/guest-dmesg.txt"
	kill "$(cat "$output/openwhisk.pid")" 2>/dev/null || true
	tar -C "$(dirname "$output")" -cf "/root/$token.tar" "$token"
	chmod 0644 "/root/$token.tar"
	echo "guest_cxlfork_complete token=$token vcpus=$vcpus rep=$rep"
}

launcher_for()
{
	case $1 in
		cohort) echo "$HPCA_DIR/start-cohort.sh" ;;
		no-tiering) echo "$HPCA_DIR/start-no-memory-tiering.sh" ;;
		starfish) echo "$HPCA_DIR/start-starfish-like.sh" ;;
		native-cxl) echo "$HPCA_DIR/start-native-cxl-vm.sh" ;;
		native-dram) echo "$HPCA_DIR/start-native-vm.sh" ;;
		*) return 2 ;;
	esac
}

serial_for()
{
	case $1 in
		cohort) echo /run/gvm-hpca/cohort-master-serial.log ;;
		no-tiering) echo /run/gvm-hpca/no-memory-tiering-master-serial.log ;;
		starfish) echo /run/gvm-hpca/starfish-like-master-serial.log ;;
		native-cxl) echo /run/gvm-hpca/native-cxl-serial.log ;;
		native-dram) echo /run/gvm-hpca/native-dram-serial.log ;;
	esac
}

launch_ssi()
{
	local system=$1 vcpus=$2 launcher half
	launcher=$(launcher_for "$system"); half=$((vcpus / 2))
	case $system in
		cohort|no-tiering|starfish)
			env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
				HOME=/root USER=root LOGNAME=root LANG=C.UTF-8 TERM=dumb \
				BOOT_TIMEOUT="$BOOT_TIMEOUT" DISK_PATH="$OWE_SSI_DISK" \
				GUEST_CPUS="$vcpus" LOCAL_CPUS="$half" MASTER_START=0 SLAVE_START="$half" \
				GUEST_MEM="$OWE_GVM_LOCAL_MEMORY" "$launcher" "$vcpus" "$OWE_GVM_LOCAL_MEMORY"
			;;
		native-cxl|native-dram)
			env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
				HOME=/root USER=root LOGNAME=root LANG=C.UTF-8 TERM=dumb \
				BOOT_TIMEOUT="$BOOT_TIMEOUT" DISK_PATH="$OWE_SSI_DISK" \
				"$launcher" "$vcpus" "$OWE_NATIVE_MEMORY"
			;;
	esac
}

copy_raw_guest_file()
{
	local guest_file=$1 destination=$2 loop mount_dir
	mount_dir=$(mktemp -d /run/owe-read.XXXXXX)
	loop=$(losetup -r --find --show -Pf "$OWE_SSI_DISK")
	trap 'mountpoint -q "$mount_dir" && umount "$mount_dir" || true; losetup -d "$loop" 2>/dev/null || true; rmdir "$mount_dir" 2>/dev/null || true' RETURN
	for _ in {1..50}; do [[ -b ${loop}p1 ]] && break; sleep .1; done
	mount -o ro,noload "${loop}p1" "$mount_dir"
	[[ -f $mount_dir/root/$guest_file ]] || return 1
	cp "$mount_dir/root/$guest_file" "$destination"
	umount "$mount_dir"; losetup -d "$loop"; rmdir "$mount_dir"; trap - RETURN
}

wait_marker()
{
	local serial=$1 marker=$2
	for _ in $(seq 1 "$RUN_TIMEOUT"); do
		[[ -f $serial ]] && tr '\r' '\n' <"$serial" | grep -q "${marker}_RC_[0-9]" && return
		sleep 1
	done
	return 1
}

copy_runtime_logs()
{
	local attempt=$1
	[[ ! -d /run/gvm-hpca ]] || cp -a /run/gvm-hpca "$attempt/runtime"
}

cleanup_runtime()
{
	local attempt=${1:-$CURRENT_ATTEMPT}
	case $OWN_RUNTIME in
		ssi)
			[[ -z $attempt ]] || copy_runtime_logs "$attempt" || true
			$HPCA_KILL >"${attempt:-/tmp}/teardown.log" 2>&1 || return
			;;
		cxl)
			env WS="$OWE_CXL_WS" "$CXLFORK_STOP" cxl >"${attempt:-/tmp}/teardown.log" 2>&1 || true
			modprobe -r kvm_intel kvm >>"${attempt:-/tmp}/teardown.log" 2>&1 || return
			;;
	esac
	OWN_RUNTIME=""
}

on_signal()
{
	local rc=$1
	trap - EXIT INT TERM
	[[ -z $OWN_RUNTIME ]] || cleanup_runtime "$CURRENT_ATTEMPT" || true
	exit "$rc"
}

on_exit()
{
	local rc=$?
	trap - EXIT INT TERM
	[[ -z $OWN_RUNTIME ]] || cleanup_runtime "$CURRENT_ATTEMPT" || true
	exit "$rc"
}

trap on_exit EXIT
trap 'on_signal 130' INT
trap 'on_signal 143' TERM

validate_result_tar()
{
	local tarfile=$1 attempt=$2 token=$3 expected=2 file
	tar -tf "$tarfile" | grep -q "^$token/"
	mkdir -p "$attempt/result"
	tar -xf "$tarfile" -C "$attempt/result"
	[[ -s $attempt/result/$token/cold-sequential/summary.json ]]
	[[ -s $attempt/result/$token/cold-throughput/summary.json ]]
	for file in "$attempt/result/$token"/*/summary.json; do
		jq -e '.set_valid == true and .samples == .successes and .successes > 0' "$file" >/dev/null
	done
	[[ $(jq -r .expected_checksum "$attempt/result/$token/cold-sequential/summary.json") == "$OWE_STATE_CHECKSUM" ]]
	if [[ $(jq -r .vcpus "$attempt/result/$token/cold-sequential/summary.json") -eq $OWE_WARM_REFERENCE_VCPU &&
	      $(jq -r .system "$attempt/result/$token/cold-sequential/summary.json") != cxlfork ]]; then
		expected=3
		[[ -s $attempt/result/$token/warm-sequential/summary.json ]]
	fi
	[[ $(find "$attempt/result/$token" -mindepth 2 -maxdepth 2 -name summary.json | wc -l) -eq $expected ]]
}

snapshot_dmesg()
{
	dmesg --level=err,crit,alert,emerg --notime 2>/dev/null || true
}

run_ssi_attempt()
{
	local system=$1 vcpus=$2 rep=$3 attempt=$4 token=$5 serial marker fifo nc_pid rc=125
	CURRENT_ATTEMPT=$attempt; mkdir -p "$attempt"; snapshot_dmesg >"$attempt/dmesg-before.txt"
	OWN_RUNTIME=ssi
	if ! launch_ssi "$system" "$vcpus" >"$attempt/launch.log" 2>&1 ||
	   ! grep -q '^boot=login$' "$attempt/launch.log"; then
		cleanup_runtime "$attempt" || return 90
		return 1
	fi
	serial=$(serial_for "$system"); sleep 20; marker="__OWE_DONE_${token}"
	fifo=$attempt/serial.fifo; mkfifo "$fifo"
	timeout $((RUN_TIMEOUT + 60)) nc -t -w $((RUN_TIMEOUT + 30)) 127.0.0.1 5555 \
		<"$fifo" >"$attempt/serial-session.log" 2>&1 &
	nc_pid=$!; exec 3>"$fifo"; printf '\r' >&3
	printf 'env OWE_SEQUENTIAL_REQUESTS=%q OWE_THROUGHPUT_SECONDS=%q bash %q guest-standard %q %q %q %q > /root/%q.log 2>&1; rc=$?; sync; echo %s_RC_${rc}__; systemctl poweroff\r' \
		"$OWE_SEQUENTIAL_REQUESTS" "$OWE_THROUGHPUT_SECONDS" \
		"$GUEST_ROOT/run-openwhisk-state-action-eval.sh" "$system" "$vcpus" "$rep" "$token" \
		"$token" "$marker" >&3
	if wait_marker "$serial" "$marker"; then
		rc=$(tr '\r' '\n' <"$serial" | sed -n -E "s/.*${marker}_RC_([0-9]+)__.*/\\1/p" | tail -1)
	fi
	exec 3>&-; kill "$nc_pid" 2>/dev/null || true; wait "$nc_pid" 2>/dev/null || true
	rm -f "$fifo"; sleep 5
	cleanup_runtime "$attempt" || return 90
	snapshot_dmesg >"$attempt/dmesg-after.txt"
	[[ $rc == 0 ]] || return 1
	copy_raw_guest_file "$token.tar" "$attempt/result.tar" || return 1
	copy_raw_guest_file "$token.log" "$attempt/guest-controller.log" || true
	validate_result_tar "$attempt/result.tar" "$attempt" "$token"
}

ssh_guest()
{
	local port=$1; shift
	sshpass -p "$OWE_GUEST_PASSWORD" ssh -i "$SSH_KEY" \
		-o BatchMode=no -o PreferredAuthentications=publickey,password \
		-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
		-o ConnectTimeout=5 -p "$port" ubuntu@127.0.0.1 "$@"
}

wait_ssh()
{
	local port=$1
	for _ in {1..180}; do ssh_guest "$port" true >/dev/null 2>&1 && return; sleep 1; done
	return 1
}

cxl_sudo()
{
	local port=$1 command=$2 quoted
	printf -v quoted '%q' "$command"
	ssh_guest "$port" "sudo bash -lc $quoted"
}

run_cxl_attempt()
{
	local vcpus=$1 rep=$2 attempt=$3 token=$4 half key cpu0 cpu1 rc=0
	half=$((vcpus / 2))
	CURRENT_ATTEMPT=$attempt; mkdir -p "$attempt"; snapshot_dmesg >"$attempt/dmesg-before.txt"
	key=$((103000000 + vcpus * 100 + rep)); cpu0="48-$((47 + half))"; cpu1="$((48 + half))-$((47 + vcpus))"
	/home/xtl/start/hpca/load-native-kvm.sh >"$attempt/kvm-load.log" 2>&1
	OWN_RUNTIME=cxl
	env PROFILE="$OWE_REAL_CXL_PROFILE" RUNTIME_ROOT=/home/xtl/start/hpca-cxlfork \
		CXLFORK_EXCLUSIVE_CONFIRM="$OWE_EXCLUSIVE_TOKEN" "$DAX_ADMIN" zero >"$attempt/dax-zero.log" 2>&1
	env WS="$OWE_CXL_WS" QEMU=/home/xtl/qemu-9.0.90-clean/build/qemu-system-x86_64 \
		MACHINE='pc-q35-8.2,kernel-irqchip=split,mem-merge=off' GUEST_APPEND_EXTRA=nox2apic \
		KERNEL=/home/xtl/start/hpca-cxlfork/kernels/bzImage-6.6.32-cxlfork-91 \
		CXL_FILE=/dev/dax0.0 CXL_BACKEND_OFFSET=4G CXL_BACKEND_SIZE=4G CXL_BACKEND_ALIGN=2M \
		CXL_PHYS=0x484000000 CXL_SIZE=0xfb000000 HYDRA_SHM_FILE=/dev/dax0.0 \
		HYDRA_SHM_SIZE=12G HYDRA_BACKEND_OFFSET=8G HYDRA_ENDPOINT_SIZE=2G \
		HYDRA_ENDPOINT1_OFFSET=2G HYDRA_BACKEND_ALIGN=2M BACKEND_RESET=none \
		MEM="$OWE_CXL_VM_MEMORY" SMP="$half" VM0_HOST_CPUS="$cpu0" VM1_HOST_CPUS="$cpu1" \
		VM_MEMORY_NODE=1 HYDRA0_PCI_ADDR=0x2 HYDRA1_PCI_ADDR=0x3 \
		VM0_PORT="$OWE_VM0_PORT" VM1_PORT="$OWE_VM1_PORT" VM1_CONTROL_PORT=2301 \
		"$CXLFORK_START" cxl >"$attempt/launch.log" 2>&1 || rc=$?
	((rc == 0)) && wait_ssh "$OWE_VM0_PORT" && wait_ssh "$OWE_VM1_PORT" || {
		cleanup_runtime "$attempt" || return 90; return 1;
	}
	# Configure the private VM0<->VM1 link and a cpuset-bound target ghost.
	cxl_sudo "$OWE_VM0_PORT" 'ip addr flush dev eth1; ip addr add 192.168.250.1/24 dev eth1; ip link set eth1 up' || rc=$?
	cxl_sudo "$OWE_VM1_PORT" 'ip addr flush dev eth1; ip addr add 192.168.250.2/24 dev eth1; ip link set eth1 up' || rc=$?
	if ((rc == 0)); then
		cxl_sudo "$OWE_VM1_PORT" "set -e; pkill -f '[c]xlporter-paper daemon' || true; docker rm -f cxlfork-state-action >/dev/null 2>&1 || true; rm -rf /run/cxlfork-state-action; install -d -m 0777 /run/cxlfork-state-action; cd $GUEST_ROOT; docker build --pull=false -q -f Dockerfile.ghost-state-action -t cxlfork-ghost:state-action-v1 .; docker run -d --name cxlfork-state-action --network none --cpuset-cpus 0-$((half - 1)) --device /dev/cxlfork:/dev/cxlfork -e CXLPORTER_GHOST_WORKERS=$half -v /run/cxlfork-state-action:/run/cxlfork cxlfork-ghost:state-action-v1; for i in \$(seq 1 60); do test -S /run/cxlfork-state-action/ghost.sock && break; sleep 1; done; test -S /run/cxlfork-state-action/ghost.sock; nohup taskset -c 0-$((half - 1)) $GUEST_ROOT/cxlporter-paper daemon 192.168.250.2 $OWE_CXLPORTER_PORT /run/cxlfork-state-action/ghost.sock >/tmp/cxlporter-state-action.log 2>&1 & echo \$! >/tmp/cxlporter-state-action.pid; for i in \$(seq 1 60); do ss -lnt 'sport = :$OWE_CXLPORTER_PORT' | grep -q LISTEN && break; sleep 1; done; ss -lnt 'sport = :$OWE_CXLPORTER_PORT' | grep LISTEN" || rc=$?
	fi
	if ((rc == 0)); then
		cxl_sudo "$OWE_VM0_PORT" "$GUEST_ROOT/state-action-capsule prepare $key && $GUEST_ROOT/state-action-capsule catalog-register $key" >"$attempt/prepare.log" 2>&1 || rc=$?
	fi
	if ((rc == 0)); then
		ssh_guest "$OWE_VM0_PORT" "sudo env OWE_SEQUENTIAL_REQUESTS=$OWE_SEQUENTIAL_REQUESTS OWE_THROUGHPUT_SECONDS=$OWE_THROUGHPUT_SECONDS bash $GUEST_ROOT/run-openwhisk-state-action-eval.sh guest-cxlfork $vcpus $rep $token" >"$attempt/guest-controller.log" 2>&1 || rc=$?
	fi
	if ((rc == 0)); then
		ssh_guest "$OWE_VM0_PORT" "sudo cat /root/$token.tar" >"$attempt/result.tar" || rc=$?
	fi
	cxl_sudo "$OWE_VM0_PORT" "$GUEST_ROOT/state-action-capsule catalog-lookup $key" >"$attempt/catalog-after.log" 2>&1 || rc=1
	cxl_sudo "$OWE_VM0_PORT" "dmesg" >"$attempt/vm0-dmesg.txt" || true
	cxl_sudo "$OWE_VM1_PORT" "dmesg; echo ===GHOST===; docker logs cxlfork-state-action; echo ===PORTER===; cat /tmp/cxlporter-state-action.log" >"$attempt/vm1-dmesg-and-services.txt" || true
	cxl_sudo "$OWE_VM0_PORT" "$GUEST_ROOT/state-action-capsule catalog-evict $key && $GUEST_ROOT/state-action-capsule release $key" >"$attempt/release.log" 2>&1 || rc=1
	ssh_guest "$OWE_VM0_PORT" 'sudo systemctl poweroff' >/dev/null 2>&1 || true
	ssh_guest "$OWE_VM1_PORT" 'sudo systemctl poweroff' >/dev/null 2>&1 || true
	for _ in {1..90}; do
		[[ ! -f $OWE_CXL_WS/pids/vm0.pid || ! -d /proc/$(cat "$OWE_CXL_WS/pids/vm0.pid" 2>/dev/null) ]] &&
		[[ ! -f $OWE_CXL_WS/pids/vm1.pid || ! -d /proc/$(cat "$OWE_CXL_WS/pids/vm1.pid" 2>/dev/null) ]] && break
		sleep 1
	done
	cleanup_runtime "$attempt" || return 90
	snapshot_dmesg >"$attempt/dmesg-after.txt"
	((rc == 0)) || return 1
	validate_result_tar "$attempt/result.tar" "$attempt" "$token"
	! grep -E 'BUG:|WARNING:|Oops:|general protection fault|cxlfork.*(fail|error)' \
		"$attempt/vm0-dmesg.txt" "$attempt/vm1-dmesg-and-services.txt" >"$attempt/guest-dmesg-errors.txt"
}

ok_path()
{
	printf '%s/state/ok/v%03d_%s_r%s.ok\n' "$CAMPAIGN" "$1" "$2" "$3"
}

record_ok()
{
	local path=$1 attempt=$2 token=$3 vcpus=$4 system=$5 rep=$6 tmp accepted
	tmp=$path.tmp.$$
	accepted="$CAMPAIGN/accepted/$(printf '%03d' "$vcpus")/$system/rep-$rep"
	rm -rf "$accepted"
	mkdir -p "$(dirname "$accepted")"
	cp -a "$attempt/result/$token" "$accepted"
	{
		printf 'result=ok\nresult_sha256=%s\n' "$(sha256sum "$attempt/result.tar" | awk '{print $1}')"
		printf 'attempt=%s\ntoken=%s\n' "${attempt##*-}" "$token"
		printf 'finished_utc=%s\n' "$(date -u +%FT%TZ)"
	} >"$tmp"
	mv "$tmp" "$path"
}

ok_valid()
{
	local path=$1 vcpus=$2 system=$3 rep=$4 attempt_no token tarfile sha
	[[ -s $path ]] || return 1
	attempt_no=$(sed -n 's/^attempt=//p' "$path"); token=$(sed -n 's/^token=//p' "$path")
	[[ $attempt_no =~ ^[1-9][0-9]*$ && -n $token ]] || return 1
	tarfile="$CAMPAIGN/runs/$(printf '%03d' "$vcpus")/$system/rep-$rep/attempt-$attempt_no/result.tar"
	sha=$(sed -n 's/^result_sha256=//p' "$path")
	[[ -f $tarfile && $(sha256sum "$tarfile" | awk '{print $1}') == "$sha" ]]
}

create_campaign()
{
	install -d -m 0755 "$CAMPAIGN"/{manifest,runs,state/ok,accepted}
	: >"$CAMPAIGN/controller.log"
	printf '%s\n' "${SELECTED_VCPUS[@]}" >"$CAMPAIGN/manifest/vcpu-order.txt"
	printf '%s\n' "${SYSTEMS[@]}" >"$CAMPAIGN/manifest/system-order.txt"
	install -m 0755 "$0" "$CAMPAIGN/manifest/run-openwhisk-state-action-eval.sh"
	install -m 0644 "$PROFILE" "$CAMPAIGN/manifest/profile.env"
	{
		printf 'created_utc=%s\nreps=%s\nsequential_requests=%s\nthroughput_seconds=%s\n' \
			"$(date -u +%FT%TZ)" "$OWE_REPS" "$OWE_SEQUENTIAL_REQUESTS" "$OWE_THROUGHPUT_SECONDS"
		printf 'gvm_local_memory=%s\nnative_memory=%s\ncxlfork_vm_memory=%s\n' \
			"$OWE_GVM_LOCAL_MEMORY" "$OWE_NATIVE_MEMORY" "$OWE_CXL_VM_MEMORY"
		printf 'jar_sha256=%s\nwsk_sha256=%s\nworkload=%s\nstate_checksum=%s\n' \
			"$OWE_JAR_SHA256" "$OWE_WSK_SHA256" "$OWE_WORKLOAD" "$OWE_STATE_CHECKSUM"
		uname -a
		lscpu
		daxctl list -d dax0.0
	} >"$CAMPAIGN/manifest/environment.txt"
	(cd "$CAMPAIGN/manifest" && sha256sum run-openwhisk-state-action-eval.sh profile.env >frozen.sha256)
}

verify_campaign()
{
	local frozen requested
	(cd "$CAMPAIGN/manifest" && sha256sum -c --quiet frozen.sha256) || die "campaign snapshot is corrupt"
	cmp -s "$0" "$CAMPAIGN/manifest/run-openwhisk-state-action-eval.sh" ||
		die "current runner differs from the campaign's frozen runner"
	cmp -s "$PROFILE" "$CAMPAIGN/manifest/profile.env" ||
		die "current profile differs from the campaign's frozen profile"
	grep -qx "reps=$OWE_REPS" "$CAMPAIGN/manifest/environment.txt" ||
		die "OWE_REPS differs from the frozen campaign"
	grep -qx "sequential_requests=$OWE_SEQUENTIAL_REQUESTS" "$CAMPAIGN/manifest/environment.txt" ||
		die "OWE_SEQUENTIAL_REQUESTS differs from the frozen campaign"
	grep -qx "throughput_seconds=$OWE_THROUGHPUT_SECONDS" "$CAMPAIGN/manifest/environment.txt" ||
		die "OWE_THROUGHPUT_SECONDS differs from the frozen campaign"
	frozen=$(cat "$CAMPAIGN/manifest/vcpu-order.txt"); requested=$(printf '%s\n' "${SELECTED_VCPUS[@]}")
	[[ $frozen == "$requested" ]] || die "requested vCPU order differs from frozen campaign"
}

run_tuple()
{
	local vcpus=$1 system=$2 rep=$3 base ok attempts attempt token rc
	ok=$(ok_path "$vcpus" "$system" "$rep")
	ok_valid "$ok" "$vcpus" "$system" "$rep" && { log "SKIP vcpu=$vcpus system=$system rep=$rep"; return; }
	base="$CAMPAIGN/runs/$(printf '%03d' "$vcpus")/$system/rep-$rep"; mkdir -p "$base"
	attempts=$(find "$base" -mindepth 1 -maxdepth 1 -type d -name 'attempt-*' | wc -l)
	while ((attempts < MAX_ATTEMPTS)); do
		attempts=$((attempts + 1)); attempt="$base/attempt-$attempts"; token="owe-v${vcpus}-${system}-r${rep}-a${attempts}"
		log "START vcpu=$vcpus system=$system rep=$rep attempt=$attempts"
		if [[ $system == cxlfork ]]; then
			run_cxl_attempt "$vcpus" "$rep" "$attempt" "$token" && rc=0 || rc=$?
		else
			run_ssi_attempt "$system" "$vcpus" "$rep" "$attempt" "$token" && rc=0 || rc=$?
		fi
		if ((rc == 0)); then
			record_ok "$ok" "$attempt" "$token" "$vcpus" "$system" "$rep"
			log "PASS vcpu=$vcpus system=$system rep=$rep"; return
		fi
		((rc != 90)) || die "cleanup failed; refusing to continue"
		log "RETRY vcpu=$vcpus system=$system rep=$rep attempt=$attempts rc=$rc"
	done
	die "tuple exhausted $MAX_ATTEMPTS attempts: vcpu=$vcpus system=$system rep=$rep"
}

set_vcpus()
{
	local value allowed
	SELECTED_VCPUS=()
	if (($# == 0)); then read -r -a SELECTED_VCPUS <<<"$OWE_VCPUS"; return; fi
	for value in "$@"; do
		allowed=0; for candidate in $OWE_VCPUS; do [[ $value == "$candidate" ]] && allowed=1; done
		((allowed)) || die "unsupported vCPU count: $value"
		[[ " ${SELECTED_VCPUS[*]} " != *" $value "* ]] || die "duplicate vCPU count: $value"
		SELECTED_VCPUS+=("$value")
	done
}

run_campaign()
{
	require_exclusive; preflight
	CAMPAIGN=$(realpath -m "$1"); shift; set_vcpus "$@"
	[[ $CAMPAIGN == "$OWE_RESULT_ROOT"/* ]] || die "campaign must be below $OWE_RESULT_ROOT"
	if [[ -e $CAMPAIGN ]]; then verify_campaign; else create_campaign; fi
	exec 9>"$LOCK"; flock -n 9 || die "another OpenWhisk evaluation holds $LOCK"
	local vcpus rep offset index system
	for vcpus in "${SELECTED_VCPUS[@]}"; do
		for ((rep = 1; rep <= OWE_REPS; rep++)); do
			for ((offset = 0; offset < ${#SYSTEMS[@]}; offset++)); do
				[[ ! -e $CAMPAIGN/STOP ]] || { log "STOP requested"; summarize_campaign; return; }
				index=$(((rep - 1 + offset) % ${#SYSTEMS[@]})); system=${SYSTEMS[$index]}
				preflight_common
				run_tuple "$vcpus" "$system" "$rep"
			done
		done
	done
	summarize_campaign
	log "COMPLETE campaign=$CAMPAIGN"
}

summarize_campaign()
{
	local collector=$PORTER/openwhisk/scripts/state_action_benchmark.py
	[[ -d $CAMPAIGN ]] || die "campaign does not exist: $CAMPAIGN"
	"$collector" summarize "$CAMPAIGN/accepted" --output "$CAMPAIGN/summary"
	(
		cd "$CAMPAIGN"
		find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum >SHA256SUMS
	)
}

status_campaign()
{
	local total expected
	CAMPAIGN=$1; [[ -d $CAMPAIGN ]] || die "campaign not found"
	total=$(find "$CAMPAIGN/state/ok" -type f -name '*.ok' 2>/dev/null | wc -l)
	expected=$(( $(wc -l <"$CAMPAIGN/manifest/vcpu-order.txt") * ${#SYSTEMS[@]} * OWE_REPS ))
	printf 'campaign=%s valid_tuples=%s expected_tuples=%s\n' "$CAMPAIGN" "$total" "$expected"
	find "$CAMPAIGN/state/ok" -type f -name '*.ok' -printf '%f\n' 2>/dev/null | sort
}

main()
{
	case ${1:-} in
		preflight) shift; (($# == 0)) || { usage; return 2; }; preflight ;;
		provision) require_root "$@"; shift; provision "$@" ;;
		run) require_root "$@"; shift; (($# >= 1)) || { usage; return 2; }; local campaign=$1; shift; run_campaign "$campaign" "$@" ;;
		status) shift; (($# == 1)) || { usage; return 2; }; status_campaign "$1" ;;
		summarize) shift; (($# == 1)) || { usage; return 2; }; CAMPAIGN=$1; summarize_campaign ;;
		guest-standard) shift; (($# == 4)) || { usage; return 2; }; guest_standard "$@" ;;
		guest-cxlfork) shift; (($# == 3)) || { usage; return 2; }; guest_cxlfork "$@" ;;
		*) usage; return 2 ;;
	esac
}

main "$@"
