# SUDA 端到端流程精讲：以 Blowfish Offload 为例

本文把 SUDA 的关键代码按一次完整请求串起来。主线使用 `vscode-blowfish-offload` 示例，并在“加载程序”步骤中插入 `QE_DATA / inline payload` 的细节解释。

## 1. 一句话主链路

`vscode-blowfish-offload.cpp` 发起请求，`libnvme` 把请求封装成 NVMe passthrough 命令，`nvmq` 把用户态命令转成 block request，`qdma` 把命令和数据经 PCIe/QDMA 发到设备侧，设备侧 `MCDMA/SPDK` 解析命令，`hlsacccompute` 创建并调度计算请求，最后由 FPGA 辅助调度器和 `OperatorController` 控制 HLS Blowfish 算子执行。

简化链路：

```text
host application
  -> libnvme ioctl API
  -> nvmq ioctl / request mapping
  -> qdma request submit
  -> device MCDMA / SPDK command process
  -> hlsacccompute scheduler
  -> FPGA AssScheduler / OperatorController
  -> HLS blowfish operator
```

## 2. Step 0：打开 SUDA 设备

代码位置：

- `host/applications/vscode-blowfish-offload/vscode-blowfish-offload.cpp:323`
- `host/applications/vscode-blowfish-offload/vscode-blowfish-offload.cpp:324`

应用打开两个设备：

```cpp
int io_fd = nvme_open("nvmq0n1");
int admin_fd = nvme_open("nvmq0");
```

含义：

- `admin_fd` 对应 controller/admin 设备，主要用来发管理命令，例如 program load、program activate、memory range set create。
- `io_fd` 对应 namespace 设备，主要用来发 IO/计算相关命令，例如 SLM copy/read 和 program execute。

这也是后面区分 admin queue 和 IO queue 的基础。NVMe 里 `qid == 0` 通常是 admin queue。

## 3. Step 1：构造并加载 Blowfish 程序

应用侧位置：

- `host/applications/vscode-blowfish-offload/vscode-blowfish-offload.cpp:419`

应用调用：

```cpp
ret = nvme_load_hlsacc_program(admin_fd, psize, 1, 2, program);
```

这里的关键参数：

- `admin_fd`：通过 admin queue 下发程序管理命令。
- `psize`：program 描述结构大小。
- `pind = 1`：程序索引，后续 execute 时用这个 ID 找程序。
- `nsid = 2`：计算相关 namespace。
- `program`：描述 Blowfish 程序如何申请算子、如何连接输入输出通道、如何暂停/释放算子。

进入 libnvme：

- `host/api/libnvme/src/nvme/ioctl.c:2697`

`nvme_load_hlsacc_program` 会按 4KB 分片加载 program：

```c
int numb = psize > 4096 ? 4096 : psize;
int ret = nvme_operate_program(..., numb, 0, ..., program_data, ...);

while (offset < psize) {
    numb = (psize - offset) > 4096 ? 4096 : (psize - offset);
    ret = nvme_operate_program(..., numb, offset, ..., program_data + offset, ...);
}
```

为什么要分片：NVMe admin 命令携带的 inline payload 有尺寸约束，项目里按页大小分片，设备侧逐片接收并组装/记录 program 数据。

## 4. Step 1.1：Program Load 为什么是 `QE_DATA`

这是主机 QDMA 层最容易被问到的细节。

相关代码：

- `host/drivers/nvmq/qdma.c:202`：`enum nvmq_map_option`
- `host/drivers/nvmq/qdma.c:3406`：识别 `0x85 // load_program`
- `host/drivers/nvmq/qdma.c:3430`：选择 `option = QE_DATA`
- `host/drivers/nvmq/qdma.c:3435`：调用 `map_nvmq_req_to_sg`
- `host/drivers/nvmq/qdma.c:3443`：调用 `nvme_qdma_map_sg_inline`
- `host/drivers/nvmq/qdma.c:3460`：调用 `nvme_qdma_post_send`

`qdma.c` 里有内部枚举：

```c
enum nvmq_map_option {
    QE,
    DATA,
    QE_DATA
};
```

它不是 NVMe 标准字段，而是 nvmq/qdma 驱动内部的 QDMA scatter-gather 映射策略：

