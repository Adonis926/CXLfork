# 从一次请求看懂 HydraRPC + CXLfork + MapReduce 系统与 Breakdown

## 1. 本文只研究一条代表性路径

本文不再比较所有策略，也不追求完全复刻 CXLfork 论文的指标体系。我们只选
当前系统最有代表性、最接近后续研究使用方式的一条路径：

```text
4 MiB reducer template
+ CXLfork-preopen
+ MoW
+ fast validation
+ 4-worker 静态 pool
+ activation probe
```

选择它的原因是：

- `CXLfork-preopen` 代表稳定运行后的热路径，device 和 capability 已提前准备；
- `MoW` 是当前共享数据页、写时本地化的主路径；
- `fast validation` 不会为每次 restore 扫描 1024 个 PTE；
- 4 MiB 是当前 MR worker template 的实际默认大小；
- activation probe 会恢复 worker、校验并读取一次业务状态，然后立即返回，
  尽量减少 WordCount 计算本身对控制路径的遮挡。

我们的目标只有两个：

1. 一次远端 worker activation 依次经过哪些进程和软件阶段；
2. 哪些阶段最耗时，为什么耗时，以及下一步最值得优化什么。

核心结论先放在这里：这条路径的完整时间约为 `288.55 us`，真正的 CXLfork
kernel restore 只有 `7.07 us`。最大开销是 worker 执行完成后的同步 reap 和
pool refill，合计约 `225.27 us`。

## 2. 系统里有哪些进程和内存

### 2.1 进程角色

一次测试启动后，系统中主要有以下进程：

| 位置 | 角色 | 存在形式 | 作用 |
| --- | --- | --- | --- |
| VM0 | master | 独立进程 | 发出 activation probe，等待结果，记录最外层 roundtrip |
| VM0 | mapper agent | 独立进程 | 完整 MR 环境的一部分；本次 reducer probe 不经过它的 worker 路径 |
| VM1 | reducer agent | 独立进程 | 从 HydraRPC queue 取请求，解析并交给本地 porter |
| VM1 agent 内 | `mr_porter` | C 对象，不是进程 | 保存本地共享 slot、busy 状态和与 supervisor 的 socket |
| VM1 | porter supervisor | agent `fork()` 出来的子进程 | 管理 worker pool，唤醒、回收和重新创建 worker |
| VM1 | reducer workers | supervisor 创建的子进程 | 调用 CXLfork restore，绑定状态，执行 callback |
| VM1 kernel | CXLfork driver/core-MM | 内核代码 | 查 slot、建 VMA/上层页表、attach shared PTE leaf |

`mr_porter` 本身只是 agent 地址空间中的管理对象，但它会 `fork()` 一个真正的
supervisor 子进程。supervisor 再维护 4 个真正的 worker 子进程。因此“porter
不是进程”和“系统里有 porter supervisor 进程”并不矛盾。

### 2.2 三种通信和共享内存不要混淆

当前系统同时使用三种不同通道：

| 通道 | 跨不跨 VM | 底层 | 传什么 |
| --- | --- | --- | --- |
| HydraRPC | 跨 VM | `/dev/dax0.0` 上的 ivshmem queue | 请求、响应和 WordCount shuffle 数据 |
| CXLfork | 跨 VM | `/dev/dax0.0` 上的 NVDIMM window | worker template、数据页、PTE leaf、generation/checksum |
| mr_porter 本地通道 | 只在 VM1 内 | `MAP_SHARED | MAP_ANONYMOUS` + Unix `SOCK_SEQPACKET` socketpair | agent、supervisor、worker 之间的命令、slot 和结果 |

所以，一次请求并不是“写一个 CXL 共享变量然后直接开始执行”。它至少要从
HydraRPC queue 进入 VM1 agent，再经过本地 porter/supervisor，最后由 worker
调用 CXLfork restore。

## 3. 发请求前，系统已经准备了什么

正式计时前会先完成以下准备：

1. VM0 创建一个 4 MiB 匿名 reducer template，写入 WordCount worker state；
2. VM0 调用 `PREPARE_V2`，把 template 发布到 CXLfork slot，得到 key、
   generation、page checksum 和 state checksum；
