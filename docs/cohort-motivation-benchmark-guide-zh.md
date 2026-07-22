# HydraRPC + CXLfork Motivation 性能测试说明

## 1. 这轮测试要回答什么

这轮工作不试图证明当前原型是生产级 remote fork，也不把 CXLfork 内核 restore
等同于“任意进程已经在远端从原 IP/SP 继续执行”。它只回答 Cohort 论文 Motivation
所需的问题：

> 当 HydraRPC 已经把跨 VM 请求和 payload 放入共享内存、CXLfork 已经避免按页面重建
> 数据地址空间之后，从请求发布到目标 worker 真正读到恢复状态并进入业务逻辑，仍然有
> 多少跨 OS 控制路径开销？其中内核 restore 占多少？

当前受测 worker 使用受限匿名地址空间模板。WordCount 的字符分类、大小写转换、hash、
数值解析和 value-scale 参数来自 template 中的 `MR_WorkerStateV1`；每个任务必须实际读取
它，并返回 checksum、access count 和 binding flags。因此测试不是只执行一个空 ioctl，
而是把 CXLfork restore 与真实业务状态消费绑定在同一条 worker 激活路径中。

## 2. 代码与分支

所有正式数据来自同名专用分支：

- 主仓库：`/home/xtl/cxlfork/cxlfork-repro`
- kernel：`/home/xtl/cxlfork/cxlfork-repro/kernel/linux-6.6.32`
- MR/HydraRPC 集成：`/home/xtl/cxlfork/mr-distributed`
- 分支：`cohort-motivation-control-plane-measurement`

关键提交：

- kernel `a1d1f8fef`：增加 V3 单次 restore 排他统计；
- MR `4af1d70`：激活时间线、application-state probe 和 preopen restore context；
- MR `97d1a68`：runner、CSV 转换和 fail-closed checker；
- MR `14c4560`：四时间点跨 VM 校准和 job 级统计；
- MR `c52a7ca`：修复 Hydra endpoint 旧 layout 附着竞态；
- MR `0d02e33`：增加 master/agent/start 三方 barrier，并按 policy 验证真实路径；
- MR `5879520`：补充可复现实验说明；
- MR `7a67dd9`：记录分析器版本，并增加 95% 置信区间。

## 3. 一次请求经过哪些阶段

受测路径如下：

```text
VM0 master
  -> Hydra request allocation/copy/publish
  -> VM1 agent receive + parse
  -> porter payload copy + supervisor command
  -> supervisor publish READY
  -> worker observes slot
  -> CXLfork restore wrapper
       -> RESUME_V2 ioctl
            -> VMA / upper page table / shared leaf 或 policy 特定路径
       -> ioctl result postcheck
  -> template bind
  -> state_ready
  -> business_entry
  -> first MR_WorkerStateV1 access
  -> Mapper/Reducer/probe callback
  -> task done
  -> CXLfork per-call stats collect
  -> worker reap + pool refill（非 persistent）
  -> agent response encode
  -> Hydra response publish
  -> VM0 master receive
```

`state_ready` 表示 restore 和 template bind 完成；`business_entry` 表示即将进入业务执行器；
`first_state_access` 是应用第一次真实读取恢复状态。三者不能混为一个时间点。

## 4. 为什么需要 V3 统计

旧统计中部分字段是父项，部分是子项，直接相加会重复计时。kernel V3 为每次 restore
返回以下互斥 bucket：

- lock wait；
- lifecycle；
- manifest、image、checksum 和地址冲突验证；
- VMA 创建；
- upper-level page-table 分配；
- shared-leaf attach；
- PTE image validate / direct install / fallback other；
- dirty prefault；
- global restore；
- other。

checker 要求这些 bucket 的和严格等于 `kernel_total_ns`。fault、leaf materialization、
data CoW 和 CXL-to-local copy 是 restore 返回后的事件，单独报告，不加入 ioctl restore
堆叠图。

preopen 模式在 worker 创建时打开 `/dev/cxlfork`、查询 capability 并校验 policy；每次
请求只分配 session 并执行 resume。per-request 模式则把 open/caps/policy 都放在请求路径。
这两种模式被明确分开，避免把可缓存的 setup 成本冒充内核 restore。

## 5. 三种原始日志

每个 scenario 的 `raw/<scenario>/` 目录至少包含：

- `master.log`
  - `task_result_v3`：目标 VM 内部激活时间线、kernel V3、state binding 证据；
  - `hydra_task_v1`：master 请求发布、响应接收以及 Hydra message 中携带的服务端耗时；
  - `master_job_v1`：一次完整 WordCount job 的 master 同时钟总耗时。
- `agent0.log`、`agent1.log`
  - `hydra_response_v1`：目标 VM 响应 allocation/copy/checksum/publish 的本地耗时。
- CXLfork scenario 还有 `template-publish.log`、`template-release.log` 和
  `template-release-inspect-after.log`。

