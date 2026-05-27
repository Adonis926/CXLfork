# CXLfork 复现环境记录

最后更新：2026-05-27

## 1. 总览

当前复现环境在远端服务器：

```text
ssh xtl@10.0.16.104
hostname: Garen
host kernel: Linux 6.8.0-110-generic
workspace: /home/xtl/cxlfork-ws
```

目标是用 QEMU/KVM 启动两个 Ubuntu 24.04 guest，并把同一个 host 后端内存文件暴露给两个 VM，模拟 CXL fabric 上的共享内存设备。当前两个 VM 已经能用自编 Linux `6.6.32-cxlfork+` 启动，并在 guest 内看到同一个 devdax namespace：

```text
VM0: cxlfork-node0, SSH localhost:2200
VM1: cxlfork-node1, SSH localhost:2201
guest kernel: 6.6.32-cxlfork+
shared device in both guests: /dev/dax0.0
```

已验证：VM0 写 `/dev/dax0.0`，VM1 可读到同样内容。

## 2. GitHub 仓库组织

GitHub 账号/owner：

```text
qmyyxtl
```

当前有两个私有仓库：

```text
https://github.com/qmyyxtl/cxlfork-repro
https://github.com/qmyyxtl/cxlfork-linux-6.6.32
```

职责划分：

- `cxlfork-repro`：顶层复现工作区，记录脚本、文档、验证工具、实验流程。
- `cxlfork-linux-6.6.32`：Linux 6.6.32 内核源码仓库，作为顶层仓库的 submodule。

顶层仓库 submodule 配置：

```text
[submodule "kernel/linux-6.6.32"]
	path = kernel/linux-6.6.32
	url = https://github.com/qmyyxtl/cxlfork-linux-6.6.32.git
```

远端当前提交状态：

```text
/home/xtl/cxlfork-ws
  branch: main
  remote: https://github.com/qmyyxtl/cxlfork-repro.git

/home/xtl/cxlfork-ws/kernel/linux-6.6.32
  branch: main
  remote: https://github.com/qmyyxtl/cxlfork-linux-6.6.32.git
  baseline commit: 9b0e454eb Import Linux 6.6.32 baseline
```

注意：服务器到 `github.com:443` 有时会卡住，但 `api.github.com` 可用。因此顶层仓库提供了 `scripts/05-push-via-github-api.sh`，用于绕过普通 `git push`，通过 GitHub Git Database API 同步顶层仓库。内核仓库上一次普通 push 已成功。

## 3. 服务器文件结构

远端主要目录：

```text
/home/xtl/cxlfork-ws/
├── .git/                         # 顶层复现仓库
├── .gitignore
├── .gitmodules                   # kernel/linux-6.6.32 submodule
├── README.md
├── docs/
│   └── reproduction-plan.md
├── criu-cxl-poc/
│   ├── .gitignore
│   ├── Makefile
│   ├── README.md
│   └── criu_cxl_poc.c           # 用户态 CRIU-CXL 原型
├── criu-cxl/                    # checkpoint-restore/criu 改造版 submodule
├── scripts/
│   ├── 01-download-base.sh
│   ├── 02-create-vm-disks.sh
│   ├── 03-create-cloudinit.sh
│   ├── 04-create-github-private-repo.sh
│   ├── 05-push-via-github-api.sh
│   ├── 06-build-linux-6.6.32-bzimage.sh
│   ├── ssh-vm0.sh
│   ├── ssh-vm1.sh
│   ├── start-vm0.sh
│   ├── start-vm1.sh
│   └── stop-vms.sh
├── tools/
│   └── devdax_rw.c               # devdax 共享读写验证工具
├── images/
│   ├── base-orig.img
│   ├── base.qcow2
│   ├── vm0.qcow2
│   └── vm1.qcow2
├── cloudinit/
│   ├── vm0-meta-data
│   ├── vm0-user-data
│   ├── vm0-seed.iso
│   ├── vm1-meta-data
│   ├── vm1-user-data
│   └── vm1-seed.iso
├── kernel/
│   ├── linux -> linux-6.6.32
│   ├── linux-6.6.32/             # Linux 源码 submodule
│   ├── linux-6.6.32.tar.xz       # 下载的源码包，忽略
│   └── build-6.6.32/             # O= out-of-tree 构建目录，忽略
├── logs/
│   ├── vm0-console.log
│   └── vm1-console.log
├── sockets/
│   ├── vm0-monitor.sock
│   └── vm1-monitor.sock
└── pids/
    ├── vm0.pid
    └── vm1.pid
```

