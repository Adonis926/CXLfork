# HydraRPC + CXLfork + MapReduce 迁移到 103 的运行手册

## 1. 目标、范围和当前状态

本手册把 91 上已经跑通的静态 WordCount 系统迁移到
`xtl@10.0.16.103`。目标是保持 guest、CXLfork UAPI、MR worker 和
HydraRPC 协议不变，只把 host 共享后端从普通文件换成真实
`/dev/dax0.0`，为后续 breakdown 对比建立可信基线。

这次迁移的是 **HydraRPC + CXLfork + MR 双 VM 主线**，不是另一套
OpenWhisk paper VM。两套镜像、端口和共享布局不同，不能混用。

截至 2026-08-10 的已完成准备：

- 91 的当前 MR VM 已停机，两张源盘通过 `qemu-img check` 和 SHA256；
- 103 已建立独立源码目录、工作盘和只读 base 盘，没有改旧 HPCA、GVM、
  MR 或 OpenWhisk 工作区；
- 91 的当前 breakdown 原始数据已备份到 103；
- 103 clean clone 的 kernel、headers 和 CXLfork selftest 已构建通过；本机
  `bzImage` SHA256 为 `50e182f51661874085e57a95c12a65ea4b42dfa11633ae21c3aea7795e573fd7`；
- 在不切 DAX 的普通文件 backend 上，双 VM、固定 BDF、SSH、litmus、应用
  状态强绑定和 5-sample motivation smoke 均通过。原始结果分别位于
  `results/tmpfs-litmus-20260810T075248Z.log`、
  `results/tmpfs-state-binding-20260810T075605Z/` 和
  `results/tmpfs-motivation-smoke-20260810T075659Z/`；
- 尚未切换或清空 103 的 DAX，尚未产生“真实 CXL 已通过”的结论。

103 当前的 `/dev/dax0.0` 是 64 GiB、2 MiB 对齐、target node 2，但审计
时处于 `system-ram`，31 个 2 GiB memory block 全部 online。它不能直接
被 QEMU mmap。切回 `devdax` 会离线整个 64 GiB 设备，因此只能在所有组员
确认的独占窗口执行。

## 2. 锁定版本与目录

| 内容 | 103 路径 | 分支/版本 |
| --- | --- | --- |
| CXLfork 主仓库 | `/home/xtl/cxlfork/cxlfork-repro` | `cxlfork-real-cxl-mr-103`，源点 `2c4f70bcd63b` |
| CXLfork kernel | `.../kernel/linux-6.6.32` | `cxlfork-real-cxl-mr-103`，源点 `f1599b6b6e6a` |
| MR | `/home/xtl/cxlfork/mr-distributed` | `cxlfork-real-cxl-mr-103`，源点 `7a67dd9987db` |
| HydraRPC | `/home/xtl/cxlfork/HydraRPC` | `full-impl-compare-breakdown-cxl`，`eb185de17f16` |
| 91 基线 | `/home/xtl/start/hpca-cxlfork/baselines/91/breakdown-91-current-20260810T042458Z` | 原始结果，不覆盖 |
| 103 结果 | `/home/xtl/start/hpca-cxlfork/results/<UTC时间>/` | 每次新目录 |

两张只读 base 盘位于 `/home/xtl/start/hpca-cxlfork/images/`；实际运行的
工作盘位于主仓库 `images/vm0.qcow2`、`images/vm1.qcow2`。旧的
`paper-vm*.qcow2` 属于 OpenWhisk，任何 MR 命令都不应修改它们。

## 3. 共享内存和 VM 拓扑

唯一权威配置是 `config/real-cxl-103.env`：

| DAX byte range | 用途 | guest 暴露形式 |
| --- | --- | --- |
| `[0,4 GiB)` | 不属于本实验 | 不映射、不写入 |
| `[4,8 GiB)` | CXLfork slot/page/PTE leaf | 共享 NVDIMM |
| `[8,10 GiB)` | HydraRPC endpoint 0 | ivshmem，固定 BDF `00:02.0` |
| `[10,12 GiB)` | HydraRPC endpoint 1 | ivshmem，固定 BDF `00:03.0` |
| `[12,64 GiB)` | 不属于本实验 | 不映射、不写入 |

