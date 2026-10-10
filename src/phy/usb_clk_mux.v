//==================================================
// Created by        : xxx
// Filename          : usb_clk_mux.v
// Author            : xiao_yuan
// Created On        : 2026-09-20
// Last Modified     :
// Update Count      : 2026-09-20 首版（按 02_clk_mux_design.md 定稿实现）
// Description       : USB 1.1 FS 无毛刺时钟切换（SIE 1× 时钟 clk12m 的唯一上游开关）
//
//   职责：内部用 ref_clk ÷ 4 产生本地发送时钟 clk12s，再在 clk12s 与恢复时钟 dclk
//     之间按收发方向无毛刺选一路输出 clk12m——
//       rcv=1（接收）→ clk12m = dclk；rcv=0（发送/空闲）→ clk12m = clk12s
//   不产生时钟，只做「切断旧时钟 → 拉低过渡 → 接入新时钟」三段切换；
//   本模块不知道包边界、不知道 EOP，只管时钟这一件事。
//
//   为什么能跑在 ref_clk 域（本模块最容易被误解的一点）：两路被切换的时钟虽然
//   频率异步，边沿却都落在 ref_clk 沿上——clk12s = ref_clk÷4 天然如此；dclk 是
//   DPLL 用 4× 量化把主机相位「掰」到 ref_clk 格子上的（周期仍跟主机走 3/4/5 拍）。
//   故状态机直接在 posedge ref_clk 采样两路电平即可，无亚稳态、无异步电路。
//
//   无毛刺的两条不变式（守住这两条，切换永远安全）：
//     ① 断开后必进过渡态（ST_HOLD1/ST_HOLD2），过渡态输出恒 0；
//     ② 接入前必等目标时钟为低（0 → 0 无缝）。
//
//   状态机（4 态，两段式：次态组合 + 时序寄存），复位进 ST_TX：
//     ST_TX →(rcv & clk12s 低)→ ST_HOLD2 →(dclk 低)→ ST_RCV
//     ST_RCV →(!rcv & dclk 低)→ ST_HOLD1 →(clk12s 低)→ ST_TX
//     四个迁移条件**统一**为「要在离开/进入时切换的那一路，必须正处于低电平」——
//     这正是两条不变式的实现口径（2026-09-20 仿真修正，见 doc §4.3 修订说明）。
//
//   设计报告：doc/design_rpt/02_clk_mux_design.md
//     §2.3 无毛刺手法 / §2.4 四态状态机 / §2.5 ref_clk 域可行性 / §4.1 复位默认态 / §4.6 rcv 的 STA 约束
//==================================================
///////////////////////////////
//  INSTANCE FILE PATH
///////////////////////////////
// Instance: demo.v
module usb_clk_mux(/*autoarg*/
    //Inputs
    ref_clk, ref_rstn, dclk, rcv,

    //Outputs
    clk12m);

///////////////////////////////
//  PARAMETER DEFINE
///////////////////////////////
// 状态编码（2 bit，值就是状态序号，不追 one-hot）
localparam [1:0] ST_RCV   = 2'd0;  // 输出 dclk（接收中）
localparam [1:0] ST_HOLD1 = 2'd1;  // 输出 0（RX→TX 过渡）
localparam [1:0] ST_HOLD2 = 2'd2;  // 输出 0（TX→RX 过渡）
localparam [1:0] ST_TX    = 2'd3;  // 输出 clk12s（发送/空闲）

///////////////////////////////
//  INPUT & OUTPUT
///////////////////////////////
input           ref_clk;    //clock 48MHz 参考时钟（4×）：分频源 + 状态机时钟
input           ref_rstn;   //reset 异步复位，低有效（复位 → ST_TX、div_cnt=0）
input           dclk;       // 恢复时钟（CDR 输出），周期 3/4/5 拍但边沿 ref_clk 对齐
input           rcv;        // 接收模式标志（SIE 协议 FSM 产出，1 = 用 dclk）

// to sie
output          clk12m;     // 切换输出的 12MHz 1× 时钟（ST_RCV=dclk / ST_TX=clk12s / 过渡态=0）

///////////////////////////////
//  WIRE  & REG DECLARE
///////////////////////////////
/*autodefine*/
// Define flip-flop registers here
reg  [1:0]      div_cnt;         // ÷4 分频计数器：每拍 +1，div_cnt[1] 即 clk12s
reg  [1:0]      stat_cur;        // 4 态切换状态机：现态寄存器
// Define combination registers here
reg  [1:0]      stat_nxt;        // 4 态切换状态机：次态组合值
// Define wires here
wire            clk12s;          // 本地发送时钟 = div_cnt[1]（内部产生，不对外输出）
wire            dclk_low;        // dclk 处于低相位：接入/断离恢复时钟的唯一合法时刻
wire            clk12s_low;      // clk12s 处于低相位：接入本地时钟的唯一合法时刻
// Define instances' ouput wires here
// End of automatic define

