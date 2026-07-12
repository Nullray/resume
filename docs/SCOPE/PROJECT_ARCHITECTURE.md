# 跨软硬件协同仿真与状态拦截系统架构解析

本项目实现了一个跨软硬件的协同仿真与状态拦截系统。核心链路是：**FPGA 硬件拦截总线事务 -> XDMA 通过 C2H DMA32 packet 把事件送到 x86/QEMU -> QEMU 解析并写回 ACK/响应 -> FPGA 按响应恢复或继续 AXI 事务**。

当前 `nexst_proxy_11` 的关键目标是：让 QEMU 作为真实 NVMe 的 proxy，可靠拦截 guest 对 NVMe BAR 的访问，解析并改写 Admin SQE 中的 DMA 地址，使真实 NVMe 通过 FPGA XDMA EP bypass BAR 进行 P2P DMA。为解决“QEMU 收到 SQ doorbell 后读到旧 SQE”的时序问题，当前版本使用 **BAR_WRITE_DONE + SQE_WRITE_DONE** 双事件闭环：QEMU 先让 guest 的 SQ doorbell MMIO 写完成，但只有同时看到 doorbell 的 BAR B 通道完成事件，以及 Admin SQE 写 DDR 的 B 通道完成事件后，才读取 SQE。为解决真实 NVMe/QEMU 与香山 CPU 对 SQ/CQ queue memory 视图不一致的问题，当前版本新增 **XDMA EP bypass coherent alias**：低 4GB raw bypass 保留给诊断访问，高 4GB alias 经 `u_role/s_axi_dma` 进入香山侧 DMA/coherency 入口；真实 NVMe DMA 地址 patch、QEMU 自身 SQE/CQE 读写默认都使用该 alias。当前版本还补充了真实 NVMe 控制器生命周期管理、Admin CQ 旧内容防护和 DMA32 ring 可靠消费机制，避免跨次测试残留状态干扰新的 guest 启动。

以下是项目中关键核心文件及其作用。

## 1. QEMU 侧：软件消费者与控制端

* **[qemu-mount/hw/misc/scope_fpga_proxy.c](qemu-mount/hw/misc/scope_fpga_proxy.c)**
  * **作用**：QEMU 自定义 PCI/虚拟设备，是 NVMe proxy 的软件状态机核心。
  * **功能详情**：
    1. 通过 XDMA 自定义 ioctl 分配 DMA32 ring，并将 ring `mmap` 到 QEMU 用户态。
    2. 启动 RX 线程轮询 DMA32 ring，解析硬件发来的固定 32B packet。ring 消费状态按物理 slot 记录 `type + seq`，而不是只记录每种 packet type 的最大 seq，避免扫描顺序导致较早但仍有效的 packet 被跳过。
    3. 当前主要 packet type 包括 `CFG_WRITE`、`BAR_WRITE`、`BAR_READ`、`BAR_WRITE_DONE` 和 `SQE_WRITE_DONE`。
    4. 维护 NVMe BAR shadow 状态，包括 `AQA/ASQ/ACQ/CC`、doorbell、Admin queue 拓扑和虚拟 INTx 状态。
    5. 初始化时确保真实 NVMe PCI Command 的 MEM/BUS_MASTER 已开启，映射真实 BAR0 后写 `CC=0` 并轮询 `CSTS.RDY=0`；guest 写 `CC.EN=0` 时也同步禁用真实控制器。若真实控制器的 `RDY` 无法清零，QEMU 会停止启动，并在诊断信息中同时报告 `CFS`，提示先执行 host driver unbind、FLR 或 rescan，而不是把坏状态继续暴露给 guest。
    6. 解析到 Admin SQ 参数后，QEMU 直接写 `sqe_write_done_monitor/s_cfg_axi` 配置寄存器，配置 Admin SQ base、bytes 和 valid。当前不再通过 `axilite_active_proxy` mailbox 传递 queue window，也不再配置 Admin CQ window 给 monitor。
    7. 对 Admin SQ doorbell 使用事件驱动延迟处理：收到 SQ doorbell `BAR_WRITE` 后先写 early OK response，并记录 pending doorbell；收到 `BAR_WRITE_DONE` 后只标记 BAR 完成；收到对应 slot 的 `SQE_WRITE_DONE` 后，如果 BAR 也已完成，才读取 SQE、patch PRP/metadata DMA 地址、写回 SQE，再把真实 doorbell 转发给真实 NVMe。
    8. 支持乱序事件：`SQE_WRITE_DONE` 可以先于 doorbell 到达并被记录；doorbell 也可以先于 `SQE_WRITE_DONE` 到达并保持 pending。pending doorbell 会记录每个 slot 的 done seq baseline；如果 DONE 在 doorbell 前到达，允许未消费的 `done_seq == baseline_seq`，同时拒绝已经被上一条 doorbell 消费的旧事件。当前默认路径不再使用 SQE timeout fallback；Admin SQ doorbell 必须等对应 slot 的完整 64B `SQE_WRITE_DONE` 覆盖后才处理。
    9. Admin SQE 读取保留短 retry 和 seed 旧值拒绝逻辑作为异常兜底；正常路径不依赖固定长延时。
    10. Admin 命令转发后按 CID 标记 outstanding。QEMU 只在存在 outstanding Admin CID 时扫描 Admin CQ，并校验 CQE 的 phase、`sq_id`、`sq_head` 和 CID，防止 ACQ 中跨启动残留的 phase-1 数据被误判为新完成。
    11. QEMU 通过属性 `bypass-coherent-alias-base` 控制 coherent alias 偏移，默认 `0x100000000`；QEMU 自身对 guest queue memory 的读写，包括 SQE 读取、SQE patch 写回和 CQE shadow 读取，默认都使用该 alias。属性 `guest-mem-raw-fallback` 默认关闭，只有调试时显式打开才会在 alias 访问失败后退回 raw bypass。
    12. QEMU 对 NVMe 命令的数据指针做完整 PRP 翻译：根据 Admin/IO 命令类型计算数据长度，解析 Identify Namespace 完成后的 LBA size，patch `PRP1/PRP2/metadata`，并在 `PRP2` 指向 PRP list 时读取 list page、逐项把 guest PA 改写成真实 NVMe 可访问的 coherent alias DMA 地址后再写回 list page。
    13. QEMU 不生成也不复制 CQE；真实 NVMe 通过 FPGA XDMA EP bypass BAR coherent alias 把 CQE DMA 写入 guest CQ memory 后，QEMU 通过同一 alias 读取该 guest CQ memory，推进 CQ shadow tail，并通过 active proxy mailbox 驱动标准 level INTx 通知香山。guest 消费 CQE 并写 CQ doorbell 后，QEMU 根据 guest CQ head 解除 INTx。
    14. 处理完成后，通过硬件 mailbox 写入 ACK/BAR response，包含 sequence、AXI response、读数据和可选 DONE request bit。