VM0 和 VM1 各有 16 GiB 私有 DRAM、16 vCPU；二者只共享上表三个 window。
VM0 固定 host CPU 48–67，VM1 固定 72–91，私有 DRAM 绑定 node1。guest
仍使用与 91 相同的 `cxl_phys=0x484000000`、`cxl_size=0xfb000000`。
103 的原生模式 KVM 要求 QEMU 使用 `kernel-irqchip=split,mem-merge=off`，
guest cmdline 使用 `nox2apic`；这是复用 103 现有可启动 profile 得出的 host
兼容配置，不是 CXLfork 机制的一部分。

这里是“host CXL-backed DAX + QEMU NVDIMM/ivshmem”。guest 并没有枚举一张
原生 CXL Type-3 PCI 设备，因此 103/91 延迟差不能全部解释为介质差异；
QEMU、EPT（当前 `eptad=N`）、CPU 和 NUMA 都要进入实验 manifest。

## 4. 为什么只有一个新管理脚本

为方便手工调试，本迁移不增加成套 wrapper：

- `scripts/start-cxlfork-vms.sh`：复用原启动器，增加 profile、NUMA 和固定
  BDF 参数；
- `scripts/stop-cxlfork-vms.sh`：原样复用，只处理自己的 PID file；
- `scripts/run-cxlfork-litmus.sh`：复用原 litmus runner；
- MR 的 `scripts/run-motivation-bench.sh`、`scripts/test-state-binding.sh`：
  复用现有 benchmark/correctness runner；
- `scripts/real-cxl-103/dax-admin.sh`：唯一新增的管理员入口，只有
  `status/preflight/enter/zero/restore` 五个子命令；
- `tools/dax_range_zero.c`：被管理员脚本按需编译，只允许清零 `[4,12) GiB`。

不要调用 103 上旧的 HPCA、ATC、HydraRPC-l1 或 `dax_zero` 启动器；它们会
切换全局 KVM、等待/终止别的 QEMU，或清空整个 64 GiB DAX。唯一可复用的
host 管理脚本是 `/home/xtl/start/hpca/load-native-kvm.sh`，但它也会重载
全局 KVM，只能在独占窗口使用。

## 5. 第一次构建（不需要 DAX 独占）

```bash
ssh xtl@10.0.16.103
cd /home/xtl/cxlfork/cxlfork-repro

mkdir -p kernel/build-6.6.32
cp /home/xtl/start/hpca-cxlfork/kernels/config-6.6.32-cxlfork-91 \
  kernel/build-6.6.32/.config
make -C kernel/linux-6.6.32 O="$PWD/kernel/build-6.6.32" olddefconfig
make -C kernel/linux-6.6.32 O="$PWD/kernel/build-6.6.32" -j16 bzImage
make -C kernel/linux-6.6.32 O="$PWD/kernel/build-6.6.32" headers_install

make -C kernel/linux-6.6.32/tools/testing/selftests \
  O="$PWD/kernel/build-6.6.32" TARGETS=cxlfork \
  INSTALL_PATH="$PWD/kernel/build-6.6.32/kselftest" install

grep -E '^CONFIG_CXLFORK(=|_)' kernel/build-6.6.32/.config
test -x kernel/build-6.6.32/kselftest/cxlfork/cxlfork_litmus
```

第一次 bring-up 的 profile 使用从 91 校验过的 `bzImage`；本机构建用于证明
源码可复现，并生成 MR 编译所需的权威 UAPI header。二者必须记录 SHA256。

原 Git baseline 导入受 Linux `.gitignore` 影响，漏跟踪了三个本来属于
Linux 6.6.32 源码的 linker-script 文件；它们在 91 的源目录中存在。103
首次 clean clone 构建发现此问题后，kernel 提交 `a5f3d70b1` 把三个原文件
纳入 Git，未改变 CXLfork 语义。`bzImage` 与 `headers_install` 分成两条命令，
避免把两个顶层目标混在同一次并行 make 中。

