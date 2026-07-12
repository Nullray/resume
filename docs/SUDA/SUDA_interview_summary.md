# SUDA 项目面试总结

本文面向面试复习，重点总结 SUDA 项目的项目定位、整体逻辑、关键文件、核心机制、重要代码位置，以及面试官可能追问的问题和回答思路。

## 1. 项目一句话

SUDA 是一个面向 SoC-FPGA 计算存储设备（Computational Storage Device, CSD）的原型系统。它把靠近存储侧的数据处理任务下推到板卡上的 SoC 和 FPGA，主机通过 NVMe Computational Storage 风格的命令控制设备侧内存、程序加载和算子执行。

面试时可以这样讲：

> 我做的是一个 SoC-FPGA 计算存储设备原型。项目核心是把主机应用的计算请求封装成 NVMe 风格命令，经 libnvme/liburing、内核 nvmq/qdma 驱动传到板卡；板卡侧 SPDK/MCDMA 软件栈解析命令，并调度 SoC 软件算子或 FPGA 硬件算子执行。系统还实现了 FPGA 算子的轻量级上下文切换、辅助调度器和统一 HLS 算子开发路径。

## 2. 项目要解决的问题

传统主机侧计算需要把数据从 SSD 读回 CPU 再处理，瓶颈主要在主机-存储带宽、CPU 占用和 I/O 延迟。SUDA 的思路是让数据尽量留在存储侧，计算靠近数据执行。

项目重点解决两类问题：

- 运行时问题：FPGA 算子传统上更像 FIFO 流水线，缺少可抢占调度和上下文切换能力。SUDA 通过 OperatorController 和辅助调度器支持任务申请、挂起、恢复、释放。
- 开发问题：SoC 和 FPGA 协同开发复杂。SUDA 用统一的 HLS 算子接口，使算子既能编译成 FPGA 硬件算子，也能作为 SoC 侧动态库软件算子加载执行。

## 3. 目录结构与职责

- `README_EN.md`：项目背景、架构、部署、运行示例。
- `docs/architecture/SUDAArch.md`：架构主链路、主机驱动、设备侧软件栈、硬件调度器说明。
- `docs/api/APIReference.md`：SUDA 底层 API，包括内存范围集、程序加载、程序执行、SLM 读写拷贝。
- `host/api/libnvme/`：扩展 libnvme，新增 SUDA/NVMe CS 风格 API。
- `host/api/liburing/`：用于异步命令下发。
- `host/drivers/nvmq/`：主机侧 SUDA NVMe 队列驱动，负责 ioctl、block request、地址映射和 qdma 提交。
- `host/drivers/qdma/`：Xilinx QDMA 驱动依赖。
- `host/applications/`：示例应用，包括 Blowfish FPGA offload、Grep 软件算子、SLM copy。
- `device/platform/software_stack/nf_spdk/`：设备 SoC 侧 SPDK 派生软件栈，处理 MCDMA/NVMe 命令和计算调度。
- `device/platform/ips/`：FPGA 侧自定义 IP，包括 OperatorController 和 HLS 辅助调度器。
- `device/operators/hls/`：HLS 算子示例，如 `blowfish`、`grep`、`knn`。
- `device/shared_components/hls/`：HLS 公共类型、流模型、调度命令结构。

## 4. 整体执行链路

主链路可以按 7 步讲：

1. 主机应用调用 SUDA API，例如创建 memory range set、加载程序、执行程序、SLM 读写。
2. libnvme 把 API 调用封装成 NVMe passthrough 命令；同步路径走 ioctl，异步路径用 io_uring 写 `/dev/ng0n1`。
3. 主机内核 nvmq 驱动接收命令，把用户态 buffer 映射到 block request，并把数据地址整理成 SGL/PRP。
4. qdma 驱动把 NVMe 命令和必要 payload 通过 PCIe/QDMA 发到 SoC-FPGA CSD。
5. 设备侧 FPGA/MCDMA 将命令流写入设备内存，SPDK poller 轮询并进入 `nvmf_mcdma_request_process`。
6. 设备侧软件栈根据 opcode 分发：SLM read/write/copy/fill 走设备内存搬运；program execute 创建计算请求并交给 hlsacccompute 调度器。
7. 调度器选择软件算子或 FPGA 算子执行；FPGA 路径通过辅助调度器和 OperatorController 控制算子、上下文和数据流，完成后回收资源并触发下一轮调度。