* **[qemu-mount/hw/misc/scope_fpga_proxy_abi.h](qemu-mount/hw/misc/scope_fpga_proxy_abi.h)**
  * **作用**：QEMU 与 FPGA RTL 共享的 DMA32 packet ABI。
  * **功能详情**：
    1. 定义 `scope_dma32_packet` 固定 32B 格式，由 8 个 `uint32_t` 字段组成。
    2. RTL 的 `AXIS_NOTIFY_LEN` 固定为 32；AXIS 数据宽度虽然是 512-bit，但 `tkeep` 只标记低 32B 有效。
    3. `SCOPE_PKT_TYPE_BAR_WRITE_DONE = 4` 表示被 QEMU early response 且请求 DONE 的 BAR write 已经在 guest AXI B 通道完成握手。
    4. `SCOPE_PKT_TYPE_SQE_WRITE_DONE = 5` 表示 Admin SQ window 内的一次 AXI write 已经在 DDR 写路径收到 B response。该 packet 使用 `flags[15:0]` 表示 slot，`flags[23:16]` 表示 qid，`flags[25:24]` 表示 bresp，`flags[31]` 表示 monitor overflow；`bar_offset` 保存 `guest_pa[31:0]`，`guest_addr_lo` 保存 `guest_pa[63:32]`，`data` 保存 write bytes。
    5. QEMU 与 RTL 必须同步更新该 header 中的 packet type 数值，否则 QEMU 会无法识别硬件事件。

## 2. 硬件/FPGA 侧：拦截、监控与通知

