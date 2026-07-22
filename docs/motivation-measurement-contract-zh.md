# Cohort Motivation 测量契约

本文件冻结 HydraRPC + CXLfork + MapReduce 的论文 Motivation 测量边界。
正式数据必须来自 `cohort-motivation-control-plane-measurement` 分支，不能与
早于 worker-state binding 的 `stage6-30-final` 混用。

## 主要时间边界

- `worker_entry`：worker 观察到本地 slot 后进入任务处理。
- `state_ready`：CXLfork resume、返回值校验和 worker-state bind 全部成功。
- `business_entry`：即将进入 Map/Reduce task executor。
- `first_callback_entry`：进入 Mapper 或第一次进入 Reducer 回调。
- `target_activation`：目标 VM 同一单调时钟上的
  `agent_request_received -> business_entry`。

Reducer 的 shuffle、spill、解析和排序发生在 `business_entry` 之后、第一次
Reducer 回调之前，属于应用数据准备，不属于控制面。

## 计时层级

正式堆叠图只使用同一时钟域、相邻事件形成的排他区间。以下字段是父子或并行关系：

- `kernel_restore_core` 嵌套于 `resume_ioctl_wall`；
- `resume_ioctl_wall` 嵌套于 restore wrapper；
- supervisor dispatch 在 prefork/CXLfork 中可与 worker 执行并行；
- localfork 的 `fork` 嵌套于 slot publish 到 worker entry；
- fault、CXL-to-local copy 和 CoW 属于 restore 返回后的访问路径；
- reap/refill 属于当前任务完成后的生命周期尾部。

任何分析脚本都不得把这些父子或并行字段直接相加。

## 跨 VM 时钟

VM0 与 VM1 的绝对 `CLOCK_MONOTONIC` 时间戳不得直接相减。论文主结果同时报告：

1. master 同时钟 request/response RTT；
2. VM1 同时钟 target activation；
3. 经四时间点校准并携带误差区间的跨 VM 单向估计。

单向估计不稳定时输出 `NA`，不能阻塞前两项精确结果。

## 正确性证据

每个 CXLfork 样本至少保存 generation、restore ID、path mask、supported/valid
mask、共享/fallback 页计数、template/state checksum、state access count 和 binding
flags。正式 WordCount 数据要求逐轮输出校验、reader 回零、release 成功且两台 VM
dmesg 无 CXLfork/BUG/WARNING 异常。

## 统计规则

- raw 数据不可覆盖；异常值保留并显式标记 invalid；
- 1000 个 activation 样本才报告 P99；
- 100 个 WordCount job 只报告 mean/P50/P95/stddev 和 95% CI；
- 同一 job 的多个 reducer 是 cluster，不能当成独立重复；
- 模式以固定随机种子的 balanced blocks 交错运行；
- 所有 summary 和图必须能由 raw 文件重新生成。

## 环境边界

10.0.16.91 使用 QEMU 文件后端模拟共享内存，只用于功能、软件控制路径和相对
breakdown；不得据此声称真实 CXL fabric 的绝对延迟或带宽。未来 10.0.16.103
真实 CXL 结果必须使用不同 backend 标签和结果目录。
