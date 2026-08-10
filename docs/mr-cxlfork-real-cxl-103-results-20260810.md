# HydraRPC + CXLfork + MapReduce：103 device-DAX 测试结果

## 1. 测试目的和结论

本轮测试在 `xtl@10.0.16.103` 上把 MR 双 VM 的共享后端从 91 的普通文件
换成真实 `/dev/dax0.0`，验证当前系统的 correctness、CXLfork fast path 和
控制路径 breakdown。它回答的核心问题不是“CXLfork 是否比所有方案快”，
而是：共享数据和页表以后，从跨 VM 请求到 worker 真正开始执行业务还剩多少
软件控制开销，以及内核 restore 占其中多少。

正式 MoW 结果的三轮均值约为：

| 路径 | 完整 activation roundtrip | 说明 |
| --- | ---: | --- |
| persistent | 28.13 us | 已存在 worker，不创建新执行上下文 |
| localfork | 348.23 us | 目标端普通 fork 路径 |
| local-prefork | 364.10 us | 当前静态 pool 的取用、reap 和 refill 全部计入 |
| CXLfork preopen | 288.55 us | `/dev/cxlfork` 和 capability 已预打开 |
| CXLfork per-request | 287.17 us | 每次请求执行 open/caps/policy setup |

CXLfork-preopen 中，`kernel_total` 三轮分别是 7.11、7.04、7.06 us，平均约
7.07 us，只占 288.55 us 完整 activation 的约 2.45%。同一条路径中，
`target_to_state_ready` 约 25.8 us、restore wrapper 约 11.9 us，而完成后的
reap 和 pool refill 分别约 68.7 us 和 156.6 us。由此可见，当前数据面已经
很短，主要余量位于目标端执行上下文管理和控制生命周期，而不是 restore
ioctl 本身。

这些字段存在包含关系，不能相加：roundtrip 包含 HydraRPC server stack；
server stack 又覆盖 target activation、reap/refill；restore wrapper 包含
resume ioctl，resume ioctl 包含 kernel total。`summary.csv` 是用于横向查看
同一边界的统计表，不是把所有行相加的账单。

## 2. 实际环境和共享布局

- host：`Lux`，Linux `6.6.32-shm+`，QEMU 9.0.90，KVM/EPT；
- DAX：`/dev/dax0.0`，64 GiB、2 MiB 对齐、target node 2；
- `[4,8) GiB`：CXLfork NVDIMM window；
- `[8,10) GiB`：HydraRPC endpoint 0，guest BDF `00:02.0`；
- `[10,12) GiB`：HydraRPC endpoint 1，guest BDF `00:03.0`；
- 两个 guest 各有独立 16 GiB DRAM 和 16 vCPU，只共享上述三个 window。

QEMU `/proc/<pid>/maps` 已证明两台 VM 同时映射同一 DAX 文件偏移。guest 看到
的是 NVDIMM 与 ivshmem，不是原生枚举的 CXL Type-3 PCI 设备。host 上有
Montage CXL 2.x 设备，但 dax0.0 由 `hmem.0`/device-dax 暴露，标准 sysfs 中
没有可追踪的 `cxl_region` 链；因此本结果应准确称为“103 真实 device-DAX
后端上的 CXL host 实验”，不能把 91/103 的差值全部解释为 CXL 介质延迟。

## 3. 正确性与真实性门槛

以下项目全部通过：

- 跨 VM atomic RMW、release/acquire message passing 和 coherent ping-pong：
  10 轮，每轮 100,000 次；
- V2 ABI 正反测试：两台 guest 各 17/17；
- checksum、stale generation、slot collision、active-reader release、失败
  rollback、fd 关闭后的 restore context 生命周期和 unsupported MM fail-fast；
- readonly restore 的 `current_pmd_pfn == shared_leaf_pfn`；
- MoW 首写后 data PFN 和 PMD leaf PFN 均变为本地，第二次写不重复 CoW；
- MoA、Hybrid、dirty prefault 和应用状态 binding；
- shared leaf A-bit 独立 feasibility：读访问后 PTE 从 `...a05` 变为 `...a25`，
  本环境结果为 `verified`；
- 独立 raw 审计中 MoW/readonly fast path 为 path 5、full validation 为 path 6、
  MoA 为 path 17、Hybrid 为 path 33，所有 fallback pages 均为 0；
- 所有 slot reader 清零，两台 guest dmesg 无 CXLfork/BUG/WARNING/Oops 错误。

