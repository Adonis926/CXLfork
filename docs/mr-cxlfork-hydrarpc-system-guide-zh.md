# CXLfork + HydraRPC 静态 MapReduce 系统完整说明

> 文档状态：2026-07-20
>
> 远端权威开发环境：`xtl@10.0.16.91:/home/xtl/cxlfork`
>
> 本地跳板机与备份目录：`/home/adonis/cxlfork`
>
> 本文描述的是 `cohort-mr-cxlfork-static` 分支上的最终静态集成系统。

## 1. 先用一句话理解这个系统

这是一套研究型实验系统：上层运行 WordCount MapReduce，节点之间通过
HydraRPC 共享内存 RPC 交换任务和 shuffle 数据，Reducer worker 可以由本地
`fork()` 创建，也可以从共享 CXL 内存中的 CXLfork 模板恢复；系统会记录从
master 派发任务、agent 接收任务、ghost 唤醒、内核 restore、执行 Reduce、回收
进程到响应返回的分项开销。

它的目的不是做一个生产级 MapReduce，也不是透明恢复任意 Linux 进程，而是为
Cohort 研究提供一个可信、可验证、可测量的实验载体：当内核数据面已经通过
共享页表 leaf 和页面共享减少恢复开销以后，上层跨 OS 控制路径还剩下多少成本？

## 2. 为什么要搭建它

CXLfork 的核心价值是减少 remote fork 中的大量数据复制、序列化和页表重建。
但是一次真正的远端任务激活还包括很多别的步骤，例如：

- 请求从发起端传到目标 OS；
- 目标端 agent 收到并解析任务；
- 找到空闲 worker 或唤醒预创建 ghost；
- 调用 `/dev/cxlfork`；
- 建立地址空间并激活进程；
- 执行应用函数；
- 回收进程并补充 ghost；
- 把结果返回 master。

如果只测 `RESUME_V2` ioctl，就无法知道这些上层步骤是否已经成为主要瓶颈。
因此，本系统把 CXLfork 接入一个真实但结构简单的 MapReduce 工作流，并保留
逐阶段测量点。

当前 workload 是 WordCount。它容易独立计算期望结果，适合反复做正确性验证，
也有明确的 map、shuffle、reduce 三个阶段。

## 3. 这套系统不是什么

为了避免误解，先明确边界：

- 它不是任意进程的透明 checkpoint/restore 工具。
- 它不是生产级 MapReduce 集群，没有动态扩缩容、容错调度和任务迁移。
- 当前 MR ghost 是预创建的普通 Linux 子进程，不是论文中的 Docker ghost
  container。
- CXLfork 模板是一块固定地址、内容可校验的匿名内存 arena，不是完整
  Mapper/Reducer 的栈、寄存器、文件描述符和执行位置。
- WordCount 代码已经存在于 `mr_hydra` 二进制中；restore 完成后，ghost 调用
  已编译好的 map/reduce 回调。不能把它描述为“从 CXL 中恢复了完整程序代码和
  任意执行上下文”。
- 但 callback 已不能脱离 template 独立执行：字符表、hash 参数和数值解析/缩放
  状态来自恢复出的 `MR_WorkerStateV1`，缺失或不匹配时任务失败。
- 10.0.16.91 使用 QEMU 共享文件模拟可被两台 VM 共同访问的 CXL 内存，可以
  验证共享、页表和生命周期语义，但不能代表真实 CXL 硬件的绝对延迟、带宽、
  cache 或 NUMA 特性。
- 当前没有把 MR 系统接入旧 OpenWhisk/CXLporter 路径。MR 使用的是重新编写的
  `mr_porter`；旧 CXLporter 子模块保持不变。

这些简化是有意为之：我们优先保证研究所需控制路径真实存在、数据可解释，
而不是无限扩展功能范围。

## 4. 给初学者的名词解释

| 名词 | 通俗解释 |
| --- | --- |
| CXL | 允许 CPU、内存扩展设备和其他节点以一致方式访问内存的一类互连技术 |
| CXLfork | 把 checkpoint 页面和部分页表放到共享 CXL 内存，目标 OS 通过共享和 CoW 快速恢复的内核原型 |
| HydraRPC | 使用共享内存队列和共享 payload allocator 传递请求/响应的 RPC 层 |
| MapReduce | 把输入切成 map 任务，再按 key 分区并由 reduce 汇总的计算模型 |
| master | 切分输入、派发 map/reduce、汇总结果的协调进程 |
| agent | 每个节点上的控制进程，接收 HydraRPC 请求并把任务交给本机 worker |
| worker | 真正执行 map 或 reduce 回调的子进程 |
| porter | agent 内负责 worker/ghost 创建、唤醒、回收和 CXLfork restore 的本地控制层 |
| ghost | 提前 fork、等待任务的一次性子进程；CXLfork 模式下会在任务到达后调用 `RESUME_V2` |
| template | checkpoint 到 CXL 的固定地址匿名 arena；v2 包含 callback 必须消费的 versioned worker state |
| slot | CXLfork 共享窗口中保存一个 checkpoint 对象及其元数据的空间 |
| generation | 同一 slot 被重新使用时区分新旧对象的版本号 |
| reader | 正在 restore 或仍持有恢复映射的使用者；reader 非零时 slot 不能 release |
| PTE leaf | 最末级 4 KiB 页表页，其中包含多个虚拟页到物理页的映射项 |
| shared-leaf attach | 目标 mm 的上层页表直接指向 CXL 中的 PTE leaf，而不是逐 PTE 重建 |
| CoW | Copy-on-Write，共享对象被写入时只给写入者复制一份本地副本 |
| MoW | Memory-on-Write，初始读取共享页，写入时复制到本地 |
| MoA | Memory-on-Access，第一次访问就复制到本地 |
| Hybrid | 根据 checkpointed A/D 信息选择共享或本地路径 |

## 5. 当前代码和版本

### 5.1 远端目录

远端服务器 `10.0.16.91` 是权威开发环境：

| 路径 | 内容 |
| --- | --- |
| `/home/xtl/cxlfork/cxlfork-repro` | 主仓库、VM 脚本、镜像、内核子模块和验收文档 |
| `/home/xtl/cxlfork/cxlfork-repro/kernel/linux-6.6.32` | CXLfork Linux 6.6.32 内核源码仓库 |
| `/home/xtl/cxlfork/cxlfork-repro/kernel/build-6.6.32` | 内核构建产物和安装后的 UAPI headers |
| `/home/xtl/cxlfork/cxlfork-repro/cxlporter` | 旧 CXLporter/OpenWhisk 控制面；本 MR 集成不链接它 |
| `/home/xtl/cxlfork/mr-distributed` | WordCount、HydraRPC transport、MR porter 和 benchmark runner |
| `/home/xtl/HydraRPC` | HydraRPC 源码 |
| `/home/xtl/cxlfork/mr-static-results` | MR 集成测试和性能结果 |

