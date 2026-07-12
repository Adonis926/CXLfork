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
