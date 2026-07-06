# 当前环境运行文档

本文说明 104 服务器上当前 CXLfork 复现环境的文件结构、VM 拓扑、启动状态、常用命令和 benchmark 运行方法。

## 1. 登录与工作目录

入口服务器：

```bash
ssh xtl@10.0.16.104
cd /home/xtl/cxlfork-ws
```

GitHub 或 Docker Hub 网络不稳定时使用代理：

```bash
export http_proxy=http://<user>:<password>@202.120.32.222:9081
export https_proxy=http://<user>:<password>@202.120.32.222:9081
export HTTP_PROXY="$http_proxy"
export HTTPS_PROXY="$https_proxy"
```

不要把代理密码、GitHub token 或 sudo 密码写入 git。需要 sudo 时使用当前服务器账户对应密码。

## 2. 顶层目录结构

当前 `/home/xtl/cxlfork-ws` 主要目录：

| 路径 | 说明 |
|---|---|
| `.gitmodules` | 记录 kernel、CRIU、Mitosis、CXLporter 子仓库 |
| `cloudinit/` | VM0/VM1 cloud-init seed 和 user-data |
| `criu-cxl/` | CRIU-CXL 子仓库 |
| `criu-cxl-poc/` | CRIU-CXL proof-of-concept 静态程序/辅助产物 |
| `cxlporter/` | CXLporter/serverless benchmark 子仓库 |
| `images/` | VM qcow2 镜像，包括 `vm0.qcow2`、`vm1.qcow2`、`normal-localfork.qcow2` |
| `kernel/` | Linux 6.6.32 源码、CXLfork 源码和 build 输出 |
| `kernel-patches/` | 可查看的内核 patch 包 |
| `logs/` | QEMU serial console log |
| `mitosis-core/` | 原始 Mitosis 参考仓库 |
| `pids/` | 当前 QEMU VM pidfile |
| `results/` | unified touch、paper-style benchmark 等结果 |
| `scripts/` | 当前主仓库 benchmark 脚本和辅助程序 |
| `sockets/` | QEMU monitor socket |

## 3. Git 仓库状态

主仓库：

```bash
cd /home/xtl/cxlfork-ws
git branch --show-current
git log --oneline --decorate -5
git submodule status --recursive
```

当前关键 commit：

- 主仓库：`d1189b0 Update CXLporter OpenWhisk benchmark`
- CXLporter：`be8022c Add OpenWhisk standalone benchmark`
- kernel：`91a312cb2 Make Mitosis forkctl resume output unbuffered`
- CRIU：`eac1d9add Disable CodeQL workflow for private fork`

更新子仓库：

```bash
git submodule update --init --recursive
```

推送主仓库当前 HEAD 到远端 `remote-fork`：

```bash
cd /home/xtl/cxlfork-ws
git push origin HEAD:remote-fork
```

推送 CXLporter：

```bash
cd /home/xtl/cxlfork-ws/cxlporter
git push origin main
```

## 4. 当前 VM 拓扑

当前有三个主要 VM：

| VM | 用途 | SSH | 内核 | CXL |
|---|---|---|---|---|
| `vm0` | checkpoint 节点 | `ssh -p 2200 ubuntu@localhost` | `6.6.32-cxlfork+` | 有 `/dev/cxlfork` |
| `vm1` | restore/invoke 节点 | `ssh -p 2201 ubuntu@localhost` | `6.6.32-cxlfork+` | 有 `/dev/cxlfork` |
| `localfork` | 单机 local fork baseline | `ssh -p 2202 ubuntu@localhost` | 同一 `bzImage` | 无 CXL 参数 |

检查 VM 是否运行：

```bash
cd /home/xtl/cxlfork-ws
ps -ef | grep qemu | grep -v grep
nc -z localhost 2200 && echo vm0_ssh_ok
nc -z localhost 2201 && echo vm1_ssh_ok
nc -z localhost 2202 && echo local_ssh_ok
```

检查 guest 内核与设备：

```bash
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 2200 ubuntu@localhost \
  'uname -r; ls -l /dev/cxlfork /dev/dax0.0 2>/dev/null || true'

ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 2201 ubuntu@localhost \
  'uname -r; ls -l /dev/cxlfork /dev/dax0.0 2>/dev/null || true'
```

