# CXLfork 复现记录

本文记录当前仓库中 CXLfork、Mitosis-CXL、CRIU-CXL 和 OpenWhisk/CXLporter 的复现状态，重点保证复现内容可以和 git 记录、子仓库 commit、测试结果文件对应。

## 1. 仓库与 commit 对应关系

主仓库：

- 路径：`/home/xtl/cxlfork-ws`
- GitHub：`https://github.com/qmyyxtl/cxlfork-repro`
- 当前主线分支：`remote-fork`
- 当前本地工作分支：`publish-cxlporter`
- 当前已推送 commit：`d1189b0 Update CXLporter OpenWhisk benchmark`

子仓库：

| 路径 | GitHub/来源 | 当前分支 | 当前 commit | 用途 |
|---|---|---|---|---|
| `kernel/linux-6.6.32` | `https://github.com/qmyyxtl/cxlfork-linux-6.6.32.git` | `remote-fork` | `91a312cb2 Make Mitosis forkctl resume output unbuffered` | Linux 6.6.32 remote-fork / CXLfork 内核开发线 |
| `criu-cxl` | `https://github.com/qmyyxtl/cxlfork-criu-cxl.git` | `criu-dev` | `eac1d9add Disable CodeQL workflow for private fork` | CRIU CXL image backend 复现 |
| `mitosis-core` | `https://github.com/ProjectMitosisOS/mitosis-core.git` | `master` | 外部参考仓库 | 参考原始 Mitosis 设计与 API |
| `cxlporter` | `https://github.com/qmyyxtl/cxlfork-cxlporter.git` | `main` | `be8022c Add OpenWhisk standalone benchmark` | CXLporter/serverless benchmark harness |

主仓库重要提交顺序：

| commit | 内容 |
|---|---|
| `4d54507` | benchmark 输出 private rebase / global attach 成本 |
| `f70f52b` | 增加 full private-state prepare 模式 |
| `574800f` | 输出 page table image 成本 |
| `6e2a982` | 输出 direct PTE install 成本 |
| `5cceacd` | CXLfork 改成 built-in kernel driver |
| `0c7a96d` | benchmark 输出 private page 类型 |
| `ddeb866` | 更新 CXLfork PTE image 语义 |
| `d1871ed` | kernel patch 增加 CXL page table tree image |
| `ef82c6a` | 更新 built-in kernel patch |
| `b109f04` | 更新 CXLfork VMA tree benchmark 支持 |
| `2381860` | 增加 CXLporter benchmark submodule |
| `d1189b0` | 更新 CXLporter OpenWhisk benchmark |

内核 patch 包：

- `kernel-patches/cxlfork-built-in/cxlfork-built-in-linux-6.6.32.patch`
- 该 patch 把 `drivers/cxlfork` 接入 Linux 6.6.32 的 `drivers/Kconfig` 和 `drivers/Makefile`，以 built-in 或 module 方式提供 `/dev/cxlfork`。

## 2. 复现目标分解

本轮复现围绕三个系统：

1. CRIU-CXL：以 CRIU 的 checkpoint/restore 语义为基线，把 image 文件路径替换为 CXL 共享介质。
2. Mitosis-CXL / remote fork：复现 remote fork 的 prepare/resume、OS state、remote paging 语义，并把 RDMA transport 替换为 CXL 共享窗口。
3. CXLfork：按照论文描述复现 CXL-resident checkpoint、restore、tiering policy 和 serverless/CXLporter benchmark 路径。

当前更适合描述为“研究原型复现”，不是论文 artifact 的完整产品级复现。已实现部分可以跑通并产生可比较数据；OpenWhisk 与 CXLfork 目前仍是两条 benchmark 路径，尚未完全合并成论文中的 CXLporter invoker。

## 3. CRIU-CXL 复现状态

对应仓库：

- `criu-cxl`
- commit：`eac1d9add`

已完成：

- 基于上游 CRIU fork 增加 CXL image backend。
- 关闭私有仓库不适用的 CodeQL workflow。
- 跑通过 CRIU simple loop 风格测试，用于证明 checkpoint image 可以经 CXL 共享介质流转。

稳定结论：

- simple loop 级 checkpoint/restore 可作为 CRIU-CXL 基础验证。
- Docker/PID 场景已有兼容方向，但没有作为当前稳定 benchmark 结论。

与论文 CXLfork 的关系：

- CRIU 是论文中的 prior art 参照：它序列化进程状态到文件，然后远端反序列化。
- 当前 CRIU-CXL 复现的意义是证明“把文件 image transport 换成 CXL 共享介质”可行。
- 它不代表 CXLfork 的 zero-copy metadata attach 设计。

## 4. Mitosis-CXL / remote fork 复现状态

对应内核仓库：

- `kernel/linux-6.6.32`
- branch：`remote-fork`
- commit：`91a312cb2`

参考仓库：

- `mitosis-core`
- 来源：`https://github.com/ProjectMitosisOS/mitosis-core`

已完成：

