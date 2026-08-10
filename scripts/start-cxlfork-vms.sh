#!/usr/bin/env bash
set -euo pipefail

# 启动三类 VM：
# - vm0/vm1：带共享 NVDIMM/CXL backend，用于 CXLfork prepare/resume。
# - localfork：普通单机 baseline，不挂 CXL backend，不带 cxlfork cmdline 参数。
WS=${WS:-/home/xtl/cxlfork/cxlfork-repro}
QEMU=${QEMU:-qemu-system-x86_64}
MACHINE=${MACHINE:-q35}
GUEST_APPEND_EXTRA=${GUEST_APPEND_EXTRA:-}
KERNEL=${KERNEL:-$WS/kernel/build-6.6.32/arch/x86/boot/bzImage}
CXL_FILE=${CXL_FILE:-/dev/shm/cxl_mem}       # host 上共享给 VM0/VM1 的 CXL 后端文件。
CXL_BACKEND_SIZE=${CXL_BACKEND_SIZE:-4G}     # QEMU memory-backend-file 大小。
CXL_BACKEND_OFFSET=${CXL_BACKEND_OFFSET:-0}  # 在真实 DAX 设备中的保留区起点。
CXL_PHYS=${CXL_PHYS:-0x484000000}            # guest 内核 ioremap 的物理基址。
CXL_SIZE=${CXL_SIZE:-0xfb000000}             # guest 内核看到的 CXL window 大小。
# HydraRPC 文件模拟后端。一个 4 GiB host tmpfs 文件按 offset 划成两个
# 2 GiB endpoint，并以两个 ivshmem BAR 同时映射到 VM0/VM1。
HYDRA_SHM_FILE=${HYDRA_SHM_FILE:-/dev/shm/cxlmem}
HYDRA_SHM_SIZE=${HYDRA_SHM_SIZE:-4G}
HYDRA_BACKEND_OFFSET=${HYDRA_BACKEND_OFFSET:-0}
HYDRA_ENDPOINT_SIZE=${HYDRA_ENDPOINT_SIZE:-2G}
HYDRA_ENDPOINT1_OFFSET=${HYDRA_ENDPOINT1_OFFSET:-2G}
# auto 只会重建普通文件；真实 /dev/dax* 必须显式使用 none，启动脚本绝不
# 删除、truncate 或清零设备节点。设备清零必须在 VM 停止后由管理员单独完成。
BACKEND_RESET=${BACKEND_RESET:-auto}
MEM=${MEM:-16G}
SMP=${SMP:-16}
VM0_PORT=${VM0_PORT:-2200}
VM1_PORT=${VM1_PORT:-2201}
LOCAL_PORT=${LOCAL_PORT:-2202}
VM1_CONTROL_HOST=${VM1_CONTROL_HOST:-172.17.0.1}
VM1_CONTROL_PORT=${VM1_CONTROL_PORT:-2301}
VM1_GUEST_CONTROL_PORT=${VM1_GUEST_CONTROL_PORT:-7000}
# 为空时保持 91 上的历史行为。103 profile 会显式固定 CPU、私有 DRAM
# NUMA 节点和 ivshmem BDF，便于复现与性能解释。
VM0_HOST_CPUS=${VM0_HOST_CPUS:-}
VM1_HOST_CPUS=${VM1_HOST_CPUS:-}
VM_MEMORY_NODE=${VM_MEMORY_NODE:-}
HYDRA0_PCI_ADDR=${HYDRA0_PCI_ADDR:-}
HYDRA1_PCI_ADDR=${HYDRA1_PCI_ADDR:-}

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
	if [[ "$BACKEND_RESET" == none ]]; then
		require_file "$CXL_FILE"
		return
	fi
	if [[ "$BACKEND_RESET" != auto ]]; then
		echo "BACKEND_RESET must be auto or none" >&2
		exit 2
	fi
	if [[ -e "$CXL_FILE" && ! -f "$CXL_FILE" ]]; then
		echo "refusing to reset non-regular CXL backend $CXL_FILE; use BACKEND_RESET=none" >&2
		exit 1
	fi
	# truncate 到相同大小不会清除旧文件中的 slot 内容。先删除再创建，
	# 保证一次全新 VM 启动不会继承上一轮 checkpoint/generation。
	rm -f "$CXL_FILE"
	require_shm_space
	truncate -s "$CXL_BACKEND_SIZE" "$CXL_FILE"
}

