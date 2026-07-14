# CXLfork 复现系统测试学习指南

> 文档状态：2026-07-14
>
> 远端权威工作区：`xtl@10.0.16.91:~/cxlfork/cxlfork-repro`
>
> 本地测试数据备份：`/home/adonis/cxlfork/remote-backup-20260713`
>
> 本文目标：不从大段内核代码入手，而是通过“测试输入—触发机制—观察证据—成功条件”理解整个 CXLfork 数据面和控制面。

## 1. 为什么从测试理解这个系统

CXLfork 同时涉及共享内存、页表、进程地址空间、跨 VM 生命周期和 OpenWhisk 控制路径。只看实现代码，很容易遇到三个问题：

1. 看到了一个函数，但不知道它是否真的在运行时走到。
2. 看到了一个统计字段，但不知道它测量的是否是所声称的机制。
3. 看到 checksum 正确，就误以为 shared leaf、CoW 和 generation 也一定正确。

本项目的测试把这些问题拆开验证。例如：

- checksum 证明“恢复后的内容正确”；
- PFN/PMD 证明“页面和页表来自哪里”；
- 写前写后的 PFN 变化证明“CoW 真实发生”；
- generation 和 reader count 证明“共享对象不会被旧请求或提前 release 破坏”；
- fast/full 对比证明“默认 fast path 没有偷偷逐 PTE 全量扫描”；
- Direct/OpenWhisk 对比帮助区分“内核数据面”和“上层控制面”开销。

因此，不存在一个测试能证明整个系统。正确的方法是把不同证据拼在一起。

## 2. 测试体系全景

可以把现有测试理解成五层：

```text
第 5 层：端到端性能
         Direct 与 OpenWhisk，大样本、不同 footprint/policy/pool
                           ▲
第 4 层：控制面正确性
         REGISTER、INVOKE、并发、stale、active release
                           ▲
第 3 层：数据面性能
         prepare/restore/touch、fast/full、LocalFork 对照
                           ▲
第 2 层：内核机制正确性
         checksum、PFN、PMD、leaf/data CoW、rollback、MM gate
                           ▲
第 1 层：平台前提与 ABI
         跨 VM 原子/内存序、V2 size/version/reserved/capability
```

执行新实验时应该自下而上。若第 1 或第 2 层失败，直接运行 OpenWhisk benchmark 得到的数字没有可信意义。

## 3. 测试环境和准备

本文假定内核已编译，VM0/VM1 使用同一 `/dev/shm/cxl_mem`，localfork 不挂共享后端：

| 实例 | 角色 | SSH |
|---|---|---:|
| VM0 | checkpoint/prepare | `localhost:2200` |
| VM1 | restore/invoke | `localhost:2201` |
| localfork | 普通 fork baseline | `localhost:2202` |

启动：

```bash
cd /home/xtl/cxlfork/cxlfork-repro
./scripts/start-cxlfork-vms.sh cxl
./scripts/start-cxlfork-vms.sh localfork
```

最基本的前置检查：

```bash
for port in 2200 2201; do
  ssh -p "$port" ubuntu@localhost \
    'uname -r; ls -l /dev/cxlfork; cat /proc/cmdline'
done

ssh -p 2202 ubuntu@localhost 'uname -r; cat /proc/cmdline'
```

VM0/VM1 必须有 `/dev/cxlfork` 和相同的 `cxlfork.cxl_phys/cxl_size`；localfork 不应携带 CXL 参数。

内核自测试源码：

```text
kernel/linux-6.6.32/tools/testing/selftests/cxlfork/cxlfork_test.c
kernel/linux-6.6.32/tools/testing/selftests/cxlfork/cxlfork_litmus.c
```

当前构建产物：

```text
kernel/build-6.6.32/kselftest/cxlfork/cxlfork_test
kernel/build-6.6.32/kselftest/cxlfork/cxlfork_litmus
```

可以部署测试程序：

```bash
TEST=kernel/build-6.6.32/kselftest/cxlfork/cxlfork_test
for port in 2200 2201 2202; do
  scp -P "$port" "$TEST" ubuntu@localhost:/tmp/cxlfork_test
  ssh -p "$port" ubuntu@localhost 'chmod 755 /tmp/cxlfork_test'
done
```

涉及 selftest-only ioctl 或 GUP probe 的项目需要在 guest 中使用 `sudo`。重新编译 UAPI 后，应先运行 `headers_install`，再重编 selftest 和 CXLporter，避免用户态与内核结构错位。

## 4. 学会看测试证据

### 4.1 返回值和 errno

成功测试不仅检查“返回 0”，失败测试还检查是否返回正确错误：

| errno | 常见含义 |
|---|---|
| `EINVAL` | 参数、size、reserved、flags 不合法 |
| `EPROTONOSUPPORT` | V2 ABI 版本不支持 |
| `ENOENT` | key 不存在或 slot 不是 READY |
| `ESTALE` | key 存在，但 generation 已过期 |
| `EBUSY` | slot 仍有 reader，不能 release |
| `EEXIST` | restore 目标虚拟地址冲突 |
| `EOPNOTSUPP` | 操作不在受支持模型中 |
| `EILSEQ` | image/checksum/metadata 损坏 |
| `ENOSPC` | slot 容量不足或用户 region buffer 太小 |

