# Static MR + CXLfork acceptance log

## Scope

This branch integrates the lifecycle of the existing restricted CXLfork data
plane into the HydraRPC MapReduce worker path.  It does not reuse the existing
OpenWhisk/CXLporter implementation and does not claim transparent restoration
of an arbitrary process, thread context, file-descriptor graph, or container.

The new MR-specific porter uses fixed roles, a fixed worker count, fixed-size
ghost pools, and a fixed-address private-anonymous template arena.  Runtime
worker scaling and migration are out of scope.

## Frozen revisions

- main repository start: `352a1fe` (`hydrarpc-file-sim`)
- MR repository start: `0172795` (`master`)
- development branch in both repositories: `cohort-mr-cxlfork-static`
- kernel: `15ae46586aaff49c5f6b72271da8b5833899132a`
- HydraRPC source snapshot: `eb185de17f16f138db2ae64176a892a33dd54d18`
- legacy CXLporter: retained unchanged and not linked by the MR implementation

## Environment layout

The 10.0.16.91 functional environment keeps the two data planes disjoint:

- `/dev/shm/cxl_mem`: 4 GiB CXLfork NVDIMM backend
- `/dev/shm/cxlmem`, offset 0: 2 GiB HydraRPC endpoint 0
- `/dev/shm/cxlmem`, offset 2 GiB: 2 GiB HydraRPC endpoint 1

The existing kernel and V2 UAPI are authoritative.  Kernel changes are not
planned; a kernel branch will be created only for a separately reproduced
kernel defect.

## Stage status

| Stage | Status | Revisions/artifacts | Acceptance |
| --- | --- | --- | --- |
| 0. Branch and baseline freeze | complete | main `352a1fe`, MR `0172795` | clean branches created and pushed |
| 1. V2 adapter and template publisher | complete | MR `2eef97d` | CXL/on-off builds pass; VM caps match; map/reduce 4 MiB publish and cross-VM checksum pass; unaligned and same-slot cases fail explicitly; dmesg clean |
| 2. MR porter local lifecycles | complete | MR `8231ede` | persistent/localfork/local-prefork pass with 1 and 2 workers; WordCount output matches; dual-VM ivshmem smoke passes; no residual processes; dmesg clean |
| 3. Serial CXLfork ghost restore | complete | MR `aa58e8d` | four reducer tasks each restore in a new ghost; path mask 5, 1024 shared-leaf pages, zero fallback; stale generation fails; active release is EBUSY; final readers zero and release succeeds; dmesg clean |
| 4. Static map/reduce placement | complete | MR `e41a516` | `role-static` sends all map work to VM0 and all reduce work to VM1; agent role checks reject a map-to-reducer mismatch; four reducer restores use shared-leaf path 5 with zero fallback; output, cleanup and guest dmesg pass |
| 5. Fixed concurrency | pending | | |
| 6. Measurement and correctness closure | pending | | |
| 7. Final 91 acceptance and 103 profile | pending | | |

Each completed stage must build, run its success/boundary/failure tests, and
check both guest kernels for BUG/WARNING/Oops/bad-page-table signatures before
the next stage begins.

## Stage 4 evidence

- Success run: `/tmp/mr-stage3-1545603` on the 10.0.16.91 host.  Despite the
  historical directory prefix, this run uses `--schedule=role-static`.
- Placement: VM0 agent is `role=map,launch=localfork`; VM1 is
  `role=reduce,launch=cxlfork`.  The four reducer tasks restored IDs 17--20,
  each reported `path_mask=5`, 1,024 shared-leaf pages and zero fallback pages.
- Lifecycle: the published reducer template was generation 7, readers returned
  to zero after the run, and generation-matched release succeeded.
- Failure boundary: `/tmp/mr-stage4-role-1545752` deliberately configured
  agent 0 as reduce-only; the role-static map request was rejected, the master
  exited nonzero, no output was published, and both agents shut down cleanly.
- Both CXL-enabled and CXL-disabled builds passed.  VM0 and VM1 had no matching
  BUG, WARNING, Oops, bad-page-table, general-protection-fault or panic record,
  and no `mr_hydra` process remained.
