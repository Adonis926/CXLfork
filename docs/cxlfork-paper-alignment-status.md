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

## 阶段 6 门禁结果（2026-07-13）

- kernel `bzImage`（`CONFIG_CXLFORK=y`）通过；kernel commit 为 `469548dc7`。
- MoW restore 对 PMD 对齐、整 PMD 覆盖的 region 现在使用真实 shared CXL PTE leaf attach；MoA 仍走旧的首次访问复制路径。
- CXL leaf 中的 PTE 现在显式设置 `pte_special`，保持 PFNMAP/mixed-PFN 语义，避免 materialize 后 core-MM 把 CXL PFN 当普通 `struct page` 映射检查。
- `handle_pte_fault()` 在写/unshare fault 对 shared leaf 调用 `cxlfork_materialize_shared_leaf_pmd()`，先复制整页 CXL PTE leaf 到本地普通页表页并切换 PMD，再让 Linux 原有 `do_wp_page()` 完成数据页 COW。
- `QUERY_CAPS_V2` 现在报告 `CXLFORK_CAP_PTE_LEAF_COW`。
- VM1 MoW 证据：写前 `shared_leaf_pfn=4769803 current_pmd_pfn=4769803`；首次写后 `after_pmd_pfn=1124167`；第二次写后 `second_pmd_pfn=1124167`。这证明写前共享 leaf，写后仅 writer 切换到本地 leaf，重复写不重复复制 leaf。
- 数据页 CoW 证据：MoW 写前 `before_pfn=shared_pfn=4768768`；写后 `after_pfn=1117807`；第二次写 `second_pfn=1117807`。shared checkpoint checksum 写后保持不变。
- 默认 16 GiB VM 验证通过：三台 VM ABI 9/9；VM1 readonly、MoW、MoA restore 通过；三种 conflict 测试通过；failure tests 和 lifecycle tests 通过；124 MiB prepare 成功；125 MiB prepare 返回 `ENOSPC`。
- 三台 VM dmesg 严格检查 clean，未见 `BUG`, `WARNING`, `Oops`, `Call Trace`, cxlfork mmap/remap 诊断、bad page map、bad pagetable、general protection fault、page fault 或 `non-zero pgtables`。
- 阶段 6 仍限于受限单线程匿名模型和 MoW 写 fault 路径；mprotect/fork/GUP/mremap/partial munmap/khugepaged 等 PTE mutation 入口尚未全部 materialize-on-write。

## 阶段 7 可行性门槛结论（2026-07-13）

- 阶段 7 目标是让 `find_vma()` / `mas_find()` 真实遍历 CXL 上的 Maple Tree/VMA leaf。
- Linux 6.6 Maple Tree 的 `ma_root` 和节点 slot/parent 保存本机 kernel 虚拟指针，并使用低位编码；`mte_to_node()` / `mas_mn()` 会直接把 entry 解码为本机 `struct maple_node *` 后解引用。
- `struct maple_node` 是来自 `maple_node_cache` 的 256-byte slab 对象，销毁和 rebalance 路径通过 RCU/slab 管理：`ma_free_rcu()`、`mt_free_rcu()`、`mas_destroy()`、`__mt_destroy()`、`mtree_destroy()`。
- 因此不能把 CXL offset、CXL physical address 或当前自定义 VMA image 直接写入 `mm->mm_mt.ma_root`。这样会让 Maple Tree 把 CXL 内容当成本机 slab 节点解引用，并可能在释放时交给 `maple_node_cache`。
- 安全实现需要 Maple Tree 级别扩展：新增可识别的 CXL node 类型或 accessor、所有 lookup 路径的 CXL offset 转换、所有 mutation 路径的 materialize、RCU/free 特判，以及 VMA entry 指针/对象图策略。
- 阶段 7 在可行性门槛处阻塞；当前 VMA 机制仍只能称为 image-driven reconstruction，不能宣称真实 Maple Tree attach 或 VMA constant-time restore。

## 阶段 12 更新（2026-07-13）

