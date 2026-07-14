# CXLfork 复现系统：环境、实现、测试与数据指南

> 文档状态：2026-07-14 复现基线说明
>
> 远端权威工作区：`xtl@10.0.16.91:~/cxlfork/cxlfork-repro`
>
> 本地备份工作区：`/home/adonis/cxlfork`
>
> 适用分支：主仓库 `cxlfork-cohort-openwhisk`、内核 `cxlfork-kernel-paper-alignment`、CXLporter `cxlfork-cohort-openwhisk`

## 1. 这套系统做了什么

本项目以 CXLfork 论文为出发点，构建了一套能够在两个 Linux 虚拟机之间共享 checkpoint 数据、恢复匿名地址空间并测量完整控制路径的研究原型。它服务于 Cohort 项目：当 CXLfork 已经减少数据复制、序列化和页表重建后，继续测量跨 OS 请求、目标端唤醒、进程激活、restore ioctl 和上层运行时还留下多少开销。

我们的目标不是百分之百复刻论文，也不是实现支持任意进程的生产级 remote fork。当前系统刻意选择了一个能够被严格验证的范围：

- 底层采用修改过的 Linux 6.6.32，在受限模型中实现真实共享 PTE leaf attach、页表 leaf CoW、数据页 MoW/MoA 和跨 VM slot 生命周期。
- 上层使用 CXLporter 控制守护进程、预派生 ghost 进程池和真实 OpenWhisk standalone action 路径，形成可拆分测量的端到端调用链。
- 实验使用 QEMU/KVM 的共享文件后端模拟两台机器可访问的 CXL 内存。它能验证共享、原子、页表和控制路径语义，但不能代表真实 CXL 设备的绝对延迟、带宽或 NUMA 行为。

一句话概括：这是一个“真实内核数据面 + 可测量的研究型控制面”，而不是完整容器迁移系统。

## 2. 系统架构

```text
                              host: 10.0.16.91

 benchmark client
    |                         direct path -------------------+
    |                                                       |
    +-> OpenWhisk HTTP API                                  |
         -> warm Node.js proxy action (Docker)              |
              -> TCP 172.17.0.1:2301 -----------------------+
                                                               |
                         QEMU hostfwd -> VM1:7000               |
                                                               v
 VM0: checkpoint/prepare                    VM1: restore/invoke
 SSH :2200                                  SSH :2201
 cxlporter-control checkpoint               cxlporter daemon
      |                                     bounded queue
      |                                     pre-forked one-shot ghost
      |                                             |
      +------ /dev/cxlfork PREPARE_V2               +-> RESUME_V2
                    |                                      |
                    +---- shared CXL backend --------------+
                          /dev/shm/cxl_mem, 4 GiB

 localfork VM: ordinary fork baseline, SSH :2202, no shared CXL backend
```

端到端实验同时保留两条路径：

1. **Direct**：客户端直接访问 `172.17.0.1:2301`，测量 QEMU 转发、VM1 daemon、ghost 激活和内核 restore。
2. **OpenWhisk**：客户端先调用 OpenWhisk，再由 Docker 中的 Node.js action 转发到同一 VM1 endpoint。两条路径之差是 Cohort 关注的上层控制面信号。

## 3. 代码与目录

远端主工作区是唯一开发权威源，本地目录是跳板机和重要数据备份区。

| 路径 | 内容 |
|---|---|
| `kernel/linux-6.6.32/` | 修改后的 Linux 内核子模块 |
| `kernel/build-6.6.32/` | 当前统一使用的 out-of-tree 内核构建目录 |
| `cxlporter/` | CXLporter、控制 daemon、客户端、OpenWhisk 集成与控制面测试 |
| `scripts/` | VM 启停、跨 VM litmus、底层 benchmark 脚本 |
| `images/` | VM0、VM1、localfork 的 qcow2 镜像 |
| `cloudinit/` | VM seed ISO |
| `results/` | 主仓库底层 benchmark 数据 |
| `cxlporter/results/` | 控制面 correctness 和 benchmark 数据 |
| `docs/` | 设计、阶段验收和运行说明 |
| `logs/`、`pids/`、`sockets/` | QEMU 日志、PID 和 monitor socket |

本说明使用文档编写时的最新源码提交：

| 仓库 | 分支 | 当前提交 |
|---|---|---|
| 主仓库 | `cxlfork-cohort-openwhisk` | 本文提交前为 `8b806e4f8b88e62f26f79c7db41739066e42c410`；最终数据采集源码为 `793a7bd0c30398168cb936e39e8dc6aab7b57494` |
| kernel | `cxlfork-kernel-paper-alignment` | `15ae46586aaff49c5f6b72271da8b5833899132a` |
| CXLporter | `cxlfork-cohort-openwhisk` | 当前文档提交前为 `603d1b00e5b67f26bde5a657c076b497306e12a4`；最终数据采集源码为 `ced2c8eb6e1bfef89a2e39cf43dcbd1e2f00d488` |

数据目录中的 `environment.txt` 和 `SHA256SUMS` 才是对应实验的最终版本凭据，不应只根据当前 HEAD 猜测实验代码版本。