一条面试中好用的请求路径：

`vscode-blowfish-offload.cpp` -> `nvme_execute_hlsacc_program()` -> `nvmq_user_cmd()` -> `nvmq_submit_user_cmd()` -> `nvme_qdma_queue_rq()` -> `nvmf_mcdma_request_process()` -> `spdk_hlsacccompute_run_request()` -> `execute_sqe()` -> `AssScheduler()` -> `OperatorController` -> HLS `blowfish()`。

## 5. 关键代码位置

### 5.1 应用和 API

- `host/applications/vscode-blowfish-offload/vscode-blowfish-offload.cpp:305`：Blowfish 示例主函数。
- `host/applications/vscode-blowfish-offload/vscode-blowfish-offload.cpp:419`：加载 HLS 程序。
- `host/applications/vscode-blowfish-offload/vscode-blowfish-offload.cpp:427`：激活程序。
- `host/applications/vscode-blowfish-offload/vscode-blowfish-offload.cpp:450`：创建 memory range set。
- `host/applications/vscode-blowfish-offload/vscode-blowfish-offload.cpp:531`：同步执行 FPGA Blowfish 程序。
- `host/applications/vscode-blowfish-offload/vscode-blowfish-offload.cpp:545`：从设备内存读回结果。
- `host/applications/vscode-grep-sw/vscode-grep-sw.cpp:299`：加载 Grep 软件算子动态库。
- `host/applications/vscode-grep-sw/vscode-grep-sw.cpp:357`：通过 `nvme_execute_hlsacc_programV2` 以软件路径执行。
- `host/applications/vscode-slmcopy-test/vscode-slmcopy-test.cpp:108`：SLM 写入。
- `host/applications/vscode-slmcopy-test/vscode-slmcopy-test.cpp:116`：SLM 读取。
- `host/api/libnvme/src/nvme/ioctl.h:4316`：`nvme_operate_memory_range_set` 内联封装。
- `host/api/libnvme/src/nvme/ioctl.c:2651`：`nvme_execute_hlsacc_program`。
- `host/api/libnvme/src/nvme/ioctl.c:2674`：`nvme_execute_hlsacc_programV2`，多了 `run_way`。
- `host/api/libnvme/src/nvme/ioctl.c:2697`：`nvme_load_hlsacc_program`，按 4KB 分片加载程序。
- `host/api/libnvme/src/nvme/ioctl.c:2747`：`nvme_slm_read`。
- `host/api/libnvme/src/nvme/ioctl.c:2763`：`nvme_slm_write`。
- `host/api/libnvme/src/nvme/ioctl.c:129`：`nvme_submit_passthru`，最终通过 ioctl 提交。

### 5.2 主机驱动

- `host/drivers/nvmq/core.c:1262`：`nvmq_submit_user_cmd`，把用户命令转为 request。
- `host/drivers/nvmq/core.c:1222` 和 `host/drivers/nvmq/core.c:1289`：SLM read/write 使用自定义 `nvmq_blk_rq_map_user` 支持更大数据映射。
- `host/drivers/nvmq/core.c:1891`：`nvmq_user_cmd`，同步 ioctl 入口。
- `host/drivers/nvmq/core.c:2109`：`nvmq_ioctl`，命名空间设备 ioctl。
- `host/drivers/nvmq/core.c:3523`：`nvmq_dev_ioctl`，管理设备 ioctl。
- `host/drivers/nvmq/core.c:3676`：`nvmq_ns_chr_write_iter`，异步 io_uring 写 `/dev/ng0n1` 的入口。
- `host/drivers/nvmq/qdma.c:3286`：`nvme_qdma_queue_rq`，block request 进入 QDMA 的核心函数。
- `host/drivers/nvmq/qdma.c:2330`：`nvme_qdma_map_data`，将请求数据映射成传输描述。
- `host/drivers/nvmq/qdma.c:2291`：`nvme_qdma_map_sg_inline`，admin/fabrics 等特殊命令将 payload inline 到 QDMA 请求。
- `host/drivers/nvmq/qdma.c:2730`：`nvme_qdma_post_next_rsp`，提前 post 接收响应。
- `host/drivers/nvmq/qdma.c:2523`：`nvme_qdma_post_send`，发送命令到设备。

