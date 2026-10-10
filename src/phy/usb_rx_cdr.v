//==================================================
// Created by        : xxx
// Filename          : usb_rx_cdr.v
// Author            : xiao_yuan
// Created On        : 2026-09-04 17:31
// Last Modified     :
// Update Count      : 2026-09-20 规则 7 改造（骨架/命名，逻辑未动）
// Description       : USB 1.1 FS RX 时钟数据恢复（Intel SIE DPLL, Fig.2）
//
//   职责：只从模拟 PHY 的单端 DP/DN 里，恢复出 12MHz 位时钟 + NRZI 电平位流——
//     单 48MHz ref_clk(4×) → 16 态 DPLL → dclk(恢复时钟) + rx_bit(NRZI 电平)
//   不碰字节对齐 / SYNC / 解填充，那些是 usb_rx_deserial 的活；本模块不解释数据内容。
//
//   双沿采样（本设计的一半精度来源）：a_reg 在 ref_clk 上升沿采 rxdp，
//   b_reg 在下降沿采 rxdp；两点相隔半个 ref_clk，用来判「电平在这半个周期里跳没跳」，
//   等效 8× 过采样，故 16 态即可锁 12MHz。
//
//   状态编码（4 bit，16 态）：stat_cur[1] = 恢复时钟位（dclk 的来源，再打一拍去毛刺）；
//   stat_cur[2] = NRZI 电平（0=K, 1=J）。
//     左环(电平 K)：1→3→2→0        右环(电平 J)：5→7→6→4
//     锁存：C, D                    长 bit 绕行：F, B
//
//   设计报告：doc/design_rpt/02_cdr_design.md
//     §2.3 双沿采样 / §2.4 DPLL 状态机 / §3.3 常量 / §4.5 去毛刺 / §4.6 数据提取
//   验证报告：doc/design_rpt/02_cdr_verification.md
//==================================================