## 6. 独占窗口中的手工流程

### 6.1 只读检查

```bash
cd /home/xtl/cxlfork/cxlfork-repro
set -a; source config/real-cxl-103.env; set +a

scripts/real-cxl-103/dax-admin.sh status
scripts/start-cxlfork-vms.sh check
```

`status` 会列出 DAX mode/driver、QEMU、设备持有者、端口、登录会话和是否有
未恢复的 host state。`check` 只验证 CXLfork/Hydra range 不重叠。

### 6.2 与所有组员确认独占后进入 devdax

先确认没有任何其他 QEMU/DAX/KVM 实验，再执行：

```bash
sudo /home/xtl/start/hpca/load-native-kvm.sh
export CXLFORK_EXCLUSIVE_CONFIRM=I_HAVE_EXCLUSIVE_KVM_DAX_103

sudo -E scripts/real-cxl-103/dax-admin.sh preflight
sudo -E scripts/real-cxl-103/dax-admin.sh enter
sudo -E scripts/real-cxl-103/dax-admin.sh zero
```

`preflight` 同时验证：host/kernel、DAX geometry/mode、node2 是否为 0 使用、
31 个 block 是否 online/removable、GVM 功能是否关闭、QEMU/kernel/base image
hash、工作盘、端口和设备持有者。缺少精确确认 token 时它故意失败。

`enter` 先保存原 mode/ACL，再把整个设备切为 devdax，只给 `xtl` 增加设备
读写 ACL。`zero` 只清零并逐字节验证 `[4,12) GiB`；C 工具锁定设备、几何、
driver、offset、length 和确认 token，无法用来清空整盘。
device-dax 没有页缓存，当前 host 对 `msync(MS_SYNC)` 返回 `EINVAL`；工具只
对这一特定返回值标记 `msync_supported=no`，随后执行 full barrier 和完整
8 GiB read-back。其他 `msync` 错误仍然失败。

### 6.3 启动和人工定位

```bash
scripts/start-cxlfork-vms.sh cxl
cat pids/vm0.pid pids/vm1.pid
tail -f logs/vm0-console.log     # 另一个终端可看 vm1-console.log

ssh -i "$SSH_KEY" -p 2200 -o StrictHostKeyChecking=no ubuntu@localhost
ssh -i "$SSH_KEY" -p 2201 -o StrictHostKeyChecking=no ubuntu@localhost
```

在 host 检查 QEMU 约束：

```bash
for p in "$(cat pids/vm0.pid)" "$(cat pids/vm1.pid)"; do
  grep '^Cpus_allowed_list' /proc/$p/status
  numastat -p "$p"
done
```

`Mems_allowed_list` 只表示 cgroup/cpuset 允许的节点，不证明 `numactl --membind`
的实际分配；应以 `numastat -p` 中绝大部分 private DRAM 位于 node1 为准。

在两个 guest 检查：

```bash
uname -a
cat /proc/cmdline
ls -l /dev/cxlfork
lspci -nn | grep -Ei 'shared memory|memory'
sudo dmesg | grep -Ei 'cxlfork|nvdimm|BUG:|WARNING:|Oops:'
```

### 6.4 必须先过的 feasibility/correctness gate

跨 VM 原子、release/acquire 和 cache coherence 不是默认假设：

```bash
OUT=/home/xtl/start/hpca-cxlfork/results/litmus-$(date -u +%Y%m%dT%H%M%SZ).log \
  scripts/run-cxlfork-litmus.sh
```

日志必须以 `CXLFORK_LITMUS_OK` 结束，失败时不得继续做 lifecycle/benchmark。
shared-leaf A-bit 是独立 feasibility；因 `eptad=N` 或 EPT/TLB 不能稳定证明
时记录为环境限制，不阻塞 shared leaf PFN、leaf CoW、page CoW 和生命周期。

应用状态强绑定验收：

