# CXLfork + HydraRPC + MapReduce 系统架构说明：Data Plane 与 Control Plane

> - 文档状态：当前实现说明，不是未来设计草案
> - 适用环境：`10.0.16.91` 上的双 VM 文件模拟环境
> - 当前 MR 提交：`518943bd1832eb8ca67e46ba2032a8ee2a910fcd`
> - 当前 kernel 提交：`15ae46586aaff49c5f6b72271da8b5833899132a`

## 1. 这套系统要解决什么问题

这套系统由三个主要部分组成：

- **MapReduce**：提供真实的 WordCount 工作流，产生 Mapper、Reducer 和 shuffle；
- **HydraRPC**：在两个 VM 之间通过共享内存传递任务、响应和 shuffle 数据；
- **CXLfork**：把一个受限的 worker 内存模板 checkpoint 到共享内存，让目标 VM
  中的 ghost 进程快速恢复并共享这些页面。

我们的目标不是实现一个支持任意 Linux 进程的生产级 remote fork。我们想回答的科研
问题是：

> 当 CXLfork 已经减少了页面复制和页表恢复成本后，跨 OS 请求传递、目标端调度、
> ghost 唤醒、进程准备、restore 调用和应用激活还剩多少开销？

所以，这套系统首先是一个**可观测的实验平台**。它既要让数据面机制真实发生，也要把
控制面每一段时间尽量拆开测量。

## 2. 先记住一句话

可以把整个系统想象成“仓库、传送带和调度员”：

- **CXLfork 是共享仓库**：长期保存 worker 模板、数据页和共享 PTE leaf；
- **HydraRPC 是共享传送带**：临时运输任务、响应和 shuffle 数据；
- **master、agent 和 porter 是调度员**：决定任务去哪里、唤醒哪个 worker，以及何时
  restore 和回收资源；
- **Mapper/Reducer 是工人**：真正执行 WordCount。

其中，“仓库和传送带上的数据如何移动”属于 data plane；“谁决定何时移动、谁来执行、
如何创建和回收 worker”属于 control plane。

## 3. 什么是 Data Plane，什么是 Control Plane

### 3.1 Data Plane

Data plane（数据面）负责真正承载和访问数据，例如：

- WordCount 输入文本；
- Mapper 产生的 KV partition；
- HydraRPC request/response payload；
- shuffle chunk；
- CXLfork checkpoint 的匿名数据页；
- CPU page walker 读取的共享 PTE leaf；
- MoW/MoA 产生的 CXL-to-local 页面复制。

简单说，data plane 回答：

> 数据在哪里？通过什么路径传输？访问时是否需要复制？

### 3.2 Control Plane

Control plane（控制面）负责组织和驱动数据面，例如：

- master 如何切分任务和选择 VM；
- agent 如何接收请求和检查角色；
- porter 如何选择、创建、唤醒和回收 worker；
- ghost 何时调用 `RESUME_V2`；
- CXLfork 如何用 key、generation、reader 管理 slot；
- 任务失败时如何回滚和返回错误；
- 何时收集统计、释放 template 和结束作业。

简单说，control plane 回答：

> 谁在什么时候让哪个执行实体做什么？

### 3.3 两者并不是完全物理分离

同一个 RPC 中可能同时包含控制和数据。例如一个 Map request 中：

- task ID、目标 worker ID 是控制信息；
- 输入文本切片是业务数据。

`RESUME_V2` ioctl 也是一个控制操作，但它触发了 data plane 的 VMA 创建、共享 leaf
attach 和页面访问。因此本文按照“主要职责”分类，而不是认为两者完全互不相干。

## 4. 物理部署和共享内存布局

### 4.1 两台虚拟机

| 实例 | 当前主要角色 | SSH 端口 |
| --- | --- | ---: |
| VM0 | master、Mapper agent、Mapper worker、template publisher | `2200` |
| VM1 | Reducer agent、Reducer ghost/worker | `2201` |

两个 VM 都运行同一个 CXLfork kernel。典型实验采用固定角色布局：VM0 只执行 Map，
VM1 只执行 Reduce，不做动态扩容和任务迁移。

### 4.2 两块逻辑共享内存

`10.0.16.91` 没有使用真实 CXL 设备，而是用两个普通共享文件作为 QEMU backend：

