# CXLfork-spawn：103 真实 CXL 实验指南

## 1. 实验目的与边界

本实验把 91 上通过的受限 CXLfork V4 remote-spawn 搬到 103 的真实
`/dev/dax0.0`。它比较两条具有相同跨 VM 请求、目标 fork、child 退出和
`waitpid()` 路径的方案：

- `remote-target-local`：VM1 的 child 使用普通 fork 继承的 4 MiB 状态；
- `remote-cxlfork`：VM1 的 child 调用 `RESUME_CAPSULE_V4`，attach 共享 PTE
  leaf 并从保存的 stack/continuation 继续执行。

结果中的 `remote_spawn_lps` 是“每秒完成的远端 spawn 次数”。它与 UnixBench
Process Creation 的 lps 量纲相同，但 workload 不同，不能称为 UnixBench INDEX，
也不代表已经实现任意 Linux 进程的透明 remote fork。

## 2. 固定环境

- host：`xtl@10.0.16.103`（Lux）；
- QEMU：固定 9.0.90；
- guest：VM0/VM1 各 16 vCPU、16 GiB；
- host CPU：VM0 为 48–63，VM1 为 64–79，私有内存绑定 node1；
- CXLfork：`/dev/dax0.0` 的 `[4,8) GiB`；
- `[8,12) GiB` 仍由通用 launcher 映射为两个未使用的 Hydra ivshmem BAR；
- capsule：4 MiB、单线程、sealed MoW、prepare-once/restore-many。

runner 只把涉及 CPU 48–79 的 cpufreq policy 临时设为 `performance`。实验结束或
普通错误退出时，它恢复 governor、DAX mode/ACL 和实验前的 KVM unloaded 状态。

## 3. 安全约束

正式运行前必须和其他成员确认独占 KVM/DAX 时间窗。旧 HPCA/GVM launcher 不遵守
CXLfork 的锁，可能切换 KVM 并清空整个 64 GiB DAX；实验期间禁止运行它们。

本实验唯一入口仍是：

```text
scripts/run-cxlfork-spawn.sh
```

真实 DAX 模式强制满足：

- 由 root 启动且携带明确的独占确认 token；
- host 无任何 QEMU，KVM 初始为 unloaded；
- DAX geometry、QEMU/kernel/基础镜像 SHA256 全部匹配；
- `BACKEND_RESET=none`，不会删除或 truncate `/dev/dax0.0`；
- 只通过 range-zero helper 清零并回读验证 `[4,12) GiB`；
- VM 停止只使用本 worktree 的 pidfile，绝不全局 `pkill qemu`。

## 4. 代码与镜像准备

使用分支 `cxlfork-spawn-real-cxl-103`，kernel gitlink 必须指向
`f696e4e737698c4e1e5934a768232875dabb02a9`。在 103 使用隔离目录：

```text
/home/xtl/cxlfork/cxlfork-spawn-real-cxl-103
```

91 的两张停止状态 qcow2 作为不可变基础镜像保存在：

```text
/home/xtl/start/hpca-cxlfork/images/cxsp-vm0-base.qcow2
/home/xtl/start/hpca-cxlfork/images/cxsp-vm1-base.qcow2
```

每次运行前 runner 校验其 SHA256，并刷新隔离 worktree 的工作副本。正式 kernel 使用
91 的锁定 `.config` 在 103 独立 `O=` 目录构建；benchmark/selftest 由 runner 从同一
kernel commit 构建并校验 static ELF。

## 5. 验收和正式命令

先做短验收：

```bash
cd /home/xtl/cxlfork/cxlfork-spawn-real-cxl-103
sudo -E env \
  CXLFORK_EXCLUSIVE_CONFIRM=I_HAVE_EXCLUSIVE_KVM_DAX_103 \
  CXSP_BACKEND=real-dax-103 \
  CXSP_LANES='1 4 16' CXSP_PASSES=1 \
  CXSP_WARMUP_SECONDS=1 CXSP_MEASURE_SECONDS=2 \
  CHURN_REQUESTS=1000 LITMUS_ROUNDS=2 LITMUS_ITERATIONS=10000 \
  scripts/run-cxlfork-spawn.sh run
```

验收通过后运行正式矩阵：

```bash
sudo -E env \
  CXLFORK_EXCLUSIVE_CONFIRM=I_HAVE_EXCLUSIVE_KVM_DAX_103 \
  CXSP_BACKEND=real-dax-103 \
  CXSP_LANES='1 4 8 16' CXSP_PASSES=3 \
  CXSP_WARMUP_SECONDS=5 CXSP_MEASURE_SECONDS=30 \
  CHURN_REQUESTS=10000 LITMUS_ROUNDS=10 LITMUS_ITERATIONS=100000 \
  scripts/run-cxlfork-spawn.sh run
```

runner 会先运行跨 VM atomic RMW、release/acquire、coherence litmus，以及 ABI、
generation、V4 continuation、共享 leaf/data PFN 和 10,000 次 context 回收 gate。
任一 gate 失败时不会进入性能矩阵。

## 6. 数据解释

正式 breakdown 满足两个严格等式：

```text
target_total = request_dispatch + activation + exit_wait
activation = fork_to_child + child_setup + restore_wall + continuation
```

`kernel_restore_ns` 及 leaf attach 等字段是 `restore_wall_ns` 的嵌套子项，不能再次
与父项相加。VM0/VM1 不直接相减绝对时间戳；跨 VM 部分由 RTT residual 表示。

主要结果文件：

- `passes.csv`：每个 30 秒 pass 的 operations 和 `remote_spawn_lps`；
- `throughput-summary.csv`：三轮 lps 的 mean/stddev/min/max；
- `summary.csv`：逐请求 breakdown 的 mean/P50/P95/P99/stddev；
- `raw.csv`、`raw/`：全部逐请求证据；
- `gates/`：litmus、PFN 和 churn 证据；
- `manifest.txt`、`logs/`、`SHA256SUMS`：环境、版本、dmesg 和完整性记录。

远端结果位于：

```text
/home/xtl/start/hpca-cxlfork/results/cxlfork-spawn/<UTC>-103-real-dax/
```

完成后按 SHA256 备份到本地：

```text
/home/adonis/cxlfork/cxlfork-spawn-results/<UTC>-103-real-dax/
```

103 与 91 的差值不能全部解释为 CXL 介质差异，因为 host、QEMU、KVM 和 NUMA 环境
仍然不同；真正可靠的是每个环境内部两条同构路径的差值和 breakdown 占比。