当前 CXL 共享后端不在 workspace 目录下，而是在 host tmpfs：

```text
/dev/shm/cxl_mem    # 4.0G, QEMU memory-backend-file, share=on
```

`.gitignore` 策略：

- 顶层仓库忽略 `images/`、`cloudinit/`、`logs/`、`pids/`、`sockets/`、`kernel/build-*`、内核 tarball。
- 内核源码仓库单独忽略 `.o`、`.cmd`、`vmlinux`、`bzImage`、`.config` 等构建产物。

## 4. CXL 共享内存如何被多个 VM 访问

当前不是使用真实 CXL 3.0 硬件，而是用 QEMU NVDIMM + host shared memory file 模拟 CXL-like 共享内存。

核心机制：

1. host 创建一个共享后端文件：

```text
/dev/shm/cxl_mem
```

2. VM0 和 VM1 的 QEMU 启动参数都引用同一个文件：

```bash
-object memory-backend-file,id=cxlmem,share=on,mem-path=/dev/shm/cxl_mem,size=4G
-device nvdimm,id=cxldev,memdev=cxlmem,label-size=16M
```

3. 因为 `share=on` 且两个 QEMU 进程映射同一个 host 文件，所以两个 guest 对 NVDIMM 数据区的读写最终落到同一段 host tmpfs 页面。

4. guest 内 Linux 通过 ACPI NFIT 发现 NVDIMM 设备。namespace 被配置为 devdax：

```bash
sudo ndctl create-namespace --force --reconfig=namespace0.0 --mode=devdax --map=dev
```

5. 两个 guest 都看到：

```text
/dev/dax0.0
namespace0.0 mode=devdax
size: 4211081216 bytes
align: 2097152 bytes
```

关键限制：

- 这验证的是共享字节可见性，不等价于真实 CXL fabric 的完整 cache-coherent 时延和一致性行为。
- devdax mmap 要满足设备对齐要求。当前 align 是 2MB，所以验证工具 `tools/devdax_rw.c` 会显式构造 2MB 对齐的虚拟地址。

共享验证方式：

```bash
cd /home/xtl/cxlfork-ws

scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -i ~/.ssh/id_ed25519 -P 2200 tools/devdax_rw.c ubuntu@localhost:/tmp/devdax_rw.c

scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -i ~/.ssh/id_ed25519 -P 2201 tools/devdax_rw.c ubuntu@localhost:/tmp/devdax_rw.c

./scripts/ssh-vm0.sh \
  'gcc -O2 -Wall /tmp/devdax_rw.c -o /tmp/devdax_rw && sudo /tmp/devdax_rw /dev/dax0.0 cxlfork-6.6.32-shared-ok'

./scripts/ssh-vm1.sh \
  'gcc -O2 -Wall /tmp/devdax_rw.c -o /tmp/devdax_rw && sudo /tmp/devdax_rw /dev/dax0.0'
```

预期输出：

```text
cxlfork-6.6.32-shared-ok
cxlfork-6.6.32-shared-ok
```

## 5. VM 配置

两个 VM 的主要配置一致：

```text
machine: q35, accel=kvm, nvdimm=on
cpu: host
vCPU: 16
local memory: 16G
maxmem: 20G
shared NVDIMM/devdax: 4G
disk: virtio qcow2 overlay
serial log: logs/vm{0,1}-console.log
monitor socket: sockets/vm{0,1}-monitor.sock
pid file: pids/vm{0,1}.pid
```

端口：

```text
VM0 SSH: host localhost:2200 -> guest :22
VM1 SSH: host localhost:2201 -> guest :22
```

网络：

```text
management NIC: QEMU user networking, enp0s2 in guest
data NIC: QEMU socket multicast, currently eth1 in guest
multicast: 230.0.0.1:1234
```

注意：cloud-init 里早期写的是 `ens4`，而新内核启动时数据网卡名显示为 `eth1`，因此静态 data 网络配置还需要后续修正。当前主要验证依赖 SSH 管理网和共享 devdax，不依赖 data NIC。

## 6. 内核构建

源码：