### 5.3 设备侧软件栈

- `device/platform/software_stack/nf_spdk/lib/nvmf/mcdma.c:4720`：`nvmf_mcdma_poller_poll`，轮询 MCDMA 队列。
- `device/platform/software_stack/nf_spdk/lib/nvmf/mcdma.c:2002`：`nvmf_mcdma_qpair_process_pending`，处理 pending 命令。
- `device/platform/software_stack/nf_spdk/lib/nvmf/mcdma.c:2396`：`nvmf_mcdma_request_process`，设备侧命令状态机核心。
- `device/platform/software_stack/nf_spdk/lib/nvmf/mcdma.c:2736`：SLM read/write/copy/fill 分发。
- `device/platform/software_stack/nf_spdk/lib/nvmf/mcdma.c:3015`：program execute 根据优先级提交到可抢占或不可抢占执行路径。
- `device/platform/software_stack/nf_spdk/lib/hlsacccompute/hlsacccompute.c:371`：读取 `config.json` 初始化 FPGA 算子池。
- `device/platform/software_stack/nf_spdk/lib/hlsacccompute/hlsacccompute.c:308`：解析 operators 数组。
- `device/platform/software_stack/nf_spdk/lib/hlsacccompute/hlsacccompute.c:630`：`execute_sqe`，写 FPGA 辅助调度器 SQ ring。
- `device/platform/software_stack/nf_spdk/lib/hlsacccompute/hlsacccompute.c:696`：`id_remap`，把逻辑算子 ID 映射到真实 slot/channel。
- `device/platform/software_stack/nf_spdk/lib/hlsacccompute/hlsacccompute.c:919`：`__spdk_hlsacccompute_run_request`，计算请求调度核心。
- `device/platform/software_stack/nf_spdk/lib/hlsacccompute/hlsacccompute.c:1231`：申请 FPGA 算子，提交 APPLY SQE。
- `device/platform/software_stack/nf_spdk/lib/hlsacccompute/hlsacccompute.c:1270` 和 `:1275`：算子申请后启动 RX/TX DMA channel。
- `device/platform/software_stack/nf_spdk/lib/hlsacccompute/hlsacccompute.c:1469`：`spdk_hlsacccompute_free_request`，回收上下文、通道、virtual object。
- `device/platform/software_stack/nf_spdk/lib/hlsacccompute/hlsacccompute.c:1590`：`spdk_hlsacccompute_schedule_request`，资源释放后触发下一轮调度。

### 5.4 FPGA/HLS

- `device/platform/ips/rtl/OperatorController.v:28`：OperatorController 顶层模块。
- `device/platform/ips/rtl/OperatorController.v:606`：控制器状态机主要状态转换。
- `device/platform/ips/rtl/OperatorController.v:715`：`ap_start` 控制，暂停阶段会抑制算子继续执行。
- `device/platform/ips/rtl/OperatorController.v:723`：每个数据流通道对应 FIFO。
- `device/platform/ips/hls/hlsacc_assscheduler/hlsacc_assscheduler.cpp:569`：`AssScheduler` 顶层函数。
- `device/platform/ips/hls/hlsacc_assscheduler/hlsacc_assscheduler.cpp:52`：读取 SQE 并转发控制请求。
- `device/platform/ips/hls/hlsacc_assscheduler/hlsacc_assscheduler.cpp:63`：`outstanding_cmd_num` 统计批量控制命令完成情况。
- `device/platform/ips/hls/hlsacc_assscheduler/hlsacc_assscheduler.cpp:184`：写 CQE 给软件调度器。
- `device/shared_components/hls/hlsacc_types.hpp:136`：辅助调度命令 opcode。
- `device/shared_components/hls/hlsacc_types.hpp:146`：`AssSchedCmd` 命令结构。
- `device/shared_components/hls/hlsacc_types.hpp:182`：`AssSchedRet` 完成结构。
- `device/shared_components/hls/hlsacc_types.hpp:207`：`AccContext` 上下文结构。
- `device/operators/hls/blowfish/blowfish.cpp:42`：Blowfish HLS 算子入口。
- `device/operators/hls/grep/grep.cpp:7`：SimpleGrep HLS/软件算子入口。