- `QE`：只发送 NVMe command，也就是 queue entry。
- `DATA`：只发送 request payload。
- `QE_DATA`：把 NVMe command 和 payload 放进同一个 QDMA request 一起发。

Program load 对应 opcode `0x85`。在 `types.h` 中它是：

- `host/api/libnvme/src/nvme/types.h:6823`

```c
nvme_admin_load_program = 0x85
```

在 QDMA 层，驱动识别这个命令：

```c
case 0x85: // load_program
    special_command_sel = (((c->common.cdw10 >> 24) & 0x1) == 0);
    special_command_sel = special_command_sel && queue->qid == 0;
    break;
```

重点是：

```c
queue->qid == 0
```

`qid == 0` 说明这是 admin queue 命令。Program load 是控制面命令，payload 不是普通块数据，而是 program 描述或程序片段。设备侧希望“命令 + 程序数据”一起到达，所以这里选择：

```c
option = (nvme_is_fabrics(c) || special_command_sel) ? QE_DATA : QE;
```

也就是说：对于 program load 这种特殊 admin 命令，用 `QE_DATA`。

## 5. Step 1.2：`QE_DATA` 如何组织 QDMA SGL

相关代码：

- `host/drivers/nvmq/qdma.c:2248`：`map_nvmq_req_to_sg`
- `host/drivers/nvmq/qdma.c:2234`：`nvme_qdma_qe_to_sg`

`QE_DATA` 分支逻辑是：

```c
case QE_DATA:
    list_for_each_entry(qe, &req->sqe_list, entry) {
        cnt += nvme_qdma_qe_to_sg(qe, sg, sqe);
    }
    if (blk_rq_nr_phys_segments(rq) > 0) {
        sg = qdma_next_sg(sg, true);
        cnt += blk_qd_map_qdma_sg(NULL, q, rq, sg, true, DMA_TO_DEVICE);
    }
    break;
```

这段做了两件事：

1. 先把 NVMe command 映射成第一个 QDMA SG 段。
2. 再把 request payload 映射成后续 QDMA SG 段。

`nvme_qdma_qe_to_sg` 对命令段的映射是：

```c
sg->pg = virt_to_page(sqe->qe_data);
sg->len = sizeof(struct nvme_command);
sg->offset = (uintptr_t)sqe->qe_data & (PAGE_SIZE - 1);
```

所以 `QE_DATA` 下的 QDMA SGL 可以理解成：

```text
qdma_req->sgl[0]    = NVMe command / QE
qdma_req->sgl[1..n] = payload data
```

对于 program load，payload 就是 `program_data` 的某个 4KB 分片。

## 6. Step 1.3：`nvme_qdma_map_sg_inline` 如何告诉设备 payload 在哪里

相关代码：

- `host/drivers/nvmq/qdma.c:2291`

`nvme_qdma_map_sg_inline` 不负责再次复制 payload，它负责修改 NVMe command 里的 SGL descriptor，让设备知道 payload 是 inline data。

核心代码：

```c
struct nvme_sgl_desc *sg = &c->common.dptr.sgl;
struct qdma_sw_sg *sgl = &qdma_req->sgl[1];

for (i = 1; i < count; i++, sgl++) {
    len += sgl->len;
}

sg->addr = cpu_to_le64(queue->ctrl->ctrl.icdoff);
sg->length = cpu_to_le32(len);
sg->type = (NVME_SGL_FMT_DATA_DESC << 4) | NVME_SGL_FMT_OFFSET;
```

含义：

- `qdma_req->sgl[0]` 是 NVMe command。
- `qdma_req->sgl[1..]` 是 inline payload。
- `len` 是 payload 总长度。
- `sg->addr = icdoff` 表示 payload 在 command capsule 内的 inline data offset。
- `sg->length = len` 表示 inline payload 长度。
- `sg->type = OFFSET` 表示这个 SGL 不是普通物理地址，而是相对 capsule 的 offset。

所以设备侧收到命令后，看 command 里的 SGL descriptor，就知道 program data 跟在命令后面，不需要再根据 PRP 从主机内存拉取。

