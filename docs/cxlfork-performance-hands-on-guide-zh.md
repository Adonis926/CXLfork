# CXLfork 性能实验保姆级手动操作教程

> 文档状态：2026-07-14，已在真实远端环境逐步实操验证
>
> 远端开发服务器：`xtl@10.0.16.91`
>
> 远端工作区：`/home/xtl/cxlfork/cxlfork-repro`
>
> 本地跳板与备份区：`/home/adonis/cxlfork`
>
> 本文只讲环境启动和性能测试。ABI、rollback、fail-fast 等正确性专项测试请看 `docs/cxlfork-testing-guide-zh.md`，这里不展开。

## 1. 学完本文后你能做什么

照着本文走完一遍，你应当能够独立完成：

1. 从本地登录远端服务器。
2. 检查内核、镜像、端口和共享内存是否满足启动条件。
3. 清理上一轮实验并启动 VM0、VM1 和 localfork。
4. 运行底层 CXLfork/LocalFork 性能矩阵。
5. 启动 CXLporter daemon、ghost pool 和 OpenWhisk standalone。
6. 分别跑 Direct 和 OpenWhisk 控制路径性能实验。
7. 找到原始 CSV、汇总 CSV、环境记录、dmesg 和 checksum 文件。
8. 看懂最重要的延迟字段，避免把嵌套时间错误相加。
9. 把重要结果复制到本地并校验完整性。
10. 正确停止 OpenWhisk 和三台 VM。

这套流程有两类主要性能问题：

```text
底层数据面 benchmark：
  checkpoint、restore 和首次访问分别需要多久？
  MoW、MoA、Hybrid 和普通 fork 有什么差异？

控制面 benchmark：
  Direct 完整请求要多久？
  加入 OpenWhisk 后又增加了多少调度、HTTP、容器代理开销？
```

## 2. 先认识三台 VM 和两条控制路径

| 实例 | SSH 端口 | 作用 |
|---|---:|---|
| VM0 | 2200 | 创建 checkpoint，执行 `PREPARE_V2` |
| VM1 | 2201 | 运行 CXLporter daemon/ghost，执行 restore 和 workload |
| localfork | 2202 | 普通 Linux `fork()` 性能基线，不挂共享 CXL backend |

VM0 和 VM1 共享 host 文件：

```text
/dev/shm/cxl_mem
```

控制面有两条路径：

```text
Direct:
benchmark client → VM1 daemon → ghost → RESUME_V2 → workload

OpenWhisk:
benchmark client → OpenWhisk HTTP → Docker Node.js proxy action
                 → VM1 daemon → ghost → RESUME_V2 → workload
```

Direct 不是绕过 CXLfork。它只绕过 OpenWhisk，进入 VM1 后仍然使用同一个 daemon、ghost 和内核 restore。

## 3. 命令提示符约定

本文使用下面的标记帮助你判断命令在哪里执行：

```text
[本地]   /home/adonis/cxlfork 所在的跳板/备份机
[远端]   xtl@10.0.16.91 的 shell
[VM0]    ssh -p 2200 ubuntu@localhost
[VM1]    ssh -p 2201 ubuntu@localhost
```

复制命令时不要把 `[本地]$` 或 `[远端]$` 一起复制。

绝大多数操作都在远端服务器执行。只有登录远端和把结果复制回本地时，才使用本地 shell。

## 4. 性能相关脚本一览

### 4.1 推荐主流程脚本

| 脚本 | 是否必用 | 作用 | 主要输出 |
|---|---|---|---|
| `scripts/start-cxlfork-vms.sh` | 是 | 启动 VM0、VM1、localfork | PID、SSH/控制端口、console log |
| `scripts/stop-cxlfork-vms.sh` | 是 | 停止本工作区启动的 VM | 停止状态 |
| `scripts/21-benchmark-unified-touch.sh` | 数据面实验必用 | LocalFork 与 MoW/MoA/Hybrid 对比 | 45 列 CSV |
| `cxlporter/scripts/31-start-control-plane.sh` | 控制面实验必用 | 编译/部署 CXLporter，启动 VM1 daemon 和 ghost pool | daemon readiness |
| `cxlporter/openwhisk/scripts/start-standalone.sh` | OpenWhisk 路径必用 | 启动 standalone OpenWhisk | PID、API host、限流参数 |
| `cxlporter/openwhisk/scripts/42-deploy-cxlporter-action.sh` | OpenWhisk 路径必用 | 部署并 PING Node.js proxy action | action readiness |
| `cxlporter/scripts/33-benchmark-control-plane.sh` | 控制面实验必用 | Direct/OpenWhisk 完整性能矩阵 | 62 列原始 CSV 和 summary |
| `cxlporter/openwhisk/scripts/stop-standalone.sh` | 是 | 停止 standalone 和 `wsk*` 容器 | 停止状态 |

### 4.2 主脚本调用的辅助程序

| 文件 | 作用 |
|---|---|
| `scripts/unified_touch_bench.c` | 底层数据面 workload 源码，由脚本自动编译和部署 |
| `cxlporter/src/cxlporter_control.c` | checkpoint、daemon、ghost 和协议客户端实现 |
| `cxlporter/openwhisk/scripts/control_benchmark.py` | 逐请求采样 Direct/OpenWhisk 路径 |
| `cxlporter/openwhisk/scripts/summarize_control.py` | 生成 mean/P50/P95/P99/stddev 汇总 |
| `cxlporter/openwhisk/actions/cxlporter_proxy.js` | Docker action 中的 TCP 代理 |

### 4.3 可选或历史性能脚本

| 脚本 | 用途 | 是否建议作为当前主结果 |
|---|---|---|
| `cxlporter/scripts/30-benchmark-cxlporter.sh` | 早期 ghost pool、合成函数和 LocalFork 对比，旧 24 列 schema | 否，学习旧路径时使用 |
| `cxlporter/openwhisk/scripts/40-benchmark-openwhisk.sh` | 独立 OpenWhisk workload baseline | 可选辅助基线 |
| `cxlporter/openwhisk/scripts/41-benchmark-local-node.sh` | 直接运行 Node runtime 容器，拆分 Docker/runtime 成本 | 可选辅助基线 |