- kernel 已推进到 `8e08aa198`。
- 阶段 12 不再停留在 bounded large-slot gate：descriptor 内嵌大数组已移出，fd/region/PTE 表在 CXL slot 内通过 offset/entries/bytes manifest 描述。
- checkpoint preflight 现在产生 sizing manifest；region/PTE 表按实际 region/page 数分配，不再为每个 checkpoint 固定预留最大 PTE 表。
- `INSPECT_V2` 现在暴露 table offsets、entries、bytes、page-data offset/bytes，以及 extent bitmap 的 extent size/count/allocated extents。
- 每个固定 512 MiB slot 增加 4 KiB extent bitmap，覆盖 descriptor、动态表、page data、PTE/VMA/state/rebase images；重复或越界分配返回错误。
- prepare 只有在全部对象构建、checksum、用户态回填成功后才发布 READY；失败路径清空 descriptor 和 extent bitmap。
- 4 MiB、192 MiB、512 MiB ENOSPC、failure、lifecycle、conflict、ABI、fdglobal、hybrid 和 threadctx 回归均通过，dmesg fatal 检查 clean。
- 仍保留的真实性边界：key placement 仍是 `key % max_slots`，每个 key 仍占用固定 512 MiB slot；当前完成的是 per-slot extent bitmap 与动态 object manifest，不是全局可变大小 extent allocator。fd/region 的 legacy ioctl 输出容量仍受 UAPI 数组上限约束，更多条目需要新的 v2 prepare/restore 用户态缓冲 API。

## 阶段 13 最终状态冻结（2026-07-13）

- kernel 最终提交为 `a21d196dd`，主仓库最终提交将记录该 gitlink。
- 最终 correctness suite 通过，日志位于远端 `/tmp/cxlfork_phase13_correctness.log`，结尾为 `PHASE13_CORRECTNESS_OK`。
- 最终性能/分解矩阵通过，CSV 位于远端 `/tmp/cxlfork_phase13_perf.csv`；CSV 为 45 列、24 行数据，覆盖 4 MiB/64 MiB/192 MiB、read/write、MoW/MoA/Hybrid，并包含 LocalFork baseline。
- 最终 dmesg 检查 clean：VM0/VM1/localfork 在 correctness 和 performance 之后均未见 kernel BUG/Oops/Call Trace、cxlfork mmap/remap 诊断、bad page map/bad pagetable/general protection、buffer overflow 或 `non-zero pgtables`。

### 最终真实性矩阵

| 机制/论文点 | 最终状态 | 说明 |
|---|---|---|
| 受限一致 checkpoint | 部分实现/已验证 | 单线程、协作式静止、私有匿名 4 KiB VMA；PTE/PFN 复制后复核；unsupported 路径明确失败。 |
| 跨 VM slot 生命周期 | 已实现/已验证 | 固定 slot、generation、reader_count、READY/RELEASING 状态机；active release 返回 `EBUSY`。 |
| Restore 地址无冲突语义 | 已实现/已验证 | 使用 `MAP_FIXED_NOREPLACE`，冲突返回 `EEXIST`，guard mapping 不被破坏。 |
| MoW/MoA 数据页语义 | 已实现/已验证 | MoW 写后切本地 PFN，checkpoint/sibling checksum 不变；MoA 首次访问复制本地页。 |
| 真实 shared PTE leaf attach | 原型实现/已验证 | 对 PMD 对齐整段 readonly/MoW region，目标 PMD 指向 CXL PTE leaf，CPU page walker 使用该 leaf。 |
| shared PTE leaf CoW | 原型实现/已验证 | MoW 写 fault materialize leaf 到本地页表页，再由 core-MM 完成数据页 COW；并非所有 PTE mutation 入口都覆盖。 |
| VMA image | 已实现/已验证 | CXL 中有 VMA image/tree，并可验证 lookup evidence。 |
| 真实 Maple Tree/VMA leaf attach | 未实现/门槛阻塞 | Linux Maple Tree 节点保存本机 kernel 指针/RCU/slab 生命周期，不能安全直接指向 CXL offset/phys。 |
| Thread context resume | 受控原型/已验证 | 专用 trampoline 测试能从保存 IP/SP 继续；不是 arbitrary process continuation。 |
| FULL_PRIVATE_STATE | 未实现 | 仍不宣称完整 task/mm/object graph 恢复。 |
| fd/global state | 子集实现/已验证 | 普通文件 fd、cwd/root/umask/signal mask 等在同 filesystem identity 环境下验证；特殊 fd/namespace 不支持。 |
| A/D-bit hybrid | 已实现/已验证 | 基于 checkpointed PTE A/D bits；dirty pages restore-time prefault；性能收益不代表真实硬件。 |
| Restore breakdown | 已实现/已验证 | per-call breakdown，不再复用共享累计字段；unsupported/not-taken 路径输出 0/NA 语义清楚。 |
| 容量/动态布局 | 部分实现/已验证 | 512 MiB fixed slots、preflight sizing、out-of-line tables、per-slot extent bitmap；不是全局可变 extent allocator。 |
| 真实 CXL 硬件性能 | 未验证/环境不支持 | 当前 QEMU shared backend 只能用于功能和趋势，不用于硬件绝对性能结论。 |