* **[shell/nm37_vu37p/fpga/sources/hdl/recorder/axilite_active_proxy.v](shell/nm37_vu37p/fpga/sources/hdl/recorder/axilite_active_proxy.v)**
  * **作用**：AXI/AXI-Lite 主动拦截代理模块。
  * **功能详情**：
    1. `S_AXI` 侧处理配置/控制类 AXI-Lite 访问，`S_BAR_AXI` 侧拦截 guest 对真实 NVMe BAR 的 AXI 访问。
    2. 拦截目标请求后生成固定 32B DMA32 packet，通过 C2H AXI-Stream 发送给 XDMA/QEMU。
    3. 内部维护 mailbox 状态机，发包后阻塞对应 AXI 通道，直到 QEMU 写回 ACK/BAR response。
    4. 对 QEMU 设置 DONE request bit 的 BAR write，RTL 先按 QEMU response 给 guest 返回 B response；随后观察 `s_bar_axi_bvalid && s_bar_axi_bready`，只有 guest 侧 B 通道握手完成后才发 `BAR_WRITE_DONE`。
    5. 当前版本不再承载 Admin SQ/CQ queue window 配置，也不再输出 queue window 到 monitor；queue window 由 QEMU 直接写 monitor 的 AXI-Lite 配置口。
    6. 保留虚拟 INTx、VCONF mailbox、BAR response、BAR read/write 统计等职责。统计寄存器和 INTx mask 寄存器已整理为单一 always block/单一状态机驱动，避免多 always block 驱动同一寄存器。

* **[shell/nm37_vu37p/fpga/sources/hdl/recorder/sqe_write_done_monitor.v](shell/nm37_vu37p/fpga/sources/hdl/recorder/sqe_write_done_monitor.v)**
  * **作用**：Admin SQE 写完成事件监控模块。
  * **功能详情**：
    1. 工作在 `xdma_ep/axi_aclk` 域，带一个 32-bit AXI-Lite 配置口 `s_cfg_axi`。
    2. QEMU 通过 `s_cfg_axi` 写入 Admin SQ window：`0x00 ADMIN_SQ_BASE_LO`、`0x04 ADMIN_SQ_BASE_HI`、`0x08 ADMIN_SQ_BYTES`、`0x0c ADMIN_SQ_CTRL bit0=valid`、`0x10 STATUS`。
    3. 该模块不是离散信号 tap，而是插入 role DDR 路径的完整 AXI4 透明 pass-through bridge：`s_mon_axi` 接收上游事务，`m_mon_axi` 连接 DDR interconnect，AW/W/B/AR/R 五个通道逐信号直通。
    4. monitor 只基于真实透传握手计算 `aw_fire = s_mon_axi_awvalid && s_mon_axi_awready` 和 `b_fire = s_mon_axi_bvalid && s_mon_axi_bready`；事件通路不会改变 AXI ready/valid，也不会因 C2H 拥塞反压 guest 的 DDR 访问。
    5. 在每次 AW handshake 时把写事务元信息写入 meta FIFO，包括地址、长度、Admin SQ 命中范围、slot 范围和配置 generation。meta FIFO 为所有 AW 保留条目，使后续无 ID 的 B response 仍能与写事务顺序对齐。
    6. 在对应 B 通道 handshake 后，命中当前 Admin SQ window 的事务进入 job FIFO；如果一次 write 覆盖多个 64B SQE slot，emitter 会为每个 slot 分别生成一个 `SQE_WRITE_DONE` packet。
    7. FIFO 满、AW/B 元信息失配或事件丢弃时设置 overflow sticky，并通过 `flags[31]` 报给 QEMU；monitor 可进入 meta desync 恢复流程，但始终不阻塞原始 DDR 事务。

* **[shell/nm37_vu37p/fpga/sources/hdl/recorder/axi_alias_attr_bridge.v](shell/nm37_vu37p/fpga/sources/hdl/recorder/axi_alias_attr_bridge.v)**
  * **作用**：XDMA EP bypass coherent alias 分支上的 AXI 地址/属性转换桥。
  * **功能详情**：
    1. 透明转发 AXI4 AW/W/B/AR/R 通道，不改变数据宽度和握手语义。
    2. 对进入 alias window 的 `AWADDR/ARADDR` 减去 `ADDR_SUBTRACT`，当前默认 `0x100000000`，因此 host/真实 NVMe 看到的是高 4GB alias，香山 role 侧仍看到原始 guest physical address。
    3. 将 `AWCACHE/ARCACHE` 固定为 `CACHE_VALUE=4'hf`，用于验证 `u_role/s_axi_dma`/`xs_top.dma_0` 入口是否能把该类外设 DMA 事务纳入香山侧一致性视图。
    4. 该模块不让数据经过香山 CPU pipeline；它只把 PCIe P2P 到 FPGA endpoint 的事务导入香山 SoC DMA/coherency 入口。

