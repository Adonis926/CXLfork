# CXLfork 论文系统复现收口状态

本文记录 `cxlfork-paper-system-reproduction` 专用开发线的基线、阶段验收和已知边界。
本开发线服务于论文机制与控制路径实验，不覆盖、重写或强制更新既有 Cohort 实验分支。

## 冻结基线

冻结日期：2026-07-24

| 仓库 | 起始分支 | 起始提交 | 专用分支 |
|---|---|---|---|
| 主仓库 `cxlfork-repro` | `cohort-motivation-control-plane-measurement` | `fd80df11f0ac0122c5ea0d83b8c1abfb0be75c88` | `cxlfork-paper-system-reproduction` |
| kernel `linux-6.6.32` | `cohort-motivation-control-plane-measurement` | `a1d1f8fefb42404f28f9153b76b3adb8272cda26` | `cxlfork-paper-system-reproduction` |
| `cxlporter` | `cxlfork-cohort-openwhisk` | `c511a78f186d899c5af1d7b086cd83f0a65813fc` | `cxlfork-paper-system-reproduction` |

三个专用分支均已推送到各自的 `origin`。主仓库的 `.gitmodules` 只在本专用分支上改为跟踪同名子模块分支。

## 实施边界

- 首要门槛是受限但真实的单线程 C 函数胶囊跨 VM 续跑：目标端必须从已保存的 continuation 恢复，不能重新执行初始化函数伪装为 restore。
- `FULL_PRIVATE_STATE` 在任意进程透明恢复未实现前保持 unsupported。
- Docker ghost、CXLporter CXLP/2 和 OpenWhisk 集成只在 continuation 门槛通过后开展。
- OpenWhisk 固定到已有 standalone JAR 所对应的上游提交 `7ef091c12714b40d5dd93ff1488b086f0cebf3f8`，后续以可审计 patch/extension 集成。
- 原有 QEMU backend、qcow2 和 Cohort benchmark 保持不变；论文复现使用独立 profile、backend 和磁盘副本。

## 阶段验收

### S0：分支与基线冻结

状态：通过。

验收项：

- [x] 三个仓库从已验证提交创建同名专用分支。
- [x] 三个专用分支推送到远端。
- [x] 原始开发分支没有被直接修改。
- [x] 主仓库提交本冻结记录和子模块跟踪配置（`8dc820e`）。

### K0：函数胶囊 continuation 可行性

状态：通过。kernel 提交：`d37dde36d`。

硬验收：

1. VM0 在自定义函数栈中完成 invocation 1--16，并在协作式 quiescent point 保存 continuation。
2. checkpoint 覆盖匿名胶囊状态与函数栈。
3. VM1 使用同一二进制的本地 activation trampoline 恢复寄存器和栈。
4. VM1 从 yield 之后继续 invocation 17；不得重新运行 1--16 或重新初始化状态。
5. 输出 continuation cookie、业务状态 checksum、恢复前后栈地址和 CXLfork inspect/PFN 证据。
6. 同时覆盖错误 key、地址冲突或损坏 cookie 的失败路径，并检查 dmesg。

验收结果：

- VM0 完成 invocation 1--16，checkpoint 4 MiB、1,024 页的 PMD 对齐匿名 arena。
- VM1 的 PID 与源 PID 不同，但 `source_initializations=1`，并从同一保存栈继续 invocation 17。
- continuation 保存和恢复了 `RSP/RIP` 与 `R12--R15` 等 callee-saved 寄存器；固定寄存器标记全部匹配。
- trampoline 在首次修改 arena 前通过 `INSPECT_V2` 证明
  `current_pmd_pfn == shared_leaf_pfn`，且 `current_pfn == shared_pfn`。
- 已验证已有地址映射时返回 `EEXIST`，随后正常 restore 仍成功，说明失败回滚未破坏 slot。
- 已验证损坏 continuation cookie 后目标 trampoline 以状态 93 拒绝执行。
- 已验证不存在的 key 返回 `ENOENT`。
- VM0/VM1 的本轮 dmesg 中没有新增 CXLfork、BUG、WARNING 或 Oops。

说明：K0 有意使用 legacy `USER_THREAD_STATE` 指定本地 trampoline，因为 V2 尚不能原子提交
continuation manifest。它只用于证明该机制可行；正式接口将在 V4 中携带 generation、运行时身份、
cookie/checksum 和独占统计。

