#!/usr/bin/env bash
set -euo pipefail

# 启动三类 VM：
# - vm0/vm1：带共享 NVDIMM/CXL backend，用于 CXLfork prepare/resume。
# - localfork：普通单机 baseline，不挂 CXL backend，不带 cxlfork cmdline 参数。
WS=${WS:-/home/xtl/cxlfork/cxlfork-repro}
QEMU=${QEMU:-qemu-system-x86_64}
KERNEL=${KERNEL:-$WS/kernel/build-6.6.32/arch/x86/boot/bzImage}
CXL_FILE=${CXL_FILE:-/dev/shm/cxl_mem}       # host 上共享给 VM0/VM1 的 CXL 后端文件。
CXL_BACKEND_SIZE=${CXL_BACKEND_SIZE:-4G}     # QEMU memory-backend-file 大小。
CXL_PHYS=${CXL_PHYS:-0x484000000}            # guest 内核 ioremap 的物理基址。
CXL_SIZE=${CXL_SIZE:-0xfb000000}             # guest 内核看到的 CXL window 大小。
MEM=${MEM:-16G}
SMP=${SMP:-16}
VM0_PORT=${VM0_PORT:-2200}
VM1_PORT=${VM1_PORT:-2201}
LOCAL_PORT=${LOCAL_PORT:-2202}
VM1_CONTROL_HOST=${VM1_CONTROL_HOST:-172.17.0.1}
VM1_CONTROL_PORT=${VM1_CONTROL_PORT:-2301}
VM1_GUEST_CONTROL_PORT=${VM1_GUEST_CONTROL_PORT:-7000}

mkdir -p "$WS/logs" "$WS/pids" "$WS/sockets"

require_file() {
	local path=$1
	if [[ ! -e "$path" ]]; then
		echo "missing required file: $path" >&2
		exit 1
	fi
}

size_to_bytes() {
	local size=$1
	case "$size" in
		*[Gg]) echo $(( ${size%[Gg]} * 1024 * 1024 * 1024 )) ;;
		*[Mm]) echo $(( ${size%[Mm]} * 1024 * 1024 )) ;;
		*[Kk]) echo $(( ${size%[Kk]} * 1024 )) ;;
		*) echo "$size" ;;
	esac
}

pid_alive() {
	local pidfile=$1
	[[ -f "$pidfile" ]] && kill -0 "$(cat "$pidfile")" 2>/dev/null
}

port_busy() {
	local port=$1
	ss -lnt "sport = :$port" | tail -n +2 | grep -q .
}

require_port_free() {
	# 防止覆盖仍在运行的 VM；端口占用时交给人工确认。
	local name=$1
	local port=$2
	if port_busy "$port"; then
		echo "$name ssh port $port is already in use; not starting a new VM" >&2
		ss -lntp "sport = :$port" >&2 || true
		exit 1
	fi
}

require_shm_space() {
	# CXL_FILE 位于 /dev/shm 时必须先确认 tmpfs 有足够空间。
	local need avail
	need=$(size_to_bytes "$CXL_BACKEND_SIZE")
	avail=$(df -B1 --output=avail "$(dirname "$CXL_FILE")" | tail -n 1 | tr -d ' ')
	if [[ "$avail" -lt "$need" ]]; then
		echo "not enough free space for $CXL_FILE: need=$CXL_BACKEND_SIZE avail=${avail}B" >&2
		df -h "$(dirname "$CXL_FILE")" >&2
		ls -lh "$CXL_FILE" 2>/dev/null >&2 || true
		exit 1
	fi
}

ensure_cxl_file() {
	# 只在没有 VM0/VM1 活跃时重建共享 CXL 后端文件，避免破坏运行中实验。
	if pid_alive "$WS/pids/vm0.pid" || pid_alive "$WS/pids/vm1.pid"; then
		return
	fi
	# truncate 到相同大小不会清除旧文件中的 slot 内容。先删除再创建，
	# 保证一次全新 VM 启动不会继承上一轮 checkpoint/generation。
	rm -f "$CXL_FILE"
	require_shm_space
	truncate -s "$CXL_BACKEND_SIZE" "$CXL_FILE"
}

