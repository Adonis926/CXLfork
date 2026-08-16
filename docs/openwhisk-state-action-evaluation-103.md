# OpenWhisk + CXLfork 六系统评测说明

## 1. 这组实验要回答什么

这不是把任意 FunctionBench 函数透明 remote-fork 到另一台 Linux。实验只回答一个更窄、但能可靠验证的问题：当普通 OpenWhisk 通过 Docker 创建一个新的函数上下文，而 CXLfork 通过预先存在的 ghost、`fork()` 和 `RESUME_CAPSULE_V4` 激活一个共享状态 capsule 时，两条路径的冷激活时间花在了哪里，并且这种差异如何随总 CPU 数变化。

六个被测系统是：

- Cohort；
- no-memory-tiering；
- Starfish-like；
- native-CXL；
- native-DRAM；
- 双 VM、真实 DAX backend 的 CXLfork。

前五项共享同一份隔离后的 SSI guest 磁盘和同一个 OpenWhisk JAR。CXLfork 使用 VM0（OpenWhisk/请求端）和 VM1（ghost/restore 端）。任一时刻只运行一项系统。

## 2. 公平比较的 workload

普通 Docker action 和 CXLfork capsule 共用 `cxlporter/workload/state_action_core.c`：初始化 4 MiB 确定性状态，每个 4 KiB 页读取一个 64-bit word，并计算相同 checksum `05ae28486824d617`。

- 普通 OpenWhisk：`state-action-http` 实现标准 `/init` 和 `/run` 接口；cold action 带 `bench-force-cold=true`，每个样本结束后销毁容器。
- CXLfork：VM0 初始化状态一次并 checkpoint；VM1 的 capsule 从 V4 continuation 恢复后直接扫描共享状态。每个激活仍创建新的 child，但不在目标端重建 4 MiB 状态。

因此可以比较相同的状态大小、访问算法、checksum 和请求/响应语义。两者仍不是完全相同的 Linux 进程模型，结果必须称为“受限 state-action 冷激活比较”。

## 3. CPU 与实验矩阵

总 vCPU 为 `8/16/32/64/80`，每项五次 fresh-boot repetition。

- SSI：一个全局 OS 拥有 N 个 vCPU；OpenWhisk/JVM/load generator 固定在前 N/2 个 CPU，action 容器固定在后 N/2 个 CPU。
- CXLfork：VM0 和 VM1 各 N/2 个 vCPU；VM0 运行 OpenWhisk/load generator，VM1 运行 ghost/capsule。
- 总 private DRAM 固定为 16 GiB：分布式单一 OS 的两个物理 QEMU 各 8 GiB，native 单 VM 16 GiB，CXLfork 两个独立 VM 各 8 GiB。workload 只触碰 4 MiB，因此不需要旧 UnixBench profile 每个 QEMU 40 GiB、合计约 80 GiB host private HugeTLB 的配置。
- throughput 并发度为 N/2；每轮还运行 200 个 sequential cold 样本。
- 只有 32 vCPU 的普通 OpenWhisk 额外记录 warm sequential 下界。它不与 CXLfork remote activation 混称为同一种 cold。

每个配置的主要数据为：200 个 sequential cold 样本、30 秒 cold throughput，以及平台启动和 action deploy 的一次性时间。五轮合并后 cold sequential 恰好 1000 个样本，才报告 P99。

## 4. 不重复的 breakdown

每个样本的 client E2E 被拆成六个互斥部分，六项必须精确相加回 E2E：

1. `api_queue_schedule_ns`：请求进入 OpenWhisk 后，到开始创建/运行上下文前的等待；
2. `handoff_ns`：向 Docker action 或跨 VM CXLporter/ghost 交接的协议时间；
3. `worker_provision_ns`：Docker 容器创建，或 target fork/exec/reap 中扣除 restore 与 workload 后的部分；
4. `state_activation_ns`：普通 action 的 `/init`，或 CXLfork 内核 `RESUME_V4`；
5. `common_workload_ns`：完全相同的 4 MiB state scan；
6. `completion_response_ns`：其余返回、ack 和 client 侧时间。