`cxlporter/scripts/32-control-correctness.sh` 是正确性验收脚本，不属于本文关注的性能流程。

## 5. 第一次操作：登录并进入工作区

在本地执行：

```bash
ssh xtl@10.0.16.91
```

登录成功后，设置工作区变量：

```bash
export WS=/home/xtl/cxlfork/cxlfork-repro
cd "$WS"
pwd
```

预期：

```text
/home/xtl/cxlfork/cxlfork-repro
```

确认分支和提交：

```bash
git branch --show-current
git rev-parse --short HEAD
git -C kernel/linux-6.6.32 rev-parse --short HEAD
git -C cxlporter rev-parse --short HEAD
```

当前应使用：

```text
主仓库分支：cxlfork-cohort-openwhisk
kernel 分支：cxlfork-kernel-paper-alignment
CXLporter 分支：cxlfork-cohort-openwhisk
```

不要在不清楚变更来源时执行 `git reset --hard` 或删除仓库。实验结果目录通常被 Git 忽略，源码状态和结果文件是两件事。

## 6. 启动前检查

### 6.1 检查关键文件

```bash
cd "$WS"

test -s kernel/build-6.6.32/arch/x86/boot/bzImage && echo kernel_ok
test -s images/vm0.qcow2 && echo vm0_image_ok
test -s images/vm1.qcow2 && echo vm1_image_ok
test -s images/normal-localfork.qcow2 && echo local_image_ok
test -s cloudinit/vm0-seed.iso && echo vm0_seed_ok
test -s cloudinit/vm1-seed.iso && echo vm1_seed_ok
```

必须看到所有 `_ok`。如果某项没有输出，先不要继续启动。

### 6.2 检查 KVM、QEMU 和共享内存空间

```bash
test -e /dev/kvm && echo kvm_ok
qemu-system-x86_64 --version | head -1
df -h /dev/shm
```

共享 backend 默认需要 4 GiB，host 还要能承载三台默认 16 GiB VM。只跑控制面时可以不启动 localfork，从而少用一台 VM 的内存。

### 6.3 检查端口

```bash
ss -lntp | grep -E ':(2200|2201|2202|2301|3233)\b' || true
```

端口用途：

| 端口 | 用途 |
|---:|---|
| 2200 | VM0 SSH |
| 2201 | VM1 SSH |
| 2202 | localfork SSH |
| 2301 | host 到 VM1 daemon 的 QEMU 转发 |
| 3233 | OpenWhisk standalone API |

如果端口已经占用，可能是上一轮环境仍在运行。先按下一节停止，不要直接再启动一套。

## 7. 可选：源码修改后重新编译内核

如果只是使用当前已经编译好的系统，可以跳到第 8 节。只有修改内核源码、切换 kernel commit 或 `bzImage` 缺失时才需要重新编译。

```bash
cd "$WS"
mkdir -p kernel/build-6.6.32

make -C kernel/linux-6.6.32 \
  O="$WS/kernel/build-6.6.32" olddefconfig

kernel/linux-6.6.32/scripts/config \
  --file kernel/build-6.6.32/.config --enable CXLFORK
kernel/linux-6.6.32/scripts/config \
  --file kernel/build-6.6.32/.config --enable CXLFORK_SELFTEST
kernel/linux-6.6.32/scripts/config \
  --file kernel/build-6.6.32/.config --enable NLS_CODEPAGE_437
kernel/linux-6.6.32/scripts/config \
  --file kernel/build-6.6.32/.config --enable NLS_ISO8859_1

make -C kernel/linux-6.6.32 \
  O="$WS/kernel/build-6.6.32" olddefconfig
make -C kernel/linux-6.6.32 \
  O="$WS/kernel/build-6.6.32" -j"$(nproc)" bzImage headers_install
```

检查：

```bash
grep -E '^CONFIG_CXLFORK(=|_)' kernel/build-6.6.32/.config
ls -lh kernel/build-6.6.32/arch/x86/boot/bzImage
```

预期至少看到：

```text
CONFIG_CXLFORK=y
CONFIG_CXLFORK_SELFTEST=y
```

CXLporter 和 unified-touch 不需要在这里手工编译：后续启动/benchmark 脚本会使用权威 UAPI 自动编译。

## 8. 清理上一轮环境并启动三台 VM

### 8.1 先停止可能存在的旧环境

```bash
cd "$WS/cxlporter"
./openwhisk/scripts/stop-standalone.sh

cd "$WS"
./scripts/stop-cxlfork-vms.sh all
```

即使环境没有运行，停止脚本也会给出 “not running”，这是正常情况。

确认端口释放：

```bash
ss -lntp | grep -E ':(2200|2201|2202|2301|3233)\b' || true
```

没有输出才表示旧环境已经完全退出。

### 8.2 获得可复现结果时，清理旧共享 backend

> **安全要求：只有在 VM0 和 VM1 都已停止、2200/2201/2301 均未监听时，才能删除 `/dev/shm/cxl_mem`。运行中删除会破坏实验。**

确认已经停止后执行：

```bash
rm -f /dev/shm/cxl_mem
```

当前 `start-cxlfork-vms.sh` 已修复为：在确认没有活跃 VM0/VM1 后，自动删除并重建 backend。这里仍显式清理一次，是为了让手工实验起点更容易理解和复现。

为什么要清理？同尺寸 `truncate -s 4G` 不会清除旧文件内容。如果沿用旧 backend，残留 slot 可能让新 checkpoint 返回：

```text
CXLFORK_FORK_PREPARE: File exists
```

### 8.3 启动 VM0 和 VM1

```bash
cd "$WS"
./scripts/start-cxlfork-vms.sh cxl
```

预期类似：

```text
started vm0 pid=... ssh=localhost:2200
started vm1 pid=... ssh=localhost:2201 control=172.17.0.1:2301
```

