# CXLfork phased acceptance log

This file records phase-by-phase validation notes for the `cxlfork-kernel-paper-alignment` branch. It is intentionally separate from the main status matrix so each phase can be reviewed later without reading terminal logs.

## Phase 0-4 accepted baseline

- Main repository: `b157faa` (`Record phase 4 restore validation`).
- Kernel submodule: `b3f9228a7` (`cxlfork: enforce strict restore mappings`).
- Phase 1 through Phase 4 were built and validated on the real remote environment `xtl@10.0.16.91:~/cxlfork/cxlfork-repro` using the default 16 GiB VM configuration.
- Latest accepted capabilities: v2 ABI, PTE/VMA image reconstruction, restricted single-thread checkpoint, reliable slot generation, MoW data COW evidence, MoA first-access copy evidence.
- Explicitly still unsupported after Phase 4: real shared PTE leaf attach, PTE leaf CoW, real Maple Tree/VMA leaf attach, full private execution-context restore, A-bit hybrid, full global state restore.

## Phase 5 attempt: real shared PTE leaf attach gate

Date: 2026-07-13 Asia/Shanghai.

Target from the plan: make the CPU page walker actually traverse a CXL-hosted PTE leaf page, then prove two mm/VM restore mappings point at the same CXL leaf PFN and that hardware access updates are visible on that leaf.

### Code audit result

The existing kernel code already builds CXL-resident PTE leaf images and a CXL page-table-shaped tree:

- `cxlfork_build_leaf_pte_image()` records per-page `orig_pteval` and `cxl_pteval`.
- `cxlfork_build_pt_page_image()` groups PTEs into page-sized CXL leaf images and records a synthetic CXL page-table tree.
- Restore still materializes local Linux PTEs through `io_remap_pfn_range()` or `vmf_insert_mixed()`; the CPU page walker does not consume the CXL leaf image.

### Blocking kernel invariant

On x86/Linux 6.6, a non-leaf PMD entry that points to a PTE page is not just a hardware pointer. Core-MM also assumes the PFN behind that PMD has normal page-table-page semantics:

- `pte_offset_kernel()` uses `pmd_page_vaddr(*pmd)`, which uses `__va(pmd physical address)`.
- `pte_lockptr()` uses `page_ptdesc(pmd_page(*pmd))`, so the PTE leaf PFN must have a valid `struct page` and page-table lock metadata.
- `free_pte_range()` obtains `pmd_pgtable(*pmd)` and eventually calls `pte_free_tlb()` on it.
- `mprotect`, fault handling, GUP, pagewalk, munmap and mm teardown all use these assumptions through `pte_offset_map_lock()` and related helpers.

The current CXL window is outside System RAM and is only accessed through driver `ioremap`. VM evidence from `sudo cat /proc/iomem` on port 2200:

- System RAM high range: `100000000-47fffffff`.
- cxlfork cmdline: `cxlfork.cxl_phys=0x484000000 cxlfork.cxl_size=0xfb000000`.
- Therefore the CXL window starts above System RAM and does not have ordinary direct-map/page-table-page semantics.

Kernel config has `CONFIG_ZONE_DEVICE=y`, so a future implementation could explore registering this window with `dev_pagemap`/altmap or a dedicated page-table-page metadata layer, but the current driver does not do that.

### Decision

Phase 5 is blocked before implementation. Directly installing a PMD that points to the current CXL PFN would be an unsafe experiment: it may let the CPU page walker read the leaf briefly, but Linux core-MM can then dereference invalid `struct page` metadata, take an invalid page-table lock, or free a non-buddy/non-pagetable page during unmap/exit.

No kernel behavior was changed for Phase 5. The next viable engineering step is a design subphase before continuing:

