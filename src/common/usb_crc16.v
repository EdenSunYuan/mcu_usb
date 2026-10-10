`timescale 1ns/1ps
//============================================================================
// usb_crc16.v — CRC-16 生成/校验器
//             CRC-16 generator/checker (USB 1.1 spec §8.3.5.2)
//
// 用途     : 保护 DATA 包的数据字段 (逐字节, 每字节内 LSb first)
// Purpose  : protects the DATA field of DATA packets
//
// 算法 (来自规范, bit-serial):
//   1. 种子 = 全 1 (0xFFFF)                    seed = all-ones (0xFFFF)
//   2. 每数据位: fb = crc[15]^d; crc=(crc<<1); if fb: crc^=0x8005
//      per bit: fb = crc[15]^d; crc=(crc<<1); if fb: crc ^= 0x8005
//   3. 多项式 = x^16+x^15+x^2+1 (0x8005)       poly = 0x8005
//   4. 发送前 CRC 取反 + MSB first 发送         transmit ~crc, MSB first
//   5. 接收残差 = 0x800D                       RX residual = 0x800D
//
// 使用: crc_clr 复位到种子后, 每拍 crc_en 喂 1 个数据位。
//       数据字节须按 LSb first 逐位喂入, 字节按序。
//       TX 侧发 ~crc_out[15:0] (MSB first);
//       RX 侧喂完数据再喂收到的 16 位 CRC, 结果 == 0x800D 则包有效。
//============================================================================

module usb_crc16 (
    input  wire        clk,        // 时钟/clock
    input  wire        rstn,       // 异步复位,低有效/async reset, active-low
    input  wire        crc_en,     // 数据位有效(处理一位)/process one data bit
    input  wire        crc_clr,    // 复位到种子全1/load seed (all-ones)
    input  wire        d_in,       // 输入数据位(线上序)/data bit (wire order)
    output reg  [15:0] crc_out     // 当前余数(未取反)/current remainder
);

    // 反馈位 = 最高位 ^ 数据位 / feedback = top bit XOR data
    wire fb = crc_out[15] ^ d_in;

    // 左移一位, 低位补 0, 需要时异或多项式 / shift left, if fb XOR poly
    wire [15:0] crc_next = {crc_out[14:0], 1'b0} ^ (fb ? 16'h8005 : 16'h0000);

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            crc_out <= 16'hFFFF;            // 异步复位/async reset
        end else if (crc_clr) begin
            crc_out <= 16'hFFFF;            // 种子加载/load seed
        end else if (crc_en) begin
            crc_out <= crc_next;            // 逐位更新/update per bit
        end
    end

endmodule