ensure_hydra_file() {
	# VM0 启动前重建一次；VM0/VM1 运行期间绝不截断共享文件。
	if pid_alive "$WS/pids/vm0.pid" || pid_alive "$WS/pids/vm1.pid"; then
		return
	fi
	if [[ "$BACKEND_RESET" == none ]]; then
		require_file "$HYDRA_SHM_FILE"
		return
	fi
	if [[ "$BACKEND_RESET" != auto ]]; then
		echo "BACKEND_RESET must be auto or none" >&2
		exit 2
	fi
	if [[ -e "$HYDRA_SHM_FILE" && ! -f "$HYDRA_SHM_FILE" ]]; then
		echo "refusing to reset non-regular Hydra backend $HYDRA_SHM_FILE; use BACKEND_RESET=none" >&2
		exit 1
	fi
	local total endpoint offset avail
	total=$(size_to_bytes "$HYDRA_SHM_SIZE")
	endpoint=$(size_to_bytes "$HYDRA_ENDPOINT_SIZE")
	offset=$(size_to_bytes "$HYDRA_ENDPOINT1_OFFSET")
	if (( offset + endpoint > total )); then
		echo "HydraRPC endpoint layout exceeds $HYDRA_SHM_SIZE" >&2
		exit 1
	fi
	avail=$(df -B1 --output=avail "$(dirname "$HYDRA_SHM_FILE")" | tail -n 1 | tr -d ' ')
	if [[ "$avail" -lt "$total" ]]; then
		echo "not enough free space for $HYDRA_SHM_FILE: need=$HYDRA_SHM_SIZE avail=${avail}B" >&2
		exit 1
	fi
	rm -f "$HYDRA_SHM_FILE"
	truncate -s "$HYDRA_SHM_SIZE" "$HYDRA_SHM_FILE"
}

hydra_endpoint0_offset=$(size_to_bytes "$HYDRA_BACKEND_OFFSET")
hydra_endpoint1_offset=$((hydra_endpoint0_offset + $(size_to_bytes "$HYDRA_ENDPOINT1_OFFSET")))

validate_backend_layout() {
	local cxl_begin cxl_end hydra_begin hydra_end
	cxl_begin=$(size_to_bytes "$CXL_BACKEND_OFFSET")
	cxl_end=$((cxl_begin + $(size_to_bytes "$CXL_BACKEND_SIZE")))
	hydra_begin=$hydra_endpoint0_offset
	hydra_end=$((hydra_endpoint1_offset + $(size_to_bytes "$HYDRA_ENDPOINT_SIZE")))
	if [[ "$CXL_FILE" == "$HYDRA_SHM_FILE" && "$BACKEND_RESET" != none ]]; then
		echo "a shared CXL/Hydra backing object requires BACKEND_RESET=none" >&2
		exit 1
	fi
	if [[ "$CXL_FILE" == "$HYDRA_SHM_FILE" ]] &&
	   (( cxl_begin < hydra_end && hydra_begin < cxl_end )); then
		echo "CXLfork and HydraRPC backend ranges overlap in $CXL_FILE" >&2
		echo "CXL=[$cxl_begin,$cxl_end) Hydra=[$hydra_begin,$hydra_end)" >&2
		exit 1
	fi
}

hydra0_device="ivshmem-plain,id=hydra-shm0,memdev=hydra0"
hydra1_device="ivshmem-plain,id=hydra-shm1,memdev=hydra1"
if [[ -n "$HYDRA0_PCI_ADDR" ]]; then
	hydra0_device+=",bus=pcie.0,addr=$HYDRA0_PCI_ADDR"
