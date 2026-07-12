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

## 阶段 1 门禁结果（2026-07-12）

- kernel `bzImage`（`CONFIG_CXLFORK=y`）通过；kernel commit 为 `223a44415`，阶段 1 修复后为 `d15d37301`。
- `tools/testing/selftests/cxlfork/cxlfork_test` 构建通过。
- 三台 VM 的 QUERY_CAPS/ABI 9 项全部通过，未宣称真实 shared PTE leaf、leaf CoW、generation、consistent snapshot 或 FULL_PRIVATE_STATE。
- 先前 4 KiB/4 MiB prepare 的 `ENOSPC` 根因已定位：测试时手工以 `MEM=8G` 启动 VM，但脚本固定 `cxlfork.cxl_phys=0x484000000`，该地址只匹配默认 16 GiB guest 内存布局。8 GiB guest 的 e820 RAM 只到 `0x27fffffff`，driver ioremap 到错误物理窗口，descriptor 写后读回为 0。阶段 1 验证必须使用脚本默认 16 GiB VM，或后续改成自动发现 NVDIMM resource。
- 修复 checkpoint image builder：构建阶段使用 prepare 已计算出的 expected slot 做容量和 offset 计算，并在每个 image 阶段校验 descriptor 的 `magic/version/slot/data_offset` invariant；descriptor 异常返回 `EILSEQ`，不再伪装成容量不足。
- 修复 MoA PFN 稳定性：`PRIVATE_COW/MoA` restore 使用 `MAP_SHARED` 建立 cxlfork VMA，使首次 fault 插入的本地页不会被后续普通写入再次 core-MM COW；MoW/Hybrid 保持 `MAP_PRIVATE`。
- 默认 16 GiB VM 验证通过：三台 VM ABI 9/9；VM0 4 MiB prepare/inspect checksum 一致；VM1 readonly、MoW、MoA restore 均 `verify=ok`，其中 MoW 写后 PFN 从共享 CXL PFN 切换到本地 PFN，MoA 首次访问本地 PFN 写后保持不变。
- 边界/失败验证通过：unknown inspect key 返回 `ENOENT`；124 MiB prepare 成功；125 MiB prepare 返回 `ENOSPC`；三台 VM dmesg 未见 `BUG:`, `WARNING:`, `Oops`, remap 错误或 descriptor invariant 诊断。
- 阶段 1 仍不声称 reliable slot generation、consistent checkpoint 或真实 shared PTE/VMA leaf；这些能力位保持 unset，进入阶段 2 前仍需实现受限一致 checkpoint。

## 阶段 2 门禁结果（2026-07-12）

- kernel `bzImage`（`CONFIG_CXLFORK=y`）通过；kernel commit 为 `26b10a209`。
- checkpoint 支持模型收紧为单线程、私有匿名、4 KiB 页。`FULL_PRIVATE_STATE` 返回 `EOPNOTSUPP`；多线程调用返回 `EBUSY`；shared anonymous 和 file-backed private VMA 返回 `EOPNOTSUPP`，失败后不发布 READY slot。
- checkpoint 页面复制顺序改为：读取源 PTE/PFN，短期 pin 页面并复制到 CXL，再复核 PTE 值、PTE PFN 和 pinned page PFN 均未变化。复核失败返回 `EBUSY`，不发布 READY slot。
- `QUERY_CAPS_V2` 现在报告 `CXLFORK_CAP_CONSISTENT_SINGLE_THREAD`，但仍不报告 reliable slot generation、FULL_PRIVATE_STATE、真实 shared PTE/VMA leaf、leaf CoW 或 A-bit hybrid。
- selftest 增加 `failures KEY`：验证 FULL_PRIVATE_STATE、多线程、shared anonymous、file-backed private 四类 unsupported 路径均明确失败且 inspect 返回 `ENOENT`。
- 默认 16 GiB VM 验证通过：三台 VM ABI 9/9；VM0 4 MiB prepare/inspect checksum 一致；VM0 failure tests `verify=ok`；VM1 readonly、MoW、MoA restore 均 `verify=ok`。
- 边界验证通过：124 MiB prepare 成功；125 MiB prepare 返回 `ENOSPC`；三台 VM dmesg 未见 `BUG:`, `WARNING:`, `Oops`, remap 错误或 descriptor invariant 诊断。
- 阶段 2 仍依赖调用者协作式静止；未实现跨 VM generation/refcount slot 协议，未证明长期 GUP/pin 拒绝的完整性，也未恢复真实执行上下文。