这证明的是受限匿名地址空间模板、真实共享 PTE leaf 和应用状态绑定路径，
不是任意 Linux 进程从保存 IP/SP 透明继续执行。

## 4. 对照实验

| 对照 | 样本 | roundtrip mean | kernel mean | 解释 |
| --- | ---: | ---: | ---: | --- |
| MoW fast，4 MiB | 3×1000 | 288.55 us | 7.07 us | 正式主路径 |
| MoA fast，4 MiB | 1000 | 292.50 us | 5.54 us | 业务仅首次访问状态页时本地复制 |
| readonly fast，4 MiB | 1000 | 295.02 us | 9.02 us | 保持共享只读页 |
| Hybrid fast，4 MiB | 1000 | 1032.39 us | 612.97 us | 模板页均 dirty，restore 时 prefault 1024 页 |
| MoW full validation，4 MiB | 1000 | 7466.34 us | 7151.95 us | 每次扫描 1024 PTE |

full validation 比 fast restore 慢约三个数量级，证明默认性能路径不能在每次
restore 时逐 PTE 扫描整个 image。Hybrid 较慢不是 shared-leaf 失败，而是
当前 WordCount template 的全部 1024 页都被写脏，策略按设计执行 dirty
prefault。

footprint scaling 的结果为：

| template | PTE leaf/restore | roundtrip mean | kernel mean | publish/checkpoint mean（约） |
| --- | ---: | ---: | ---: | ---: |
| 4 MiB | 2 | 288.78 us | 7.09 us | 8.8 ms |
| 64 MiB | 32 | 298.43 us | 11.15 us | 140 ms |
| 256 MiB | 128 | 327.31 us | 23.51 us | 562 ms |

checkpoint 是模板发布的一次性成本，不属于每次 restore roundtrip。fast restore
随 PTE leaf 数增加，但没有按 4 KiB page 数退化成 full-validation 的毫秒路径。

## 5. 真实 WordCount job

沿用 91 基线的 256,000-byte 输入，输入和 expected 的 SHA256 固定在
`/home/xtl/start/hpca-cxlfork/workloads/wordcount-91-baseline/SHA256SUMS`。
localfork 与 CXLfork-preopen 正序/逆序交错各运行 100 个独立 job：

| 模式 | n | mean | P50 | P95 |
| --- | ---: | ---: | ---: | ---: |
| CXLfork-preopen | 100 | 44.514 ms | 44.463 ms | 45.090 ms |
| localfork | 100 | 44.763 ms | 44.734 ms | 45.263 ms |

200/200 个 `output.diff` 为空。每种模式只有 100 个独立 job，因此不报告 P99。
该 workload 的约 44 ms 业务总时长远大于约 7 us kernel restore；这个结果用于
证明功能和端到端占比，不应被解读为通用 WordCount 性能结论。

## 6. 原始数据位置

103 的权威原始结果：

- litmus：`/home/xtl/start/hpca-cxlfork/results/real-dax-litmus-20260810T082441Z.log`；
- 状态绑定：`.../real-dax-state-binding-20260810T082516Z/`；
- 内核正确性：`.../real-dax-kernel-correctness-20260810T082852Z/`；
- smoke：`.../real-dax-motivation-smoke-20260810T083135Z/`；
- 正式三轮：`.../real-dax-core-r1-20260810T083212Z/`、
  `r2-20260810T083617Z/`、`r3-20260810T084014Z/`；
- policy/validation/scaling：`.../real-dax-secondary-20260810T084427Z/`；
- WordCount：`.../real-dax-wordcount-20260810T085254Z/`；
- 最终环境与独立审计：`.../real-dax-final-audit-20260810T091100Z/`。

每个正式目录都保留 `tasks.csv`、`summary.csv`、metadata、run manifest、
validation JSON、逐场景 master/agent/template 日志和测试前后 guest dmesg。
完整副本同时备份到跳板机
`/home/adonis/cxlfork/real-cxl-103-results/real-dax-20260810/`。

## 7. 环境归还

实验结束后已验证：QEMU 数量为 0，两张 qcow2 通过 `qemu-img check`，
`dax0.0` 恢复 `system-ram`/kmem，31/31 memory blocks online，node2
`MemUsed=0`，临时 `xtl` ACL 已删除，active host state 已轮转。恢复时发现
`daxctl 77` 对已经全部 online 的设备再次执行 `online-memory` 会返回非零；
管理员脚本已改为只在存在 offline block 时调用，并通过幂等 restore 验证。