本地 `/home/adonis/cxlfork` 是跳板机和重要备份区，不应替代远端权威源码。

### 5.2 最终分支和提交

| 仓库 | 分支 | 最终代码提交 |
| --- | --- | --- |
| 主仓库 | `cohort-mr-cxlfork-static` | `efa6d04627787372c2cde9b8888f5186a07442de` |
| MR 仓库 | `cohort-mr-cxlfork-static` | `518943bd1832eb8ca67e46ba2032a8ee2a910fcd` |
| kernel | `cxlfork-kernel-paper-alignment` | `15ae46586aaff49c5f6b72271da8b5833899132a` |
| 旧 CXLporter | `cxlfork-cohort-openwhisk` | `c511a78f186d899c5af1d7b086cd83f0a65813fc` |
| HydraRPC 快照 | 独立源码树 | `eb185de17f16f138db2ae64176a892a33dd54d18` |

kernel 和旧 CXLporter 在本轮 MR 集成中没有改动。MR 直接复用了已经完成并通过
阶段验收的 CXLfork kernel 和 V2 UAPI。

核查命令：

```bash
git -C /home/xtl/cxlfork/cxlfork-repro status --short
git -C /home/xtl/cxlfork/cxlfork-repro/kernel/linux-6.6.32 status --short
git -C /home/xtl/cxlfork/mr-distributed status --short
git -C /home/xtl/cxlfork/cxlfork-repro submodule status
```

## 6. 实验环境和内存布局

### 6.1 虚拟机拓扑

| 实例 | MR 角色 | SSH 端口 | 说明 |
| --- | --- | ---: | --- |
| VM0 | Mapper 节点，同时运行 master | `localhost:2200` | 发布 CXLfork template；执行 map/localfork |
| VM1 | Reducer 节点 | `localhost:2201` | 执行 reduce/CXLfork restore |
| localfork VM | 早期底层 fork baseline | `localhost:2202` | 不参与最终静态 MR 矩阵 |

VM0、VM1 默认分别配置 16 GiB 内存和 16 vCPU，使用同一个 CXLfork kernel。

### 6.2 两块逻辑数据面必须分开

10.0.16.91 的 host 共享布局如下：

| 用途 | Host 后端 | 范围 | Guest 暴露方式 |
| --- | --- | --- | --- |
| CXLfork checkpoint/页表/数据页 | `/dev/shm/cxl_mem` | 4 GiB 文件 | shared NVDIMM，VM0/VM1 共用 |
| HydraRPC endpoint 0 | `/dev/shm/cxlmem` | offset 0，2 GiB | ivshmem BAR，BDF `00:02.0` |
| HydraRPC endpoint 1 | `/dev/shm/cxlmem` | offset 2 GiB，2 GiB | ivshmem BAR，BDF `00:03.0` |

这两个文件名字很相似，但职责完全不同：

- `/dev/shm/cxl_mem` 保存 CXLfork slot、PTE leaf 和 checkpoint 数据；
- `/dev/shm/cxlmem` 保存 HydraRPC 队列、allocator 和 RPC payload。

不能把两个协议的数据写进同一未分区范围。当前 91 环境用两个普通文件物理隔离；
103 真实 DAX 方案则用严格不重叠的 offset 隔离。

CXLfork guest 物理窗口为：

```text
CXL_PHYS=0x484000000
CXL_SIZE=0xfb000000       # 4,211,081,216 bytes
```

每个 VM 同时看到两个 HydraRPC BAR。最终固定拓扑约定：

- agent 0 使用 `0000:00:02.0/resource2`；
- agent 1 使用 `0000:00:03.0/resource2`；
- VM0 中的 master 能看到两段 BAR，因此能分别向两个 agent endpoint 发请求。

### 6.3 架构总览

```text
Host 10.0.16.91

  /dev/shm/cxl_mem (4 GiB)       /dev/shm/cxlmem (4 GiB)
  CXLfork slots/pages/leaves      Hydra endpoint0 | endpoint1
            |                              |             |
            |                              |             |
  +---------+------------------------------+-------------+---------+
  | VM0 :2200                                                     |
  |                                                              |
  |  mr_hydra master --schedule=role-static                      |
  |       |                                                      |
  |       +--> agent0(role=map) --> mr_porter --> Mapper workers |
  |       |                     localfork                         |
  |       |                                                      |
  |       +---------------- Hydra endpoint1 request --------------|---+
  +--------------------------------------------------------------+   |
                                                                     |
  +------------------------------------------------------------------v--+
  | VM1 :2201                                                           |
  |                                                                    |
  |  agent1(role=reduce) --> mr_porter supervisor                      |
  |                           |                                        |
  |                           +--> pre-forked one-shot ghosts           |
  |                                  |                                 |
  |                                  +--> /dev/cxlfork RESUME_V2        |
  |                                  +--> Reduce callback               |
  |                                  +--> stats / unmap / exit / refill |
  +--------------------------------------------------------------------+
```

## 7. CXLfork 内核层做了什么

### 7.1 代码入口

主要内核代码位于：

- `drivers/cxlfork/cxlfork_main.c`：设备、slot、prepare/resume/release、策略和统计；
- `drivers/cxlfork/cxlfork.h`：内部共享结构；
- `include/uapi/linux/cxlfork.h`：唯一权威用户态 ABI；
- `include/linux/cxlfork_mm.h`：驱动与 core-MM 的内部接口；
- `mm/memory.c`：shared leaf materialization、写 fault 和 CoW；
- `mm/gup.c`、`mm/mremap.c`、`kernel/fork.c`：受限模型的 MM gate/hook；
- `tools/testing/selftests/cxlfork/`：ABI、correctness、lifecycle、fast path 和 litmus 测试。

### 7.2 V2 UAPI

MR 只使用 versioned V2 ioctl。所有结构都有 `size`、`abi_version`、固定宽度字段、
reserved 字段和严格校验。常用操作是：

| 操作 | 作用 |
| --- | --- |
| `QUERY_CAPS_V2` | 查询 ABI、页大小、slot、策略和真实支持能力 |
| `PREPARE_V2` | 把受支持匿名内存 checkpoint 到共享 slot |
| `RESUME_V2` | 按 key+generation 恢复并返回本次 restore ID/统计 |
| `GET_CALL_STATS_V2` | 读取指定 restore 的单次调用和 fault 统计 |
| `INSPECT_V2` | 查看 slot state、generation、reader、checksum 和页面证据 |
| `RELEASE_V2` | generation 匹配且无 reader 时回收 slot |

最终 VM0/VM1 caps 一致：ABI 2、4 KiB 页、2 MiB shared-leaf alignment、
7 个 slot、每个 slot 512 MiB，capabilities 数值为 `31711`。

### 7.3 slot 生命周期

slot 状态机是：

```text
FREE -> WRITING -> READY -> RELEASING -> FREE
```

关键规则：