正确失败是系统语义的一部分。例如 active reader 下 release 返回 `EBUSY`，比“release 成功”更正确。

### 4.2 checksum

测试通常使用确定性模式填充页面，然后计算 checksum：

```text
VM0 checkpoint 前 checksum
      == 共享 slot page_checksum
      == VM1 restore 后遍历内容的 checksum
```

写入恢复进程后，还会重新观察 checkpoint checksum。如果它变化，说明 sibling/checkpoint 被污染，CoW 失败。

checksum 能证明内容，但不能单独证明零复制或 shared leaf。复制出一份内容相同的页面也能得到同样 checksum。

### 4.3 PFN 和 PMD/PTE

`INSPECT_V2` 可以返回：

- `shared_pfn`：checkpoint 中共享数据页的 PFN；
- `current_pfn`：当前恢复 mm 中该虚拟地址实际使用的 PFN；
- `shared_leaf_pfn`：CXL 中共享 PTE leaf 的 PFN；
- `current_pmd_pfn`：当前 mm 的 PMD 指向哪个 leaf。

典型判断：

```text
restore 后：current_pmd_pfn == shared_leaf_pfn   → 真实 shared leaf
MoW 写后： current_pmd_pfn != shared_leaf_pfn   → leaf 已本地化
MoW 写后： current_pfn != shared_pfn            → 数据页已 CoW
第二次写： PFN 不再变化                       → 没有重复复制
```

这比只看 `faults=1` 更可靠，因为 fault counter 可能漏掉 core-MM 中处理的写保护 fault。

### 4.4 generation、state 和 readers

`INSPECT_V2` 还报告：

```text
state=READY
generation=N
readers=M
```

它们回答三个问题：

- 现在看到的是不是完整发布的 checkpoint？
- 这个请求是不是对应当前 generation？
- 是否仍有 VMA/context 可能访问 slot？

### 4.5 stats mask 和 `NA`

统计结构同时有 supported mask、valid mask 和 path mask。读取结果时：

- 字段受支持且本次执行：数值有效；
- 字段受支持但本次未走到：应按 `NA` 解释；
- 机制没有完整计量 hook：同样是 `NA`，不能写成 0 ns。

例如最终控制 benchmark 的 workload 是读触碰，它能测 shared-leaf attach，却不会触发 leaf/data CoW，所以这些 fault 后统计应为 `NA`。

## 5. V2 ABI 和 capability 测试

### 5.1 入口

```bash
ssh -p 2200 ubuntu@localhost 'sudo /tmp/cxlfork_test abi'
ssh -p 2201 ubuntu@localhost 'sudo /tmp/cxlfork_test abi'
ssh -p 2202 ubuntu@localhost 'sudo /tmp/cxlfork_test abi'
```

不带参数运行 `cxlfork_test` 也会执行 ABI 测试。

### 5.2 测试逻辑

当前为 TAP 13 格式的 11 项测试：

1. `QUERY_CAPS_V2` 正常成功。
2. size/version 能正确往返。
3. 已实现能力位存在。
4. `FULL_PRIVATE_STATE` 和 real shared VMA leaf 等未实现能力没有被宣传。
5. 过大的结构返回 `EINVAL`。
6. 非零 reserved tail 返回 `EINVAL`。
7. page size、slot 数、slot layout 等限制合理。
8. 未知 ABI version 返回 `EPROTONOSUPPORT`。
9. 过短结构返回 `EINVAL`。
10. 非零 header reserved 返回 `EINVAL`。
11. `INSPECT` 未知 key 返回 `ENOENT`。

### 5.3 意义

ABI 是所有用户态程序和内核之间的合同。如果它不严格，结构体扩展后可能出现“程序看似成功，但 key、指针或统计字段已经错位”的危险问题。正向和反向测试同样重要。

最终记录：VM0、VM1、localfork 均通过 11/11。历史 Phase 13 的 9/9 是继续收口前的旧版本，不应覆盖最终 11/11 结论。

## 6. 跨 VM 原子和内存序 litmus

### 6.1 入口和结果

```bash
cd /home/xtl/cxlfork/cxlfork-repro
ROUNDS=10 ITERATIONS=100000 ./scripts/run-cxlfork-litmus.sh
```

脚本：`scripts/run-cxlfork-litmus.sh`。

默认远端日志为 `/tmp/cxlfork_litmus.log`，永久本地备份为：

```text
/home/adonis/cxlfork/remote-backup-20260713/logs/cxlfork-stage4-litmus.log
```

### 6.2 三个子测试

#### 原子 RMW

VM0 和 VM1 同时对共享 64 位计数器做 CAS/RMW。每台执行 100000 次，最终必须是 200000，不能丢增量。它验证 slot 的 packed state+reader CAS 在当前 backend 上具有真正的跨 VM 原子性。

#### Release/acquire 消息发布

producer 先写多字 payload，再 release 发布 sequence；consumer acquire 看到新 sequence 后检查整个 payload。如果出现 sequence 已更新、payload 仍是旧值，说明 READY 发布协议不可靠。

#### coherent ping-pong