| 文件 | 大小/范围 | Guest 暴露方式 | 保存内容 |
| --- | --- | --- | --- |
| `/dev/shm/cxl_mem` | 约 4 GiB | shared NVDIMM | CXLfork slot、页面和页表 leaf |
| `/dev/shm/cxlmem` offset 0 | 2 GiB | ivshmem BAR | Hydra endpoint 0 |
| `/dev/shm/cxlmem` offset 2 GiB | 2 GiB | ivshmem BAR | Hydra endpoint 1 |

这两个名字很相似，但必须区分：

```text
/dev/shm/cxl_mem   -> CXLfork
/dev/shm/cxlmem    -> HydraRPC
```

当前使用两个文件把协议物理隔离。将来迁移到真实 `/dev/dax0.0` 时，可以使用同一个
DAX 设备，但必须为 CXLfork 和 HydraRPC 分配严格不重叠的 offset 范围。

### 4.3 整体架构图

```text
                         Host 10.0.16.91

       /dev/shm/cxl_mem                         /dev/shm/cxlmem
       CXLfork shared NVDIMM                    HydraRPC ivshmem
       slots + pages + PTE leaves               endpoint 0 | endpoint 1
                  |                                  |              |
          +-------+------------------+---------------+--------------+
          |                          |                              |
     +----v--------------------------v---+        +-----------------v----+
     | VM0                                |        | VM1                  |
     |                                    |        |                      |
     | master                             |        | Reducer agent        |
     | Mapper agent                       |        | porter supervisor    |
     | Mapper workers                     |        | preforked ghosts     |
     | template publisher                 |        | Reducer workers      |
     +------------------+-----------------+        +----------+-----------+
                        |                                     |
                        +------ HydraRPC shuffle --------------+
```

## 5. 系统中的主要软件组件

| 组件 | 所在位置 | 作用 |
| --- | --- | --- |
| `master` | VM0 用户态 | 切分作业、静态调度、收集结果 |
| `agent` | VM0/VM1 用户态 | 节点级 RPC 服务，接收 task 和 shuffle 请求 |
| `mr_porter` | 每个 agent 内部 | 管理 worker/ghost 生命周期和本地任务交接 |
| Mapper/Reducer callback | worker 进程 | 执行 WordCount 业务逻辑 |
| HydraRPC | 用户态库 | 共享内存 request/response transport |
| `/dev/cxlfork` | VM 内核驱动 | prepare、resume、inspect、release 和统计 |
| core-MM/x86 页表改造 | VM 内核 | shared PTE leaf attach、leaf/data CoW |
| QEMU shared backend | Host | 让两个 VM 看到同一份底层存储 |

需要特别注意：worker 不是一个独立对外 RPC 服务。对外长期存在的是 agent endpoint；
agent 再通过 porter 把任务交给本机 worker。

## 6. Data Plane：HydraRPC 中有哪些数据

### 6.1 HydraRPC 共享区域的长期结构

每个 Hydra endpoint 中长期存在：

- superblock：版本、节点 ID、映射大小和各区域 offset；
- connection table；
- request queue 和 response queue；
- response dispatch queue；
- allocator pool、heap 和 segment 表；
- remote-free queue；
- 队列 `head/tail`、锁、generation 和 allocator 统计。

这些结构相当于共享传送带的轨道、编号和空闲空间管理器。

### 6.2 HydraRPC 中临时存在的消息

每个消息包含 `hydra_msg` 元数据，例如：

- request/connection/sequence ID；
- operation 和 status；
- payload offset、长度和 checksum；
- allocator owner、segment 和 generation；
- 请求发布、服务端接收和响应发布等时间戳。

真实 payload 位于共享 allocator 分配的 block 中，queue entry 主要发布这个 block 的
offset。

### 6.3 Map 数据

master 发给 Mapper agent 的请求大致是：

```text
mr_wire_header
control_map_task
input text slice
```

其中包括 job ID、map task ID、reducer 数量、目标 worker 以及真正的输入文本切片。

Mapper 在本地完成 tokenize、partition、sort 和 combiner。完整 partition 被写入 VM0
本地 KV 文件，而不是长期塞在 Hydra 共享内存中。

### 6.4 Intermediate metadata

Mapper 向 master 返回 `IntermediateLocation[]`，其中包括：

- job、map task、reducer、node 和 worker ID；
- 本地 partition 文件路径；
- 文件 offset、字节数和 record 数量；
- 远程 reducer 应使用的 Hydra endpoint。