- producer 只有完成页面、PTE、VMA image 和 checksum 后才能发布 READY；
- key 找对象，generation 区分同一 slot 的新旧版本；
- stale generation 必须失败，不能读到后来覆盖的新对象；
- restore 成功会增加共享 reader；
- 恢复出的 VMA/context 仍可能 fault 时，即使 fd 关闭也不能提前释放 reader；
- reader 非零时 `RELEASE_V2` 返回 `EBUSY`；
- 跨 VM 状态使用原子 CAS 和 release/acquire 语义。

在采用协议前，项目已经用独立跨 VM litmus 验证当前 QEMU/KVM backend 上的原子
RMW、release/acquire publication 和 cache-coherent ping-pong。

### 7.4 真实 shared PTE leaf attach

当前实现不是把 CXL 中的页表当“镜像”读取后再逐 PTE 建表。对满足 PMD 对齐、
完整 leaf 覆盖等条件的 region：

1. 目标 mm 在本地内存分配 PGD/P4D/PUD/PMD；
2. PMD 直接指向 CXL 物理窗口中的 4 KiB PTE leaf；
3. CPU page walker 实际从该物理 leaf 读取 PTE；
4. 内核通过专用 ioremap accessor 访问 leaf，不伪造 `struct page`；
5. CXL leaf 不会被交给普通 buddy allocator；
6. stats/inspect 报告 shared leaf 页数、PFN 和 checksum 证据。

不满足条件时只能走明确记录的 fallback reconstruction，不能把 fallback 称为
shared attach。最终 MR 的 4 MiB MoW/readonly template 均报告：

```text
path_mask=5
shared_leaf_pages=1024
fallback_pages=0
```

### 7.5 leaf CoW 和数据页 CoW

共享 leaf 不能被单个恢复进程直接修改。受支持写 fault 的简化流程是：

```text
写 fault
  -> 识别 shared CXL leaf
  -> 把整个 4 KiB PTE leaf materialize 到本地页表页
  -> 切换当前 mm 的 PMD，刷新 TLB
  -> Linux 写保护路径为写入者复制本地匿名数据页
```

因此 sibling 仍指向原共享 leaf，checkpoint 数据也不被污染。该机制已在 kernel
selftest 中通过 PFN/PTE/checksum 验证。

需要注意：WordCount 的业务输入仍放在 porter/Hydra payload 中，但 callback 现在
必须读取 CXLfork template v2 中的 worker state；缺失、损坏、角色不匹配或没有被
callback 消费都会使任务失败。当前业务只读状态页，不会写完整 4 MiB template，
所以 MoW 数据页写 CoW 的主要硬证据仍来自底层 kernel selftest，而不是 WordCount
本身。

### 7.6 四种页面策略

- `readonly`：只读共享映射；写入不属于允许语义。
- `mow`：读共享页面，写时本地复制。
- `moa`：第一次访问时复制到本地。
- `hybrid`：依据 checkpointed A/D 信息选择路径，并可配合 dirty prefetch。

下面是 2026-07-16、应用状态强绑定之前的历史 policy smoke 结果：

| 策略 | path mask | shared pages | local copy pages | 说明 |
| --- | ---: | ---: | ---: | --- |
| readonly | 5 | 1024 | 0 | shared-leaf 路径 |
| MoW | 5 | 1024 | 0 | 本次业务没有写 template |
| MoA | 17 | 0 | 1 | 当时 fast validation 只访问 header 页 |
| Hybrid | 33 | 0 | 0 | 当时 header-only smoke 没有触发本地 promotion |

这些数据用于说明 kernel policy 路径，不能冒充当前 template v2 的重新测量结果。

### 7.7 尚未完整实现的内核能力

- 没有真实跨 OS Maple Tree/VMA leaf sharing；目标 mm 重建本地 VMA/Maple Tree。
- 没有任意 `task_struct/mm_struct` 对象图 rebase。
- 没有任意 IP/SP/TLS 的透明执行位置恢复。
- 不支持透明多线程 checkpoint。
- global state 只有独立验证过的普通文件等受限子集。
- socket、pipe、epoll、timerfd、完整 namespace 等不支持。
- 只有经过真实 hook 和测试的 MM 操作才能称为 fail-fast，其余应标记 unsupported。

## 8. HydraRPC 和 MapReduce 层做了什么

### 8.1 当前 workload：WordCount

应用代码在 `src/wordcount.c`。Mapper 把文本切成单词并产生 `(word, "1")`，
Reducer 对同一个 key 的所有 value 求和，最后输出：

```text
word count
```

runtime 负责切片、分区、排序、shuffle、`get_next` 和结果写文件。应用只需要实现
map/reduce 回调。

### 8.2 三个业务阶段

1. **Map**：master 根据 `--map-chunk` 切输入，把 descriptor 和输入片段发给
   Mapper agent。worker 执行 map、partition、sort 和 count combiner。
2. **Intermediate metadata**：Mapper 把每个 reducer partition 写成本地 KV
   wire-format 文件，只向 master 返回 `IntermediateLocation`，而不是把整个文件
   放进控制响应。
3. **Reduce/shuffle**：master 汇总每个 reducer 的 locations。Reducer 对本地文件
   直接读取；远端文件通过 Mapper agent 的 `MR_TASK_SHUFFLE_FETCH` 分块获取，
   append 到本地 spill，最后 parse/sort/reduce。

HydraRPC payload 的指针只在一次 request/response 生命周期内有效，因此 Reducer
收到 shuffle chunk 后立刻写 spill，不长期保存共享内存指针。

### 8.3 node-level endpoint

外部只有两个长期角色：

```text
mr_hydra master
mr_hydra agent --workers=N
```

worker 不是单独 CLI 服务，也不创建对外 endpoint。一个 agent endpoint 同时处理：

- master 发来的 map/reduce/shutdown 请求；
- 远端 reducer 发来的 shuffle fetch 请求。

transport 使用 `hydrarpc-poll` busy poll。固定并发 Reducer 要求：

```text
shuffle-connections >= workers
```

每个 Reducer worker 固定绑定一个 response connection。配置 4 个 worker 却只给
1 个 connection 会在 agent 启动时明确失败，而不是运行中静默卡死。

### 8.4 固定角色调度

最终实验使用：

```text
--schedule=role-static
```

它要求恰好两个 agent：

- agent 0：只接收 map；
- agent 1：只接收 reduce；
- `--workers-per-agent=N` 给出每边固定 worker 数；
- agent 自身的 `--role=map|reduce` 再做一次权限检查。

master 以固定窗口并发派发：一批最多给每个 worker 一个任务，response 可以乱序
返回，再按 task/partition ID 汇总。没有动态扩容和调度迁移。

## 9. MR 专用 porter 和四种 worker 生命周期

`src/mr_porter.c` 是本系统重新实现的轻量 porter，不依赖旧 CXLporter。

