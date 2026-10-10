//==================================================
// Created by        : xxx
// Filename          : usb_dpll_phy.v
// Author            : xiao_yuan
// Created On        : 2026-09-29
// Last Modified     :
// Update Count      : 2026-09-29 首版
// Description       : USB 1.1 FS 数字收发器 PHY 顶层（五个子模块的唯一边界）
//
//   职责：把五个 PHY 子模块连成一层，只出 PHY↔SIE/chip 边界，本层不含任何逻辑
//     （无寄存器、无组合译码，只有例化与连线）。
//     usb_rx_cdr      DP/DN → 恢复位时钟 dclk + NRZI 电平 rx_bit
//     usb_clk_mux     dclk / clk12s 按 rcv 无毛刺切出 clk12m
//     usb_rx_deserial clk12m 位流水线 → 字节级 RX + 线电平
//     usb_tx_serial   SIE 字节 → tx_bit/tx_se0/tx_en 交模拟收发器
//     usb_bus_state   线电平计时 → 四个总线事件
//
//   本层不是「多一层接线」，它是接口的唯一定义处。五个子模块拆开用会各自漏掉的
//   四条约束全在这里落地：
//     ① line_s 只在 usb_rx_deserial 里采一次，usb_bus_state 直接吃这一份
//        （同一把尺子，本层不外送、也不让 bus_state 自己采）；
//     ② tx_en 组合直连 usb_bus_state 当 driving：不打拍、不同步，
//        取的是「有没有在驱总线」而不是寄存过的 tx_active 语义；
//     ③ clk12m 由 usb_clk_mux 产生后同时驱动 deserial / tx_serial 与 bus_state
//        的事件跨域段，并输出给 SIE。它是 PHY 唯一的 1× 时钟出口；
//     ④ usb_rst 是 PHY 唯一的 core 复位入口，同送 deserial 与 bus_state。
//        bus_state 判出的 usb_bus_rst 由本层输出给上层，在 PHY 之外与软复位并成
//        usb_rst 再送回来（SIE 也吃同一根），故本层不产生复位、也不自己并。
//
//   设计报告：doc/design_rpt/phy_design.md
//   验证报告：doc/design_rpt/phy_verification.md
//==================================================
`timescale 1ns/1ps

///////////////////////////////
//  INSTANCE FILE PATH
///////////////////////////////
// Instance: demo.v
module usb_dpll_phy(/*autoarg*/
    //Inputs
    ref_clk, ref_rstn, usb_rst, rxdp, rxdn,
    rcv, tx_active, rx_abort, tx_data, tx_last, sie_wkup,

    //Outputs
    clk12m, rx_data, rx_valid, rx_active, rx_error, line_state,
    tx_ready, tx_done, connect_evt, usb_bus_rst, suspend_evt, resume_evt,
    tx_bit, tx_se0, tx_en);

///////////////////////////////
//  PARAMETER DEFINE
///////////////////////////////
// 本层无参数、无常量：门限与状态编码全在各自子模块内定义

///////////////////////////////
//  INPUT & OUTPUT
///////////////////////////////
input           ref_clk;    //clock 48MHz 参考时钟（4×）：CDR / clk_mux / deserial 定界 / bus_state 判据
input           ref_rstn;   //reset 异步复位，低有效：全 PHY，含两个跨域同步链
input           usb_rst;    //reset core 复位（软复位 ∪ 总线复位），同步高有效、宽 1 个 clk12m 周期

// to phy
input           rxdp;       // 模拟收发器 D+ 单端（J=1, K=0）
input           rxdn;       // 模拟收发器 D- 单端（只做 SE0 判据）
input           rcv;        // SIE 的方向信号：1 = 选 dclk（接收），0 = 选 clk12s（发送/空闲）
input           tx_active;  // SIE 的发送请求（起包/中止）：同送 deserial 与 tx_serial
input           rx_abort;   // SIE 的接收中止（包缓冲溢出）：送 deserial
input [7:0]     tx_data;    // SIE 待发字节（LSb 先发）
input           tx_last;    // 「本字节是最后一个」标志，与末字节同拍
input           sie_wkup;   // SIE 远程唤醒请求（电平）。挂起态不从这里进：tx_serial 读 bus_state 的 bus_suspended

// to sie
output          clk12m;     // 切换出的 12MHz 1× 时钟，SIE 自己的工作时钟由本层供出
output [7:0]    rx_data;    // 接收字节（LSb 对齐，维持满字节周期）
output          rx_valid;   // 每字节一拍脉冲
output          rx_active;  // 包接收中（下降沿 = 包结束）
output          rx_error;   // 接收错误电平（帧机回 idle 即清）
output [1:0]    line_state; // 线电平 {D+,D-} 透传（未采样，规则 6 同域豁免）
output          tx_ready;   // 「当前字节已取走」握手脉冲
output          tx_done;    // 整包发完脉冲（EOP 结束）
output          connect_evt;// 连接事件脉冲：J 保持 ≥2.5µs
output          usb_bus_rst;// 总线复位事件脉冲：SE0 保持 ≥2.5µs；交上层并进 usb_rst
output          suspend_evt;// 挂起事件脉冲：总线空闲 J ≥3ms
output          resume_evt; // 唤醒事件脉冲：挂起中主机驱 K ≥2.5µs

// to analog
output          tx_bit;     // NRZI 线电平（J/K），EOP 段被 tx_se0 顶替
output          tx_se0;     // SE0 标志（EOP）
output          tx_en;      // 驱动器使能：1 = 驱总线，0 = 交高阻

///////////////////////////////
//  WIRE  & REG DECLARE
///////////////////////////////
/*autodefine*/
// Define flip-flop registers here
// Define combination registers here
// Define wires here
wire            bus_suspended;   // 挂起状态（bus_state → tx_serial，本层不外送）
wire            dclk;            // CDR 恢复的 12MHz 位时钟（CDR → clk_mux）
wire            rx_bit;          // CDR 出的 NRZI 电平（CDR → deserial，领先 dclk 1 个 ref_clk）
wire [1:0]      line_s;          // deserial 采样的 {D+,D-}（deserial → bus_state，本层不外送）
// Define instances' ouput wires here
// End of automatic define

///////////////////////////////
//  RTL LOGIC
///////////////////////////////
// 本层无逻辑：全部行为在五个子模块内，本层只决定「谁接谁」

///////////////////////////////
//  INSTANTIATION
///////////////////////////////
//-----------------------------------------------------------------------------
// CDR：DP/DN 单端 → 恢复位时钟 + NRZI 电平（ref_clk 4× 域，16 态 DPLL）
//-----------------------------------------------------------------------------
usb_rx_cdr u_rx_cdr (
    .ref_clk      (ref_clk),
    .ref_rstn     (ref_rstn),
    .rxdp         (rxdp),
    .rxdn         (rxdn),
    .dclk         (dclk),
    .rx_bit       (rx_bit));

//-----------------------------------------------------------------------------
// 时钟切换：dclk / clk12s 按 rcv 无毛刺切出 clk12m
//   ref_rstn 复位进 ST_TX（rcv 初值 0 也选 clk12s），故 clk12m 上电即有沿
//-----------------------------------------------------------------------------
usb_clk_mux u_clk_mux (
    .ref_clk      (ref_clk),
    .ref_rstn     (ref_rstn),
    .dclk         (dclk),
    .rcv          (rcv),
    .clk12m       (clk12m));

//-----------------------------------------------------------------------------
// RX 反序列化：位 → 字节（clk12m 位流水线 + ref_clk EOP/SE0 定界）
//   line_s 只在这里采一次，直接送 bus_state；line_state 是同一对电平的透传
//-----------------------------------------------------------------------------
usb_rx_deserial u_rx_deserial (
    .clk12m       (clk12m),
    .ref_clk      (ref_clk),
    .ref_rstn     (ref_rstn),
    .usb_rst      (usb_rst),
    .rx_bit       (rx_bit),
    .rxdp         (rxdp),
    .rxdn         (rxdn),
    .tx_active    (tx_active),
    .rx_abort     (rx_abort),
    .rx_data      (rx_data[7:0]),
    .rx_valid     (rx_valid),
    .rx_active    (rx_active),
    .rx_error     (rx_error),
    .line_state   (line_state[1:0]),
    .line_s       (line_s[1:0]));

//-----------------------------------------------------------------------------
// TX 串行器：SIE 字节 → 线电平（含挂起/远程唤醒旁路）
//   tx_en 同时给模拟收发器和 bus_state（driving），本层组合直连、不打拍；
//   旁路的挂起态读 bus_state 判出的 bus_suspended，SIE 只出唤醒请求 sie_wkup
//-----------------------------------------------------------------------------
usb_tx_serial u_tx_serial (
    .clk12m       (clk12m),
    .ref_rstn     (ref_rstn),
    .tx_active    (tx_active),
    .tx_data      (tx_data[7:0]),
    .tx_last      (tx_last),
    .bus_suspended(bus_suspended),
    .sie_wkup     (sie_wkup),
    .tx_en        (tx_en),
    .tx_bit       (tx_bit),
    .tx_se0       (tx_se0),
    .tx_ready     (tx_ready),
    .tx_done      (tx_done));

//-----------------------------------------------------------------------------
// 总线状态检测：线电平 → 四个事件（判据 ref_clk 域，事件 clk12m 域）
//   线电平吃 deserial 采好的 line_s；driving 吃 tx_en
//-----------------------------------------------------------------------------
usb_bus_state u_bus_state (
    .clk12m       (clk12m),
    .ref_clk      (ref_clk),
    .ref_rstn     (ref_rstn),
    .usb_rst      (usb_rst),
    .line_s       (line_s[1:0]),
    .tx_en        (tx_en),
    .connect_evt  (connect_evt),
    .usb_bus_rst  (usb_bus_rst),
    .suspend_evt  (suspend_evt),
    .resume_evt   (resume_evt),
    .bus_suspended(bus_suspended));

endmodule