3. VM1 reducer agent 启动 porter supervisor；
4. supervisor 预先创建 4 个 worker 子进程；
5. 每个 worker 提前打开 `/dev/cxlfork`、查询 capability、检查 policy，然后在
   本地 porter slot 上自旋等待任务。

注意：这些 ghost worker 此时只是“已经存在、已经 preopen、正在等待”的本地
进程。它们还没有为本次请求 restore template。真正的 `RESUME_V2` 仍要在请求
到达后由被唤醒的 worker 调用。

一次 template publish 平均约 8.8 ms，但这是请求开始前的一次性准备，不属于
每次 288.55 us activation。

## 4. 跟着一条请求走完整流程

下面使用三轮正式测试的平均值讲解。括号中的字段名就是 `tasks.csv` 中可以
找到的列。

### 阶段 A：VM0 把请求发布到 HydraRPC

master 构造一个很小的 activation probe：指定目标是 VM1 reducer worker，
同时携带期望的 role 和 state checksum。HydraRPC 为消息分配 queue slot、写
header/payload/checksum，然后发布 READY 状态。

平均耗时：`3.19 us`（`master_request_send_wall_ns`）。

这只是 VM0 本地组织和发布请求的 CPU 时间，不等于全部 HydraRPC 时间。

### 阶段 B：请求跨 VM，被 VM1 agent 取到

VM1 reducer agent 轮询自己的 ivshmem request queue。看到 READY 后读取消息，
记录 `agent_recv_ns`，然后解析 MR wire header。

- 跨 VM 往返传播部分的估计：`1.77 us`（`cross_vm_delay_estimate_ns`）；
- VM1 请求解析：约 `0.135 us`（`target_parse_ns`）。

`cross_vm_delay_estimate_ns` 是根据请求和响应的四个边界估算的诊断值，不与
后面的 `cross_os_unassigned_ns` 相加。

### 阶段 C：agent 把请求交给本地 porter

agent 根据 task/partition 选择一个空闲 worker，把 payload 复制到
`mr_porter` 的本地匿名共享 slot，再通过 Unix socketpair 给 supervisor 发送
dispatch 命令。

平均耗时：

- payload 复制：`0.086 us`；
- agent 到 supervisor 命令传递：`3.31 us`；
- supervisor 检查并发布 slot READY：`0.10 us`。

这里不是 HydraRPC，也不是 CXLfork，而是 VM1 内部的进程间控制路径。

### 阶段 D：supervisor 唤醒一个预建 worker

代表性模式已经有 4 个 worker 在自旋等待。supervisor 不需要在请求前临时
fork worker，只需把对应 slot 设为 READY。worker 观察到 READY 后进入
`worker_run_one()`。

平均唤醒时间：`0.65 us`（`target_worker_wakeup_ns`）。

### 阶段 E：worker 执行 CXLfork restore

worker 进入 CXLfork wrapper，分配一次 restore session，检查 policy，然后调用
`RESUME_V2`：

| 子阶段 | 平均时间 |
| --- | ---: |
| session 分配 | 2.17 us |
| policy check | 0.082 us |
| `RESUME_V2` ioctl | 9.12 us |
| restore post-check | 0.137 us |
| 完整 restore wrapper | 11.91 us |

device open 和 query caps 不在这 11.91 us 中，因为 worker 在创建时已经完成
preopen。它们的一次性平均时间分别约 5.30 us 和 3.34 us。

这些数有包含关系：11.91 us wrapper 包含 9.12 us ioctl，9.12 us ioctl 又包含
7.07 us kernel restore，不能相加成 28.10 us。

### 阶段 F：7.07 us 的 kernel restore 内部做了什么

V3 kernel stats 的子项是互斥计时，可以相加得到 `kernel_total`：