同一 task 通过 task ID 连接三类日志。原始日志不可覆盖；CSV 和 summary 可以随分析器
修正而重新生成。

## 6. 跨 VM 时钟规则

VM0 和 VM1 的绝对 `CLOCK_MONOTONIC` 值不能直接相减。精确主结果只使用：

1. VM0 同时钟的 request/response round trip；
2. VM1 同时钟的 agent receive 到 state/business/first-state-access；
3. 同一 ioctl 内的 kernel 排他 bucket。

同时保存 Hydra 四时间点：

```text
t1 = VM0 request_ready
t2 = VM1 server_recv
t3 = VM1 response_ready
t4 = VM0 response_recv
```

分析器计算 NTP 形式的 offset、双向剩余 delay、对称 one-way estimate 和 `±delay/2`
误差界。该估计用于辅助解释，不替代两端各自同一时钟的精确结果；不满足事件顺序或
出现负 delay 时输出空值，而不是伪造 0。

## 7. 自动验证规则

`analyze-motivation.py` 与 `check-motivation-results.py` fail closed。每条样本至少验证：

- target VM 内部事件因果顺序；
- task status 为 0；
- `template_binding_flags=15` 且 `template_access_count>=1`；
- CXLfork restore ID 非 0；
- kernel 排他 bucket 精确求和；
- MoW 有 shared leaf；
- MoA 有 fault、local page 和 CXL-to-local copy；
- Hybrid 至少选择 shared、fault-copy 或 dirty-prefault 路径之一；
- scenario 的 measured/warmup 数量与 manifest 一致；
- WordCount 的 `output.diff` 为空；
- release 后相同 key 不可 inspect；
- dmesg 无 BUG/Oops/panic/general-protection-fault/CXLfork error。

此外，已有 `scripts/test-state-binding.sh` 独立覆盖正常绑定、业务参数变化、损坏 state、
角色错配和 reader/release 回收。本轮通过结果位于：

`/home/xtl/cxlfork/mr-static-results/state-binding-acceptance/`

## 8. 如何手工运行

在 10.0.16.91 上：

```bash
cd /home/xtl/cxlfork/mr-distributed
git switch cohort-motivation-control-plane-measurement

RESULT=/home/xtl/cxlfork/mr-static-results/motivation-control-plane/manual-$(date -u +%Y%m%dT%H%M%SZ)

scripts/run-motivation-bench.sh \
  --output-dir="$RESULT" \
  --samples=1000 --warmups=5 --activation-blocks=10 \
  --workers=4 \
  --modes=persistent,localfork,local-prefork,cxlfork-preopen,cxlfork-per-request \
  --template-bytes-list=4194304
```

快速检查使用：

```bash
scripts/run-motivation-bench.sh \
  --output-dir=/tmp/motivation-smoke \
  --smoke --no-build
```

只重算 CSV 和检查结果：

```bash
python3 scripts/analyze-motivation.py "$RESULT"
python3 scripts/check-motivation-results.py "$RESULT"
```

正式 WordCount job 使用双向 barrier，命令为：

```bash
scripts/run-motivation-bench.sh \
  --output-dir="$RESULT" --skip-activation --workers=4 \
  --template-bytes-list=4194304 \
  --wordcount-input=/home/xtl/cxlfork/mr-file-sim-smoke/input/input_0.txt \
  --wordcount-expected=/home/xtl/cxlfork/mr-file-sim-smoke/expected.txt \
  --wordcount-modes=localfork,cxlfork-preopen \
  --wordcount-repeats=100
```

## 9. 输出文件怎么读

- `metadata.txt`：commit、样本数、mode、policy、clock contract；
- `run-manifest.csv`：每个 block/job 的期望样本；
- `tasks.csv`：逐 task 原始字段和同钟域派生字段；
- `summary.csv`：按 scenario group 聚合的 task 指标；
- `jobs.csv`：逐 WordCount job；
- `job-summary.csv`：以 job 为独立重复的汇总；
- `validation.json`：验证结论和所有错误；
- `system/`：build、capability、前后 dmesg；
- `raw/`：不可替代的原始日志和 correctness/lifecycle 证据。

统计规则：activation 有 1000 个有效样本时报告 P99；不足 500 个时 P99 留空。
100 个 WordCount job 只报告 mean/P50/P95/stddev，不把同一 job 的多个 reducer 当成
独立样本。`ci95_low/high` 使用 `mean ± 1.96 × sample_stdev / sqrt(n)` 的正态近似，
具体公式也写入 `validation.json`。

## 10. 当前正式数据与初步结论

### 10.1 4 MiB activation core

目录：

`/home/xtl/cxlfork/mr-static-results/motivation-control-plane/formal-core-v2-20260722T054743Z/`

每种模式 1000 个有效 probe。中位数如下：

| mode | target 到 business | target 到首次状态读取 | master RTT |
|---|---:|---:|---:|
| persistent | 7.89 us | 9.34 us | 27.93 us |
| local-prefork | 11.83 us | 22.35 us | 317.47 us |
| CXLfork preopen | 23.69 us | 31.15 us | 257.97 us |
| CXLfork per-request | 45.34 us | 51.98 us | 245.19 us |
| localfork | 237.17 us | 255.41 us | 461.07 us |

