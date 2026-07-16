# 10.0.16.103 real-CXL migration profile

## Status and safety boundary

This is a configuration profile, not an acceptance record.  The machine was
not contacted during the static MR+CXLfork closure because another group was
using it.  No VM, DAX mode, device content, repository, or process on
10.0.16.103 was changed.

The reported device is `/dev/dax0.0`, 64 GiB (68,719,476,736 bytes), 2 MiB
aligned, devdax mode, target NUMA node 2.  Reconfirm all of those facts and
coordinate exclusive ownership before migration.  Never run `dax_zero`,
`daxctl reconfigure-device`, `rm`, or `truncate` while another user or VM may
hold the device.

## Proposed static layout

Use one physical DAX object with non-overlapping, 2 MiB-aligned QEMU offsets:

| Consumer | Byte range | Size |
| --- | ---: | ---: |
| HydraRPC endpoint 0 | `[0, 2 GiB)` | 2 GiB |
| HydraRPC endpoint 1 | `[2 GiB, 4 GiB)` | 2 GiB |
| CXLfork shared NVDIMM backend | `[4 GiB, 8 GiB)` | 4 GiB |
| Unassigned / future experiments | `[8 GiB, 64 GiB)` | 56 GiB |

The first migration should keep the same guest-visible sizes, fixed worker
count, CXLfork kernel, addresses, slot format, and UAPI as the validated 91
environment.  Only the host backing path and offsets change.  This isolates
hardware effects from software changes.

## Launcher profile

The launcher on `cohort-mr-cxlfork-static` supports offsets and refuses
overlap.  With both VMs stopped and exclusive device ownership confirmed, the
intended environment is:

```bash
export CXL_FILE=/dev/dax0.0
export CXL_BACKEND_OFFSET=4G
export CXL_BACKEND_SIZE=4G

export HYDRA_SHM_FILE=/dev/dax0.0
export HYDRA_BACKEND_OFFSET=0
export HYDRA_ENDPOINT_SIZE=2G
export HYDRA_ENDPOINT1_OFFSET=2G

# Mandatory for device-backed operation.  The launcher must not delete,
# truncate, or zero a DAX character device.
export BACKEND_RESET=none

scripts/start-cxlfork-vms.sh check
```

The check must print `backend_layout_ok` before any VM is started.  An overlap
is a hard error.  The default 91 profile remains unchanged and continues to
use `/dev/shm/cxl_mem` and `/dev/shm/cxlmem` as two ordinary files.

## Migration acceptance order

1. Record `git status`, branch, commit, kernel hash, QEMU version, `daxctl
   list`, `numactl --hardware`, ownership and device mode.  Stop if the checkout
   or exclusive-ownership assumption is false.
2. Stop both experiment VMs.  Only after explicit coordination, clear the
   reserved ranges or the full device with the site-approved tool.  Do not
   embed destructive clearing in the launcher.
3. Run launcher `check`, start VM0/VM1, and verify guest BDF/resource sizes,
   `/dev/cxlfork`, cmdline physical range, caps, and cross-VM template inspect.
4. Run one-worker WordCount in persistent, localfork and CXLfork modes; verify
   every output, generation/refcount release, and dmesg.
5. Run the four-worker concurrent-reader test and require `readers=4`, path
   mask 5, 1,024 shared-leaf pages and zero fallback for the 4 MiB template.
6. Run the policy smoke and then the 30-sample matrix.  Store 103 results in a
   new directory; never overwrite the 91 baseline.

Real hardware changes the backing medium and performance interpretation, but
does not remove the need for QEMU to expose the same physical range coherently
to both guests.  Passing `daxctl` alone is not proof that the guest MMU used a
shared CXLfork leaf; the existing path/PFN/page and lifecycle evidence remains
required.