## 4. 当前支持范围和真实性边界

### 4.1 可靠支持的核心模型

- x86-64、4 KiB 基础页。
- checkpoint 调用者协作式静止且为单线程。
- 私有匿名 VMA；地址、权限和元数据必须符合驱动的 eligibility 检查。
- restore 使用无冲突固定地址；失败时回滚已建立的映射和引用。
- PMD 对齐、覆盖完整 PMD 的只读或 MoW 区域可以进入真实 shared PTE leaf attach。
- MoW 在写入时先本地化共享 leaf，再由 Linux 写保护路径产生本地匿名数据页。
- MoA 在首次访问时把 CXL 数据复制到本地页。
- Hybrid 使用 checkpointed A/D 信息选择路径；dirty prefetch 是单独统计项。
- slot 的 generation、reader 和状态转换在 VM 间共享，并采用原子 CAS 与 release/acquire 发布协议。

### 4.2 没有实现或只实现受限子集的内容

| 能力 | 当前结论 |
|---|---|
| 真实共享 PTE leaf | 已实现，但仅限受支持的对齐匿名内存模型 |
| PTE leaf CoW | 已在受支持的写 fault 路径实现和验证 |
| 真实共享 Maple Tree/VMA leaf | **未实现**；restore 根据 VMA image 在目标 mm 中重建本地 VMA/Maple Tree |
| 完整 `task_struct/mm_struct` 对象图 rebase | 未实现 |
| 任意 IP/SP/TLS 透明恢复 | 未实现；只有独立测试过的 cooperative thread trampoline 子集 |
| global state | 仅普通文件 fd、cwd/root、umask、signal mask 等受限子集；不支持 socket、pipe、epoll、timerfd 和完整 namespace |
| 多线程透明 checkpoint | 不支持，必须明确失败 |
| THP/hugetlb、共享映射、DAX/PFNMAP、长期 pin 等 | 不属于支持模型 |
| 任意 mprotect/fork/GUP/partial munmap/mremap | 只对已有真实 hook 和测试覆盖的入口声明 fail-fast；其余按 unsupported 处理 |
| 真实 CXL 硬件性能 | 未测量；当前共享文件后端只用于功能和软件控制路径研究 |

`FULL_PRIVATE_STATE` 不应被描述为已支持。默认论文数据面 benchmark 也不会启用非必要的 global/thread restore，避免它们污染匿名内存 fast path。

## 5. 环境准备

### 5.1 主机要求

已验证主机配置包括：

- Ubuntu host，最终控制面数据记录的 host kernel 为 `6.8.0-124-generic`。
- x86-64 CPU，支持 KVM；当前 QEMU 使用 `-cpu host`。
- QEMU/KVM，支持 q35、NVDIMM 和共享 `memory-backend-file`。
- 至少能同时容纳两个 16 GiB CXL VM；运行 localfork 时还需额外 16 GiB。
- `/dev/shm` 至少有 4 GiB 可用空间。
- 内核构建工具链、Git、GCC/Make、SSH/SCP、Python 3、Docker。
- OpenWhisk standalone 所需环境；最终数据中的 Docker 版本为 `29.1.3`，OpenWhisk build 为 `7ef091c`，action 使用 Node.js 20。

先检查：

```bash
test -e /dev/kvm && ls -l /dev/kvm
df -h /dev/shm
qemu-system-x86_64 --version
docker version
ss -lnt | grep -E ':(2200|2201|2202|2301)\b' || true
```

### 5.2 获取仓库和子模块

服务器已有完整环境。若在同一服务器重新初始化：

```bash
cd /home/xtl/cxlfork/cxlfork-repro
git checkout cxlfork-cohort-openwhisk
git submodule update --init --recursive
git -C kernel/linux-6.6.32 checkout cxlfork-kernel-paper-alignment
git -C cxlporter checkout cxlfork-cohort-openwhisk
```

确认三层状态：

```bash
git status --short
git -C kernel/linux-6.6.32 status --short
git -C cxlporter status --short
git submodule status
```

不要在本地 `/home/adonis/cxlfork` 直接替代远端开发；本地副本主要用于保存文档、diff 和不可丢失的实验数据。

### 5.3 VM 镜像和 SSH

启动脚本要求以下文件存在：

```text
images/vm0.qcow2
images/vm1.qcow2
images/normal-localfork.qcow2
cloudinit/vm0-seed.iso
cloudinit/vm1-seed.iso
```

guest 默认用户为 `ubuntu`，实验环境已经配置 SSH 登录。新环境应优先配置密钥，并避免把凭据写入代码或结果文件。更底层的镜像制作历史参见 `docs/environment-runbook-zh.md`。

## 6. 编译内核和自测试

所有脚本默认使用 `kernel/build-6.6.32`，不要混用历史构建目录。