`exclusive_delta_ns` 必须为 0，且所有分类非负，否则样本失败而不是带着错误 breakdown 进入汇总。

## 5. 正确性证据为何仍保留

性能样本只有同时满足下列条件才有效：

- 普通 cold 的 `container_id` 每次不同、`invocation=1`、`init_count=1`；
- worker 实际运行在目标 CPU 集；
- 状态为 4 MiB且 checksum 正确；
- CXLfork 的 `restore_id` 唯一，slot/catalog generation 有效；
- CXLfork 返回 source-integrated、shared-leaf、continuation register 和 marker proof；
- OpenWhisk activation 成功且六项 breakdown 守恒。

这些验证不会额外逐页扫描 checkpoint；它们使用真实请求已返回的 proof/统计字段。

## 6. 代码与唯一入口

- `scripts/run-openwhisk-state-action-eval.sh`：唯一 host 编排入口，同时包含 guest 子命令；
- `config/openwhisk-state-action-eval-103.env`：固定环境、版本、哈希与默认矩阵；
- `cxlporter/openwhisk/scripts/state_action_benchmark.py`：逐请求采集、验证和汇总；
- `cxlporter/workload/state_action_*`：普通 action 与 CXLfork capsule 共用 workload；
- `cxlporter/openwhisk/patches/0002-*.patch`：普通 Docker cold 生命周期纳秒埋点及强制 cold 语义。

编排器复用已有 HPCA/CXLfork start/stop 和安全 DAX 管理器，没有创建另一套 VM launcher。

## 7. 人工运行

以下命令均在 103 执行。必须先确认没有其他人使用 KVM、QEMU 或 DAX：

```bash
cd /home/xtl/cxlfork/openwhisk-state-action-eval
export OWE_EXCLUSIVE_CONFIRM=I_HAVE_EXCLUSIVE_KVM_DAX_103

# 只读检查
scripts/run-openwhisk-state-action-eval.sh preflight

# 首次一次：创建专用磁盘/overlay并安装固定资产
sudo -E scripts/run-openwhisk-state-action-eval.sh provision

# 8 核、每系统一轮的小样；通过后再运行正式矩阵
sudo -E OWE_REPS=1 OWE_SEQUENTIAL_REQUESTS=20 OWE_THROUGHPUT_SECONDS=5 \
  scripts/run-openwhisk-state-action-eval.sh run \
  /home/xtl/start/hpca-openwhisk-eval/results/pilot-8vcpu 8

# 正式矩阵
sudo -E scripts/run-openwhisk-state-action-eval.sh run \
  /home/xtl/start/hpca-openwhisk-eval/results/formal-$(date -u +%Y%m%dT%H%M%SZ) \
  8 16 32 64 80
```

创建 `CAMPAIGN/STOP` 会在当前 tuple 完整清理后暂停；再次执行完全相同的命令会验证 `.ok` 与原始 tar 的 SHA256，只补未完成 tuple。

## 8. 结果目录

每个 campaign 包含：

- `runs/<vcpus>/<system>/rep-N/attempt-N/`：启动、串口、guest 原始 CSV/JSONL、OpenWhisk、Docker、dmesg、prepare/release 证据；
- `accepted/`：只包含通过全部 gate 的 tuple，汇总器只读取这里；
- `state/ok/`：断点续跑的原子成功记录；
- `summary/summary.csv`：延迟、吞吐和样本量；
- `summary/breakdown.csv`：六个互斥阶段的平均值；
- `manifest/`：脚本快照、profile、环境和固定版本；
- `SHA256SUMS`：全部结果文件的最终校验清单。

正式结果完成后整体复制到本地 `/home/adonis/cxlfork/openwhisk-eval-results/<runid>/`，并在两端执行 `sha256sum -c SHA256SUMS`。