## 阶段 3 门禁结果（2026-07-12）

- kernel `bzImage`（`CONFIG_CXLFORK=y`）通过；kernel commit 为 `7ab337872`。
- slot descriptor 增加 `state/generation/reader_count`。prepare 使用 shared `state` 从 `FREE` 原子 claim 到 `WRITING`，发布时 `WRITING -> READY`；release 使用 `READY -> RELEASING -> FREE`。
- 同 slot 活跃对象不允许静默覆盖：同 slot 新 key prepare 返回 `EEXIST`，原 key generation 和 READY 对象保持不变。
- restore/fault/direct-map VMA 都携带 generation 并持有 reader 引用；release 在 `reader_count != 0` 时返回 `EBUSY`。VMA close 后 reader 引用释放，release 可成功。
- `QUERY_CAPS_V2` 现在报告 `CXLFORK_CAP_RELIABLE_SLOT_GENERATION`；`INSPECT_V2` 返回 generation、state、reader_count。
- selftest 增加 `lifecycle KEY` 和 `hold KEY SECONDS`：验证 same-slot collision、active release `EBUSY`、reader_count 归零后 release 成功，以及 release 后 inspect 返回 `ENOENT`。
- 默认 16 GiB VM 验证通过：三台 VM ABI 9/9；VM0 4 MiB prepare/inspect checksum 一致；VM0 failure tests `verify=ok`；VM0 lifecycle tests `verify=ok`；VM1 readonly、MoW、MoA restore 均 `verify=ok`。
- 跨 VM reader 验证通过：VM1 `hold` restore 映射时，VM0 `INSPECT` 看到 `readers=1`，VM0 `RELEASE` 返回 `EBUSY`；VM1 退出后 VM0 看到 `readers=0`，release 成功且 inspect 返回 `ENOENT`。
- 边界验证通过：124 MiB prepare 成功；125 MiB prepare 返回 `ENOSPC`；三台 VM dmesg 未见 `BUG:`, `WARNING:`, `Oops`, remap 错误或 descriptor invariant 诊断。
- 阶段 3 仍不是完整分布式锁服务：状态和 reader 使用 guest atomic/cmpxchg 操作在当前 QEMU shared backend 上验证通过，但还没有面向真实 CXL fabric 的持久化崩溃恢复、超时回收或多 writer 压测。

## 阶段 4 门禁结果（2026-07-12）

