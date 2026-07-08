# CXLfork 主线复现记录

本文只记录当前阶段关注的主线：CXLfork 内核原型、CXLporter serverless harness、OpenWhisk baseline。CRIU-CXL、Mitosis-CXL 和原始 Mitosis 仅作为历史参考，不进入当前编译、启动或 benchmark 主流程。

## 1. 仓库与分支

主仓库：

- 目标机器：`xtl@10.0.16.91`
- 工作目录：`/home/xtl/cxlfork/cxlfork-repro`
- 当前主线分支建议：`cxlfork-only-mainline`
- 归档保护分支：`archive/full-mainline-before-cxlfork-only`
- 归档保护 tag：`archive-before-cxlfork-only`

当前主线只保留两个子仓库入口：

| 路径 | 用途 |
|---|---|
| `kernel/linux-6.6.32` | Linux 6.6.32 上的 CXLfork 内核原型，建议使用 `cxlfork-only` 分支 |
| `cxlporter` | CXLporter serverless benchmark 和 OpenWhisk baseline |

内核 patch 包：

- `kernel-patches/cxlfork-built-in/cxlfork-built-in-linux-6.6.32.patch`
- 该 patch 把 `drivers/cxlfork` 接入 Linux 6.6.32，并提供 `/dev/cxlfork`。

## 2. 当前复现目标

当前目标是复现论文中 CXLfork 主线的关键语义：

1. VM0 作为 checkpoint 节点，把函数进程私有状态写入 CXL 共享窗口。
2. VM1 作为 restore/invoke 节点，通过 `/dev/cxlfork` 从共享窗口恢复状态并执行 workload。
3. localfork VM 作为单机 `fork()` baseline，用于比较底层 fork/restore 开销。
4. CXLporter 作为轻量 serverless harness，包装 checkpoint-store、ghost process、invoke 和 policy 测试。
5. OpenWhisk standalone 作为完整 serverless 平台 baseline，用于观察传统平台控制面和容器 runtime 的端到端开销。

不在当前主线范围内：

- CRIU-CXL image backend。
- Mitosis-CXL / remote paging baseline。
- 原始 Mitosis runtime 或 forkctl 工具链。

这些内容如需恢复，可切回归档分支或历史提交。

## 3. CXLfork 内核复现状态

核心接口：

- 设备：`/dev/cxlfork`
- prepare ioctl：`CXLFORK_FORK_PREPARE`
- resume ioctl：`CXLFORK_FORK_RESUME`
- stats ioctl：`CXLFORK_STATS`
- release ioctl：`CXLFORK_RELEASE`

关键机制：

- VM0/VM1 通过 QEMU shared memory backend 共享 host 文件 `/dev/shm/cxl_mem`。
- guest 内核通过启动参数获得 CXL window：
  - `cxlfork.cxl_phys=0x484000000`
  - `cxlfork.cxl_size=0xfb000000`
- prepare 阶段复制 private pages，构建 PTE image、page table image、VMA tree image、state image 和 private rebase image。
- restore 阶段根据 policy attach 或 fault-in CXL-resident state，并记录 restore breakdown。

当前支持的 policy：

| policy | 语义 |
|---|---|
| `mow` | migrate-on-write，读路径优先共享 CXL replica |
| `moa` | migrate-on-access，访问时迁移到本地 |
| `hybrid` | 混合策略，当前需要继续核查 hot stride 是否真实生效 |

## 4. CXLporter 复现状态

CXLporter 是当前主线的 serverless 原型层，主要命令为：

- `cxlporter checkpoint`
- `cxlporter invoke`
- `cxlporter local`

测试拓扑：

| 节点 | 端口 | 角色 |
|---|---:|---|
| VM0 | 2200 | checkpoint 节点 |
| VM1 | 2201 | restore/invoke 节点 |
| localfork | 2202 | 单机 fork baseline |

关键观测字段：

- `prepare_ns`
- `restore_ns`
- `dispatch_ns`
- `workload_ns`
- `faults`
- `pages`
- image build / validate breakdown

注意：当前 CXLporter 的 pool 参数主要用于 ghost process 配置，现有 benchmark 路径并不等价于完整生产 serverless 并发调度器。

## 5. OpenWhisk Baseline

OpenWhisk 路径用于对比完整 serverless 平台的控制面和 Docker runtime 开销：

- `cxlporter/openwhisk/scripts/start-standalone.sh`
- `cxlporter/openwhisk/scripts/40-benchmark-openwhisk.sh`
- `cxlporter/openwhisk/scripts/41-benchmark-local-node.sh`

比较时需要注意：

- OpenWhisk 是完整平台 baseline。
- CXLporter 是轻量 CXLfork prototype harness。
- 两者 runtime、语言实现和调度路径不同，适合比较平台级延迟，不适合逐周期比较 workload 本身。

## 6. 与论文一致性和差异

对齐部分：

- 跨 OS restore 通过 CXL shared state 完成。
- private/global state 分离，并输出 metadata breakdown。
- 支持 CXLfork 论文中的 tiering policy 方向。
- serverless workload 可以通过 CXLporter 跑通端到端 checkpoint/invoke。

主要差异：

- 当前使用 QEMU shared memory backend 模拟 CXL memory window，没有真实 CXL fabric、设备延迟、带宽和 NUMA 拓扑。
- global state 恢复是研究原型子集，不覆盖完整 Linux 全局对象。
- OpenWhisk invoker 尚未直接接入 `/dev/cxlfork`。
- CXLporter harness 比真实 serverless 平台轻量，不能直接等价为生产级调度器。

## 7. 建议结果判定

最小闭环成功标准：

1. VM0/VM1 启动后均存在 `/dev/cxlfork`。
2. VM0/VM1 `/proc/cmdline` 均包含 `cxlfork.cxl_phys` 和 `cxlfork.cxl_size`。
3. unified touch benchmark 能生成 CSV，LocalFork 行列数与 header 对齐。
4. CXLporter benchmark 能生成 invoke CSV 和 checkpoint manifest。
5. OpenWhisk smoke benchmark 能生成 CSV。
6. CSV 中 prepare、restore、touch/workload、faults 等关键字段非空。
7. `mow` 和 `moa` 在 restore/touch/faults 上能观察到差异。

faults 的具体值先作为现象记录，不作为第一轮 pass/fail 的硬性标准。
