# CXLfork 主线环境运行手册

本文面向当前阶段的主线复现：CXLfork、CXLporter、OpenWhisk baseline。默认目标环境为：

- 目标机器：`xtl@10.0.16.91`
- 工作目录：`/home/xtl/cxlfork/cxlfork-repro`
- kernel 源码：`/home/xtl/cxlfork/cxlfork-repro/kernel/linux-6.6.32`
- kernel build：`/home/xtl/cxlfork/cxlfork-repro/kernel/build-6.6.32`
- bzImage：`/home/xtl/cxlfork/cxlfork-repro/kernel/build-6.6.32/arch/x86/boot/bzImage`

所有脚本仍支持通过环境变量覆盖 `WS`、`KERNEL`、端口和 benchmark 参数。

## 1. 预检查

进入工作目录：

```bash
cd /home/xtl/cxlfork/cxlfork-repro
pwd
git branch --show-current
git status --short
git submodule status || true
```

检查资源：

```bash
df -h .
df -h /dev/shm
free -h
groups
ls -l /dev/kvm
```

检查端口和旧 VM：

```bash
ss -lntp | grep -E ':2200|:2201|:2202' || true
ps -ef | grep qemu | grep -v grep || true
ls -lh /dev/shm/cxl_mem 2>/dev/null || true
```

如果 2200/2201/2202 已被占用，或存在无法确认归属的旧 QEMU 进程，先不要启动新 VM。

## 2. 子模块

当前主线只需要：

```bash
git submodule update --init cxlporter
```

如果当前 checkout 中记录了 kernel gitlink：

```bash
git ls-files --stage kernel/linux-6.6.32
git submodule update --init kernel/linux-6.6.32
git -C kernel/linux-6.6.32 checkout cxlfork-only
```

如果当前 checkout 没有 kernel gitlink，则使用已有的 kernel 目录，或手动 clone 私有 kernel 仓库到固定路径：

```bash
mkdir -p kernel
git clone -b cxlfork-only https://github.com/qmyyxtl/cxlfork-linux-6.6.32.git kernel/linux-6.6.32
```

确认路径：

```bash
test -d kernel/linux-6.6.32
test -d cxlporter
```

CRIU-CXL、Mitosis-CXL 和原始 Mitosis 不属于当前主线，默认不初始化、不编译、不测试。

## 3. 编译内核

```bash
mkdir -p kernel/build-6.6.32
make -C kernel/linux-6.6.32 O=/home/xtl/cxlfork/cxlfork-repro/kernel/build-6.6.32 olddefconfig
kernel/linux-6.6.32/scripts/config --file kernel/build-6.6.32/.config --enable CXLFORK
kernel/linux-6.6.32/scripts/config --file kernel/build-6.6.32/.config --enable NLS_CODEPAGE_437
kernel/linux-6.6.32/scripts/config --file kernel/build-6.6.32/.config --enable NLS_ISO8859_1
make -C kernel/linux-6.6.32 O=/home/xtl/cxlfork/cxlfork-repro/kernel/build-6.6.32 olddefconfig
make -C kernel/linux-6.6.32 O=/home/xtl/cxlfork/cxlfork-repro/kernel/build-6.6.32 -j"$(nproc)" bzImage
```

编译后检查：

```bash
ls -lh kernel/build-6.6.32/arch/x86/boot/bzImage
grep CONFIG_CXLFORK kernel/build-6.6.32/.config || true
```

期望：

```text
CONFIG_CXLFORK=y
```

如果 `CONFIG_CXLFORK` 未启用，不要继续启动 VM。

如果 localfork 启动后进入 emergency mode 并提示 FAT `IO charset iso8859-1 not found`，说明 `CONFIG_NLS_CODEPAGE_437` 或 `CONFIG_NLS_ISO8859_1` 没有 built-in，需要按上面的 `scripts/config` 命令重新配置并编译。

## 4. 镜像和 Cloud-init

需要三个 qcow2：

```text
images/vm0.qcow2
images/vm1.qcow2
images/normal-localfork.qcow2
```

需要两个 seed ISO：

```text
cloudinit/vm0-seed.iso
cloudinit/vm1-seed.iso
```

当前默认 VM 用户：

- 用户名：`ubuntu`
- 密码：`123`
- 可写入本机 SSH public key 以免密登录。