* **[shell/nm37_vu37p/fpga/scripts/xiangshan.tcl](shell/nm37_vu37p/fpga/scripts/xiangshan.tcl)**
  * **作用**：Vivado Block Design 构建脚本。
  * **功能详情**：
    1. 例化 `axilite_active_proxy_0`、`sqe_write_done_monitor_0`、AXIS clock converter、AXIS register slice 和 C2H 合流 interconnect。
    2. `axi_ic_host_vconf/M02_AXI` 连接到 `sqe_write_done_monitor_0/s_cfg_axi`，QEMU 通过 host AXI-Lite 空间直接配置 monitor。
    3. active proxy C2H packet 和 SQE monitor C2H packet 通过 `axis_ic_proxy_c2h1` 2-to-1 合流，再接到 `xdma_ep/S_AXIS_C2H_1`。
    4. role DDR 路径为：`u_role/m_axi_mem -> axi_ic_ddr_mem_reg_slice_S01 -> sqe_write_done_monitor_0/s_mon_axi -> sqe_write_done_monitor_0/m_mon_axi -> axi_ic_ddr_mem/S01_AXI -> DDR4 MIG`。原始 AXI 接口不再拆成单根信号连接。
    5. XDMA EP bypass 路径新增 `axi_ic_ep_bypass_split`：`M00` 保留低 4GB raw DDR window，直连 `axi_ic_ddr_mem/S00_AXI`；`M01` 进入 `axi_alias_attr_bridge_0`，再接到 `axi_ic_pcie_rp_dma/S01_AXI -> axi_dwidth_converter_0 -> u_role/s_axi_dma`，形成 coherent alias window。
    6. 由于自定义 RTL pass-through 不是 Vivado BD 自动识别的 address-transparent interconnect，Tcl 显式创建多个地址段：`ROLE_DDR_MONITOR` 表示 role 到 monitor slave，`ROLE_DDR` 表示 monitor master 到 DDR4 MIG；`PCIE_EP_BYPASS_RAW_DDR` 表示 EP bypass 低 4GB raw DDR；`PCIE_EP_BYPASS_ROLE_DMA_ALIAS` 表示 EP bypass 高 4GB alias 进入 role DMA。
    7. 地址分配：`HOST_MBX_REG = 0x11000000-0x11000fff`，`HOST_SQE_MONITOR_CFG = 0x11001000-0x11001fff`，`HOST_VCONF_BRAM = 0x11010000-0x11010fff`。QEMU 侧 monitor config offset 对应 `0x01001000`，三个 4KB 地址段互不重叠。EP bypass 中 `0x000000000-0x0ffffffff` 是 raw DDR，`0x100000000-0x1ffffffff` 是 coherent alias，alias bridge 在进入 role DMA 前减去 `0x100000000`。
    8. 当前保留 ILA 重点观察 XDMA EP bypass AXI、alias bridge/role DMA 分支、monitor 实际透传到 DDR 的 AXI、SQE monitor 原始 packet stream 和合流后的 C2H stream。

## 3. NVMe Proxy 数据路径与时序闭环

1. guest NVMe 驱动把 Admin SQE 写入 FPGA 侧 queue memory。
2. `sqe_write_done_monitor.v` 作为 role DDR 路径中的透明 AXI4 bridge，看到 Admin SQ window 内的真实 AW handshake，并等待该写事务 B response handshake。
3. guest 对 NVMe BAR doorbell 写 tail。
4. `axilite_active_proxy.v` 捕获 SQ doorbell `BAR_WRITE`，把它作为 DMA32 packet 发给 QEMU。
5. QEMU 识别这是 Admin SQ doorbell 后，先通过 mailbox 写 OK response，并设置 DONE request bit，但暂时不读 SQE。
6. 硬件收到 response 后给 guest 返回 AXI B response。等 `s_bar_axi_bvalid && s_bar_axi_bready` 完成后，硬件发 `BAR_WRITE_DONE` packet。
7. SQE 写事务在 DDR 写路径收到 B response 后，monitor 发 `SQE_WRITE_DONE` packet。
8. QEMU 只有在 pending doorbell 同时满足 `BAR_WRITE_DONE` 和对应 slot 的未消费 `SQE_WRITE_DONE` 后，才读取 SQE。这个判断包含 baseline seq，并允许 DONE-before-doorbell 的合法乱序。当前 QEMU 读 SQE 时默认访问 XDMA bypass coherent alias，而不是低 4GB raw DDR window。
9. QEMU 将 SQE 中的 PRP/metadata guest 地址改写成真实 NVMe 可访问的 FPGA XDMA EP bypass coherent alias host 地址。
10. QEMU 把 patch 后的 SQE 通过同一 coherent alias 写回 queue memory，并把真实 doorbell 转发给真实 NVMe。
11. 真实 NVMe 通过 PCIe P2P 访问 FPGA XDMA EP bypass BAR 的 coherent alias window。该事务进入 FPGA 后经 `axi_alias_attr_bridge_0 -> u_role/s_axi_dma`，在 role/DUT 侧仍访问原 guest physical address。
12. QEMU 在转发 Admin 命令时记录 outstanding CID；只有通过 coherent alias 看到与该 CID 匹配的有效 CQE 后，才推进 CQ shadow tail 并触发虚拟 INTx。
13. guest NVMe 驱动从自己的 CQ buffer 中读取 CQE，随后写 CQ doorbell 更新 CQ head；QEMU 只负责验证完成状态和维护虚拟中断电平，不替 Linux 消费 CQE，也不推进 guest CQ head。

