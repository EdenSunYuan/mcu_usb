`timescale 1ns/1ps
//============================================================================
// tb_usb_crc5.v — usb_crc5 测试台骨架 (rtl_autogen.py tb 自动生成)
// DUT: src/common/usb_crc5.v  module usb_crc5 (6 端口)
// TODO: 在 "激励与自检" 区补充测试向量与结果比对
//============================================================================

module tb_usb_crc5;

    // ---- 时钟 ----
    reg clk = 1'b0;                    // 初值必须给, 否则 ~X 仍为 X 无沿
    parameter CLK_PERIOD = 10.0;                 // 时钟周期 ns
    always #(CLK_PERIOD/2.0) clk = ~clk;

    // ---- 复位 (低有效) ----
    reg rstn;

    // ---- DUT 输入激励 ----
    reg        crc_en ;   // 数据位有效(处理一位)/process one data bit
    reg        crc_clr;   // 复位到种子全1/load seed (all-ones)
    reg        d_in   ;   // 输入数据位(线上序)/data bit (wire order)

    // ---- DUT 输出观测 ----
    wire [4:0] crc_out;

    // ---- DUT 实例 ----
    usb_crc5 dut (
        .clk      (clk),
        .rstn     (rstn),
        .crc_en   (crc_en),
        .crc_clr  (crc_clr),
        .d_in     (d_in),
        .crc_out  (crc_out)
    );

    // ---- 复位流程 ----
    initial begin
        rstn = 1'b0;
        repeat (5) @(posedge clk);
        rstn = 1'b1;
    end

    // ---- 波形转储 ----
    initial begin
        $dumpfile("tb_usb_crc5.vcd");
        $dumpvars(0, tb_usb_crc5);
    end

    // ---- 激励与自检 (TODO: 手动补充) ----
    initial begin
        // 示例: 喂入向量 → @(posedge clk) → if (out !== expected) $error;
        repeat (100) @(posedge clk);
        $display("[%t] %m 仿真结束", $time);
        $finish;
    end

endmodule