### 8.4 启动 localfork

底层 LocalFork 对照实验需要：

```bash
./scripts/start-cxlfork-vms.sh localfork
```

预期：

```text
started localfork pid=... ssh=localhost:2202
```

如果只跑第 12 节的 Direct/OpenWhisk 控制面 benchmark，可以不启动 localfork。

### 8.5 等待 SSH 可用

VM 通常很快启动，但首次进入时仍建议检查：

```bash
for port in 2200 2201 2202; do
  until ssh -o ConnectTimeout=2 \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -p "$port" ubuntu@localhost true 2>/dev/null; do
    echo "waiting for SSH port $port"
    sleep 2
  done
done

echo all_guests_ready
```

## 9. 检查 VM 是否真的使用了正确环境

### 9.1 检查 VM0/VM1

```bash
for port in 2200 2201; do
  echo "checking VM on port $port"
  ssh -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -p "$port" ubuntu@localhost \
    'uname -r; ls -l /dev/cxlfork; cat /proc/cmdline'
done
```

你应该看到：

- kernel 为 `6.6.32+`；
- `/dev/cxlfork` 存在；
- cmdline 包含 `cxlfork.cxl_phys=0x484000000`；
- cmdline 包含 `cxlfork.cxl_size=0xfb000000`。

### 9.2 检查 localfork

```bash
ssh -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -p 2202 ubuntu@localhost \
  'uname -r; cat /proc/cmdline'
```

localfork cmdline 不应包含 `cxlfork.cxl_phys`。因为三台 VM 使用同一个 built-in 内核，localfork 中仍可能看到 `/dev/cxlfork` 设备节点；判断它是不是 CXL 实验 VM，应看 QEMU 是否挂共享 backend 和 cmdline，而不是只看设备节点。

### 9.3 检查 host 端口

```bash
ss -lnt | grep -E ':(2200|2201|2202|2301)\b'
```

四个端口都应出现。

## 10. 第一类性能实验：底层 unified-touch

### 10.1 这个脚本测什么

`scripts/21-benchmark-unified-touch.sh` 会自动完成：

```text
host 编译 unified_touch_bench
  → 部署到 VM0、VM1、localfork
  → localfork 执行普通 fork + touch
  → VM0 为每种 policy prepare checkpoint
  → VM1 restore 并执行相同 read/write touch
  → VM0 release key
  → 写出 45 列 CSV
```

它适合回答：不同 footprint、访问模式和 MoW/MoA/Hybrid 策略，对 prepare、restore、page fault 和首次访问有什么影响。

### 10.2 先跑经过验证的最小矩阵

```bash
cd "$WS"

export DATA_RUN_ID="manual-unified-$(date +%Y%m%d-%H%M%S)"
export DATA_OUT="$WS/results/$DATA_RUN_ID.csv"

OUT="$DATA_OUT" \
ITERS=3 \
WARMUP=1 \
SIZES="4194304" \
MODES="read" \
POLICIES="mow moa hybrid" \
KEY_BASE=97200 \
./scripts/21-benchmark-unified-touch.sh
```

参数含义：

| 参数 | 示例 | 含义 |
|---|---|---|
| `OUT` | `results/manual-unified-时间.csv` | 输出文件，建议每轮唯一 |
| `ITERS` | 3 | 正式 touch 次数 |
| `WARMUP` | 1 | 不计入最终值的预热次数 |
| `SIZES` | `4194304` | 工作集字节数，即 4 MiB |
| `MODES` | `read` | 逐页读；也可以是 `write` |
| `POLICIES` | `mow moa hybrid` | 要比较的 CXLfork 策略 |
| `KEY_BASE` | 97200 | 本轮第一个 checkpoint key |

你会看到类似输出：

```text
[LocalFork] bytes=4194304 mode=read ...
[CXLfork] policy=mow ...
[CXLfork] policy=moa ... faults=1024
[CXLfork] policy=hybrid ...
results=/home/xtl/.../results/manual-unified-....csv
```

只出现 SSH known-host warning 通常不影响实验。脚本使用临时 known-host 配置，每次连接可能重复打印。

### 10.3 检查输出文件

```bash
echo "$DATA_OUT"
wc -l "$DATA_OUT"
head -1 "$DATA_OUT"
```

这个最小矩阵应有 5 行：

```text
1 行表头
1 行 LocalFork
1 行 MoW
1 行 MoA
1 行 Hybrid
```

检查每行都是 45 列：

```bash
awk -F, '
NF != 45 {
  print "bad line", NR, "columns", NF
  bad = 1
}
END {
  if (bad) exit 1
  print "csv_columns=45 verify=ok"
}' "$DATA_OUT"
```

### 10.4 把最重要的纳秒字段换算成毫秒

```bash
awk -F, '
NR == 1 {
  for (i = 1; i <= NF; i++) col[$i] = i
  print "system,policy,prepare_ms,restore_ms,touch_ms,total_ms,faults"
  next
}
{
  printf "%s,%s,%.3f,%.3f,%.3f,%.3f,%s\n", \
    $col["system"], $col["policy"], \
    $col["prepare_ns"] / 1000000, \
    $col["restore_ns"] / 1000000, \
    $col["touch_ns"] / 1000000, \
    $col["total_ns"] / 1000000, \
    $col["faults"]
}' "$DATA_OUT"
```

本文实操时得到的示例：

```text
system,policy,prepare_ms,restore_ms,touch_ms,total_ms,faults
LocalFork,local,0.000,0.000,1.480,2.073,NA
CXLfork,mow,10.709,8.192,0.009,8.644,0
CXLfork,moa,10.717,8.018,2.507,11.131,1024
CXLfork,hybrid,10.760,7.642,0.012,8.054,0
```

这些是小样本流程验证数据，不应作为正式论文统计。MoA 的 `faults=1024` 与 4 MiB/4 KiB=1024 页一致，首次访问时间也明显增加。

### 10.5 跑更完整的底层矩阵

流程确认无误后，可以运行阶段 13 风格的矩阵：