| launch 模式 | worker 如何产生 | 是否一次性 | 主要用途 |
| --- | --- | --- | --- |
| `persistent` | agent 启动时 fork，循环处理任务 | 否 | warm/persistent baseline |
| `localfork` | 每次 dispatch 到来后再 fork | 是 | 普通 fork baseline |
| `local-prefork` | 预先 fork 等待，任务完成后退出并 refill | 是 | 不做 CXL restore 的 ghost baseline |
| `cxlfork` | 预先 fork 等待，收到任务后 `RESUME_V2` | 是 | CXLfork ghost 路径 |

### 9.1 porter 内部结构

agent 启动时创建：

- 每个 worker 一个共享 slot，保存 task descriptor、payload 和 response；
- 一个 `SOCK_SEQPACKET` control channel；
- 一个 porter supervisor；
- 根据 launch mode 创建 worker/ghost 池。

porter 支持异步 `submit/collect`。supervisor 同时观察多个 worker slot，所以
4 个 ghost 可以真正并发，而不是 master 批量发送后仍在 supervisor 内串行。
所有 HydraRPC response 仍由 agent 主循环统一发布，避免多个线程并发操作 transport
和 response 乱配。

### 9.2 CXLfork ghost 的一次任务

一个 CXLfork ghost 的生命周期是：

```text
pre-fork 并等待
  -> agent 把 task 发布到本地共享 slot
  -> ghost 被唤醒
  -> 打开 /dev/cxlfork
  -> RESUME_V2(key, generation, policy)
  -> 校验并 bind versioned worker state
  -> callback 必须消费恢复状态
  -> 执行 map/reduce 回调
  -> GET_CALL_STATS_V2
  -> munmap 恢复区域并关闭 context/fd
  -> 退出
  -> supervisor waitpid 并 fork 新 ghost
```

最终并发测试通过 `INSPECT` 实际观察到 `readers=4`，随后降回 0；8 个 Reducer
任务使用 8 个不同 PID。这证明不是用同一个进程伪装多次 restore。

## 10. CXLfork template 到底保存了什么

这是理解当前原型最重要的一点。

template publisher 会在默认地址 `0x500000000000` 创建一段 2 MiB 对齐的私有匿名
arena，写入 template v2 header、versioned `MR_WorkerStateV1` 和可重复 payload，
然后调用 `PREPARE_V2`。当前实验通常使用 4 MiB template：

```text
base  = 0x500000000000
bytes = 4194304
role  = reduce
key   = 1002（示例）
```

prepare 返回：

- slot；
- generation；
- page checksum；
- payload checksum；
- page/region 数和耗时。

目标 ghost 用 key+generation 恢复同一固定地址，并检查 role、base、bytes、seed、
fingerprint、state checksum 和 checksum 元数据。

`MR_WorkerStateV1` 保存 WordCount 真正使用的初始化状态：

- 256 项 word-character 分类表；
- 256 项小写转换表；
- 256 项数字解析表；
- partition hash 初值和乘数；
- 数值 radix 和 `value_scale`；
- role、版本、大小、flags、checksum 和 reserved 字段。

Mapper、默认 partitioner 和 Reducer 都通过 `MR_GetWorkerState()` 读取这些字段。
porter 要求 `template_binding_flags=15`，即 validated、role-match、app-consumed 和
required 四个条件全部成立。合法的 scale=2 Reducer template 会使相同输入的所有
WordCount 计数严格翻倍；损坏状态、错误角色和 stale generation 均已实测失败。

它没有保存：

- WordCount 函数机器码；
- 任意源进程的寄存器/IP/SP；
- Mapper/Reducer 运行到一半时的栈；
- HydraRPC socket/queue context；
- 任意 fd、namespace 或容器状态。

因此，最准确的说法是：系统恢复的是 MR callback 正确执行所必需的、受限且只读
的 worker 初始化状态，并把它接入真实 worker 激活生命周期；它仍不是透明
remote-fork 一个运行中的完整 MR worker。

## 11. 一次完整作业如何运行

以最终默认拓扑为例：

1. VM0 发布 Reducer template，得到 generation 和 checksum。
2. VM0 启动 map agent，launch=`localfork`，固定 4 个逻辑 worker。
3. VM1 启动 reduce agent，launch=`cxlfork`，预创建 4 个 ghost。
4. VM0 启动 master，打开 endpoint 0/1。
5. master 批量派发 map；Mapper 子进程生成 partition 文件和 locations。
6. master 按 reducer 聚合 locations，并向 VM1 批量派发 4 个 reduce。
7. 每个 ghost 调用 `RESUME_V2`，bind worker state，Reduce 必须消费该状态。
8. Reducer 通过 HydraRPC 从 VM0 拉取远端 partition，写 spill 并汇总。
9. agent 把 232-byte measurement envelope 和业务结果一起返回 master。
10. master 校验 envelope、去掉它，再解析 WordCount 结果。
11. master 写 output，向两个 agent 发 shutdown。
12. 检查 reader 回到 0，用正确 generation release template。

## 12. 测量设计

### 12.1 `mr_task_result_v2`

每个 map/reduce response 的业务 payload 前有固定 232-byte、versioned envelope。
master 严格验证 magic、size、version 和 reserved 后才移除。

主要字段：

| 字段 | 含义 |
| --- | --- |
| `roundtrip_ns` | master 发任务到收到对应 response |
| `porter_total_ns` | porter 从接收 dispatch 到完成回收/refill 的外层区间 |
| `dispatch_ns` | control command 到 supervisor 接收 |
| `fork_ns` | localfork 的 fork 时间 |
| `wakeup_ns` | 本地 slot 发布到 worker 开始 |
| `restore_ioctl_ns` | 用户态包围 `RESUME_V2` 的墙钟区间 |
| `template_validate_ns` | ghost 对 template header/state 的验证和 role bind |
| `task_ns` | 只包围应用 map/reduce 回调，不包含 restore |
| `reap_ns` | `waitpid()` 回收一次性 worker |
| `refill_ns` | 补充新 ghost |
| `kernel_total_ns` | 内核按本次 restore 返回的 total |
| `path_mask` | 本次实际使用的恢复路径 |
| page counters | shared leaf、fallback、本地复制和 leaf copy 页数 |
| `template_state_checksum` | 实际 bind 的 worker-state checksum |
| `template_access_checksum/count` | callback 获取和消费恢复状态的证据 |
| `template_state_pages` | worker state 覆盖的页面数；当前为 1 |
| `template_binding_flags` | 必须为 15，表示四项 binding 条件全部成立 |

### 12.2 字段不能随便相加

有些区间是嵌套的：

- `restore_ioctl_ns` 包含 `kernel_total_ns`；
- `roundtrip_ns` 包含 porter、task 和 HydraRPC 等待；
- `porter_total_ns` 是外层区间，包含多个子阶段。

所以不能把所有列相加当总时间。正确做法是比较父区间和子区间的差值，或只在
同一层级横向比较。

### 12.3 runner 的端到端口径