## 6. 重要机制

### 6.1 统一 API 与 NVMe 风格命令

SUDA 底层 API 包括 memory range set、program load/unload/activate/deactivate、program execute、SLM read/write/copy/fill。应用不直接操作 FPGA，而是通过扩展 libnvme 生成 NVMe passthrough 风格命令。这样主机侧复用 NVMe 设备模型，设备侧也可以按 opcode 统一分发存储命令和计算命令。

### 6.2 同步和异步两条主机路径

同步路径走 ioctl：`nvme_submit_passthru` 调 `ioctl(fd, ioctl_cmd, cmd)`，进入 nvmq 驱动。

异步路径用 io_uring。由于项目验证内核是 5.4，无法像新内核一样直接用 io_uring 提交 uring cmd/ioctl，所以项目创建了 `/dev/ng0n1`，通过 io_uring `writev` 把 NVMe 命令写入字符设备，内核入口是 `nvmq_ns_chr_write_iter`。

补充概念：io_uring 的 SQ/CQ 是 Linux 用户态和内核之间的队列。SQ（Submission Queue）用于用户态提交 I/O 请求，CQ（Completion Queue）用于内核向用户态返回完成事件。

### 6.3 nvmq/qdma 地址映射与传输

nvmq 负责把用户态命令和 buffer 转成 block request。SLM read/write 走 `nvmq_blk_rq_map_user`，目的是突破普通路径对较大数据映射的限制。

qdma 负责把 request 中的 NVMe command、SGL/PRP 和 payload 发到设备。对于管理命令或 fabrics 命令，如果 payload 需要一起下发，会用 `nvme_qdma_map_sg_inline` 将 payload inline 到传输请求里。

### 6.4 设备侧 MCDMA/SPDK 命令状态机

设备侧 poller 轮询 MCDMA 队列，发现命令后进入 `nvmf_mcdma_request_process`。这个函数按 opcode 分发：

- SLM read/write：根据数据长度处理 1 页、2 页、多页 PRP list，并把搬运任务交给 `handc_thread`。
- SLM copy/fill：完成设备侧内存拷贝或填充。
- Program execute：查 memory range set、查 program、创建 `spdk_hlsacccompute_request`，绑定输入/输出 virtual object，然后交给计算线程。

### 6.5 软件算子与硬件算子统一调度

`run_way` 控制执行方式。`run_way == 1` 时尝试软件执行，要求程序只有一个输入、一个输出、一个算子，并且有 `software_data`；否则回退硬件路径。硬件路径则需要申请 FPGA 算子、通道和上下文。

Grep 示例就是软件算子路径：主机加载 `device/operators/hls/grep/libgrep.so`，再通过 `nvme_execute_hlsacc_programV2(..., run_way=1)` 执行。

### 6.6 FPGA 算子池、动态映射和抢占

设备侧 `config.json` 描述 FPGA 上已有算子，包括 `operator_type_id` 和 `slot_id`。同一种 `operator_type_id` 可以有多个实例，调度时通过 `id_remap` 把程序里的逻辑算子 ID 映射到真实 FPGA slot。

如果目标算子空闲，请求直接锁定资源并执行。若算子正在工作且请求允许抢占，则调度器生成 pause 请求，等待已有请求上下文保存完成，再执行新请求。

