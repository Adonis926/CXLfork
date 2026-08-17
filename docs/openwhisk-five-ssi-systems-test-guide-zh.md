**五个单一 OS 系统的 OpenWhisk 测试说明**  
**1. 测试目的**  
这组实验只比较下面五个系统中的 OpenWhisk 冷激活性能：  
- cohort：Cohort；  
- no-tiering：关闭内存分层的单一 OS；  
- starfish：Starfish-like；  
- native-cxl：普通 Linux 虚拟机使用 CXL 内存；  
- native-dram：普通 Linux 虚拟机只使用 DRAM。  
这里的“单一 OS 系统”强调的是应用只看到一个 Linux OS。Cohort、no-tiering 和 Starfish-like 的底层虽然可能由两个 QEMU 组成，但它们向 OpenWhisk 提供的是一个统一 OS；native-CXL 和 native-DRAM 则是普通的单 VM Linux。  
本测试五个系统运行同一个 OpenWhisk JAR、同一个 action 和相同的 CPU、内存及请求配置。  
**2. 测试内容**  
**2.1 Workload**  
OpenWhisk action 使用 state-scan-4m-v1：  
1. 创建并初始化 4 MiB 状态；  
2. 每个 4 KiB 页面读取一个 64-bit 数值；  
3. 计算固定 checksum 05ae28486824d617；  
4. 把 checksum 和执行时间返回给测试程序。  
checksum 用来证明每次请求确实执行了相同的业务，而不是只启动了一个空容器。  
**2.2 两种测试场景**  
每个“系统 × vCPU 数 × 轮次”都会 fresh boot，然后运行两种场景：  
- sequential：串行发送 200 个强制冷启动请求，主要观察单次请求延迟；  
- throughput：持续 30 秒发送强制冷启动请求，并发度为总 vCPU 数的一半，主要观察吞吐量。  
强制冷启动表示每个有效样本都使用一个新的 action 容器；脚本会检查 invocation=1、初始化次数和容器 ID，防止 warm 请求混入 cold 数据。  
正式核数为 8、16、32、64、80，每个配置重复 5 轮。每轮结束后关闭当前系统，下一个配置重新启动，避免不同系统共享残留的 OpenWhisk 或 Docker 运行状态。  
**3. 主要性能指标**  
汇报时主要看两个指标：  
1. **Cold E2E latency**：请求从测试程序发出，到收到 action 返回结果的总时间。通常报告 P50 和 P95；五轮合并得到 1000 个串行样本后才报告 P99。  
2. **Cold throughput**：30 秒并发测试中每秒完成的有效冷请求数，即 achieved_rps_mean。数值越大，说明单位时间内能创建和完成的函数越多。  
summary/summary.csv 保存这两个主指标及样本数量；summary/breakdown.csv 保存 API 调度、容器创建、状态初始化、函数执行和响应等细分时间。主图只需要使用 E2E latency 和 achieved RPS，breakdown 用来解释性能差异。  
**4. 103 服务器上的测试入口**  
代码目录：  
/home/xtl/cxlfork/openwhisk-state-action-eval  
   
唯一编排脚本：  
scripts/run-openwhisk-state-action-eval.sh  
   
它会调用已有的五个启动脚本，不重新实现 VM 生命周期：  
| | |  
|-|-|  
| **测试名称** | **实际复用的启动脚本** |   
| cohort | /home/xtl/start/hpca/start-cohort.sh |   
| no-tiering | /home/xtl/start/hpca/start-no-memory-tiering.sh |   
| starfish | /home/xtl/start/hpca/start-starfish-like.sh |   
| native-cxl | /home/xtl/start/hpca/start-native-cxl-vm.sh |   
| native-dram | /home/xtl/start/hpca/start-native-vm.sh |   
   
统一清理入口为 /home/xtl/start/hpca/kill-gvm.sh。  
**5. 手工测试命令**  
以下命令都在 xtl@10.0.16.103 上执行。启动前必须确认学长和其他用户没有使用该机器的 QEMU、KVM 或 /dev/dax0.0。  
**5.1 进入目录并做只读检查**  
cd /home/xtl/cxlfork/openwhisk-state-action-eval  
   
 env OWE_SYSTEMS="cohort no-tiering starfish native-cxl native-dram" \  
   scripts/run-openwhisk-state-action-eval.sh preflight  
   
看到 PREFLIGHT_OK 才能继续。  
**5.2 首次部署**  
103 当前已经完成过部署，正常情况下不要重复执行。只有专用磁盘或固定测试资产丢失时才运行：  
sudo env \  
   OWE_EXCLUSIVE_CONFIRM=I_HAVE_EXCLUSIVE_KVM_DAX_103 \  
   OWE_SYSTEMS="cohort no-tiering starfish native-cxl native-dram" \  
   scripts/run-openwhisk-state-action-eval.sh provision  
   