```bash
cd /home/xtl/cxlfork/cxlfork-repro
mkdir -p kernel/build-6.6.32

make -C kernel/linux-6.6.32 \
  O="$PWD/kernel/build-6.6.32" olddefconfig

kernel/linux-6.6.32/scripts/config \
  --file kernel/build-6.6.32/.config --enable CXLFORK
kernel/linux-6.6.32/scripts/config \
  --file kernel/build-6.6.32/.config --enable CXLFORK_SELFTEST
kernel/linux-6.6.32/scripts/config \
  --file kernel/build-6.6.32/.config --enable NLS_CODEPAGE_437
kernel/linux-6.6.32/scripts/config \
  --file kernel/build-6.6.32/.config --enable NLS_ISO8859_1

make -C kernel/linux-6.6.32 \
  O="$PWD/kernel/build-6.6.32" olddefconfig
make -C kernel/linux-6.6.32 \
  O="$PWD/kernel/build-6.6.32" -j"$(nproc)" bzImage headers_install
```

预期：

```bash
grep -E '^CONFIG_CXLFORK(=|_)' kernel/build-6.6.32/.config
test -s kernel/build-6.6.32/arch/x86/boot/bzImage
```

应看到 `CONFIG_CXLFORK=y` 和 `CONFIG_CXLFORK_SELFTEST=y`。驱动设计为 built-in，因为 core-MM 的 fault 和页表路径直接调用其 helper。

自测试源码位于 `tools/testing/selftests/cxlfork/`，最终二进制安装位置是：

```text
kernel/build-6.6.32/kselftest/cxlfork/cxlfork_test
kernel/build-6.6.32/kselftest/cxlfork/cxlfork_litmus
```

可用内核 kselftest 的 `TARGETS=cxlfork` 构建/安装，或沿用当前构建目录中已生成的二进制。每次 UAPI 修改后必须先 `headers_install` 再重编测试和 CXLporter，保证只使用权威头文件。

## 7. 启动和检查虚拟机

### 7.1 默认拓扑

| 实例 | 用途 | SSH | 共享后端 |
|---|---|---:|---|
| VM0 | checkpoint/prepare | `localhost:2200` | `/dev/shm/cxl_mem` |
| VM1 | restore、daemon、invoke | `localhost:2201` | 与 VM0 相同 |
| localfork | 普通 fork baseline | `localhost:2202` | 无 |

VM0/VM1 默认各使用 16 GiB、16 vCPU。后端文件大小为 4 GiB，guest 中驱动使用物理窗口：

```text
CXL_PHYS=0x484000000
CXL_SIZE=0xfb000000    # 4,211,081,216 bytes
```

QEMU 通过 NVDIMM 把同一个 `share=on` 文件映射给两台 VM。这里的“CXL”是功能模拟名称，不代表 QEMU 已模拟真实 CXL fabric 性能。

### 7.2 启动

```bash
cd /home/xtl/cxlfork/cxlfork-repro

# 推荐分步启动，便于定位资源问题
./scripts/start-cxlfork-vms.sh cxl
./scripts/start-cxlfork-vms.sh localfork

# 或一次启动三台
# ./scripts/start-cxlfork-vms.sh all
```

VM1 还配置了：

```text
host 172.17.0.1:2301 -> QEMU hostfwd -> VM1:7000
```

绑定 `172.17.0.1` 是为了让默认 Docker bridge 中的 OpenWhisk action 能访问 host endpoint。

### 7.3 启动后核查

```bash
for port in 2200 2201 2202; do
  ssh -o StrictHostKeyChecking=no -p "$port" ubuntu@localhost \
    'uname -r; cat /proc/cmdline'
done

for port in 2200 2201; do
  ssh -o StrictHostKeyChecking=no -p "$port" ubuntu@localhost \
    'ls -l /dev/cxlfork; dmesg | tail -80'
done
```

VM0/VM1 cmdline 必须包含 `cxlfork.cxl_phys` 和 `cxlfork.cxl_size`，并出现 `/dev/cxlfork`；localfork 不应带 CXL 参数。

### 7.4 停止

```bash
./scripts/stop-cxlfork-vms.sh all
```

不要在 VM 仍运行时手工 truncate `/dev/shm/cxl_mem`。启动脚本也会通过 PID、端口和空间检查防止覆盖活跃实验。

## 8. CXLfork 内核核心实现

### 8.1 代码入口与 UAPI

主要新增/修改位置：

- `drivers/cxlfork/cxlfork_main.c`：设备、checkpoint/restore、共享布局、slot、统计和策略主体。
- `drivers/cxlfork/cxlfork.h`：内部数据结构。
- `include/uapi/linux/cxlfork.h`：**唯一权威 UAPI**。
- `include/linux/cxlfork_mm.h`：驱动与 core-MM 的内部接口。
- `mm/memory.c`：共享 leaf materialization 与写 fault 集成。
- `mm/gup.c`、`mm/mremap.c`、`kernel/fork.c`：受限模型的 MM 操作 hook/gate。
- `lib/maple_tree.c`、`include/linux/maple_tree.h`：受控可行性/检查接口；不表示真实共享 VMA leaf 已完成。
- `tools/testing/selftests/cxlfork/`：ABI、correctness、lifecycle、fast path、fault 和 litmus 测试。

