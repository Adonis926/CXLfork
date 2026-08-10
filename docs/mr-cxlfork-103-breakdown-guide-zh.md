# HydraRPC + CXLfork + MapReduce 性能测试速查与汇报指南

## 1. 这次测试到底想看什么

这次测试关注的不是“CXLfork 功能有多少”，而是下面这个问题：

> HydraRPC 已经把跨 VM 数据传递放进共享内存，CXLfork 也已经把 4 MiB
> worker 模板的内核 restore 缩短到微秒级以后，一次远端任务为什么还需要
> 两三百微秒才能真正执行？剩余时间花在哪里？

最核心的结果是：正式 CXLfork-preopen 路径的完整 activation 平均约
`288.55 us`，其中内核 restore 只有约 `7.07 us`，占完整时间约 `2.45%`。
大部分时间不是在恢复页表，而是在目标端接收请求、取得 worker、绑定状态、
回收旧 worker、补充进程池和返回响应等软件控制路径中。

## 2. 测试环境是怎么搭起来的

### 2.1 Host 和共享内存

测试服务器是 `xtl@10.0.16.103`：

- host kernel：`6.6.32-shm+`；
- QEMU：9.0.90，KVM/EPT；
- 共享设备：`/dev/dax0.0`，容量 64 GiB，2 MiB 对齐，位于 NUMA node 2；
- 实验期间将设备切为 devdax，结束后已经恢复为 system-ram。

本实验只映射了 DAX 中的 `[4,12) GiB`，没有清空或使用整个设备：

| DAX 范围 | 大小 | 用途 | Guest 看到的接口 |
| --- | ---: | --- | --- |
| `[4,8) GiB` | 4 GiB | CXLfork slot、数据页和 PTE leaf | NVDIMM、`/dev/cxlfork` |
| `[8,10) GiB` | 2 GiB | HydraRPC endpoint 0 | ivshmem，BDF `00:02.0` |
| `[10,12) GiB` | 2 GiB | HydraRPC endpoint 1 | ivshmem，BDF `00:03.0` |

两台 VM 各有 16 vCPU 和 16 GiB 私有 DRAM。VM0 固定到 host CPU 48–67，
VM1 固定到 72–91，私有 DRAM 主要从 node 1 分配。两台 VM 只共享上表三个
窗口，不共享普通内存。

严格来说，这是“真实 `/dev/dax0.0` device-DAX 后端上的 CXL host 实验”。
Guest 看到的是 NVDIMM/ivshmem，而不是原生枚举的 CXL Type-3 PCI 设备；
因此不能把 91 和 103 的性能差异全部解释成 CXL 介质差异。

### 2.2 两台 VM 分别做什么

可以把整个性能路径理解为：

```text
VM0 master/mapper
    │
    │ HydraRPC：把请求写入共享 ivshmem queue
    ▼
VM1 reducer agent
    │
    │ agent 内部的 mr_porter 选择 worker 激活方式
    │ persistent / localfork / prefork / CXLfork
    ▼
VM1 reducer worker 开始访问恢复出的业务状态并执行 callback
    │
    │ HydraRPC：把响应写回共享 queue
    ▼
VM0 master 收到响应
```

这里的 `mr_porter` 是 VM1 agent 进程内部的一个管理对象，不是独立 daemon。
它负责提交 worker 激活请求、取得 worker、调用 CXLfork restore、回收并补充
worker pool。

## 3. 测试脚本有哪些

### 3.1 环境脚本

这些脚本位于 `/home/xtl/cxlfork/cxlfork-repro/`：

| 脚本 | 作用 |
| --- | --- |
| `scripts/real-cxl-103/dax-admin.sh` | `preflight/enter/zero/restore`，安全切换 DAX mode，只清零 `[4,12) GiB`，结束后恢复 host |
| `scripts/start-cxlfork-vms.sh` | 用同一个 DAX backend 启动 VM0、VM1，并设置 CPU/NUMA、NVDIMM 和 ivshmem |
| `scripts/stop-cxlfork-vms.sh` | 只停止本实验 PID file 记录的两台 QEMU |

