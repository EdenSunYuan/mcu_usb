`timescale 1ns/1ps
//============================================================================
// usb_crc5_byte.v — CRC-5 字节并行版 (1 字节/拍)
//                 byte-parallel CRC-5 (one byte per clock)
//
// 用途     : 保护 TOKEN 包的 ADDR+ENDP 字段（11 bit），供 SIE 接收路径用
// Purpose  : protects ADDR+ENDP fields of TOKEN packets; used by the SIE RX path
//
// 为什么要这一版（usb_sie_design.md §2.5.1）:
//   FS 下 1 字节 = 8 个 clk12m 周期，位串行 usb_crc5.v 正好 100% 占用、零余量；
//   本模块把位串行的 8 拍展开成 1 拍。算法与 usb_crc5.v 完全一致：
//     种子 = 0x1F；每数据位 fb = crc[4]^d; crc = (crc<<1) ^ (fb ? 0x05 : 0)
//   展开后每位是一组 tap 的异或（余数对该输入是 GF(2) 线性的）。
//   tap 集合由 tools/gen_crc_gold.py --eq 生成，该脚本内置「展开式 == 逐位算法」
//   的等价自检（64 组随机种子 × 256 个字节），改动方程请先跑它。
//
// 使用: crc_clr 载种子, 每拍 crc_en 喂 1 个字节(线序, bit0 先发)。TOKEN 的 CRC5
//       恰好盖住 2 个整字节（byte1+byte2 = 11 bit 数据 + 5 bit CRC），所以喂完
//       这 2 字节直接查残差 == 0x0C 即可，不需要处理非字节对齐（§2.3）。
//============================================================================

module usb_crc5_byte (
    input  wire       clk,        // 时钟/clock
    input  wire       rstn,       // 异步复位,低有效/async reset, active-low
    input  wire       crc_en,     // 字节有效(处理一个字节)/process one byte
    input  wire       crc_clr,    // 复位到种子全1/load seed (all-ones)
    input  wire [7:0] d_in,       // 输入字节(线序, bit0 先)/data byte (wire order)
    output reg  [4:0] crc_out     // 当前余数(未取反)/current remainder
);

    // 余数次值（字节并行更新方程，每位一组 tap）
    wire [4:0] crc_out_nxt;

    // crc_out_nxt[0]：被 4 个余数位 + 4 个数据位驱动
    assign crc_out_nxt[0] = crc_out[0] ^ crc_out[2] ^ crc_out[3]
                          ^ d_in[1] ^ d_in[2] ^ d_in[4] ^ d_in[7];

    // crc_out_nxt[1]
    assign crc_out_nxt[1] = crc_out[1] ^ crc_out[3] ^ crc_out[4]
                          ^ d_in[0] ^ d_in[1] ^ d_in[3] ^ d_in[6];

    // crc_out_nxt[2]
    assign crc_out_nxt[2] = crc_out[0] ^ crc_out[3] ^ crc_out[4]
                          ^ d_in[0] ^ d_in[1] ^ d_in[4] ^ d_in[5] ^ d_in[7];

    // crc_out_nxt[3]
    assign crc_out_nxt[3] = crc_out[0] ^ crc_out[1] ^ crc_out[4]
                          ^ d_in[0] ^ d_in[3] ^ d_in[4] ^ d_in[6];

    // crc_out_nxt[4]
    assign crc_out_nxt[4] = crc_out[1] ^ crc_out[2]
                          ^ d_in[2] ^ d_in[3] ^ d_in[5];

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            crc_out <= 5'b11111;            // 异步复位/async reset
        end else if (crc_clr) begin
            crc_out <= 5'b11111;            // 种子加载/load seed
        end else if (crc_en) begin
            crc_out <= crc_out_nxt;         // 逐字节更新/update per byte
        end
    end

endmodule