因此 master 收到的是“数据在哪里”的描述，而不是所有 intermediate KV 数据。

### 6.5 Reduce 和 shuffle 数据

master 发给 Reducer 的请求包含：

```text
mr_wire_header
control_reduce_task
IntermediateLocation[]
```

Reducer 遇到远端 partition 时，通过 Mapper agent 发起：

```text
shuffle_fetch_request
```

Mapper agent 返回：

```text
ShuffleChunkHeader + KV bytes
```

Reducer 收到 chunk 后立即写入 VM1 本地 spill 文件。Hydra payload 只在一次
request/response 生命周期内有效，处理完成后通过 `hydra_release_message()` 释放。

### 6.6 HydraRPC 不保存的内容

HydraRPC 不负责保存：

- CXLfork template；
- 完整 worker 地址空间；
- worker 页表和寄存器；
- 所有 Mapper partition 的长期副本；
- 可供未来任务重复使用的进程 checkpoint。

## 7. Data Plane：CXLfork 中有哪些数据

### 7.1 Slot

CXLfork 共享窗口前 2 MiB 是保留区，后面提供 7 个 nominal 512 MiB slot。每个
checkpoint 对象占用一个 slot。

slot descriptor 保存：

- key、slot 和 generation；
- `FREE/WRITING/READY/RELEASING` 状态；
- reader count；
- region、PTE 和页面数量；
- page/leaf checksum；
- 各个 table/image 的 offset 和大小；
- 4 KiB extent bitmap；
- prepare/restore 的统计和页面计数。

### 7.2 当前 MR template

publisher 在固定地址创建一个私有匿名 arena。当前验收通常使用：

```text
base  = 0x500000000000
bytes = 4 MiB
pages = 1024
```

arena 中包含：

```text
base + 0       template v2 header
base + 128     MR_WorkerStateV1（856 字节，位于一个页面中）
其余区域       由固定 seed 生成的可重复 pattern
```

header 记录 role、base、bytes、seed、state offset/size/checksum、payload checksum、
config fingerprint 和 required binding flags。

`MR_WorkerStateV1` 保存 WordCount 真正消费的初始化状态：

- 256 项 word-character 分类表；
- 256 项小写转换表；
- 256 项数字解析表；
- partition hash 初值和乘数；
- reducer radix 和 `value_scale`；
- role、version、flags、checksum 和 reserved 字段。

### 7.3 Checkpoint 数据页

`PREPARE_V2` 遍历指定匿名 VMA，把每个 4 KiB 页面复制到 CXLfork slot，并记录：

- 源虚拟地址；
- CXL 数据页 offset；
- 原始 PTE 值；
- 指向 CXL 页面后的 PTE 值；
- checkpointed A/D bit；
- 页面 checksum。

当前 MR 的 4 MiB template 因而形成 1,024 个共享数据页。

### 7.4 页表和 VMA image

slot 还保存：

- region table：VMA 地址、长度、权限和页范围；
- 自定义 VMA tree image；
- 扁平 leaf PTE image；
- PTE page 描述符；
- 真实的 4 KiB PTE leaf 页面；
- 页表 tree image 和 checksum。

满足对齐和完整 leaf 覆盖条件时，目标 mm 的本地 PMD 直接指向共享窗口中的 PTE
leaf，CPU page walker 会真实读取该 leaf。目标端的 PGD/P4D/PUD/PMD 和 Linux
VMA/Maple Tree 仍然在本地创建。

### 7.5 进程状态摘要

slot 也记录 task、mm、thread、global、普通 fd 和 private-rebase manifest 摘要。
这些字段可用于验证、受限子集恢复和测量，但当前 MR fast path 不依靠它们透明恢复
一个运行中的源进程。

当前 `FULL_PRIVATE_STATE` 明确不支持。目标 ghost 不会安装 publisher 的完整 IP/SP
并从其原执行位置继续；它会在自己的调用栈上从 `RESUME_V2` 返回，然后调用已经存在
于 `mr_hydra` 二进制中的 callback。

## 8. Data Plane：四种页面策略

| 策略 | 第一次读 | 写入 | 主要目的 |
| --- | --- | --- | --- |
| Readonly | 读共享 CXL 页 | 不属于允许语义 | 最直接的共享读 |
| MoW | 读共享 CXL 页 | leaf materialize 后复制本地数据页 | 写时迁移 |
| MoA | 首次访问时复制到本地 | 后续访问本地页 | 访问时迁移 |
| Hybrid | 根据 checkpointed A/D 信息选择 | 可结合本地复制和 dirty prefetch | 分层策略实验 |

