# CXLfork 主线复现环境与测试说明

本文是当前服务器工作区的主入口说明文档，目标是用一份清晰、可执行的文档说明当前已经搭建好的 CXLfork 主线环境、启动方式、测试脚本和结果含义。

当前阶段只关注这条主线：

```text
CXLfork kernel prototype
        +
CXLporter serverless harness
        +
OpenWhisk standalone baseline
```

不讨论、不要求运行 CRIU、Mitosis、Mitosis+CXL 等其他历史路径。

## 1. 当前目标

当前复现的目标不是完整生产级 serverless 平台，而是把论文中 CXLfork/CXLporter 的关键数据路径跑通并可测量：

1. VM0 作为 checkpoint 节点，把函数进程的内存状态和部分 OS metadata 写入共享 CXL window。
2. VM1 作为 remote invoke 节点，通过 `/dev/cxlfork` 从共享 CXL window 恢复状态并执行 workload。
3. localfork VM 作为普通单机 `fork()` baseline。
4. OpenWhisk standalone 作为完整 serverless 平台 baseline，用来观察传统平台控制面和容器 runtime 的端到端开销。

需要明确：当前 CXLporter 是轻量 serverless harness，不是已经接入 OpenWhisk invoker 的生产 runtime。扩容/调用决策由 benchmark 脚本显式驱动。

## 2. 服务器与路径

目标机器：

```text
xtl@10.0.16.91
```

主工作目录：

```text
/home/xtl/cxlfork/cxlfork-repro
```

关键路径：

```text
/home/xtl/cxlfork/cxlfork-repro/kernel/linux-6.6.32
/home/xtl/cxlfork/cxlfork-repro/kernel/build-6.6.32
/home/xtl/cxlfork/cxlfork-repro/kernel/build-6.6.32/arch/x86/boot/bzImage
/home/xtl/cxlfork/cxlfork-repro/cxlporter
/home/xtl/cxlfork/cxlfork-repro/results
```

当前主线分支：

```text
main repo:  cxlfork-only-mainline
kernel:     cxlfork-only
cxlporter:  cxlfork-mainline
```

## 3. 组件职责

### 3.1 CXLfork kernel

位置：

```text
kernel/linux-6.6.32/drivers/cxlfork/
kernel/linux-6.6.32/include/uapi/linux/cxlfork.h
kernel/linux-6.6.32/samples/cxlfork/cxlfork_uapi.h
```

作用：

- 注册 `/dev/cxlfork` 字符设备。
- 通过 `cxlfork.cxl_phys` 和 `cxlfork.cxl_size` 映射共享 CXL/NVDIMM window。
- 支持 `CXLFORK_FORK_PREPARE`：扫描 VMA、复制页面、构建 PTE/VMA/state/rebase 镜像。
- 支持 `CXLFORK_FORK_RESUME`：校验镜像、恢复映射、按 policy 处理 MoW/MoA/hybrid。
- 输出 prepare/restore 的 metadata breakdown，例如 `pte_image_build_ns`、`vma_tree_build_ns`、`private_rebase_ns`、`global_restore_ns`。

### 3.2 VM 启动脚本

位置：

```text
scripts/start-cxlfork-vms.sh
scripts/stop-cxlfork-vms.sh
```

VM 角色：

| VM | SSH 端口 | 角色 |
|---|---:|---|
| VM0 | 2200 | CXLfork checkpoint / prepare |
| VM1 | 2201 | CXLfork remote restore / invoke |
| localfork | 2202 | 普通单机 fork baseline |

VM0 和 VM1 共享同一个 host 文件作为 CXL backend：

```text
/dev/shm/cxl_mem
```

默认大小：

```text
4G
```

VM0/VM1 的 kernel cmdline 必须包含：

```text
cxlfork.cxl_phys=0x484000000
cxlfork.cxl_size=0xfb000000
```

localfork VM 不挂 CXL backend，不带 CXLfork cmdline 参数。

### 3.3 Unified Touch microbenchmark

位置：

```text
scripts/21-benchmark-unified-touch.sh
scripts/unified_touch_bench.c
```

作用：

- 最小化验证 CXLfork prepare/resume 是否可用。
- 使用固定虚拟地址映射一段匿名内存。
- VM0 prepare，VM1 resume 后逐页 read/write。
- 与 localfork VM 中的普通 `fork()` 做对比。