- 在 Linux 6.6.32 上复现 remote fork 风格接口，而不是直接安装旧版 Mitosis。
- 增加 CXL remote paging transport，用 CXL 共享窗口替代 RDMA transport。
- 增加稳定 fork control tool。
- 支持 remote page fault benchmark。
- 支持并发 CXL remote page fetch。
- 增加 warm skeleton pool benchmark。
- 增加 lean serverless remote fork benchmark。
- 逐步补齐 OS state：
  - fd alias / fs state
  - rlimit
  - signal stack
  - security / thread OS state
  - forkctl resume 输出控制

语义说明：

- 原始 Mitosis 的核心是：checkpoint 阶段建立 parent 的 shadow immutable copy，并序列化 OS state；restore 阶段在远端创建 child；child 访问尚未复制的页时通过 remote paging 从 parent 端拉取。
- 当前 CXL 版本保留 remote paging 语义，但 transport 换成 CXL 共享窗口。
- 跨 VM 版本更接近原始 remote fork，因为 VM0/VM1 私有内存不能互相直接寻址，需要通过 CXL transport 做 page fetch。
- 单 VM / 同 host 模拟版本更接近 CXLfork 论文中对 Mitosis-CXL baseline 的限制，因为论文也指出当前 CXL 无法直接服务 inter-node fault，只能在同节点测试 Mitosis-CXL。

与原始 Mitosis 的差距：

- 不复现 RDMA 硬件和 RNIC queue pair 细节。
- 不复现原始 Mitosis 的完整 lean-container runtime。
- remote paging 的底层传输机制不是 one-sided RDMA，而是 CXL 共享内存。
- 当前目标是对齐论文语义与性能 breakdown，而不是逐行移植旧代码。

## 5. CXLfork 内核复现状态

对应 patch：

- `kernel-patches/cxlfork-built-in/cxlfork-built-in-linux-6.6.32.patch`

运行内核：

- VM0：`6.6.32-cxlfork+`
- VM1：`6.6.32-cxlfork+`
- local baseline VM：同一 `bzImage`，但不挂 CXL 参数

已完成机制：

- `/dev/cxlfork` 作为内核态 CXLfork 原型接口。
- VM0 checkpoint，VM1 restore/invoke。
- 共享 CXL 窗口由 QEMU NVDIMM 暴露，底层为 host `/dev/shm/cxl_mem`。
- CXLfork prepare 阶段把进程 private memory checkpoint 到 CXL。
- 记录 private state breakdown：
  - page 数
  - anon pages
  - clean file pages
  - dirty file pages
  - PTE image build
  - page table page image build
  - VMA tree image build
  - state image build
  - private rebase
  - global detach
- 支持 tiering policies：
  - `mow`：migrate-on-write，默认策略
  - `moa`：migrate-on-access
  - `hybrid`：混合策略
- 支持 benchmark 输出：
  - `prepare_ns`
  - `restore_ns`
  - `dispatch_to_done_ns`
  - `workload_ns`
  - `faults`
  - `pages`

与论文描述对齐的部分：

- process state 从发起 fork 的 OS instance 中解耦，并放入共享 CXL medium。
- 其他 VM 可以通过共享 CXL medium 访问 checkpointed state。
- 区分 private state 和 global state，并输出 private/global 相关成本。
- checkpointed page table / VMA metadata 以 image 形式进入 CXL，并在 benchmark 中拆分统计。
- 支持 CXLfork 论文中提到的三种 tiering policy。
- 默认 `mow` 下 read-heavy workload 不触发 migrate fault；写路径或 `moa` 会触发迁移。

仍未完全等价的部分：

- 论文中 page table leaf / VMA leaf 的“直接 attach CXL-resident object”语义，在当前实现中仍有一部分是 prototype image/metadata 路径。
- global state detach/attach 是可运行子集，不是完整覆盖 Linux 所有全局对象。
- OpenWhisk invoker 尚未直接调用 CXLfork 去恢复 action container。
- 当前 benchmark 不是论文 artifact 原始函数集合，而是复现 serverless 风格 workload。

## 6. CXLporter / OpenWhisk 复现状态

对应子仓库：

- `cxlporter`
- commit：`be8022c`

已完成两条路径：

1. CXLporter-style harness：
   - `cxlporter checkpoint`
   - `cxlporter invoke`
   - `cxlporter local`
   - 跨 VM 跑 VM0 checkpoint、VM1 invoke。
   - 支持 ghost pool、checkpoint manifest、tiering policy、keep-alive 参数。

2. OpenWhisk standalone benchmark：
   - 使用 `openwhisk/standalone:nightly`。
   - 使用 upstream `wsk` CLI。
   - action 经由真实 `wsk action update` 和 `wsk action invoke --blocking` 执行。
   - 默认 runtime 为 `nodejs:20`，因为 standalone 预热了 Node.js runtime 容器。
   - 保留 `python:3.10` action，等待 runtime 镜像可用后可切换。

当前 benchmark 分离状态：