VM0/VM1 轮流修改共享 token，共 100000 次。它检查双方是否能持续看到对方的最新 cache line 状态，而不是各自保留不一致副本。

### 6.3 成功条件和边界

最终 10 轮的 counter、sequence、acknowledgement 和 token 均正确，`errors=0`，以：

```text
CXLFORK_LITMUS_OK rounds=10 iterations=100000
```

结束。

这个测试只证明当前 QEMU/KVM、`ioremap_cache()` 和 shared-file backend 的实验前提。换成真实 CXL 设备或不同 cacheability 配置后必须重新执行。

## 7. checkpoint/restore 基础正确性

### 7.1 最小跨 VM 流程

```bash
# VM0：创建并发布 4 MiB checkpoint
ssh -p 2200 ubuntu@localhost \
  'sudo /tmp/cxlfork_test prepare 42001 4194304'

# VM1：恢复；policy 可为 readonly、mow 或 moa
ssh -p 2201 ubuntu@localhost \
  'sudo /tmp/cxlfork_test restore 42001 mow'

# VM0：释放
ssh -p 2200 ubuntu@localhost \
  'sudo /tmp/cxlfork_test release 42001'
```

### 7.2 prepare 测试做什么

`prepare_snapshot()` 大致执行：

1. 建立受支持、对齐的私有匿名 region。
2. 用由 key 和 offset 决定的模式填充数据。
3. 调用 checkpoint ioctl。
4. 检查 region/page 数、页面分类、image 大小和统计。
5. 输出 key、slot、pages、checksum、extent 数和 `verify=ok`。

它证明 checkpoint 不是空壳：数据、PTE/VMA metadata 和 manifest 都被写入共享 slot。

### 7.3 restore 测试做什么

`restore_snapshot()` 的检查比“能读出来”更严格：

1. 调用 restore，遍历所有 region 重新计算 checksum。
2. `INSPECT` 一个具体地址，读取 shared/current PFN 和 PMD PFN。
3. readonly/MoW 检查 `current_pmd_pfn == shared_leaf_pfn`。
4. 对可写策略修改第一页。
5. 检查 checkpoint 的 observed checksum 没变化。
6. MoW 检查 leaf PFN 和数据 PFN 都切到本地。
7. MoA 检查首次访问已经获得本地 PFN。
8. 再写一次，确认 PFN 不再变化，避免重复 CoW。

这组测试共同证明内容、shared leaf、leaf CoW、数据 CoW 和重复写语义。

### 7.4 关于测试输出中的 VMA image

旧输出或错误文本可能出现 “attach a CXL Maple VMA node”。当前真实含义只是：checkpoint 中的只读 VMA image 能按地址找到正确记录。它没有成为 Linux `mm->mm_mt` 的真实共享节点。

所以这项测试只能支持“VMA image lookup/reconstruction 正确”，不能支持“真实 Maple Tree leaf attach”。

## 8. 地址冲突和 unsupported 输入测试

### 8.1 conflict

```bash
ssh -p 2201 ubuntu@localhost \
  'sudo /tmp/cxlfork_test conflict 42001 mow'
```

测试先在目标 checkpoint 地址放一个 guard mapping，再尝试 restore。期望：

- 返回 `EEXIST`；
- guard 内容不变；
- 不使用破坏性的 `MAP_FIXED` 覆盖已有地址；
- 不留下部分映射和 reader。

意义是保护 ghost 自己的代码、栈和动态库。如果地址冲突时强行覆盖，restore 即使返回成功，进程也可能稍后随机崩溃。

### 8.2 failures

```bash
ssh -p 2200 ubuntu@localhost \
  'sudo /tmp/cxlfork_test failures 43001'
```

`run_failure_tests()` 覆盖不支持的 checkpoint 输入，例如多线程、特殊/shared VMA、错误范围或其他 eligibility 失败。核心判定是：

- 返回明确 errno；
- 不静默跳过不支持的 VMA；
- 不发布一个看似 READY、实际缺页的 slot；
- `INSPECT` 不应找到失败对象。

这防止“测试小程序 checksum 正确，但真实进程有一半地址空间根本没 checkpoint”的假成功。

## 9. slot lifecycle 和 restore context

### 9.1 相关入口

```text
cxlfork_test lifecycle KEY
cxlfork_test v2-lifecycle KEY
cxlfork_test hold KEY SECONDS
cxlfork_test hold-close KEY SECONDS
```

### 9.2 `v2-lifecycle` 的逻辑

这个测试在一个受控流程中验证：

1. `PREPARE_V2` 返回非零 generation。
2. 正确 generation 可以 `RESUME_V2`。
3. restore 后 `INSPECT` 看到 `readers=1`。
4. reader 活跃时 `RELEASE_V2` 返回 `EBUSY`。
5. unmap 最后一个恢复 VMA 后 release 成功。
6. 相同 key 再次 prepare，generation 必须增长。
7. 使用旧 generation resume/release 返回 `ESTALE`。
8. 当前 generation 才能 release。

### 9.3 `hold-close` 为什么重要

它在 restore 后关闭 `/dev/cxlfork` fd，但保留 VMA 并继续访问页面。测试要求：