`run_ms` 从 host 发起远端 master 命令到 master 返回。agent SSH 进程在它之前刚刚
启动，agent readiness 可能影响 master；显式 build、输入发现/复制、master 返回
后的 agent wait、日志复制、sort/diff 校验和 summary 生成不在该计时内。

最终矩阵用 5 次 warmup、30 次 repeat。30 次只报告 mean/P50/P95/标准差，不报告
P99；若要可信 P99，应该至少做数百次，建议约 1000 次。

## 13. 如何构建

### 13.1 构建 CXLfork-enabled MR

```bash
cd /home/xtl/cxlfork/mr-distributed

cmake -S . -B build-static-cxlfork \
  -DHYDRARPC_ROOT=/home/xtl/HydraRPC \
  -DMR_ENABLE_CXLFORK=ON \
  -DCXLFORK_UAPI_INCLUDE_DIR=/home/xtl/cxlfork/cxlfork-repro/kernel/build-6.6.32/usr/include

cmake --build build-static-cxlfork -j"$(nproc)"
```

### 13.2 构建不带 CXLfork 的对照版本

```bash
cmake -S . -B build-static-local \
  -DHYDRARPC_ROOT=/home/xtl/HydraRPC \
  -DMR_ENABLE_CXLFORK=OFF

cmake --build build-static-local -j"$(nproc)"
```

不带 CXLfork 的版本调用 `cxlfork-caps` 会明确返回不支持，不能误报 capability。

### 13.3 何时需要重编 kernel

普通 MR/porter 修改不需要重写或重编 kernel。只有修改内核/UAPI 时才需要：

1. 在 `kernel/linux-6.6.32` 修改源码；
2. 构建 `kernel/build-6.6.32/arch/x86/boot/bzImage`；
3. 重新执行 `headers_install`；
4. 用新权威 header 重编 MR；
5. 重启 VM。

当前最终 kernel 已经构建好，分支与远端完全同步。

## 14. 如何启动环境

### 14.1 启动前检查

不要直接重复启动。先看端口和 PID：

```bash
cd /home/xtl/cxlfork/cxlfork-repro

ss -lnt | grep -E ':(2200|2201|2202)\b' || true
for f in pids/*.pid; do test -f "$f" && echo "$f $(cat "$f")"; done

./scripts/start-cxlfork-vms.sh check
```

`check` 会验证 CXLfork/Hydra backend 范围。默认 91 输出应显示两个不同文件。

### 14.2 启动 VM0/VM1

如果 VM 没有运行：

```bash
./scripts/start-cxlfork-vms.sh cxl
```

启动后检查：

```bash
for port in 2200 2201; do
  ssh -p "$port" -o StrictHostKeyChecking=no ubuntu@localhost \
    'uname -r; ls -l /dev/cxlfork; cat /proc/cmdline; lspci -nn | grep -i shared || true'
done
```

不要在 VM 运行期间删除或 truncate `/dev/shm/cxl_mem`、`/dev/shm/cxlmem`。

### 14.3 部署 MR 二进制

```bash
cd /home/xtl/cxlfork/mr-distributed

for port in 2200 2201; do
  scp -P "$port" -o StrictHostKeyChecking=no \
    build-static-cxlfork/mr_hydra \
    ubuntu@localhost:/tmp/mr_hydra
done
```

### 14.4 验证两台 VM capability 一致

```bash
for port in 2200 2201; do
  ssh -p "$port" -o StrictHostKeyChecking=no ubuntu@localhost \
    'sudo /tmp/mr_hydra cxlfork-caps'
done
```

## 15. 手工运行一遍 CXLfork WordCount

以下流程适合第一次学习。`GEN` 和 `SUM` 必须取自当次 publisher 输出，不能照抄
历史数字。

### 15.1 准备输入

Host 上已有测试输入：

```bash
scp -P 2200 -o StrictHostKeyChecking=no \
  /home/xtl/cxlfork/mr-file-sim-smoke/input/input_0.txt \
  ubuntu@localhost:/tmp/mr-input.txt
```

### 15.2 发布 Reducer template

```bash
PUB=$(ssh -p 2200 -o StrictHostKeyChecking=no ubuntu@localhost \
  'sudo /tmp/mr_hydra template --role=reduce --key=1002 --bytes=4194304 --value-scale=1')

echo "$PUB"
GEN=$(echo "$PUB" | sed -n 's/.* generation=\([0-9][0-9]*\).*/\1/p')
SUM=$(echo "$PUB" | sed -n 's/.* page_checksum=\([0-9][0-9]*\).*/\1/p')
echo "generation=$GEN checksum=$SUM"
printf 'export GEN=%s\nexport SUM=%s\n' "$GEN" "$SUM" > /tmp/mr-template.env
```

最后一行把两个数保存在 host 的 `/tmp/mr-template.env`，供其他终端读取。执行
`cat /tmp/mr-template.env` 应看到两个非空十进制整数。

如果 key 对应 slot 已经有未释放对象，publisher 会明确失败。先 inspect，确认对象
身份和 reader，再用匹配 generation release；不要盲目清空共享文件。

### 15.3 终端 A：启动 VM0 Mapper agent

```bash
ssh -p 2200 -o StrictHostKeyChecking=no ubuntu@localhost \
  "sudo rm -rf /tmp/mr-manual-map; \
   sudo /tmp/mr_hydra agent \
     --backend=ivshmem \
     --path=/sys/bus/pci/devices/0000:00:02.0/resource2 \
     --node-id=0 --agent-count=2 --workers=4 \
     --role=map --launch=localfork \
     --template-bytes=4194304 \
     --store-dir=/tmp/mr-manual-map \
     --size=2147483648 --shuffle-size=2147483648 \
     --payload-max=4194304 \
     --shuffle-connections=4 --queue-policy=shared_pair"
```

agent 会等待 master 初始化 Hydra endpoint。

### 15.4 终端 B：启动 VM1 Reducer agent

新终端不会自动继承 15.2 中的 shell 变量，因此先读取刚才生成的文件并确认：

```bash
source /tmp/mr-template.env
echo "generation=$GEN checksum=$SUM"
```

确认后再启动 agent：

```bash
ssh -p 2201 -o StrictHostKeyChecking=no ubuntu@localhost \
  "sudo rm -rf /tmp/mr-manual-reduce; \
   sudo /tmp/mr_hydra agent \
     --backend=ivshmem \
     --path=/sys/bus/pci/devices/0000:00:03.0/resource2 \
     --node-id=1 --agent-count=2 --workers=4 \
     --global-worker-base=4 \
     --role=reduce --launch=cxlfork \
     --template-key=1002 --template-generation=$GEN \
     --template-page-checksum=$SUM \
     --template-bytes=4194304 \
     --template-value-scale=1 \
     --cxlfork-policy=mow --validation=fast \
     --store-dir=/tmp/mr-manual-reduce \
     --size=2147483648 --shuffle-size=2147483648 \
     --payload-max=4194304 \
     --shuffle-connections=4 --queue-policy=shared_pair"
```