MoW 写入时需要两层隔离：

1. OS 要修改共享 PTE leaf 前，先把整张 4 KiB leaf materialize 到当前 mm 的本地页表；
2. Linux 写保护路径再为写入者创建本地匿名数据页。

因此 sibling 仍指向原共享 leaf，checkpoint 数据也不应被污染。

当前 WordCount callback 只读 template state，所以 MR 业务本身主要证明 shared read 和
状态绑定；数据页写 CoW、leaf CoW 的硬证据主要来自 kernel selftest。

## 9. Control Plane：master 和静态调度

当前实验使用：

```text
--schedule=role-static
```

master 的职责是：

1. 读取输入并按 `map-chunk` 切分；
2. 把所有 Map task 发给 agent 0/VM0；
3. 收集所有 `IntermediateLocation`；
4. 为每个 reducer 构造 Reduce task；
5. 把所有 Reduce task 发给 agent 1/VM1；
6. 收集结果、合并输出并发送 shutdown。

`--workers-per-agent=N` 决定固定 worker 数量。当前没有动态 scaling、worker 迁移或
复杂负载均衡，这能让实验路径更稳定、更容易拆分。

## 10. Control Plane：agent

每个 agent 是长期运行的节点级服务，负责：

- 初始化或连接自己的 Hydra endpoint；
- 接收 master 的 map/reduce/shutdown request；
- 接收远程 reducer 的 shuffle-fetch request；
- 检查自身 `--role=map|reduce`；
- 选择 porter worker slot；
- 把任务提交给 porter；
- 收集 worker 结果；
- 由 agent 主循环统一发布 Hydra response。

Hydra transport 使用 busy polling。固定并发 reducer 要求：

```text
shuffle-connections >= workers
```

否则 agent 在启动阶段明确失败，避免运行到一半死锁。

## 11. Control Plane：porter 和 worker 生命周期

`src/mr_porter.c` 是为本实验重新实现的轻量 porter。它不复用旧 CXLporter。

porter 内部有：

- 一个 supervisor 进程；
- 一个 `SOCK_SEQPACKET` control channel；
- 每个 worker 一个本地 `MAP_SHARED|MAP_ANONYMOUS` slot；
- task payload 区和 response 区；
- worker/ghost PID 和 busy 状态。

这里的 porter slot 只在同一个 VM 的相关进程间共享，不是 HydraRPC ivshmem，也不是
CXLfork NVDIMM。

### 11.1 四种已实现的 worker 模式

| 模式 | 创建方式 | 请求关键路径特点 |
| --- | --- | --- |
| `persistent` | agent 启动时 fork，循环执行 | 不重复创建进程，warm baseline |
| `localfork` | 每次收到任务后 fork | 包含普通进程创建成本 |
| `local-prefork` | 请求前 fork 等待，一次任务后退出 | 只测 ghost 唤醒，不做 CXL restore |
| `cxlfork` | 请求前 fork ghost，醒后 `RESUME_V2` | 论文式预置 ghost + CXL restore |

当前还没有独立的 `cxlfork-on-demand` 模式。也就是说，CXLfork 模式的 ghost 创建通常
不在本次请求的关键路径中；这也是未来若要研究“进程创建是否应进入关键路径”时值得
增加的对照模式。

### 11.2 CXLfork ghost 是真实进程

ghost 由目标 OS 的普通 `fork()` 创建，所以它拥有真实的 `task_struct`、`mm_struct`、
PID、cred、files 和 signal 等内核对象。

`/dev/cxlfork` 不负责创建这个进程。它负责向已经存在的目标进程恢复受限地址空间：

```text
目标 OS fork ghost
  -> ghost 等待
  -> 收到任务并被唤醒
  -> RESUME_V2
  -> 映射 template
  -> callback 执行
```

所以当前实现是“本地创建真实进程骨架 + CXLfork 恢复共享内存模板”，不是“从 CXL
直接反序列化出一个任意完整 Linux 进程”。

## 12. Control Plane：CXLfork slot 生命周期

slot 状态机是：

```text
FREE -> WRITING -> READY -> RELEASING -> FREE
```

关键控制规则：