- 页面仍能 fault 和读取；
- 另一个 control fd 仍能按 restore ID 查询 stats；
- `INSPECT` 仍显示一个 reader；
- release 仍返回 `EBUSY`；
- 最后一个 VMA 消失后 reader 才归零。

这证明 slot 生命周期属于恢复映射，而不是错误地绑定在设备 fd 上。

### 9.4 并发 holder 测试

本地备份：`logs/cxlfork-stage6-concurrency.log`。

测试让多个 VM1 进程同时 restore 同一 checkpoint。最终记录曾观察到 3 个并发 reader；另一个因固定测试地址冲突被拒绝。VM0 release 返回 `EBUSY`，进程退出后 readers 回到 0，最终 release 成功。

它验证 restore-many 生命周期安全，但也说明单个 mm 的固定地址约束与“slot 可以有多个 reader”是两个不同问题。

## 10. 事务式 rollback 测试

### 10.1 入口

```bash
ssh -p 2201 ubuntu@localhost \
  'sudo /tmp/cxlfork_test v2-rollback 44001'
```

### 10.2 测试逻辑

测试构造两个 region，并通过仅在 `CONFIG_CXLFORK_SELFTEST` 下可用的 fault-injection flag，让内核在成功映射第一个 region 后故意返回 `EIO`。

随后验证：

1. 两个目标地址都能重新用 `MAP_FIXED_NOREPLACE` 占用，说明没有残留 VMA。
2. `INSPECT` 显示 reader count 回到 0。
3. generation-aware release 成功。
4. dmesg 没有 page-table warning。

最终验收连续注入 20 次失败均无残留。它证明“失败不会留下半个恢复进程”。

## 11. MM fail-fast 测试

### 11.1 入口

```bash
ssh -p 2201 ubuntu@localhost \
  'sudo /tmp/cxlfork_test mm-failfast 45001'
```

### 11.2 测试操作

对恢复 VMA 分别尝试：

- `mprotect()`；
- partial `munmap()`；
- `mremap()`；
- `fork()`；
- read/write/long-term/write+long-term GUP probe。

这些操作可能修改、复制、拆分或长期 pin 共享页表/页面。当前原型没有为它们实现完整安全语义，所以测试要求真实 hook 返回 `EOPNOTSUPP`。

最后还检查 `QUERY_CAPS_V2.mm_failfast_mask` 与真实覆盖的 hook 一致。没有 hook 和测试的入口只能叫 unsupported，不能笼统宣称全部 fail-fast。

## 12. fast path 与 full validation 测试

### 12.1 入口

```bash
ssh -p 2201 ubuntu@localhost \
  'sudo /tmp/cxlfork_test v2-fastpath 46001 4194304'
```

永久测试文件：

```text
/home/adonis/cxlfork/remote-backup-20260713/logs/cxlfork-stage4-fastpath-30-v2.log
```

### 12.2 对比逻辑

同一个 checkpoint 恢复两次：

| 路径 | flag | 应有表现 |
|---|---|---|
| fast | 默认 V2 | 只做固定布局/manifest admission，`validated_ptes=0` |
| full | `CXLFORK_F_VALIDATE_FULL` | 重算和扫描全部 image/PTE，`validated_ptes=总页数` |

同时检查 `path_mask`、shared leaf pages、fallback pages 和 checksum，防止“为了快而跳过必要的 generation/边界检查”。

### 12.3 已有结果

4 MiB、30 样本：

| 指标 | mean | P50 | P95 | stddev |
|---|---:|---:|---:|---:|
| fast total | 11.66 µs | 11.23 µs | 14.72 µs | 1.58 µs |
| full total | 5.934 ms | 5.930 ms | 5.966 ms | 0.0167 ms |

单点 scaling 中，4/64/192 MiB 的 fast/full total 大约为：

```text
4 MiB:    19.9 µs /   5.94 ms
64 MiB:   23.5 µs /  94.4 ms
192 MiB:  41.4 µs / 283.3 ms
```

它说明 fast admission 接近与页数无关，但完整 restore 仍包含 VMA/页表建立等工作，因此不能据此声称整个 restore 严格 O(1)。30 样本只报告 mean/P50/P95/stddev，不报告可信 P99。

## 13. A/D bit、Hybrid 和 dirty prefetch 测试

### 13.1 Hybrid correctness

入口：

```text
cxlfork_test hybrid-prepare KEY
cxlfork_test hybrid-restore KEY
```

测试刻意准备不同 checkpointed PTE 状态：

- hot 页：A=1；
- cold 页：A=0；
- dirty 页：D=1。

restore 后检查：

- hot 页走预期本地/迁移路径；
- cold 页仍共享；
- dirty 页在 restore 阶段 prefault/prefetch；
- PFN 和 `dirty_prefault_pages` 与设计一致。

最终记录包含 `dirty_prefault_pages=1 verify=ok`。

### 13.2 shared leaf A-bit feasibility

入口：

```text
cxlfork_test abit-prepare KEY
cxlfork_test abit-restore KEY
```

永久结果：

```text
/home/adonis/cxlfork/remote-backup-20260713/logs/cxlfork-stage5-abit.log
```