它不是 serverless benchmark，只是内存恢复与访问路径的最小闭环测试。

### 3.4 CXLporter

位置：

```text
cxlporter/src/cxlporter.c
cxlporter/scripts/30-benchmark-cxlporter.sh
```

作用：

- 模拟论文中 CXLporter 的 serverless 数据路径。
- VM0 运行 `cxlporter checkpoint`，为函数 workload 生成 checkpoint。
- VM1 运行 `cxlporter invoke`，创建 ghost worker，执行 CXLfork restore，然后运行函数 workload。
- localfork VM 运行 `cxlporter local`，作为普通 fork baseline。

当前 CXLporter 的实现不是完整 runtime scheduler。benchmark 脚本负责决定 function、key、policy、pool size 和请求次数。

### 3.5 OpenWhisk baseline

位置：

```text
cxlporter/openwhisk/scripts/start-standalone.sh
cxlporter/openwhisk/scripts/40-benchmark-openwhisk.sh
cxlporter/openwhisk/scripts/41-benchmark-local-node.sh
cxlporter/openwhisk/actions/faas_workload.js
cxlporter/openwhisk/actions/faas_workload.py
```

作用：

- `40-benchmark-openwhisk.sh`：通过 OpenWhisk standalone 执行 blocking invoke。
- `41-benchmark-local-node.sh`：直接运行 OpenWhisk Node.js runtime 容器，不经过 OpenWhisk 控制面。

OpenWhisk 当前只是 baseline。OpenWhisk invoker 没有直接调用 `/dev/cxlfork`，也没有接入 CXLporter。

## 4. 当前控制流

### 4.1 CXLfork 最小闭环

```text
host script
   |
   | deploy unified_touch_bench
   v
VM0: prepare key
   |
   | CXLFORK_FORK_PREPARE
   v
shared CXL window
   |
   | CXLFORK_FORK_RESUME
   v
VM1: resume key + touch pages
```

### 4.2 CXLporter benchmark

```text
host script
   |
   | choose function/key/policy/pool/requests
   v
VM0: ./cxlporter checkpoint <key> <function> <bytes>
   |
   | write function state to CXL slot
   v
VM1: ./cxlporter invoke <key> <function> <bytes> <policy> ...
   |
   | spawn ghost worker
   | CXLFORK_FORK_RESUME
   | run function workload
   v
CSV result
```

论文里更完整的设计通常是 serverless runtime 先决定是否扩容，再调用或查询 CXLporter。当前实现中，这个 runtime 决策被 benchmark 脚本替代。

## 5. 启动 VM

进入工作目录：

```bash
cd /home/xtl/cxlfork/cxlfork-repro
```

建议先启动 CXL 两个 VM：

```bash
WS=/home/xtl/cxlfork/cxlfork-repro \
KERNEL=/home/xtl/cxlfork/cxlfork-repro/kernel/build-6.6.32/arch/x86/boot/bzImage \
./scripts/start-cxlfork-vms.sh cxl
```

确认 VM0/VM1 正常后，再启动 localfork：

```bash
WS=/home/xtl/cxlfork/cxlfork-repro \
KERNEL=/home/xtl/cxlfork/cxlfork-repro/kernel/build-6.6.32/arch/x86/boot/bzImage \
./scripts/start-cxlfork-vms.sh localfork
```

不要在已有 VM 或端口占用状态下直接再次启动。先检查：

```bash
ss -lntp | grep -E ':2200|:2201|:2202' || true
ps -ef | grep qemu | grep -v grep || true
```

停止 VM：

```bash
WS=/home/xtl/cxlfork/cxlfork-repro ./scripts/stop-cxlfork-vms.sh all
```

## 6. VM 启动后检查

Host 上检查：

```bash
ps -ef | grep qemu | grep -v grep
ls -lh /dev/shm/cxl_mem
nc -z localhost 2200 && echo vm0_ssh_ok || echo vm0_not_ready
nc -z localhost 2201 && echo vm1_ssh_ok || echo vm1_not_ready
nc -z localhost 2202 && echo localfork_ssh_ok || echo localfork_not_ready
```

VM0 检查：

```bash
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 2200 ubuntu@localhost \
  'hostname; uname -r; cat /proc/cmdline; ls -l /dev/cxlfork /dev/dax0.0 2>/dev/null || true; dmesg | grep -i cxlfork | tail -40'
```

VM1 检查：