## 5. CXL 共享内存如何被多个 VM 访问

VM0 和 VM1 通过 QEMU 共享同一个 host 文件：

```text
/dev/shm/cxl_mem
```

QEMU 参数核心部分：

```bash
-object memory-backend-file,id=cxlmem,share=on,mem-path=/dev/shm/cxl_mem,size=4G
-device nvdimm,id=cxldev,memdev=cxlmem,label-size=16M
```

guest 内核启动参数：

```text
cxlfork.cxl_phys=0x484000000 cxlfork.cxl_size=0xfb000000
```

含义：

- host 上 `/dev/shm/cxl_mem` 是两个 VM 共同映射的后端。
- QEMU 把它作为 NVDIMM 暴露给 VM。
- guest 中 CXLfork driver 根据 `cxlfork.cxl_phys` 和 `cxlfork.cxl_size` 找到共享窗口。
- VM0 checkpoint 写入该共享窗口。
- VM1 restore/invoke 从同一共享窗口读取 checkpointed state。

当前这不是物理 CXL 3.0 GIM，而是 QEMU 共享内存模拟。它足够验证论文里的共享 CXL medium 机制路径。

## 6. 内核构建与启动内核

当前 build 输出：

```bash
/home/xtl/cxlfork-ws/kernel/build-6.6.32/arch/x86/boot/bzImage
```

当前运行的 VM 都通过 QEMU `-kernel` 使用这个 bzImage。

重新编译内核：

```bash
cd /home/xtl/cxlfork-ws/kernel/linux-6.6.32
make O=/home/xtl/cxlfork-ws/kernel/build-6.6.32 olddefconfig
make O=/home/xtl/cxlfork-ws/kernel/build-6.6.32 -j"$(nproc)" bzImage
```

内核 patch 可查看：

```bash
cd /home/xtl/cxlfork-ws
less kernel-patches/cxlfork-built-in/cxlfork-built-in-linux-6.6.32.patch
```

注意：

- 当前 VM 已经在跑，不建议无准备地 kill QEMU。
- 如需重启 VM，先确认 `pids/`、`sockets/` 和 QEMU 启动参数。
- 当前仓库没有把完整 QEMU 启动脚本纳入 git，运行参数可从 `/proc/<pid>/cmdline` 或 `pids/*.pid` 反查。

查看当前 QEMU 命令：

```bash
cd /home/xtl/cxlfork-ws
for p in pids/*.pid; do
  echo "== $p =="
  tr '\0' ' ' </proc/$(cat "$p")/cmdline
  echo
done
```

## 7. CXLporter benchmark

CXLporter 子仓库：

```bash
cd /home/xtl/cxlfork-ws/cxlporter
```

构建：

```bash
make clean all
```

命令：

```bash
./cxlporter checkpoint <key> <function> <bytes>
./cxlporter invoke <key> <function> <bytes> <policy> <pool> <requests> <warmup> [keepalive_us] [hot_stride_pages]
./cxlporter local <function> <bytes> <requests> <warmup>
```

函数：

```text
touch json pyaes html float
```

策略：

```text
mow moa hybrid
```

标准 serverless benchmark：

```bash
cd /home/xtl/cxlfork-ws/cxlporter
FUNCTIONS="json:4194304 pyaes:4194304 html:8388608 touch:67108864" \
POLICIES="mow moa hybrid" \
POOL_SIZES="1 4" \
REQUESTS=5 \
WARMUP=1 \
./scripts/30-benchmark-cxlporter.sh
```

输出：

```text
cxlporter/results/cxlporter-*.csv
cxlporter/results/checkpoint-store-*.csv
```

最新一次结果：

```text
cxlporter/results/cxlporter-20260703-025157.csv
cxlporter/results/checkpoint-store-20260703-025157.csv
```

## 8. OpenWhisk standalone benchmark

OpenWhisk 路径：

```bash
cd /home/xtl/cxlfork-ws/cxlporter/openwhisk
```

启动：

```bash
./scripts/start-standalone.sh
```

该脚本会：