逻辑：先清除 CXL leaf PTE 的 A bit，VM1 通过 shared leaf 读取一个字节，再次 inspect 同一个 leaf PTE。已有观测：

```text
before_pte=...ca05
after_pte =...ca25
```

新增的 `0x20` 即 `_PAGE_ACCESSED`。这说明在当前 QEMU/KVM 环境中，硬件 page walker 实际更新了共享 leaf。

这是一项独立 feasibility gate。如果 EPT/TLB 让观测不稳定，它可以报告 unsupported，而不应阻塞 PFN、leaf CoW、lifecycle 和 fast path 等核心测试。

## 14. thread context 和 fd/global 子集测试

### 14.1 cooperative thread context

入口：

```text
cxlfork_test threadctx-prepare KEY BYTES
cxlfork_test threadctx-restore KEY readonly|mow|moa
```

它使用专门设计的 trampoline、栈和保存点，检查受控 IP/SP/TLS 恢复后能从预期位置继续执行。它证明的是 cooperative 子集，不是任意进程透明恢复，也不等于 `FULL_PRIVATE_STATE`。

### 14.2 普通文件 global state

入口：

```text
cxlfork_test fdglobal-prepare KEY BYTES
cxlfork_test fdglobal-restore KEY readonly|mow|moa
```

检查普通文件 fd number、offset、flags，以及 cwd/root/umask/signal mask 等受限字段。它要求目标看到相同文件系统身份。

同一 VM/同一 root filesystem 的测试通过；跨独立 qcow2 root 时，如果 `/tmp` inode 不存在，返回 `ENOENT` 是正确的环境限制。不能据此声称 socket、pipe、epoll、timerfd 或 namespace 已恢复。

默认数据面和控制面 benchmark 不启用 thread/global restore，避免它们阻塞匿名内存 fast path。

## 15. 容量和动态布局测试

阶段 12 测试关注的不只是“大内存能否成功”，还包括失败是否干净：

- 4 MiB 和 192 MiB prepare/restore；
- 多 region、动态 region/PTE/fd table 和 extent manifest；
- slot 内 extent bitmap 分配和回收；
- 512 MiB 输入超过当前固定 slot 可用 payload 时返回 `ENOSPC`；
- 失败对象不能进入 READY；
- release 后 extent 可重新使用。

当前共享窗口约 4 GiB，使用固定 512 MiB slot，最多 7 个 slot。它不是全窗口任意大小全局 allocator。

历史“124 MiB 成功、125 MiB 失败”属于早期静态 128 MiB slot 布局，不能作为当前容量结论。当前结论以阶段 12/13 acceptance log 为准。

## 16. 底层 unified-touch benchmark

### 16.1 脚本

```text
scripts/21-benchmark-unified-touch.sh
scripts/unified_touch_bench.c
```

运行示例：

```bash
cd /home/xtl/cxlfork/cxlfork-repro
ITERS=2 WARMUP=1 \
SIZES="4194304 67108864 201326592" \
MODES="read write" \
POLICIES="mow moa hybrid" \
./scripts/21-benchmark-unified-touch.sh
```

### 16.2 测试逻辑

对于每个 footprint 和 read/write mode：

1. localfork VM 执行普通 `fork()` + 相同逐页 touch，形成 baseline。
2. VM0 prepare 一次 checkpoint。
3. VM1 分别以 MoW/MoA/Hybrid restore 并执行相同 touch。
4. 收集 prepare、restore、fault、touch 和总时间。
5. VM0 release key，避免固定 slot 的后续 key collision。
6. 检查每行 CSV 都是 45 列。

它回答：数据量、访问模式和迁移策略改变时，checkpoint、restore 和首次访问成本如何变化。

### 16.3 最终结果

远端：

```text
results/cxlfork-phase13-perf.csv
```

本地：

```text
/home/adonis/cxlfork/remote-backup-20260713/results/cxlfork-phase13-perf.csv
```

数据为 45 列、24 行，覆盖 4/64/192 MiB、read/write、LocalFork 以及三种 CXLfork policy。`results/unified-touch-*.csv` 是不同开发阶段的历史数据；比较它们时必须结合对应提交和 acceptance log，不能假设字段语义始终相同。

这是 QEMU shared-backend 下的功能 breakdown 和趋势数据，不是真实 CXL 设备性能。

## 17. 早期 CXLporter benchmark

脚本：

```text
cxlporter/scripts/30-benchmark-cxlporter.sh
```

它在 VM0 为 json、pyaes、html、touch 等合成函数 checkpoint，在 VM1 使用旧版 ghost worker invoke，并与 localfork 比较。主要输出为旧 24 列 CSV 和 14 列 checkpoint manifest。

这套测试对理解“checkpoint once、不同 policy/pool restore many”很有用，但它早于最终 `CXLP/1` daemon + OpenWhisk 控制面和 62 列 measurement schema。正式控制面论文分析应优先使用 `33-benchmark-control-plane.sh` 的最终数据。

## 18. 控制面 correctness 测试

### 18.1 脚本和运行

脚本：`cxlporter/scripts/32-control-correctness.sh`。

在 VM、daemon、OpenWhisk 都可用时：