```bash
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 2201 ubuntu@localhost \
  'hostname; uname -r; cat /proc/cmdline; ls -l /dev/cxlfork /dev/dax0.0 2>/dev/null || true; dmesg | grep -i cxlfork | tail -40'
```

关键期望：

- VM0/VM1 都存在 `/dev/cxlfork`。
- VM0/VM1 `/proc/cmdline` 都包含 `cxlfork.cxl_phys` 和 `cxlfork.cxl_size`。
- `dmesg` 中能看到 CXLfork 初始化和 CXL window 映射信息。

## 7. 运行 Unified Touch

最小测试：

```bash
cd /home/xtl/cxlfork/cxlfork-repro

WS=/home/xtl/cxlfork/cxlfork-repro \
CXLFORK_KERNEL=/home/xtl/cxlfork/cxlfork-repro/kernel/linux-6.6.32 \
SIZES="4194304" \
MODES="read write" \
POLICIES="mow moa" \
ITERS=2 \
WARMUP=1 \
RUN_LOCAL=1 \
./scripts/21-benchmark-unified-touch.sh
```

输出：

```text
results/unified-touch-*.csv
```

成功标准：

- 脚本不崩溃。
- VM0 prepare 成功。
- VM1 resume 成功。
- CSV 中关键字段非空。
- LocalFork、MoW、MoA 的 `restore_ns`、`touch_ns`、`faults` 能观察到差异。

`faults` 的绝对数值先作为现象记录，不作为第一轮硬性 pass/fail 标准。

## 8. 运行 CXLporter

最小测试：

```bash
cd /home/xtl/cxlfork/cxlfork-repro/cxlporter

WS=/home/xtl/cxlfork/cxlfork-repro \
FUNCTIONS="json:4194304 touch:67108864" \
POLICIES="mow moa" \
POOL_SIZES="1 4" \
REQUESTS=2 \
WARMUP=1 \
./scripts/30-benchmark-cxlporter.sh
```

输出：

```text
cxlporter/results/cxlporter-*.csv
cxlporter/results/checkpoint-store-*.csv
```

`checkpoint-store-*.csv` 记录 checkpoint 阶段：

- `prepare_ns`
- `pages`
- `anon_pages`
- `pte_image_build_ns`
- `pt_page_image_build_ns`
- `vma_tree_build_ns`
- `state_image_build_ns`
- `private_rebase_ns`
- `global_detach_ns`

`cxlporter-*.csv` 记录 invoke 阶段：

- `restore_ns`
- `dispatch_to_done_ns`
- `workload_ns`
- `child_total_ns`
- `faults`
- `pages`

注意：

- 当前 `pool` 参数主要用于 ghost worker 配置，不等价于完整生产 runtime 的并发 autoscaling。
- 当前实现更适合测 CXLfork remote restore/invoke 路径，而不是测真实 serverless 调度器吞吐。

## 9. 运行 OpenWhisk baseline

启动 standalone：

```bash
cd /home/xtl/cxlfork/cxlfork-repro/cxlporter/openwhisk

ROOT=/home/xtl/cxlfork/cxlfork-repro/cxlporter/openwhisk \
PROXY= \
./scripts/start-standalone.sh
```

OpenWhisk benchmark：

```bash
ROOT=/home/xtl/cxlfork/cxlfork-repro/cxlporter/openwhisk \
RUNTIME=nodejs:20 \
FUNCTIONS="json:4194304 touch:67108864" \
REQUESTS=2 \
WARMUP=1 \
./scripts/40-benchmark-openwhisk.sh
```

Local Docker Node baseline：

```bash
ROOT=/home/xtl/cxlfork/cxlfork-repro/cxlporter/openwhisk \
FUNCTIONS="json:4194304 touch:67108864" \
REQUESTS=2 \
WARMUP=1 \
./scripts/41-benchmark-local-node.sh
```

停止 standalone：

```bash
ROOT=/home/xtl/cxlfork/cxlfork-repro/cxlporter/openwhisk \
./scripts/stop-standalone.sh
```

输出：

```text
cxlporter/openwhisk/results/openwhisk-*.csv
cxlporter/openwhisk/results/local-node-*.csv
```

OpenWhisk 的结果适合用来观察：

- OpenWhisk 控制面开销。
- Docker runtime 启动/执行开销。
- blocking invoke 端到端延迟。

