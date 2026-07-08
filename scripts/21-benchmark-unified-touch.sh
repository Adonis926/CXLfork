#!/usr/bin/env bash
set -euo pipefail

# 主仓库最小 CXLfork benchmark 编排脚本：
# - 在 host 编译 unified_touch_bench。
# - 部署到 VM0/VM1/localfork。
# - VM0 prepare，VM1 resume，localfork 跑普通 fork baseline。
WS=${WS:-/home/xtl/cxlfork/cxlfork-repro}
KBUILD=${KBUILD:-$WS/kernel/build-6.6.32}
CXLFORK_KERNEL=${CXLFORK_KERNEL:-$WS/kernel/linux-6.6.32}
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
POLICIES=${POLICIES:-"mow moa hybrid"}
HYBRID_HOT_STRIDE=${HYBRID_HOT_STRIDE:-4}
RUN_LOCAL=${RUN_LOCAL:-1}
CXLFORK_BUILTIN=${CXLFORK_BUILTIN:-1}
DIR=${DIR:-/tmp/cxlfork-unified-touch}
OUT=${OUT:-$WS/results/unified-touch-$(date +%Y%m%d-%H%M%S).csv}
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)

vm_ssh() {
	# 统一封装 SSH，端口决定访问 VM0/VM1/localfork 哪个环境。
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
	# 从 benchmark stdout 的 key=value 文本中提取字段，后续拼成 CSV。
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
	# 用户态 benchmark 依赖 samples/cxlfork/cxlfork_uapi.h，因此必须传 CXLFORK_KERNEL。
	gcc -O2 -Wall -Wextra -I"$CXLFORK_KERNEL/samples/cxlfork" \
		-o "$WS/scripts/unified_touch_bench" "$WS/scripts/unified_touch_bench.c"
	if [[ "$CXLFORK_BUILTIN" != "1" ]]; then
		make -C "$KBUILD" M="$CXLFORK_KERNEL/drivers/cxlfork" CONFIG_CXLFORK=m \
			KBUILD_MODPOST_WARN=1 modules >/tmp/cxlfork_unified_module.log
	fi
}

deploy() {
	# 部署到三个 VM；如果 cxlfork 内建为 y，则只需 chmod /dev/cxlfork。
	local port

	if [[ "$RUN_LOCAL" == "1" ]]; then
		vm_ssh "$LOCAL_PORT" "mkdir -p '$DIR'"
		vm_scp "$LOCAL_PORT" "$WS/scripts/unified_touch_bench" ubuntu@localhost:"$DIR/" >/dev/null
	fi
	for port in "$VM0_PORT" "$VM1_PORT"; do
		vm_ssh "$port" "mkdir -p '$DIR'"
		if vm_ssh "$port" "test -e /dev/cxlfork"; then
			vm_scp "$port" "$WS/scripts/unified_touch_bench" ubuntu@localhost:"$DIR/" >/dev/null
			vm_ssh "$port" "sudo chmod 666 /dev/cxlfork"
		else
			vm_scp "$port" "$WS/scripts/unified_touch_bench" \
				"$CXLFORK_KERNEL/drivers/cxlfork/cxlfork.ko" \
				ubuntu@localhost:"$DIR/" >/dev/null
			vm_ssh "$port" "cd '$DIR' && sudo rmmod cxlfork 2>/dev/null || true; sudo insmod ./cxlfork.ko cxl_phys='$CXL_PHYS' cxl_size='$CXL_SIZE' && sudo chmod 666 /dev/cxlfork"
		fi
	done
}

csv_header() {
	# CSV header 是后续分析脚本的契约；LocalFork 行也必须严格对齐这些列。
	printf 'system,policy,hot_stride_pages,bytes,mode,iters,warmup,key,prepare_ns,pte_image_build_ns,pte_image_pages,pt_page_image_build_ns,pt_page_image_pages,pt_page_image_entries,vma_tree_build_ns,vma_tree_pages,vma_tree_nodes,state_image_build_ns,state_image_pages,private_rebase_ns,private_rebase_entries,private_rebase_pages,global_detach_ns,fork_to_child_ns,restore_ns,global_restore_ns,pte_attach_ns,pte_attach_pages,direct_pte_install_ns,direct_pte_install_pages,pte_image_validate_ns,pt_page_image_validate_ns,vma_tree_validate_ns,state_image_validate_ns,private_rebase_validate_ns,global_attach_ns,touch_ns,total_ns,full_ns,pages,anon_pages,clean_file_pages,dirty_file_pages,faults,notes\n'
}

