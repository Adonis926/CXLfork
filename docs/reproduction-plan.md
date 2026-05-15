# CXLfork Reproduction Plan

## Goal

Reproduce the core mechanisms of CXLfork in a nested virtualization environment before attempting performance-oriented evaluation:

1. Shared CXL-like memory visible to two OS instances.
2. Checkpoint of process private state into shared memory.
3. Restore on another node by attaching shared read-only state.
4. Migrate-on-write semantics for modified pages.
5. Minimal global state reconstruction for files and namespaces.

## Current Base

The environment already has two QEMU/KVM VMs sharing the same host memory-backed device. Both guests see the device as `/dev/dax0.0`, and cross-VM byte visibility has been validated.

The host currently runs Ubuntu kernel `6.8.0-110-generic`, while the CXLfork development baseline has been downloaded as Linux `6.6.32` under `/home/xtl/cxlfork-ws/kernel/linux-6.6.32`.

## Implementation Path

Phase 0: Environment hardening

- Fix the guest data NIC naming mismatch. Cloud-init expects `ens4`, but the guest currently exposes `enp0s3`.
- Add repeatable scripts to start, stop, validate DAX, and validate cross-VM sharing.
- Keep a clean Linux 6.6.32 baseline and export all changes as patches.

Phase 1: User-space semantic prototype

- Define a checkpoint object layout in `/dev/dax0.0`.
- Store process memory pages and metadata with offsets instead of local pointers.
- Restore in VM1 by mapping the shared state read-only.
- Use a fault handler prototype to copy a page locally on write.

Phase 2: Kernel checkpoint/restore prototype

- Add an ioctl-based kernel interface for checkpoint and restore.
- Traverse VMAs and page tables for a restricted process model.
- Copy private pages to the shared DAX region and rewrite metadata references as offsets.
- Restore by creating local top-level page-table structures and attaching CXL-backed read-only leaves where possible.

Phase 3: CXLfork semantics

- Implement migrate-on-write in the page fault path.
- Track shared CXL pages versus local migrated pages.
- Add minimal global state serialization for files first, then expand only if needed.
- Add tiering modes: migrate-on-write first, migrate-on-access later, hybrid only after access-bit accounting is reliable.

Phase 4: Evaluation

- Compare against local fork and CRIU-like checkpoint/restore baselines.
- Measure restore latency, first-write latency, memory consumption, and scaling with multiple clones.
- Treat QEMU/NVDIMM numbers as functional validation, not real CXL latency results.

## Main Engineering Risks

- QEMU NVDIMM shared files validate shared byte visibility but do not fully model CXL.cache/CXL.mem coherence timing.
- Linux page-table and VMA internals are version-sensitive, so development should stay pinned to Linux 6.6.32.
- Correct copy-on-write semantics matter more than early performance numbers.
- Full container integration should wait until the process-level primitive is stable.

