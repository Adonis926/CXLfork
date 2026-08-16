# CXLfork Spawn vCPU Scaling Results on Real CXL

The accepted scale subset is 8, 16, 32, 64 and 80 total guest vCPUs. VM0 and
VM1 receive half of the total budget and request lanes equal VM1 vCPUs. New
points use five 30-second `remote-cxlfork` passes on `/dev/dax0.0`.

| total vCPU | lanes | mean lps | lps/total-vCPU | RTT us | residual us | residual/RTT | kernel restore us |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 8 | 4 | 8,399 | 1,050 | 476.1 | 190.4 | 40.0% | 4.35 |
| 16 | 8 | 14,252 | 891 | 561.2 | 243.5 | 43.4% | 4.57 |
| 32 | 16 | 22,751 | 711 | 703.1 | 327.2 | 46.5% | 4.67 |
| 64 | 32 | 34,845 | 544 | 918.3 | 540.8 | 58.9% | 5.07 |
| 80 | 40 | 33,692 | 421 | 1,187.1 | 819.1 | 69.0% | 4.70 |

Throughput peaks at 64 total vCPUs and regresses by about 3.3% at 80. Kernel
restore remains 4.35--5.07 us and 1.28--1.52% of target total. The scaling loss
is instead associated with cross-VM/client residual growth from 190 to 819 us.

All points place VM0 on node0 and VM1 on node1 with one vCPU per distinct
physical core. Cohort comparisons remain preliminary because UnixBench Process
Creation and the restricted CXLfork capsule are not identical workloads.

Full results and the Chinese explanation are backed up under
`/home/adonis/cxlfork/cxlfork-spawn-results/scale-total-vcpu-20260816/`.