### 6.7 辅助调度器 SQ/CQ ring

SoC 软件调度器通过 BAR 映射访问 FPGA 辅助调度器的提交队列和完成队列。`execute_sqe` 写 SQE 并推进 `sq_tailer`；HLS `AssScheduler` 读取 SQE，向一个或多个 OperatorController 发控制命令，收齐响应后写 CQE 并推进 `cq_tailer`。

这个机制减少了 SoC 对多个 OperatorController 的轮询压力。软件只发一个批量 SQE，硬件内部并行控制多个 operator，并用 outstanding counter 判断批量命令是否全部完成。

### 6.8 OperatorController 上下文切换

OperatorController 是每个 FPGA 算子的控制器，负责接收 APPLY/SUSPEND/FREE 等控制命令、暂停数据流、保存 FIFO 和静态变量上下文、恢复新上下文、再启动算子。

上下文切换大体分四阶段：

1. 等待算子到达可抢占窗口。
2. 暂停 I/O 事务和算子工作。
3. 保存旧上下文并恢复新上下文，包括 FIFO 数据、静态变量、地址列表。
4. 恢复 I/O 和算子执行。

难点是流式 FPGA 算子没有天然“线程上下文”。项目把上下文拆成静态变量、FIFO 残留数据和数据流路由信息，通过控制器状态机在安全点保存和恢复。

### 6.9 计算完成信号

设备侧用 AXIS `TUSER == 0xff` 表示计算结束。这个结束包不作为普通数据处理，而是沿数据流传播到 MCDMA 接收通道。软件栈检测到该信号后触发 callback，调用 `spdk_hlsacccompute_free_request` 回收资源，并调度下一批等待请求。

因为结束标记也要占一个包，接收空间需要比预计输出多一页，避免结束信号没有空间返回。

## 7. 三个可讲示例

### 7.1 Blowfish FPGA offload

位置：`host/applications/vscode-blowfish-offload/vscode-blowfish-offload.cpp`

流程：构造 HLS program，加载并激活程序，创建输入/输出 memory range set，用 `nvme_slm_copy` 把存储数据拷到设备内存，调用 `nvme_execute_hlsacc_program` 执行 FPGA Blowfish，最后用 `nvme_slm_read` 读回输出。

适合展示端到端数据流和硬件算子调度。

### 7.2 Grep 软件算子

位置：`host/applications/vscode-grep-sw/vscode-grep-sw.cpp`

流程：读取测试数据和 pattern，创建 memory range set，打开 `device/operators/hls/grep/libgrep.so`，加载并激活 program，用 `nvme_execute_hlsacc_programV2(..., run_way=1)` 执行软件算子，从设备内存读回匹配结果。

适合展示统一编程模型和 SoC/FPGA 异构执行。

### 7.3 SLM copy test

位置：`host/applications/vscode-slmcopy-test/vscode-slmcopy-test.cpp`

流程：打开 `/dev/nvmq0`、`/dev/nvmq0n1`、`/dev/ng0n1`，使用 `nvme_slm_write` 写入设备内存，再用 `nvme_slm_read` 读回校验。

适合展示存储层内存命名空间和数据搬运机制。

## 8. 面试高频问题与回答

### Q1：这个项目的核心创新点是什么？

A：可以从两个层面讲。系统层面，SUDA 把计算存储设备抽象成 NVMe 风格的可编程设备，主机通过统一 API 管理内存范围、程序和执行请求。运行时层面，项目在 FPGA 算子池上实现了辅助调度器和 OperatorController，使流式算子支持申请、暂停、上下文保存、恢复和释放，为抢占式调度打基础。

### Q2：为什么不用普通 NVMe read/write，而要新增这些 API？

A：普通 NVMe read/write 只能表达块存储读写，无法表达“加载程序”“执行程序”“指定输入输出 memory range”“调度 FPGA 算子”这些计算语义。SUDA 用 NVMe passthrough 风格命令承载计算存储语义，既复用了 NVMe 设备模型，又能扩展 CS 场景需要的控制面。

