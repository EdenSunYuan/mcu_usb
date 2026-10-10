//============================================================================
// usb_nrzi_dec.v — NRZI 解码器
// NRZI Decoder (USB 1.1 spec 7.1.10)
//
// 解码规则:
// Decoding rule:
//   当前电平与上一电平相同 => 数据 1
//     same as previous level => data 1
//   当前电平与上一电平不同 => 数据 0
//     different from previous => data 0
//
// 初始上一电平 = J (空闲态)
// Previous level init = J (idle)
//============================================================================
`timescale 1ns/1ps

module usb_nrzi_dec (
    input  wire clk,         // 时钟 / clock
    input  wire rstn,        // 异步复位 低有效 / async reset active-low
    input  wire dec_en,      // 采样一个电平 / sample one level
    input  wire dec_rst,     // 复位上一电平到J / reset prev level to idle J
    input  wire nrzi_in,     // 输入电平 / input level (differential data)
    output reg  d_out,       // 解码数据位 / decoded data bit (0=toggle,1=hold)
    output reg  last_level   // 上一采样电平 / previous sampled level
);

    // ---- last_level 寄存器 ----
    // Previous level register
    always @(posedge clk or negedge rstn) begin
        if (!rstn)
            last_level <= 1'b1;         // idle J
        else if (dec_rst)
            last_level <= 1'b1;         // 恢复空闲态 / restore idle
        else if (dec_en)
            last_level <= nrzi_in;
    end

    // ---- d_out 寄存器 ----
    // Decoded data output register
    always @(posedge clk or negedge rstn) begin
        if (!rstn)
            d_out <= 1'b1;
        else if (dec_rst)
            d_out <= 1'b1;
        else if (dec_en)
            d_out <= ~(nrzi_in ^ last_level);
            // 同=1, 异=0 / same=1, different=0
    end

endmodule