### 最终可声明范围

可以声明：在当前 QEMU shared-backend 环境中，CXLfork 已在受限单线程私有匿名模型上实现并验证一致 checkpoint、可靠固定 slot 生命周期、MoW/MoA 数据页语义、真实 shared PTE leaf attach 原型、MoW leaf materialization、A/D-bit hybrid 原型、fd/global 子集、thread-context trampoline、per-call breakdown 和 per-slot 动态布局 manifest。

不能声明：完整复现论文 Figure 5 的 VMA/Maple Tree leaf attach、完整 arbitrary-process private-state graph、完整 namespace/global state、全局可变 CXL extent allocator、所有 Linux PTE mutation 入口的 leaf CoW 覆盖，或真实 CXL 硬件性能。

## 最终收口阶段 0：跨 VM 内存序硬门禁（2026-07-13）

- kernel 提交为 `ea3f5ef6f`。
- 在生产 slot 协议之外的预留 CXL 页上，使用相同的 `ioremap_cache()`
  映射验证跨 VM CAS/RMW、release/acquire payload publication 和双向
  cache-coherent ping-pong。
- VM0/VM1 共运行 10 轮，每项每轮 100,000 次迭代；lost update、payload
  mismatch、ordering error 和 timeout 均为 0。日志位于远端
  `/tmp/cxlfork_stage0_litmus.log`。
- 该结果使当前 QEMU/KVM shared-file backend 满足后续 lifecycle CAS
  原型的功能前提；结论不自动外推到尚未测试的真实 CXL 设备。
- UAPI 现以 `include/uapi/linux/cxlfork.h` 为唯一来源；删除已漂移的
  sample 副本，selftest 与 benchmark 均使用 `headers_install` 结果。

## 最终收口阶段 1：packed lifecycle 与 V2 context（2026-07-13）

- kernel 提交为 `68e2f0c6e`、`8f1ad4220`、`fe9523d5d`。
- state 与 reader count 合并为同一个跨 VM CAS word；release 只能获取
  `READY,0`，reader 只能原子增加 `READY,n`。
- 每次 restore 只有一个独立 context/slot reader。关闭控制 fd 后，VMA、
  fault、reader 和 per-call stats 仍由各自 kref 保持，最后一个 VMA 关闭
  后才释放 reader。
- V2 prepare 返回 generation；V2 resume/release 强制携带 generation；同
  key 重新 prepare 后，旧 generation 的 resume/release 均返回 `ESTALE`。
- V2 ABI 11/11、fd-close-with-live-VMA、call-stats reopen query、旧
  readonly/MoW/MoA/lifecycle、跨 VM litmus 和 dmesg 门禁均通过。
- `REAL_SHARED_VMA_LEAF` capability 已取消；现有 VMA 机制继续准确报告为
  image-driven reconstruction。

## 最终收口阶段 2：事务 restore 与 MM fail-fast（2026-07-13）

- kernel 提交为 `18f804f4f`。
- 默认匿名内存 restore 已事务化：所有目标区间先做无冲突检查，逐 region
  记录成功映射；后续任何错误均按逆序 `vm_munmap()`，随后才释放 context
  和 slot reader。
- 两 region 故障注入在第一段成功后返回 `EIO`，验证两段地址均可重新以
  `MAP_FIXED_NOREPLACE` 建立映射、reader_count 回到 0、release 成功；连续
  20 次重复通过。
- 已通过真实 hook 验证并在 `mm_failfast_mask` 中声明的操作只有：
  `mprotect`、`fork`、read/write/long-term GUP、partial `munmap` 和
  `mremap`。它们均返回 `EOPNOTSUPP`，完整 VMA unmap/进程退出仍受支持。
- 新内核 #79 在 VM0/VM1/localfork 通过 ABI 11/11；V2/legacy lifecycle、
  failure tests、跨 VM readonly/MoW/MoA、10×100,000 litmus 和三 VM dmesg
  门禁全部通过。