| Kernel 子阶段 | 平均时间 | 占 kernel restore | 做什么 |
| --- | ---: | ---: | --- |
| VMA 创建 | 3.09 us | 43.7% | 根据 template metadata 在目标 mm 中建立受限 VMA |
| 上层页表分配 | 1.40 us | 19.8% | 分配本地 PGD/P4D/PUD/PMD 层级 |
| slot lifecycle | 1.13 us | 15.9% | generation、reader、restore context 生命周期 |
| kernel other | 0.67 us | 9.5% | 已归入 restore 总区间的其他短控制代码 |
| shared leaf attach | 0.229 us | 3.2% | 让目标 PMD 指向共享 CXL PTE leaf |
| manifest validation | 0.220 us | 3.1% | 检查发布时生成的 metadata manifest |
| lock wait | 0.201 us | 2.8% | 内核锁等待 |
| 地址冲突检查 | 0.129 us | 1.8% | 确认 restore 地址没有被占用 |
| 合计 | 7.07 us | 100% | `kernel_unaccounted_ns=0` |

这个结果说明两件事：

1. shared PTE leaf attach 本身已经非常短，只有约 0.23 us；
2. 即使只看 kernel，主要成本也来自 VMA 重建和本地上层页表分配，而不是 leaf
   attach。当前并未实现真实跨 OS Maple Tree/VMA leaf sharing，所以 VMA 仍要
   在目标 mm 中创建。

fast path 中 `pte_validate/image/checksum/fallback` 等字段为 0，是因为这些阶段
没有进入本次路径，不代表“做了这些工作但没有成本”。该路径的证据是
`path_mask=5`、每次 `shared_leaf_count=2`、`shared_data_pages=1024`、
`fallback_pages=0`、`validated_ptes=0`。

### 阶段 G：把恢复的内存与 WordCount 业务绑定

ioctl 成功并不代表 worker 可以直接跑业务。worker 随后执行
`mr_template_bind()`：

- 检查 template role 必须是 reducer；
- 检查 generation、page checksum 和 state checksum；
- 找到 `MR_WorkerStateV1`；
- 建立本次 callback 使用的业务状态引用。

平均耗时：`8.74 us`（`target_bind_ns`）。

从 VM1 agent 收到请求到 state ready 的累计时间为 `25.79 us`；这个累计值
已经包含请求解析、porter handoff、worker 唤醒、restore 和 bind，不能再和
11.91 us restore 相加。

### 阶段 H：worker 真正读取状态并执行 callback

activation probe 的 callback 会调用 `MR_GetWorkerState()`，检查 checksum，
读取 `value_scale/role`，计算一个 proof 并返回。这一步故意很小，目的是证明
恢复出的状态真的被业务消费，同时避免 WordCount 计算掩盖控制面。

- 从 agent 收到请求到第一次访问状态：`33.65 us`，这是累计时间；
- callback/business 本身：约 `8.23 us`。

到这里，本次 worker 实际已经完成了有意义的业务动作。

### 阶段 I：worker 收集 restore 统计并退出

worker 收集本次 restore/fault stats，结束 CXLfork session，把 response 放回
本地 porter slot，发布 DONE，然后退出。supervisor 观察到 DONE 后才开始下面
两个最昂贵的阶段。

### 阶段 J：supervisor 同步 reap 旧 worker

当前 CXLfork worker 是一次性子进程。任务完成后，supervisor 在请求关键路径
中调用 `waitpid()` 等待它完全退出。

平均耗时：`68.65 us`（`target_reap_ns`），约占完整 roundtrip 的 23.8%。

这里测到的不只是一个系统调用，还包含 worker 退出、mm/VMA/页表释放以及
调度器让 supervisor 再次运行的时间。

### 阶段 K：supervisor 同步补充 worker pool

为了让 pool 恢复到 4 个可用 worker，supervisor 立即 `fork()` 一个替代
worker，并同步等待它完成：

1. 新建进程；
2. 初始化 worker；
3. preopen `/dev/cxlfork`；
4. query caps、检查 policy；
5. 设置 `worker_ready=1`。

平均耗时：`156.62 us`（`target_refill_ns`），约占完整 roundtrip 的 54.3%。