- `key` 用来寻找 checkpoint 对象；
- `generation` 防止旧请求读到后来覆盖的新对象；
- producer 写完页面、metadata 和 checksum 后才能发布 `READY`；
- 成功 restore 会增加 reader；
- 只要恢复出的 VMA/context 仍存在或可能 fault，reader 就不能提前释放；
- reader 非零时 `RELEASE_V2` 返回 `EBUSY`；
- slot 发布采用跨 VM 原子 CAS 和 release/acquire 语义；
- 失败 restore 必须 rollback，不留下部分 VMA 或 reader 泄漏。

主要 V2 ioctl 是：

| ioctl | 控制作用 |
| --- | --- |
| `QUERY_CAPS_V2` | 查询真实支持能力 |
| `PREPARE_V2` | 创建 checkpoint |
| `RESUME_V2` | 按 key+generation 恢复 |
| `GET_CALL_STATS_V2` | 获取单次 restore/fault 统计 |
| `INSPECT_V2` | 查看 slot、reader、checksum 和 PFN 证据 |
| `RELEASE_V2` | 无 reader 时释放对象 |

## 13. 一次完整 WordCount 作业

下面把 data plane 和 control plane 串在一起。

### 13.1 启动阶段

1. Host 准备两个共享 backend 文件并启动 VM0/VM1。
2. 两个 VM 加载相同 CXLfork kernel，看到 `/dev/cxlfork` 和 Hydra ivshmem BAR。
3. template publisher 在 VM0 创建 4 MiB匿名 arena。
4. publisher 填写 template header、`MR_WorkerStateV1` 和 pattern。
5. `PREPARE_V2` 把 arena 页面、PTE leaf 和 metadata 写入 CXLfork slot。
6. publisher 得到 key、generation 和 page checksum。
7. VM0/VM1 agent 启动 Hydra endpoint 和 porter worker 池。
8. CXLfork Reducer ghost 在 VM1 中预先 fork 并等待。

### 13.2 Map 阶段

1. master 把输入切成多个 slice。
2. master 通过 Hydra endpoint 0 发送 Map request 和输入文本。
3. VM0 agent 接收请求，通过 porter 唤醒或创建 Mapper worker。
4. Mapper 执行 WordCount map、partition、sort 和 combiner。
5. 每个 reducer partition 写入 VM0 本地 KV 文件。
6. Mapper 返回 `IntermediateLocation[]` 和任务测量结果。
7. Hydra payload 被消费并回收。

### 13.3 Reduce 激活阶段

1. master 汇总 locations，通过 endpoint 1 发送 Reduce request。
2. VM1 agent 检查 role 并把请求放入 porter 本地 slot。
3. porter supervisor 唤醒一个预创建 ghost。
4. ghost 打开 `/dev/cxlfork`，调用 `RESUME_V2(key, generation, policy)`。
5. kernel 查找 slot、验证 generation/checksum 并增加 reader。
6. kernel 创建本地 VMA 和上层页表，满足条件时 attach 共享 PTE leaf。
7. ioctl 返回到 ghost 原来的调用点。
8. ghost 校验 template header 和 `MR_WorkerStateV1`。
9. porter 要求 validated、role-match、app-consumed、required 四个 binding flag 全部成立。
10. Reducer callback 开始执行。

### 13.4 Shuffle 和输出阶段

1. Reducer 根据 `IntermediateLocation` 判断 partition 是否在本地。
2. 远端 partition 通过 Hydra endpoint 0 分块 fetch。
3. 每个 chunk 被写入 VM1 本地 spill 文件，Hydra block 随后释放。
4. Reducer parse、sort、调用 `get_next` 并求和。
5. 最终 WordCount 输出和 `mr_task_result_v2` 返回 master。

### 13.5 清理阶段

1. ghost 调用 `GET_CALL_STATS_V2`。
2. ghost `munmap` 恢复区域并关闭 restore context/fd。
3. CXLfork reader 降回 0。
4. ghost 退出，supervisor `waitpid` 并补充新的预创建 ghost。
5. 所有任务完成后，master 发送 shutdown。
6. 使用正确 generation 调用 `RELEASE_V2`，slot 回到 `FREE`。

## 14. 应用状态强绑定是什么意思

WordCount 函数机器码本来就编译在目标 `mr_hydra` 二进制中，但 callback 的关键初始化
状态来自 CXLfork template。