```bash
cd /home/xtl/cxlfork/mr-distributed
set -a
source /home/xtl/cxlfork/cxlfork-repro/config/real-cxl-103.env
set +a
RESULT_ROOT=/home/xtl/start/hpca-cxlfork/results/state-binding-$(date -u +%Y%m%dT%H%M%SZ) \
  scripts/test-state-binding.sh
```

该测试证明 reducer 实际消费 template role、generation、checksum 和业务
`value_scale`，并覆盖 readonly/MoW/MoA/Hybrid、损坏状态、错误 role、stale
generation、reader 清理与 dmesg。它不是“任意 IP/SP 透明恢复”的证明。

### 6.5 benchmark

先跑 smoke，再跑正式样本；每次使用新目录：

```bash
cd /home/xtl/cxlfork/mr-distributed
set -a
source /home/xtl/cxlfork/cxlfork-repro/config/real-cxl-103.env
set +a

RESULT=/home/xtl/start/hpca-cxlfork/results/motivation-smoke-$(date -u +%Y%m%dT%H%M%SZ)
scripts/run-motivation-bench.sh --output-dir="$RESULT" --smoke

RESULT=/home/xtl/start/hpca-cxlfork/results/motivation-main-$(date -u +%Y%m%dT%H%M%SZ)
scripts/run-motivation-bench.sh \
  --output-dir="$RESULT" --samples=1000 --warmups=50 --workers=4 \
  --activation-blocks=1 --modes=persistent,localfork,cxlfork \
  --template-bytes-list=4194304 --policy=mow --validation=fast
```

保留每请求 raw CSV、summary、stdout/stderr、guest dmesg、slot inspect、内核
restore stats 和环境 manifest。1000 样本可报告 mean/P50/P95/P99/stddev；若
临时只跑 30 次，只报告 mean/P50/P95/stddev，不写 P99。

解释 breakdown 时不要相加重叠字段。至少分开：HydraRPC 数据路径、host
调度/跨 OS 控制路径、worker 激活、slot lookup/lifecycle、kernel restore、
leaf attach/reconstruction、page fault/copy/prefetch。`persistent`、`localfork`
和 `cxlfork` 的差异不能单独归因于 CXL 介质。

## 7. 停止与恢复 host

每轮结束都先停自己的 VM，再恢复 103 原 DAX 状态：

```bash
cd /home/xtl/cxlfork/cxlfork-repro
scripts/stop-cxlfork-vms.sh
scripts/real-cxl-103/dax-admin.sh status

export CXLFORK_EXCLUSIVE_CONFIRM=I_HAVE_EXCLUSIVE_KVM_DAX_103
sudo -E scripts/real-cxl-103/dax-admin.sh restore
```

`restore` 拒绝有 QEMU/KVM/DAX holder 的环境，恢复进入实验前记录的 DAX
mode 和 ACL；原状态若是 system-ram，会重新 online 全部 memory block。它不
触碰 `/run/gvm-hpca`、`/dev/hugepages/gvm-private/pmem*`、旧 paper 镜像，
也不会替其他组恢复它们自己的 KVM 参数。

## 8. 最终验收和结果备份

正式迁移只有以下项目全部满足才算完成：

1. 两个 guest OS 同时映射 `/dev/dax0.0` 的相同 CXLfork/Hydra ranges；
2. 跨 VM atomic/coherence litmus 通过；
3. checksum、generation/reader/release、失败 rollback、shared leaf PFN、leaf
   CoW、page CoW 和 MoW/MoA/Hybrid 有原始证据；
4. MR reducer 确实消费恢复出的应用状态，WordCount 全部正确；
5. benchmark 有逐请求原始数据、无重复 breakdown、干净 dmesg 和环境
   manifest；
6. 结束后 DAX 恢复原 mode，未修改其他组资产。

结果先保存在 103 的 `/home/xtl/start/hpca-cxlfork/results/`。验收后再完整
复制到本地跳板 `/home/adonis/cxlfork/real-cxl-103-results/`；不要只备份
summary，也不要把大体积 raw 结果提交进 Git。