start_vm0() {
	# VM0 是 checkpoint/prepare 端，挂载共享 CXL backend。
	local pidfile=$WS/pids/vm0.pid
	if pid_alive "$pidfile"; then
		echo "vm0 already running pid=$(cat "$pidfile")"
		return
	fi
	require_file "$WS/images/vm0.qcow2"
	require_file "$WS/cloudinit/vm0-seed.iso"
	require_port_free vm0 "$VM0_PORT"
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
		-netdev user,id=mgmt,hostfwd=tcp::"$VM0_PORT"-:22 \
		-device virtio-net-pci,netdev=mgmt,mac=52:54:00:12:00:01 \
		-netdev socket,id=data,mcast=230.0.0.1:1234 \
		-device virtio-net-pci,netdev=data,mac=52:54:00:12:01:01 \
		-serial file:"$WS/logs/vm0-console.log" \
		-monitor unix:"$WS/sockets/vm0-monitor.sock",server,nowait \
		-pidfile "$pidfile" \
		-display none \
		-daemonize
	echo "started vm0 pid=$(cat "$pidfile") ssh=localhost:$VM0_PORT"
}

start_vm1() {
	# VM1 是 remote resume/invoke 端，和 VM0 使用同一个 CXL_FILE。
	local pidfile=$WS/pids/vm1.pid
	if pid_alive "$pidfile"; then
		echo "vm1 already running pid=$(cat "$pidfile")"
		return
	fi
	require_file "$WS/images/vm1.qcow2"
	require_file "$WS/cloudinit/vm1-seed.iso"
	require_port_free vm1 "$VM1_PORT"
	require_port_free vm1-control "$VM1_CONTROL_PORT"
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
		-netdev user,id=mgmt,hostfwd=tcp::"$VM1_PORT"-:22,hostfwd=tcp:"$VM1_CONTROL_HOST":"$VM1_CONTROL_PORT"-:"$VM1_GUEST_CONTROL_PORT" \
		-device virtio-net-pci,netdev=mgmt,mac=52:54:00:12:00:02 \
		-netdev socket,id=data,mcast=230.0.0.1:1234 \
		-device virtio-net-pci,netdev=data,mac=52:54:00:12:01:02 \
		-serial file:"$WS/logs/vm1-console.log" \
		-monitor unix:"$WS/sockets/vm1-monitor.sock",server,nowait \
		-pidfile "$pidfile" \
		-display none \
		-daemonize
	echo "started vm1 pid=$(cat "$pidfile") ssh=localhost:$VM1_PORT control=$VM1_CONTROL_HOST:$VM1_CONTROL_PORT"
}

start_localfork() {
	# localfork VM 只用于普通 fork baseline，因此没有 nvdimm 设备和 cxlfork 参数。
	local pidfile=$WS/pids/local.pid
	if pid_alive "$pidfile"; then
		echo "localfork already running pid=$(cat "$pidfile")"
		return
	fi
	require_file "$WS/images/normal-localfork.qcow2"
	require_file "$WS/cloudinit/vm0-seed.iso"
	require_port_free localfork "$LOCAL_PORT"
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
		-netdev user,id=mgmt,hostfwd=tcp::"$LOCAL_PORT"-:22 \
		-device virtio-net-pci,netdev=mgmt,mac=52:54:00:12:00:03 \
		-serial file:"$WS/logs/local-console.log" \
		-monitor unix:"$WS/sockets/local-monitor.sock",server,nowait \
		-pidfile "$pidfile" \
		-display none \
		-daemonize
	echo "started localfork pid=$(cat "$pidfile") ssh=localhost:$LOCAL_PORT"
}

main() {
	# 调试时推荐先 cxl，再 localfork，避免 all 一次启动三个 VM 时难以定位失败点。
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
