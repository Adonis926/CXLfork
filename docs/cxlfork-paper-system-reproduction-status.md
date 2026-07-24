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

