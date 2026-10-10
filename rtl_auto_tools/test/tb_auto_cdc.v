`timescale 1ns/1ps
//============================================================================
// tb_usb_sie_cdc.v — usb_sie_cdc 测试台骨架 (rtl_autogen.py tb 自动生成)
// DUT: src/sie/usb_sie_cdc.v  module usb_sie_cdc (22 端口)
// TODO: 在 "激励与自检" 区补充测试向量与结果比对
//============================================================================

module tb_usb_sie_cdc;

    // ---- 时钟 ----
    reg pclk = 1'b0;                    // 初值必须给, 否则 ~X 仍为 X 无沿
    parameter CLK_PERIOD = 10.0;                 // 时钟周期 ns
    always #(CLK_PERIOD/2.0) pclk = ~pclk;

    // ---- 复位 (低有效) ----
    reg sie_rstn;

    // ---- DUT 输入激励 ----
    reg        clk12m    ;
    reg  [7:0] rx_data   ;   // SIE 解析出的字节（握手期间保持稳定）
    reg        rx_start  ;   // 包首（=PID 字节）
    reg        rx_last   ;   // 包尾
    reg        rx_error  ;   // 包错
    reg        rx_req    ;   // SIE: 字节就绪（保持到 rx_ack）
    reg        tx_req    ;   // SIE: 请求字节（保持到 tx_ack）
    reg        s_rx_ack  ;   // FIFO: 已取走本字节
    reg  [7:0] s_tx_data ;   // FIFO 提供的字节（s_tx_ack 期间保持稳定）
    reg        s_tx_ack  ;

    // ---- DUT 输出观测 ----
    wire       rx_ack    ;   // FIFO: 已取走本字节
    wire       tx_ack    ;   // FIFO: 字节就绪（随 tx_data 有效）
    wire [7:0] tx_data   ;   // FIFO 提供的字节（随 tx_ack 有效）
    wire [7:0] s_rx_data ;   // 同步后的字节（s_rx_valid 有效时稳定）
    wire       s_rx_start;
    wire       s_rx_last ;
    wire       s_rx_error;
    wire       s_rx_valid;   // 字节有效（= rx_req 同步后，电平非脉冲）
    wire       s_tx_req  ;   // tx_req 同步后（电平非脉冲）

    // ---- DUT 实例 ----
    usb_sie_cdc dut (
        .clk12m      (clk12m),
        .sie_rstn    (sie_rstn),
        .rx_data     (rx_data),
        .rx_start    (rx_start),
        .rx_last     (rx_last),
        .rx_error    (rx_error),
        .rx_req      (rx_req),
        .rx_ack      (rx_ack),
        .tx_req      (tx_req),
        .tx_ack      (tx_ack),
        .tx_data     (tx_data),
        .pclk        (pclk),
        .p_rstn      (p_rstn),
        .s_rx_data   (s_rx_data),
        .s_rx_start  (s_rx_start),
        .s_rx_last   (s_rx_last),
        .s_rx_error  (s_rx_error),
        .s_rx_valid  (s_rx_valid),
        .s_rx_ack    (s_rx_ack),
        .s_tx_req    (s_tx_req),
        .s_tx_data   (s_tx_data),
        .s_tx_ack    (s_tx_ack)
    );

    // ---- 复位流程 ----
    initial begin
        sie_rstn = 1'b0;
        repeat (5) @(posedge pclk);
        sie_rstn = 1'b1;
    end

    // ---- 波形转储 ----
    initial begin
        $dumpfile("tb_usb_sie_cdc.vcd");
        $dumpvars(0, tb_usb_sie_cdc);
    end

    // ---- 激励与自检 (TODO: 手动补充) ----
    initial begin
        // 示例: 喂入向量 → @(posedge clk) → if (out !== expected) $error;
        repeat (100) @(posedge pclk);
        $display("[%t] %m 仿真结束", $time);
        $finish;
    end

endmodule