1. Add an explicit CXL page-table leaf metadata model: either register the CXL page-table pool as `ZONE_DEVICE` with usable `struct page`/ptdesc semantics, or create a dedicated shared-leaf PMD marker plus custom accessors that never call `pmd_page()`, `pmd_page_vaddr()` or `pte_free_tlb()` on CXL PFNs.
2. Hook every core-MM path that can inspect, lock, mutate or free a PTE leaf: fault, mprotect, munmap, fork, GUP/pagewalk, khugepaged, mremap and mm teardown.
3. Implement materialization before any OS write to a shared leaf.
4. Only after those hooks exist should `CXLFORK_CAP_REAL_SHARED_PTE_LEAF` be set.

Phase 5 is therefore not accepted. The work stopped at the planned feasibility gate rather than falling back to image reconstruction under the shared-leaf name.

## Phase 5a accepted: readonly real shared PTE leaf attach

Date: 2026-07-13 Asia/Shanghai.

Kernel commit: `fbc9e54b3` (`cxlfork: attach readonly mappings to shared PTE leaves`).

Scope accepted:

- `CONFIG_CXLFORK` is now `bool`, because core-MM calls cxlfork shared-leaf helpers and cannot depend on a loadable module symbol.
- Added `include/linux/cxlfork_mm.h` as the minimal core-MM interface.
- `mm/memory.c` now recognizes cxlfork shared CXL PTE leaf PMDs in zap/free paths. It clears the PMD, flushes the PMD range, updates page-table accounting, and never calls `pmd_page()`, `pmd_page_vaddr()` or `pte_free_tlb()` on the CXL PFN.
- Readonly restore uses real CXL PTE leaf attach for PMD-aligned, full-PMD regions. Non-aligned regions fall back to the older direct PTE reconstruction path.
- `QUERY_CAPS_V2` now reports `CXLFORK_CAP_REAL_SHARED_PTE_LEAF` but still does not report `CXLFORK_CAP_PTE_LEAF_COW`.
- `INSPECT_V2` now reports `shared_leaf_pfn`, `current_pmd`, and `current_pmd_pfn`.

Hard evidence from VM validation:

- 4 MiB checkpoint succeeded with two regions and 1024 pages.
- VM1 readonly restore reported `shared_pfn=4768768 before_pfn=4768768 shared_leaf_pfn=4769803 current_pmd_pfn=4769803 verify=ok`.
- The equality `current_pmd_pfn == shared_leaf_pfn` proves the target mm PMD points at the CXL PTE leaf page.
- The equality `before_pfn == shared_pfn` proves the PTE read through that leaf maps the CXL data page.
- User-space checksum verification passed after CPU reads from the restored mapping.

Regression validation:

- Kernel `bzImage` build passed.
- UAPI headers were refreshed and `tools/testing/selftests/cxlfork/cxlfork_test` rebuilt successfully.
- Three VMs passed ABI 9/9.
- VM1 readonly, MoW and MoA restore passed.
- readonly/MoW/MoA conflict tests passed.
- failure tests and lifecycle tests passed.
- 124 MiB prepare succeeded; 125 MiB prepare returned `ENOSPC`.
- Strict dmesg check on VM0/VM1/localfork was clean: no `BUG`, `WARNING`, `Oops`, `Call Trace`, cxlfork mmap/remap diagnostics, bad pagetable, general protection fault, page fault, or `non-zero pgtables` warning.

Known limits after Phase 5a:

- Shared leaf attach is readonly-only and limited to PMD-aligned full-PMD regions.
- MoW/MoA still use the previous local-PTE/fault paths; they do not yet use shared leaf CoW.
- PTE mutation paths such as mprotect, fork, GUP/pagewalk mutation, mremap and partial munmap are not yet converted to materialize-on-write semantics.
- `CXLFORK_CAP_PTE_LEAF_COW` remains unset.

## Phase 6 accepted: shared PTE leaf materialize-on-write

Date: 2026-07-13 Asia/Shanghai.

Kernel commit: `469548dc7` (`cxlfork: materialize shared PTE leaves on write`).

Scope accepted:

- MoW restore now uses the same real shared CXL PTE leaf attach as readonly restore for PMD-aligned full-PMD regions.
- The CXL leaf PTEs are explicitly marked `pte_special`, matching PFNMAP/mixed-PFN semantics and preventing core-MM from treating CXL PFNs as ordinary `struct page` mappings after materialization.
- `handle_pte_fault()` detects a cxlfork shared leaf PMD before calling `pte_offset_map_nolock()` on write/unshare faults.
- `cxlfork_materialize_shared_leaf_pmd()` allocates a normal local page-table page, copies the 4 KiB CXL leaf, switches the PMD under PMD lock, flushes the PMD range, and then lets existing Linux `do_wp_page()` perform data-page COW.
- `QUERY_CAPS_V2` now reports `CXLFORK_CAP_PTE_LEAF_COW` in addition to `CXLFORK_CAP_REAL_SHARED_PTE_LEAF`.

Hard evidence from VM validation:

- VM1 MoW restore reported `shared_leaf_pfn=4769803 current_pmd_pfn=4769803` before write, proving the target mm initially points at the CXL PTE leaf.
- After the first write, VM1 MoW reported `after_pmd_pfn=1124167`, which differs from `shared_leaf_pfn`, proving the writer materialized a local PTE leaf.
- The second write reported `second_pmd_pfn=1124167`, proving repeated writes do not repeatedly copy the leaf.
- Data-page PFN also changed from the shared CXL PFN to a local PFN on first write and stayed stable on the second write.
- The shared checkpoint checksum remained unchanged after writes.

Regression validation:

- Kernel `bzImage` build passed.
- UAPI headers were refreshed and cxlfork selftest rebuilt successfully.
- Three VMs passed ABI 9/9.
- VM1 readonly, MoW and MoA restore passed.
- readonly/MoW/MoA conflict tests passed.
- failure tests and lifecycle tests passed.
- 124 MiB prepare succeeded; 125 MiB prepare returned `ENOSPC`.
- Strict dmesg check on VM0/VM1/localfork was clean: no `BUG`, `WARNING`, `Oops`, `Call Trace`, cxlfork mmap/remap diagnostics, bad page map, bad pagetable, general protection fault, page fault, or `non-zero pgtables` warning.

Known limits after Phase 6:

- Leaf CoW is validated for the write-fault path used by MoW in the restricted single-thread anonymous model.
- mprotect, fork, GUP/pagewalk mutation, mremap, partial munmap and khugepaged interactions are still not fully converted to materialize-on-write semantics.
- The implementation still supports shared leaf attach only for PMD-aligned full-PMD regions; non-aligned regions fall back to reconstruction.

## Phase 7 gate: real Maple Tree/VMA leaf attach blocked

Date: 2026-07-13 Asia/Shanghai.

Target from the plan: make `find_vma()` / `mas_find()` actually traverse CXL-hosted VMA/Maple Tree nodes, then materialize local nodes on VMA mutation.

Audit result:

- Linux 6.6 `mm_struct.mm_mt` is a real `struct maple_tree` whose `ma_root` stores kernel virtual pointers with low-bit Maple encoding.
- `struct maple_node` is a 256-byte slab object allocated from `maple_node_cache`.
- Maple node entries and parent pointers are kernel virtual pointers, not offsets.
- Maple Tree lookup uses helpers such as `mte_to_node()` / `mas_mn()` that directly decode and dereference those local kernel pointers.
- Maple Tree destruction and rebalance paths use RCU and slab freeing: `ma_free_rcu()`, `mt_free_rcu()`, `mas_destroy()`, `__mt_destroy()`, and `mtree_destroy()` eventually return nodes to `maple_node_cache`.

Blocking invariant:

A CXL VMA image cannot be attached to `mm->mm_mt` by writing a CXL offset or CXL physical address into `ma_root`. The Maple Tree code would treat it as a local encoded `struct maple_node *`, dereference it as a kernel virtual address, and later attempt RCU/slab lifecycle operations on it.

A safe real VMA leaf attach would require a dedicated Maple Tree extension, not a driver-only change:

1. A new encoded node type or accessor path that can distinguish CXL-backed nodes from slab-backed nodes.
2. CXL offset-to-local alias translation in every Maple Tree lookup path used by `find_vma()` / `mas_find()`.
3. Mutation materialization before `mas_store()`, `mas_erase()`, VMA split/merge, mprotect, munmap, mremap, brk and VMA iterator updates.
4. RCU/free handling that never sends CXL nodes to `maple_node_cache` and never treats CXL image nodes as local slab objects.
5. A strategy for entries inside CXL nodes: either local `struct vm_area_struct *` pointers with per-restore reconstruction, or a separate CXL VMA object graph and local materialization layer.

Decision:

Phase 7 is blocked at the feasibility gate. The existing cxlfork VMA image remains image-driven reconstruction. It must not be reported as real Maple Tree attach or constant-time VMA restore. No kernel behavior was changed for this phase.

## Phase 7 accepted: bounded CXL Maple-node lookup proof

Date: 2026-07-13 Asia/Shanghai.

Kernel commit: `bb15f4f2daec` (`cxlfork: probe VMA lookups through CXL Maple nodes`).

Scope accepted:

- Added a bounded Maple Tree probe path that copies the current process `mm->mm_mt` node structure into a reserved CXL scratch area at the end of the checkpoint slot.
- The copied CXL Maple nodes preserve Maple low-bit node encoding, child slots, parent pointers and root parent encoding for the current kernel address space.
- `INSPECT_V2` temporarily switches `mm->mm_mt.ma_root` to the CXL-hosted root, calls `find_vma()`, records the lookup result, and immediately restores the original local Maple root before returning to user space.
- Added `MT_FLAGS_CXLFORK_CXL_NODES` as a guard so an accidentally attached CXL Maple tree is not destroyed through the normal slab/RCU Maple free path.
- `INSPECT_V2` now reports `vma_maple_root_pfn`, `vma_maple_nodes`, and `vma_lookup_start/end`.
- The cxlfork selftest now requires `CXLFORK_CAP_REAL_SHARED_VMA_LEAF` and verifies that restore-time inspect observes a CXL VMA node lookup covering the restored address.

Hard evidence from clean VM validation:

- The shared backend was reset with `rm -f /dev/shm/cxl_mem` before the acceptance run.
- VM1 readonly restore reported `vma_root_pfn=4800512 vma_nodes=3 vma_lookup=500000000000-500000200000 verify=ok`.
- VM1 MoW restore reported the same CXL VMA root evidence and also preserved Phase 6 leaf CoW evidence: shared PMD PFN before write, local PMD PFN after write.
- VM1 MoA restore reported `vma_root_pfn=4800512 vma_nodes=3 vma_lookup=500000000000-500000200000 verify=ok`.
- The `vma_lookup` range covers the first restored page, proving `find_vma()` returned the expected VMA while `mm->mm_mt.ma_root` pointed at the CXL-hosted Maple root.

Regression validation:

- Kernel `bzImage` build passed.
- UAPI headers were refreshed from the O= build tree and cxlfork selftest rebuilt successfully.
- VM0, VM1 and localfork each passed ABI 9/9.
- VM1 readonly, MoW and MoA restore passed with CXL VMA lookup evidence.
- failure tests passed.
- lifecycle tests passed.
- conflict test passed with `errno=17 guard=ok verify=ok`.
- 124 MiB prepare succeeded; 125 MiB prepare returned `ENOSPC`.
- Strict dmesg check on VM0/VM1/localfork was clean: no `BUG`, `WARNING`, `Oops`, `Call Trace`, cxlfork mmap/remap diagnostics, bad page map, bad pagetable, general protection fault, page fault, or `non-zero pgtables` warning.

Known limits after Phase 7:

- This is a bounded lookup proof, not a complete cross-VM VMA object graph.
- CXL Maple nodes currently contain local `struct vm_area_struct *` entries reconstructed in the restoring process; they do not yet contain portable CXL-offset VMA objects.
- The CXL Maple tree is attached only during the `INSPECT_V2` probe transaction and is restored to the local tree before returning to user space. This avoids `exit_mmap()`, `munmap`, mprotect, split/merge and RCU/slab free paths acting on CXL nodes.
- Therefore this phase proves that Linux `find_vma()` can traverse CXL-hosted Maple nodes under controlled conditions. It still does not prove constant-time VMA restore or persistent shared VMA leaf lifecycle across arbitrary VMA mutation.