## 7. Step 1.4：`nvme_qdma_post_send` 真正提交给 QDMA

相关代码：

- `host/drivers/nvmq/qdma.c:2523`
- `host/drivers/nvmq/qdma.c:3460`

`nvme_qdma_post_send` 最终调用：

```c
ret = qdma_request_submit(dev_hndl, queue->qe_qp.h2c_qhndl, qdma_req);
```

这里的方向是 H2C，也就是 Host to Card。到这里，program load 的 QDMA request 已经包含：

```text
load_program admin command + inline program_data fragment
```

面试时可以这样总结：

> `QE_DATA` 是主机 qdma 驱动内部的映射策略，表示这个 QDMA request 同时包含 NVMe 命令和命令携带的数据。Program load 是 admin queue 上的特殊控制命令，程序数据需要随命令一起到设备侧，所以驱动把 `program_data` 映射到 command 后面的 inline data 区域，并通过 `nvme_qdma_map_sg_inline` 在 NVMe command 的 SGL 字段里写入 offset 和长度。最后 `nvme_qdma_post_send` 把整个 `qdma_req` 通过 H2C QDMA 队列发送到 CSD。

## 8. Step 2：激活程序

应用侧位置：

- `host/applications/vscode-blowfish-offload/vscode-blowfish-offload.cpp:427`

调用：

```cpp
ret = nvme_activate_program(admin_fd, 1, 2);
```

进入：

- `host/api/libnvme/src/nvme/ioctl.c:2728`

激活程序也是 admin 管理命令。设备侧收到后会把 program 标记为可执行，后续 `program execute` 才能通过 `pind = 1` 找到这个程序。

设备侧处理 program activation 的位置：

- `device/platform/software_stack/nf_spdk/lib/nvmf/mcdma.c:2714`

## 9. Step 3：创建 Memory Range Set

应用侧位置：

- `host/applications/vscode-blowfish-offload/vscode-blowfish-offload.cpp:450`

调用：

```cpp
ret = nvme_create_memory_range_set(admin_fd, 2, &rsid, 2, mdes);
```

`mdes[0]` 描述输入设备内存，`mdes[1]` 描述输出设备内存。返回的 `rsid` 是后续执行程序时的输入输出集合 ID。

面试表达：

> Memory range set 是计算请求的输入/输出内存描述。应用先把设备侧内存范围注册成一个集合，后续 execute 只传 `rsid`，设备侧通过 `rsid` 找到输入输出 virtual object 并绑定到计算请求。

## 10. Step 4：把 SSD 数据拷贝到 SLM / 设备侧内存

应用侧位置：

- `host/applications/vscode-blowfish-offload/vscode-blowfish-offload.cpp:514`

调用：

```cpp
ret = nvme_slm_copy(io_fd, sr, sizeof(union nvme_source_range) * 8,
                    0, 0x3, 8, input_mem_id);
```

这里的含义：

- `sr[j].scc.snsid = 1`：源 storage namespace 是 1。
- `input_mem_id`：目标是设备侧 memory namespace。
- 目的：把 SSD 上的数据搬到 FPGA/SoC 更近的设备侧内存，让后续计算不需要再从主机拉数据。

libnvme 封装位置：

- `host/api/libnvme/src/nvme/ioctl.c:2778`

设备侧 SLM copy/read/write 分发位置：

- `device/platform/software_stack/nf_spdk/lib/nvmf/mcdma.c:2737`
- `device/platform/software_stack/nf_spdk/lib/nvmf/mcdma.c:2874`

## 11. Step 5：执行 Blowfish 程序

应用侧位置：

- `host/applications/vscode-blowfish-offload/vscode-blowfish-offload.cpp:531`

调用：

```cpp
ret = nvme_execute_hlsacc_program(io_fd, 2, rsid, 1,
                                  context_data, 0, 0, 0, &res);
```

关键参数：

- `io_fd`：执行是 IO/计算路径，不是 admin 路径。
- `nsid = 2`：计算 namespace。
- `rsid`：前面创建的 memory range set。
- `pind = 1`：前面加载并激活的 Blowfish program。
- `priority = 0`：优先级。

libnvme 封装位置：

- `host/api/libnvme/src/nvme/ioctl.c:2651`