CXLfork preopen 中位 kernel restore 为 6.29 us，只占 target-to-business 的约 27.4%；
同一样本配对计算的 `target activation - kernel` 中位数仍有 17.17 us。说明共享页表和
数据页并没有消除 agent parse、porter 命令、worker wakeup、wrapper、postcheck 和
application bind。

请求完成后的 worker reap 与 refill 中位数分别约 55.5 us 和 133.8 us。它们不属于
“worker 开始执行前”的 activation，但会进入 master 观察到的完整响应 RTT，这正是
必须同时报告 activation 与 RTT、不能只看 ioctl 的原因。

per-request 的 open/caps/session setup 使 restore wrapper 从 10.64 us 增至 27.40 us，
target activation 从 23.69 us 增至 45.34 us。正式 fast path 应使用 preopen；
per-request 作为 setup 对照保留。

注意：该目录中的 activation 数据有效，但其中最早一版 100-job `job_total` 把 runner
通过 SSH 启动 agent 的时间算入了 job。目录根部的 `SUPERSEDED-WORDCOUNT.txt` 明确
禁止引用这部分 job summary；应用输出和逐 task correctness 证据仍保留。

### 10.2 footprint / leaf scaling

目录：

`/home/xtl/cxlfork/mr-static-results/motivation-control-plane/formal-scaling-20260722T060149Z/`

| footprint | pages | shared leaves | kernel restore P50 | leaf attach P50 | target activation P50 |
|---|---:|---:|---:|---:|---:|
| 4 MiB | 1,024 | 2 | 5.97 us | 0.22 us | 22.30 us |
| 64 MiB | 16,384 | 32 | 9.12 us | 1.89 us | 24.92 us |
| 256 MiB | 65,536 | 128 | 20.06 us | 7.12 us | 37.70 us |

fast path 不再逐 PTE 扫描整个 checkpoint，但并非绝对常数：upper-level allocation 和
shared-leaf attach 仍随 leaf 数增长。增长幅度远小于逐 4 KiB 页面 reconstruction。

### 10.3 debug validation 与 policy

- full validation：`formal-full-validation-20260722T060428Z/`
  - 4 MiB kernel restore P50 约 5.92 ms；这是逐页/镜像验证 debug path，不能与默认
    fast path 混用。
- MoA：`formal-moa-20260722T060542Z/`
  - 每个 probe 首次访问产生 1 次 fault、1 个 local-copy page；它没有 shared leaf，
    这是 policy 语义而不是实现失败。
- Hybrid：`formal-hybrid-20260722T060756Z/`
  - 当前 template 的 checkpointed hot/dirty 信息使 1,024 页走 dirty-prefault，kernel
    P50 约 0.60 ms；它不等于 MoW shared-leaf fast path。

### 10.4 authoritative WordCount

目录：

`/home/xtl/cxlfork/mr-static-results/motivation-control-plane/formal-wordcount-barrier-20260722T061502Z/`

该数据使用 `master initialized -> agents ready -> runner go` barrier，排除了 SSH/runner
启动污染。每种模式有 100 个独立 job，1000 条 task 记录全部通过 checker，200 个
`output.diff` 全部为空。结果如下（单位 ms）：

| mode | mean | P50 | P95 | stddev | mean 的 95% CI |
|---|---:|---:|---:|---:|---:|
| localfork | 41.64 | 41.31 | 45.35 | 1.79 | [41.29, 42.00] |
| CXLfork preopen | 39.00 | 38.69 | 42.12 | 1.49 | [38.70, 39.29] |

CXLfork preopen 的 job P50 比 localfork 低约 2.62 ms（约 6.3%）。这个结果只能说明在
当前静态 WordCount、4 workers 和文件模拟 backend 下，复用 CXLfork worker 激活路径
减少了完整 job 的一部分开销；不能把 2.62 ms 全部归因于单次 kernel restore。更细的
归因应使用 10.1 的逐 task target timeline 和 V3 排他 bucket。由于每组只有 100 个 job，
`job-summary.csv` 的 P99 按规则保持空白。

## 11. 环境限制

10.0.16.91 的 CXLfork 与 HydraRPC 分别使用不重叠的 QEMU host-backed 共享文件区域。
这些数据能证明软件控制路径、真实共享页表/data policy 和相对 breakdown，但不能代表
真实 CXL fabric 的绝对 latency、bandwidth、NUMA 或 cache 行为。迁移到 10.0.16.103
真实设备时必须使用新 backend 标签和新结果目录，不能覆盖本目录。

本轮同样没有实现任意进程 IP/SP 透明恢复、完整多线程、socket/epoll/namespace 或真实
Maple Tree leaf sharing。结论只适用于文档定义的单线程匿名模板和静态 MR worker 模型。