## Phase 8 accepted: restricted user thread context resume

Date: 2026-07-13 Asia/Shanghai.

Kernel commit: `16c8fa021d88` (`cxlfork: validate user thread context resume`).

Scope accepted:

- Added `CXLFORK_CAP_USER_THREAD_CONTEXT_RESUME` to distinguish the implemented restricted context-resume mechanism from unsupported full private-state restore.
- `CXLFORK_CAP_FULL_PRIVATE_STATE` remains unset and `CXLFORK_F_FULL_PRIVATE_STATE` prepare still returns `EOPNOTSUPP`.
- `CXLFORK_F_USER_THREAD_STATE` lets the checkpoint caller store an explicit user IP/SP in the CXL state image.
- `CXLFORK_F_APPLY_THREAD_STATE` now validates that the saved IP/SP are nonzero user addresses and returns an error instead of silently doing nothing.
- Thread register application is now performed after restore output has been copied to user memory, so the final syscall return path is the first point where the saved IP/SP take effect.
- The cxlfork selftest is linked `-no-pie` for stable cross-VM text addresses and adds `threadctx-prepare` / `threadctx-restore`.

Hard evidence from clean VM validation:

- The shared backend was reset with `rm -f /dev/shm/cxl_mem` before the acceptance run.
- VM0 prepared a checkpoint with saved user context:
  `threadctx-prepare key=71001 ip=4029f0 sp=60000010fff8 pages=1024 checksum=6781908030244848515 verify=ok`.
- VM1 restored that checkpoint with `CXLFORK_F_APPLY_THREAD_STATE` and printed:
  `threadctx-resume verify=ok`.
- The restore command would print `threadctx restore returned without jumping to saved IP` and exit nonzero if the ioctl returned to its original call site. The observed output proves the syscall returned through the saved IP/SP trampoline instead.
- The same saved-context resume check passed for readonly, MoW and MoA restore policies.

Regression validation:

- Kernel `bzImage` build passed.
- UAPI headers were refreshed from the O= build tree and cxlfork selftest rebuilt successfully.
- VM0, VM1 and localfork each passed ABI 9/9.
- VM1 readonly, MoW and MoA restore passed with Phase 7 CXL VMA lookup evidence.
- failure tests passed, including `FULL_PRIVATE_STATE` returning `EOPNOTSUPP`.
- lifecycle tests passed.
- conflict test passed with `errno=17 guard=ok verify=ok`.
- 124 MiB prepare succeeded; 125 MiB prepare returned `ENOSPC`.
- Strict dmesg check on VM0/VM1/localfork was clean: no `BUG`, `WARNING`, `Oops`, `Call Trace`, cxlfork mmap/remap diagnostics, bad page map, bad pagetable, general protection fault, page fault, or `non-zero pgtables` warning.

Known limits after Phase 8:

- This is not arbitrary-process `FULL_PRIVATE_STATE` restore.
- The restored IP/SP are explicitly supplied through `CXLFORK_F_USER_THREAD_STATE`; the kernel does not yet capture and resume an asynchronously checkpointed instruction pointer from an arbitrary source process.
- The trampoline requires an address-compatible target process. The selftest enforces this with a non-PIE binary and a fixed mapped restore stack.
- The private rebase image is still a validated offset manifest for cxlfork metadata, not a consumed reconstruction of Linux `task_struct` / `mm_struct` object graphs.
- TLS restore remains a separate optional flag and was not claimed as part of this acceptance beyond preserving the existing path.

## Phase 9 accepted: strict regular-file global state subset

Date: 2026-07-13 Asia/Shanghai.

Kernel commit: `5a7f0089e560` (`cxlfork: restore strict regular file state`).

Scope accepted:

- Added `CXLFORK_CAP_GLOBAL_FILE_STATE` for the tested global-state subset.
- Strict fd capture is requested by using `CXLFORK_F_REOPEN_FDS` during prepare.
- Strict fd capture records only user-opened fd numbers `>= 3`; stdin/stdout/stderr are treated as inherited environment and are outside this subset.
- The active `/dev/cxlfork` control fd is skipped during capture so the ioctl fd does not poison the checkpoint.
- Any captured fd `>= 3` that is not a regular file causes prepare to fail with `EOPNOTSUPP`. This covers pipe/socket/epoll/timerfd-style unsupported objects.
- Restore reopens regular files by path, verifies inode/dev identity, restores the original fd number with `replace_fd()`, restores file offset with `vfs_llseek()`, and preserves supported file status flags such as `O_APPEND`.
- `CXLFORK_F_APPLY_GLOBAL_STATE` continues to apply cwd, root, umask, signal mask, altstack metadata and rlimits; the selftest now verifies cwd, umask and signal mask.

Hard evidence from clean VM validation:

- The shared backend was reset with `rm -f /dev/shm/cxl_mem` before the acceptance run.
- Same-VM validation was used for fd identity because VM0 and VM1 use separate qcow2 root filesystems; inode/dev equality is not meaningful across those images.
- VM0 strict prepare reported:
  `fdglobal-prepare key=72001 fd=7 pos=11 flags=append cwd=/tmp umask=027 sigusr1=blocked fds=1 verify=ok`.
- VM0 strict restore reported:
  `fdglobal-restore key=72001 policy=readonly fd=7 pos=11 flags=append cwd=/tmp umask=027 sigusr1=blocked verify=ok`.
- The same fd/global restore check passed for MoW and MoA policies.
- The failure suite now includes a strict pipe-fd checkpoint and passed, proving unsupported fd objects fail explicitly rather than being silently skipped.

Regression validation:

- Kernel `bzImage` build passed.
- UAPI headers were refreshed from the O= build tree and cxlfork selftest rebuilt successfully.
- VM0, VM1 and localfork each passed ABI 9/9.
- VM1 readonly, MoW and MoA restore passed with Phase 7 CXL VMA lookup evidence.
- Phase 8 thread-context resume still passed.
- failure tests passed, including `FULL_PRIVATE_STATE` returning `EOPNOTSUPP` and strict pipe fd returning `EOPNOTSUPP`.
- lifecycle tests passed.
- conflict test passed with `errno=17 guard=ok verify=ok`.
- 124 MiB prepare succeeded; 125 MiB prepare returned `ENOSPC`.
- Strict dmesg check on VM0/VM1/localfork was clean: no `BUG`, `WARNING`, `Oops`, `Call Trace`, cxlfork mmap/remap diagnostics, bad page map, bad pagetable, general protection fault, page fault, or `non-zero pgtables` warning.

Known limits after Phase 9:

- The file-state subset requires the same root filesystem identity at restore time. In the current VM0/VM1 setup, root disks are separate images, so strict inode/dev verification is validated same-VM and would reject mismatched cross-VM files.
- Only regular files are supported. Sockets, pipes, epoll, eventfd, timerfd, anon_inode and device fds are explicitly unsupported for strict fd capture.
- Descriptor flags such as close-on-exec are not yet separately serialized; the accepted test covers file status flags and offset.
- Namespace restore is still identity/path recording plus cwd/root application, not namespace recreation.

## Phase 10 accepted: checkpointed A/D-bit hybrid tiering

Date: 2026-07-13 Asia/Shanghai.

Kernel commit: `f44e8a87d684` (`cxlfork: drive hybrid tiering from checkpointed pte bits`).

Scope accepted:

- Added `CXLFORK_CAP_A_BIT_HYBRID` for the tested A/D-bit based hybrid policy.
- Added `CXLFORK_PTE_MARK_V2`, a test-only v2 ioctl that can set/clear accessed and dirty bits on the caller's own PTEs under `mmap_write_lock()`.
- `INSPECT_V2` now reports the checkpointed `orig_pte` and marks it with `CXLFORK_INSPECT_F_ORIG_PTE_VALID`.
- Hybrid restore no longer uses synthetic stride-based hot-page selection.
- The hybrid fault path now makes local-copy decisions from the checkpointed PTE image: write faults, checkpointed accessed pages, and checkpointed dirty pages take the local-copy path.
- Dirty pages are prefaulted into local anonymous pages during hybrid restore, so the dirty-prefetch decision is based on checkpointed D bits rather than runtime stride.
- The selftest now creates a three-page hot/cold/dirty matrix, manipulates A/D bits through `PTE_MARK_V2`, checkpoints the resulting PTE image, and verifies restore behavior through `INSPECT_V2` and PFN transitions.
- The fd/global descriptor corruption investigation was resolved during this phase: the observed all-zero descriptor came from running prepare on `localfork`, which intentionally has no NVDIMM/CXL backend. In the correct CXL VM environment, fdglobal prepare/restore passes. State capture was still hardened by constructing task/mm/thread/global/fd state locally before copying it into the CXL descriptor.

Hard evidence from clean VM validation:

- The shared backend was reset with `rm -f /dev/shm/cxl_mem` before the acceptance run.
- VM0 prepared the hybrid checkpoint:
  `hybrid-prepare key=81003 pages=3 verify=ok`.
- VM1 restored the hybrid checkpoint:
  `hybrid-restore key=81003 hot_orig=8000000105710827 cold_orig=800000010ac21807 dirty_orig=800000010ad2b847 hot_pfn=1079508 cold_pfn=5096449 dirty_pfn=1063771 verify=ok`.
- The restore output proves:
  - the hot page carried the checkpointed accessed bit;
  - the cold page did not carry the checkpointed accessed bit and stayed on the shared CXL PFN path;
  - the dirty page carried the checkpointed dirty bit and was already local before user access.
- Same-VM fd/global validation also passed after the descriptor investigation:
  `fdglobal-restore key=81002 policy=readonly fd=7 pos=11 flags=append cwd=/tmp umask=027 sigusr1=blocked verify=ok`,
  and the same check passed for MoW and MoA.

Regression validation:

- Kernel `bzImage` build passed.
- UAPI headers were refreshed from the O= build tree and cxlfork selftest rebuilt successfully.
- VM0, VM1 and localfork each passed ABI 9/9.
- VM1 readonly, MoW and MoA restore passed with Phase 7 CXL VMA lookup evidence.
- Phase 8 thread-context resume still passed for readonly, MoW and MoA.
- Phase 9 fd/global restore still passed for readonly, MoW and MoA in the same-VM filesystem-identity environment.
- failure tests passed.
- lifecycle tests passed.
- conflict test passed with `errno=17 guard=ok verify=ok`.
- 124 MiB prepare succeeded with `pages=31744` and `image_bytes=133443584`; 125 MiB prepare returned `ENOSPC`.
- Strict dmesg check on VM0/VM1/localfork was clean: no `BUG`, `WARNING`, `Oops`, `Call Trace`, cxlfork debug logs, cxlfork mmap/remap diagnostics, bad page map, bad pagetable, general protection fault, page fault, or `non-zero pgtables` warning.

Known limits after Phase 10:

- The accepted mechanism uses checkpointed PTE A/D bits as the policy source. It does not prove CXL hardware latency, bandwidth, NUMA-distance, cache-line, or dirty-prefetch performance benefits.
- `CXLFORK_PTE_MARK_V2` is a controlled test hook for constructing deterministic A/D-bit inputs; it is not a production migration API.
- Dirty prefetch is implemented as restore-time local prefault of pages whose checkpointed PTE has D=1. It does not yet include an asynchronous background worker or device-driven prefetch pipeline.
- The A-bit policy is meaningful for the current shared PTE leaf prototype, but full arbitrary-process A/D-bit semantics still depend on the supported checkpoint model and the real shared-leaf lifecycle limits documented in Phases 5 and 6.
- The old stride behavior is removed from the paper-mechanism path; any future synthetic policy must be explicitly reported as synthetic and not used as evidence for the paper's A-bit hybrid policy.

## Phase 11 accepted: per-call restore breakdown hygiene

Date: 2026-07-13 Asia/Shanghai.