`timescale 1ns/1ps

///////////////////////////////
//  INSTANCE FILE PATH
///////////////////////////////
// Instance: demo.v
module usb_rx_cdr(/*autoarg*/
    //Inputs
    ref_clk, ref_rstn, rxdp, rxdn,

    //Outputs
    dclk, rx_bit);

///////////////////////////////
//  PARAMETER DEFINE
///////////////////////////////
// DPLL 状态编码：4 bit 就是状态序号本身（0~15 全枚举在下面的 case 里），
// 这里只给 4 个「有名字的特殊态」取常量，其余直接用 4'dN 字面量。
localparam [3:0] ST_C = 4'd12;  // 锁存：等 b 采样到 0 才放行
localparam [3:0] ST_D = 4'd13;  // 锁存：b 采样到 1 则出锁，进右环
localparam [3:0] ST_F = 4'd15;  // 长 bit 绕行（左环 3 跳来）
localparam [3:0] ST_B = 4'd11;  // 长 bit 绕行（右环 7 跳来）

///////////////////////////////
//  INPUT & OUTPUT
///////////////////////////////
input           ref_clk;    // 48MHz 参考时钟（4×），采样与状态机都用它
input           ref_rstn;   // 异步复位，低有效
input           rxdp;       // USB D+ 单端（J=1, K=0）
input           rxdn;       // USB D- 单端（只做 SE0 判据，本模块暂未用其值）

// to phy
output          dclk;       // 恢复的 12MHz 时钟：送 usb_clk_mux 当 dclk 输入
output          rx_bit;     // NRZI 电平（0=K/1=J）：送 usb_rx_deserial，领先 dclk 1 个 ref_clk

///////////////////////////////
//  WIRE  & REG DECLARE
///////////////////////////////
/*autodefine*/
// Define flip-flop registers here
reg             a_reg;           // ref_clk 上升沿采样的 rxdp（DPLL 的 a 支路）
reg             b_reg;           // ref_clk 下降沿采样的 rxdp（DPLL 的 b 支路）
reg  [3:0]      stat_cur;        // 16 态 DPLL：现态寄存器
reg             clk12m_reg;     // 恢复时钟输出寄存器（state_clk 打一拍去毛刺）
// Define combination registers here
reg  [3:0]      stat_nxt;        // 16 态 DPLL：次态组合值
// Define wires here
wire            state_clk;       // 恢复时钟原始位 = stat_cur[1]（DFF Q 的位切片）
wire            state_data;      // NRZI 电平位 = stat_cur[2]（DFF Q 的位切片）
wire            nxt_clk;         // 次态里的时钟位 = stat_nxt[1]（纯观测，逻辑不引用）
// Define instances' ouput wires here
// End of automatic define

///////////////////////////////
//  RTL LOGIC
///////////////////////////////

//-----------------------------------------------------------------------------
// a 支路采样 · ref_clk 上升沿采 rxdp
//-----------------------------------------------------------------------------
always @(posedge ref_clk or negedge ref_rstn) begin
    if (!ref_rstn) begin
        a_reg <= 1'b1;                  // 复位到 idle J
    end
    else begin
        a_reg <= rxdp;
    end
end

//-----------------------------------------------------------------------------
// b 支路采样 · ref_clk 下降沿采 rxdp
//   ★ 这是本模块唯一的负沿时序块。a/b 相隔半个 ref_clk，两者一比就知道
//     「这半个周期里电平跳过没有」，等效 8× 过采样——别把它改成上升沿。
//-----------------------------------------------------------------------------
always @(negedge ref_clk or negedge ref_rstn) begin
    if (!ref_rstn) begin
        b_reg <= 1'b1;                  // 复位到 idle J
    end
    else begin
        b_reg <= rxdp;
    end
end

//-----------------------------------------------------------------------------
// DPLL 状态机 · 组合段：现态 + a/b 采样 → 次态
//   左环(电平 K) 1→3→2→0 与 右环(电平 J) 5→7→6→4 各 4 态循环；C/D 是锁存对，
//   F/B 是长 bit（1.5 bit 宽）绕行。全部现态译码，不引任何次值线（规则 6）。
//-----------------------------------------------------------------------------
always @(*) begin
    case (stat_cur[3:0])
    // 锁存 / Lock Acquisition
    ST_C: begin
        stat_nxt[3:0] = (b_reg != 1'b0) ? ST_C : ST_D;
    end
    ST_D: begin
        stat_nxt[3:0] = (b_reg == 1'b0) ? ST_D : 4'd5;
    end

    // 左环(电平 K) / Left Loop (level K)
    4'd1: begin
        stat_nxt[3:0] = 4'd3;
    end
    4'd3: begin
        stat_nxt[3:0] = (a_reg == 1'b0) ? 4'd2 : ST_F;
    end
    4'd2: begin
        stat_nxt[3:0] = (b_reg == 1'b0) ? 4'd0 : 4'd5;
    end
    4'd0: begin
        stat_nxt[3:0] = (b_reg == 1'b0) ? 4'd1 : 4'd5;
    end

    // 右环(电平 J) / Right Loop (level J)
    4'd5: begin
        stat_nxt[3:0] = 4'd7;
    end
    4'd7: begin
        stat_nxt[3:0] = (a_reg == 1'b1) ? 4'd6 : ST_B;
    end
    4'd6: begin
        stat_nxt[3:0] = (b_reg == 1'b1) ? 4'd4 : 4'd1;
    end
    4'd4: begin
        stat_nxt[3:0] = (b_reg == 1'b1) ? 4'd5 : 4'd1;
    end

    // 长 bit 绕行 / Long-bit Detour
    ST_F: begin
        stat_nxt[3:0] = 4'd6;
    end
    ST_B: begin
        stat_nxt[3:0] = 4'd2;
    end

    default: begin
        stat_nxt[3:0] = ST_C;
    end
    endcase
end

//-----------------------------------------------------------------------------
// DPLL 状态机 · 时序段：现态寄存器（唯一状态更新点）
//-----------------------------------------------------------------------------
always @(posedge ref_clk or negedge ref_rstn) begin
    if (!ref_rstn) begin
        stat_cur[3:0] <= ST_C;              // 复位进锁存对
    end
    else begin
        stat_cur[3:0] <= stat_nxt[3:0];
    end
end

//-----------------------------------------------------------------------------
// 状态位切片：恢复时钟位 / NRZI 电平位
//   两者都是状态寄存器 Q 的位切片，中间没有任何组合逻辑（规则 6 直接达标）。
//-----------------------------------------------------------------------------
assign state_clk  = stat_cur[1];
assign state_data = stat_cur[2];

// 次态里的时钟位：纯观测点，逻辑不引用；保留是为了波形与覆盖率能看到次态译码结果
assign nxt_clk = stat_nxt[1];

//-----------------------------------------------------------------------------
// 恢复时钟输出 dclk：state_clk 再打一拍去毛刺
//   规则 6：dclk 跨出本模块去 clk_mux 选时钟，必须 DFF 直出。
//   打这一拍是滤掉状态译码瞬间可能出现的窄脉冲——DPLL 每态只停 1 个 ref_clk，
//   直接从 stat_cur[1] 出会把毛刺送到时钟选择逻辑上（报告 §4.5）。
//-----------------------------------------------------------------------------
always @(posedge ref_clk or negedge ref_rstn) begin
    if (!ref_rstn) begin
        clk12m_reg <= 1'b0;
    end
    else begin
        clk12m_reg <= state_clk;
    end
end

assign dclk = clk12m_reg;

//-----------------------------------------------------------------------------
// NRZI 电平输出 rx_bit：直接取状态位切片（规则 6：DFF Q 直出）
//   ★ 这里不能再补触发器——rx_bit 必须比 dclk 早 1 个 ref_clk，
//     多打一拍会把整个位流后移，破坏 deserial 依赖的相位关系（报告 §4.6）。
//-----------------------------------------------------------------------------
assign rx_bit = state_data;

endmodule