V2 ioctl 包括 capabilities、prepare、resume、release、inspect、A/D mark、litmus、per-call stats 和 GUP probe。所有 V2 结构以 `size`、`abi_version` 开头，使用固定宽度字段、显式保留字段和严格 size/version/reserved 校验。旧 ioctl 只保留兼容性，不用于当前论文机制结论。

### 8.2 受限一致 checkpoint

`PREPARE_V2` 的核心顺序是：

1. 验证单线程、VMA 类型、页大小和地址范围。
2. 计算布局和容量，分配 slot 内 extent。
3. 在受控 PTE/VMA 锁序下采集 PTE、PFN、A/D 和权限。
4. 对支持的匿名页执行 GUP/pin 和页面复制。
5. 再次确认 PTE/PFN 没有在采集期间改变。
6. 构建 VMA image、PTE/leaf image、页面 checksum 和 metadata checksum。
7. 只有全部完成后才以 release 语义把 slot 从 WRITING 发布为 READY。

不支持的对象会明确返回错误，失败 slot 不会对 reader 可见。这里的一致性只针对协作式单线程模型，不等于任意多线程进程的瞬时快照。

### 8.3 共享布局、generation 与 reader 生命周期

共享区域包含 superblock、slot header、动态元数据表、页表 leaf 和数据页。当前布局使用 512 MiB 固定 slot；约 4 GiB 可见窗口最多容纳 7 个 slot。表项不再受早期固定 64 VMA、32 fd、32768 PTE 数组约束，但每个对象仍受 slot、窗口和安全上限约束。

状态机为：

```text
FREE -> WRITING -> READY -> RELEASING -> FREE
```

- key 定位候选 slot，generation 区分同一位置的不同对象版本。
- state 和 reader count 使用跨 VM 原子 CAS 更新。
- producer 使用 release 发布，reader 使用 acquire 获取完整 image。
- stale generation 返回 `ESTALE`；同槽冲突不会静默覆盖活跃对象。
- restore context 独立持有 slot reader 引用。即使 `/dev/cxlfork` fd 已关闭，只要 VMA 仍存在或可能 fault，context、per-call stats 和 reader 都不能释放。
- 活跃 reader 存在时 `RELEASE_V2` 返回 `EBUSY`；最后一个映射退出后才能回收。

在采用这套协议前，项目先用跨 VM litmus 验证了当前 QEMU/KVM 共享后端上的原子 RMW、release/acquire message publication 和 cache-coherent ping-pong。

### 8.4 真实 shared PTE leaf attach

这不是“驱动遍历一份 PTE 镜像后逐页重建”的伪 attach。对于满足条件的 region：

1. 目标 mm 在普通本地内存中创建 PGD/P4D/PUD/PMD 上层页表。
2. PMD 的 leaf 指针直接指向共享 CXL 物理窗口中的 4 KiB PTE leaf。
3. CPU MMU page walker 通过该物理地址读取 leaf PTE。
4. 内核通过专用 ioremap accessor 访问 leaf，不伪造 `struct page`，也不把 CXL leaf 交给 buddy allocator。
5. `INSPECT_V2` 和 stats 可报告 shared leaf 页数、leaf/PFN/checksum 等证据。

真实 attach 要求 region PMD 对齐并完整覆盖 leaf；不符合条件时只能进入明确记录的 fallback reconstruction，不能把 fallback 时间命名为 shared attach。

### 8.5 leaf CoW 与数据页 CoW

共享 leaf 不能被某个恢复进程直接修改，否则会污染 sibling 和 checkpoint。受支持的 MoW 写 fault 路径为：

```text
write fault
  -> mm/memory.c 识别 CXL shared leaf
  -> 复制整个 4 KiB PTE leaf 到普通本地页表页
  -> 原子切换目标 mm 的 PMD，并刷新 TLB
  -> Linux do_wp_page/wp_page_copy
  -> 仅为写入者建立本地匿名数据页
```

因此需要同时验证两种 CoW：页表 leaf PFN 只在写入者一侧改变；数据 PFN 和内容也只在写入者一侧改变。sibling 仍使用原共享 leaf 和 checkpoint 数据。

### 8.6 MoW、MoA 与 Hybrid

- **MoW**：初始读直接访问共享 CXL 数据页，写 fault 才本地复制数据。
- **MoA**：第一次访问即在本地分配和复制页面，后续访问本地页。
- **Hybrid**：依据 checkpointed A/D 信息在两者间选择，并可对 checkpointed dirty 页执行 opportunistic prefetch。

共享 leaf A-bit 硬件更新是单独的 feasibility test。QEMU/KVM 环境曾观测到所需行为，但它可能受 EPT、TLB 和虚拟化实现影响；这项不稳定不会否定 shared-leaf PFN、leaf CoW 和数据 CoW 的其他硬证据，也不能被外推成真实硬件性能。

### 8.7 VMA、执行上下文和 global state

restore 根据 checkpoint 中的 VMA image 调用内核映射接口，在目标 mm 中建立本地 VMA 和 Maple Tree。`find_vma()` 后续走的是本地树，不是跨 OS 共享的 CXL Maple Tree leaf。因此复杂度和统计必须称为 **VMA reconstruction**。