```bash
cd "$WS"

export DATA_RUN_ID="unified-full-$(date +%Y%m%d-%H%M%S)"
export DATA_OUT="$WS/results/$DATA_RUN_ID.csv"

OUT="$DATA_OUT" \
ITERS=2 \
WARMUP=1 \
SIZES="4194304 67108864 201326592" \
MODES="read write" \
POLICIES="mow moa hybrid" \
KEY_BASE=98000 \
./scripts/21-benchmark-unified-touch.sh
```

这会覆盖 4、64、192 MiB 和 read/write。正式性能实验应增加迭代次数并考虑 CPU 绑定、系统噪声和重复轮次；本文只保证操作路径可运行。

### 10.6 如何理解 45 列 CSV

最常用字段：

| 字段 | 含义 |
|---|---|
| `system` | `LocalFork` 或 `CXLfork` |
| `policy` | local/MoW/MoA/Hybrid |
| `bytes`、`pages` | 工作集大小和页数 |
| `prepare_ns` | VM0 checkpoint 总时间 |
| `restore_ns` | VM1 restore 时间 |
| `touch_ns` | restore 后 workload 首次访问时间 |
| `total_ns` | 当前 VM1 测量的总路径 |
| `full_ns` | prepare + total 的组合指标 |
| `faults` | 驱动可观察到的 fault 数；不能替代 PFN correctness 证据 |

这个脚本保留了较早的 45 列/legacy breakdown，用于底层策略和首次访问趋势。它的 `restore_ns` 不应直接与第 12 节 V2 fast-path 的 `kernel_total_ns` 当成同一个指标比较。

## 11. 启动 CXLporter 控制面

控制面性能实验只要求 VM0 和 VM1 在线，localfork 可以继续运行，也可以关闭。

### 11.1 启动 daemon 和 ghost pool

```bash
cd "$WS/cxlporter"
POOL=4 ./scripts/31-start-control-plane.sh
```

脚本会：

1. 从 kernel 子模块复制权威 UAPI 到临时 `.build-uapi`。
2. 编译 `cxlporter-control`。
3. 停止旧 VM1 daemon，避免覆盖运行中二进制导致 `ETXTBSY`。
4. 部署二进制到 VM0/VM1 的 `/tmp/cxlporter-control/`。
5. 在 VM1:7000 启动 daemon 和 4 个 ghost。
6. 通过 host `172.17.0.1:2301` 发送 PING。

成功输出：

```text
cxlporter_daemon_ready protocol=CXLP/1 port=7000 pool=4 abi=2 ...
control_plane_ready endpoint=172.17.0.1:2301 pool=4 verify=ok
```

手工 PING：

```bash
./cxlporter-control send 172.17.0.1 2301 \
  CXLP/1 PING id=manual-direct-ping
```

预期：

```text
CXLP/1 RESULT id=manual-direct-ping status=0 verify=1 pong=1
```

### 11.2 `POOL` 是什么

`POOL=4` 表示 VM1 预先准备 4 个一次性 ghost 进程。它影响并发请求能否立即分配 worker。

```bash
POOL=1 ./scripts/31-start-control-plane.sh
POOL=4 ./scripts/31-start-control-plane.sh
POOL=8 ./scripts/31-start-control-plane.sh
```

每次执行会重启 daemon。单请求 micro 通常固定 pool=4；并发 scaling 才比较 1/4/8。

## 12. 启动 OpenWhisk 并验证代理 action

### 12.1 启动 standalone

```bash
cd "$WS/cxlporter"
./openwhisk/scripts/start-standalone.sh
```

成功输出：

```text
openwhisk_ready apihost=http://127.0.0.1:3233 ...
invokes_per_minute=100000 invokes_concurrent=30
```

脚本把 invocation limit 设为 100000/min。不要手工启动一个使用默认 60/min 限制的旧 standalone，否则大样本运行会在约 60 次调用后出现 HTTP 429。

查看日志：

```bash
tail -50 "$WS/cxlporter/openwhisk/openwhisk-standalone.log"
```

### 12.2 部署 CXLporter proxy action

```bash
./openwhisk/scripts/42-deploy-cxlporter-action.sh
```

预期：

```text
cxlporter_action_ready action=cxlporter_proxy \
endpoint=172.17.0.1:2301 verify=ok
```

该 action 是 Docker 中的 Node.js TCP 代理。真正执行 `RESUME_V2` 和 workload 的是 VM1 ghost，不是 action container。

### 12.3 手工发送 OpenWhisk PING

注意 `wsk` 的正确路径是 `openwhisk/wsk`，不是 CXLporter 根目录下的 `./wsk`：

```bash
./openwhisk/wsk -i action invoke cxlporter_proxy \
  --blocking --result \
  -p operation PING \
  -p request_id manual-openwhisk-ping
```

预期 JSON 包含：

```json
{
  "status": "0",
  "verify": "1",
  "pong": "1",
  "transport": "tcp-qemu-hostfwd"
}
```

到这里，Direct 和 OpenWhisk 两条控制路径都已经连通。

## 13. 第二类性能实验：Direct/OpenWhisk 控制面

### 13.1 主脚本做什么

`cxlporter/scripts/33-benchmark-control-plane.sh` 自动完成：

```text
记录源码和环境版本
  → 启动/重启 VM1 daemon
  → 部署 OpenWhisk proxy action
  → VM0 checkpoint 并生成 key/generation/checksum
  → daemon REGISTER 并验证 checkpoint
  → 采样 Direct 和 OpenWhisk 请求
  → 比较 invoke、restore-only 和 cold
  → 比较 ghost pool 并发
  → 生成逐请求 CSV 和 summary
  → release checkpoint
  → 保存 VM0/VM1 dmesg
  → 生成可移植 SHA256SUMS
```

### 13.2 先跑经过验证的小矩阵