Mapper、默认 partitioner 和 Reducer 都必须调用 `MR_GetWorkerState()`，实际使用字符
分类表、大小写表、hash 参数和数值规则。合法任务要求：

```text
template_binding_flags = 15
```

这代表：

- template 已验证；
- role 匹配；
- 应用确实消费了状态；
- 该 binding 是强制条件。

验收中将 `value_scale` 从 1 改为 2 后，相同输入的 WordCount 输出全部精确翻倍；损坏
state、错误 role 和 stale generation 都会失败。这证明 restore 出来的状态进入了真实
业务语义，而不只是执行一个形式上的 ioctl。

但它仍不是从源进程任意 IP/SP 继续执行：ghost 从自己的 `RESUME_V2` 调用点返回，
随后调用 callback。

## 15. 如何理解当前系统测到的开销

### 15.1 End-to-end

从 master 发出请求到收到响应，包含：

```text
Hydra request publish
+ 跨 VM 等待
+ agent dispatch
+ porter/ghost 调度
+ CXLfork restore
+ template bind
+ callback
+ shuffle
+ response publish
```

它适合回答“用户实际等待多久”，但不能直接代表 kernel restore。

### 15.2 Porter/worker breakdown

当前结果可区分：

- dispatch；
- fork；
- wakeup；
- restore ioctl；
- template validation；
- task callback；
- reap；
- refill；
- porter total。

### 15.3 Kernel restore breakdown

内核按单次 restore 记录：

- slot lookup、validation 和 lifecycle；
- VMA 创建；
- 上层页表分配；
- shared leaf attach；
- fallback PTE reconstruction；
- dirty prefault；
- global restore；
- rollback；
- fault dispatch；
- leaf materialization；
- data CoW；
- CXL-to-local copy。

### 15.4 HydraRPC breakdown

HydraRPC 记录 queue reserve、allocator、header/payload copy、checksum、visibility、
publish、服务端接收和 response placement 等时间。

只有把这些层次分开，才能判断瓶颈到底在 CXL 数据面、kernel restore，还是用户态和
跨 OS 控制路径。

## 16. 当前系统真实实现了什么

- 双 VM 上真实共享的 backend；
- 共享内存 HydraRPC request/response 和 shuffle；
- 真实目标子进程和固定 worker 生命周期；
- 受限单线程私有匿名 VMA checkpoint；
- key/generation/reader slot 协议；
- CPU page walker 使用的共享 PTE leaf；
- leaf materialization 和数据页 CoW；
- Readonly、MoW、MoA、Hybrid；
- 应用状态与 WordCount callback 强绑定；
- 失败 rollback 和按单次调用统计；
- 静态 VM0 Mapper、VM1 Reducer 工作流。

## 17. 当前系统没有实现什么

- 任意多线程进程的透明 checkpoint；
- 从任意源 IP/SP 无缝继续；
- 完整 `task_struct/mm_struct` 对象图 rebase；
- 真实跨 OS Maple Tree leaf attach；
- socket、pipe、epoll、timerfd 的完整 global-state restore；
- 完整 namespace 和容器迁移；
- 动态 scaling、动态调度和生产级故障恢复；
- 真实 CXL fabric latency、带宽和 NUMA 性能模拟。

因此，正确的系统名称是：

> 基于 CXLfork 数据面、HydraRPC 共享内存通信和静态 MapReduce 生命周期的可观测
> remote worker 激活原型。

不应称为：

> 能透明 remote-fork 任意运行中 Linux 进程的生产系统。

## 18. 从代码入手学习

### 18.1 仓库

| 内容 | 远端路径 | 分支/提交 |
| --- | --- | --- |
| 主仓库和文档 | `/home/xtl/cxlfork/cxlfork-repro` | `cohort-mr-cxlfork-static` |
| MapReduce 集成 | `/home/xtl/cxlfork/mr-distributed` | `518943b` |
| CXLfork kernel | `/home/xtl/cxlfork/cxlfork-repro/kernel/linux-6.6.32` | `15ae46586` |
| HydraRPC | `/home/xtl/HydraRPC` | `eb185de1` 快照 |

### 18.2 推荐阅读顺序