### 15.5 终端 C：运行 master

VM0 中 master 能访问两个 ivshmem endpoint：

```bash
ssh -p 2200 -o StrictHostKeyChecking=no ubuntu@localhost \
  'sudo /tmp/mr_hydra master \
     --backend=ivshmem \
     --input=/tmp/mr-input.txt --output=/tmp/mr-output.txt \
     --agent=/sys/bus/pci/devices/0000:00:02.0/resource2 \
     --agent=/sys/bus/pci/devices/0000:00:03.0/resource2 \
     --schedule=role-static --workers-per-agent=4 \
     --reducers=4 \
     --size=2147483648 --payload-max=4194304 \
     --connections=4 --queue-policy=shared_pair'
```

master 完成后会向两个 agent 发送 shutdown。两个 agent 终端应正常退出。

### 15.6 校验输出

```bash
scp -P 2200 -o StrictHostKeyChecking=no \
  ubuntu@localhost:/tmp/mr-output.txt /tmp/mr-output.txt

sort /tmp/mr-output.txt > /tmp/mr-output.norm
diff -u \
  /home/xtl/cxlfork/mr-file-sim-smoke/expected.txt \
  /tmp/mr-output.norm
```

`diff` 无输出表示结果一致。

### 15.7 inspect 和 release

```bash
ssh -p 2201 -o StrictHostKeyChecking=no ubuntu@localhost \
  'sudo /tmp/mr_hydra cxlfork-inspect 1002'

ssh -p 2201 -o StrictHostKeyChecking=no ubuntu@localhost \
  "sudo /tmp/mr_hydra cxlfork-release 1002 $GEN"
```

inspect 应看到 `readers=0`、generation/checksum 匹配；release 输出 `verify=ok`。

## 16. 推荐使用 benchmark runner

手工流程适合理解，批量实验应使用：

```text
/home/xtl/cxlfork/mr-distributed/scripts/run-bench.sh
```

runner 不会启动 QEMU，也不会自动发布 CXLfork template；它负责：

- 通过 SSH 启动 master/agent；
- 复制输入和输出；
- 固定角色与 launch mode；
- warmup/repeat；
- WordCount 校验；
- 收集逐任务 envelope；
- 生成统计和日志。

worker descriptor 格式：

```text
HOST,MASTER_PATH,AGENT_PATH,ROLE,LAUNCH,WORKERS
```

最终 CXLfork 30 次实验的命令骨架如下。先发布 template 并设置 `GEN`、`SUM`：

```bash
cd /home/xtl/cxlfork/mr-distributed

BYTES=$(wc -c < /home/xtl/cxlfork/mr-file-sim-smoke/input/input_0.txt)
OUT=/home/xtl/cxlfork/mr-static-results/my-cxlfork-run

scripts/run-bench.sh \
  --mode=ssh --repo="$PWD" \
  --input-dir=/home/xtl/cxlfork/mr-file-sim-smoke/input \
  --expected=/home/xtl/cxlfork/mr-file-sim-smoke/expected.txt \
  --output-dir="$OUT" --input-bytes="$BYTES" \
  --master-host=127.0.0.1:2200 \
  --worker=127.0.0.1:2200,/sys/bus/pci/devices/0000:00:02.0/resource2,/sys/bus/pci/devices/0000:00:02.0/resource2,map,localfork,4 \
  --worker=127.0.0.1:2201,/sys/bus/pci/devices/0000:00:03.0/resource2,/sys/bus/pci/devices/0000:00:03.0/resource2,reduce,cxlfork,4 \
  --ssh-user=ubuntu \
  --remote-dir=/tmp/mr-bench \
  --no-remote-build --remote-binary=/tmp/mr_hydra --sudo \
  --backend=ivshmem --shuffle-backend=ivshmem \
  --size=2147483648 --payload-max=4194304 \
  --schedule=role-static --reducers=4 --shuffle-connections=4 \
  --template-bytes=4194304 \
  --template-value-scale=1 \
  --reduce-template-key=1002 \
  --reduce-template-generation="$GEN" \
  --reduce-template-checksum="$SUM" \
  --cxlfork-policy=mow --validation=fast \
  --warmup=5 --repeat=30 --verify=all
```

比较 launch mode 时只替换第二个 worker descriptor 的 `LAUNCH`：

```text
reduce,persistent,4
reduce,localfork,4
reduce,local-prefork,4
reduce,cxlfork,4
```

只有 `cxlfork` 需要 template key/generation/checksum。

## 17. runner 会产生什么文件

每个 output directory 中：

| 文件 | 内容 |
| --- | --- |
| `runs.csv` | repeat 的 job elapsed 和退出状态 |
| `warmups.csv` | warmup 记录，不参与最终统计 |
| `tasks.csv` | 每个 map/reduce 的原始 envelope，一行一个任务 |
| `task_summary.csv` | 按 kind/metric 聚合的 count、mean、P50、P95、标准差 |
| `result.json` | 机器可读的端到端结果、配置和正确性状态 |
| `result.env` | 便于 shell 读取的同类 summary |
| `repeat_N.out` | 每轮原始 WordCount 输出 |
| `repeat_N.norm` | 规范化、排序后的输出 |
| `logs/` | master/agent 日志、build/prepare 日志、校验 diff |

`tasks.csv` 中 kind `1` 是 map，kind `2` 是 reduce。

当前 CSV 还包含 template-state checksum、访问 checksum/count、状态页数和 binding
flags。强绑定成功的每一行必须有非零访问证据且 flags 为 15。

## 18. 已完成的测试

### 18.1 构建和 ABI

- CXLfork enabled/disabled 两种 MR 构建通过；
- VM0/VM1 capabilities 完全一致；
- V2 size/version/reserved 正反测试通过；
- CXL-disabled binary 明确拒绝 caps。

### 18.2 template 和 checkpoint

- 4 MiB Mapper/Reducer template publish；
- 跨 VM inspect 和 checksum；
- 非对齐 3 MiB 明确返回错误；
- 同 slot key collision 不静默覆盖；
- 容量、metadata 和失败 slot 可见性边界。

### 18.3 porter 生命周期

- persistent、localfork、local-prefork、cxlfork；
- 1、2、4 worker；
- one-shot PID 和 refill；
- 4 reader 同时存在；
- active release=`EBUSY`；
- stale generation 失败且 reader 回到 0；
- 最终 matched release 成功。

### 18.4 MR 正确性

- WordCount checksum/expected output；
- 多 map、8 reducer 和 4-way concurrency；
- VM0 只接收 map、VM1 只接收 reduce；
- 错误 role 明确失败；
- shuffle connection 数不足明确失败；
- 所有最终性能样本 `verify=all`。

### 18.5 CXLfork 机制证据

- shared leaf PFN/PTE/checksum；
- path mask、shared/fallback pages；
- leaf/data CoW 底层 selftest；
- readonly/MoW/MoA/Hybrid smoke；
- rollback、reader、release 和 dmesg。

