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
| 5. Fixed concurrency | complete | MR `349180f` | async porter submit/collect and batched master dispatch run four fixed ghosts concurrently; reader count reaches four; eight one-shot reducer PIDs use shared leaves with zero fallback; undersized shuffle connection configuration fails explicitly; output and dmesg pass |
| 6. Measurement and correctness closure | complete | MR `debcb1b` | versioned task-result envelope, non-overlapping task sub-interval, standard static runner, raw/summary CSV and 30-sample four-mode matrix pass; active/stale/release regression and dmesg pass |
| 7. Final 91 acceptance and 103 profile | complete | main `3e81659` | four-policy smoke, final caps/build/cleanliness/dmesg checks and local backup pass; safe non-overlapping real-DAX launcher profile is documented but deliberately not run on occupied 103 host |
| 8. Application-state binding | complete | MR `efb9706`, `6311b3e` | template v2 contains WordCount state consumed by map/hash/reduce; scale=2 changes output exactly; corrupt/wrong-role/stale cases fail with evidence; readers, dmesg and cleanup pass |

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

## Stage 5 evidence

- Local functional run: `/tmp/mr-stage5-local2-1548422`.  A 3.36 MiB input was
  split into 13 map tasks, followed by eight reducers.  Four fixed workers ran
  in each role; all 13 localfork mapper PIDs and all eight local-prefork reducer
  PIDs were one-shot, and normalized WordCount output matched the independently
  generated expected file.
- Cross-VM CXLfork run: `/tmp/mr-stage5-cxl-1549004`.  With a 1,000 ms test
  hold, `INSPECT` observed `readers=4` at once.  Eight reducer tasks used eight
  distinct PIDs; every restore reported path mask 5, 1,024 shared-leaf pages
  and zero fallback pages.  Readers returned to zero and release succeeded.
- The first concurrency probe identified an old serial-only assumption: all
  reducers shared response connection zero.  The accepted implementation binds
  each reducer worker to a stable HydraRPC connection and requires
  `shuffle-connections >= workers`; an intentionally undersized 4-worker/1-
  connection agent exits with status 2 instead of hanging.
- The porter supervisor is now event driven: dispatch commands mark individual
  worker slots in flight, completions may be returned out of order, and the
  agent main loop alone owns HydraRPC response publication.  The master batches
  at most one task per fixed worker and demultiplexes by task/partition ID.
- Both build variants and both guest dmesg scans passed, with no residual
  `mr_hydra` process.

## Stage 6 evidence

- Final dataset: `/home/xtl/cxlfork/mr-static-results/stage6-30-final` on
  10.0.16.91.  It contains four identical 30-sample experiments (plus five
  warmups): `persistent`, `localfork`, `local-prefork`, and `cxlfork`.
  `verify=all` passed for every measured sample.  Each mode includes
  `runs.csv`, `tasks.csv`, `task_summary.csv`, result JSON/env and raw logs.
- End-to-end mean/P50/P95/stddev in milliseconds were: persistent
  361.367/361.000/371.000/5.642; localfork
  365.067/365.000/378.000/7.728; local-prefork
  365.667/366.500/378.000/7.494; and CXLfork
  357.167/356.000/375.000/8.238.  These figures include SSH-launched agent
  setup/teardown and the full MR/Hydra control path; they are not kernel-only
  restore latency.
- Across 120 measured CXLfork reducer tasks, mean task callback time was
  12.888 ms, porter total 13.133 ms, restore ioctl wall time 44.759 us,
  kernel-reported restore total 12.626 us, and ghost refill 69.745 us.  Every
  task reported path mask 5, 1,024 shared-leaf pages, zero fallback pages and
  a distinct one-shot PID for that task invocation.
- At this historical revision, the response began with fixed-size
  `mr_task_result_v1` and was validated by
  magic, size, version and zero reserved fields before master strips it from
  the business payload.  `task_ns` measures only the application callback;
  restore, template validation, reap and refill are separate sub-intervals,
  while `porter_total_ns` is the outer inclusive interval.
- The standard `scripts/run-bench.sh` accepts the fixed worker descriptor
  `HOST,MASTER_PATH,AGENT_PATH,ROLE,LAUNCH,WORKERS`, produces raw per-call
  `tasks.csv`, mean/P50/P95/stddev task summaries, and never reports P99 for
  the 30-sample matrix.