项目还分别实现/测试了 cooperative thread activation 和普通文件 global-state 子集。这些是 correctness 子实验，不是默认匿名 fast path：

- 不把目标 stub 的原执行流冒充任意源进程恢复。
- 不声称完整 `task_struct/mm_struct` rebase。
- socket、pipe、epoll、timerfd、完整 namespace 和任意文件系统环境仍不支持。

### 8.8 失败回滚和性能统计

默认匿名 restore 采用事务式结构：每一步记录已经创建的 VMA、页表、reader 和 context；后续失败时逆序 unmap、释放页表/引用并恢复 slot reader。重复失败测试用于发现残留映射和 reader 泄漏。

V2 stats 是按单次调用返回，不使用跨 restore 的共享累计值。主要分项包括：

- checkpoint scan、PTE walk、GUP、page copy 和 metadata build；
- slot lookup、lock wait、validation 和 lifecycle；
- VMA reconstruction、upper-level allocation；
- shared-leaf attach、fallback reconstruction；
- global restore、dirty prefetch、rollback 和 other；
- fault dispatch、leaf materialization、data CoW、CXL-to-local copy。

字段同时带 supported/valid mask：没有实现或本次路径未发生的机制输出 `NA`，而不是用 0 暗示“耗时为零”。父子区间可能嵌套，不能相加。例如 `restore_ioctl_ns` 包含 `kernel_total_ns`，而 `client_e2e_ns` 又包含 daemon 和 OpenWhisk 路径。

## 9. 上层 CXLporter 与 OpenWhisk 控制面

### 9.1 CXLporter daemon

`cxlporter-control checkpoint` 在 VM0 创建 PMD 对齐的匿名工作集并执行 `PREPARE_V2`。VM1 的 `cxlporter-control serve` 提供：

- function name 到 `(key, generation, bytes, checksum)` 的 registry；
- 只有 `INSPECT_V2` 验证 generation、大小和 checksum 后才接受 REGISTER；
- 有界请求队列和固定大小 ghost pool；
- `CXLP/1` 文本协议的 PING、REGISTER、INVOKE；
- `invoke`、`restore-only`、`cold` 三类调用，以及 readonly/MoW/MoA/Hybrid policy；
- 明确返回 status 和 `error_stage`，不把 restore 失败包装成成功。

### 9.2 当前 ghost 是什么

原论文使用预配置的空 Docker ghost container。当前实现做了有意的工程简化：daemon 在 VM1 预先 `fork()` 普通 Linux 子进程，以 `AF_UNIX/SOCK_SEQPACKET` 与父进程通信；每个 ghost 只处理一次请求，调用 `RESUME_V2`、执行合成 C 工作集、读取 stats 后退出，由父进程 `waitpid()` 并补充新 ghost。

因此当前 ghost 能真实覆盖“预创建执行上下文、排队、唤醒、进程激活、restore、执行和回收”控制路径，但不覆盖 Docker namespace/cgroup/rootfs 创建，也不等价于透明恢复 OpenWhisk language runtime。这个简化符合 Cohort 研究目标；涉及容器资源管理的绝对结论则不能由它推出。

### 9.3 OpenWhisk 集成

OpenWhisk standalone 是真实调度和 action container 路径。Node.js action `cxlporter_proxy.js` 只做 TCP bridge：它不会重复 restore，也不会在容器内执行合成函数。这样 direct 与 OpenWhisk 两条路径共享同一个 VM1 数据面，差值更容易解释。

启动顺序：

```bash
cd /home/xtl/cxlfork/cxlfork-repro/cxlporter

./scripts/31-start-control-plane.sh
./openwhisk/scripts/start-standalone.sh
./openwhisk/scripts/42-deploy-cxlporter-action.sh
```

`31-start-control-plane.sh` 会编译程序、部署到 VM0/VM1，在 VM1:7000 启动默认 4 个 ghost，并通过 host endpoint PING。可用 `POOL=1` 或 `POOL=8` 改变 pool size。

OpenWhisk 启动脚本显式设置每分钟 100000 次 invocation，并拒绝复用 throttle 参数不一致的旧进程。上游 standalone 的 60/min 默认值会导致大样本实验出现 HTTP 429。

停止 OpenWhisk：

```bash
./openwhisk/scripts/stop-standalone.sh
```

## 10. 测试体系

每项机制尽量同时具备成功、边界和失败测试。阶段验收全过程记录在 `docs/cxlfork-phase-acceptance-log.md`，下表是当前最重要的测试入口。