原始日志：

- 远端：`results/paper-system/20260724-k0/`
- 本地跳板机备份：`remote-backup-20260724/paper-system/k0/`

### S1：Capsule V4 ABI 与 restore fast path

状态：通过。kernel 提交：`5d78fd12b`。

实现内容：

- 新增严格 `size/version/reserved` 校验的
  `PREPARE_CAPSULE_V4`、`RESUME_CAPSULE_V4`、`INSPECT_CAPSULE_V4`
  和 `GET_CALL_STATS_V4`。
- checkpoint 在 READY 发布前原子封存 runtime SHA-256、image SHA-256、
  context VA、目标 trampoline/activation stack、continuation cookie 和业务状态 checksum。
- resume 必须匹配 `key+generation+runtime+image`；运行时身份不匹配返回 `ENOEXEC`。
- 新 capability 只声明 `COOPERATIVE_FUNCTION_CONTINUATION`；
  `FULL_PRIVATE_STATE` 和真实跨 OS Maple Tree attach 仍不声明。
- V4 的单次统计满足
  `total_ns = core.total_ns + capsule_validate_ns + activation_commit_ns`；
  页 fault/CoW 仍是独立的 restore 后归因，不能重复加到 total。
- 默认 sealed V4 不逐 PTE/checksum 扫描；`VALIDATE_FULL` 保留 correctness/debug 全量路径。
- 关闭发起 restore 的 `/dev/cxlfork` fd 后，恢复 VMA 继续持有 context、slot reader
  和 per-call stats；新 fd 的 `GET_CALL_STATS_V4` 已实测成功。

验收结果（QEMU/KVM 文件模拟 CXL，4 MiB/1,024 页）：

- 同一 checkpoint 的 `VALIDATE_FULL` restore：`9,474,122 ns`。
- 同一 checkpoint 的 sealed fast restore：`18,700 ns`。
- 本次样本只用于路径门槛和数量级诊断，不作为正式统计结论。
- fast/full 两条路径均证明 shared leaf/data PFN，并从 invocation 17 继续执行。
- V2 fast-path 回归：`fast_total_ns=22,785`、`full_total_ns=5,930,722`，`verify=ok`。
- VM0/VM1 共 34 项 ABI TAP 正向/反向断言通过。
- runtime mismatch=`ENOEXEC`、地址冲突=`EEXIST`、损坏 cookie=目标拒绝（exit 93）。
- kernel build `#86`、selftests build、双 VM 启动和 dmesg 检查通过。

原始日志：

- 远端：`results/paper-system/20260724-v4/`
- 本地跳板机备份：`remote-backup-20260724/paper-system/v4/`

### S2：跨 VM capsule catalog

状态：通过。kernel 提交：`2aa0cee8d`。

实现内容：

- 在 slot 之前的共享 CXL superblock 区建立 64-entry 有界 catalog。
- catalog identity 为 `(owner, function, version)`，记录 runtime/image digest、
  slot key/generation、image bytes、page/state checksum 和 restore policy。
- 新增严格 V4 `CATALOG_REGISTER/LOOKUP/EVICT` ioctl。
- 逐 entry 使用 `FREE -> WRITING -> READY` CAS 与 release/acquire 发布；
  查找会二次验证 state/catalog generation，避免读取半写 entry。
- lookup 还会验证底层 slot generation；slot 已释放或复用时返回 `ESTALE`。
- 这是有界科研 catalog，不宣称生产级分布式目录或故障恢复 allocator。

前置门槛：

- 在当前 #86/#87 QEMU/KVM shared backend 重新运行独立 litmus：
  10 轮、每轮 100,000 次跨 VM RMW/message/ping-pong，全部通过。

验收结果：

- VM0 register 后 VM1 lookup 得到相同 key、slot generation、digest 和 checksum。
- 两 VM 同时注册同一 identity，恰好一方成功，另一方返回 `EEXIST`。
- VM1 evict 后 VM0 lookup 返回 `ENOENT`。
- slot release 后保留的 catalog entry lookup 返回 `ESTALE`。
- 错误 catalog generation 的 evict 返回 `ESTALE`，且不破坏正确 entry。
- capsule V4 continuation、ABI TAP 与 dmesg 回归通过。