```bash
cd /home/xtl/cxlfork/cxlfork-repro/cxlporter
./scripts/31-start-control-plane.sh
./openwhisk/scripts/start-standalone.sh
./openwhisk/scripts/42-deploy-cxlporter-action.sh
./scripts/32-control-correctness.sh
```

### 18.2 脚本逐步做什么

1. 以指定 pool size 启动 VM1 daemon。
2. 清理测试 key 的旧 generation。
3. VM0 创建 4 MiB `touch` checkpoint，记录 page/workload checksum。
4. 向 daemon 发送 REGISTER；daemon 只有在 `INSPECT_V2` 验证 generation、bytes、checksum 后才接受。
5. 发送一次 Direct INVOKE，检查 ghost restore、workload 和返回结果。
6. 部署 OpenWhisk action，执行 3 个 smoke 样本和 1 个 warmup。
7. 发送未知 function，必须失败且 `status=2`。
8. 用错误 generation REGISTER，必须失败且 `status=116`（`ESTALE`）。
9. 发送未知协议字段，必须在 `error_stage=parse` 失败。
10. 以 concurrency=8 发送 16 个 Direct 请求。
11. 发一个 `hold_ms=1500` 请求，让恢复 VMA 保持活跃。
12. VM0 inspect 必须看到 `readers>=1`，此时 release 必须 `EBUSY`。
13. holder 结束后 readers 必须归零，最终 release 成功。
14. 保存 VM0/VM1 完整 dmesg，并扫描 BUG/WARNING/Oops/UAF/bad pagetable 等。

### 18.3 意义

它不是性能测试，而是整个控制链的“上线前体检”：

```text
OpenWhisk/Direct 请求
 → daemon parser/registry/queue
 → ghost
 → RESUME_V2
 → workload/checksum
 → 生命周期清理
```

只有它通过后，才应该运行上千样本 benchmark。

### 18.4 最终结果位置

远端：

```text
cxlporter/results/control-correctness-20260713-175411/
```

本地：

```text
/home/adonis/cxlfork/remote-backup-20260713/control-plane/final-correctness/
```

重要文件：

| 文件 | 内容 |
|---|---|
| `checkpoint.log` | key/generation/checksum/prepare 分项 |
| `register.log` | registry 验证结果 |
| `direct.log` | Direct smoke |
| `openwhisk-smoke.csv` | OpenWhisk smoke 原始行 |
| `failures.log` | unknown/stale/malformed 的预期失败 |
| `concurrent.csv` | 16 个并发请求 |
| `active-reader.log` | holder 活跃时 reader 数 |
| `active-release.log` | 预期 `EBUSY` |
| `readers-after.log` | holder 退出后 reader=0 |
| `final-release.log` | 最终 release 成功 |
| `dmesg-2200.log`、`dmesg-2201.log` | 内核异常检查 |

## 19. 最终 Direct/OpenWhisk benchmark

### 19.1 脚本

```text
cxlporter/scripts/33-benchmark-control-plane.sh
cxlporter/openwhisk/scripts/control_benchmark.py
cxlporter/openwhisk/scripts/summarize_control.py
```

运行：

```bash
cd /home/xtl/cxlfork/cxlfork-repro/cxlporter
./scripts/33-benchmark-control-plane.sh
```

### 19.2 实验矩阵

- footprint：4、64、192 MiB；
- policy：MoW、MoA、Hybrid；
- path：Direct、OpenWhisk；
- mode：invoke、restore-only、cold；
- ghost pool：1、4、8；
- micro：1000 样本；
- concurrency：1000 样本；
- scaling：每组 100 样本；
- 默认 warmup：20。

### 19.3 三种 mode 的区别

| mode | 是否 RESUME_V2 | 是否运行函数 | 用途 |
|---|---|---|---|
| `invoke` | 是 | 是 | 完整 remote invoke |
| `restore-only` | 是 | 否 | 尽量隔离恢复/控制路径 |
| `cold` | 否 | 是，本地重新 map/fill | 无 CXLfork restore 的对照 |

### 19.4 Direct 与 OpenWhisk

```text
Direct:
client → hostfwd → VM1 daemon → ghost → RESUME_V2 → workload

OpenWhisk:
client → OpenWhisk HTTP → Docker Node proxy → hostfwd
       → VM1 daemon → ghost → RESUME_V2 → workload
```

两条路径在进入 VM1 daemon 后共用同一数据面。因此它们的差异主要揭示 OpenWhisk HTTP、调度、action container 和 bridge 路径的额外成本。

### 19.5 每行记录什么

最终 schema v2 共 62 列，每一行是一个请求。主要层次：

```text
client_e2e_ns
  └─ OpenWhisk wait/scheduling/HTTP（OpenWhisk 路径）
      └─ action_total_ns
          └─ action_bridge_rtt_ns
              └─ daemon_total_ns
                  ├─ queue_wait_ns
                  ├─ worker_wakeup_ns
                  └─ worker_total_ns
                      ├─ restore_ioctl_ns
                      │   └─ kernel_total_ns
                      └─ workload_ns
```

这些是嵌套区间，不能把 `client_e2e + daemon + restore + kernel` 相加。正确用法是比较父项与子项的差值或占比。