```text
/home/xtl/cxlfork-ws/kernel/linux-6.6.32
```

构建目录：

```text
/home/xtl/cxlfork-ws/kernel/build-6.6.32
```

构建脚本：

```bash
cd /home/xtl/cxlfork-ws
JOBS=64 ./scripts/06-build-linux-6.6.32-bzimage.sh
```

脚本做的事：

- 使用 `/boot/config-6.6.32-shm+` 作为 base config。
- 设置 `LOCALVERSION=-cxlfork`。
- 关闭 BTF debug 和 system trusted/revocation keys，避免构建依赖问题。
- 把直接启动 VM 所需组件编进内核：
  - `CONFIG_ACPI_NFIT=y`
  - `CONFIG_LIBNVDIMM=y`
  - `CONFIG_BLK_DEV_PMEM=y`
  - `CONFIG_ND_BTT=y`
  - `CONFIG_ND_PFN=y`
  - `CONFIG_DEV_DAX=y`
  - `CONFIG_DEV_DAX_PMEM=y`
  - `CONFIG_DEV_DAX_KMEM=y`
  - `CONFIG_NLS_CODEPAGE_437=y`
  - `CONFIG_NLS_ISO8859_1=y`
  - `CONFIG_ISO9660_FS=y`

输出：

```text
kernel/build-6.6.32/arch/x86/boot/bzImage
```

当前已验证的镜像：

```text
Linux kernel x86 boot executable bzImage
version 6.6.32-cxlfork+ #3
```

## 7. 脚本使用方式

所有脚本在远端：

```bash
cd /home/xtl/cxlfork-ws
```

### 7.1 下载基础镜像

```bash
./scripts/01-download-base.sh
```

作用：

- 下载 Ubuntu 24.04 cloud image。
- 转换/扩展为 `images/base.qcow2`。

### 7.2 创建 VM overlay 磁盘

```bash
./scripts/02-create-vm-disks.sh
```

作用：

- 基于 `images/base.qcow2` 创建：
  - `images/vm0.qcow2`
  - `images/vm1.qcow2`

注意：当前 CXL 共享后端使用 runtime `/dev/shm/cxl_mem`，不再通过这个脚本预创建 `cxl/cxl_mem.img`。

### 7.3 创建 cloud-init ISO

```bash
./scripts/03-create-cloudinit.sh
```

作用：

- 创建 VM0/VM1 的 NoCloud seed ISO：
  - `cloudinit/vm0-seed.iso`
  - `cloudinit/vm1-seed.iso`

当前 SSH 用户：

```text
ubuntu / cxlfork
```

### 7.4 编译 Linux 6.6.32 bzImage

```bash
JOBS=64 ./scripts/06-build-linux-6.6.32-bzimage.sh
```

输出：

```text
kernel/build-6.6.32/arch/x86/boot/bzImage
```

### 7.5 启动 VM

```bash
./scripts/start-vm0.sh
./scripts/start-vm1.sh
```

默认使用自编内核：

```text
USE_CUSTOM_KERNEL=1
KERNEL_IMAGE=/home/xtl/cxlfork-ws/kernel/build-6.6.32/arch/x86/boot/bzImage
KERNEL_APPEND="root=/dev/vda1 rw console=ttyS0 earlyprintk=ttyS0 nokaslr net.ifnames=0"
```

如果要回退到 guest 磁盘内默认内核：

```bash
USE_CUSTOM_KERNEL=0 ./scripts/start-vm0.sh
USE_CUSTOM_KERNEL=0 ./scripts/start-vm1.sh
```

### 7.6 停止 VM

```bash
./scripts/stop-vms.sh
```

如果旧 QEMU 进程已退出但 pid 文件还在，脚本会提示 not running 并清理 pid 文件。避免用宽泛 `pkill -f qemu`，因为容易误杀当前 SSH 命令行。

### 7.7 SSH 到 VM

```bash
./scripts/ssh-vm0.sh 'uname -r'
./scripts/ssh-vm1.sh 'uname -r'
```

脚本使用：

```text
StrictHostKeyChecking=no
UserKnownHostsFile=/dev/null
identity: ~/.ssh/id_ed25519
```

这样 VM 重建或 host key 改变时不会被旧 known_hosts 卡住。

### 7.8 GitHub 仓库创建/同步

创建顶层私有仓库：