原始日志：

- 远端：`results/paper-system/20260724-catalog/`
- 本地跳板机备份：`remote-backup-20260724/paper-system/catalog/`

### S3：独立 paper VM profile 与论文规模容量

状态：通过。kernel 提交：`1cb6747e8`、`f1599b6b6`。

环境隔离：

- 原 `vm0.qcow2`、`vm1.qcow2` 只在停机状态下读取，没有原地修改。
- 新建 `paper-vm0.qcow2`、`paper-vm1.qcow2`，各自扩展为 40 GiB。
- paper VM 使用独立端口 2400/2401、独立 PID/monitor/console 文件和
  `/dev/shm/cxlfork_paper_mem` 16 GiB backend。
- 原 4 GiB profile 仍可运行；slot 数根据实际 CXL window 计算为 3，
  证明扩大编译上限不会让旧环境越界。

实现内容：

- 单 slot 从 512 MiB 扩展为 1 GiB，PTE 上限从 131,072 扩展为 262,144。
- 编译期最多 14 个 slot，但 `QUERY_CAPS_V2.max_slots` 和 key 映射均使用
  当前 `cxl_size` 推导的运行时 slot 数。
- selftest 新增 `caps` 子命令，直接输出运行时容量与 ABI 能力。
- paper guest 安装 Docker 29.1.3 和 OpenJDK 17；Docker 使用 `vfs`、
  禁用 bridge/iptables，以适配本实验内核的模块配置。

验收结果：

- 两台 paper VM 均运行 kernel build `#88`，映射 CXL window
  `17,095,983,104` bytes。
- 两台 `QUERY_CAPS_V2` 均报告
  `slot_bytes=1,073,741,824`、`max_slots=14`、`max_ptes=262,144`。
- 两台各 17 项 ABI TAP 断言全部通过。
- VM0 checkpoint/register、VM1 catalog lookup/restore 成功；目标从
  invocation 17 继续，并证明 shared PMD leaf PFN 和 data PFN。
- 630 MiB 匿名 footprint checkpoint 成功：
  161,280 页，image 672,325,632 bytes，页面与 leaf checksum 复核一致。
- Docker 在两台 guest 均报告 `driver=vfs cgroup=2`。
- dmesg 无新增 BUG、WARNING 或 Oops。

管理脚本：

- `scripts/paper-system/00-create-paper-images.sh`
- `scripts/paper-system/10-start-paper-vms.sh`
- `scripts/paper-system/11-stop-paper-vms.sh`
- `scripts/paper-system/20-provision-paper-guests.sh`

原始日志：

- 远端：`results/paper-system/20260724-paper-vm/acceptance.log`
- 本地跳板机备份：
  `remote-backup-20260724/paper-system/paper-vm/acceptance.log`

### S4：真实 Docker ghost 与 CXLP/2 激活路径

状态：通过。cxlporter 提交：`530bb91`。

实现内容：

- 保留旧 CXLP/1，新增独立 `cxlporter-paper` CXLP/2 daemon/client。
- VM1 中运行真实 Docker 容器 `cxlfork-ghost-paper`；容器使用离线
  `FROM scratch` 镜像和 `--network none`，常驻 agent 是容器 PID1。
- `/dev/cxlfork` 只通过 Docker `--device` 授权给 ghost 容器。
  VM1 外层 daemon 以 `ubuntu` 用户运行，实测没有 CXLfork device fd。
- daemon 经 bind-mounted Unix `SOCK_SEQPACKET` 把 ACTIVATE 交给 agent。
- agent 在容器内查询共享 catalog，随后 fork/exec 与 VM0 prepare 使用的
  同一个静态 non-PIE capsule runtime。
- 返回 daemon、Unix IPC、catalog lookup、fork-to-exit、kernel V4
  restore 和 agent total 等互不混淆的原始时间戳/区间，并保留 runtime
  原始证明的十六进制输出。

验收结果：

- host 经 QEMU port forwarding 成功执行 CXLP/2 PING 和 POOL_STATUS。
- 同一 VM0 checkpoint 经 CXLP/2 连续激活两个不同容器子进程，二者均：
  - 使用相同 key、slot generation 和 catalog generation；
  - 证明 shared leaf/data PFN；
  - 从 invocation 17 继续，`source_initializations=1`；
  - `child_status=0`、`verify=1`。
