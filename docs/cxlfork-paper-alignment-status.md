# CXLfork 内核论文对齐状态

本文冻结 `cxlfork-kernel-paper-alignment` 分支的审计起点、支持范围和真实性口径。任何性能字段或能力位只有在对应机制通过硬证明后才能标为 supported；未实现的机制返回 unsupported/NA，不以零值代替。

## 冻结起点

| 仓库 | 审计起点 | 对齐分支 |
|---|---|---|
| cxlfork-repro | `42977d76006153e3b9d6571824e8be6db71febb3` | `cxlfork-kernel-paper-alignment` |
| kernel/linux-6.6.32 gitlink | `797e634da8353226c6c5b06a348d49f48cec1ca3` | `cxlfork-kernel-paper-alignment` |
| cxlporter gitlink | `4bafb0c9e150c470c7ab86588bbfa6bc1e5182bd` | `cxlfork-mainline`（不改动） |

主仓库分支从上述提交创建。原工作树 `/home/adonis/cxlfork/cxlfork-repro` 中已有的未提交文档、脚本和结果没有被修改；实现使用独立 worktree `/home/adonis/cxlfork/cxlfork-paper-alignment`。

远端开发机 `xtl@10.0.16.91:~/cxlfork/cxlfork-repro` 已核实两个私有子模块和精确 gitlink 可访问；本阶段在该环境中直接使用原 kernel commit，不以本地替代树作为证据。cxlporter 不参与本轮修改。

## 第一轮真实性矩阵

| 论文/接口概念 | 当前实现 | 结论 |
|---|---|---|
| PTE leaf attach | 驱动遍历 CXL 中的 PTE image，目标 `mm` 通过 `io_remap_pfn_range()` 重建本地 PTE | software image reconstruction，不是共享 leaf attach |
| Restore 复杂度 | 按 page/region 遍历和映射 | 随页数增长，不能宣称近常数 |
| VMA leaf attach | CXL 自定义树，restore 逐 region `vm_mmap()` | image-driven reconstruction，不是 Maple Tree attach |
| MoW | 只读 PFNMAP 映射的普通 CPU store 走 core-MM COW | 仅限 4 KiB 私有匿名支持子集；需 PFN/PTE 证明 |
| MoW fault 统计 | 写 fault 不进入 `cxlfork_fault()` | 旧 `faults=0` 不代表无 fault |
| FULL_PRIVATE_STATE | 保存 metadata，但目标 stub 继续执行 | unsupported；未恢复 IP/SP/TLS |
| private rebase | offset/phys/size manifest | 不是被 restore 消费的对象图 |
| checkpoint 一致性 | `mmap_read_lock` 不阻止其他线程写页 | 非一致快照 |
| slot 生命周期 | VM 本地 mutex；无 generation/refcount/acquire | 跨 VM 不可靠，允许静默覆盖 |
| 固定 slot 容量 | nominal 128 MiB，metadata 与静态表占空间 | 实际 payload 小于 128 MiB，且存在静默截断风险 |

## v2 第一版支持模型

- x86-64、4 KiB 页。
- checkpoint 调用者必须是单线程、协作式静止进程。
- 只支持私有匿名 VMA；THP/hugetlb、共享映射、PFNMAP/DAX、userfaultfd、长期 GUP/pin 和特殊 VMA 必须明确失败。
- restore 地址必须无冲突；strict 模式禁止破坏性的 `MAP_FIXED` 回退。
- `FULL_PRIVATE_STATE` 在真实执行上下文恢复完成前返回 `EOPNOTSUPP`。
- 不满足支持模型时不得静默跳过，也不得发布 READY slot。

## 分阶段门禁

每阶段独立提交，依次要求：kernel build、用户态/selftest 构建、VM smoke、成功/边界/失败测试和 dmesg 检查。任一必需门禁无法运行或失败，即停止后续机制阶段并记录原因；不得把软件模拟命名为论文机制。

当前 QEMU 环境可以验证共享 backend 页面、受限一致快照、跨 VM slot 协议以及 MoW/MoA 数据页 CoW。它不能提供真实 CXL fabric 延迟、带宽、NUMA/cache 行为或硬件性能结论。共享 PTE leaf、leaf CoW 和 Maple Tree attach 必须分别通过 CPU page walker/PFN 与实际查找路径的硬证明后才可报告为实现。
