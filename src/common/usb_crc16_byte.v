`timescale 1ns/1ps
//============================================================================
// usb_crc16_byte.v — CRC-16 字节并行版 (1 字节/拍)
//                  byte-parallel CRC-16 (one byte per clock)
//
// 用途     : 保护 DATA 包的数据字段，供 SIE 接收路径用
// Purpose  : protects the DATA field of DATA packets; used by the SIE RX path
//
// 为什么要这一版（usb_sie_design.md §2.5.1）:
//   FS 下 1 字节 = 8 个 clk12m 周期，位串行 usb_crc16.v 正好 100% 占用、零余量，
//   而且包尾还要额外 16 拍才出残差（1.33 µs，远超应答窗口）。本模块把位串行的
//   8 拍展开成 1 拍。算法与 usb_crc16.v 完全一致：
//     种子 = 0xFFFF；每数据位 fb = crc[15]^d; crc = (crc<<1) ^ (fb ? 0x8005 : 0)
//   展开后每位是一组 tap 的异或（余数对该输入是 GF(2) 线性的）。
//   tap 集合由 tools/gen_crc_gold.py --eq 生成，该脚本内置「展开式 == 逐位算法」
//   的等价自检（64 组随机种子 × 256 个字节），改动方程请先跑它。
//
// 使用: crc_clr 载种子, 每拍 crc_en 喂 1 个字节(线序, bit0 先发)。接收侧喂完
//       净荷 + 收到的 2 个 CRC 字节，残差 == 0x800D 则包有效。
//============================================================================

module usb_crc16_byte (
    input  wire        clk,        // 时钟/clock
    input  wire        rstn,       // 异步复位,低有效/async reset, active-low
    input  wire        crc_en,     // 字节有效(处理一个字节)/process one byte
    input  wire        crc_clr,    // 复位到种子全1/load seed (all-ones)
    input  wire [7:0]  d_in,       // 输入字节(线序, bit0 先)/data byte (wire order)
    output reg  [15:0] crc_out     // 当前余数(未取反)/current remainder
);

    // 余数次值（字节并行更新方程，每位一组 tap）
    wire [15:0] crc_out_nxt;

    // crc_out_nxt[0]：被 8 个余数位 + 8 个数据位驱动
    assign crc_out_nxt[0] = crc_out[8]  ^ crc_out[9]  ^ crc_out[10] ^ crc_out[11]
                          ^ crc_out[12] ^ crc_out[13] ^ crc_out[14] ^ crc_out[15]
                          ^ d_in[0] ^ d_in[1] ^ d_in[2] ^ d_in[3]
                          ^ d_in[4] ^ d_in[5] ^ d_in[6] ^ d_in[7];

    // crc_out_nxt[1]
    assign crc_out_nxt[1] = crc_out[9]  ^ crc_out[10] ^ crc_out[11] ^ crc_out[12]
                          ^ crc_out[13] ^ crc_out[14] ^ crc_out[15]
                          ^ d_in[0] ^ d_in[1] ^ d_in[2] ^ d_in[3]
                          ^ d_in[4] ^ d_in[5] ^ d_in[6];

    // crc_out_nxt[2]
    assign crc_out_nxt[2] = crc_out[8] ^ crc_out[9] ^ d_in[6] ^ d_in[7];

    // crc_out_nxt[3]
    assign crc_out_nxt[3] = crc_out[9] ^ crc_out[10] ^ d_in[5] ^ d_in[6];

    // crc_out_nxt[4]
    assign crc_out_nxt[4] = crc_out[10] ^ crc_out[11] ^ d_in[4] ^ d_in[5];

    // crc_out_nxt[5]
    assign crc_out_nxt[5] = crc_out[11] ^ crc_out[12] ^ d_in[3] ^ d_in[4];

    // crc_out_nxt[6]
    assign crc_out_nxt[6] = crc_out[12] ^ crc_out[13] ^ d_in[2] ^ d_in[3];

    // crc_out_nxt[7]
    assign crc_out_nxt[7] = crc_out[13] ^ crc_out[14] ^ d_in[1] ^ d_in[2];

    // crc_out_nxt[8]
    assign crc_out_nxt[8] = crc_out[0] ^ crc_out[14] ^ crc_out[15] ^ d_in[0] ^ d_in[1];

    // crc_out_nxt[9]
    assign crc_out_nxt[9] = crc_out[1] ^ crc_out[15] ^ d_in[0];

    // crc_out_nxt[10..14]：纯移位
    assign crc_out_nxt[10] = crc_out[2];
    assign crc_out_nxt[11] = crc_out[3];
    assign crc_out_nxt[12] = crc_out[4];
    assign crc_out_nxt[13] = crc_out[5];
    assign crc_out_nxt[14] = crc_out[6];

    // crc_out_nxt[15]：被 9 个余数位 + 8 个数据位驱动
    assign crc_out_nxt[15] = crc_out[7]  ^ crc_out[8]  ^ crc_out[9]  ^ crc_out[10]
                           ^ crc_out[11] ^ crc_out[12] ^ crc_out[13] ^ crc_out[14]
                           ^ crc_out[15]
                           ^ d_in[0] ^ d_in[1] ^ d_in[2] ^ d_in[3]
                           ^ d_in[4] ^ d_in[5] ^ d_in[6] ^ d_in[7];

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            crc_out <= 16'hFFFF;            // 异步复位/async reset
        end else if (crc_clr) begin
            crc_out <= 16'hFFFF;            // 种子加载/load seed
        end else if (crc_en) begin
            crc_out <= crc_out_nxt;         // 逐字节更新/update per byte
        end
    end

endmodule