- 两次诊断样本的端到端 daemon 区间约 11.45 ms 和 9.66 ms；
  其中 kernel V4 restore 分别约 0.183 ms 和 0.020 ms。它们是功能门槛
  样本，不作为正式统计结论，但已经证明 restore 之外有可观测控制开销。
- 不存在的 catalog identity 返回 `ENOENT`，不会 fork child。
- 容器持续运行、device 映射为 `/dev/cxlfork:/dev/cxlfork`；
  外层 daemon 无 device fd，dmesg 无 BUG、WARNING 或 Oops。

说明文档：

- `cxlporter/docs/paper-cxlp2-ghost.md`

原始日志：

- 远端：`results/paper-system/20260724-cxlp2-ghost/smoke.log`
- 本地跳板机备份：
  `remote-backup-20260724/paper-system/cxlp2-ghost/smoke.log`

### S5：OpenWhisk 源码级 CXLP/2 集成

状态：通过。OpenWhisk 本地分支提交：`8fde5944`；可重放 patch 与脚本的
cxlporter 提交：`2c50456`。

实现内容：

- OpenWhisk 固定在上游提交
  `7ef091c12714b40d5dd93ff1488b086f0cebf3f8`，独立源码仓库分支为
  `cxlfork-paper-system-reproduction`。
- 在 invoker 中实现真实 `CxlporterContainer`。带 `cxlfork=true` 及
  owner/function/version annotation 的 executable action 不再运行其
  JavaScript 占位函数，而是直接发送 CXLP/2 ACTIVATE。
- OpenWhisk activation ID 映射为 CXLP/2 request ID；结果中保留
  OpenWhisk adapter、daemon、Unix IPC、agent、fork-to-exit 和 kernel
  restore 各层原始区间，以及完整 runtime proof。
- annotated action 明确跳过普通 runtime prewarm。初次验收曾证明仅在
  factory 中加分支不够：预热容器会在 factory 收到具体 action 前截获
  请求；最终在 `ContainerPool.takePrewarmContainer()` 对该 annotation
  返回 `None`，普通 action 不受影响。
- 配置默认 `enabled=false`，只有 Paper standalone 显式设置
  `CXLPORTER_ENABLED=true` 时启用。
- OpenWhisk 上游仓库不是本项目可推送仓库，因此把完整提交导出为
  `cxlporter/openwhisk/patches/0001-...patch`；构建脚本会验证固定 commit、
  patch 状态、JDK/Node 版本、focused 单测和产物哈希。

验收结果：

- 固定源码在 JDK 11、Gradle 6.9.1 下通过 invoker/standalone Scala
  编译、scalafmt 检查和 bootJar。
- 7 项 CXLP/2 focused ScalaTest 全部通过，覆盖 request ID、成功、
  远端错误、缺失字段、legacy 协议、超长响应和非法 proof hex。
- 从干净 standalone 状态连续执行两次 annotated action，二者均：
  - `openwhisk_source_integrated=true`、`status=0`、`verify=1`；
  - 经 hostfwd、VM1 daemon、Docker ghost、fork/exec 到内核
    `RESUME_CAPSULE_V4`；
  - 证明 shared leaf/data PFN、fd 关闭后的 context 生命周期和
    invocation 17 continuation。
- 本轮两次功能验收样本的 OpenWhisk adapter 区间约 13.13 ms 和
  8.32 ms；daemon 区间约 9.64 ms 和 7.21 ms；kernel restore 约
  23.0 us 和 9.7 us。它们只用于路径验收，不作为统计结论。
- 缺失 catalog identity 通过 OpenWhisk application error 返回
  `status=-2`、`verify=0`，没有 fork child。
- 未标注 action 返回真实 Node.js workload 结果；annotated action 日志
  中不存在普通 `DockerContainer` 的 `sending arguments` 记录。
- VM0/VM1 完整 dmesg 已保存，错误筛选文件为空。

管理脚本：

- `cxlporter/openwhisk/scripts/50-build-paper-source.sh`
- `cxlporter/openwhisk/scripts/51-start-paper-source.sh`
- `cxlporter/openwhisk/scripts/52-stop-paper-source.sh`
- `cxlporter/openwhisk/scripts/53-deploy-paper-source-action.sh`
- `cxlporter/openwhisk/scripts/54-smoke-paper-source.sh`