///////////////////////////////
//  RTL LOGIC
///////////////////////////////

//-----------------------------------------------------------------------------
// ÷4 分频器 · 时序段：自由运转的 2-bit 计数器
//   ★ 不复位到任何「相位」以外的东西——复位 div_cnt=0 是刻意的：上电 clk12s 从低
//     起振，保证 ST_TX 下 MUX 的输出第一个沿是干净的上升沿。
//-----------------------------------------------------------------------------
assign clk12s = div_cnt[1];

always @(posedge ref_clk or negedge ref_rstn) begin
    if (!ref_rstn) begin
        div_cnt[1:0] <= 2'd0;
    end
    else begin
        div_cnt[1:0] <= div_cnt[1:0] + 2'd1;
    end
end

//-----------------------------------------------------------------------------
// 电平判据：三路「等电平」条件的显式化
//   切换的两条不变式全靠它们——断开看旧时钟相位，接入看新时钟相位。
//-----------------------------------------------------------------------------
assign dclk_low   = ~dclk;
assign clk12s_low = ~clk12s;

//-----------------------------------------------------------------------------
// 切换状态机 · 时序段：现态寄存器（唯一状态更新点）
//-----------------------------------------------------------------------------
always @(posedge ref_clk or negedge ref_rstn) begin
    if (!ref_rstn) begin
        stat_cur[1:0] <= ST_TX;             // 上电默认本地时钟（DPLL 未锁、无 dclk）
    end
    else begin
        stat_cur[1:0] <= stat_nxt[1:0];
    end
end

//-----------------------------------------------------------------------------
// 切换状态机 · 组合段：次态译码
//   每个态只认「现态 + 现态电平」，不引任何次值线（规则 6）；不满足条件即自环。
//   ★ 四个条件的相位口径统一为「低点」：断离时旧时钟必须已经是 0（输出 0→0 无缝，
//     不会多出一个下降沿），接入时新时钟必须是 0（恒 0 接到 0 无缝，随后第一个上升沿
//     是它自己的沿）。守住这一条，输出 clk12m 的每个沿都必然来自当拍所选的那路时钟。
//   ★ 2026-09-20 仿真修正：原按设计报告 §4.3 让 ST_TX 在 clk12s **高点**断离，实测会在
//     rcv 恰在 clk12s 上升沿那一拍起来时把该高电平截成 1 拍（标称 2 拍），多出一个
//     clk12s 自己没有的下降沿（mux_tx2rx_glitchfree 抓到 spur_fall=1、周期 2 拍）。
//     低点断离后 7/7 用例全过，见 doc/design_rpt/clk_mux_verification.md。
//-----------------------------------------------------------------------------
always @(*) begin
    case (stat_cur[1:0])
    ST_RCV: begin
        // 收完（rcv 落）+ dclk 低点 → 断离恢复时钟，输出 0→0 无缝
        stat_nxt[1:0] = ((~rcv) && dclk_low) ? ST_HOLD1 : ST_RCV;
    end
    ST_HOLD1: begin
        // 等本地时钟低点，接入 clk12s（恒 0 接到 0 无缝）
        stat_nxt[1:0] = clk12s_low ? ST_TX : ST_HOLD1;
    end
    ST_TX: begin
        // 发完（rcv 起）+ clk12s 低点 → 断离本地时钟，输出 0→0 无缝（不截短高电平）
        stat_nxt[1:0] = (rcv && clk12s_low) ? ST_HOLD2 : ST_TX;
    end
    ST_HOLD2: begin
        // 等恢复时钟低点，接入 dclk
        stat_nxt[1:0] = dclk_low ? ST_RCV : ST_HOLD2;
    end
    default: begin
        stat_nxt[1:0] = ST_TX;              // 兜底（case 补全）：回默认本地时钟
    end
    endcase
end

//-----------------------------------------------------------------------------
// 无毛刺 MUX 输出 clk12m
//   ★ 规则 6 显式例外：clk12m 是**派生时钟**，必须保持组合输出。
//     无毛刺的全部机理就是「过渡态输出恒 0 + 只在目标时钟为低时接入」——把它寄存化
//     等于给时钟加一拍延迟、并毁掉「0→0 无缝」这个性质。时钟路径不适用 DFF 直出。
//   ★ 规则 6 同域豁免同样适用：ST_RCV 输出 dclk、ST_TX 输出 clk12s，两者边沿都对齐
//     ref_clk，选的又是同一路电平，不引入任何组合毛刺。
//-----------------------------------------------------------------------------
assign clk12m = (stat_cur[1:0] == ST_RCV) ? dclk :
                (stat_cur[1:0] == ST_TX ) ? clk12s : 1'b0;

endmodule
