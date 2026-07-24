#!/usr/bin/env bash
set -euo pipefail

WS=${WS:-/home/xtl/cxlfork/cxlfork-repro}
QEMU=${QEMU:-qemu-system-x86_64}
KERNEL=${KERNEL:-$WS/kernel/build-6.6.32/arch/x86/boot/bzImage}
PAPER_VM0=${PAPER_VM0:-$WS/images/paper-vm0.qcow2}
PAPER_VM1=${PAPER_VM1:-$WS/images/paper-vm1.qcow2}
CXL_FILE=${CXL_FILE:-/dev/shm/cxlfork_paper_mem}
CXL_BACKEND_SIZE=${CXL_BACKEND_SIZE:-16G}
CXL_PHYS=${CXL_PHYS:-0x484000000}
CXL_SIZE=${CXL_SIZE:-0x3fb000000}
BACKEND_RESET=${BACKEND_RESET:-auto}
MEM=${MEM:-16G}
SMP=${SMP:-16}
VM0_PORT=${VM0_PORT:-2400}
VM1_PORT=${VM1_PORT:-2401}
CONTROL_HOST=${CONTROL_HOST:-172.17.0.1}
CONTROL_PORT=${CONTROL_PORT:-2501}
GUEST_CONTROL_PORT=${GUEST_CONTROL_PORT:-7100}

mkdir -p "$WS/logs" "$WS/pids" "$WS/sockets"

pid_alive() {
	[[ -f "$1" ]] && kill -0 "$(cat "$1")" 2>/dev/null
}

port_busy() {
	ss -lnt "sport = :$1" | tail -n +2 | grep -q .
}

require_free_port() {
	if port_busy "$2"; then
		echo "$1 port $2 is already in use" >&2
		exit 1
	fi
}

reset_backend() {
	if pid_alive "$WS/pids/paper-vm0.pid" ||
	   pid_alive "$WS/pids/paper-vm1.pid"; then
		return
	fi
	case "$BACKEND_RESET" in
	auto)
		if [[ -e "$CXL_FILE" && ! -f "$CXL_FILE" ]]; then
			echo "refusing to reset non-regular backend: $CXL_FILE" >&2
			exit 1
		fi
		rm -f "$CXL_FILE"
		truncate -s "$CXL_BACKEND_SIZE" "$CXL_FILE"
		;;
	none)
		[[ -e "$CXL_FILE" ]] || {
			echo "missing backend with BACKEND_RESET=none: $CXL_FILE" >&2
			exit 1
		}
		;;
	*)
		echo "BACKEND_RESET must be auto or none" >&2
		exit 2
		;;
	esac
}

start_one() {
	local name=$1
	local image=$2
	local seed=$3
	local ssh_port=$4
	local mac=$5
	local pidfile=$WS/pids/$name.pid
	local netdev

	if pid_alive "$pidfile"; then
		echo "$name already running pid=$(cat "$pidfile")"
		return
	fi
	[[ -f "$image" ]] || {
		echo "missing paper image: $image" >&2
		exit 1
	}
	[[ -f "$seed" ]] || {
		echo "missing cloud-init seed: $seed" >&2
		exit 1
	}
	require_free_port "$name ssh" "$ssh_port"
	netdev="user,id=mgmt,hostfwd=tcp::$ssh_port-:22"
	if [[ "$name" == paper-vm1 ]]; then
		require_free_port "$name control" "$CONTROL_PORT"
		netdev+=",hostfwd=tcp:$CONTROL_HOST:$CONTROL_PORT-:$GUEST_CONTROL_PORT"
	fi

	"$QEMU" \
		-name "$name" \
		-machine q35,accel=kvm,nvdimm=on \
		-cpu host \
		-smp "$SMP",sockets=1,cores="$SMP",threads=1 \
		-m "$MEM",slots=1,maxmem=32G \
		-object memory-backend-file,id=cxlmem,share=on,mem-path="$CXL_FILE",size="$CXL_BACKEND_SIZE" \
		-device nvdimm,id=cxldev,memdev=cxlmem,label-size=16M \
		-drive file="$image",if=virtio,cache=writeback,format=qcow2 \
		-drive file="$seed",media=cdrom,if=virtio,format=raw,readonly=on \
		-kernel "$KERNEL" \
		-append "root=/dev/vda1 rw console=ttyS0 earlyprintk=ttyS0 nokaslr net.ifnames=0 cxlfork.cxl_phys=$CXL_PHYS cxlfork.cxl_size=$CXL_SIZE" \
		-netdev "$netdev" \
		-device virtio-net-pci,netdev=mgmt,mac="$mac" \
		-serial file:"$WS/logs/$name-console.log" \
		-monitor unix:"$WS/sockets/$name-monitor.sock",server,nowait \
		-pidfile "$pidfile" \
		-display none \
		-daemonize
	echo "started $name pid=$(cat "$pidfile") ssh=localhost:$ssh_port"
}

[[ -f "$KERNEL" ]] || {
	echo "missing kernel: $KERNEL" >&2
	exit 1
}
reset_backend
case "${1:-all}" in
all)
	start_one paper-vm0 "$PAPER_VM0" "$WS/cloudinit/vm0-seed.iso" \
		"$VM0_PORT" 52:54:00:22:00:01
	start_one paper-vm1 "$PAPER_VM1" "$WS/cloudinit/vm1-seed.iso" \
		"$VM1_PORT" 52:54:00:22:00:02
	;;
vm0)
	start_one paper-vm0 "$PAPER_VM0" "$WS/cloudinit/vm0-seed.iso" \
		"$VM0_PORT" 52:54:00:22:00:01
	;;
vm1)
	start_one paper-vm1 "$PAPER_VM1" "$WS/cloudinit/vm1-seed.iso" \
		"$VM1_PORT" 52:54:00:22:00:02
	;;
*)
	echo "usage: $0 [all|vm0|vm1]" >&2
	exit 2
	;;
esac