### 3.1 CQE 完成通知链路

当前项目没有为 CQE 增加类似 `SQE_WRITE_DONE` 的硬件 packet，也没有让 QEMU 主动构造 CQE。CQE 的数据面和通知面按以下方式分层：

1. **CQE 数据面**：guest 在 `ACQ` 或 Create CQ 命令中给出的 CQ guest 物理地址会被 QEMU patch 成真实 NVMe 可访问的 FPGA XDMA EP bypass coherent alias host 地址。真实 NVMe 完成命令后，通过 PCIe P2P 到 FPGA endpoint，再经 FPGA 内部 role DMA/coherency 入口写入 guest CQ memory。因此 CQE 的生产者是真实 NVMe，CQE 最终存放位置仍是香山 Linux 驱动分配的 CQ buffer。
2. **QEMU 观测面**：QEMU 在转发 Admin SQE 时记录 outstanding CID。后续每次收到相关事件、doorbell 或定期轮询时，`scope_update_virtual_intx()` 会调用 `scope_refresh_cq_shadow_tail()`，通过 XDMA bypass coherent alias 读取 `cq->guest_base + shadow_tail * sizeof(NvmeCqe)`。读取采用两次稳定读，只有两次内容一致才继续判断。
3. **有效 CQE 过滤**：QEMU 先检查 phase bit 是否等于当前 `cq->phase`；Admin CQ 还会校验 `sq_id == 0`、`sq_head < admin_sq_depth`，并要求 `cid` 处于 `admin_cid_outstanding[]`。这样可以过滤 ACQ 中跨次启动残留的 phase-1 CQE，避免把旧 CQE 当成新完成。
4. **推进 shadow tail**：识别到有效 CQE 后，QEMU 清除对应 outstanding CID，提交挂起的 Admin queue topology 更新，然后推进 `cq->shadow_tail`；如果 tail 回绕，则翻转 `cq->phase`。
5. **通知香山**：如果 `cq->shadow_tail != cq->last_guest_head` 且该 CQ 开启中断、guest 没有通过 `INTMS` mask 中断，QEMU 写 `HOST_MBX_BASE + MBX_REG_RP_INTX_CTRL`。`axilite_active_proxy` 将该 mailbox bit 转成 `interrupt_out`，再通过 `role_intr_concat/In1 -> u_role/s2r_intr` 注入香山。
6. **香山消费**：香山 Linux NVMe 驱动收到 INTx 后，从自己的 CQ buffer 读取 CQE。这个读取应当访问同一个 guest CQ buffer；QEMU 不替 Linux 消费 CQE，也不会推进 guest CQ head。
7. **解除中断**：guest 处理 CQE 后写 CQ doorbell，例如 Admin CQ0 doorbell。QEMU 在 `scope_handle_doorbell_write()` 中更新 `cq->last_guest_head`，再次调用 `scope_update_virtual_intx()`；当 `shadow_tail == last_guest_head` 时，QEMU 写 mailbox 清除 INTx。

因此，CQE 通知的正确时序应当是：

```text
真实 NVMe 经 coherent alias DMA 写 CQE 到 guest CQ memory
QEMU 通过 coherent alias 稳定读到有效 CQE
QEMU 写 RP_INTX_CTRL=1，active proxy interrupt_out 拉起
香山 Linux 进入 nvme_irq 并从 CQ buffer 读 CQE
香山写 CQ doorbell 更新 CQ head
QEMU 更新 last_guest_head -> RP_INTX_CTRL=0
```

该链路要求真实 NVMe、QEMU 和香山 CPU 对同一个 guest CQ slot 具有一致视图。仅有 QEMU shadow CQ 看到 CQE 还不足以完成 guest 语义；INTx 拉起前，应尽量保证 CQE 已经进入香山 CPU 可消费的 queue memory 视图。

