//============================================================================
// phy_model.v — TB 内理想 PHY 模型 (数字 tx_* → 差分 DP/DN)
// Ideal PHY model for testbenches: digital tx_* → differential DP/DN
//
// 发送方向最末端是模拟收发器驱动 DP/DN; 仿真里没有模拟电路, 用本模型把
// usb_tx_serial 的三个数字输出还原成差分电平, 接给已验的接收链
// (usb_rx_cdr → usb_rx_deserial) 做端到端回环 (设计报告 §4.8.2)。
//
// 映射 (FS 设备: J = D+ 高 / D- 低):
//   tx_en=0                → 高阻 (驱动撤, 电阻分压 = 空闲 J)
//   tx_en=1, tx_se0=1      → SE0   (D+ 与 D- 同低, 忽略 tx_bit)
//   tx_en=1, tx_se0=0, bit=1 → J   (D+ 高 / D- 低)
//   tx_en=1, tx_se0=0, bit=0 → K   (D+ 低 / D- 高)
//
// ★ 高阻为什么可以直接建模成 J: tx_en=0 时驱动确实撤了, 但总线并不悬空 ——
//   主机端 D+/D- 各有 15kΩ 下拉, 设备端 (FS) D+ 有 1.5kΩ 上拉, 分压结果就是
//   D+ 高 / D- 低 = 空闲 J。本模型不写死电平, 而是真挂 pullup/pulldown 电阻 +
//   输出高阻, 让"空闲 J"由电阻分压自然得到 —— 与真实电气语义一致, 且换个
//   接法 (如主机侧模型) 时不用改模型。
//
// 模型是理想的: 组合输出, 无传播延迟/抖动/上下沿斜率。这些属模拟域与 CDR
// 容差范畴 (CDR 已单独验证), 本模型只负责"数字 → 差分"这一件事。
//============================================================================

`timescale 1ns/1ps

module phy_model (
    input  wire tx_bit,     // usb_tx_serial 线电平: 1=J / 0=K
    input  wire tx_se0,     // usb_tx_serial SE0 压线 (仅 EOP 前 2 拍)
    input  wire tx_en,      // usb_tx_serial 驱动使能 (= tx_active 直通)
    output wire rxdp,       // 差分 D+ / D+ line
    output wire rxdn        // 差分 D- / D- line
);

`ifdef VERILATOR
    // ---- Verilator 分支: 高阻直接写成等价的空闲 J ----
    // ① Verilator 是 2 态仿真, `1'bz` 会塌成 0 → 总线交不出去, 回环卡死;
    // ② Verilator 不支持 pullup/pulldown 的强度与电阻分压。
    // 故直接把"高阻 = 空闲 J"写死 (D+ 高 / D- 低), 与下面电阻分压的结果**语义相同**
    // (等价性双证: `iverilog -DVERILATOR` 编出的 log 与正常 iverilog 编出的逐字节一致)。
    assign rxdp = tx_en ? (tx_se0 ? 1'b0 :  tx_bit) : 1'b1;
    assign rxdn = tx_en ? (tx_se0 ? 1'b0 : ~tx_bit) : 1'b0;
`else
    // ---- 总线终端电阻: D+ 上拉 / D- 下拉 ----
    // 高阻时由这两个电阻分压出空闲 J (D+ 高 / D- 低), 见文件头说明。
    pullup   pull_dp (rxdp);    // D+ 上拉 (设备侧 1.5kΩ 等效)
    pulldown pull_dn (rxdn);    // D- 下拉 (主机侧 15kΩ 等效)

    // ---- 驱动: tx_en=0 交高阻 (z), 由电阻决定电平 ----
    assign rxdp = tx_en ? (tx_se0 ? 1'b0 :  tx_bit) : 1'bz;
    assign rxdn = tx_en ? (tx_se0 ? 1'b0 : ~tx_bit) : 1'bz;
`endif

endmodule
