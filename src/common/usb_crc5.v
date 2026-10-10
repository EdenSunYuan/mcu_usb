`timescale 1ns/1ps
//============================================================================
// usb_crc5.v — CRC-5 生成/校验器
//            CRC-5 generator/checker (USB 1.1 spec §8.3.5.1)
//
// 用途     : 保护 TOKEN 包的 ADDR+ENDP 字段 (11 bit)
// Purpose  : protects ADDR+ENDP fields of TOKEN packets (11 bits)
//
// 算法 (来自规范, bit-serial):
//   1. 种子 = 全 1 (0x1F)                       seed = all-ones (0x1F)
//   2. 每数据位: fb = crc[4]^d; crc=(crc<<1); if fb: crc^=0x05
//      per bit: fb = crc[4]^d; crc=(crc<<1); if fb: crc ^= 0x05
//   3. 多项式 = x^5+x^2+1  (00101B)             poly = x^5+x^2+1
//   4. 发送前 CRC 取反 + MSB first 发送          transmit ~crc, MSB first
//   5. 接收残差 = 01100B (0x0C)                 RX residual = 0x0C
//
// 使用: crc_clr 复位到种子后, 每拍 crc_en 喂 1 个数据位(线上序)。
//       TX 侧发 ~crc_out[4:0] (MSB first);
//       RX 侧喂完数据位再喂收到的 CRC 位, 若结果为 0x0C 则包有效。
// Usage: assert crc_clr to load seed, then feed one data bit per crc_en.
//       TX: transmit ~crc_out MSB first; RX: residual==0x0C means valid.
//============================================================================

module usb_crc5 (
    input  wire       clk,        // 时钟/clock
    input  wire       rstn,       // 异步复位,低有效/async reset, active-low
    input  wire       crc_en,     // 数据位有效(处理一位)/process one data bit
    input  wire       crc_clr,    // 复位到种子全1/load seed (all-ones)
    input  wire       d_in,       // 输入数据位(线上序)/data bit (wire order)
    output reg  [4:0] crc_out     // 当前余数(未取反)/current remainder
);

    // 反馈位 = 最高位 ^ 数据位 / feedback = top bit XOR data
    wire fb = crc_out[4] ^ d_in;

    // 左移一位, 低位补 0, 需要时异或多项式 / shift left, if fb XOR poly
    wire [4:0] crc_next = {crc_out[3:0], 1'b0} ^ (fb ? 5'b00101 : 5'b00000);

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            crc_out <= 5'b11111;            // 异步复位/async reset
        end else if (crc_clr) begin
            crc_out <= 5'b11111;            // 种子加载/load seed
        end else if (crc_en) begin
            crc_out <= crc_next;            // 逐位更新/update per bit
        end
    end

endmodule