原始日志：

- 远端：`results/paper-system/20260724-064504-openwhisk-source/`
- 本地跳板机备份：
  `remote-backup-20260724/paper-system/openwhisk-source/`

### S6：OpenWhisk 主路径性能与测量收口

状态：通过。cxlporter 提交：`9d36fa7`、`7f929f7`、`7ad9534`、
`0aae499`。

实现内容：

- 新增 direct CXLP/2 与完整 OpenWhisk 源码路径的统一逐样本采集器，
  正式场景均使用 1,000 个样本并报告 mean/P50/P95/P99/标准差。
- 将嵌套 interval 转换为逐样本严格守恒的 exclusive breakdown；
  分项之和必须等于 client total，否则样本直接失败。
- OpenWhisk action 使用 `logsize=0`，避免普通 Docker log store 对
  逻辑 `CxlporterContainer` 执行不存在的 `docker logs` 并将其误判失效。
- OpenWhisk 入口并发上限设为 128，高于负载发生器的 64；action 使用
  128 MiB 实验记账。ghost 从串行 accept 改为 16-worker 固定池，
  每次 activation 仍创建独立 capsule 子进程。
- 结果收口增加本轮 OpenWhisk 日志、HTTP 429/容器生命周期错误筛选、
  slot reader、ghost 进程、dmesg 和不自包含的 SHA-256 清单检查。

正式结果（每行 1,000/1,000 成功）：

| 场景 | 实际吞吐 | mean | P50 | P95 | P99 | kernel restore mean |
|---|---:|---:|---:|---:|---:|---:|
| direct-sequential | 94.30 RPS | 10.472 ms | 10.579 ms | 11.587 ms | 11.746 ms | 15.652 us |
| openwhisk-sequential | 59.52 RPS | 16.648 ms | 16.201 ms | 20.558 ms | 22.779 ms | 16.750 us |
| direct-150rps | 149.77 RPS | 19.294 ms | 20.564 ms | 23.988 ms | 28.863 ms | 21.459 us |
| openwhisk-150rps | 149.64 RPS | 23.172 ms | 24.643 ms | 28.672 ms | 32.281 ms | 21.987 us |

关键结论：

- kernel restore 只占完整路径平均 `0.095%--0.149%`；共享页和页表状态
  已经可快速 attach，并不等价于目标执行上下文已经能够直接运行。
- 顺序 OpenWhisk 相对 direct 下界平均多 `6.176 ms`，150 RPS 下平均多
  `3.878 ms`。顺序 OpenWhisk 的 `outer_control` 和 adapter 外围平均约
  `7.010 ms`，而 kernel restore 约 `0.0168 ms`。
- 150 RPS 下 catalog lookup 和 fork/runtime 出现并发争用，但 direct
  与 OpenWhisk 都实际维持约 150 RPS，没有 HTTP 429。
- 4,000 个正式样本均证明 shared leaf/data PFN、fd-close 后 context
  生命周期和 invocation 17 continuation；`source_initializations=1`，
  且 4,000 个 restore ID 全部不同。结束后 slot `readers=0`，无遗留
  capsule/zombie，VM0/VM1 dmesg 错误筛选为空。

首轮 `paper-source-full-20260724` 中 OpenWhisk burst 有 839 个 HTTP
429，并暴露逻辑容器 Docker 日志误收集问题。该批次原样保留为故障证据，
不用于最终性能图；修复后正式批次为 `paper-source-full-v2-20260724`。

说明与边界：

- 详细结果见 `docs/cxlfork-paper-openwhisk-benchmark-results.md`。
- 本轮明确不补造 CRIU-CXL/Mitosis-CXL；它们保持未实现、未测试。
- 当前结果是固定 4 MiB C capsule、QEMU/KVM 文件 backend 和真实
  OpenWhisk 源码控制路径，不宣称覆盖原论文十种函数、Azure trace、
  动态内存压力或真实 CXL hardware 性能。

原始数据：

- 远端正式批次：
  `results/paper-system/paper-source-full-v2-20260724/`
- 远端失败证据：
  `results/paper-system/paper-source-full-20260724/`
- 本地跳板机备份：
  `remote-backup-20260724/paper-system/openwhisk-benchmark/`
