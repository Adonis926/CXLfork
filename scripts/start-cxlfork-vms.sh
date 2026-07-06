#!/usr/bin/env bash
set -euo pipefail

WS=${WS:-/home/xtl/cxlfork-ws}
QEMU=${QEMU:-qemu-system-x86_64}
KERNEL=${KERNEL:-$WS/kernel/build-6.6.32/arch/x86/boot/bzImage}
CXL_FILE=${CXL_FILE:-/dev/shm/cxl_mem}
CXL_BACKEND_SIZE=${CXL_BACKEND_SIZE:-4G}
CXL_PHYS=${CXL_PHYS:-0x484000000}
CXL_SIZE=${CXL_SIZE:-0xfb000000}
MEM=${MEM:-16G}
SMP=${SMP:-16}

mkdir -p "$WS/logs" "$WS/pids" "$WS/sockets"

require_file() {
	local path=$1
	if [[ ! -e "$path" ]]; then
		echo "missing required file: $path" >&2
		exit 1
	fi
}

pid_alive() {
	local pidfile=$1
	[[ -f "$pidfile" ]] && kill -0 "$(cat "$pidfile")" 2>/dev/null
}

ensure_cxl_file() {
	if pid_alive "$WS/pids/vm0.pid" || pid_alive "$WS/pids/vm1.pid"; then
		return
	fi
	truncate -s "$CXL_BACKEND_SIZE" "$CXL_FILE"
}

start_vm0() {
	local pidfile=$WS/pids/vm0.pid
	if pid_alive "$pidfile"; then
		echo "vm0 already running pid=$(cat "$pidfile")"
		return
	fi
	require_file "$WS/images/vm0.qcow2"
	require_file "$WS/cloudinit/vm0-seed.iso"
	ensure_cxl_file
	"$QEMU" \
		-name vm0 \
		-machine q35,accel=kvm,nvdimm=on \
		-cpu host \
		-smp "$SMP",sockets=1,cores="$SMP",threads=1 \
		-m "$MEM",slots=1,maxmem=20G \
		-object memory-backend-file,id=cxlmem,share=on,mem-path="$CXL_FILE",size="$CXL_BACKEND_SIZE" \
		-device nvdimm,id=cxldev,memdev=cxlmem,label-size=16M \
		-drive file="$WS/images/vm0.qcow2",if=virtio,cache=writeback,format=qcow2 \
		-drive file="$WS/cloudinit/vm0-seed.iso",media=cdrom,if=virtio,format=raw,readonly=on \
		-kernel "$KERNEL" \
		-append "root=/dev/vda1 rw console=ttyS0 earlyprintk=ttyS0 nokaslr net.ifnames=0 cxlfork.cxl_phys=$CXL_PHYS cxlfork.cxl_size=$CXL_SIZE" \
		-netdev user,id=mgmt,hostfwd=tcp::2200-:22 \
		-device virtio-net-pci,netdev=mgmt,mac=52:54:00:12:00:01 \
		-netdev socket,id=data,mcast=230.0.0.1:1234 \
		-device virtio-net-pci,netdev=data,mac=52:54:00:12:01:01 \
		-serial file:"$WS/logs/vm0-console.log" \
		-monitor unix:"$WS/sockets/vm0-monitor.sock",server,nowait \
		-pidfile "$pidfile" \
		-display none \
		-daemonize
	echo "started vm0 pid=$(cat "$pidfile") ssh=localhost:2200"
}

start_vm1() {
	local pidfile=$WS/pids/vm1.pid
	if pid_alive "$pidfile"; then
		echo "vm1 already running pid=$(cat "$pidfile")"
		return
	fi
	require_file "$WS/images/vm1.qcow2"
	require_file "$WS/cloudinit/vm1-seed.iso"
	ensure_cxl_file
	"$QEMU" \
		-name vm1 \
		-machine q35,accel=kvm,nvdimm=on \
		-cpu host \
		-smp "$SMP",sockets=1,cores="$SMP",threads=1 \
		-m "$MEM",slots=1,maxmem=20G \
		-object memory-backend-file,id=cxlmem,share=on,mem-path="$CXL_FILE",size="$CXL_BACKEND_SIZE" \
		-device nvdimm,id=cxldev,memdev=cxlmem,label-size=16M \
		-drive file="$WS/images/vm1.qcow2",if=virtio,cache=writeback,format=qcow2 \
		-drive file="$WS/cloudinit/vm1-seed.iso",media=cdrom,if=virtio,format=raw,readonly=on \
		-kernel "$KERNEL" \
		-append "root=/dev/vda1 rw console=ttyS0 earlyprintk=ttyS0 nokaslr net.ifnames=0 cxlfork.cxl_phys=$CXL_PHYS cxlfork.cxl_size=$CXL_SIZE" \
		-netdev user,id=mgmt,hostfwd=tcp::2201-:22 \
		-device virtio-net-pci,netdev=mgmt,mac=52:54:00:12:00:02 \
		-netdev socket,id=data,mcast=230.0.0.1:1234 \
		-device virtio-net-pci,netdev=data,mac=52:54:00:12:01:02 \
		-serial file:"$WS/logs/vm1-console.log" \
		-monitor unix:"$WS/sockets/vm1-monitor.sock",server,nowait \
		-pidfile "$pidfile" \
		-display none \
		-daemonize
	echo "started vm1 pid=$(cat "$pidfile") ssh=localhost:2201"
}

start_localfork() {
	local pidfile=$WS/pids/local.pid
	if pid_alive "$pidfile"; then
		echo "localfork already running pid=$(cat "$pidfile")"
		return
	fi
	require_file "$WS/images/normal-localfork.qcow2"
	require_file "$WS/cloudinit/vm0-seed.iso"
	"$QEMU" \
		-name localfork \
		-machine q35,accel=kvm \
		-cpu host \
		-smp "$SMP",sockets=1,cores="$SMP",threads=1 \
		-m "$MEM" \
		-drive file="$WS/images/normal-localfork.qcow2",if=virtio,cache=writeback,format=qcow2 \
		-drive file="$WS/cloudinit/vm0-seed.iso",media=cdrom,if=virtio,format=raw,readonly=on \
		-kernel "$KERNEL" \
		-append "root=/dev/vda1 rw console=ttyS0 earlyprintk=ttyS0 nokaslr net.ifnames=0" \
		-netdev user,id=mgmt,hostfwd=tcp::2202-:22 \
		-device virtio-net-pci,netdev=mgmt,mac=52:54:00:12:00:03 \
		-serial file:"$WS/logs/local-console.log" \
		-monitor unix:"$WS/sockets/local-monitor.sock",server,nowait \
		-pidfile "$pidfile" \
		-display none \
		-daemonize
	echo "started localfork pid=$(cat "$pidfile") ssh=localhost:2202"
}

main() {
	require_file "$KERNEL"
	case "${1:-all}" in
		all)
			start_vm0
			start_vm1
			start_localfork
			;;
		cxl)
			start_vm0
			start_vm1
			;;
		vm0) start_vm0 ;;
		vm1) start_vm1 ;;
		local|localfork) start_localfork ;;
		*)
			echo "usage: $0 [all|cxl|vm0|vm1|localfork]" >&2
			exit 2
			;;
	esac
}

main "$@"