```bash
cd "$WS/cxlporter"

export RUN_ID="cohort-control-manual-$(date +%Y%m%d-%H%M%S)"
export CONTROL_OUT="$WS/cxlporter/results/$RUN_ID"

RUN_ID="$RUN_ID" \
KEY=97300 \
FOOTPRINTS="4194304" \
POLICIES="mow" \
POOL_SIZES="4" \
MICRO_SAMPLES=20 \
SCALING_SAMPLES=10 \
CONCURRENCY_SAMPLES=20 \
WARMUP=3 \
OPENWHISK_SCALING=1 \
./scripts/33-benchmark-control-plane.sh
```

`RUN_ID` 必须每轮唯一。不要把新实验写入旧目录，否则某些合并文件可能混入上一轮样本。使用 `cohort-control-` 前缀也能让结果目录符合当前 `.gitignore`。

参数含义：

| 参数 | 示例 | 含义 |
|---|---|---|
| `RUN_ID` | 带时间戳的唯一名称 | 本轮结果目录名 |
| `KEY` | 97300 | checkpoint key；中断后重跑可先重置 backend |
| `FOOTPRINTS` | 4194304 | 4 MiB 工作集 |
| `POLICIES` | mow | 本轮只跑 MoW |
| `POOL_SIZES` | 4 | 并发实验只跑 pool=4 |
| `MICRO_SAMPLES` | 20 | Direct/OW invoke 和 restore-only 各 20 样本 |
| `SCALING_SAMPLES` | 10 | policy/cold 每组 10 样本 |
| `CONCURRENCY_SAMPLES` | 20 | 并发组 20 样本 |
| `WARMUP` | 3 | 每组预热 3 次 |
| `OPENWHISK_SCALING` | 1 | scaling 也运行 OpenWhisk |

该配置共生成 140 条正式样本：

```text
micro:       4 组 × 20 = 80
concurrency: 1 组 × 20 = 20
scaling:     4 组 × 10 = 40
总计：                  140
```

成功结束时：

```text
control_summary samples=140 output=.../control-summary.csv
CONTROL_BENCHMARK_OK outdir=... samples=140
```

这只是手工流程验证。20 个样本不足以报告可信 P99，因此 summary 中 P99 应为 `NA`。

### 13.3 三种 mode 的含义

| mode | CXLfork restore | 运行 workload | 用途 |
|---|---|---|---|
| `invoke` | 是 | 是 | 完整 remote invoke |
| `restore`/restore-only | 是 | 否 | 尽量隔离控制与 restore 路径 |
| `cold` | 否 | 是，重新 map/fill | 不使用 CXLfork restore 的对照 |

### 13.4 检查样本数量、列数和失败数

```bash
cd "$CONTROL_OUT"
wc -l control-samples.csv
```

140 个样本应得到 141 行：1 行表头 + 140 行数据。

检查 62 列：

```bash
awk -F, '
NR == 1 { print "columns=" NF }
NF != 62 { print "bad line", NR, NF; bad = 1 }
END { if (bad) exit 1 }
' control-samples.csv
```

检查 `status=0` 且 `verify=1`：

```bash
awk -F, '
NR == 1 {
  for (i = 1; i <= NF; i++) {
    if ($i == "status") status_col = i
    if ($i == "verify") verify_col = i
  }
  next
}
$status_col != 0 || $verify_col != 1 {
  print "failed row", NR
  bad++
}
END {
  print "bad_rows=" (bad + 0)
  if (bad) exit 1
}' control-samples.csv
```

预期：

```text
columns=62
bad_rows=0
```

## 14. 控制面结果目录怎么读

一个完整结果目录大致包括：

| 文件 | 内容 | 最常见用途 |
|---|---|---|
| `control-samples.csv` | 所有请求，每请求一行，62 列 | 自定义分析的权威原始数据 |
| `control-summary.csv` | 相同维度聚合后的所有指标 | 快速浏览整轮结果 |
| `samples-*.csv` | 某一个实验 tag 的原始样本 | 分析单组异常值 |
| `samples-*-summary.csv` | 单组 mean/P50/P95/P99/stddev | 论文表格和对比优先使用 |
| `checkpoint-manifest.csv` | key/generation/checksum 和 prepare 分项 | 分析 checkpoint 成本 |
| `environment.txt` | commit、Docker、OpenWhisk、样本参数 | 保证结果可追溯 |
| `checkpoints.log` | checkpoint 命令原始输出 | 调试 prepare |
| `register.log` | daemon REGISTER 输出 | 调试 registry |
| `release.log` | release 输出 | 检查 slot 是否回收 |
| `dmesg-2200.log`、`dmesg-2201.log` | 实验后内核日志 | 排查页表/生命周期问题 |
| `SHA256SUMS` | 所有结果文件的相对路径 checksum | 复制后完整性校验 |

### 14.1 先看环境记录

```bash
cat environment.txt
```

确认：

- `main_commit`、`kernel_commit`、`cxlporter_commit`；
- `openwhisk_build` 和 Docker 版本；
- footprint/policy/pool；
- 样本数。

如果两份结果的源码提交不同，不应只比较数字而忽略实现变化。

### 14.2 看 Direct micro 的关键指标

```bash
awk -F, '
NR == 1 ||
$9 == "client_e2e_ns" ||
$9 == "restore_ioctl_ns" ||
$9 == "kernel_total_ns"
' samples-direct-invoke-micro-summary.csv | column -s, -t
```

### 14.3 看 OpenWhisk micro 的关键指标

```bash
awk -F, '
NR == 1 ||
$9 == "client_e2e_ns" ||
$9 == "action_bridge_rtt_ns" ||
$9 == "daemon_total_ns" ||
$9 == "kernel_total_ns"
' samples-openwhisk-invoke-micro-summary.csv | column -s, -t
```

summary 中的单位仍然是 ns。换算：

```text
1 ms = 1,000,000 ns
1 µs = 1,000 ns
```

例如 `mean=950294 ns` 约为 `0.950 ms`。

### 14.4 为什么不能把所有字段相加

时间关系是嵌套的：