- kernel `bzImage`（`CONFIG_CXLFORK=y`）通过；kernel commit 为 `b3f9228a7`。
- restore 地址空间语义收紧：direct map、MoW 和 MoA 路径均只使用 `MAP_FIXED_NOREPLACE`；目标地址已有映射时返回 `EEXIST`，不再回退到破坏性的 `MAP_FIXED` 覆盖。
- 预期地址冲突属于正常失败路径；direct/COW restore 的 `-EEXIST` 不再写 `pr_warn`，避免 dmesg 噪声掩盖真实异常。
- selftest 增强 `restore KEY POLICY`：MoW 写后必须从共享 CXL PFN 切换到本地 PFN；MoA 首次访问即为本地 PFN 且写后保持；重复写不得再次切换 PFN；写入后 `INSPECT` 的 shared checkpoint checksum 必须保持不变。
- selftest 增加 `conflict KEY POLICY`：在目标 restore 地址预先建立 guard mapping，验证 readonly、MoW、MoA 三种策略均返回 `EEXIST`，且 guard 内容未被替换。
- strict restore 暴露并修正了旧 lifecycle 测试假设：fork 出来的 child 会继承 parent prepare 使用的 `TEST_BASE` 映射；测试现在在 child hold restore 前先 `munmap()` 该继承映射，符合无冲突 restore 模型。
- 默认 16 GiB VM 验证通过：三台 VM ABI 9/9；VM0 4 MiB prepare/inspect checksum 一致；VM1 readonly、MoW、MoA restore 均 `verify=ok`；三种 conflict 测试均 `verify=ok`；VM0 failure tests 和 lifecycle tests 均 `verify=ok`。
- PFN 证据：MoW restore 初始 `current_pfn == shared_pfn`，首次写后切换到本地 PFN，第二次写保持同一 PFN；MoA 初始 `current_pfn != shared_pfn`，首次和第二次写均保持同一 PFN。
- 边界验证通过：124 MiB prepare 成功；125 MiB prepare 返回 `ENOSPC`；三台 VM dmesg 严格检查未见 `BUG`, `WARNING`, `Oops`, `Call Trace`, `cxlfork: vm_mmap`, `cxlfork: cow vm_mmap` 或 `remap` 诊断。
- 阶段 4 仍未实现 GUP/write、mprotect/fork 等所有 PTE mutation 入口的显式拒绝或 leaf materialization；MoW 仍依赖 Linux core-MM 对只读 PFNMAP 的 COW 行为，不等同于论文 Figure 5 的共享 PTE leaf CoW。

## 阶段 5a 门禁结果（2026-07-13）

- kernel `bzImage`（`CONFIG_CXLFORK=y`）通过；kernel commit 为 `fbc9e54b3`。
- `CONFIG_CXLFORK` 从 `tristate` 收紧为 `bool`，因为 core-MM 已调用 cxlfork shared-leaf helper，不能依赖可卸载模块 symbol。
- 新增 `include/linux/cxlfork_mm.h` 作为 core-MM 与 cxlfork 的最小接口。
- `mm/memory.c` 的 zap/free 路径识别 cxlfork shared CXL PTE leaf PMD：清 PMD、flush 对应 PMD 范围、更新页表 accounting，且不对 CXL PFN 调用 `pmd_page()`、`pmd_page_vaddr()` 或 `pte_free_tlb()`。
- readonly restore 对 PMD 对齐且整 PMD 覆盖的 region 安装真实 CXL PTE leaf；非对齐 region 回退到阶段 4 的 direct PTE reconstruction。
- `QUERY_CAPS_V2` 现在报告 `CXLFORK_CAP_REAL_SHARED_PTE_LEAF`；`CXLFORK_CAP_PTE_LEAF_COW` 仍保持 unset。
- `INSPECT_V2` 增加 `shared_leaf_pfn/current_pmd/current_pmd_pfn`，用于证明目标 mm 的 PMD 是否指向 CXL leaf。
- VM1 readonly restore 证据：`shared_pfn=4768768 before_pfn=4768768 shared_leaf_pfn=4769803 current_pmd_pfn=4769803 verify=ok`。其中 `current_pmd_pfn == shared_leaf_pfn` 证明 CPU page walker 使用目标 mm 中指向 CXL leaf 的 PMD；`before_pfn == shared_pfn` 证明 leaf 内 PTE 映射的是 CXL 数据页。
- 默认 16 GiB VM 验证通过：三台 VM ABI 9/9；VM1 readonly、MoW、MoA restore 通过；三种 conflict 测试通过；failure tests 和 lifecycle tests 通过；124 MiB prepare 成功；125 MiB prepare 返回 `ENOSPC`。
- 三台 VM dmesg 严格检查 clean，未见 `BUG`, `WARNING`, `Oops`, `Call Trace`, cxlfork mmap/remap 诊断、bad pagetable、general protection fault、page fault 或 `non-zero pgtables`。
- 阶段 5a 仍不是 leaf CoW：MoW/MoA 尚未使用 shared leaf，mprotect/fork/GUP/mremap/partial munmap 等 PTE mutation 入口尚未 materialize-on-write；`CXLFORK_CAP_PTE_LEAF_COW` 不可宣称。