`nvme_execute_hlsacc_program` 会构造 program execute 命令，最终仍然通过 `nvme_submit_passthru` 走 ioctl 进入内核。

## 12. Step 6：libnvme 通过 ioctl 进入 nvmq

共同提交入口：

- `host/api/libnvme/src/nvme/ioctl.c:129`

核心动作：

```c
err = ioctl(fd, ioctl_cmd, cmd);
```

然后进入 nvmq：

- `host/drivers/nvmq/core.c:3523`：`nvmq_dev_ioctl`，处理 admin 设备。
- `host/drivers/nvmq/core.c:2109`：`nvmq_ioctl`，处理 namespace 设备。
- `host/drivers/nvmq/core.c:1891`：`nvmq_user_cmd`，把用户态 passthrough 命令复制进内核。
- `host/drivers/nvmq/core.c:1262`：`nvmq_submit_user_cmd`，创建 request 并映射用户 buffer。

对 SLM read/write，代码会走自定义映射：

- `host/drivers/nvmq/core.c:1289`

```c
if (nvme_is_slm_rw(cmd)) {
    ret = nvmq_blk_rq_map_user(q, req, NULL, ubuffer, bufflen, GFP_KERNEL);
} else {
    ret = blk_rq_map_user(q, req, NULL, ubuffer, bufflen, GFP_KERNEL);
}
```

这是为了支持更大的 SLM 数据搬运 buffer。

## 13. Step 7：nvmq request 进入 qdma

核心入口：

- `host/drivers/nvmq/qdma.c:3286`

`nvme_qdma_queue_rq` 做几件事：

1. 从 request 中取出 NVMe command。
2. 调 `nvme_qdma_map_data` 映射数据。
3. 调 `nvme_qdma_post_next_rsp` 预先 post 接收响应。
4. 根据 opcode 和 queue id 选择 `QE` 或 `QE_DATA`。
5. 组装 `qdma_req->sgl`。
6. 调 `nvme_qdma_post_send` 发送到设备。

关键位置：

- `host/drivers/nvmq/qdma.c:3375`：`nvme_qdma_map_data`
- `host/drivers/nvmq/qdma.c:3395`：`nvme_qdma_post_next_rsp`
- `host/drivers/nvmq/qdma.c:3430`：选择 `option`
- `host/drivers/nvmq/qdma.c:3460`：发送

## 14. Step 8：设备侧 MCDMA/SPDK 收到命令

设备侧轮询入口：

- `device/platform/software_stack/nf_spdk/lib/nvmf/mcdma.c:4720`

`nvmf_mcdma_poller_poll` 轮询 MCDMA 队列。

pending 命令处理：

- `device/platform/software_stack/nf_spdk/lib/nvmf/mcdma.c:2002`

真正命令分发：

- `device/platform/software_stack/nf_spdk/lib/nvmf/mcdma.c:2396`

`nvmf_mcdma_request_process` 根据 opcode 做不同处理：

- SLM read/write/copy/fill：做设备侧内存搬运。
- Program load：接收并记录 program 数据。
- Program activation：激活 program。
- Program execute：创建计算请求。

Program execute 分支位置：

- `device/platform/software_stack/nf_spdk/lib/nvmf/mcdma.c:2923`

在这个分支里，设备侧会：

1. 从命令中取出 `rsid`、`pind`、`priority` 等。
2. 通过 `rsid` 查 memory range set。
3. 通过 `pind` 找 program。
4. 创建 `spdk_hlsacccompute_request`。
5. 绑定输入/输出 virtual object。
6. 把请求发给 compute thread。

创建请求位置：

- `device/platform/software_stack/nf_spdk/lib/nvmf/mcdma.c:2969`

提交到计算线程：

- `device/platform/software_stack/nf_spdk/lib/nvmf/mcdma.c:3015`
- `device/platform/software_stack/nf_spdk/lib/nvmf/mcdma.c:3017`

## 15. Step 9：hlsacccompute 调度 FPGA 算子

核心入口：

- `device/platform/software_stack/nf_spdk/lib/hlsacccompute/hlsacccompute.c:919`

`__spdk_hlsacccompute_run_request` 做的事：

