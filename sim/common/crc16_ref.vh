//============================================================================
// crc16_ref.vh — USB 1.1 CRC16 参考模型 (纯 Verilog 函数)
//
// 多项式: x^16 + x^15 + x^2 + 1 (0x8005)
// 种子:   0xFFFF (全 1)
// 数据序: LSB first (每字节 bit0 先发送)
// CRC 发送序: MSB first (~rem[15] 先发送)
// 发送前: 取反 (~)
// 残差:   0x800D (规范 §8.3.5.2)
//
// 用此参考模型在 testbench 内计算期望值，避免硬编码黄金向量
//============================================================================

`ifndef CRC16_REF_VH
`define CRC16_REF_VH

// 对字节流计算 CRC16 余数 (未取反)
// bytes: 数据字节数组 (通过 generate 或逐字节函数实现)
// n: 字节数

// 单步 CRC16 移位
function [15:0] crc16_step;
    input [15:0] crc;
    input        d;
    begin
        crc16_step = {crc[14:0], 1'b0} ^ ((crc[15] ^ d) ? 16'h8005 : 16'h0000);
    end
endfunction

// 喂一个字节 (LSB first) 并返回新 CRC
function [15:0] crc16_feed_byte;
    input [15:0] crc;
    input [7:0]  b;
    integer i;
    reg [15:0] c;
    begin
        c = crc;
        for (i = 0; i < 8; i = i + 1)
            c = crc16_step(c, b[i]);
        crc16_feed_byte = c;
    end
endfunction

// 计算多字节 payload 的 CRC16 余数 (种子 0xFFFF, 未取反)
// 由于 Verilog function 不支持动态数组，使用 8 个字节参数 + nbytes
function [15:0] crc16_rem;
    input [7:0] b0, b1, b2, b3, b4, b5, b6, b7;
    input [6:0] nbytes;
    reg [15:0] c;
    integer i;
    reg [7:0] bytes [0:7];
    begin
        bytes[0]=b0; bytes[1]=b1; bytes[2]=b2; bytes[3]=b3;
        bytes[4]=b4; bytes[5]=b5; bytes[6]=b6; bytes[7]=b7;
        c = 16'hFFFF;
        for (i = 0; i < nbytes; i = i + 1)
            c = crc16_feed_byte(c, bytes[i]);
        crc16_rem = c;
    end
endfunction

// 计算发送 CRC 值 (取反后的余数)
function [15:0] crc16_tx;
    input [7:0] b0, b1, b2, b3, b4, b5, b6, b7;
    input [6:0] nbytes;
    begin
        crc16_tx = ~crc16_rem(b0, b1, b2, b3, b4, b5, b6, b7, nbytes);
    end
endfunction

`endif