```text
client_e2e_ns
  └─ OpenWhisk 调度/HTTP（OpenWhisk 路径）
      └─ action_total_ns
          └─ action_bridge_rtt_ns
              └─ daemon_total_ns
                  ├─ queue_wait_ns
                  ├─ worker_wakeup_ns
                  └─ worker_total_ns
                      ├─ restore_ioctl_ns
                      │   └─ kernel_total_ns
                      └─ workload_ns
```

`client_e2e_ns` 已经包含下面的时间。不能计算：

```text
client_e2e + daemon + restore + kernel
```

正确做法是比较父子差值或占比。例如：

```text
OpenWhisk 额外路径 ≈ OpenWhisk client_e2e - Direct client_e2e
ioctl 用户/系统边界开销 ≈ restore_ioctl - kernel_total
```

### 14.5 `NA` 和 0 的区别

- 数值 0：字段有效，实际计数/计时为 0。
- `NA`：机制不支持、该请求没走这条路径，或没有有效测量 hook。

最终控制 benchmark 的 `touch` 是读路径，所以能测 shared-leaf attach，但通常不会触发 leaf/data CoW。相关 fault 字段为 `NA` 是正确结果，不应改成 0。

### 14.6 单组 summary 优先于总 summary

`control-summary.csv` 会按列维度聚合。若 micro 和 scaling 恰好具有相同 path/bytes/policy/mode，它们可能被合并为一个更大的组。

需要严格分析 micro 时，优先使用：

```text
samples-direct-invoke-micro-summary.csv
samples-openwhisk-invoke-micro-summary.csv
samples-direct-restore-micro-summary.csv
samples-openwhisk-restore-micro-summary.csv
```

## 15. 正式控制面矩阵

确认小矩阵完全成功后，可以运行默认正式矩阵：

```bash
cd "$WS/cxlporter"

export RUN_ID="cohort-control-$(date +%Y%m%d-%H%M%S)"
export CONTROL_OUT="$WS/cxlporter/results/$RUN_ID"

RUN_ID="$RUN_ID" ./scripts/33-benchmark-control-plane.sh
```

默认参数：

```text
FOOTPRINTS="4194304 67108864 201326592"
POLICIES="mow moa hybrid"
POOL_SIZES="1 4 8"
MICRO_SAMPLES=1000
SCALING_SAMPLES=100
CONCURRENCY_SAMPLES=1000
WARMUP=20
OPENWHISK_SCALING=1
```

默认矩阵应得到 9400 条正式样本：

```text
micro：       4000
concurrency： 3000
scaling/cold：2400
合计：        9400
```

1000 样本的 micro/concurrency 会报告 mean、P50、P95、P99、stddev。100 样本的 scaling 会把 P99 标为 `NA`。

正式运行期间不要：

- 同时在 host 上编译大型项目；
- 启动另一套 QEMU VM；
- 重启 daemon/OpenWhisk；
- 删除 `/dev/shm/cxl_mem`；
- 修改 CPU governor 或 host 资源配额；
- 用同一个 `RUN_ID` 再启动一轮。

## 16. 可选辅助 baseline

这些脚本不是当前主控制面结果的必需步骤。

### 16.1 早期 CXLporter/LocalFork

```bash
cd "$WS/cxlporter"
REQUESTS=5 WARMUP=1 \
FUNCTIONS="touch:4194304" \
POLICIES="mow moa hybrid" \
POOL_SIZES="1 4" \
./scripts/30-benchmark-cxlporter.sh
```

它输出旧 24 列 CXLporter CSV 和 14 列 checkpoint manifest。可用于理解早期路径，不应与当前 62 列 V2 控制面数据直接拼接。

### 16.2 纯 OpenWhisk workload baseline

```bash
cd "$WS/cxlporter"
FUNCTIONS="touch:4194304" REQUESTS=5 WARMUP=1 \
./openwhisk/scripts/40-benchmark-openwhisk.sh
```

它测 OpenWhisk 调度普通 Node/Python workload，不经过 CXLporter/CXLfork。

### 16.3 直接 Node runtime container baseline

```bash
cd "$WS/cxlporter"
FUNCTIONS="touch:4194304" REQUESTS=5 WARMUP=1 \
./openwhisk/scripts/41-benchmark-local-node.sh
```

它直接运行 OpenWhisk Node runtime 容器，用于拆分 Docker/runtime 与 OpenWhisk 平台成本。

## 17. 实验后检查 dmesg

性能数据生成后，至少扫描 VM0/VM1：

```bash
for port in 2200 2201; do
  ssh -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -p "$port" ubuntu@localhost 'sudo dmesg' \
    >"/tmp/cxlfork-dmesg-$port.log"

  if grep -E 'BUG:|WARNING:|Oops:|use-after-free|Bad pagetable|general protection fault' \
    "/tmp/cxlfork-dmesg-$port.log"; then
    echo "kernel error found on port $port"
  else
    echo "dmesg port $port clean"
  fi
done
```

`33-benchmark-control-plane.sh` 已自动把完整 dmesg 保存到结果目录，但手工检查有助于理解流程。

## 18. 把结果复制到本地备份区

下面的命令回到本地跳板机执行。先退出远端：

```bash
exit
```

### 18.1 复制底层 CSV

假设远端 `DATA_OUT` 是：

```text
/home/xtl/cxlfork/cxlfork-repro/results/manual-unified-20260714-150000.csv
```

本地执行：

```bash
mkdir -p /home/adonis/cxlfork/manual-results

scp xtl@10.0.16.91:/home/xtl/cxlfork/cxlfork-repro/results/\
manual-unified-20260714-150000.csv \
/home/adonis/cxlfork/manual-results/
```

底层 CSV 没有独立 manifest，可以比较远端和本地 SHA-256：

```bash
ssh xtl@10.0.16.91 \
  'sha256sum /home/xtl/cxlfork/cxlfork-repro/results/manual-unified-20260714-150000.csv'

sha256sum /home/adonis/cxlfork/manual-results/\
manual-unified-20260714-150000.csv
```

两行最前面的 hash 必须一致。

### 18.2 复制控制面结果目录

