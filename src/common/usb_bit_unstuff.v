//============================================================================
// usb_bit_unstuff.v — 位解填充器
// Bit Unstuffer (USB 1.1 spec 7.1.9)
//
// 规则: 连续6个1之后的0是stuffed bit, 接收端丢弃
// Rule: a '0' following six consecutive '1's is a stuffed bit; discard it
//
// 使用: NRZI解码之后, 每拍喂1个解码位
// Usage: after NRZI decode, feed one decoded bit per cycle
//   被丢弃的stuffed 0不产生输出 (d_out_valid=0)
//   discarded stuffed 0s produce no output
//============================================================================
`timescale 1ns/1ps

module usb_bit_unstuff (
    input  wire clk,         // 时钟 / clock
    input  wire rstn,        // 异步复位 低有效 / async reset active-low
    input  wire d_in,        // 解码后的输入位 / decoded input bit
    input  wire d_valid,     // 输入位有效 / input bit valid
    output reg  d_out,       // 去除stuffed 0的数据位 / bit without stuffed 0s
    output reg  d_out_valid  // 输出位有效 / output bit valid
);

    reg [2:0] ones_cnt;      // 连续1计数(饱和6) / consecutive-ones count

    wire discard = d_valid && !d_in && (ones_cnt == 3'd6);
    wire out_bit = d_valid && !discard;

    // ---- 连续1计数 ----
    // Consecutive-ones counter
    always @(posedge clk or negedge rstn) begin
        if (!rstn)
            ones_cnt <= 3'd0;
        else if (d_valid) begin
            if (d_in) begin
                if (ones_cnt < 3'd6)
                    ones_cnt <= ones_cnt + 1'b1;
            end else begin
                ones_cnt <= 3'd0;
            end
        end
    end

    // ---- d_out 寄存器 ----
    // Data output register
    always @(posedge clk or negedge rstn) begin
        if (!rstn)
            d_out <= 1'b0;
        else
            d_out <= d_in;
    end

    // ---- d_out_valid 寄存器 ----
    // Data valid output register
    always @(posedge clk or negedge rstn) begin
        if (!rstn)
            d_out_valid <= 1'b0;
        else
            d_out_valid <= out_bit;
    end

endmodule