| 层次 | 测试 | 覆盖内容 | 主要结果位置 |
|---|---|---|---|
| 构建 | kernel/selftest build | bzImage、headers、UAPI、自测试编译 | acceptance log；本地 build log 备份 |
| ABI | `cxlfork_test abi` | V2 size/version/reserved、正反向 ABI | 最终 11/11 通过 |
| 跨 VM 内存序 | `scripts/run-cxlfork-litmus.sh` | atomic RMW、release/acquire、coherent ping-pong | `/tmp/cxlfork_litmus.log`；本地 litmus log |
| checkpoint/restore | `cxlfork_test` 子命令 | checksum、permissions、PFN/PTE、错误 key、inspect、容量 | acceptance log |
| lifecycle | `v2-lifecycle`、hold/hold-close | generation、reader、collision、active release、fd close 后 VMA | acceptance log |
| rollback | `v2-rollback` | 失败逆序回滚、reader 和映射泄漏 | 20 次重复通过记录 |
| MM gate | `mm-failfast`、GUP probe | 受支持 hook 的 fork/GUP/mremap 等拒绝 | acceptance log |
| shared leaf | `v2-fastpath` | shared leaf PFN、fallback、upper level、统计 mask | fast-path logs |
| CoW/policy | restore、Hybrid、A-bit 子测试 | leaf/data CoW、MoW/MoA/Hybrid、A/D feasibility | stage 4/5/6 logs |
| 底层性能 | `21-benchmark-unified-touch.sh` | LocalFork 与三种 policy、不同 footprint/mode | `results/*.csv` |
| 控制面正确性 | `32-control-correctness.sh` | direct/OW、stale、malformed、16 并发、EBUSY、dmesg | final correctness 目录 |
| 控制面性能 | `33-benchmark-control-plane.sh` | direct/OW、micro/scaling/concurrency、cold/restore | final benchmark 目录 |

### 10.1 跨 VM litmus

```bash
cd /home/xtl/cxlfork/cxlfork-repro
ROUNDS=10 ITERATIONS=100000 ./scripts/run-cxlfork-litmus.sh
```

最终基线每轮分别执行 100000 次 RMW、message publication 和 ping-pong，共 10 轮，错误数为 0。这证明当前 QEMU/KVM shared backend 满足本项目 slot CAS 协议的实验前提，但不是对所有 CXL 硬件平台的通用证明。

### 10.2 底层 unified-touch benchmark

```bash
cd /home/xtl/cxlfork/cxlfork-repro
ITERS=5 WARMUP=1 \
SIZES="4194304 67108864 201326592" \
MODES="read write" \
POLICIES="mow moa hybrid" \
./scripts/21-benchmark-unified-touch.sh
```

脚本在 host 使用 `headers_install` 后的权威 UAPI 编译 workload，部署到三台 VM；VM0 prepare，VM1 resume/touch，localfork 执行普通 fork baseline。输出 CSV 的旧 45 列 schema 包含 prepare、各种 image build/validation、restore、touch 和页面分类。该脚本形成了阶段演进数据；控制面最终数据使用更新、更严格的 62 列 schema v2。

### 10.3 控制面 correctness

VM、daemon、OpenWhisk 和 action 均就绪后：

```bash
cd /home/xtl/cxlfork/cxlfork-repro/cxlporter
./scripts/32-control-correctness.sh
```

最终测试覆盖 checkpoint/register、direct invoke、OpenWhisk invoke、stale generation、未知 function、malformed request、16 个并发 restore、活跃 reader 下 release=`EBUSY`、reader 退出后 release 成功，以及 VM0/VM1 dmesg 清洁。

### 10.4 控制面 benchmark

```bash
cd /home/xtl/cxlfork/cxlfork-repro/cxlporter
./scripts/33-benchmark-control-plane.sh
```

最终矩阵：

- footprint：4、64、192 MiB；
- policy：MoW、MoA、Hybrid；
- path：direct、OpenWhisk；
- mode：invoke、restore-only、cold；
- ghost pool：1、4、8；
- micro 和 concurrency 各 1000 样本，scaling 各 100 样本。

1000 样本报告 mean/P50/P95/P99/标准差；100 样本 scaling 明确把 P99 记为 `NA`，避免用过少样本声称可信 P99。

### 10.5 每轮实验后的公共检查

```bash
for port in 2200 2201; do
  ssh -p "$port" ubuntu@localhost \
    "dmesg | grep -Ei 'cxlfork|BUG:|WARNING:|Oops|general protection|use-after-free' | tail -100"
done

git status --short
git -C kernel/linux-6.6.32 status --short
git -C cxlporter status --short
```

还应检查 slot reader 回到 0、临时映射和 ghost 都已回收，并保存 environment、原始样本、summary、dmesg 和 checksum manifest。

## 11. 测试数据在哪里

### 11.1 远端权威数据

| 数据 | 远端路径 | 说明 |
|---|---|---|
| 阶段 13 底层性能 | `~/cxlfork/cxlfork-repro/results/cxlfork-phase13-perf.csv` | 45 列、24 行；4/64/192 MiB，read/write，LocalFork/MoW/MoA/Hybrid |
| 历次 unified touch | `~/cxlfork/cxlfork-repro/results/unified-touch-*.csv` | 从早期 image reconstruction 到最终 fast path 的阶段数据，版本间字段语义需结合提交解释 |
| 最终控制正确性 | `~/cxlfork/cxlfork-repro/cxlporter/results/control-correctness-20260713-175411/` | correctness 原始日志、并发 CSV、dmesg |
| 最终控制 benchmark | `~/cxlfork/cxlfork-repro/cxlporter/results/cohort-control-20260713-175429/` | 9400 行、62 列 schema v2、summary、environment、SHA256SUMS |
| 诊断性 throttle 失败 | `~/cxlfork/cxlfork-repro/cxlporter/results/cohort-control-20260713-172616/` | 因 standalone 60/min 限制产生 429；只能用于故障分析，不能作为最终性能数据 |
| 历史阶段日志 | 主要在 `/tmp/cxlfork_*.log` 和 acceptance log 所列路径 | `/tmp` 不保证永久保存，应以本地备份为准 |