不要把 OpenWhisk action 内部 workload 时间与 CXLporter C 版本 workload 做逐周期对比。两者语言、runtime 和执行环境不同。

## 10. 推荐测试顺序

建议每次重新搭环境或改代码后按以下顺序测试：

1. 检查 host 资源、端口、旧 QEMU 进程。
2. 启动 VM0/VM1。
3. 验证 VM0/VM1 的 `/dev/cxlfork` 和 kernel cmdline。
4. 启动 localfork。
5. 跑 Unified Touch 最小矩阵。
6. 跑 CXLporter 最小矩阵。
7. 跑 OpenWhisk standalone baseline。
8. 根据结果扩大矩阵，例如增加 function、size、policy、requests。

## 11. 常见停止条件

遇到以下情况不要继续扩大测试矩阵，先排查：

- 2200/2201/2202 端口已被占用，但无法确认是否属于当前实验。
- 已有旧 QEMU 进程且不清楚对应哪个工作区。
- `/dev/shm` 剩余空间不足 4G。
- VM0/VM1 没有 `/dev/cxlfork`。
- VM0/VM1 `/proc/cmdline` 没有 `cxlfork.cxl_phys` 或 `cxlfork.cxl_size`。
- `dmesg` 出现 CXLfork ioremap 或 CXL window 初始化失败。
- benchmark 编译找不到 `samples/cxlfork/cxlfork_uapi.h`。
- CSV 生成了，但关键 breakdown 字段为空。
- OpenWhisk standalone 未 ready 或 Docker runtime 拉取失败。

## 12. 结果解读重点

### Unified Touch

重点看：

- `prepare_ns`
- `restore_ns`
- `touch_ns`
- `faults`
- `pte_image_build_ns`
- `pt_page_image_build_ns`
- `vma_tree_build_ns`
- `state_image_build_ns`
- `private_rebase_ns`

一般来说：

- `prepare_ns` 反映 checkpoint 端扫描、复制和 metadata 镜像构建。
- `restore_ns` 反映 remote restore 端校验、映射和状态应用。
- `touch_ns` 与 policy 和 fault 行为强相关。
- `faults` 用于观察 MoW/MoA/hybrid 是否走了预期路径。

### CXLporter

重点看：

- checkpoint manifest 中的 prepare breakdown。
- invoke CSV 中的 `restore_ns`、`dispatch_to_done_ns`、`workload_ns`、`faults`。
- LocalFork 与 CXLporter 的端到端差异。

### OpenWhisk

重点看：

- `invoke_ns`
- `ow_wait_time_ms`
- `ow_duration_ms`
- `ow_init_ns`
- `ow_workload_ns`

OpenWhisk 是完整平台 baseline，通常会包含更多控制面和 runtime 开销。

## 13. 当前实现与论文的对应关系

已经覆盖的主线能力：

- 跨 VM 通过共享 CXL window 传递 checkpoint 状态。
- CXLfork prepare/resume 走 `/dev/cxlfork` ioctl。
- 输出 page table、VMA tree、state image、private rebase 等 metadata breakdown。
- 支持 MoW、MoA、hybrid 三类 tiering policy。
- CXLporter 能跑 checkpoint-store、ghost worker invoke 和 local fork baseline。
- OpenWhisk 能作为独立 baseline。

当前简化点：

- 使用 QEMU shared memory/NVDIMM 模拟 CXL window，不是真实 CXL fabric。
- CXLporter 没有真正嵌入 OpenWhisk invoker。
- 没有生产级 autoscaler，扩容/请求调度由脚本驱动。
- global state/fd/thread/namespace 恢复是研究原型子集。
- workload 是合成 workload，适合趋势分析，不代表完整应用语义。

## 14. 后续建议

如果要继续贴近论文中的 serverless runtime 集成，建议下一步补一个长期运行的 CXLporter controller：

1. 维护 `function -> checkpoint key` 的 checkpoint store。
2. 接收 invoke 请求，而不是每次由 shell 脚本直接调用。
3. 根据请求队列或并发阈值决定是否 spawn/restore ghost worker。
4. 暴露简单 HTTP/gRPC/Unix socket 接口，模拟 runtime 查询 CXLporter。
5. 再考虑和 OpenWhisk invoker 侧做真实集成。

这样可以把当前的“benchmark 脚本驱动”推进到更接近论文的“runtime 驱动 CXLporter”模型。