内核 breakdown 进一步包括 validation、VMA create、upper PT allocation、shared leaf attach、fallback、dirty prefetch、global、rollback、other。fault 后的 leaf/data CoW 和 CXL-to-local copy 通过 restore context 查询。

### 19.6 样本数与百分位数

- 1000 样本的 micro/concurrency 报告 mean、P50、P95、P99 和标准差。
- 100 样本的 scaling 明确把 P99 写为 `NA`。
- 30 样本 fast-path 历史日志不报告 P99。

这是为了避免把一个非常靠近最大值的少量样本顺序统计量包装成稳定尾延迟。

### 19.7 最终结果位置

远端：

```text
cxlporter/results/cohort-control-20260713-175429/
```

本地：

```text
/home/adonis/cxlfork/remote-backup-20260713/control-plane/final-benchmark/
```

结果共 9400 行、62 列，0 个验证失败。Direct 6200 行、OpenWhisk 3200 行。

重要文件：

| 文件 | 如何使用 |
|---|---|
| `control-samples.csv` | 所有请求的原始数据，做自定义分析从这里开始 |
| `control-summary.csv` | 按实验组聚合后的统计 |
| `samples-*.csv` | 单个 path/size/policy/mode 的原始样本 |
| `samples-*-summary.csv` | 单组 mean/P50/P95/P99/stddev |
| `checkpoint-manifest.csv` | checkpoint key/generation/checksum 和 prepare 分项 |
| `environment.txt` | 源码提交、Docker/OpenWhisk 版本和实验参数 |
| `analysis-summary.md` | 最终数据概览 |
| `dmesg-2200.log`、`dmesg-2201.log` | 实验后内核检查 |
| `SHA256SUMS` | 文件完整性 |

### 19.8 关键结果示例

4 MiB micro 的 client E2E：

| 路径/模式 | mean | P50 | P95 | P99 |
|---|---:|---:|---:|---:|
| Direct invoke | 0.584 ms | 0.474 ms | 1.025 ms | 1.072 ms |
| OpenWhisk invoke | 6.637 ms | 5.654 ms | 12.762 ms | 15.718 ms |
| Direct restore-only | 0.611 ms | 0.538 ms | 1.028 ms | 1.100 ms |
| OpenWhisk restore-only | 6.978 ms | 5.675 ms | 13.890 ms | 16.704 ms |

OpenWhisk invoke 的 action bridge、daemon、restore ioctl 和 kernel restore 均值约为 0.919、0.156、0.030、0.019 ms。再次强调，它们是嵌套区间，不能相加。

最终默认 workload 是 read-only touch：4/64/192 MiB 的 shared leaf data pages 精确为 1024/16384/49152，fallback 均为 `NA`。它证明默认 fast path 的 shared leaf 覆盖；leaf/data CoW 则由前面的内核写入 correctness 测试证明，而不是这份读 benchmark。

## 20. 诊断数据与最终数据的区别

不要只看目录名带日期就默认是正式数据。

诊断目录：

```text
cxlporter/results/cohort-control-20260713-172616/
/home/adonis/cxlfork/remote-backup-20260713/control-plane/diagnostic-throttle/
```

这次运行在 20 个 warmup 和 39 个成功请求后，受到 OpenWhisk standalone 默认 60/min throttle，后续 961 个请求返回 HTTP 429。它很适合说明测试为什么需要错误率、原始行和 environment，但不能用于最终延迟结论。

最终脚本把 invocation limit 显式提高到 100000/min，并拒绝复用参数不一致的旧 standalone 进程。

同理，最终目录之前的 pre-audit 数据曾暴露统计字段问题。修复后的最终结果是 `175429`，分析时应优先使用它。

## 21. dmesg 和资源泄漏检查

功能输出全部 `verify=ok` 仍不够。页表和 VMA bug 可能暂时不影响当前进程，却在退出或稍后 reclaim 时触发 warning。

每轮结束检查：

```bash
for port in 2200 2201 2202; do
  ssh -p "$port" ubuntu@localhost 'sudo dmesg' >"/tmp/dmesg-$port.log"
  grep -Ei 'BUG:|WARNING:|Oops:|use-after-free|Bad pagetable|general protection|non-zero pgtables' \
    "/tmp/dmesg-$port.log" || true
done
```

同时检查：

- readers 最终是否回到 0；
- release 是否成功；
- ghost 是否被 `waitpid()` 回收并补充；
- 没有残留目标 VMA；
- 结果 CSV 列数一致；
- `SHA256SUMS` 能通过。

## 22. 结果文件总索引

### 22.1 远端

```text
~/cxlfork/cxlfork-repro/
├── docs/cxlfork-phase-acceptance-log.md
├── docs/cxlfork-paper-alignment-status.md
├── results/cxlfork-phase13-perf.csv
├── results/unified-touch-*.csv
└── cxlporter/results/
    ├── control-correctness-20260713-175411/
    ├── cohort-control-20260713-175429/
    └── cohort-control-20260713-172616/       # throttle 诊断，非正式数据
```

部分阶段日志最初在 `/tmp`，可能随重启丢失，因此长期分析应使用本地备份。

### 22.2 本地