### 3.2 真实控制器生命周期与跨次测试状态

1. 真实 NVMe 应由 QEMU 独占使用，启动 QEMU 前应先从 host `nvme` 驱动 unbind，避免 host 驱动和 guest 同时操作同一个控制器。
2. QEMU 启动时和 guest 写 `CC.EN=0` 时都会禁用真实控制器，并等待 `CSTS.RDY` 清零。该步骤用于清除上一轮测试留下的 controller enabled、fatal status 或未完成 queue 状态。
3. guest 写 AQA/ASQ/ACQ 只更新并同步 queue 寄存器，不应由 QEMU 主动清空 guest ACQ；ACQ 内存由 guest/真实 NVMe 数据路径拥有。
4. 因为 ACQ 可能保留旧内容，QEMU 在没有 outstanding Admin 命令时不扫描 Admin CQ；有命令后仍会用 CID 和 queue 字段过滤 stale CQE。

### 3.3 PRP/PRP List 地址翻译

NVMe 命令中的数据缓冲区由 `metadata`、`PRP1`、`PRP2` 描述。香山 Linux 驱动写入 SQE 时，这些字段保存的是 guest physical address；真实 NVMe 控制器不能直接访问这些 guest PA，因此 QEMU 在转发 doorbell 前必须把所有数据指针改写成真实设备能 DMA 到的 FPGA XDMA EP bypass coherent alias 地址。

当前 QEMU 的 PRP 翻译分为三层：

1. **数据长度计算**：Admin 命令按命令类型计算数据长度，例如 Identify 返回 4096B；IO read/write/compare 根据 `nsid`、`nlb` 和 namespace LBA size 计算数据长度。QEMU 在 Identify Namespace CQE 完成后，通过读取 Identify Namespace 返回数据记录每个 namespace 的 LBA shift，后续 IO 不再固定假设 512B sector。
2. **直接 PRP 翻译**：对于只使用 `PRP1`，或使用 `PRP1 + PRP2` 直接描述两段数据页的命令，QEMU 分别把每个 guest PA 映射到 coherent alias host DMA 地址，并写回 SQE 中对应字段。
3. **PRP list 翻译**：当数据长度超过 `PRP1` 能覆盖的第一页以及 `PRP2` 直接数据页时，`PRP2` 表示 PRP list page 的地址。QEMU 先把 `PRP2` list page 指针本身翻译成真实 NVMe 可访问的 alias 地址，再通过 coherent alias 读取该 list page，逐项解析其中的 64-bit PRP entry。每个 data entry 都从 guest PA 翻译成 coherent alias DMA 地址并写回 list page；如果 list page 最后一项指向下一页 PRP list，QEMU 也会翻译该 next-list 指针并继续处理下一页。

PRP list page 本身仍位于 guest memory，由香山 Linux 分配；QEMU 只是把 page 内部条目从 guest PA 改写为真实 NVMe DMA 地址。这样，真实 NVMe 读取 PRP list 时看到的是 coherent alias 地址，而不是香山 guest PA，能够支持大 IO、文件系统格式化和 mount 过程中出现的多页数据传输。

该机制仍保持数据面 P2P：真实 NVMe 根据 patch 后的 PRP/PRP list 发起 PCIe DMA 到 FPGA endpoint coherent alias window；QEMU 不搬运用户数据，只在命令提交前修改 SQE 和 PRP list 元数据。

## 4. Linux 驱动侧：XDMA 内核态桥梁

* **[shell/software/xdma_drv/XDMA/linux-kernel/xdma/cdev_ctrl.c](shell/software/xdma_drv/XDMA/linux-kernel/xdma/cdev_ctrl.c)**
  * **作用**：XDMA 字符设备控制节点的增强实现。
  * **功能详情**：
    1. 新增 `XDMA_IOC_DMA32_DB_ALLOC` 等自定义 ioctl，为 QEMU 分配连续 DMA 内存。
    2. 分配内存时自动配置并启动 C2H cyclic DMA 引擎，使硬件 packet 自动写入 host ring。
    3. 提供 stale cyclic transfer 清理机制，提升多次运行、remove/rescan 和异常退出后的稳定性。

* **[shell/software/xdma_drv/XDMA/linux-kernel/xdma/libxdma.c](shell/software/xdma_drv/XDMA/linux-kernel/xdma/libxdma.c)**
  * **作用**：底层 DMA 引擎控制核心。
  * **功能详情**：增强 cyclic stop 等路径的鲁棒性，避免 QEMU 异常退出或链路断开时留下坏状态。

