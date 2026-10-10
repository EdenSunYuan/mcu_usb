//============================================================================
// nrzi_ref.vh — NRZI 编解码参考模型 (纯 Verilog function/task)
//
// NRZI 编码规则 (USB 1.1 §7.1.6):
//   data=0 → 翻转 NRZI 电平 (level toggle)
//   data=1 → 保持 NRZI 电平 (no change)
//
// NRZI 解码规则:
//   电平变化 → data=0
//   电平不变 → data=1
//
// 空闲态: J (rxdp=1, rxdn=0), NRZI 电平=1
//
// 用此参考模型在 testbench 内计算期望值，避免硬编码黄金向量
//============================================================================

`ifndef NRZI_REF_VH
`define NRZI_REF_VH

// 编码器参考: 给定当前电平 + 数据位，返回输出电平
function enc_ref;
    input cur_level;   // 当前 NRZI 电平
    input d;           // 数据位 (0=翻转, 1=保持)
    begin
        enc_ref = d ? cur_level : ~cur_level;
    end
endfunction

// 解码器参考: 给定前一个电平 + 当前电平，返回数据位
function dec_ref;
    input prev_level;  // 上一拍 NRZI 电平
    input cur_level;   // 当前拍 NRZI 电平
    begin
        dec_ref = (prev_level == cur_level) ? 1'b1 : 1'b0;
    end
endfunction

`endif