1. `mr-distributed/src/mr_wire.h`：先看任务和结果的 wire format；
2. `mr-distributed/src/mapreduce.c`：看 master、agent、Map、Reduce 和 shuffle；
3. `mr-distributed/src/mr_porter.c`：看四种 worker 生命周期；
4. `mr-distributed/src/mr_cxlfork.c`：看 template、prepare、resume 和状态 binding；
5. `HydraRPC/src/hydra_internal.h`：看共享队列和 allocator 布局；
6. `HydraRPC/src/hydra.c`：看 message 分配、发布、接收和释放；
7. `kernel/drivers/cxlfork/cxlfork.h`：看 CXL slot 内部格式；
8. `kernel/drivers/cxlfork/cxlfork_main.c`：看 checkpoint/restore；
9. `kernel/mm/memory.c`：看 shared leaf materialization 和 CoW。

## 19. 测试和结果在哪里

| 内容 | 路径 | 说明 |
| --- | --- | --- |
| 系统完整操作手册 | `docs/mr-cxlfork-hydrarpc-system-guide-zh.md` | 搭建、启动和手工操作 |
| 最终验收记录 | `docs/mr-cxlfork-static-acceptance.md` | 各阶段证据 |
| 状态强绑定脚本 | `mr-distributed/scripts/test-state-binding.sh` | 正常和失败测试 |
| 状态强绑定结果 | `/home/xtl/cxlfork/mr-static-results/state-binding-acceptance` | template v2 权威结果 |
| 历史 30 次矩阵 | `/home/xtl/cxlfork/mr-static-results/stage6-30-final` | 强绑定前控制路径基线 |
| 最终 diff/bundle | `/home/xtl/cxlfork/mr-static-results/final-artifacts` | 可离线审计源码 |
| 本地备份 | `/home/adonis/cxlfork/backups/mr-cxlfork-static-20260716` | 跳板机重要备份 |

注意：历史 30 次矩阵来自 template v1、应用状态强绑定之前。它可以帮助理解控制路径，
但正式论文性能数据应基于当前 template v2 重新运行。

## 20. 小白常见问题

### 20.1 HydraRPC 和 CXLfork 是不是在做同一件事？

不是。HydraRPC 传递每次任务的动态输入和输出；CXLfork 保存多个任务可以复用的 worker
内存模板。

### 20.2 CXLfork 是否把 WordCount 输入放在 template 中？

没有。输入文本、Reduce descriptor 和 shuffle chunk 仍通过 HydraRPC 传递。template
保存的是 worker 初始化状态和匿名内存页面。

### 20.3 CXLfork ghost 是线程还是进程？

是目标 VM 中通过普通 `fork()` 创建的真实子进程。porter supervisor 负责管理它。

### 20.4 为什么叫 remote fork，却还需要本地 fork ghost？

目标 OS 必须拥有本地 `task_struct`、PID、调度实体和资源引用。ghost 先提供这个本地
骨架，CXLfork 再避免重新复制全部数据页和逐页重建页表。

### 20.5 当前能否从源 Reducer 运行到一半的位置继续？

不能。当前从协作式 callback 边界激活，而不是安装任意源 IP/SP。

### 20.6 两个 VM 会不会同时修改同一 checkpoint？

正常情况下不会。shared template 被视为不可变对象；MoW 写入者先获得本地 leaf 和
本地数据页。slot reader 非零时也不能 release 或覆盖。

### 20.7 为什么还要比较 localfork、prefork 和 persistent？

这些基线分别帮助拆出进程创建、ghost 唤醒和 restore 的成本。如果只测一个 CXLfork
总时间，就无法知道收益或瓶颈来自哪里。

## 21. 最后的心智模型

第一次接触这套系统时，只需要记住下面的流程：

```text
master 决定任务去哪里                         <- control plane
  -> HydraRPC 把任务送到目标 VM                <- data plane + transport control
  -> agent 选择 porter worker                  <- control plane
  -> porter 唤醒真实 ghost 进程                 <- control plane
  -> ghost 调用 CXLfork RESUME_V2              <- control operation
  -> kernel attach 共享 PTE leaf 和数据页       <- data plane
  -> callback 消费恢复出的 worker state         <- application/data plane
  -> HydraRPC 传输 shuffle 和结果               <- data plane
  -> porter/agent 回收 worker 和 slot reader     <- control plane
```

CXLfork 让“数据和页表如何恢复”变快；HydraRPC 让“跨 VM 数据如何到达”走共享内存；
master、agent 和 porter 则构成了我们真正想研究和优化的跨 OS 控制路径。