```text
/home/adonis/cxlfork/remote-backup-20260713/
├── README.md
├── docs/
│   ├── cxlfork-paper-alignment-status.md
│   └── cxlfork-phase-acceptance-log.md
├── logs/
│   ├── cxlfork-stage4-fastpath-30-v2.log
│   ├── cxlfork-stage4-litmus.log
│   ├── cxlfork-stage4-selftest-build.log
│   ├── cxlfork-stage5-abit.log
│   ├── cxlfork-stage5-selftest-build.log
│   └── cxlfork-stage6-concurrency.log
├── results/
│   ├── cxlfork-phase13-perf.csv
│   └── unified-touch-*.csv
├── control-plane/
│   ├── final-correctness/
│   ├── final-benchmark/
│   └── diagnostic-throttle/
├── source/
│   ├── cxlfork-test-final.c
│   ├── cxlfork-uapi-final.h
│   ├── kernel-final.diff
│   └── main-final.diff
└── metadata/
    └── SHA256SUMS-ALL
```

验证最终控制数据：

```bash
cd /home/adonis/cxlfork/remote-backup-20260713/control-plane/final-benchmark
awk '{name=$2; sub(/^.*\//, "", name); print $1 "  " name}' \
  SHA256SUMS | sha256sum -c -
```

2026-07-13 的历史清单保存了远端绝对路径，所以本地校验需要先转换为文件名。当前 benchmark 脚本已经使用相对路径生成新清单。

## 23. 推荐的学习顺序

如果第一次接触系统，建议不要直接运行完整 9400 样本矩阵。

### 第一步：ABI 和 inspect

运行 `abi`，再 prepare 一个 4 MiB key，用 `inspect` 看 state、generation、pages 和 checksum。目标是理解“共享对象是什么”。

### 第二步：readonly restore

只读恢复并比较 `current_pmd_pfn` 与 `shared_leaf_pfn`。目标是理解“真实 shared leaf 的证据”。

### 第三步：MoW 与 MoA

观察写入前后 data PFN 和 PMD PFN。目标是理解 leaf CoW 与 data CoW 的区别。

### 第四步：lifecycle 和 rollback

运行 `v2-lifecycle`、`hold-close`、`v2-rollback`。目标是理解“恢复成功之外，资源如何安全活着和退出”。

### 第五步：litmus 和 MM fail-fast

理解跨 VM CAS 的平台前提，以及原型为什么拒绝某些 Linux MM 操作。

### 第六步：fast/full 和 unified touch

比较默认 admission 与全量验证，再改变 footprint 和 policy。目标是理解复杂度和首次访问成本。

### 第七步：控制面 correctness

阅读 `32-control-correctness.sh` 并对照每个输出文件。目标是把 key/generation 从 VM0 一直跟到 Direct/OpenWhisk 返回。

### 第八步：小规模 benchmark

先覆盖 4 MiB、少量样本：

```bash
cd /home/xtl/cxlfork/cxlfork-repro/cxlporter
FOOTPRINTS=4194304 \
POLICIES=mow \
POOL_SIZES=4 \
MICRO_SAMPLES=20 \
SCALING_SAMPLES=10 \
CONCURRENCY_SAMPLES=20 \
WARMUP=3 \
./scripts/33-benchmark-control-plane.sh
```

确认 schema、error rate、checksum、generation 和 dmesg 后，再运行正式矩阵。小样本只用于调试，不能代替最终统计。

## 24. 新增测试时的检查表

新增机制或 benchmark 时，至少回答：

- 它要证明哪一个具体命题？
- 成功、边界、失败各是什么？
- 是否检查了正确 errno，而不只是非零返回？
- 内容证据之外，是否需要 PFN/PTE/PMD 或 reader 证据？
- 测试是否真的触发目标路径？
- stats 的 supported/valid/path mask 是否匹配？
- 失败后映射、reader、slot 和进程是否回收？
- 是否保存源码提交、环境、原始样本和 dmesg？
- 样本数是否足够支撑要报告的百分位数？
- 结果是否只适用于 QEMU backend，还是已在真实 CXL 设备重新验证？

## 25. 当前测试仍不能证明什么

测试覆盖很广，但必须保留边界：

- 没有证明真实 CXL fabric 的延迟、带宽、NUMA 和 cache 行为。
- 没有证明任意多线程进程能获得透明一致 checkpoint。
- 没有证明真实共享 Maple Tree/VMA leaf attach。
- 没有证明任意进程 IP/SP/TLS 和完整 kernel object graph 恢复。
- 没有覆盖 socket、pipe、epoll、timerfd 和完整 namespace。
- 没有证明每一个 Linux PTE mutation 入口都支持 shared leaf。
- 当前 OpenWhisk action 是 Docker 中的真实 proxy action，但被 CXLfork 恢复和执行的是 VM1 中的合成 C ghost 工作集，不是完整 OpenWhisk language runtime。

测试的价值不在于消除所有限制，而在于让每个已声明能力都具有可重复的输入、明确的成功条件和可审计的原始证据。

---

阅读测试时始终问四个问题：**输入是什么、触发了哪条真实路径、观察了什么硬证据、失败后是否完整清理**。沿着这四步阅读 `cxlfork_test.c`、三个主脚本和结果目录，就能从实验角度建立对整个系统的完整理解。