假设 `RUN_ID=cohort-control-20260714-150500`：

```bash
scp -r xtl@10.0.16.91:/home/xtl/cxlfork/cxlfork-repro/\
cxlporter/results/cohort-control-20260714-150500 \
/home/adonis/cxlfork/manual-results/
```

进入本地副本并校验：

```bash
cd /home/adonis/cxlfork/manual-results/\
cohort-control-20260714-150500

sha256sum -c SHA256SUMS
```

当前脚本生成相对路径 checksum，所以结果目录复制到任意位置后都可以直接验证。所有文件都应显示 `OK`。

## 19. 正确停止环境

重新登录远端：

```bash
ssh xtl@10.0.16.91
export WS=/home/xtl/cxlfork/cxlfork-repro
```

先停止 OpenWhisk：

```bash
cd "$WS/cxlporter"
./openwhisk/scripts/stop-standalone.sh
```

再停止 VM：

```bash
cd "$WS"
./scripts/stop-cxlfork-vms.sh all
```

最后确认端口全部释放：

```bash
ss -lntp | grep -E ':(2200|2201|2202|2301|3233)\b' || true
```

无输出表示关停完成。停止 VM 后共享 backend 文件可以保留，但下一次可复现实验仍建议按第 8 节从 clean backend 开始。

## 20. 常见问题和处理方法

### 20.1 `PREPARE: File exists`

常见原因：旧 `/dev/shm/cxl_mem` 保留了 READY slot，或者上一轮实验中断、没有 release。

处理：

```bash
cd "$WS/cxlporter"
./openwhisk/scripts/stop-standalone.sh
cd "$WS"
./scripts/stop-cxlfork-vms.sh all

ss -lntp | grep -E ':(2200|2201|2301)\b' || true
# 确认无输出后：
rm -f /dev/shm/cxl_mem

./scripts/start-cxlfork-vms.sh cxl
./scripts/start-cxlfork-vms.sh localfork
```

当前启动脚本已经真正重建同尺寸 backend，但旧提交上的脚本可能只有 `truncate -s 4G`，这不会清除内容。

### 20.2 SSH 端口已占用

```bash
ss -lntp | grep -E ':(2200|2201|2202|2301)\b'
cat "$WS"/pids/*.pid 2>/dev/null
```

优先使用 `stop-cxlfork-vms.sh all`。不要只删除 pidfile，QEMU 进程可能仍在运行。

### 20.3 VM 启动但 SSH 连接拒绝

先等待 10–30 秒，再看 console：

```bash
tail -100 "$WS/logs/vm0-console.log"
tail -100 "$WS/logs/vm1-console.log"
tail -100 "$WS/logs/local-console.log"
```

检查 host 内存、`/dev/kvm`、镜像路径和 root filesystem。

### 20.4 VM0/VM1 没有 `/dev/cxlfork`

```bash
ssh -p 2200 ubuntu@localhost 'uname -r; cat /proc/cmdline; dmesg | tail -100'
```

检查 QEMU 是否使用 `kernel/build-6.6.32/arch/x86/boot/bzImage`，config 是否为 `CONFIG_CXLFORK=y`，cmdline 的 CXL 物理范围是否正确。

### 20.5 `ETXTBSY` 或 daemon 启动失败

说明旧 daemon 仍在执行而脚本试图覆盖二进制。使用：

```bash
POOL=4 "$WS/cxlporter/scripts/31-start-control-plane.sh"
```

当前脚本会先终止旧 daemon、等待退出，再部署新二进制。不要在 VM1 手工直接覆盖运行中的文件。

### 20.6 OpenWhisk 出现 HTTP 429

检查 standalone 是否由项目脚本启动：

```bash
cd "$WS/cxlporter"
./openwhisk/scripts/stop-standalone.sh
./openwhisk/scripts/start-standalone.sh
```

成功输出必须包含：

```text
invokes_per_minute=100000
```

受到 60/min throttle 的结果只能用于故障诊断，不能混入性能统计。

### 20.7 找不到 `./wsk`

正确路径：

```text
$WS/cxlporter/openwhisk/wsk
```

在 CXLporter 根目录应执行：

```bash
./openwhisk/wsk -i property get
```

### 20.8 summary 中 P99 是 `NA`

这通常不是错误。小样本和 100 样本 scaling 不报告可信 P99。只有约 1000 样本的 micro/concurrency 才会报告 P99。

### 20.9 本地 `sha256sum -c` 仍引用远端绝对路径

说明结果来自修复前的 CXLporter 提交。新脚本生成：

```text
HASH  action-deploy.log
```

旧脚本生成：

```text
HASH  /home/xtl/.../action-deploy.log
```

旧结果可以重新在远端校验，或重新生成相对路径 manifest。当前修复后的 CXLporter commit 不再有这个问题。

### 20.10 小矩阵成功但数字波动很大

小矩阵的目的只是确认流程。正式测量前应：

- 使用足够 warmup 和样本数；
- 避免 host 同时运行高负载任务；
- 固定软件提交和配置；
- 保存 environment/dmesg；
- 重复多轮并报告标准差；
- 需要时固定 CPU、NUMA 和 governor；
- 不把 QEMU shared-file 结果描述成真实 CXL 硬件绝对性能。

## 21. 本文操作的真实验证记录

本文不是只根据源码推测命令。2026-07-14 在 `xtl@10.0.16.91` 上按上述顺序实际完成了两轮验证。

### 21.1 环境启动与底层性能

- 从无运行中 VM、无监听端口开始。
- 启动 VM0、VM1、localfork 成功。
- 三台 guest 均为 `6.6.32+`。
- VM0/VM1 cmdline 含相同 CXL phys/size。
- 运行 4 MiB、read、MoW/MoA/Hybrid、`ITERS=3`、`WARMUP=1`。
- 生成 5 行、45 列 CSV。
- 三台 VM dmesg 异常签名扫描干净。

远端结果：

```text
/home/xtl/cxlfork/cxlfork-repro/results/
manual-guide-unified-touch-clean-20260714.csv
```