### Q3：主机应用到 FPGA 算子的完整路径是什么？

A：应用调用 libnvme API，API 生成 NVMe command；同步路径通过 ioctl 进入 nvmq，异步路径通过 io_uring 写 `/dev/ng0n1`；nvmq 把用户 buffer 映射成 request；qdma 把 command/payload/PRP 发到设备；设备侧 MCDMA/SPDK poller 收到命令后解析 opcode；如果是 program execute，就创建 hlsacccompute request，申请算子和通道，写辅助调度器 SQE，最后由 OperatorController 启动 HLS 算子执行。

### Q4：nvmq 和 qdma 分别负责什么？

A：nvmq 更靠近 NVMe/block 语义，负责 ioctl、namespace、用户地址映射、request 创建。qdma 更靠近传输层，负责把 request 组织成 QDMA 能发送的 SGL/PRP/QE_DATA，并通过 PCIe/QDMA 发送给设备，同时 post 接收响应。

### Q5：为什么异步路径要用 `/dev/ng0n1`？

A：项目验证内核是 5.4，当时 io_uring 对 NVMe passthrough/uring cmd 支持不足，只能稳定地异步读写设备文件。项目将“提交命令”抽象成对特殊字符设备的 `writev`，这样应用仍能用 io_uring 异步提交，驱动再在 `nvmq_ns_chr_write_iter` 中解析并执行命令。

### Q6：memory range set 是什么？

A：它是计算请求的输入/输出内存描述。应用先把设备内存中的若干范围注册成一个 range set，program execute 只传 `rsid`，设备侧通过 `rsid` 查到输入输出 virtual object，然后把这些对象绑定到计算请求的 TX/RX 通道。

### Q7：SLM read/write/copy 和普通存储 I/O 有什么区别？

A：SLM 操作面向设备侧内存命名空间，不只是块设备读写。`nvme_slm_write` 把主机数据写到设备内存，`nvme_slm_read` 把设备内存读回主机，`nvme_slm_copy` 可以把存储 namespace 的数据搬到设备 memory namespace，让后续计算直接在设备侧数据上执行。

### Q8：FPGA 算子怎么被调度？

A：设备侧先根据 program 中的逻辑 operator type 查 `opconfigs`，找到可用的真实 operator slot。如果空闲就锁定并执行；如果被低优先级请求占用且允许抢占，就生成 pause 请求，等旧请求上下文保存完成后再执行新请求。执行时通过 `execute_sqe` 把 APPLY 命令写到辅助调度器 SQ ring。

### Q9：`id_remap` 解决了什么问题？

A：program 里写的是逻辑算子编号，但 FPGA 上真实部署的是 slot ID。`id_remap` 根据运行时选择的 `dynamic_id_map`，把 APPLY/Pause/Free 命令里的逻辑 ID 和通道目的地改成真实 slot/channel ID。这样 program 不需要提前绑定具体物理算子。

### Q10：辅助调度器为什么必要？

A：如果 SoC 软件直接控制多个 OperatorController，就需要频繁轮询每个控制器状态，软件栈压力较大。辅助调度器把多个控制命令打包成一个 SQE，在 FPGA 内部并行下发给多个控制器，并用 CQE 告诉软件“这一批控制完成了”，减少软件轮询和控制面开销。

### Q11：FPGA 上下文切换难在哪里？

A：流式 FPGA 算子不像 CPU 线程有天然寄存器上下文。切换时除了静态变量，还要处理 AXIS FIFO 中已经进入流水线但尚未处理完的数据、数据包长度、所属 FIFO、数据流路由和上下文地址。OperatorController 的状态机负责在可抢占窗口暂停算子，保存这些信息，再恢复新任务。

### Q12：怎么判断一个 FPGA 计算结束？

A：MCDMA 给算子输入数据流时会附带结束标记，当前实现用 AXIS `TUSER == 0xff` 表示结束。该标记穿过算子和互连返回接收通道，软件栈收到后触发完成回调、释放资源，并调度等待队列中的后续请求。