```bash
./scripts/04-create-github-private-repo.sh cxlfork-repro
```

通过 GitHub API 同步顶层仓库：

```bash
./scripts/05-push-via-github-api.sh qmyyxtl cxlfork-repro main
```

这个脚本支持普通 blob，也支持 `kernel/linux-6.6.32` 这种 gitlink/submodule entry。

### 7.9 CRIU-CXL 用户态原型

源码在远端：

```bash
cd /home/xtl/cxlfork-ws/criu-cxl-poc
make clean all
```

这个原型不是完整 CRIU，也不透明迁移任意 Linux 进程。它复现的是论文里 CRIU 路径的核心数据流：把进程用户态内存和一小部分 OS 维护状态序列化出来，然后在另一台节点恢复。区别是这里不落文件、不通过网络传输，而是直接写入两个 VM 同时 mmap 的 CXL-like devdax 区域 `/dev/dax0.0`。

分发到两个 VM：

```bash
scp -r -P 2200 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  /home/xtl/cxlfork-ws/criu-cxl-poc ubuntu@localhost:/home/ubuntu/
scp -r -P 2201 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  /home/xtl/cxlfork-ws/criu-cxl-poc ubuntu@localhost:/home/ubuntu/
```

VM0 checkpoint：

```bash
./scripts/ssh-vm0.sh 'cd /home/ubuntu/criu-cxl-poc && make clean all && sudo ./criu-cxl-poc checkpoint --dax /dev/dax0.0 --mb 16 --iters 200000'
```

VM1 restore：

```bash
./scripts/ssh-vm1.sh 'cd /home/ubuntu/criu-cxl-poc && make clean all && sudo ./criu-cxl-poc restore --dax /dev/dax0.0 --iters 200000'
```

一次通过的结果：

```text
checkpoint=ok dax=/dev/dax0.0 heap=16777216 counter=100000 target=200000 checksum=0x74bfc57751ff9363 pre_acc=12299872 file_offset=29
restore=ok source_host=cxlfork-node0 heap=16777216 counter=100000 target=200000 verify=ok checksum=0x74bfc57751ff9363 continued=ok post_acc=12300064 final=0x1cbb8f2d906bc80b
os_state cwd=/home/ubuntu/criu-cxl-poc file=/tmp/criu-cxl-os-state-1233.txt file_offset=29 note="cooperative CRIU-CXL checkpoint"
```

其中：

- `heap/checksum/counter` 代表用户态内存镜像和执行进度。
- `cwd/file_offset` 模拟 CRIU 会保存的 OS 进程状态的一小部分。
- `continued=ok` 表示 VM1 基于 VM0 写入 CXL 的状态继续执行，而不是从头运行。

Docker 兼容路径：

```bash
cd /home/ubuntu/criu-cxl-poc
make clean DOCKER='sudo docker' docker-image
sudo ./docker-vm0-checkpoint.sh   # VM0
sudo ./docker-vm1-restore.sh      # VM1
```

当前两个 VM 的 Docker daemon 为适配自编内核做了保守配置：

```json
{
  "iptables": false,
  "bridge": "none",
  "ip-forward": false,
  "ip-masq": false,
  "storage-driver": "vfs",
  "features": {
    "containerd-snapshotter": false
  }
}
```

原因：

- 当前内核缺少 Docker 默认 bridge/nftables 所需能力，所以禁用容器网络。
- 当前内核缺少 overlayfs/snapshotter 所需能力，所以使用 `vfs` storage driver。
- 该测试不依赖容器网络，只需要 Docker 启动容器并把 `/dev/dax0.0` 透传给容器。

### 7.10 CRIU 原生 CXL image backend

源码：

```text
/home/xtl/cxlfork-ws/criu-cxl
```

GitHub：

```text
https://github.com/qmyyxtl/cxlfork-criu-cxl
```

基线来自 upstream `checkpoint-restore/criu`，当前改动提交：

```text
03fe89e Add CXL image backend
```

使用方式：

```bash
cd /home/ubuntu/criu-cxl
make -j$(nproc) criu/criu
```

VM0 dump 一个真实 PID 到 CXL：

```bash
mkdir -p /tmp/criu-cxl-dump
setsid sleep 600 >/dev/null 2>&1 &
pid=$!
sudo CRIU_CXL_IMAGE=/dev/dax0.0 ./criu/criu dump \
  -t "$pid" -D /tmp/criu-cxl-dump --shell-job -v4 -o dump.log
```