本阶段不要自动删除或重建已有 qcow2 镜像。

## 5. 分阶段启动 VM

先启动 CXL 两个 VM：

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

停止：

```bash
WS=/home/xtl/cxlfork/cxlfork-repro ./scripts/stop-cxlfork-vms.sh all
```

脚本默认端口：

| VM | 端口 | 角色 |
|---|---:|---|
| VM0 | 2200 | checkpoint |
| VM1 | 2201 | restore/invoke |
| localfork | 2202 | local fork baseline |

## 6. VM 验证

host 检查：

```bash
ps -ef | grep qemu | grep -v grep
ls -lh /dev/shm/cxl_mem
nc -z localhost 2200 && echo vm0_ssh_ok || echo vm0_not_ready
nc -z localhost 2201 && echo vm1_ssh_ok || echo vm1_not_ready
nc -z localhost 2202 && echo local_ssh_ok || echo local_not_ready
```

VM0：

```bash
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 2200 ubuntu@localhost \
  'hostname; uname -r; cat /proc/cmdline; ls -l /dev/cxlfork /dev/dax0.0 2>/dev/null || true; dmesg | grep -i cxlfork | tail -40'
```

VM1：

```bash
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 2201 ubuntu@localhost \
  'hostname; uname -r; cat /proc/cmdline; ls -l /dev/cxlfork /dev/dax0.0 2>/dev/null || true; dmesg | grep -i cxlfork | tail -40'
```

只有 VM0/VM1 都存在 `/dev/cxlfork`，且 dmesg 没有 CXL window 初始化失败时，才继续 benchmark。

## 7. Unified Touch 最小测试

```bash
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

期望：

- 生成 `results/unified-touch-*.csv`。
- LocalFork 行列数与 header 对齐。
- CXLfork 行的 prepare/restore/touch/faults 字段非空。
- `mow` 和 `moa` 能观察到差异。

## 8. CXLporter Benchmark

```bash
cd /home/xtl/cxlfork/cxlfork-repro/cxlporter
WS=/home/xtl/cxlfork/cxlfork-repro \
FUNCTIONS="json:4194304 touch:67108864" \
POLICIES="mow moa" \
POOL_SIZES="1 4" \
REQUESTS=2 \
WARMUP=1 \
RUN_LOCAL=1 \
./scripts/30-benchmark-cxlporter.sh
```

期望：

- 生成 `results/cxlporter-*.csv`。
- 生成 `results/checkpoint-store-*.csv`。
- CSV 列数校验通过。
- `restore_ns`、`workload_ns`、`faults` 等字段非空。

## 9. OpenWhisk Baseline

启动：

```bash
cd /home/xtl/cxlfork/cxlfork-repro/cxlporter/openwhisk
ROOT=/home/xtl/cxlfork/cxlfork-repro/cxlporter/openwhisk PROXY= ./scripts/start-standalone.sh
```

benchmark：

```bash
ROOT=/home/xtl/cxlfork/cxlfork-repro/cxlporter/openwhisk \
RUNTIME=nodejs:20 \
FUNCTIONS="json touch" \
REQUESTS=2 \
WARMUP=1 \
./scripts/40-benchmark-openwhisk.sh

ROOT=/home/xtl/cxlfork/cxlfork-repro/cxlporter/openwhisk \
FUNCTIONS="json touch" \
REQUESTS=2 \
WARMUP=1 \
./scripts/41-benchmark-local-node.sh
```

停止：

```bash
ROOT=/home/xtl/cxlfork/cxlfork-repro/cxlporter/openwhisk ./scripts/stop-standalone.sh
```

## 10. Stop / Report 条件

遇到以下情况应停止并报告：

- 2200/2201/2202 被占用。
- 存在无法确认归属的旧 QEMU。
- `/dev/shm` 剩余空间不足 4G。
- `CONFIG_CXLFORK` 未启用。
- VM0/VM1 `/proc/cmdline` 缺少 `cxlfork.cxl_phys` 或 `cxlfork.cxl_size`。
- VM0/VM1 没有 `/dev/cxlfork`。
- dmesg 出现 cxlfork ioremap 或 CXL window 初始化失败。
- benchmark 编译找不到 `samples/cxlfork/cxlfork_uapi.h`。
- CSV 生成但关键 breakdown 字段为空或列数不一致。