Kernel commit: `b3c0fcdfaa5d` (`cxlfork: report restore breakdown per call`).

Scope accepted:

- Restore-time validation and mapping timings are now accumulated in a stack-local `cxlfork_restore_breakdown` for the current ioctl call.
- Restore no longer resets or reuses shared descriptor fields for per-call values such as direct PTE install time, PTE-page validation time, VMA-tree validation time, private-rebase validation time, or global attach time.
- Existing `pte_attach_ns/pages` are retained as legacy aliases but now mirror the explicitly named `pte_image_reconstruct_ns/pages`.
- Added explicit restore output fields:
  - `pte_image_reconstruct_ns/pages`
  - `shared_leaf_attach_ns/pages`
  - `dirty_prefault_ns/pages`
- `direct_pte_install_ns/pages` now report the current restore call's direct PTE work only. They include shared-leaf PMD install and fallback PFN remap work, rather than reading a mutable shared descriptor accumulator.
- Hybrid dirty prefault reports current-call dirty-prefault time and pages through the restore output.
- The selftest now verifies restore breakdown relationships:
  - readonly and MoW have direct install coverage for all restored pages;
  - readonly and MoW expose nonzero shared-leaf attach coverage when the shared-leaf path is used;
  - MoW reports PTE-image reconstruction pages and the legacy alias matches the new field;
  - MoA reports zero direct/shared/reconstruct pages for its fault-driven local-copy path;
  - hybrid reports exactly one dirty-prefault page in the controlled hot/cold/dirty test.

Hard evidence from clean VM validation:

- The shared backend was reset with `rm -f /dev/shm/cxl_mem` before the acceptance run.
- VM1 readonly restore reported:
  `direct_pages=1024 shared_leaf_pages=512 reconstruct_pages=0 verify=ok`.
- VM1 MoW restore reported:
  `direct_pages=1024 shared_leaf_pages=512 reconstruct_pages=1024 verify=ok`.
- VM1 MoA restore reported:
  `direct_pages=0 shared_leaf_pages=0 reconstruct_pages=0 verify=ok`.
- VM1 hybrid restore reported:
  `dirty_prefault_pages=1 verify=ok`.
- These outputs show that the measured paths are no longer collapsed into a single ambiguous attach counter and that unsupported/not-taken paths report zero instead of inherited shared descriptor values.

Regression validation:

- Kernel `bzImage` build passed.
- UAPI headers were refreshed from the O= build tree and cxlfork selftest rebuilt successfully.
- VM0, VM1 and localfork each passed ABI 9/9.
- VM1 readonly, MoW and MoA restore passed with Phase 7 CXL VMA lookup evidence and Phase 11 breakdown checks.
- Phase 10 hybrid A/D-bit restore passed with dirty-prefault breakdown evidence.
- failure tests passed.
- lifecycle tests passed.
- conflict test passed with `errno=17 guard=ok verify=ok`.
- 124 MiB prepare succeeded; 125 MiB prepare returned `ENOSPC`.
- Strict dmesg check on VM0/VM1/localfork was clean: no `BUG`, `WARNING`, `Oops`, `Call Trace`, cxlfork debug logs, cxlfork mmap/remap diagnostics, bad page map, bad pagetable, general protection fault, page fault, or `non-zero pgtables` warning.

Known limits after Phase 11:

- This phase fixes per-call accounting hygiene and naming for the current ioctl output. It does not add kernel tracepoints yet.
- `pte_attach_ns/pages` remain in the legacy UAPI as compatibility aliases. New analysis should use `pte_image_reconstruct_ns/pages` for software reconstruction and `shared_leaf_attach_ns/pages` for real shared-leaf PMD installation.
- Fault-time `faults`, `shared_map_pages`, `local_copy_pages`, and `leaf_copy_pages` remain descriptor-level lifecycle counters. They are not claimed as per-restore-call fields.
- Dirty-prefault accounting covers restore-time prefault of checkpointed D=1 pages. Fault-driven later local copies are still accounted by existing lifecycle counters, not by this restore-call field.
