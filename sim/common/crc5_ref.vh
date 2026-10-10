//============================================================================
// crc5_ref.vh — USB 1.1 CRC5 参考模型 (纯 Verilog 函数)
//
// 多项式: x^5 + x^2 + 1 (0x05)
// 种子:   0x1F (全 1)
// 数据序: LSB first (addr[0] 先发送, 然后 addr[1]...endp[3])
// CRC 发送序: MSB first (~rem[4] 先发送)
// 发送前: 取反 (~)
// 残差:   0x0C (规范 §8.3.5.1)
//
// 用此参考模型在 testbench 内计算期望值，避免硬编码黄金向量
//============================================================================

`ifndef CRC5_REF_VH
`define CRC5_REF_VH

// 通用 11-bit CRC5 余数 (未取反)
// data: 任意 11-bit 数据, data[0] 先发送 (Token 的 ADDR+ENDP, 或 SOF 的帧号)
function [4:0] crc5_rem_11;
    input [10:0] data;
    reg [4:0] c;
    integer i;
    begin
        c = 5'h1F;                       // 种子全 1
        for (i = 0; i < 11; i = i + 1) begin
            c = {c[3:0], 1'b0} ^ ((c[4] ^ data[i]) ? 5'h05 : 5'h00);
        end
        crc5_rem_11 = c;
    end
endfunction

// 计算 ADDR+ENDP (11 bit, LSB first) 的 CRC5 余数 (未取反)
function [4:0] crc5_rem;
    input [6:0] addr;
    input [3:0] endp;
    begin
        // LSB first: addr[0]→addr[6]→endp[0]→endp[3]
        crc5_rem = crc5_rem_11({endp[3:0], addr[6:0]});
    end
endfunction

// 计算 Token 发送 CRC 值 (取反后的余数)
function [4:0] crc5_tx;
    input [6:0] addr;
    input [3:0] endp;
    begin
        crc5_tx = ~crc5_rem(addr, endp);
    end
endfunction

// 计算 SOF 发送 CRC 值 (frame number 11-bit, 取反后的余数)
function [4:0] crc5_tx_11;
    input [10:0] data;
    begin
        crc5_tx_11 = ~crc5_rem_11(data);
    end
endfunction

`endif