这是当前最大的单项开销。虽然它发生在本次 callback 已经完成以后，但源码中
supervisor 要等 refill 完成后才把 completion reply 发给 agent，所以它仍在
master 观察到的 roundtrip 关键路径中。

reap + refill 合计约 `225.27 us`，占完整 288.55 us 的约 78.1%。这正是本
case study 最重要的观察。

### 阶段 L：VM1 返回结果，VM0 结束计时

agent 收到 supervisor completion，编码 `task_result_v3` 和业务 proof，调用
HydraRPC 发布 response。VM0 master 轮询到响应、读取并释放 message slot，
停止 roundtrip 计时。

- VM1 response publish：`7.11 us`；
- VM0 response consume：约 `0.71 us`；
- 顶层未明确归属的 residual：`1.17 us`。

最终得到完整 `roundtrip_ns = 288.55 us`。

## 5. 顶层 Breakdown：哪些数字可以相加

最外层只有下面五项是按分析脚本定义拆开的：

| 顶层互斥区间 | 三轮平均 |
| --- | ---: |
| VM0 request publish | 3.19 us |
| VM1 Hydra server stack | 276.37 us |
| VM1 response publish | 7.11 us |
| VM0 response consume | 0.71 us |
| cross-OS unassigned residual | 1.17 us |
| 合计 | 288.55 us |

这里的 `Hydra server stack` 不是“HydraRPC 库本身用了 276 us”。它的定义是
VM1 agent 收到请求到准备发送响应，因此把 restore、callback、reap 和 refill
全包含进去了。

可以把它进一步近似拆成：

| VM1 server stack 中的主要互斥阶段 | 平均 |
| --- | ---: |
| parse + 本地 porter handoff + worker wakeup | 约 4.28 us |
| restore wrapper | 11.91 us |
| template/business state bind | 8.74 us |
| activation probe business | 8.23 us |
| worker reap | 68.65 us |
| worker refill | 156.62 us |
| 其余 collect、poll、encode、状态转换和调度间隙 | 约 17.94 us |
| 合计 | 276.37 us |

第二张表是为了找大头的近似归因。正式作图时仍应以 `tasks.csv` 的原始字段和
第一张顶层互斥表为准。

## 6. 用一条真实请求把数字串起来

下面这条请求来自 R1 block 02，是三轮 3000 个 CXLfork-preopen measured
请求中最接近总体中位数的一条：

```text
scenario = probe_cxlfork_preopen_4194304_block02
task     = 9223372036854775923
roundtrip = 285.171 us
```

它实际经历了：

```text
VM0 发布 Hydra 请求                  3.312 us
  ↓
跨 VM delay estimate                1.592 us   # 诊断值，不直接相加
  ↓
VM1 解析请求                         0.139 us
VM1 payload → porter slot            0.083 us
agent → supervisor 命令              3.860 us
supervisor gate                      0.101 us
唤醒预建 worker                      0.680 us
  ↓
CXLfork restore wrapper             11.248 us
  └─ RESUME_V2 ioctl                 8.713 us
     └─ kernel restore               6.874 us
业务状态 bind                        8.612 us
第一次访问恢复状态：距 agent recv     36.287 us  # 累计值
activation callback                  9.287 us
  ↓
reap 旧 worker                      66.190 us
refill 新 worker                   155.626 us
  ↓
VM1 发布 Hydra response              6.765 us
VM0 消费 response                    0.667 us
未归属 residual                      0.906 us
  ↓
完整 roundtrip                     285.171 us
```

这条单请求与三轮平均非常接近，说明 288.55 us 的结论不是由少数极端值产生。

## 7. 我们真正应该从结果中得到什么

### 7.1 当前大头不是 CXLfork kernel

kernel restore 只占 2.45%，shared leaf attach 更只占完整 roundtrip 的约
0.08%。继续把 7 us 优化成 5 us，对 289 us 的完整路径影响很小。

### 7.2 当前最大问题是同步 worker 生命周期

worker callback 已经结束，系统却还要同步等待旧进程退出并创建替代 worker，
之后才允许 agent 返回响应。reap/refill 合计占 78.1%。

这为后续研究提供了很清楚的方向：

