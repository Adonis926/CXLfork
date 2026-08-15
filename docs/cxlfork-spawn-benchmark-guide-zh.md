# CXLfork Spawn 专用测试说明

> 103 真实 DAX 的环境、安全步骤和正式 1/4/8/16 lanes 协议见
> `docs/cxlfork-spawn-real-cxl-103-guide-zh.md`。本文件后半部分的 91 数据仅是
> file-sim pilot，不能作为真实 CXL 绝对性能。

## 1. 这项测试回答什么问题

这项测试与 MapReduce、HydraRPC、OpenWhisk 和 CXLporter 无关。它单独考察当前
CXLfork 内核已经真实支持的受限 remote-spawn 路径：源 VM 把一个 4 MiB、单线程、
协作式静止的函数 capsule 准备到共享 CXL window；目标 VM 收到请求后创建一个全新
child，child 执行 `RESUME_CAPSULE_V4`，接上保存的用户栈和 continuation，消费恢复出的
worker state，随后退出。

测试要回答的不是“是否已经实现任意 Linux 进程的透明 remote fork”，而是：

1. CXLfork 的共享页表和状态恢复真实发生后，一次 fresh-child 激活还剩多少开销；
2. 内核 restore 在完整请求中占多少；
3. 随并发 lane 增长，跨 VM 请求、目标端 `fork()`、child setup、continuation 和
   `waitpid()` 分别如何变化。

## 2. 两条对照路径

### CXLfork 路径

```text
VM0 client
  -> TCP 请求（VM0 eth1 到 VM1 eth1）
  -> VM1 lane handler
  -> pipe2 + fork fresh child
  -> child open(/dev/cxlfork)
  -> RESUME_CAPSULE_V4
  -> 内核创建 VMA/上层页表并 attach 共享 PTE leaf
  -> 本地 trampoline
  -> 从保存的栈继续执行 invocation 17
  -> checksum/寄存器/continuation 证明
  -> child exit + parent waitpid
  -> TCP 响应返回 VM0
```

### target-local fork 对照

VM1 的 server parent 预先持有同样的 4 MiB 匿名状态。每个请求同样执行
`pipe2 + fork + child 消费状态 + exit + waitpid`，但不调用 CXLfork。它是目标端普通
Linux fork 的受控下界，不代表 Cohort，也不等价于完整透明 remote fork。

两条路径使用相同的状态初始化、invocation 1–16 和 child invocation 17，因此业务
checksum 相同。CXLfork 路径额外证明 continuation、保存的栈和 shared PFN。

## 3. 代码在哪里

- 内核 benchmark：
  `kernel/linux-6.6.32/tools/testing/selftests/cxlfork/cxlfork_spawn_bench.c`
- kselftest 构建入口：
  `kernel/linux-6.6.32/tools/testing/selftests/cxlfork/Makefile`
- 唯一 host runner：`scripts/run-cxlfork-spawn.sh`
- 复用的 VM 生命周期脚本：
  `scripts/start-cxlfork-vms.sh`、`scripts/stop-cxlfork-vms.sh`

benchmark 被构建为 static、non-PIE、无 stack protector/CF protection 的固定二进制，
VM0 和 VM1 部署前必须通过 SHA256 一致性检查。V4 manifest 内的 digest 当前是固定的
相等性 token；真正的 ELF SHA256 由 runner 记录和验证，不能把 token 描述成内核完成
的密码学文件校验。

## 4. 计时边界

所有 VM1 内部时间来自 `CLOCK_MONOTONIC_RAW`，可以在同一个 VM 内相减。VM0 与 VM1
之间不比较绝对时间戳。

最外层严格满足：

```text
target_total
  = request_dispatch
  + activation
  + exit_wait
```

activation 内部严格满足：

```text
activation
  = fork_to_child
  + child_setup
  + restore_wall
  + continuation
```

各字段含义：

- `rtt_ns`：VM0 发请求到收到完整响应。
- `vm0_residual_ns`：`rtt - target_total`；包括两次虚拟网络传递、VM0/VM1 调度缝隙、
  协议读写等未在目标 critical section 内计入的开销。
- `request_dispatch_ns`：VM1 解码请求后到调用 `fork()` 前，主要是 `pipe2` 和准备工作。
- `fork_to_child_ns`：进入 `fork()` 到 child 真正开始运行。
- `child_setup_ns`：child 开始到发起 restore，包括 activation stack 和设备 fd。
- `restore_wall_ns`：目标 child 看到的完整 restore ioctl 墙钟时间。
- `kernel_restore_ns`：V4 内核统计，是 `restore_wall` 内的嵌套子项，不能再次与它相加。
- `continuation_ns`：restore/trampoline 完成后到 worker checksum 证明完成；local 模式中
  表示 child 消费同一份状态的时间。
- `exit_wait_ns`：证明完成到 parent `waitpid()` 返回。
- `fork_parent_return_ns`：parent 从 `fork()` 返回的诊断值，与 child critical path 并行，
  不属于可相加的 exclusive breakdown。

raw CSV 同时保存 `kernel_supported_mask`、`kernel_valid_mask` 和 `kernel_path_mask`。只有
valid bit 置位的内核 bucket 才能解释为测量值；未启用的 full checksum validation、
fallback/global 等必须报告为 `NA`，不能把 0 写成“已经实现且零开销”。

## 5. 如何运行

在 91 的主仓库执行：

```bash
cd /home/xtl/cxlfork/cxlfork-repro
git switch cxlfork-spawn-benchmark
git submodule update --init kernel/linux-6.6.32
scripts/run-cxlfork-spawn.sh run
```

