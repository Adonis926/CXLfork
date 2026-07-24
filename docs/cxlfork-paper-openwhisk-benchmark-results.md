# CXLfork OpenWhisk 主路径性能结果

## 目的

这组实验固定使用同一个 CXLfork capsule，比较两条激活路径：

- `direct`：宿主直接发送 CXLP/2 请求，是当前控制路径下界；
- `openwhisk`：HTTP → OpenWhisk controller/invoker →
  `CxlporterContainer` → QEMU hostfwd → VM1 daemon → Docker ghost →
  capsule 子进程 → `RESUME_CAPSULE_V4`。

两条路径恢复相同的 key `2472401`、slot generation `2` 和 catalog
generation `3`。实验要回答的不是 CRIU、Mitosis 和 CXLfork 谁更快，
而是内核 restore 已经很快后，完整跨 OS 激活路径还剩多少软件开销。

## 方法

- 每个场景 20 次 warmup、1,000 个正式样本；
- 顺序场景一次只发一个请求；
- burst 以 open-loop 方式提供 150 RPS，最多 64 个客户端并发；
- OpenWhisk 入口上限 128，action 为 128 MiB、`logsize=0`；
- Docker ghost 使用 16 个固定 worker，并行创建独立 capsule 子进程；
- P99 只在 1,000 个成功样本上报告；
- 每个样本的 exclusive 分项必须严格等于 client total。

正式采集使用 cxlporter `7f929f7`，审计和摘要工具使用 `0aae499`。

## 结果

| 场景 | 成功/总数 | 实际吞吐 | mean | P50 | P95 | P99 | stddev | kernel restore mean |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| direct-sequential | 1000/1000 | 94.30 RPS | 10.472 ms | 10.579 ms | 11.587 ms | 11.746 ms | 0.863 ms | 15.652 us |
| openwhisk-sequential | 1000/1000 | 59.52 RPS | 16.648 ms | 16.201 ms | 20.558 ms | 22.779 ms | 3.186 ms | 16.750 us |
| direct-150rps | 1000/1000 | 149.77 RPS | 19.294 ms | 20.564 ms | 23.988 ms | 28.863 ms | 3.801 ms | 21.459 us |
| openwhisk-150rps | 1000/1000 | 149.64 RPS | 23.172 ms | 24.643 ms | 28.672 ms | 32.281 ms | 4.050 ms | 21.987 us |

顺序 OpenWhisk 比 direct 平均多 `6.176 ms`；150 RPS 下平均多
`3.878 ms`。这些差值描述当前实现的额外控制路径，不是硬件 CXL
fabric latency，也不是与其他 remote-fork 系统的比较。

## Exclusive mean breakdown

单位为微秒。下列分项按逐样本计算，每行之和等于 client total；原始
daemon/agent/fork interval 是嵌套关系，不能重复相加。

| 场景 | outer control | adapter other | daemon other | Unix connect | Unix transport | catalog | agent other | fork/runtime other | kernel restore | 总计 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| direct-sequential | 862.931 | 0 | 193.313 | 26.677 | 123.199 | 21.773 | 11.203 | 9217.163 | 15.652 | 10471.909 |
| openwhisk-sequential | 6088.951 | 921.504 | 203.174 | 27.869 | 129.184 | 23.049 | 12.072 | 9224.958 | 16.750 | 16647.512 |
| direct-150rps | 839.805 | 0 | 160.777 | 22.186 | 110.549 | 2592.628 | 14.041 | 15532.834 | 21.459 | 19294.278 |
| openwhisk-150rps | 4491.871 | 770.645 | 156.328 | 23.006 | 117.570 | 2520.797 | 12.563 | 15057.451 | 21.987 | 23172.220 |

顺序 direct 中 kernel restore 只占 `0.149%`，最大的分项是
`fork_runtime_other=9.217 ms`。顺序 OpenWhisk 中 outer control 和
adapter other 合计约 `7.010 ms`，kernel restore 只有约 `0.0168 ms`。
这正好支撑本项目的动机：共享数据和 worker 状态不意味着远端执行上下文
已经可以直接运行，进程创建、runtime 激活和跨 OS 控制仍然可见。

150 RPS 下，catalog lookup 增长到约 `2.5 ms`，fork/runtime 增长到约
`15 ms`，体现并发 catalog/ioctl 和进程创建争用；两条路径仍达到约
150 RPS。

## 真实性检查

4,000 个正式样本全部满足：

- `status=0`、`verify=1`、`exclusive_delta_ns=0`；
- shared PTE leaf PFN 和数据 PFN 证明存在；
- `/dev/cxlfork` fd 关闭后 context/reader 仍有效；
- 从保存的 continuation 继续到 invocation 17；
- `source_initializations=1`，没有重跑初始化；
- restore ID 全部不同，key/generation 始终一致。

测试结束后 slot `readers=0`，ghost 只剩 PID1 的 16 个 worker thread，
无遗留 capsule 或 zombie。VM0/VM1 dmesg 错误筛选为空；OpenWhisk
日志无 429、Docker log 误收集或 warm-container 失效。

## 数据位置

远端正式数据：

```text
/home/xtl/cxlfork/cxlfork-repro/results/paper-system/
  paper-source-full-v2-20260724/
```

其中：

- 四个 CSV 是逐样本字段；
- 四个 `*-raw.jsonl` 保存完整请求、响应和 runtime proof；
- `summary.csv/json` 是机器可读统计；
- `analysis.md` 是自动摘要；
- `result-analysis.md` 是详细解释；
- `openwhisk-run*.log`、`postflight-audit.txt` 和 `dmesg-*` 是审计证据；
- `SHA256SUMS` 校验除清单自身外的所有文件。

首轮失败数据位于相邻的 `paper-source-full-20260724/`，只用于证明默认
30 并发限流和 Docker log 误收集的故障过程，不用于最终性能图。

## 边界

当前是固定 4 MiB C capsule、QEMU/KVM 文件 backend 和真实 OpenWhisk
源码控制路径。它不代表真实 CXL hardware latency，也不声称实现任意
进程透明恢复、原论文十种函数/Azure trace/动态内存压力完整矩阵。
CRIU-CXL 和 Mitosis-CXL 当前未实现、未测试，本轮不补造相关对照。
