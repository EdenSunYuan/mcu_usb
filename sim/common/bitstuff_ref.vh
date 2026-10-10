//============================================================================
// bitstuff_ref.vh — 位填充/解填充参考模型 (纯 Verilog function)
//
// USB 位填充规则 (USB 1.1 §7.1.9):
//   发送方: 数据流中每连续 6 个 data=1 后插入一个 stuffed 0
//   接收方: 检测到 6 个连续 1 后丢弃紧跟的 stuffed 0
//
// 注: NRZI 编码在 bit-stuffing 之前进行
//
// 用此参考模型在 testbench 内计算期望值，避免硬编码黄金向量
//============================================================================

`ifndef BITSTUFF_REF_VH
`define BITSTUFF_REF_VH

// 位填充参考: 输入数据位 + 当前连续 1 计数 → {输出位(可能含 stuffed 0), 新计数}
// 返回: 2-bit: {has_stuffed_bit, stuffed_bit_value}
//   bit[1]=1 表示需要先输出一个 stuffed 0, bit[0] 总是 0
//   调用方: 先检查 bit[1], 若=1 则输出 stuffed 0; 然后输出原始数据位

// 简化版: 直接返回是否需要插入 stuffed 0
function stuff_check;
    input [3:0] ones_cnt;  // 当前连续 1 计数 (0-6)
    input       d;          // 当前数据位
    begin
        // 如果已连续 6 个 1 且当前数据位仍是 1 → 需要插入 stuffed 0
        stuff_check = (ones_cnt == 4'd6 && d == 1'b1);
    end
endfunction

// 更新连续 1 计数 (考虑 stuffed 0 重置)
function [3:0] stuff_next_cnt;
    input [3:0] ones_cnt;
    input       d;          // 发送的数据位 (非 stuffed)
    begin
        if (d == 1'b1)
            stuff_next_cnt = ones_cnt + 1;
        else
            stuff_next_cnt = 0;
    end
endfunction

`endif