- 当前 rollback 声明只覆盖默认匿名内存数据路径；可选 global/thread
  restore 是独立 correctness 子集，尚不声明具有可逆事务语义，也不进入
  默认论文数据面 benchmark。

## 阶段 3/4：fast path 与 measurement 收口（2026-07-13）

阶段 3 kernel commit 为 `cbb0d33a5`。V2 默认 restore 只执行 O(1)
manifest/bounds admission；legacy 或 `CXLFORK_F_VALIDATE_FULL` 才执行完整
VMA/PT/state/rebase validation 和 checksum。`path_mask`、`validated_ptes` 和
新的统计 validity mask 按单次调用返回。CXL VMA image 仅用于只读 lookup
证据，未接入 `mm_mt`；临时 Maple probe 已删除。

阶段 4 将 prepare/restore/fault breakdown 对齐到实际执行区间：

- prepare：lock/lifecycle、VMA preflight、PTE walk、GUP、页面复制、PTE
  recheck、metadata、checksum seal、publish；
- restore：manifest/full validation、VMA create、upper page-table allocation、
  shared leaf attach、fallback reconstruction、dirty prefault、global restore、
  rollback 和 residual `other_ns`；
- fault：实际 dispatch 和 CXL-to-local copy。core-MM data CoW 与 leaf
  materialization 尚无完整 hook，validity bit 保持清零，表示 NA 而不是 0。

阶段 4 验收：ABI 11/11、fast/full path、20 次 transactional rollback、MM
fail-fast、fd-close 后 context/fault stats、跨 VM readonly/MoW/MoA、10×100,000
litmus 与三 VM dmesg 均通过。MoW 4 MiB 矩阵明确报告
`shared_leaf_pages=512` 与 `reconstruct_pages=512`，不重复统计。

30 次 4 MiB 样本只报告 mean/P50/P95/stddev，不报告 P99：
`fast_total_ns` 11661.6/11228/14724/1579.27，`full_total_ns`
5934280.53/5929577/5965923/16705.67；validation-only fast/full 为
212.23/203/269/27.4 和 5735.73/5084/5552/2384.42。4/64/192 MiB 单次
fast/full total 约为 19.9us/5.94ms、23.5us/94.4ms、41.4us/283.3ms；仅能
说明默认 fast validation 近似与页数无关，不能宣称完整 restore 为常数时间。

## 阶段 5：A-bit feasibility 与独立状态子集（2026-07-13）

新增 selftest-only `abit-prepare/abit-restore` gate：在 PMD 对齐的 2 MiB
shared-leaf 映射上，checkpoint 前清除源 PTE A/D，目标读取一字节后通过
`INSPECT_V2.current_pte` 观察 CXL leaf。当前 QEMU/KVM backend 实测
`before ...ca05` 到 `after ...ca25`，证明 `_PAGE_ACCESSED` 由硬件 walker
写回共享 CXL leaf。若后续 KVM/EPT/TLB 环境不能稳定观察，该测试输出
`status=unsupported`，不阻塞 shared-leaf、leaf CoW、slot lifecycle 或
fast-path 收口，也不外推为所有真实 CXL 设备的硬件结论。

Hybrid A/D policy 通过：A=1 页面走本地复制，A=0 页面保持共享，D=1 页面
在 restore 时 prefault 本地。cooperative thread-context trampoline 通过。
普通文件/global state 在同一 VM/同一 root filesystem 子集通过；跨 VM 使用
独立 qcow2 root 时，checkpointed `/tmp` inode 不存在并返回 `ENOENT`，因此
本轮不宣称跨 root filesystem 的 global-state restore。

## 阶段 6：并发、scaling 与 fault 回归（2026-07-13）

同一 checkpoint 上并发启动 4 个 restore holder，观测到 3 个 reader 同时
存在（第 4 个因固定测试地址冲突而被拒绝）；active release 返回 `EBUSY`，
所有 VMA 退出后 reader_count 回到 0，最终 release 成功。阶段 4 的 30 次
统计和 4/64/192 MiB scaling 在最终 selftest binary 上重跑通过。

最终门禁包括 ABI 11/11、V2 lifecycle、20 次 rollback、MM fail-fast、跨 VM
readonly/MoW/MoA、Hybrid A/D、A-bit feasibility、cooperative thread context、
同 filesystem fd/global 子集、10×100,000 litmus 与三 VM dmesg/resource 检查。