这些脚本只负责把环境搭起来，不产生最终 breakdown CSV。

### 3.2 主要性能脚本

这些脚本位于 `/home/xtl/cxlfork/mr-distributed/scripts/`：

| 脚本 | 作用 | 是否直接查看 |
| --- | --- | --- |
| `run-motivation-bench.sh` | 构建/部署程序，轮换启动各 worker 模式，运行请求，收集 master/agent 日志，最后生成 CSV | 最主要的入口 |
| `analyze-motivation.py` | 把 `task_result_v3` 和 `hydra_task_v1` 原始日志合并成逐请求 `tasks.csv`，再生成统计表 | 通常由 runner 自动调用 |
| `check-motivation-results.py` | 检查样本数、warmup、状态、时间边界和统计合法性，生成 `validation.json` | 看测试是否可用 |

`run-cxlfork-litmus.sh` 和 `test-state-binding.sh` 是正式性能测试前的正确性
门槛，不是本次性能汇报重点，因此本文不展开。

## 4. 正式测试包含哪些组

### 4.1 核心 activation 矩阵

核心矩阵独立运行了三轮。每一轮中，每种模式有 1000 个 measured 请求，
另外有 warmup；10 个 block 会轮换模式顺序，避免某个模式永远先跑或后跑。

```bash
cd /home/xtl/cxlfork/mr-distributed

HYDRARPC_ROOT=/home/xtl/cxlfork/HydraRPC \
scripts/run-motivation-bench.sh \
  --output-dir="$RESULT" \
  --samples=1000 --warmups=50 --workers=4 --activation-blocks=10 \
  --modes=persistent,localfork,local-prefork,cxlfork-preopen,cxlfork-per-request \
  --template-bytes-list=4194304 --policy=mow --validation=fast
```

五种模式的通俗含义：

| 模式 | 含义 |
| --- | --- |
| persistent | reducer worker 已经存在，只传请求，不创建新执行上下文；可看作 HydraRPC + 已存在 worker 的基线 |
| localfork | VM1 用普通 Linux fork 创建 reducer worker |
| local-prefork | 预先准备 worker pool，请求到达时取出一个，完成后 reap 并 refill |
| cxlfork-preopen | worker pool + CXLfork；`/dev/cxlfork` 和 capability 在请求前已经打开/查询 |
| cxlfork-per-request | 与上一项相同，但每个请求重新 open device、query caps 和检查 policy |

这些模式只改变 VM1 reducer worker 的激活方式；上层请求仍通过同一套 HydraRPC
共享队列传输。

### 4.2 单变量对照

每组各 1000 个 measured 请求：

- MoA、Hybrid、readonly；
- MoW full validation；
- 4 MiB、64 MiB、256 MiB template scaling。

这样可以分别观察复制策略、逐 PTE 验证和 footprint 对 restore 的影响。

### 4.3 真实 WordCount job

使用与 91 基线相同的 256,000-byte 输入，localfork 和 CXLfork-preopen 各跑
100 个独立 job。该测试测的是完整 map、HydraRPC shuffle、reduce 和输出收集，
不是单独的 worker activation。

## 5. Breakdown 字段应该怎么理解

### 5.1 最重要的计时边界