- response 是否可以在 business result 和必要 stats 已经安全收集后先返回；
- refill 是否可以异步化，与下一次请求或响应传输重叠；
- 是否可以批量维护 pool 水位，而不是每个请求同步补 1 个；
- 是否可以复用 worker 执行壳，只替换受限地址空间/状态；
- supervisor、agent 和 worker 之间是否需要当前这么多同步和轮询边界。

### 7.3 “跨 OS 控制面”不等于“网络延迟”

跨 VM delay estimate 只有约 1.77 us，顶层 residual 也只有约 1.17 us。真正
大的控制开销发生在目标 OS 内部：进程退出、fork、调度、preopen、等待 pool
ready。论文中应把它描述为“跨 OS 请求触发的目标端执行上下文生命周期”，
而不是笼统称为 CXL 通信延迟。

### 7.4 为什么不把 44 ms WordCount 当主要 Breakdown

完整 WordCount job 平均约 44.5 ms，包含 map、shuffle、reduce、输出收集和
多个 task。7 us restore 在其中几乎不可见，难以回答控制路径为什么慢。

因此：

- activation probe 用来研究 worker 从请求到真正开始执行的控制路径；
- WordCount 只用来证明这套激活机制能够支撑真实业务，并观察端到端占比；
- 后续 Motivation 图应优先使用代表性 activation 路径，而不是罗列所有
  MoA/Hybrid/full-validation 策略。

## 8. 去哪里查看对应原始数据

本地完整备份：

`/home/adonis/cxlfork/real-cxl-103-results/real-dax-20260810/results/`

代表性三轮：

- `real-dax-core-r1-20260810T083212Z/`；
- `real-dax-core-r2-20260810T083617Z/`；
- `real-dax-core-r3-20260810T084014Z/`。

最重要的文件：

| 文件 | 用途 |
| --- | --- |
| `tasks.csv` | 一行一个请求，本文所有阶段都能在列中找到；做新分析时优先读它 |
| `summary.csv` | mean/P50/P95/P99/标准差；快速查图表数据 |
| `raw/<scenario>/master.log` | 最原始 `task_result_v3`、`hydra_task_v1`，用于核查 timestamp |
| `metadata.txt` | Git commit、样本数、worker 数、policy 和 validation |
| `validation.json` | `validation_errors=[]` 才能使用该组数据 |

快速查看核心数字：

```bash
cd /home/adonis/cxlfork/real-cxl-103-results/real-dax-20260810/results
R1=real-dax-core-r1-20260810T083212Z

grep 'probe_cxlfork_preopen_4194304,roundtrip_ns' "$R1/summary.csv"
grep 'probe_cxlfork_preopen_4194304,kernel_total_ns' "$R1/summary.csv"
grep 'probe_cxlfork_preopen_4194304,target_refill_ns' "$R1/summary.csv"
```

## 9. 给学长汇报时最简洁的版本

> 我们没有把重点放在复刻 CXLfork 论文的所有策略，而是选了一条最有代表性
> 的 4 MiB CXLfork-preopen + MoW fast path，跟踪一次远端 reducer worker 从
> HydraRPC 请求到 callback 真正读取恢复状态、再到响应返回的全过程。完整
> activation 平均约 289 微秒，其中 CXLfork kernel restore 只有 7 微秒，
> shared PTE leaf attach 只有 0.23 微秒。最大的开销反而发生在 callback 完成
> 之后：退出旧 worker 约 69 微秒，同步 fork 并 preopen 一个替代 worker 约
> 157 微秒，二者占完整路径约 78%。所以我们的 case study 说明，数据共享和
> 页表恢复被优化后，主要瓶颈已经转移到目标 OS 内的进程生命周期、调度和
> pool 管理。这正是后续研究跨 OS 控制路径的动机。

需要同时说明：当前恢复的是受限匿名 worker template 和业务状态，不是任意
Linux 进程从保存的 IP/SP 透明继续运行；guest 使用 NVDIMM/ivshmem 接口，
因此结果用于研究软件路径分解，不用于宣称原生 CXL Type-3 的绝对硬件延迟。