**5.3 运行一个 8-vCPU 小样**  
小样每个系统只运行一轮、20 个串行请求和 5 秒吞吐测试：  
PILOT=/home/xtl/start/hpca-openwhisk-eval/results/ssi-five-pilot-$(date -u +%Y%m%dT%H%M%SZ)  
   
 sudo env \  
   OWE_EXCLUSIVE_CONFIRM=I_HAVE_EXCLUSIVE_KVM_DAX_103 \  
   OWE_SYSTEMS="cohort no-tiering starfish native-cxl native-dram" \  
   OWE_REPS=1 \  
   OWE_SEQUENTIAL_REQUESTS=20 \  
   OWE_THROUGHPUT_SECONDS=5 \  
   scripts/run-openwhisk-state-action-eval.sh run "$PILOT" 8  
   
**5.4 运行正式矩阵**  
FORMAL=/home/xtl/start/hpca-openwhisk-eval/results/ssi-five-formal-$(date -u +%Y%m%dT%H%M%SZ)  
   
 sudo env \  
   OWE_EXCLUSIVE_CONFIRM=I_HAVE_EXCLUSIVE_KVM_DAX_103 \  
   OWE_SYSTEMS="cohort no-tiering starfish native-cxl native-dram" \  
   OWE_REPS=5 \  
   OWE_SEQUENTIAL_REQUESTS=200 \  
   OWE_THROUGHPUT_SECONDS=30 \  
   scripts/run-openwhisk-state-action-eval.sh run "$FORMAL" 8 16 32 64 80  
   
也可以只测指定核数，例如只测 32 和 64 vCPU：  
sudo env \  
   OWE_EXCLUSIVE_CONFIRM=I_HAVE_EXCLUSIVE_KVM_DAX_103 \  
   OWE_SYSTEMS="cohort no-tiering starfish native-cxl native-dram" \  
   OWE_REPS=5 \  
   OWE_SEQUENTIAL_REQUESTS=200 \  
   OWE_THROUGHPUT_SECONDS=30 \  
   scripts/run-openwhisk-state-action-eval.sh run "$FORMAL" 32 64  
   
注意：同一个结果目录会冻结系统列表、轮数和请求参数。恢复同一次实验时必须使用完全相同的环境参数，不能中途改变测试配置。  
**6. 暂停、恢复与查看进度**  
安全暂停是在 campaign 目录创建 STOP。脚本会完成并清理当前 tuple，然后停止：  
sudo touch "$FORMAL/STOP"  
   
恢复前删除 STOP，然后重新执行与首次完全相同的 run 命令。已经通过的 tuple 会被校验并跳过：  
sudo rm "$FORMAL/STOP"  
   
查看完成情况：  
env OWE_SYSTEMS="cohort no-tiering starfish native-cxl native-dram" \  
   scripts/run-openwhisk-state-action-eval.sh status "$FORMAL"  
   
重新生成汇总：  
scripts/run-openwhisk-state-action-eval.sh summarize "$FORMAL"  
   
生成一张只包含五系统核心指标的 CSV：  
scripts/export-openwhisk-five-system-core-csv.sh "$FORMAL"  
   
汇总工具会检查五个系统、全部核数、轮数、串行样本数和成功数是否完整。任何配置缺失时都会报错，不会生成一张看似完整但实际缺数据的表。  
   
**7. 结果在哪里、怎么看**  
一个正式 campaign 的主要目录如下：  
CAMPAIGN/  
 ├── controller.log  
 ├── runs/                       # 每次启动、串口和 guest 原始结果  
 ├── accepted/                   # 通过校验的有效 tuple  
 ├── state/ok/                   # 断点续跑状态  
 ├── summary/summary.csv         # 延迟和吞吐主结果  
 ├── summary/breakdown.csv       # 各阶段耗时  
 ├── summary/five-system-core-metrics.csv # 一张核心指标汇总表  
 ├── manifest/                   # 固定配置与环境信息  
 └── SHA256SUMS                  # 文件完整性校验  
   
最简单的查看命令：  
column -s, -t < "$FORMAL/summary/summary.csv" | less -S  
 column -s, -t < "$FORMAL/summary/breakdown.csv" | less -S  
 column -s, -t < "$FORMAL/summary/five-system-core-metrics.csv" | less -S  
   
核心表中每个“核数 × 系统”占一行，共 25 行。字段包括核数、系统、cold E2E 的 mean/P50/P95/P99，以及 cold throughput RPS。  
   
查看时先确认：  
- 五个系统、全部目标核数和五轮数据都存在；  
- successes 等于 samples；  
- checksum 全部为 05ae28486824d617；  
- 正式 sequential 数据五轮合并后，每个“系统 × 核数”有 1000 个有效样本；  
- 只有样本量达到约 1000 时才使用 P99。  
目前已经完成的 8-vCPU 小样备份位于本地：  
/home/adonis/cxlfork/openwhisk-eval-results/pilot-8vcpu-v7-20260817/  
   
该小样只用于确认五条路径能够运行和观察数量级，不能替代五轮正式矩阵。  
**8. 一句话概括测试方法**  
在相同总 vCPU 和内存预算下，依次 fresh boot 五种单一 OS 系统，让它们运行同一个 OpenWhisk 4 MiB state action；分别测量单请求强制冷启动延迟和并发冷启动吞吐，并用五轮原始数据比较不同 OS 架构的函数上下文创建能力。  