fi
if [[ -n "$HYDRA1_PCI_ADDR" ]]; then
	hydra1_device+=",bus=pcie.0,addr=$HYDRA1_PCI_ADDR"
fi

hydra_ivshmem_args=(
	-object "memory-backend-file,id=hydra0,share=on,mem-path=$HYDRA_SHM_FILE,size=$HYDRA_ENDPOINT_SIZE,offset=$hydra_endpoint0_offset"
	-device "$hydra0_device"
	-object "memory-backend-file,id=hydra1,share=on,mem-path=$HYDRA_SHM_FILE,size=$HYDRA_ENDPOINT_SIZE,offset=$hydra_endpoint1_offset"
	-device "$hydra1_device"
)

launch_qemu() {
	local cpus=$1
	shift
	if [[ -n "$cpus" || -n "$VM_MEMORY_NODE" ]]; then
		command -v numactl >/dev/null || {
			echo "numactl is required when CPU or memory binding is configured" >&2
			return 1
		}
		local numa_args=()
		[[ -n "$cpus" ]] && numa_args+=(--physcpubind="$cpus")
		[[ -n "$VM_MEMORY_NODE" ]] && numa_args+=(--membind="$VM_MEMORY_NODE")
		numactl "${numa_args[@]}" "$QEMU" "$@"
	else
		"$QEMU" "$@"
	fi
}

