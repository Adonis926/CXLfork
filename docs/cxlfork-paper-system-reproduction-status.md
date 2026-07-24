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