- 使用 `openwhisk/standalone:nightly`。
- 从镜像中提取 `openwhisk-standalone.jar`。
- 下载 `wsk` CLI。
- 启动 OpenWhisk standalone。
- 解析日志中的 auth，并配置 `wsk property`。

运行 OpenWhisk benchmark：

```bash
RUNTIME=nodejs:20 REQUESTS=5 WARMUP=1 ./scripts/40-benchmark-openwhisk.sh
```

运行 direct OpenWhisk runtime container baseline：

```bash
REQUESTS=5 WARMUP=1 ./scripts/41-benchmark-local-node.sh
```

停止 OpenWhisk：

```bash
./scripts/stop-standalone.sh
```

输出：

```text
cxlporter/openwhisk/results/openwhisk-*.csv
cxlporter/openwhisk/results/local-node-*.csv
```

最新一次结果：

```text
cxlporter/openwhisk/results/openwhisk-20260703-023943.csv
cxlporter/openwhisk/results/local-node-20260703-024045.csv
```

注意：

- 默认 `nodejs:20`，因为 standalone 镜像已经预热 Node.js runtime。
- `python:3.10` action 已保留，但 Python runtime 镜像曾因 Docker Hub EOF 拉取失败；镜像可用后可运行：

```bash
RUNTIME=python:3.10 REQUESTS=5 WARMUP=1 ./scripts/40-benchmark-openwhisk.sh
```

## 9. Unified touch benchmark

主仓库脚本：

```bash
cd /home/xtl/cxlfork-ws
./scripts/21-benchmark-unified-touch.sh
```

常用参数：

```bash
SIZES="4194304 67108864" \
MODES="read write" \
POLICIES="mow moa hybrid" \
ITERS=5 \
WARMUP=1 \
./scripts/21-benchmark-unified-touch.sh
```

输出：

```text
results/unified-touch-*.csv
```

该 benchmark 用于观察：

- local fork touch 成本
- CXLfork prepare/restore
- read/write 下 `mow`、`moa`、`hybrid` 的 fault 和迁移成本

## 10. CRIU-CXL

进入仓库：

```bash
cd /home/xtl/cxlfork-ws/criu-cxl
```

当前状态：

```bash
git branch --show-current
git log --oneline -5
```

用途：

- 验证 CRIU simple loop 风格 checkpoint/restore。
- 验证 CXL image backend 可替换文件 image transport。

目前 CRIU-CXL 不作为主 serverless benchmark 结论。

## 11. 常见检查命令

检查 `/dev/cxlfork`：

```bash
ssh -p 2200 ubuntu@localhost 'ls -l /dev/cxlfork; dmesg | tail -40'
ssh -p 2201 ubuntu@localhost 'ls -l /dev/cxlfork; dmesg | tail -40'
```

给设备授权：

```bash
ssh -p 2200 ubuntu@localhost 'sudo chmod 666 /dev/cxlfork'
ssh -p 2201 ubuntu@localhost 'sudo chmod 666 /dev/cxlfork'
```

检查 CXLporter 结果：

```bash
cd /home/xtl/cxlfork-ws/cxlporter
ls -lt results/*.csv | head
```

检查 OpenWhisk 结果：

```bash
cd /home/xtl/cxlfork-ws/cxlporter/openwhisk
ls -lt results/*.csv | head
```

检查 OpenWhisk action：

```bash
cd /home/xtl/cxlfork-ws/cxlporter/openwhisk
./scripts/start-standalone.sh
./wsk -i action list
./wsk -i activation list --limit 5
```

## 12. 当前注意事项

1. 主仓库存在大量未跟踪运行产物，包括 VM 镜像、结果 CSV、kernel build 输出、logs、pids。这些是环境产物，不应直接全部提交。
2. CXLporter 子仓库已忽略 OpenWhisk jar、wsk、log、result CSV。
3. OpenWhisk standalone 跑完后建议执行 `./scripts/stop-standalone.sh`，避免长期占用 Java 进程和 prewarm containers。
4. 如果 Docker Hub 拉取失败，先确认 Docker daemon proxy 是否生效，再重试。
5. benchmark 数字受当前 QEMU、host 负载、缓存状态影响；汇报时优先使用趋势和 breakdown，而不是绝对值。
