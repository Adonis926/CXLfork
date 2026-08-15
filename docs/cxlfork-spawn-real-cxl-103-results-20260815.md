# CXLfork-spawn 103 真实 CXL 正式结果（2026-08-15）

## 1. 实验口径

本次实验使用 103 的真实 64 GiB `/dev/dax0.0`，CXLfork 使用 `[4,8) GiB`。
VM0/VM1 各 16 vCPU、16 GiB，分别固定 host CPU 48–63、64–79，私有 DRAM
绑定 NUMA node1。正式 workload 是固定 4 MiB、单线程、sealed MoW 的 V4
cooperative capsule。

比较的两条路径都经过 VM0 请求、VM1 forkserver、fresh child、退出、`waitpid()` 和
响应：

- `remote-cxlfork`：child 执行 `RESUME_CAPSULE_V4` 并从恢复的 continuation 继续；
- `remote-target-local`：child 使用 VM1 普通 fork 继承的等价匿名状态。

Prepare 和 VM 冷启动均在 steady-state 计时外单独记录。`remote_spawn_lps` 表示每秒
完成的远端 spawn 数，与 UnixBench Process Creation 的 lps 量纲一致，但不是
UnixBench workload 或 INDEX。

正式运行版本：

- main runtime HEAD：`a4dd387`；
- kernel HEAD：`f696e4e737698c4e1e5934a768232875dabb02a9`；
- guest bzImage SHA256：`09b4c7bf533be4fa505823f4229ddae23af8ed8f33fe0077849536dbc41bdd46`；
- static benchmark SHA256：`23b62d42af9a5cf05a162913db80d178e4d2f028c42840fd84ec6d0b78741a8e`；
- QEMU：9.0.90。

## 2. 验收结果

- 10 轮、每轮 100,000 次跨 VM atomic RMW、release/acquire 和 ping-pong 全部通过；
- 10,000 次连续 restore/exit 后 `readers=0`；
- V4 continuation、worker checksum 和状态消费全部 `verify=ok`；
- `shared_leaf_pfn=5260831 == current_pmd_pfn`；
- `shared_data_pfn=5259796 == current_data_pfn`；
- 8,737,450 条正式请求全部通过 supported/valid/path mask 与两层非重叠等式校验；
- guest dmesg error 文件为 0 字节；
- 结束后无 QEMU、KVM module 或 DAX holder，DAX mode/ACL 和 CPU governor 已恢复；
- 结果目录 250 个文件、约 3.8 GiB，`SHA256SUMS` 独立复核通过。

## 3. Spawn 吞吐

每点包含三个独立 30 秒 pass，表中为三轮 mean，括号内为总体标准差。

| lanes | remote-cxlfork lps | remote-target-local lps | CXLfork/local | 吞吐提升 |
|---:|---:|---:|---:|---:|
| 1 | 2,490.31 (24.41) | 2,155.83 (5.19) | 1.155× | 15.52% |
| 4 | 9,000.41 (5.72) | 7,967.73 (9.09) | 1.130× | 12.96% |
| 8 | 16,755.47 (23.26) | 14,992.16 (4.62) | 1.118× | 11.76% |
| 16 | 23,198.07 (10.74) | 20,522.80 (21.50) | 1.130× | 13.04% |

CXLfork 路径在该受限 workload 中快于 target-local，并不是“任意 remote fork 已经快于
Linux fork”。local forkserver parent 长期持有普通 4 MiB 匿名映射，fork 会复制/引用其
普通页表状态；CXLfork forkserver parent 不持有 capsule VMA，fresh child 在 fork 后通过
共享 leaf attach 获得状态。这正是本实验要隔离的数据路径差异。

## 4. CXLfork 路径 mean breakdown

单位均为微秒。`kernel restore` 是 `restore wall` 的子项，不能重复相加。

| lanes | RTT | VM0 residual | target total | fork→child | child setup | restore wall | kernel restore | continuation | exit/wait | shared-leaf attach |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | 401.44 | 108.60 | 292.84 | 80.66 | 7.71 | 8.35 | 3.55 | 130.73 | 62.75 | 0.197 |
| 4 | 444.30 | 130.87 | 313.43 | 81.93 | 8.21 | 9.36 | 4.24 | 132.40 | 78.61 | 0.219 |
| 8 | 477.34 | 147.84 | 329.50 | 86.59 | 8.52 | 9.65 | 4.38 | 134.76 | 86.94 | 0.240 |
| 16 | 689.59 | 318.60 | 371.00 | 106.23 | 8.76 | 10.27 | 4.81 | 137.78 | 104.71 | 0.264 |

关键占比：

| lanes | kernel restore / target total | restore wall / target total | VM0 residual / RTT |
|---:|---:|---:|---:|
| 1 | 1.21% | 2.85% | 27.05% |
| 4 | 1.35% | 2.99% | 29.46% |
| 8 | 1.33% | 2.93% | 30.97% |
| 16 | 1.30% | 2.77% | 46.20% |

## 5. 结论

1. 真实 CXL 上的 shared leaf attach 和受限 worker-state restore 确实发生，并且内核
   restore 已被压到约 3.6–4.8 微秒，只占目标端完整执行的约 1.2%–1.35%。
2. 即使数据页和 PTE leaf 已共享，fresh child 仍要经历目标 OS 的 fork/调度、child
   setup、continuation 的真实状态消费、退出和 wait/reap；这些合计远大于内核 restore。
3. 并发从 1 增至 16 lanes 时，内核 restore 只增加约 1.25 微秒，而 VM0 residual 从
   108.6 微秒增至 318.6 微秒，占 RTT 的比例从 27.1% 增至 46.2%。跨 VM 协议、排队和
   两侧调度缝隙是高并发下更明显的瓶颈。
4. 结果支持项目的研究动机：共享数据和 worker state 不等于远端执行上下文已经可以
   直接运行；当数据面 restore 足够快后，跨 OS 的执行上下文创建和控制路径成为主要开销。

91 file-sim 与 103 real-DAX 的绝对数值不能直接相减后全部归因于 CXL 介质，因为 host、
QEMU、KVM、NUMA 和 CPU 环境不同。论文分析应优先使用 103 内部两条同构路径的差值、
breakdown 占比和随 lanes 的趋势。

## 6. 数据位置

远端权威结果：

```text
/home/xtl/start/hpca-cxlfork/results/cxlfork-spawn/
  formal-20260815T1027Z-103-real-dax/
```

本地完整备份：

```text
/home/adonis/cxlfork/cxlfork-spawn-results/
  formal-20260815T1027Z-103-real-dax/
```

优先查看：

- `throughput-summary.csv`：主吞吐数据；
- `passes.csv`：24 个独立 pass；
- `summary.csv`：各 breakdown 的 mean/P50/P95/P99/stddev；
- `raw.csv`、`raw/`：8,737,450 条逐请求原始证据；
- `gates/`：atomic/coherence、PFN 和 churn 证据；
- `manifest.txt`、`logs/`、`SHA256SUMS`：版本、环境、错误检查和完整性。