### 18.6 应用状态强绑定

- 正常 scale=1 CXLfork WordCount 正确，Reducer 均为 shared path 5、1,024 页；
- 合法 scale=2 checkpoint 使全部输出计数严格变为两倍；
- readonly、MoA、Hybrid 均在强绑定状态下通过，path 分别为 5、17、33；
- 故意破坏 state table 后，kernel restore 仍能完成，但应用 bind 返回 `EILSEQ`；
- Mapper template 被 Reducer 使用时返回 `EILSEQ`；
- stale generation 返回 116，不能借用当前对象；
- 三个失败路径都保留 versioned failure envelope，reader 最终为 0；
- 自动验收脚本：`mr-distributed/scripts/test-state-binding.sh`；
- 原始结果：`/home/xtl/cxlfork/mr-static-results/state-binding-acceptance`。

### 18.7 每阶段公共验收

- 两种 build；
- 成功、边界和失败用例；
- VM0/VM1 dmesg；
- 无残留 `mr_hydra`；
- Git worktree 干净后才提交下一阶段。

完整阶段日志见主仓库：

```text
docs/mr-cxlfork-static-acceptance.md
```

## 19. 既有性能结果（template v1，强绑定前）

本节 30 次数据来自 MR 提交 `debcb1b`，当时 template 只做 header validation。
它仍可作为此前控制路径基线，但不是当前 template v2 的正式性能数据；论文主实验
需要在 `6311b3e` 或更新提交上重新运行完整矩阵。

最终数据使用同一 256,000-byte WordCount 输入、VM0 Mapper localfork、VM1 4 个
Reducer、5 次 warmup、30 次 repeat、`verify=all`。变化的是 Reducer launch mode。

| Reducer 模式 | Mean | P50 | P95 | 标准差 |
| --- | ---: | ---: | ---: | ---: |
| persistent | 361.367 ms | 361.000 ms | 371.000 ms | 5.642 ms |
| localfork | 365.067 ms | 365.000 ms | 378.000 ms | 7.728 ms |
| local-prefork | 365.667 ms | 366.500 ms | 378.000 ms | 7.494 ms |
| cxlfork | 357.167 ms | 356.000 ms | 375.000 ms | 8.238 ms |

120 个 CXLfork Reducer task 的均值：

| 分项 | Mean |
| --- | ---: |
| Reduce callback (`task_ns`) | 12.888 ms |
| Porter outer interval | 13.133 ms |
| `RESUME_V2` ioctl wall time | 44.759 µs |
| Kernel restore total | 12.626 µs |
| Ghost refill | 69.745 µs |

### 19.1 应如何理解

这些结果显示，在当前 4 MiB template 和小型 WordCount 中，kernel restore 已经是
十几微秒，而应用执行、HydraRPC 往返、目标端调度和更大的 job 控制路径明显更长。
这正是 Cohort 想研究的方向。

但是不能据此直接声称“CXLfork 比 persistent 快 4 ms”：

- 四种模式按顺序测试，没有随机交错；
- 样本只有 30 次；
- workload 很小，只有 1 个 map 和 4 个 reduce/轮；
- 91 使用 QEMU 文件模拟共享内存；
- mode 间 mean 差异与系统噪声处于同一数量级。

更可靠的结论是：当前测量链已经能把 kernel restore、porter、task 和端到端路径
分开，适合作为后续 Cohort 控制面实验基线。

## 20. 数据和备份在哪里

### 20.1 远端权威结果

| 路径 | 内容 |
| --- | --- |
| `/home/xtl/cxlfork/mr-static-results/stage6-30-final` | 四种 launch mode 的最终 30 次矩阵 |
| `/home/xtl/cxlfork/mr-static-results/stage7-policies` | readonly/MoW/MoA/Hybrid smoke |
| `/home/xtl/cxlfork/mr-static-results/state-binding-acceptance` | template v2 正常、scale=2、损坏、错误角色和 stale 验收 |
| `/home/xtl/cxlfork/mr-static-results/final-artifacts` | 完整 diff、Git bundle、验收文档和脚本快照 |

`stage6-30-final` 下有四个子目录：

```text
persistent/
localfork/
local-prefork/
cxlfork/
```

### 20.2 本地重要备份

```text
/home/adonis/cxlfork/backups/mr-cxlfork-static-20260716
```

关键 diff、CSV、JSON 和最新状态强绑定结果均应与远端做 SHA-256 比对。重要入口：

- `stage6-30-final/cxlfork/tasks.csv`：CXLfork 逐任务原始数据；
- `stage6-30-final/cxlfork/task_summary.csv`：CXLfork task summary；
- `stage6-30-final/cxlfork/result.json`：端到端 summary；
- `stage7-policies/`：四策略结果；
- `state-binding-acceptance/`：应用状态强绑定验收结果；
- `final-artifacts/mr-distributed-current.diff`：当前 MR 完整源码差异；
- `final-artifacts/cxlfork-repro-current.diff`：当前主仓库差异；
- `final-artifacts/mr-distributed-state-binding.bundle`：当前 MR Git bundle；
- `final-artifacts/cxlfork-repro-current.bundle`：当前主仓库 Git bundle；
- 带 `debcb1b`、`efa6d04` 的旧文件是强绑定前的历史快照，不要当作当前源码。

## 21. 和旧 CXLporter/OpenWhisk 系统的关系

主仓库中还保留一套较早完成的控制面：

```text
OpenWhisk HTTP -> Node.js proxy action -> TCP -> VM1 CXLporter daemon
               -> pre-fork ghost -> RESUME_V2 -> synthetic workload
```

它适合研究 OpenWhisk/HTTP/action bridge 开销；当前 MR 系统适合研究
MapReduce/HydraRPC/worker 生命周期。二者共用 CXLfork kernel 思想，但控制面不同：

| 项目 | OpenWhisk/CXLporter | 静态 MR 系统 |
| --- | --- | --- |
| 上层 workload | proxy action + synthetic C workload | WordCount MapReduce |
| RPC | TCP 文本协议 | HydraRPC shared-memory RPC |
| porter | 旧 `cxlporter` 子模块 | `mr-distributed/src/mr_porter.c` |
| ghost | CXLporter daemon 子进程 | MR agent supervisor 子进程 |
| 是否本轮修改 | 否 | 是 |

不要把旧 OpenWhisk benchmark 数据和 MR 的 `tasks.csv` 直接合并；两者的路径、
schema 和计时边界不同。

## 22. 迁移到 10.0.16.103 真实 DAX

103 已报告存在 `/dev/dax0.0`，64 GiB、2 MiB 对齐、devdax mode、NUMA node 2。
由于该机器当时有其他组员实验，本轮没有连接、清空或修改它。

建议首轮布局：

| 范围 | 用途 |
| --- | --- |
| `[0, 2 GiB)` | Hydra endpoint 0 |
| `[2 GiB, 4 GiB)` | Hydra endpoint 1 |
| `[4 GiB, 8 GiB)` | CXLfork NVDIMM backend |
| `[8 GiB, 64 GiB)` | 保留 |