VM1 从 CXL restore：

```bash
mkdir -p /tmp/criu-cxl-restore
cd /tmp
sudo CRIU_CXL_IMAGE=/dev/dax0.0 /home/ubuntu/criu-cxl/criu/criu restore \
  -D /tmp/criu-cxl-restore --shell-job --restore-detached -v4 -o restore.log
pgrep -a sleep
```

已验证结果：

```text
VM0: Stored CXL image inventory/pages/core/... into /dev/dax0.0
VM1: Materialized CXL image ... entries=25
VM1: Restore finished successfully. Tasks resumed.
VM1: 32741 sleep 600
```

当前实现策略：

- dump 阶段：CRIU image 写入临时 backing file，`close_image()` 时复制到 `/dev/dax0.0` 中的 CXL archive，然后删除 backing image。
- restore 阶段：`open_image_dir()` 时先从 CXL archive materialize 全部 CRIU images 到 restore `-D` 目录，再让 CRIU 原生 restore 路径读取这些 images。
- 这样 CRIU 的进程冻结、寄存器、内存、fd、VMA、pstree 等语义仍由 upstream CRIU 路径负责；CXL backend 负责跨 VM image transport/storage。
- 后续要更接近论文的最终形态，可以继续把 restore 阶段从 materialize-all 优化为真正按需 CXL fd backend，但需要谨慎处理 CRIU restorer 的 fd 编号和生命周期。

## 8. 当前验证命令

### 8.1 CXLfork global/container state 语义

CXLfork 论文把 global state 分成两类处理：

- open files、sockets、mount points、PID namespace 等需要轻量序列化到 CXL，restore 时 redo/attach。
- network 和 cgroup configuration 不从 checkpointed process 完整恢复，而是继承调用 `CXLfork-restore` 的目标进程/ghost container 环境。

当前 `cxlfork` kernel branch 已按这个语义显式化：

- `cxlfork_global_state` 记录 `cwd/root`、`umask`、`rlimit`、signal mask、sigaltstack、fd state。
- `cxlfork_namespace_state` 记录 PID namespace、network namespace、cgroup namespace 的 inode 编号和策略 flags。
- mount namespace 的精确 inum 需要内核内部 helper；当前模块版不依赖未导出符号，用 `cwd/root` 路径作为 portable mount-state 表示。
- fd restore 采用重新打开 checkpointed path 的方式；因为跨 OS 实例没有必要强制保持同一个 fd number，本复现保留这种实现。
- `CXLFORK_NS_F_NET_INHERITED` 和 `CXLFORK_NS_F_CGROUP_INHERITED` 表示 network/cgroup 来自 restore caller，而不是从 checkpoint 反序列化。

跨 VM 验证命令：

```bash
cd /home/xtl/cxlfork-ws
for p in 2200 2201; do
  scp -P "$p" kernel/linux-6.6.32-cxlfork/drivers/cxlfork/cxlfork.ko \
    kernel/linux-6.6.32-cxlfork/samples/cxlfork/cxlfork_global_demo \
    ubuntu@localhost:/tmp/cxlfork/
  ssh -p "$p" ubuntu@localhost \
    'cd /tmp/cxlfork && sudo rmmod cxlfork 2>/dev/null || true; sudo insmod ./cxlfork.ko cxl_phys=0x484000000 cxl_size=0xfb000000 && sudo chmod 666 /dev/cxlfork'
done

KEY=68322
ssh -p 2200 ubuntu@localhost \
  "/tmp/cxlfork/cxlfork_global_demo prepare $KEY /tmp/cxlfork-global-state /tmp/cxlfork-global-state/fd.txt"
ssh -p 2201 ubuntu@localhost \
  "/tmp/cxlfork/cxlfork_global_demo resume $KEY /tmp/cxlfork-global-state /tmp/cxlfork-global-state/fd.txt"
```

最近一次验证输出：

