# CXLfork Spawn 等资源扩核实验

本实验补充固定 `16+16` vCPU 并发压力测试，回答 CXLfork remote-spawn 在增加
CPU 预算后能否扩展，以及它与 Cohort 的总核数曲线能否按相同资源口径比较。

## 口径

`total_vcpus` 是 VM0 和 VM1 的 vCPU 总和。每个配置平均分配：

```text
VM0 vCPU = total_vcpus / 2
VM1 vCPU = total_vcpus / 2
lanes     = VM1 vCPU
```

正式子集为 8、16、32、64、80 个总 vCPU，对应 4、8、16、32、40 lanes。
VM0 固定在 host NUMA node 0，VM1 固定在更靠近 CXL 设备的 node 1；每个 vCPU
使用一个不同的物理核，不使用 SMT sibling。4 MiB capsule、sealed MoW、DAX extent、
guest 内存和计时边界保持不变。

主扩核曲线对每个配置运行 `remote-cxlfork` 5次30秒测量，和 Cohort 的每系统五轮
保持一致。`remote-target-local` 是可选的双 OS 内部对照，不应被误算成 CXLfork 的另外
五轮；已完成的8核点和历史32核点保留该对照，其他点可通过 `CXSP_MODES=cxlfork`
省略。prepare 位于 steady-state 计时外。结果同时保存逐请求 raw CSV、每轮 lps、
breakdown、拓扑、dmesg 和环境 manifest。

## Runner 参数

仍只使用 `scripts/run-cxlfork-spawn.sh`。扩核所需的覆盖参数为：

- `CXSP_SMP`：每个 VM 的 vCPU 数；
- `CXSP_VM0_HOST_CPUS`、`CXSP_VM1_HOST_CPUS`：两个 VM 的 host CPU 集；
- `CXSP_VM0_MEMORY_NODE`、`CXSP_VM1_MEMORY_NODE`：私有 DRAM NUMA 绑定；
- `CXSP_LANES`：并发 remote-spawn lane 数。
- `CXSP_MODES`：要测的路径；主扩核实验使用 `cxlfork`。

runner 会拒绝 CPU 集数量与 `CXSP_SMP` 不等、两个 CPU 集重叠、lanes 超过目标
VM vCPU 的配置。guest 启动后还会核对 `nproc`，manifest 会记录全部配置。

已有的32总 vCPU正式结果使用 VM0/VM1 都在 node 1 的历史 pinning。若把它和新结果
组合，只能明确标为复用点；严格的同拓扑扩展曲线应在 node0+node1布局下重跑32点。