launcher 已支持 offset 和 overlap check。真实 DAX 必须：

```bash
export CXL_FILE=/dev/dax0.0
export CXL_BACKEND_OFFSET=4G
export CXL_BACKEND_SIZE=4G
export HYDRA_SHM_FILE=/dev/dax0.0
export HYDRA_BACKEND_OFFSET=0
export HYDRA_ENDPOINT_SIZE=2G
export HYDRA_ENDPOINT1_OFFSET=2G
export BACKEND_RESET=none

scripts/start-cxlfork-vms.sh check
```

`BACKEND_RESET=none` 是安全要求：launcher 不得删除、truncate 或清零 DAX 字符设备。
只有确认独占设备、停止所有相关 VM 并和其他使用者协调后，才可由管理员单独执行
站点认可的清理工具。

迁移详细流程见：

```text
docs/mr-cxlfork-103-migration-profile.md
```

## 23. 常见故障

### 23.1 VM 启动脚本说端口占用

这通常表示 VM 已经运行，不要删除 PID 文件后强行再启。检查：

```bash
ss -lntp | grep -E ':(2200|2201|2202)\b'
ps -ef | grep qemu-system | grep -v grep
```

### 23.2 guest 中没有 `/dev/cxlfork`

检查：

- 是否使用 `kernel/build-6.6.32/arch/x86/boot/bzImage`；
- `CONFIG_CXLFORK=y`；
- cmdline 是否有正确 `cxlfork.cxl_phys/cxl_size`；
- `logs/vm*-console.log` 和 dmesg。

### 23.3 template publisher 返回 collision/EEXIST

说明候选 slot 已有 READY 对象。先执行 `cxlfork-inspect KEY`，确认 generation 和
reader。不要让新 key 静默覆盖旧对象。

### 23.4 restore 返回 stale generation

agent 使用的 generation 不是当前 slot generation。重新发布并把同一行输出中的
generation/checksum 一起传给 runner。不能只改 key 或只改 checksum。

### 23.5 release 返回 `EBUSY`

如果任务正在执行，这是正确保护。等待 ghost unmap/退出后再次 inspect。若所有
worker 已退出仍长期非零，才按 reader 泄漏排查。

### 23.6 Reducer agent 启动时报 connection 不足

固定并发 shared-pair 模式必须满足：

```text
--shuffle-connections >= --workers
```

master 的 `--connections` 使用相同数值。

### 23.7 master 很快失败，没有 output

依次检查：

- agent 0 是否 `--role=map`；
- agent 1 是否 `--role=reduce`；
- master `--agent` 顺序是否 endpoint 0 在前、endpoint 1 在后；
- `--workers-per-agent` 是否等于 agent 的 `--workers`；
- payload/size/connections 是否两端一致；
- agent/master 原始日志中的 `agent task failed` 或 Hydra 错误。

### 23.8 dmesg 出现异常

立即停止叠加新实验，保存日志：

```bash
for port in 2200 2201; do
  ssh -p "$port" ubuntu@localhost \
    "sudo dmesg | grep -Ei 'cxlfork|BUG:|WARNING:|Oops:|bad pagetable|general protection|kernel panic' | tail -200"
done
```

## 24. 每次实验的推荐检查清单

实验前：

- [ ] 当前分支和提交已记录；
- [ ] 主/MR/kernel worktree 干净；
- [ ] VM、端口、backend 布局正确；
- [ ] 两台 VM caps 一致；
- [ ] 输入、期望输出、template bytes 和 policy 已记录；
- [ ] generation/checksum 来自本次 publisher。

实验后：

- [ ] 所有 repeat `status=ok`、`correctness=ok`；
- [ ] `verify=all` 没有 diff；
- [ ] CXLfork rows 的 path/page counters 符合预期；
- [ ] inspect reader 回到 0；
- [ ] generation-matched release 成功；
- [ ] VM0/VM1 dmesg 干净；
- [ ] 没有残留 `mr_hydra`；
- [ ] 原始 CSV、summary、日志、环境和提交已备份；
- [ ] 小样本不报告 P99。

## 25. 可以和不可以做出的结论

可以用当前系统证明：

- 受限匿名 template 被真实 checkpoint 到共享 backend；
- VM1 按 key+generation 执行真实 `RESUME_V2`；
- 支持范围内 CPU 使用共享 CXL PTE leaf；
- 4 个 ghost 可以同时持有 4 个 reader；
- generation、reader、release 和 collision 保护有效；
- VM0 Mapper/VM1 Reducer 的 HydraRPC 控制和 shuffle 路径完整；
- localfork、prefork、CXLfork 的 worker 生命周期可按单次任务拆分；
- kernel restore 与更大控制路径可以分别测量。
- WordCount callback 必须消费恢复出的 worker state；改变合法 state 会受控改变输出，
  损坏、错误角色或 stale 对象不会继续执行任务。

不能声称：

- 已透明恢复完整 Mapper/Reducer 进程；
- 当前 template 就是函数代码、栈和寄存器的完整 checkpoint；
- 已实现真实共享 Maple Tree/VMA leaf；
- 当前 MR ghost 等价于论文 Docker ghost container；
- 已支持任意进程、多线程、socket/namespace/global state；
- 91 文件后端等价于真实 CXL 性能；
- 30 次样本给出了可信 P99；
- 目前几毫秒的 mode mean 差异具有统计显著性。

## 26. 建议阅读顺序

1. 本文：理解当前静态 MR+CXLfork 系统全貌。
2. `docs/mr-cxlfork-static-acceptance.md`：查看阶段验收和硬证据。
3. `mr-distributed/README.md`：查看 MR CLI、调度和 wire format。
4. `docs/cxlfork-reproduction-system-guide-zh.md`：了解底层 CXLfork 和旧
   OpenWhisk/CXLporter 全系统。
5. `docs/cxlfork-phase-acceptance-log.md`：审计内核各阶段测试。
6. `docs/cxlfork-paper-alignment-status.md`：查看论文真实性矩阵。
7. `docs/mr-cxlfork-103-migration-profile.md`：迁移真实 DAX 前阅读。

## 27. 最后总结

当前系统已经形成一条完整、受限但可信的研究链路：

```text
WordCount task
  -> static master scheduling
  -> HydraRPC cross-VM request/shuffle
  -> MR porter and one-shot ghost
  -> CXLfork RESUME_V2 and shared PTE leaf
  -> Reduce execution
  -> per-call measurement envelope
  -> verified output and lifecycle cleanup
```

它最有价值的地方不是“功能最多”，而是每一层都有清楚的真实性边界、成功与失败
语义、逐调用测量和原始数据。后续 Cohort 工作可以在这条可信数据面基线上继续研究
跨 OS 请求传递、唤醒、调度和执行激活，而不必再把所有时间都归因于内核 restore。
