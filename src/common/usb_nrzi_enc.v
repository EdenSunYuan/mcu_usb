//============================================================================
// usb_nrzi_enc.v — NRZI 编码器
// NRZI Encoder (USB 1.1 spec 7.1.10)
//
// NRZI 规则:
// NRZI rule:
//   数据位 0 = 电平翻转 (toggle)
//     data 0 = toggle level
//   数据位 1 = 电平保持 (keep)
//     data 1 = keep level
//
// 初始电平 = J (空闲态)
// Initial level = J (idle)
//   FS设备: J = D+高, D-低
//   FS device: J = D+ high, D- low
//============================================================================
`timescale 1ns/1ps

module usb_nrzi_enc (
    input  wire clk,         // 时钟 / clock
    input  wire rstn,        // 异步复位 低有效 / async reset active-low
    input  wire nrzi_rst,    // 复位到J态 / reset to idle J
    input  wire nrzi_en,     // 处理一个数据位 / process one data bit
    input  wire d_in,        // 数据位 (0=翻转, 1=保持) / data bit (0=toggle,1=keep)
    output reg  nrzi_out     // 编码后电平 (1=J, 0=K) / encoded level
);

    // ---- nrzi_out 寄存器 ----
    // Encoded level register
    always @(posedge clk or negedge rstn) begin
        if (!rstn)
            nrzi_out <= 1'b1;               // idle J
        else if (nrzi_rst)
            nrzi_out <= 1'b1;               // 进入空闲态 / enter idle
        else if (nrzi_en)
            nrzi_out <= d_in ? nrzi_out : ~nrzi_out;
            // 0翻转 1保持 / toggle on 0, keep on 1
    end

endmodule
