# CXLfork Reproduction Workspace

This workspace tracks the QEMU/KVM environment, scripts, notes, and patch artifacts for reproducing CXLfork-style remote fork over shared CXL-like memory.

The Linux 6.6.32 source tree is kept under `kernel/linux-6.6.32` and intentionally ignored by the top-level project repository. Kernel changes should be committed in the kernel tree itself or exported as patches under `patches/`.

## Current Environment

- Host: `xtl@10.0.16.104`
- Workspace: `/home/xtl/cxlfork-ws`
- VM0: `localhost:2200`, hostname `cxlfork-node0`
- VM1: `localhost:2201`, hostname `cxlfork-node1`
- Shared memory: host `/dev/shm/cxl_mem`, exposed to both guests as `/dev/dax0.0`
- Kernel source baseline: Linux `6.6.32` in `kernel/linux-6.6.32`

## Development Rule

Keep generated VM artifacts, disk images, logs, and downloaded kernel tarballs out of git. Track source patches, scripts, experiment notes, and reproducible commands.

