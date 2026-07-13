# Cohort control-plane acceptance

## Accepted revisions

The final benchmark was produced from these measured revisions:

- main repository: `793a7bd0c30398168cb936e39e8dc6aab7b57494`
- kernel: `15ae46586aaff49c5f6b72271da8b5833899132a`
- CXLporter: `ced2c8eb6e1bfef89a2e39cf43dcbd1e2f00d488`
- OpenWhisk standalone build: `7ef091c`

The development branches are `cxlfork-cohort-openwhisk` in the main and
CXLporter repositories and `cxlfork-kernel-paper-alignment` in the kernel.

## Acceptance artifacts

- correctness:
  `cxlporter/results/control-correctness-20260713-175411`
- final benchmark:
  `cxlporter/results/cohort-control-20260713-175429`
- pre-audit runs `172616`, `173220`, and `174850` are retained only as
  diagnostics.  The first exposed the OpenWhisk 60/minute throttle; the next
  two exposed and verified fixes for shared-leaf page accounting and missing
  `NA`/breakdown fields.  They are not the final paper dataset.

Correctness passed checkpoint/register, direct and OpenWhisk invocation,
stale generation, missing function, malformed request, 16 concurrent restores,
active-reader release rejection, release after the reader exits, and VM0/VM1
dmesg checks.  The direct evidence line reported `path_mask=5`,
`shared_leaf_pages=1024`, and no fallback for a 4 MiB MoW restore.

The final benchmark contains 9,400 rows and 62 schema-v2 columns:

- 6,200 direct requests and 3,200 OpenWhisk requests;
- 1,000 samples for each micro and concurrency group;
- 100 samples per footprint/policy/path scaling group;
- 4, 64, and 192 MiB footprints;
- MoW, MoA, Hybrid, restore-only, and cold modes.

All 9,400 rows have `status=0` and `verify=1`.  Every restore row matches its
checkpoint generation and page checksum.  Shared-leaf coverage is exactly
1,024, 16,384, or 49,152 pages according to footprint.  Fallback reconstruction
is `NA` in every final sample.  VM0 and VM1 dmesg contain none of the configured
BUG/WARNING/Oops/bad-pagetable signatures.

## Main results

The 4 MiB, pool-4 micro results are in milliseconds:

| Path and mode | N | Mean | P50 | P95 | P99 |
| --- | ---: | ---: | ---: | ---: | ---: |
| Direct, invoke | 1000 | 0.584 | 0.474 | 1.025 | 1.072 |
| OpenWhisk, invoke | 1000 | 6.637 | 5.654 | 12.762 | 15.718 |
| Direct, restore-only | 1000 | 0.611 | 0.538 | 1.028 | 1.100 |
| OpenWhisk, restore-only | 1000 | 6.978 | 5.675 | 13.890 | 16.704 |

For the OpenWhisk invoke path, mean action bridge RTT is 0.919 ms, daemon time
is 0.156 ms, restore ioctl time is 0.030 ms, and kernel restore time is
0.019 ms.  OpenWhisk reports mean wait time 2.648 ms and duration 2.678 ms at
millisecond resolution.  The large gap between kernel restore and end-to-end
latency is the control-plane opportunity that this baseline was built to
expose; nested intervals must not be summed.

Mean direct-path scaling results are:

| Footprint | MoW E2E | MoW kernel restore | MoA E2E | Hybrid E2E |
| ---: | ---: | ---: | ---: | ---: |
| 4 MiB | 0.612 ms | 0.010 ms | 3.978 ms | 2.304 ms |
| 64 MiB | 0.835 ms | 0.017 ms | 34.510 ms | 15.560 ms |
| 192 MiB | 2.186 ms | 0.046 ms | 106.777 ms | 52.389 ms |

MoW shared-leaf attach itself grows from 0.0022 ms to 0.0087 ms and 0.0337 ms
as the number of 2 MiB leaves grows.  It does not scan every 4 KiB PTE on the
default restore path.  MoA moves CXL-to-local copy into first access (mean copy
time 0.480, 9.424, and 36.949 ms), while Hybrid moves its selected prefetch work
into restore (1.203, 12.804, and 46.238 ms).  These are different policies and
must not be presented as the same fast path.

Checkpoint totals for 4, 64, and 192 MiB were 7.387, 116.765, and 351.860 ms.
The current full checksum seal accounted for 5.949, 94.293, and 282.719 ms;
this is deliberate correctness validation overhead and should be reported
separately from steady-state remote invocation.

The direct concurrency files reached 1,518 requests/s with one worker and
5,566 requests/s with eight workers by run makespan.  The pool-4 file contains
two approximately 1.05 s client-side TCP outliers that do not appear in daemon
time; its P50/P95 are 0.608/1.000 ms but its makespan throughput is only
838 requests/s.  This run is retained rather than silently trimming outliers,
and it should be treated as evidence of host/QEMU control-path jitter, not as a
clean pool-size scaling curve.

## Interpretation limits

- The benchmark uses a real OpenWhisk HTTP/action/container path and a real
  cross-VM CXLfork restore, but the Node action proxies to a synthetic C
  function worker.  It is not arbitrary language-runtime continuation.
- The read-only `touch` workload does not exercise leaf or data CoW.  The final
  CSV correctly records those fields as `NA`; separate kernel tests supply the
  CoW evidence.
- Default data-plane runs do not enable global or thread restore, so their
  fields are `NA` and cannot be used to claim full process restoration.
- Scaling groups have 100 samples and do not report P99.  Only the 1,000-sample
  micro/concurrency groups report P99.
- QEMU `/dev/shm/cxl_mem` cannot support absolute claims about real CXL fabric
  latency, bandwidth, NUMA distance, or cache behavior.