| 字段 | 通俗含义 |
| --- | --- |
| `roundtrip_ns` | VM0 发起一次请求，到 VM0 收到响应；最外层、最重要的端到端 activation 时间 |
| `master_request_send_wall_ns` | VM0 把请求组织并发布到 HydraRPC queue 的本地 CPU 时间 |
| `cross_vm_delay_estimate_ns` | 根据请求/响应两边 duration 估出的跨 VM 传播部分；不是直接相减两台 VM 的绝对时钟 |
| `hydra_server_stack_ns` | VM1 agent 收到请求到准备好响应；它包含 worker 激活、执行、回收和 refill，不能当作“纯 HydraRPC 库开销” |
| `target_to_state_ready_ns` | VM1 收到请求到 worker 的恢复状态已经可用 |
| `target_to_first_state_access_ns` | VM1 收到请求到 worker 第一次真正读取恢复出的业务状态 |
| `restore_wrapper_ns` | MR 的 CXLfork restore 包装层，包括 session、policy、ioctl 和 post-check |
| `resume_ioctl_ns` | 用户态进入 `RESUME_V2` 到 ioctl 返回 |
| `kernel_total_ns` | 真正位于 CXLfork kernel restore 内的时间 |
| `target_bind_ns` | restore 后，把 worker 与 WordCount role、checksum 和业务状态绑定起来 |
| `target_reap_ns` | 本次 worker 完成后，目标端回收它 |
| `target_refill_ns` | 为下一次请求重新补充 worker/ghost pool |
| `target_response_send_wall_ns` | VM1 构造并发布 HydraRPC 响应的本地 CPU 时间 |
| `cross_os_unassigned_ns` | 外层 roundtrip 扣掉可明确归属区间后的很小残余项 |

### 5.2 为什么不能把这些数字全部相加

它们是嵌套关系，不是互斥账单：

```text
roundtrip
├── 请求发布与跨 VM 传递
├── hydra_server_stack
│   ├── target_to_state_ready
│   │   ├── restore_wrapper
│   │   │   └── resume_ioctl
│   │   │       └── kernel_total
│   │   └── target_bind
│   ├── worker 访问状态并执行业务
│   ├── target_reap
│   └── target_refill
└── 响应发布与跨 VM 返回
```

例如 `7.07 us kernel_total` 已经包含在 `9.12 us resume_ioctl` 里面，后者又
包含在 `11.91 us restore_wrapper` 里面。汇报时只能比较同一层边界，不能把
三者相加成 28 us。

## 6. 关键性能结果

### 6.1 五种 activation 模式

下表是三轮各自 mean 再取平均；每轮的原始分布和 P99 仍独立保存：

| 模式 | 完整 roundtrip mean | 直观理解 |
| --- | ---: | --- |
| persistent | 28.13 us | HydraRPC + 已存在 worker 的最短基线 |
| localfork | 348.23 us | 普通 fork 的完整远端激活 |
| local-prefork | 364.10 us | 当前实现把 pool 的 reap/refill 也放在响应关键路径中 |
| CXLfork-preopen | 288.55 us | 正式 CXLfork 主路径 |
| CXLfork-per-request | 287.17 us | 总 roundtrip 被 reap/refill 波动掩盖，不能据此说重复 open 更快 |

CXLfork-preopen 三轮 roundtrip 分别为 `288.23/288.46/288.96 us`，说明重复性
很好。其 kernel restore 分别为 `7.11/7.04/7.06 us`。

### 6.2 CXLfork-preopen 的主要 breakdown

| 区间 | 三轮 mean 的平均值 | 与最外层关系 |
| --- | ---: | --- |
| 完整 roundtrip | 288.55 us | 最外层 |
| Hydra server stack | 276.37 us | 包含 VM1 上的激活、执行、reap/refill |
| 收到请求到 state ready | 25.79 us | 包含 restore 和 bind |
| 收到请求到第一次访问状态 | 33.65 us | 包含上一项，不与上一项相加 |
| restore wrapper | 11.91 us | 包含 ioctl |
| resume ioctl | 9.12 us | 包含 kernel restore |
| kernel restore | 7.07 us | 只占完整 roundtrip 约 2.45% |
| state bind | 8.74 us | restore 后的应用状态绑定 |
| worker reap | 68.65 us | 完成后的控制路径 |
| pool refill | 156.62 us | 完成后的控制路径，当前最大的软件阶段 |
| VM0 request publish | 3.19 us | HydraRPC 发送端本地工作 |
| VM1 response publish | 7.11 us | HydraRPC 响应端本地工作 |
| 跨 VM delay estimate | 1.77 us | 估算值 |
| cross-OS unassigned | 1.17 us | 未明确归属的残余 |