最终控制 benchmark 目录的重要文件：

- `control-samples.csv`：每个请求一行的 62 列原始数据。
- `control-summary.csv`：按实验组聚合的统计。
- `samples-*-summary.csv`：每个 path/size/policy/mode 的单独 summary。
- `checkpoint-manifest.csv`：key、generation、bytes 和 checksum。
- `environment.txt`：提交、软件版本、样本数和矩阵。
- `analysis-summary.md`：自动分析摘要。
- `dmesg-2200.log`、`dmesg-2201.log`：实验后内核日志。
- `SHA256SUMS`：结果完整性校验。

### 11.2 本地备份

```text
/home/adonis/cxlfork/remote-backup-20260713/
```

重点目录和文件：

| 本地路径 | 内容 |
|---|---|
| `results/cxlfork-phase13-perf.csv` | 阶段 13 底层性能 |
| `results/unified-touch-*.csv` | 历次底层 benchmark |
| `logs/cxlfork-stage4-fastpath-30-v2.log` | 30 次 fast-path 原始运行；只适合 mean/P50/P95/std，不应报告 P99 |
| `logs/cxlfork-stage4-litmus.log` | 跨 VM 原子和内存序 litmus |
| `logs/cxlfork-stage5-abit.log` | A-bit feasibility |
| `logs/cxlfork-stage6-concurrency.log` | 并发/lifecycle 相关测试 |
| `control-plane/final-correctness/` | 最终控制面 correctness 完整副本 |
| `control-plane/final-benchmark/` | 最终 9400 样本 benchmark 完整副本 |
| `control-plane/diagnostic-throttle/` | 429 诊断数据，非最终结果 |
| `source/kernel-final.diff`、`source/main-final.diff` | 完整源码差异备份 |
| `source/cxlfork-uapi.h` | 权威 UAPI 快照 |

本地控制面备份共 125 个文件，复制后已做 checksum 验证。分析前仍建议运行：

```bash
cd /home/adonis/cxlfork/remote-backup-20260713/control-plane/final-benchmark
awk '{name=$2; sub(/^.*\//, "", name); print $1 "  " name}' \
  SHA256SUMS | sha256sum -c -
```

这份 2026-07-13 历史清单记录的是远端绝对路径，因此本地校验时先保留文件名。后续脚本已经改为生成可直接执行 `sha256sum -c SHA256SUMS` 的相对路径清单。

## 12. 已有结果应如何理解

最终控制 benchmark 共 9400 个请求、0 个失败，其中 direct 6200 个、OpenWhisk 3200 个。4/64/192 MiB 对应的 shared data pages 分别精确为 1024、16384 和 49152；最终默认对齐矩阵未走 fallback，generation 和 checksum 匹配，VM dmesg 清洁。

4 MiB micro 的端到端结果如下：

| 路径/模式 | mean | P50 | P95 | P99 |
|---|---:|---:|---:|---:|
| direct invoke | 0.584 ms | 0.474 ms | 1.025 ms | 1.072 ms |
| OpenWhisk invoke | 6.637 ms | 5.654 ms | 12.762 ms | 15.718 ms |
| direct restore-only | 0.611 ms | 0.538 ms | 1.028 ms | 1.100 ms |
| OpenWhisk restore-only | 6.978 ms | 5.675 ms | 13.890 ms | 16.704 ms |

OpenWhisk invoke 的均值分项中，action bridge 约 0.919 ms、daemon 约 0.156 ms、restore ioctl 约 0.030 ms、kernel restore 约 0.019 ms。它们是嵌套或局部区间，**不能直接相加**。结果说明当前实验中内核数据面已经很短，上层 OpenWhisk 等待、调度、HTTP 和容器 action 路径成为显著部分，这正是 Cohort 动机要研究的现象。

这些结果只适用于当前软件栈、QEMU shared backend 和合成 C workload。它们不证明真实 CXL fabric 的绝对性能，也不等价于恢复完整 Node.js/Docker 应用。

## 13. 最小复现流程

从一个已经具备镜像和依赖的远端工作区出发：