## 5. 测试与运行工具侧

* **[tools/proto/load_and_run.sh](tools/proto/load_and_run.sh) / [tools/proto/load_and_run_5.sh](tools/proto/load_and_run_5.sh)**
  * **作用**：FPGA 原型运行入口脚本。
  * **功能详情**：对目标系统 assert/deassert reset，加载 bootrom 和 payload，并通过 readback fence 排空/确认 DDR bypass posted write，随后启动串口连接。

* **ILA/Tcl/Python 调试脚本**
  * **作用**：在枚举卡死、丢包、SQE 旧值、P2P DMA 路径异常时抓取硬件侧波形。
  * **重点观察点**：
    1. `system_ila_4/SLOT_0_AXI` 观察 `xdma_ep/M_AXI_BYPASS`，用于确认 QEMU 或真实 NVMe 对 FPGA DDR 的 P2P AR/AW/R/W。
    2. `system_ila_6` 在同一个 `xdma_ep/axi_aclk` 域逐周期对比 role DDR 与 role IO 路径：`SLOT_0_AXI` 观察 `axi_ic_ddr_mem_reg_slice_S01/S_AXI`，`SLOT_1_AXI` 观察 `axi_ic_ddr_mem_reg_slice_S01/M_AXI`，`SLOT_2_AXI` 观察 `sqe_write_done_monitor_0/m_mon_axi`，`SLOT_3_AXI` 观察 `axi_ic_role_io_reg_slice_S00/S_AXI`。
    3. SQ doorbell BAR write 及 `BAR_WRITE_DONE`。
    4. `system_ila_5/SLOT_0_AXIS` 观察 monitor 原始 `SQE_WRITE_DONE` stream，`SLOT_1_AXIS` 观察合流后送往 `xdma_ep/S_AXIS_C2H_1` 的 packet stream。
    5. Vivado build 日志中不应再出现 monitor AXI 端口 tied-off、`NET has no source` 或 role DDR addressing path 不存在。

## 6. 当前实现边界

1. Linux NVMe 驱动不依赖额外 `dma_wmb()` 修改；当前修复目标放在 proxy 软硬件事件闭环上。
2. QEMU 与 RTL 必须同步更新。只更新 QEMU 而不更新 bitstream 时，QEMU 会等待硬件永远不会发出的 `BAR_WRITE_DONE` 或 `SQE_WRITE_DONE`。
3. `BAR_WRITE_DONE` 只证明 doorbell MMIO 写对 guest 完成；`SQE_WRITE_DONE` 证明 Admin SQE 写事务在 DDR AXI 写路径收到 B response。QEMU 正常路径需要两个事件都到达。
4. `SQE_WRITE_DONE` 的完成语义不是 CPU cache/PMA 层面的全局一致性证明。如果 `SQE_WRITE_DONE` 之后仍读到旧 SQE，应继续排查 queue memory/cache coherency/alias，而不是继续增加固定 sleep。
5. `sqe_write_done_monitor` 当前只覆盖 Admin SQ window，这是为 probe 阶段 qid 0 的 SQE 读早问题设计的第一阶段修复。
6. monitor 是透明 AXI4 pass-through bridge，而不是旁路 tap。它必须保持 AW/W/B/AR/R 的原始语义，不能因为 meta/job FIFO、packet emitter 或 C2H backpressure 改变 DDR 事务行为。
7. monitor 当前接口没有 AXI ID，依赖写响应按 AW 顺序返回；meta FIFO 必须为命中和未命中的每个 AW 都保留顺序条目，才能把 B response 正确关联到 SQE write。
8. Admin CQ shadow 扫描和虚拟 INTx 只用于识别真实 NVMe 已写入 guest CQ memory 的 CQE，不代替 guest 对 CQE 的内存读取，也不应主动清零 CQE。
9. 真实 NVMe 必须由 QEMU 独占并能干净进入 `CSTS.RDY=0`；若 host 驱动仍绑定、控制器无法 disable，或诊断中同时出现 `CFS=1`，应先执行 unbind/FLR/rescan，而不是继续调 SQE/CQE 时序。
10. 历史 bring-up 阶段使用过 SQE timeout fallback、CQE publish/readback、INTx retry pulse、内核 CBO/dma_sync/forced-mmio 等保护路径；当前默认实现已清理这些行为型兜底，只保留地址和值的诊断打印。
11. Coherent alias 数据面仍是 host PCIe device 到 FPGA endpoint 的 PCIe P2P，不经过 x86 host memory 或 QEMU 数据复制；但进入 FPGA 后不再是 raw DDR 直写，而是经 `u_role/s_axi_dma`/DMA-coherency 入口到达 guest memory。