最适合汇报的解释是：

- persistent 为 28.13 us，而 CXLfork-preopen 为 288.55 us，二者相差约
  260 us，这部分大体代表“已有 worker”之外新增的远端激活生命周期；
- kernel restore 只有 7.07 us，占完整 CXLfork activation 的 2.45%；
- reap + refill 约为 225 us，是当前关键路径中最明显的控制面成本；
- 因此继续只优化页表 restore，已经无法显著降低完整 activation；更有价值的
  方向是缩短或异步化目标端 worker 回收、pool refill 和调度控制路径。

这个 260 us 是跨模式的近似差值，不是严格可加的独立组件；两种模式的 pool
行为不同，论文中应把它称为观测到的“额外 worker lifecycle”，不要称为纯
跨 OS 网络延迟。

### 6.3 Preopen 到底有没有作用

总 roundtrip 中，preopen 与 per-request 很接近，是因为两组的 reap/refill
波动不同，掩盖了前端 setup 差异。但只看相同的目标激活边界：

| 字段 | preopen | per-request |
| --- | ---: | ---: |
| target to state ready | 25.79 us | 52.62 us |
| restore wrapper | 11.91 us | 32.11 us |
| resume ioctl | 9.12 us | 9.12 us |
| kernel restore | 7.07 us | 7.07 us |

因此 preopen 确实省掉了约 20 us 的 device/capability/policy setup；它没有改变
kernel restore，只是缩短用户态包装层。

### 6.4 Policy、validation 和 footprint

| 对照 | roundtrip mean | kernel mean | 主要原因 |
| --- | ---: | ---: | --- |
| MoW fast，4 MiB | 288.55 us | 7.07 us | 正式主路径 |
| MoA fast，4 MiB | 292.50 us | 5.54 us | 本次业务只首次访问一个状态页 |
| readonly fast，4 MiB | 295.02 us | 9.02 us | 保持共享只读页 |
| Hybrid fast，4 MiB | 1032.39 us | 612.97 us | 4 MiB template 的 1024 页均 dirty，restore 时全部 prefault |
| MoW full validation，4 MiB | 7466.34 us | 7151.95 us | 每次逐一扫描 1024 个 PTE |

full validation 比默认 fast restore 慢约三个数量级。这说明 correctness/debug
全量验证不能放进正式 fast path。

| Template | PTE leaf 数 | roundtrip mean | kernel mean | 一次性 template publish |
| --- | ---: | ---: | ---: | ---: |
| 4 MiB | 2 | 288.78 us | 7.09 us | 约 8.8 ms |
| 64 MiB | 32 | 298.43 us | 11.15 us | 约 140 ms |
| 256 MiB | 128 | 327.31 us | 23.51 us | 约 562 ms |

publish/checkpoint 是模板准备时的一次性成本，不属于每个 restore。fast restore
会随 PTE leaf 数增加，但没有像 full validation 那样随 4 KiB 页数退化到毫秒级。

### 6.5 WordCount 端到端结果

| 模式 | 独立 job 数 | mean | P50 | P95 |
| --- | ---: | ---: | ---: | ---: |
| CXLfork-preopen | 100 | 44.514 ms | 44.463 ms | 45.090 ms |
| localfork | 100 | 44.763 ms | 44.734 ms | 45.263 ms |

200 个输出全部正确。WordCount 总时间约 44 ms，远大于 7 us kernel restore，
所以这一组主要说明：在真实工作流中，单独优化 restore 对完整 job 的影响很小。
每种模式只有 100 个独立 job，因此只报告 mean/P50/P95/标准差，不报告 P99。

## 7. 最终结果文件在哪里

### 7.1 103 上的权威结果

根目录：`/home/xtl/start/hpca-cxlfork/results/`