```bash
cd /home/xtl/cxlfork/cxlfork-repro
git submodule update --init --recursive

# 1. 编译
make -C kernel/linux-6.6.32 \
  O="$PWD/kernel/build-6.6.32" -j"$(nproc)" bzImage headers_install

# 2. 启动数据面 VM
./scripts/start-cxlfork-vms.sh cxl

# 3. 验证跨 VM 原子前提
./scripts/run-cxlfork-litmus.sh

# 4. 启动控制面
cd cxlporter
./scripts/31-start-control-plane.sh
./openwhisk/scripts/start-standalone.sh
./openwhisk/scripts/42-deploy-cxlporter-action.sh

# 5. correctness；必须先通过
./scripts/32-control-correctness.sh

# 6. benchmark
./scripts/33-benchmark-control-plane.sh

# 7. 停止
./openwhisk/scripts/stop-standalone.sh
cd ..
./scripts/stop-cxlfork-vms.sh all
```

若只研究底层数据面，则不需要启动 OpenWhisk，改为启动 `localfork` 并运行 `scripts/21-benchmark-unified-touch.sh`。

## 14. 常见故障

### 14.1 VM 端口已占用

启动脚本会拒绝覆盖已有实例。先查看 `pids/*.pid`、`ss -lntp` 和 QEMU 进程，不要直接删除 PID 文件后再次启动。

### 14.2 `/dev/shm` 空间不足

后端需要 4 GiB。停止 VM 后清理确认不再使用的旧文件，不能在运行中 truncate 共享 backend。

### 14.3 guest 没有 `/dev/cxlfork`

检查是否从 `kernel/build-6.6.32/arch/x86/boot/bzImage` 启动、config 是否为 built-in、cmdline 物理范围是否一致，并查看串口日志 `logs/vm*-console.log`。

### 14.4 CXLporter 报 `ETXTBSY`

旧 daemon 仍在执行时不能原位覆盖二进制。`31-start-control-plane.sh` 会先读 daemon PID、终止并等待；手工部署也必须遵循相同步骤。

### 14.5 OpenWhisk 大样本出现 HTTP 429

不要把这类样本混入最终性能结果。使用项目启动脚本重新启动 standalone，确认显式 100000/min 限制。目录 `cohort-control-20260713-172616` 正是这个问题的诊断样本。

### 14.6 stale generation 或 release=`EBUSY`

这是生命周期保护，不一定是 bug。客户端必须携带 REGISTER 返回的 generation；slot 仍被 VMA/restore context 引用时 release 应失败。若所有 worker 已退出仍长期 `EBUSY`，再检查 reader 泄漏。

### 14.7 统计出现 0 或 NA

先检查 supported/valid mask。`NA` 表示 unsupported 或本次路径未执行；0 只有在字段有效且真实计时为零时才有意义。不要把旧 45 列 CSV 与控制面 62 列 schema v2 直接拼接。

## 15. 可以和不可以做出的结论

可以用当前系统证明：

- checkpoint 数据、权限、metadata 和 checksum 在受限模型内一致。
- 两个 mm/VM 的上层页表可以指向同一 CXL leaf PFN，CPU 实际使用该 leaf 完成地址翻译。
- 写入者发生 leaf materialization 和数据页 CoW，不污染 checkpoint 或 sibling。
- MoW、MoA、Hybrid 的受限语义和 PFN 转换真实发生。
- generation/reader/release/collision 和并发 restore 生命周期在当前 shared backend 上正确。
- restore fast path 与 OpenWhisk/daemon/ghost 等控制路径可以按单次请求拆分测量。

不可以声称：

- 已实现真实共享 Maple Tree/VMA leaf。
- 已恢复任意进程、任意线程、完整 kernel object graph 或所有 global state。
- 当前 ghost 就是论文的 Docker ghost container。
- QEMU 文件后端数据代表真实 CXL 设备的延迟、带宽、缓存或 NUMA 特性。
- OpenWhisk proxy action 等价于恢复完整 OpenWhisk language runtime。
- 30 次样本足以给出可信 P99。

## 16. 文档索引与优先级

| 文档 | 用途 |
|---|---|
| `docs/cxlfork-reproduction-system-guide-zh.md` | 本文；当前完整入口和事实边界 |
| `docs/cohort-control-plane-acceptance.md` | 最终控制面验收与关键结果 |
| `cxlporter/docs/cohort-control-plane.md` | 控制协议、measurement schema 和运行方法 |
| `docs/cxlfork-phase-acceptance-log.md` | 阶段 0–13 及后续收口的详细测试流水 |
| `docs/cxlfork-paper-alignment-status.md` | 论文机制对齐与真实性矩阵 |
| `docs/environment-runbook-zh.md` | 环境搭建历史和底层运维细节 |
| `docs/reproduction-zh.md` | 早期复现记录 |
| `docs/current-mainline-guide-zh.md` | 较早主线说明；涉及 OpenWhisk/分支/能力时以本文和最终 acceptance 为准 |

阅读顺序建议：先读本文理解系统全貌，再读 control-plane acceptance 获取最终数据结论，需要审计某项机制时再查 phase acceptance log 和对应原始日志。

---

本系统最重要的使用原则是：把“机制是否真实发生”“软件路径耗时”和“真实 CXL 硬件性能”分开陈述；把默认匿名内存 fast path 与可选 global/thread correctness 子集分开测试；任何能力都以 UAPI capability、PFN/PTE/checksum 证据、失败语义和原始数据共同支撑。