## 7. Guest Queue Coherency

NVMe Admin SQ/CQ queue memory 同时被三个主体访问：香山 CPU、QEMU proxy 和真实 NVMe 控制器。为了让三者看到一致的队列内容，仓库 11 把真实 NVMe DMA 地址和 QEMU 自身的 guest queue memory 读写都映射到 XDMA EP bypass coherent alias。

1. 香山 CPU 按普通 Linux NVMe 驱动模型分配和访问 SQ/CQ buffer。
2. QEMU proxy 在解析 doorbell 后，通过 coherent alias 读取 Admin SQE、patch PRP/metadata，再通过同一 alias 写回 SQE。
3. QEMU patch 给真实 NVMe 的 PRP、metadata、SQ/CQ 地址都指向 coherent alias window。
4. 真实 NVMe 的 P2P DMA 进入 FPGA 后，经 `axi_alias_attr_bridge_0` 地址还原，再从 `u_role/s_axi_dma` 进入香山 SoC 的 DMA/coherency 入口。
5. QEMU shadow CQ 扫描同样通过 coherent alias 观察真实 NVMe 写入的 CQE，避免 QEMU 侧和真实 NVMe 侧使用不同视图。

这个设计避免了 raw DDR bypass 直写和香山 CPU cache 之间形成两个彼此不可见的队列副本。raw bypass window 仍保留为诊断入口，但不作为默认 NVMe queue 数据面。

## 8. Bring-up 保护路径清理

仓库 11 曾在 bring-up 阶段加入几类保护路径，用于定位和绕过 cache 可见性或中断边沿问题。这些路径不属于当前默认架构，已从正常行为中清理：

1. **Admin SQE timeout fallback**：不再默认绕过 `SQE_WRITE_DONE`；Admin SQ doorbell 必须等完整 SQE done mask。
2. **CQE publish/readback**：QEMU 不再主动 mirror CQE 到 guest CQ slot；真实 NVMe 的 CQE DMA 和 coherent alias 数据面承担可见性语义。
3. **INTx retry hook**：QEMU 不再对 pending INTx 做 deassert/assert pulse；虚拟 INTx 恢复为标准 level 语义。
4. **内核 cache/MMIO 兜底**：Linux NVMe 驱动不再执行 Admin SQE `cbo.clean`、Admin CQE `cbo.inval`、`dma_sync_single_for_cpu()`、forced-mmio 读取、ILA 延时或 MMPMA 配置。
5. **raw fallback 控制**：`guest-mem-raw-fallback` 默认关闭。只有在诊断 coherent alias 失效时，才允许 QEMU 在 alias 访问失败后尝试 raw bypass。

当前正常路径依赖硬件 DONE 事件、coherent alias 数据面和标准 level INTx 语义；内核侧保留 SQE/CQE 地址和值打印，用于观察队列内容。

## 9. Host PCIe P2P 数据面

当前主机侧真实 NVMe 的数据面仍然保持 PCIe P2P 语义：真实 NVMe 作为 host PCIe device，直接向 FPGA XDMA endpoint 的 bypass BAR 发起 DMA 读写。QEMU 只负责控制面代理、地址 patch、状态机推进和中断模拟，不在数据面复制用户数据。

coherent alias 模式下，P2P 事务进入 FPGA 后的内部路径为：

```text
真实 NVMe / QEMU
-> x86 host PCIe write/read to FPGA XDMA EP bypass BAR alias
-> xdma_ep/M_AXI_BYPASS
-> axi_ic_ep_bypass_split/M01_AXI
-> axi_alias_attr_bridge_0: 地址减 0x100000000, AWCACHE/ARCACHE=4'hf
-> axi_ic_pcie_rp_dma/S01_AXI
-> axi_dwidth_converter_0
-> u_role/s_axi_dma
-> 香山侧 DMA/coherency 入口和 guest memory
```

因此，从 x86 PCIe fabric 的角度看，真实 NVMe 仍在访问 FPGA endpoint BAR；从香山 SoC 的角度看，这些访问被导入 DMA/coherency 入口，而不是绕过缓存一致性直接写 raw DDR。这个分层使系统同时保留 host-side P2P 传输形态和 guest queue memory 的一致性需求。