1. 根据 program 需要的 operator type 查 `opconfigs`。
2. 从同类算子池中选择真实 FPGA slot。
3. 如果目标算子空闲，直接锁定。
4. 如果目标算子忙，并且允许抢占，生成 pause 请求。
5. 为输入/输出申请 DMA channel。
6. 用 `id_remap` 把逻辑算子 ID 映射成真实 slot/channel。
7. 调 `execute_sqe` 写 FPGA 辅助调度器 SQ ring。

关键位置：

- `device/platform/software_stack/nf_spdk/lib/hlsacccompute/hlsacccompute.c:371`：初始化算子池配置。
- `device/platform/software_stack/nf_spdk/lib/hlsacccompute/hlsacccompute.c:696`：`id_remap`。
- `device/platform/software_stack/nf_spdk/lib/hlsacccompute/hlsacccompute.c:1194`：对 apply/pause/free 命令做 remap。
- `device/platform/software_stack/nf_spdk/lib/hlsacccompute/hlsacccompute.c:1231`：提交 APPLY SQE。
- `device/platform/software_stack/nf_spdk/lib/hlsacccompute/hlsacccompute.c:1270`：启动 RX channel。
- `device/platform/software_stack/nf_spdk/lib/hlsacccompute/hlsacccompute.c:1275`：启动 TX channel。

## 16. Step 10：FPGA AssScheduler 和 OperatorController

辅助调度器位置：

- `device/platform/ips/hls/hlsacc_assscheduler/hlsacc_assscheduler.cpp:569`

`AssScheduler` 通过 SQ/CQ ring 和 SoC 软件调度器交互：

- `sq_header` / `sq_tailer`：提交队列指针。
- `cq_header` / `cq_tailer`：完成队列指针。
- SQE：SoC 写入的控制命令。
- CQE：FPGA 写回的完成状态。

读取 SQE 的位置：

- `device/platform/ips/hls/hlsacc_assscheduler/hlsacc_assscheduler.cpp:53`

写 CQE 的位置：

- `device/platform/ips/hls/hlsacc_assscheduler/hlsacc_assscheduler.cpp:185`

OperatorController 顶层：

- `device/platform/ips/rtl/OperatorController.v:28`

状态机：

- `device/platform/ips/rtl/OperatorController.v:606`

`ap_start` 控制：

- `device/platform/ips/rtl/OperatorController.v:715`

它负责每个 FPGA 算子的申请、暂停、上下文保存、上下文恢复和继续执行。

## 17. Step 11：结果读回主机

应用侧位置：

- `host/applications/vscode-blowfish-offload/vscode-blowfish-offload.cpp:545`

调用：

```cpp
ret = nvme_slm_read(io_fd, output_mem_id,
                    j * LBA_SIZE * 32,
                    LBA_SIZE * 32,
                    output_buf + ...);
```

含义：从输出 memory namespace / SLM 把 FPGA 计算结果读回 host buffer。

## 18. 面试压缩版讲法

可以用下面这段作为面试回答：

> 以 Blowfish offload 为例，主机应用先打开 `nvmq0` 和 `nvmq0n1`，用 admin fd 加载并激活 program，用 memory range set 描述输入输出设备内存。加载 program 时，libnvme 把 program 分片封装成 opcode `0x85` 的 admin 命令；到 qdma 层，因为它是 qid 0 上的特殊 admin 命令，所以选择 `QE_DATA`，把 NVMe command 和 program payload 一起映射进 QDMA SGL，再用 `nvme_qdma_map_sg_inline` 在命令 SGL 字段写入 inline offset 和长度，最后通过 `nvme_qdma_post_send` 发到设备。执行时，应用通过 `nvme_execute_hlsacc_program` 下发 program execute，设备侧 MCDMA/SPDK 解析命令，查 `rsid` 和 `pind`，创建 hlsacccompute request。hlsacccompute 根据算子池状态选择真实 FPGA slot，必要时抢占旧任务，然后通过 `execute_sqe` 写 FPGA 辅助调度器 SQE。辅助调度器控制 OperatorController 启动 Blowfish HLS 算子，结果写回 SLM，主机最后用 `nvme_slm_read` 读回输出。