```text
cxlfork_global_prepare key=68322 checkpoint_ns=8044 global_checkpoint_ns=2056 cwd=/tmp/cxlfork-global-state umask=027 fd=77 mnt_ns=0 pid_ns=4026531836 pid_ns_level=0 net_ns=4026531840 cgroup_ns=4026531835 ns_flags=0xf verify=ok
cxlfork_global_resume key=68322 restore_ns=16261 global_restore_ns=2143 fds_restored=1 cwd=/tmp/cxlfork-global-state umask=027 rlimit=777 sigmask=ok altstack=ok fd_state=ok checkpoint_mnt_ns=0 restore_mnt_ns=0 checkpoint_pid_ns=4026531836 restore_pid_ns=4026531836 restore_net_ns=4026531840 restore_cgroup_ns=4026531835 ns_flags=0xf verify=ok
```

### 8.2 CXLfork tiering 策略

当前 `cxlfork` kernel branch 已显式支持三种论文语义下的 tiering policy：

- `mow` / `CXLFORK_F_MIGRATE_ON_WRITE`：默认策略。restore 时预装 read-only CXL PTE，read 直接访问 CXL snapshot，write 走内核 COW/MoW。
- `moa` / `CXLFORK_F_MIGRATE_ON_ACCESS`：第一次 read/write 都触发 fault，并从 CXL snapshot 复制到本地页。
- `hybrid` / `CXLFORK_F_HYBRID_TIERING`：用 `tiering_hot_stride_pages` 表示实验性 hot-page profile；hot page 或 write fault 迁移到本地，cold read 保持 CXL-backed mapping。

UAPI 里新增了 `pte_image_build_ns`、`pte_image_pages`、`state_image_build_ns`、`state_image_pages`、`private_rebase_ns`、`private_rebase_entries`、`private_rebase_pages`、`global_detach_ns`、`pte_attach_ns`、`pte_attach_pages`、`pte_image_validate_ns`、`state_image_validate_ns`、`private_rebase_validate_ns` 和 `global_attach_ns`。这些字段用于衡量论文 3.1/4.1 中“restore 端直接访问 CXL checkpointed state、不 bulk fetch memory footprint”的核心路径：

- prepare 阶段在 CXL 中构建 state image，保存 restore 所需的 mm/thread/global/fd/VMA metadata。这个 state image 位于共享 CXL slot 内，VM1 restore 端直接读取和校验，而不是从 VM0 通过 socket/file 传输。
- prepare 阶段在 CXL 中构建 private rebase image，把 private state 内部对象统一记录成 `id -> CXL offset -> CXL physical address -> bytes/entries`。当前包括 page data、leaf-PTE image、state image、region table 和 PTE table，VM1 restore 必须验证该表后才继续。
- `CXLFORK_F_FULL_PRIVATE_STATE` 严格 private-state 模式会遍历进程全地址空间中的 eligible private VMAs，而不是只扫描 benchmark working set。它排除 shared/special VMAs，包含 private anonymous pages 和 private clean file-backed mappings（例如 library text/data pages），并通过 native memory copy 将这些页放到 CXL。
- page-table metadata 进一步从 flat leaf-PTE image 扩展为 CXL-resident PTE page image：按 2MB PMD 范围生成 4KB PTE page，每页包含 512 个 raw PTE value。restore 会先校验这些 page-table page images，再从该 image 解析连续 PFN run，并按 run 安装 CXL-backed PTE mapping；`direct_pte_install_ns/pages` 单独记录这个更严格的 PTE install 路径。
- task private image 已加入 CXL state image，记录 pid/tgid/ppid、comm、personality、task flags、调度 policy/priority、uid/gid/euid/egid/suid/sgid/fsuid/fsgid 和 capability masks。
- prepare 阶段显式记录 global detach cost；restore 阶段显式记录 global attach cost。这里的 detach/attach 语义对应跨 VM 可执行策略：checkpoint 端把 cwd/root/rlimit/signal/namespace/fd path metadata 从 private checkpoint 中拆出为 global attach descriptors，restore 端在 VM1 OS 中重新 apply/reopen，而不是把源 VM 的 kernel object 指针带过去。
- prepare 阶段在 CXL 中构建 leaf-PTE image，记录每个 checkpointed VA 对应的 CXL PFN/PTE value。
- 默认 MoW restore 会先校验 CXL leaf-PTE image，再把 CXL checkpointed pages attach 成 child 的 read-only mapping。
- child read 直接访问 CXL，write 再迁移到本地。