- CXLfork benchmark：直接测 VM0/VM1 的 CXLfork checkpoint/invoke。
- OpenWhisk benchmark：测完整 OpenWhisk standalone 控制面和 Docker action runtime。
- 尚未完成：OpenWhisk invoker 直接调用 `/dev/cxlfork` 恢复 ghost container。

## 7. 最新 CXLfork serverless benchmark 结果

结果文件：

- `/home/xtl/cxlfork-ws/cxlporter/results/cxlporter-20260703-025157.csv`
- `/home/xtl/cxlfork-ws/cxlporter/results/checkpoint-store-20260703-025157.csv`

Checkpoint / prepare：

| workload | size | pages | prepare |
|---|---:|---:|---:|
| json | 4 MB | 1024 | 0.947 ms |
| pyaes | 4 MB | 1024 | 0.968 ms |
| html | 8 MB | 2048 | 1.887 ms |
| touch | 64 MB | 16384 | 15.519 ms |

默认 `mow` invoke：

| workload | size | pool | restore | dispatch-to-done | workload | faults |
|---|---:|---:|---:|---:|---:|---:|
| json | 4 MB | 1 | 19.0 us | 7.56 ms | 7.24 ms | 0 |
| pyaes | 4 MB | 1 | 18.5 us | 14.84 ms | 14.60 ms | 0 |
| html | 8 MB | 1 | 21.0 us | 10.35 ms | 10.11 ms | 0 |
| touch | 64 MB | 1 | 25.8 us | 0.80 ms | 0.49 ms | 0 |

`moa` 对比：

| workload | size | policy | dispatch-to-done | workload | faults |
|---|---:|---|---:|---:|---:|
| json | 4 MB | `moa` | 13.25 ms | 12.88 ms | 1024 |
| pyaes | 4 MB | `moa` | 16.71 ms | 16.42 ms | 1024 |
| html | 8 MB | `moa` | 14.55 ms | 14.26 ms | 2048 |
| touch | 64 MB | `moa` | 32.09 ms | 31.77 ms | 16384 |

LocalFork baseline：

| workload | size | LocalFork workload | CXLfork `mow` workload |
|---|---:|---:|---:|
| json | 4 MB | 8.13 ms | 7.24 ms |
| pyaes | 4 MB | 15.56 ms | 14.60 ms |
| html | 8 MB | 11.38 ms | 10.11 ms |
| touch | 64 MB | 10.44 ms | 0.49 ms |

解释：

- `restore_ns` 是几十微秒级，符合 CXLfork restore 低开销方向。
- `prepare_ns` 随 footprint 增长，64 MB 约 15.5 ms，体现 checkpoint copy 成本。
- 默认 `mow` 下 read-heavy workload 不触发 page migration fault。
- `moa` 下每页访问都会触发迁移，fault 数等于页数。

## 8. OpenWhisk benchmark 结果

结果文件：

- `/home/xtl/cxlfork-ws/cxlporter/openwhisk/results/openwhisk-20260703-023943.csv`
- `/home/xtl/cxlfork-ws/cxlporter/openwhisk/results/local-node-20260703-024045.csv`

OpenWhisk standalone：

| workload | size | avg invoke | OpenWhisk duration | workload |
|---|---:|---:|---:|---:|
| json | 4 MB | 561 ms | 510 ms | 12.3 ms |
| pyaes | 4 MB | 146 ms | 93 ms | 65.6 ms |
| html | 8 MB | 1130 ms | 1075 ms | 55.4 ms |
| touch | 64 MB | 362 ms | 312 ms | 0.35 ms |

Direct OpenWhisk runtime container baseline：

| workload | size | avg invoke |
|---|---:|---:|
| json | 4 MB | 982 ms |
| pyaes | 4 MB | 638 ms |
| html | 8 MB | 1607 ms |
| touch | 64 MB | 707 ms |

解释：

- Direct baseline 每次 `docker run` 新建 runtime container，因此比 OpenWhisk prewarm container 慢。
- OpenWhisk standalone 结果证明真实 OpenWhisk invoke 路径可以运行。
- 这还不是论文中 OpenWhisk invoker 与 CXLfork 完全集成的 CXLporter 端到端结果。

## 9. 当前结论

可以稳定汇报的结论：

1. 复现环境已能跑跨 VM CXLfork checkpoint/invoke。
2. CXLfork prepare/restore/execution/fault breakdown 已可统计。
3. 默认 `mow` 与 `moa` 的性能差异符合论文机制描述：`mow` 避免 read migration，`moa` 访问即迁移。
4. CXLporter-style harness 可以对比 LocalFork、CXLfork policies、pool size。
5. OpenWhisk standalone 可以跑真实 OpenWhisk action invoke benchmark。

需要谨慎表述的部分：

1. 当前不是论文 artifact 的完整 OpenWhisk+CXLporter autoscaler。
2. OpenWhisk benchmark 与 CXLfork benchmark 当前是分离路径。
3. page table / VMA leaf direct attach 与 Linux 全量 global state attach 仍是 prototype 子集。
4. 性能结果适合说明机制趋势，不适合作为与论文绝对数值的一一复现。