| 目录 | 内容 |
| --- | --- |
| `real-dax-core-r1-20260810T083212Z/` | 核心五模式正式第 1 轮 |
| `real-dax-core-r2-20260810T083617Z/` | 核心五模式正式第 2 轮 |
| `real-dax-core-r3-20260810T084014Z/` | 核心五模式正式第 3 轮 |
| `real-dax-secondary-20260810T084427Z/` | MoA、Hybrid、readonly、full-validation 和 scaling |
| `real-dax-wordcount-20260810T085254Z/` | 200 个真实 WordCount job |
| `real-dax-final-audit-20260810T091100Z/` | 环境、Git、DAX 映射、数据审计和 SHA256 manifest |

### 7.2 本地跳板机备份

完整副本位于：

`/home/adonis/cxlfork/real-cxl-103-results/real-dax-20260810/`

共 3,085 个 raw result 文件通过 SHA256 校验，不只是 summary。

### 7.3 每个结果目录中最值得看的文件

| 文件 | 怎么用 |
| --- | --- |
| `tasks.csv` | 最重要的逐请求原始表；一行对应一个 task，包含 HydraRPC、worker、restore 和 kernel 全部字段 |
| `summary.csv` | 按 scenario/metric 汇总的 n、mean、标准差、P50、P95、P99；适合直接画图和汇报 |
| `metadata.txt` | 样本数、warmup、worker 数、policy、validation、Git commit |
| `run-manifest.csv` | 实际跑了哪些 scenario、每组预期多少样本 |
| `validation.json` | `validation_errors` 必须为空；同时说明 P99 和时钟规则 |
| `raw/<scenario>/master.log` | 最原始的 `task_result_v3` 与 `hydra_task_v1`；CSV 有疑问时回到这里 |
| `raw/<scenario>/agent*.log` | VM0/VM1 agent 原始日志 |
| `jobs.csv`、`job-summary.csv` | 只在 WordCount 结果中使用；一个独立 job 一行 |

最快的查看方式：

```bash
cd /home/adonis/cxlfork/real-cxl-103-results/real-dax-20260810/results/

R1=real-dax-core-r1-20260810T083212Z
grep 'probe_cxlfork_preopen_4194304,roundtrip_ns' "$R1/summary.csv"
grep 'probe_cxlfork_preopen_4194304,kernel_total_ns' "$R1/summary.csv"

WC=real-dax-wordcount-20260810T085254Z
cat "$WC/job-summary.csv"
cat "$WC/validation.json"
```

`summary.csv` 中只有样本数至少 500 的 scenario 才会填写 P99。三轮核心测试
每种模式各有 1000 个样本，可以报告 P99；WordCount 每种模式只有 100 个
独立 job，P99 列故意为空。

## 8. 给学长汇报时可以怎么说

可以直接概括为：

> 我们在 103 的真实 device-DAX 环境上跑通了 HydraRPC + CXLfork +
> MapReduce 双 VM 系统，并做了三轮、每模式 1000 次的 worker activation
> breakdown。CXLfork-preopen 的完整远端 activation 平均约 289 微秒，但
> 内核 restore 只有约 7 微秒，占 2.45%。最大的剩余开销不是页表恢复，而是
> 目标端 worker 的回收和 pool refill，合计约 225 微秒。把设备和 capability
> 预打开可以把 restore 包装层从约 32 微秒降到 12 微秒，但不会改变 7 微秒的
> kernel restore。4 到 256 MiB 的 fast restore 只从约 7 微秒增长到 24 微秒，
> 而逐 PTE full validation 会达到 7.15 毫秒。真实 WordCount 中 kernel restore
> 相对 44 毫秒 job 总时长几乎可以忽略。这些结果支持我们的动机：共享数据和
> 页表并不等于远端执行上下文已经就绪，数据面优化之后，主要问题转移到了跨
> OS 的 worker 生命周期和控制路径。

最后要主动说明两个边界：当前 guest 使用 NVDIMM/ivshmem 接口，不是原生
CXL Type-3 枚举；当前 CXLfork 恢复的是受限匿名 worker 模板和业务状态，
不是任意 Linux 进程从保存的 IP/SP 透明继续运行。