注意：当前仍是 module prototype，没有直接把 CXL device memory 里的 page-table page 安装成 Linux `mm_struct` 的真实页表页；它先实现了 CXL state image / leaf-PTE image 的构建、校验和 attach breakdown。

`scripts/21-benchmark-unified-touch.sh` 已支持：

```bash
RUN_LOCAL=0 \
ITERS=2 WARMUP=1 \
SIZES=4194304 \
MODES=read \
POLICIES="mow moa hybrid" \
HYBRID_HOT_STRIDE=4 \
bash scripts/21-benchmark-unified-touch.sh
```

最近一次 4MB read smoke test：

```text
跨 VM MoW read:
default 4MB working-set MoW read:
prepare_ns=803725 pte_image_build_ns=4593 pte_image_pages=6 pt_page_image_build_ns=5251 pt_page_image_pages=3 pt_page_image_entries=2 state_image_build_ns=1625 state_image_pages=3 private_rebase_ns=272 private_rebase_entries=6 private_rebase_pages=1 global_detach_ns=5075
restore_ns=133147 global_restore_ns=11395 pte_attach_ns=107796 pte_attach_pages=1024 direct_pte_install_ns=58963 direct_pte_install_pages=1024 pte_image_validate_ns=29205 pt_page_image_validate_ns=11059 state_image_validate_ns=397 private_rebase_validate_ns=452 global_attach_ns=11395 touch_ns=28203 faults=0

full private-state prepare smoke test:
prepare_ns=977786 pte_image_build_ns=6411 pte_image_pages=6 pt_page_image_build_ns=7637 pt_page_image_pages=7 pt_page_image_entries=6 state_image_build_ns=2737 state_image_pages=3 private_rebase_ns=326 private_rebase_entries=6 private_rebase_pages=1 global_detach_ns=4845 pages=890

早前 tiering smoke test:
mow:    prepare_ns=1039605 pte_image_build_ns=6315 pte_image_pages=6 restore_ns=51747 pte_attach_ns=43502 pte_attach_pages=1024 pte_image_validate_ns=8595 touch_ns=18350 faults=0
moa:    prepare_ns=1073843 restore_ns=16028  touch_ns=3492982 faults=1024
hybrid: prepare_ns=715685  restore_ns=25274  touch_ns=3425950 faults=1024
```

解释：

- `mow` read 没有 driver fault，因为 read-only CXL PTE 已在 restore 阶段安装；`pte_attach_pages=1024` 表示 4MB footprint 的 1024 个 checkpointed pages 被 attach 到 VM1 child 地址空间。
- `moa` read 对每页触发一次迁移，因此 4MB 有 1024 次 fault。
- `hybrid` 当前 smoke test 会对 cold/hot 页都在第一次访问进入 driver fault 路径，其中 hot 页复制到本地，cold read 映射 CXL；后续可以把 `tiering_hot_stride_pages` 替换为真实 A/D bit 或 profile 结果。

检查 VM 是否运行：

```bash
ps -ef | grep qemu-system-x86_64 | grep -v grep
```

检查 guest 内核：

```bash
./scripts/ssh-vm0.sh 'uname -a'
./scripts/ssh-vm1.sh 'uname -a'
```

检查 devdax：

```bash
./scripts/ssh-vm0.sh 'ls -l /dev/dax*; sudo ndctl list -N'
./scripts/ssh-vm1.sh 'ls -l /dev/dax*; sudo ndctl list -N'
```

预期：

```text
/dev/dax0.0
namespace0.0 mode=devdax
```

如果 namespace 退回 raw/pmem 模式，可在任一 VM 中重新配置：

```bash
sudo ndctl create-namespace --force --reconfig=namespace0.0 --mode=devdax --map=dev
```

然后重启两个 VM，让两边重新读取共享 NVDIMM label。

## 9. 当前已知问题

- `cloudinit/03-create-cloudinit.sh` 里数据网卡仍写的是 `ens4`，而当前 guest 中实际数据网卡是 `eth1`。这影响 VM 间 data network 静态 IP，但不影响管理 SSH 和 devdax 共享验证。
- 顶层 GitHub 同步优先用 `scripts/05-push-via-github-api.sh`，因为服务器到 `github.com:443` 曾出现卡住。
- 当前 CXL 方案是 QEMU/NVDIMM shared file 模拟，适合做 CXLfork 功能语义原型，不适合直接声称复现真实 CXL 硬件性能。