### Q13：软件算子和硬件算子如何统一？

A：它们共享 program、memory range、context、request 抽象。硬件路径申请 FPGA operator 和 DMA channel，软件路径从 `software_data` 加载动态库并分配 SoC 计算资源。应用侧仍然通过同一套 `nvme_load_hlsacc_program` 和 `nvme_execute_hlsacc_programV2` 调用。

### Q14：这个项目最大的工程挑战是什么？

A：挑战在跨层协同：用户态 API、内核驱动、QDMA 传输、设备侧 SPDK、FPGA 控制器必须对同一套命令格式、地址格式和状态机语义达成一致。任何一层对 buffer 长度、PRP/SGL、队列 tailer、上下文布局理解不一致都会导致难定位的问题。

### Q15：项目有哪些已知限制？

A：当前原型依赖特定硬件和内核环境，README 中说明主要验证在 Ubuntu 20.04、kernel 5.4.211 和 Fidus Sidewinder-100 上。部分路径存在硬编码，例如 `config.json` 路径。设备侧代码里也有 TODO，例如某些 namespace 支持和抢占时通道释放语义仍需完善。面试中可以把它表述为原型系统的工程边界和后续优化方向。

### Q16：如果让你继续优化，你会做什么？

A：我会优先做四件事：第一，收敛命令格式和错误码，完善文档化 ABI；第二，升级内核路径，利用更新内核的 io_uring uring cmd 能力简化 `/dev/ng0n1`；第三，完善调度策略，统一优先级阈值并增加公平性和 starvation 控制；第四，增加端到端 tracing，把应用请求 ID、NVMe CID、QDMA request、MCDMA request、FPGA SQE/CQE 串起来，提升调试效率。

## 9. 面试讲述顺序

建议按这个顺序讲，避免一开始陷入太多硬件细节：

1. 背景：主机-存储带宽和 CPU 占用是瓶颈，计算存储把计算下推。
2. 架构：host API/runtime、host driver、device SPDK control plane、SoC/FPGA operator pool。
3. 主链路：应用 API -> NVMe command -> nvmq/qdma -> MCDMA/SPDK -> hlsacccompute -> FPGA。
4. 重点机制：memory range set、program load/execute、算子池动态映射、辅助调度器、OperatorController 上下文切换。
5. 示例：Blowfish 展示 FPGA offload，Grep 展示软件算子统一模型。
6. 反思：原型限制、调试难点、后续优化。

## 10. 个人贡献表达模板

如果面试官问“你具体做了什么”，按你的真实参与情况从下面选择，不要全部硬套：

- 我参与了主机侧 SUDA API 的设计/使用，重点是把计算语义封装成 NVMe passthrough 命令。
- 我参与了 nvmq/qdma 驱动链路，处理用户态 buffer 映射、SLM 大块数据映射和 QDMA 命令发送。
- 我参与了设备侧 SPDK/MCDMA 命令分发，把 SLM 和 program execute 命令转成设备侧 request。
- 我参与了 hlsacccompute 调度器，实现算子池管理、优先级调度、抢占、通道申请和资源回收。
- 我参与了 FPGA 辅助调度器或 OperatorController，实现 SQ/CQ 控制、批量算子控制和上下文切换。
- 我参与了 HLS 算子和示例应用，用 Blowfish/Grep/SLM copy 验证端到端路径。

## 11. 快速复习清单

- 能用 1 分钟讲清楚 SUDA 是什么。
- 能画出 API 到 FPGA 算子的完整链路。
- 能解释 `memory range set`、`program execute`、`run_way`、`id_remap`。
- 能说明 nvmq 和 qdma 的职责边界。
- 能讲清楚为什么有 `/dev/ng0n1` 异步路径。
- 能讲清楚辅助调度器 SQ/CQ ring 的作用。
- 能讲清楚 OperatorController 如何做上下文保存/恢复。
- 能指出至少 5 个关键代码位置。
- 能讲一个端到端示例：推荐 Blowfish。
- 能诚实说明原型限制和下一步优化。