- Lifecycle regression `/tmp/mr-stage3-life-1578120` confirmed active release
  returns `EBUSY`, stale generation fails the job without leaking a reader,
  reader count returns to zero, and matched release succeeds.  Final template
  generation 14 was also observed with zero readers and released.  Both guest
  dmesg scans and residual-process checks passed.

## Stage 7 evidence

- Policy dataset: `/home/xtl/cxlfork/mr-static-results/stage7-policies`.
  Readonly and MoW each used path mask 5 with 1,024 shared-leaf pages and zero
  fallback.  MoA used path 17 and copied the one header page touched by fast
  validation.  Hybrid used path 33; no page happened to be promoted by this
  header-only smoke.  All four modes produced correct WordCount output and the
  shared template released with zero readers.
- Both final build variants pass.  VM0 and VM1 report identical ABI 2 caps
  (`capabilities=31711`, 4 KiB page, 2 MiB shared-leaf alignment, seven 512 MiB
  slots); the CXL-disabled build rejects caps with status 2 instead of claiming
  support.
- The launcher now supports a CXL backing offset and Hydra base offset, checks
  range overlap, refuses automatic reset of non-regular backing objects, and
  requires `BACKEND_RESET=none` when both planes share one real DAX device.
  Default 91 layout validation and a proposed disjoint 103 layout pass; an
  intentionally overlapping layout fails.  Default 91 values are unchanged.
- `docs/mr-cxlfork-103-migration-profile.md` records the proposed first 8 GiB
  layout and gated migration order.  It is explicitly unvalidated: 103 was not
  contacted or modified because another group was using it.
- Stage 7 froze MR `debcb1bda938f8a02021067d5cfa661896463d32`; Stage 8 advances
  MR to `6311b3e0cf2d3340f3ed6ec84a7f56124ee85e58`.  Kernel remains
  `15ae46586aaff49c5f6b72271da8b5833899132a`; kernel and legacy cxlporter were
  untouched.
- Important code, diffs, acceptance documents, the complete 30-sample matrix,
  and policy results are copied to the local jump-host backup directory
  `/home/adonis/cxlfork/backups/mr-cxlfork-static-20260716`.

## Stage 8 evidence

- Implementation commits: MR `efb9706375bcc293526891c1234360a199db20a1`
  makes template v2 state mandatory; MR
  `6311b3e0cf2d3340f3ed6ec84a7f56124ee85e58` adds failure-envelope retention,
  automated acceptance and documentation.  Kernel and HydraRPC were unchanged.
- `MR_WorkerStateV1` stores the ASCII word-character table, lowercase table,
  digit table, partition hash parameters, value radix/scale, role, version,
  checksum and reserved fields.  Mapper, default partitioner and Reducer call
  `MR_GetWorkerState()` and use these values.  A callback that does not consume
  state cannot set all required binding flags and the porter returns failure.
- The wire result is now the strict 232-byte `mr_task_result_v2`.  Successful
  rows contain state/access checksums, nonzero access count, one state page and
  `template_binding_flags=15`.  Failed porter tasks retain the same versioned
  envelope rather than being printed as a binary error string.
- Automated command: `scripts/test-state-binding.sh`.  Authoritative results:
  `/home/xtl/cxlfork/mr-static-results/state-binding-acceptance`.
- Normal scale=1: `status=ok`, `correctness=ok`; both reducers used path 5,
  1,024 shared-leaf pages, zero fallback, state checksum
  `16711033182850390991`, 512 state acquisitions, one state page and flags 15.
- Semantic-dependency test: a valid scale=2 checkpoint used state checksum
  `3234589969764740584`; every expected WordCount value doubled exactly and
  the run passed `verify=all`.  This proves that a fake/no-op restore cannot
  be substituted while preserving the accepted task semantics.
- Corrupt state and wrong-role checkpoints reached the worker but were both
  rejected with status 84 (`EILSEQ`), zero application-access evidence and no
  output.  A stale generation was rejected with status 116.  Each failure
  returned reader count to zero and preserved its failure row in `tasks.csv`.
- VM0/VM1 report identical CXLfork caps.  Both CXL-enabled and disabled builds
  pass; final dmesg logs are empty for BUG/WARNING/Oops/bad-pagetable/panic
  patterns; no worker remains; test key 2002 is released.
- The older 30-sample Stage 6 matrix predates this binding and remains a
  historical control-path baseline.  Publication performance numbers for the
  current system must be rerun from MR `6311b3e` or later.