print_affinity() {
	local name=$1 pidfile=$2
	local pid
	pid=$(cat "$pidfile")
	awk -v name="$name" '
		/^Cpus_allowed_list:/ { printf "%s %s\n", name, $0 }
	' "/proc/$pid/status"
	[[ -z "$VM_MEMORY_NODE" ]] || echo "$name requested_memory_node=$VM_MEMORY_NODE (verify allocations with numastat -p $pid)"
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
	ensure_hydra_file
	launch_qemu "$VM0_HOST_CPUS" \
		-name vm0 \
		-machine "$MACHINE",accel=kvm,nvdimm=on \
		-cpu host \
		-smp "$SMP",sockets=1,cores="$SMP",threads=1 \
		-m "$MEM",slots=1,maxmem=20G \
		-object memory-backend-file,id=cxlmem,share=on,mem-path="$CXL_FILE",size="$CXL_BACKEND_SIZE",offset="$CXL_BACKEND_OFFSET" \
		-device nvdimm,id=cxldev,memdev=cxlmem,label-size=16M \
		"${hydra_ivshmem_args[@]}" \
		-drive file="$WS/images/vm0.qcow2",if=virtio,cache=writeback,format=qcow2 \
		-drive file="$WS/cloudinit/vm0-seed.iso",media=cdrom,if=virtio,format=raw,readonly=on \
		-kernel "$KERNEL" \
		-append "root=/dev/vda1 rw console=ttyS0 earlyprintk=ttyS0 nokaslr net.ifnames=0 cxlfork.cxl_phys=$CXL_PHYS cxlfork.cxl_size=$CXL_SIZE $GUEST_APPEND_EXTRA" \
		-netdev user,id=mgmt,hostfwd=tcp::"$VM0_PORT"-:22 \
		-device virtio-net-pci,netdev=mgmt,mac=52:54:00:12:00:01 \
		-netdev socket,id=data,mcast=230.0.0.1:1234 \
		-device virtio-net-pci,netdev=data,mac=52:54:00:12:01:01 \
		-serial file:"$WS/logs/vm0-console.log" \
		-monitor unix:"$WS/sockets/vm0-monitor.sock",server,nowait \
		-pidfile "$pidfile" \
		-display none \
		-daemonize
	print_affinity vm0 "$pidfile"
	echo "started vm0 pid=$(cat "$pidfile") ssh=localhost:$VM0_PORT hydra=$HYDRA_SHM_FILE"
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
	ensure_hydra_file
	launch_qemu "$VM1_HOST_CPUS" \
		-name vm1 \
		-machine "$MACHINE",accel=kvm,nvdimm=on \
		-cpu host \
		-smp "$SMP",sockets=1,cores="$SMP",threads=1 \
		-m "$MEM",slots=1,maxmem=20G \
		-object memory-backend-file,id=cxlmem,share=on,mem-path="$CXL_FILE",size="$CXL_BACKEND_SIZE",offset="$CXL_BACKEND_OFFSET" \
		-device nvdimm,id=cxldev,memdev=cxlmem,label-size=16M \
		"${hydra_ivshmem_args[@]}" \
		-drive file="$WS/images/vm1.qcow2",if=virtio,cache=writeback,format=qcow2 \
		-drive file="$WS/cloudinit/vm1-seed.iso",media=cdrom,if=virtio,format=raw,readonly=on \
		-kernel "$KERNEL" \
		-append "root=/dev/vda1 rw console=ttyS0 earlyprintk=ttyS0 nokaslr net.ifnames=0 cxlfork.cxl_phys=$CXL_PHYS cxlfork.cxl_size=$CXL_SIZE $GUEST_APPEND_EXTRA" \
		-netdev user,id=mgmt,hostfwd=tcp::"$VM1_PORT"-:22,hostfwd=tcp:"$VM1_CONTROL_HOST":"$VM1_CONTROL_PORT"-:"$VM1_GUEST_CONTROL_PORT" \
		-device virtio-net-pci,netdev=mgmt,mac=52:54:00:12:00:02 \
		-netdev socket,id=data,mcast=230.0.0.1:1234 \
		-device virtio-net-pci,netdev=data,mac=52:54:00:12:01:02 \
		-serial file:"$WS/logs/vm1-console.log" \
		-monitor unix:"$WS/sockets/vm1-monitor.sock",server,nowait \
		-pidfile "$pidfile" \
		-display none \
		-daemonize
	print_affinity vm1 "$pidfile"
	echo "started vm1 pid=$(cat "$pidfile") ssh=localhost:$VM1_PORT control=$VM1_CONTROL_HOST:$VM1_CONTROL_PORT hydra=$HYDRA_SHM_FILE"
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
	launch_qemu "${LOCAL_HOST_CPUS:-}" \
		-name localfork \
		-machine "$MACHINE",accel=kvm \
		-cpu host \
		-smp "$SMP",sockets=1,cores="$SMP",threads=1 \
		-m "$MEM" \
		-drive file="$WS/images/normal-localfork.qcow2",if=virtio,cache=writeback,format=qcow2 \
		-drive file="$WS/cloudinit/vm0-seed.iso",media=cdrom,if=virtio,format=raw,readonly=on \
		-kernel "$KERNEL" \
		-append "root=/dev/vda1 rw console=ttyS0 earlyprintk=ttyS0 nokaslr net.ifnames=0 $GUEST_APPEND_EXTRA" \
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
	validate_backend_layout
	case "${1:-all}" in
		check)
			printf 'backend_layout_ok machine=%s qemu=%s cxl=%s offset=%s size=%s hydra=%s offset=%s endpoint_size=%s endpoint1_offset=%s reset=%s vm0_cpus=%s vm1_cpus=%s mem_node=%s hydra_bdfs=%s,%s\n' \
				"$MACHINE" "$QEMU" \
				"$CXL_FILE" "$CXL_BACKEND_OFFSET" "$CXL_BACKEND_SIZE" \
				"$HYDRA_SHM_FILE" "$HYDRA_BACKEND_OFFSET" \
				"$HYDRA_ENDPOINT_SIZE" "$HYDRA_ENDPOINT1_OFFSET" "$BACKEND_RESET" \
				"${VM0_HOST_CPUS:-none}" "${VM1_HOST_CPUS:-none}" "${VM_MEMORY_NODE:-none}" \
				"${HYDRA0_PCI_ADDR:-auto}" "${HYDRA1_PCI_ADDR:-auto}"
			;;
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
			echo "usage: $0 [check|all|cxl|vm0|vm1|localfork]" >&2
			exit 2
			;;
	esac
}

main "$@"