本地备份：

```text
/home/adonis/cxlfork/manual-guide-validation-20260714/
manual-guide-unified-touch-clean-20260714.csv
```

### 21.2 控制面性能

- `POOL=4` daemon/ghost 启动成功。
- Direct PING 返回 `status=0 verify=1 pong=1`。
- OpenWhisk standalone 以 100000/min 限制启动。
- proxy action 部署和 OpenWhisk PING 成功。
- 运行 4 MiB、MoW 的小矩阵。
- 生成 140 条样本、62 列、0 个失败。
- Direct/OpenWhisk invoke、restore-only、cold 和 concurrency 均有数据。
- 结果 manifest 和 VM0/VM1 dmesg 检查通过。

远端结果：

```text
/home/xtl/cxlfork/cxlfork-repro/cxlporter/results/
cohort-control-manual-guide-20260714/
```

本地备份：

```text
/home/adonis/cxlfork/manual-guide-validation-20260714/
cohort-control-manual-guide-20260714/
```

小样本 Direct invoke 的示例均值约为：

```text
client_e2e_ns     950294 ns  ≈ 0.950 ms
restore_ioctl_ns   44225 ns  ≈ 0.044 ms
kernel_total_ns    26819 ns  ≈ 0.027 ms
```

小样本 OpenWhisk invoke 的示例均值约为：

```text
client_e2e_ns         17079374 ns ≈ 17.079 ms
action_bridge_rtt_ns   1336868 ns ≈ 1.337 ms
daemon_total_ns         214840 ns ≈ 0.215 ms
kernel_total_ns          25778 ns ≈ 0.026 ms
```

这些数字只证明教程流程在当时环境可工作，不替代先前 1000 样本的正式结果。

### 21.3 实操发现并修复的问题

1. 启动脚本原先对已有 4 GiB backend 做同尺寸 truncate，旧 slot 未清空。修复后，在无活跃 CXL VM 时先删除再重建 backend，并通过 inode 变化验证新文件确实创建。
2. 控制 benchmark 原先在 `SHA256SUMS` 写入远端绝对路径。修复后使用相对文件名；结果复制到本地后执行 `sha256sum -c SHA256SUMS` 全部通过。
3. 手工 OpenWhisk CLI 的正确位置是 `openwhisk/wsk`，已用真实 PING 验证。
4. 全流程最后按顺序停止 OpenWhisk 和三台 VM，2200/2201/2202/2301/3233 端口全部释放。

## 22. 一页式操作清单

如果已经理解前文，可用下面的清单快速执行。

### 22.1 远端启动

```bash
ssh xtl@10.0.16.91
export WS=/home/xtl/cxlfork/cxlfork-repro

cd "$WS/cxlporter"
./openwhisk/scripts/stop-standalone.sh
cd "$WS"
./scripts/stop-cxlfork-vms.sh all

# 确认所有 VM 已停止后才可清理：
rm -f /dev/shm/cxl_mem

./scripts/start-cxlfork-vms.sh cxl
./scripts/start-cxlfork-vms.sh localfork
```

### 22.2 最小底层性能

```bash
cd "$WS"
export DATA_RUN_ID="manual-unified-$(date +%Y%m%d-%H%M%S)"
export DATA_OUT="$WS/results/$DATA_RUN_ID.csv"

OUT="$DATA_OUT" ITERS=3 WARMUP=1 \
SIZES="4194304" MODES="read" \
POLICIES="mow moa hybrid" KEY_BASE=97200 \
./scripts/21-benchmark-unified-touch.sh
```

### 22.3 控制面启动

```bash
cd "$WS/cxlporter"
POOL=4 ./scripts/31-start-control-plane.sh
./openwhisk/scripts/start-standalone.sh
./openwhisk/scripts/42-deploy-cxlporter-action.sh
```

### 22.4 最小 Direct/OpenWhisk 性能

```bash
export RUN_ID="cohort-control-manual-$(date +%Y%m%d-%H%M%S)"
export CONTROL_OUT="$WS/cxlporter/results/$RUN_ID"

RUN_ID="$RUN_ID" KEY=97300 \
FOOTPRINTS="4194304" POLICIES="mow" POOL_SIZES="4" \
MICRO_SAMPLES=20 SCALING_SAMPLES=10 \
CONCURRENCY_SAMPLES=20 WARMUP=3 OPENWHISK_SCALING=1 \
./scripts/33-benchmark-control-plane.sh

cd "$CONTROL_OUT"
wc -l control-samples.csv
sha256sum -c SHA256SUMS
```

### 22.5 停止

```bash
cd "$WS/cxlporter"
./openwhisk/scripts/stop-standalone.sh
cd "$WS"
./scripts/stop-cxlfork-vms.sh all
```

## 23. 最重要的理解边界

完成实验后，解释结果时记住：

- `21-benchmark-unified-touch.sh` 主要看底层策略、checkpoint/restore/touch 趋势，使用旧 45 列 breakdown。
- `33-benchmark-control-plane.sh` 是当前 Direct/OpenWhisk 主实验，使用 V2 fast path 和 62 列逐请求 schema。
- 两个脚本中的同名时间不一定具有完全相同的调用范围，不应直接拼表。
- Direct 与 OpenWhisk 进入 VM1 后共享同一 CXLporter/CXLfork 数据面。
- OpenWhisk action 是真实 Docker proxy，但不是被 CXLfork 恢复的完整语言运行时。
- QEMU shared-file backend 能验证软件路径，不能代表真实 CXL fabric 的绝对延迟和带宽。
- 小样本只用于确认流程；正式论文数据必须使用足够样本、固定环境并保留原始 CSV。

---

第一次手工操作时，建议只跑第 10.2 节和第 13.2 节的小矩阵。确认输出行数、列数、失败数、dmesg 和 checksum 都正确后，再运行正式矩阵。这样遇到问题时，你能知道故障发生在 VM、底层数据面、CXLporter、OpenWhisk，还是结果分析阶段。