run_local() {
	# localfork 是单机普通 fork baseline，没有 CXLfork 专属字段，缺失列写 0/NA。
	local bytes=$1
	local mode=$2
	local out fork_ns touch_ns total_ns pages

	out=$(vm_ssh "$LOCAL_PORT" "cd '$DIR' && ./unified_touch_bench local '$bytes' '$ITERS' '$WARMUP' '$mode'")
	fork_ns=$(field "$out" fork_to_child_ns)
	touch_ns=$(field "$out" touch_ns)
	total_ns=$(field "$out" total_ns)
	pages=$(field "$out" pages)
	printf 'LocalFork,local,0,%s,%s,%s,%s,NA,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,%s,0,0,0,0,0,0,0,0,0,0,0,0,%s,%s,%s,%s,0,0,0,NA,same volatile per-page touch loop\n' \
		"$bytes" "$mode" "$ITERS" "$WARMUP" "$fork_ns" "$touch_ns" "$total_ns" "$total_ns" "$pages" >>"$OUT"
	printf '[LocalFork] bytes=%s mode=%s fork_ns=%s touch_ns=%s total_ns=%s\n' \
		"$bytes" "$mode" "$fork_ns" "$touch_ns" "$total_ns"
}

run_cxlfork() {
	# CXLfork 主路径：VM0 prepare 产生 CXL slot，VM1 resume/touch 并回填 breakdown。
	local bytes=$1
	local mode=$2
	local key=$3
	local policy=$4
	local prep_out resume_out prepare_ns pte_image_build_ns pte_image_pages pt_page_image_build_ns pt_page_image_pages pt_page_image_entries vma_tree_build_ns vma_tree_pages vma_tree_nodes state_image_build_ns state_image_pages private_rebase_ns private_rebase_entries private_rebase_pages global_detach_ns
	local fork_ns restore_ns touch_ns total_ns full_ns pages anon_pages clean_file_pages dirty_file_pages faults
	local global_restore_ns pte_attach_ns pte_attach_pages direct_pte_install_ns direct_pte_install_pages pte_image_validate_ns pt_page_image_validate_ns vma_tree_validate_ns state_image_validate_ns private_rebase_validate_ns global_attach_ns hot_stride

	hot_stride=0
	if [[ "$policy" == "hybrid" ]]; then
		hot_stride=$HYBRID_HOT_STRIDE
	fi
	prep_out=$(vm_ssh "$VM0_PORT" "cd '$DIR' && ./unified_touch_bench prepare '$key' '$bytes'")
	resume_out=$(vm_ssh "$VM1_PORT" "cd '$DIR' && ./unified_touch_bench resume '$key' '$bytes' '$ITERS' '$WARMUP' '$mode' '$policy' '$hot_stride'")
	prepare_ns=$(field "$prep_out" prepare_ns)
	pte_image_build_ns=$(field "$prep_out" pte_image_build_ns)
	pte_image_pages=$(field "$prep_out" pte_image_pages)
	pt_page_image_build_ns=$(field "$prep_out" pt_page_image_build_ns)
	pt_page_image_pages=$(field "$prep_out" pt_page_image_pages)
	pt_page_image_entries=$(field "$prep_out" pt_page_image_entries)
	vma_tree_build_ns=$(field "$prep_out" vma_tree_build_ns)
	vma_tree_pages=$(field "$prep_out" vma_tree_pages)
	vma_tree_nodes=$(field "$prep_out" vma_tree_nodes)
	state_image_build_ns=$(field "$prep_out" state_image_build_ns)
	state_image_pages=$(field "$prep_out" state_image_pages)
	private_rebase_ns=$(field "$prep_out" private_rebase_ns)
	private_rebase_entries=$(field "$prep_out" private_rebase_entries)
	private_rebase_pages=$(field "$prep_out" private_rebase_pages)
	global_detach_ns=$(field "$prep_out" global_detach_ns)
	pages=$(field "$prep_out" pages)
	anon_pages=$(field "$prep_out" anon_pages)
	clean_file_pages=$(field "$prep_out" clean_file_pages)
	dirty_file_pages=$(field "$prep_out" dirty_file_pages)
	fork_ns=$(field "$resume_out" fork_to_child_ns)
	restore_ns=$(field "$resume_out" restore_ns)
	global_restore_ns=$(field "$resume_out" global_restore_ns)
	pte_attach_ns=$(field "$resume_out" pte_attach_ns)
	pte_attach_pages=$(field "$resume_out" pte_attach_pages)
	direct_pte_install_ns=$(field "$resume_out" direct_pte_install_ns)
	direct_pte_install_pages=$(field "$resume_out" direct_pte_install_pages)
	pte_image_validate_ns=$(field "$resume_out" pte_image_validate_ns)
	pt_page_image_validate_ns=$(field "$resume_out" pt_page_image_validate_ns)
	vma_tree_validate_ns=$(field "$resume_out" vma_tree_validate_ns)
	state_image_validate_ns=$(field "$resume_out" state_image_validate_ns)
	private_rebase_validate_ns=$(field "$resume_out" private_rebase_validate_ns)
	global_attach_ns=$(field "$resume_out" global_attach_ns)
	touch_ns=$(field "$resume_out" touch_ns)
	total_ns=$(field "$resume_out" total_ns)
	faults=$(field "$resume_out" faults)
	full_ns=$((prepare_ns + total_ns))
	printf 'CXLfork,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,tiering policy comparison with CXL state/PTE image attach breakdown\n' \
		"$policy" "$hot_stride" "$bytes" "$mode" "$ITERS" "$WARMUP" "$key" "$prepare_ns" "$pte_image_build_ns" "$pte_image_pages" "$pt_page_image_build_ns" "$pt_page_image_pages" "$pt_page_image_entries" "$vma_tree_build_ns" "$vma_tree_pages" "$vma_tree_nodes" "$state_image_build_ns" "$state_image_pages" "$private_rebase_ns" "$private_rebase_entries" "$private_rebase_pages" "$global_detach_ns" "$fork_ns" "$restore_ns" \
		"$global_restore_ns" "$pte_attach_ns" "$pte_attach_pages" "$direct_pte_install_ns" "$direct_pte_install_pages" "$pte_image_validate_ns" "$pt_page_image_validate_ns" "$vma_tree_validate_ns" "$state_image_validate_ns" "$private_rebase_validate_ns" "$global_attach_ns" "$touch_ns" "$total_ns" "$full_ns" "$pages" "$anon_pages" "$clean_file_pages" "$dirty_file_pages" "$faults" >>"$OUT"
	printf '[CXLfork] policy=%s hot_stride=%s bytes=%s mode=%s prepare_ns=%s pte_image_build_ns=%s pte_image_pages=%s pt_page_image_build_ns=%s pt_page_image_pages=%s pt_page_image_entries=%s vma_tree_build_ns=%s vma_tree_pages=%s vma_tree_nodes=%s state_image_build_ns=%s state_image_pages=%s private_rebase_ns=%s private_rebase_entries=%s private_rebase_pages=%s global_detach_ns=%s restore_ns=%s global_restore_ns=%s pte_attach_ns=%s pte_attach_pages=%s direct_pte_install_ns=%s direct_pte_install_pages=%s pte_image_validate_ns=%s pt_page_image_validate_ns=%s vma_tree_validate_ns=%s state_image_validate_ns=%s private_rebase_validate_ns=%s global_attach_ns=%s touch_ns=%s total_ns=%s full_ns=%s anon_pages=%s clean_file_pages=%s dirty_file_pages=%s faults=%s\n' \
		"$policy" "$hot_stride" "$bytes" "$mode" "$prepare_ns" "$pte_image_build_ns" "$pte_image_pages" "$pt_page_image_build_ns" "$pt_page_image_pages" "$pt_page_image_entries" "$vma_tree_build_ns" "$vma_tree_pages" "$vma_tree_nodes" "$state_image_build_ns" "$state_image_pages" "$private_rebase_ns" "$private_rebase_entries" "$private_rebase_pages" "$global_detach_ns" "$restore_ns" "$global_restore_ns" "$pte_attach_ns" "$pte_attach_pages" "$direct_pte_install_ns" "$direct_pte_install_pages" "$pte_image_validate_ns" "$pt_page_image_validate_ns" "$vma_tree_validate_ns" "$state_image_validate_ns" "$private_rebase_validate_ns" "$global_attach_ns" "$touch_ns" "$total_ns" "$full_ns" "$anon_pages" "$clean_file_pages" "$dirty_file_pages" "$faults"
}

main() {
	# 矩阵由 SIZES/MODES/POLICIES 控制，第一轮调试可保持小规模。
	local bytes mode policy key

	mkdir -p "$(dirname "$OUT")"
	csv_header >"$OUT"
	build
	deploy
	key=$KEY_BASE
	for bytes in $SIZES; do
		for mode in $MODES; do
			if [[ "$RUN_LOCAL" == "1" ]]; then
				run_local "$bytes" "$mode"
			fi
			for policy in $POLICIES; do
				run_cxlfork "$bytes" "$mode" "$key" "$policy"
				key=$((key + 1))
			done
		done
	done
	echo "results=$OUT"
}

main "$@"