runner 会自动完成：

1. 构建 selftest，并强制检查 benchmark 是 static ELF；
2. 只停止/启动本仓库 pidfile 记录的 VM0/VM1；
3. 使用 `/dev/shm/cxlfork_spawn_mem` 作为 4 GiB CXL 模拟 backend；
4. 启动各 16 vCPU、16 GiB 的 VM0/VM1，并固定 host CPU 48–63、64–79；
5. 配置 direct NIC：VM0 `192.168.91.10`、VM1 `192.168.91.11`；
6. 跑 ABI/V2 lifecycle gate、10,000 次 V4 churn 和 reader 回收检查；
7. 分别运行 1/4/16 lanes，3 轮，每轮 warmup 2 次后计时 5 秒；
8. 生成 raw、pass throughput、统计 summary、dmesg 和 SHA256 清单；
9. release slot 并关闭本项目 VM。

缩小参数可用于调试，例如：

```bash
PILOT_LANES=1 PILOT_PASSES=1 PILOT_SECONDS=1 CHURN_REQUESTS=10 \
  scripts/run-cxlfork-spawn.sh run
```

## 6. 91 文件模拟环境的正式 pilot

结果目录：

```text
/home/xtl/cxlfork/cxlfork-repro/results/cxlfork-spawn/
  20260814T081108Z-91-file-sim/
```

本地备份目录：

```text
/home/adonis/cxlfork/cxlfork-spawn-results/
  20260814T081108Z-91-file-sim/
```

核心吞吐（ops/s，三轮 mean）：

| lanes | CXLfork | target-local | CXLfork/local |
|---:|---:|---:|---:|
| 1 | 1,280.8 | 1,150.1 | 1.114× |
| 4 | 9,766.4 | 8,346.0 | 1.170× |
| 16 | 26,499.3 | 22,419.7 | 1.182× |

CXLfork 路径 mean breakdown（微秒）：

| lanes | RTT | VM0 residual | target total | fork→child | child setup | restore wall | kernel restore | continuation | exit/wait |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | 780.43 | 175.57 | 604.85 | 126.34 | 18.78 | 20.05 | 8.63 | 334.41 | 102.45 |
| 4 | 409.39 | 113.40 | 295.99 | 75.72 | 8.67 | 9.63 | 4.36 | 138.12 | 61.10 |
| 16 | 603.60 | 266.07 | 337.53 | 100.30 | 8.90 | 10.18 | 4.78 | 136.57 | 78.46 |

`kernel_restore / target_total` 在三组中约为 1.42%–1.47%。换句话说，共享 PTE leaf
和受限 worker state restore 已经把内核数据面压到数微秒后，完整 fresh-child 请求仍由
目标 `fork`/调度、continuation 的真实状态消费、exit/wait，以及跨 VM residual 主导。
16 lanes 时 residual 占 RTT 约 44.1%，说明并发提高后跨 VM 协议、排队和调度缝隙变得
更显眼。这正是后续比较单一 OS 控制路径时最有价值的观察。

CXLfork 比本地对照更快并非测试错误。local server parent 长期持有普通 4 MiB 匿名
映射，`fork()` 需要复制/引用其普通页表状态；CXLfork server parent 不持有 capsule VMA，
fresh child 通过共享 leaf attach 获取状态。结果说明当前受限数据路径确实有收益，但不能
外推为“完整 remote fork 比 local fork 快”。

1 lane 到 4 lanes 的每请求 latency 降低带有并行唤醒、空闲态和流水化影响；4 到 16
lanes 后 contention 开始出现。因此这组短时 pilot 用于机制与量级判断，不替代迁移到
103 真 CXL 后的正式重复实验。

## 7. 结果文件

- `raw.csv`：合并后的全部 1,041,934 条逐请求记录。
- `raw/`：按 mode、lane 数、pass、lane 拆分的原始文件；便于定位异常。
- `passes.csv`：18 轮吞吐，论文画吞吐图优先使用它。
- `summary.csv`：各 breakdown 的 mean/P50/P95/P99/标准差；每组样本远大于 1,000，
  因而 P99 有足够样本基础。
- `gates/churn-10000.csv`：10,000 次连续 restore/exit 压力的逐请求证据。
- `logs/*client.log`：每轮完成信息和 warmup shared PFN 证明。
- `logs/post-churn-inspect.log`：压力结束后 `readers=0`。
- `logs/*dmesg*`：测试前后 dmesg；`dmesg-errors.log` 为空。
- `manifest.txt`：Git HEAD、kernel/binary SHA、host CPU 和文件系统信息。
- `SHA256SUMS`：结果包内所有 179 个文件的完整性清单。

## 8. 仍然存在的边界

- 91 使用 host tmpfs 普通文件模拟 CXL backend，不能用于真实 CXL latency、带宽、NUMA
  或 cache 行为的绝对结论。
- capsule 固定为 4 MiB、单线程、匿名地址空间和协作式静止；不保存任意进程的完整
  task/fd/namespace/socket 状态。
- VM1 的 fresh child 是目标端 forkserver 创建的真实 Linux 进程，但不是内核从零透明
  重建的任意源进程对象。
- TCP direct NIC 是为了覆盖跨 VM 请求/响应而使用的最小控制路径，不是 HydraRPC，
  也不代表 OpenWhisk/CXLporter。
- 当前结果适合作为 103 真 CXL 迁移前的功能、计时和研究假设 pilot；正式论文数值需在
  独占的真实硬件窗口按同一脚本重跑并单独报告环境差异。
