//==================================================
// Created by        : xxx
// Filename          : usb_rx_deserial.v
// Author            : xiao_yuan
// Created On        : 2026-09-20 19:41
// Last Modified     : 2026-09-28 补 usb_rst（core 复位同步脉冲）输入
// Update Count      : 2026-09-28 第 2 版（补 usb_rst）
// Description       : USB 1.1 FS RX 反序列化（位 → 字节恢复），clk12m 域位流水线
//
//   职责：把 CDR + clk_mux 恢复出来的位时钟 clk12m 与 NRZI 电平 rx_bit，
//     变成 SIE 事务逻辑能直接消费的「对齐字节流 + 包边界信号」。
//   本模块是 PHY 的最末端（2026-09-20 由 SIE 改挂 PHY），出口即 PHY↔SIE 边界
//     （字节级 rx_data/rx_valid/rx_active/rx_error + 线状态 line_state）；
//   不解释字节内容——PID / CRC / 端点都是 SIE 的活。
//   另出一份 `line_s` 给同域的 usb_bus_state 用：线电平在这里采一次就够，
//     两个模块共用同一把尺子（§2.6）。
//
//   两条流水线，各跑各的时钟域：
//     clk12m (1×)  — 位流水线：NRZI 解码 → SYNC 搜索 → 解填充 → 字节对齐 → 输出寄存
//     ref_clk (4×) — EOP/SE0 定界：Fig.7 五态 FSM，需要 4× 的计时精度
//   两域都由 ref_clk 派生、上升沿对齐；跨域靠「展宽 ≥1 个 clk12m + 单拍采样」，
//   全同步派生时钟交接，没有异步 CDC。
//
//   两根复位分工（2026-09-28 补 usb_rst）：
//     ref_rstn — 异步、低有效：上电复位，清全部寄存器（含 line_s 采样）
//     usb_rst  — 同步、高有效、1 个 clk12m 周期的脉冲：core 复位，帧机与位流水线
//                当拍回 USB_IDLE（与 rx_abort 同一条强退路径，不置 rx_error）。
//                只清 clk12m 域；ref_clk 域的 EOP 定界 FSM 由 ~in_frame 自动回待命。
//                line_s 采样寄存器不吃它（它是总线的影子，§2.6）
//
//   三个关键设计点：
//     ① NRZI 解码 = rx_bit 打 2 拍后同或（无跳变 → 1）。全寄存、不依赖实时 rx_bit，
//        解码栅格整体比「单拍比较」晚约 1 个 clk12m —— 正好给 EOP 门控留出余量。
//     ② EOP 假 7 连 1 修复：EOP 确认后 eop_conf_r 强制清 ones_cnt + 掩 seven_ones
//        + 冻结移位，使「包尾连续 1 + 真 EOP」不被当成第 7 个数据 1（合规包不再误报）。
//     ③ rx_error 是电平不是脉冲：物理检错置起、USB_ERROR 态保持、帧机回 USB_IDLE 即清。
//
//   设计报告：doc/design_rpt/rx_deserial_design.md
//     §2.4 解填充 / §2.6 EOP 定界 / §2.7 时钟方案 / §3.4 常量 / §4.6 EOP 检测 / §4.8 字节输出
//   验证报告：doc/design_rpt/rx_deserial_verification.md（§7 覆盖率）
//==================================================

`timescale 1ns/1ps

///////////////////////////////
//  INSTANCE FILE PATH
///////////////////////////////
// Instance: demo.v
module usb_rx_deserial(/*autoarg*/
    //Inputs
    clk12m, ref_clk, ref_rstn, usb_rst, rx_bit, rxdp, rxdn, tx_active, rx_abort,

    //Outputs
    rx_data, rx_valid, rx_active, rx_error, line_state, line_s);

///////////////////////////////
//  PARAMETER DEFINE
///////////////////////////////
// 收包帧状态机（clk12m 域）状态编码
localparam [1:0] USB_IDLE      = 2'd0;  // 空闲：搜索 SYNC 前的第一个 0
localparam [1:0] USB_SYNC_SEEK = 2'd1;  // 数 0：找到 ≥SYNC_MIN_ZERO 个 0 再收 1
localparam [1:0] USB_DATA      = 2'd2;  // 收数据：PID 起，rx_active=1 且吐字节
localparam [1:0] USB_ERROR     = 2'd3;  // 错误保持：rx_active=1 但不吐字节，等总线回 idle

// 帧机阈值（位宽取被比较计数器的位宽，避免隐式扩展）
localparam [2:0] SYNC_MIN_ZERO = 3'd4;  // SYNC 尾巴最少 0 个数（容忍 CDR 吃 1~2 个 0）
localparam [2:0] STUFF_MAX_ONE = 3'd6;  // 位填充上限：连续 6 个 1 之后必须插 0

// EOP 定界状态机（ref_clk 域，Fig.7）状态编码
localparam [2:0] ST_EOP_IDLE  = 3'd0;   // 空闲：待 SE0
localparam [2:0] ST_EOP_SE0_1 = 3'd1;   // SE0 第 1 拍
localparam [2:0] ST_EOP_SE0_2 = 3'd2;   // SE0 第 2 拍
localparam [2:0] ST_EOP_SE0_3 = 3'd3;   // SE0 第 3 拍（≈62.5ns，过判决点 = EOP 确认）
localparam [2:0] ST_EOP_DEAD  = 3'd4;   // SE0 后非 J 的异常收尾（只待一拍，见 j 补判 eop）

// EOP 事件展宽阈值
localparam [3:0] EOP_WIDEN_MAX = 4'd8;  // eop/eop_err 展宽 ≥1 个 clk12m 周期再跨域

///////////////////////////////
//  INPUT & OUTPUT
///////////////////////////////
input           clk12m;     // 位流水线主时钟 12MHz（接收时 = dclk 经 usb_clk_mux）
input           ref_clk;    // 48MHz 参考时钟（EOP/SE0 定界域，4×）
input           ref_rstn;   // 异步复位，低有效
input           usb_rst;    // core 复位：clk12m 域同步脉冲，1 个周期宽（外面并好总线复位/软复位并展宽）
input           rx_bit;     // CDR 恢复的 NRZI 电平（0=K/1=J），领先 dclk 1 个 ref_clk
input           rxdp;       // USB D+ 单端（ref_clk 域采样，用于 SE0/EOP 检测）
input           rxdn;       // USB D- 单端（同上）
input           tx_active;  // 设备正在发送：自收发门控，强制回 IDLE 并冻结位流水线
input           rx_abort;   // SIE 溢出中止：回 USB_IDLE，但不置 rx_error

// to sie
output [7:0]    rx_data;    // 恢复出的接收字节（LSb 对齐，维持满字节周期）
output          rx_valid;   // 每字节一拍脉冲 = 字节有效标记（UTMI RXValid）
output          rx_active;  // 帧中标志（现态译码；规则 6 同域豁免，见文末说明）
output          rx_error;   // 接收错误电平（位填充违规 / EOP 错），帧机回 idle 即清
output [1:0]    line_state; // 单端电平 {rxdp, rxdn} 透传
output [1:0]    line_s;     // 同一对电平在 ref_clk 域采样（DFF 直出），供 usb_bus_state 共用

///////////////////////////////
//  WIRE  & REG DECLARE
///////////////////////////////
/*autodefine*/
// Define flip-flop registers here
reg             rx_d1;           // rx_bit 打第 1 拍
reg             rx_d2;           // rx_bit 打第 2 拍（与 rx_d1 同或出解码位）
reg  [1:0]      st_stat_cur;     // 收包帧状态机：现态寄存器
reg  [2:0]      zero_cnt;        // SYNC 连续 0 计数
reg  [2:0]      ones_cnt;        // 解填充连续 1 计数
reg  [6:0]      shift_reg;       // 字节移位寄存器（存 b0~b6）
reg  [2:0]      bit_cnt;         // 字节内位计数 (0~7)
reg  [7:0]      rx_data;         // 接收字节输出寄存器
reg             rx_valid;        // 字节有效脉冲输出寄存器
reg             rx_error;        // 接收错误电平输出寄存器
reg  [1:0]      line_s;          // ref_clk 域采样的 {rxdp,rxdn}（输出给 usb_bus_state）
reg  [2:0]      eop_stat_cur;    // EOP 定界状态机：现态寄存器
reg             eop_w;           // eop 展宽电平（ref_clk 域）
reg             eop_err_w;       // eop_err 展宽电平（ref_clk 域）
reg  [3:0]      widen_cnt;       // 展宽共享计时
reg             eop_sync;        // eop 跨域到 clk12m（单拍采样）
reg             eop_err_sync;    // eop_err 跨域到 clk12m（单拍采样）
reg             eop_conf_r;      // eop_conf 打一拍（ref_clk 域）
// Define combination registers here
reg  [1:0]      st_stat_nxt;     // 收包帧状态机：次态组合值
reg  [2:0]      eop_stat_nxt;    // EOP 定界状态机：次态组合值
// Define wires here
wire            d_bit;           // NRZI 解码位（rx_d1 与 rx_d2 同或：无跳变 → 1）
wire            in_frame;        // 帧中（USB_DATA 或 USB_ERROR 态）
wire            frame_clr;       // 强退本帧：自发送 / SIE 中止 / core 复位（回 IDLE、不置 rx_error）
wire            seven_ones_data; // DATA 态下第 7 个连续 1 = 位填充违规
wire            seven_ones_err;  // ERROR 态下第 7 个连续 1 = 静默 idle 探针
wire            enter_error;     // DATA 态进 USB_ERROR（EOP 错或 7 连 1）
wire            enable_shift;    // 本拍是有效数据位，移位寄存器要动
wire            byte_rdy;        // 第 8 位到齐（bit_cnt==7 且为有效数据位）
wire            err_set;         // 物理检错条件（置起 rx_error）
wire            line_se0;        // ref 域采样到 SE0（两线同 0）
wire            line_j;          // ref 域采样到 J（全速 idle）
wire            eop_evt;         // 正常 EOP 事件（SE0→J）
wire            eop_evt2;        // 宽容收尾（SE0 后先回 K 再回 J）
wire            eop_err_evt;     // EOP 错事件（SE0 后非 J）
wire            widen_on;        // 任一展宽进行中
wire            eop_conf;        // EOP 已确认（达 se0_3 或进 dead）
wire [7:0]      rx_data_nxt;     // rx_data 的 D 线
wire            rx_valid_nxt;    // rx_valid 的 D 线
wire            rx_error_nxt;    // rx_error 的 D 线
// Define instances' ouput wires here
// End of automatic define

///////////////////////////////
//  RTL LOGIC
///////////////////////////////

//========================================================================
// clk12m 域 — 位流水线（NRZI 解码 / SYNC 搜索 / 解填充 / 字节对齐）
//========================================================================

//-----------------------------------------------------------------------------
// line_state：{rxdp,rxdn} 透传（规则 6 同域豁免：目的地是 SIE 的采样寄存器）
//-----------------------------------------------------------------------------
assign line_state[1:0] = {rxdp, rxdn};

//-----------------------------------------------------------------------------
// frame_clr：三条强退路径合成一根
//   tx_active — 自发送：线归我们驱，收到的东西没有意义
//   rx_abort  — SIE 按包类型数超上限，放弃本包
//   usb_rst   — core 复位（总线复位 / 软复位并好后送来）：SIE 已经回到初始态，
//               本模块的帧机不能还开着，否则刚出复位的 SIE 看到一个陈旧的开口帧
//   三者同义：当拍把帧机打回 USB_IDLE、冻结位流水线，且都不置 rx_error。
//   不做同步器：usb_rst 按契约由外面整形成 1 个 clk12m 周期的脉冲（§3.2）。
//-----------------------------------------------------------------------------
assign frame_clr = tx_active | rx_abort | usb_rst;

//-----------------------------------------------------------------------------
// NRZI 解码 · 前置两级采样
//   rx_bit → rx_d1 → rx_d2，相邻两拍同或出解码位：全寄存，不组合依赖实时 rx_bit。
//   复位 / 自发送期对齐到 idle J（两拍都 = 1 → d_bit = 1），保证不误判出 0。
//   usb_rst 不进这两级：它们是线的影子，不承载协议状态。硬塞一个 J 进去，复位撤掉
//   那一拍反而假造一次跳变（d_bit=0），进而在 IDLE 里误起一次 SYNC 搜索。
//-----------------------------------------------------------------------------
always @(posedge clk12m or negedge ref_rstn) begin
    if (!ref_rstn) begin
        rx_d1 <= 1'b1;                  // 复位到 idle J
    end
    else if (tx_active) begin
        rx_d1 <= 1'b1;                  // 自发送期对齐到 idle J
    end
    else begin
        rx_d1 <= rx_bit;                // 采样 CDR 电平
    end
end

always @(posedge clk12m or negedge ref_rstn) begin
    if (!ref_rstn) begin
        rx_d2 <= 1'b1;                  // 复位到 idle J
    end
    else if (tx_active) begin
        rx_d2 <= 1'b1;                  // 自发送期对齐到 idle J
    end
    else begin
        rx_d2 <= rx_d1;                 // 相邻上一拍
    end
end

// 无跳变 → 数据 1；有跳变 → 数据 0（NRZI）
assign d_bit = (rx_d1 == rx_d2) ? 1'b1 : 1'b0;

//-----------------------------------------------------------------------------
// 帧中标志：收包帧状态的现态译码
//   ★ rx_active 是组合输出（不是寄存器）。规则 6 的强制场景是「跨出本时钟域 /
//     直连 pad / 直连模拟 PHY」——本信号目的地是 SIE，与这里同跑 clk12m，
//     属同域握手，组合毛刺会被 SIE 的采样沿吸收，故按规则 6 兜底条款保留组合。
//-----------------------------------------------------------------------------
assign in_frame      = (st_stat_cur[1:0] == USB_DATA) || (st_stat_cur[1:0] == USB_ERROR);
assign rx_active     = in_frame;        // 帧中有效信号（UTMI RXActive）

//-----------------------------------------------------------------------------
// 收包帧状态机 · 时序段：现态寄存器（唯一状态更新点）
//-----------------------------------------------------------------------------
always @(posedge clk12m or negedge ref_rstn) begin
    if (!ref_rstn) begin
        st_stat_cur[1:0] <= USB_IDLE;   // 复位回空闲
    end
    else begin
        st_stat_cur[1:0] <= st_stat_nxt[1:0];
    end
end

//-----------------------------------------------------------------------------
// 收包帧状态机 · 组合段：当前态 + 输入 → 次态
//   进位优先级：eop_sync(正常关包) > eop_err_sync / 7 连 1(错误)；
//   ERROR 态的释放 = eop_sync 或 7 连 1（idle 探针）。
//   ★ eop_conf_r 期间 7 连 1 被掩（SE0 不是数据），故不会因包尾 SE0 误进 ERROR。
//-----------------------------------------------------------------------------
always @(*) begin
    st_stat_nxt[1:0] = st_stat_cur[1:0];        // 默认保持现态
    if (frame_clr) begin
        st_stat_nxt[1:0] = USB_IDLE;            // 自发送 / 中止 / core 复位 → 回空闲
    end
    else begin
        case (st_stat_cur[1:0])
        USB_IDLE: begin
            if (~d_bit) begin
                st_stat_nxt[1:0] = USB_SYNC_SEEK;   // 首个 0 = 包开始候选
            end
            else begin
                st_stat_nxt[1:0] = USB_IDLE;        // 无 0 保持空闲
            end
        end
        USB_SYNC_SEEK: begin
            if ((~d_bit) && (zero_cnt[2:0] == 3'd7)) begin
                st_stat_nxt[1:0] = USB_IDLE;        // 0 过多（第 8 个 0）非法
            end
            else if (d_bit && (zero_cnt[2:0] >= SYNC_MIN_ZERO)) begin
                st_stat_nxt[1:0] = USB_DATA;        // SYNC 命中（≥4 个 0 + 1）
            end
            else if (d_bit) begin
                st_stat_nxt[1:0] = USB_IDLE;        // 假触发（0 太少）
            end
            else begin
                st_stat_nxt[1:0] = USB_SYNC_SEEK;   // 又一个 0，继续 SEEK
            end
        end
        USB_DATA: begin
            if (eop_sync) begin
                st_stat_nxt[1:0] = USB_IDLE;        // 正常关包（SE0→J）
            end
            else if (eop_err_sync) begin
                st_stat_nxt[1:0] = USB_ERROR;       // EOP 错（SE0 后非 J）
            end
            else if (seven_ones_data) begin
                st_stat_nxt[1:0] = USB_ERROR;       // 位填充违规 7 连 1 → 错误保持
            end
            else begin
                st_stat_nxt[1:0] = USB_DATA;        // 保持收数据
            end
        end
        USB_ERROR: begin
            if (eop_sync) begin
                st_stat_nxt[1:0] = USB_IDLE;        // 坏帧仍以 SE0→J 收尾 → 释放
            end
            else if (seven_ones_err) begin
                st_stat_nxt[1:0] = USB_IDLE;        // 静默回 J、7 连 1 再现 → 释放
            end
            else begin
                st_stat_nxt[1:0] = USB_ERROR;       // 保持错误
            end
        end
        default: begin
            st_stat_nxt[1:0] = USB_IDLE;            // 兜底（case 补全）
        end
        endcase
    end
end

//-----------------------------------------------------------------------------
// zero_cnt：SYNC 连续 0 计数（窗口只在 USB_SYNC_SEEK）
//-----------------------------------------------------------------------------
always @(posedge clk12m or negedge ref_rstn) begin
    if (!ref_rstn) begin
        zero_cnt[2:0] <= 3'd0;
    end
    else if (frame_clr) begin
        zero_cnt[2:0] <= 3'd0;
    end
    else begin
        case (st_stat_cur[1:0])
        USB_IDLE: begin
            if (~d_bit) begin
                zero_cnt[2:0] <= 3'd1;          // 首个 0 起数
            end
            else begin
                zero_cnt[2:0] <= 3'd0;
            end
        end
        USB_SYNC_SEEK: begin
            if (~d_bit) begin
                if (zero_cnt[2:0] == 3'd7) begin
                    zero_cnt[2:0] <= 3'd0;      // 8 个 0 已非法，归零重计
                end
                else begin
                    zero_cnt[2:0] <= zero_cnt[2:0] + 3'd1;   // 再数一个 0
                end
            end
            else begin
                zero_cnt[2:0] <= 3'd0;          // 命中 / 假触发 → 清 0
            end
        end
        default: begin
            zero_cnt[2:0] <= 3'd0;              // DATA/ERROR 保持 0
        end
        endcase
    end
end

//-----------------------------------------------------------------------------
// ones_cnt：解填充连续 1 计数
//   窗口 = rx_active（DATA/ERROR，帧中），帧外（IDLE/SEEK）保持 0；
//   计数从 PID 起算，进 DATA 时恒 0 —— SYNC 尾的 1 不计入（报告 §2.4）：
//   SYNC 之后必是 PID，PID 是 code + ~code 结构、结构上最多 4 连 1，
//   与 SYNC 尾 1 合起来 5 < 6，故 SYNC/PID 段不可能出现填充位。
//   bit=1 自加（封顶 6），bit=0 清零；数满 6 后下一个 bit 只能是
//   stuffed 0（丢弃清零）或 7 连 1 违规。
//   ★ eop_conf_r（EOP SE0 已确认）期间强制恒 0：包尾 SE0 被解成「1」时不再累计，
//     合规包的「尾连续 1 + EOP」就不会凑出第 7 个 1。
//-----------------------------------------------------------------------------
always @(posedge clk12m or negedge ref_rstn) begin
    if (!ref_rstn) begin
        ones_cnt[2:0] <= 3'd0;
    end
    else if (frame_clr) begin
        ones_cnt[2:0] <= 3'd0;
    end
    else if (~rx_active) begin
        ones_cnt[2:0] <= 3'd0;              // 帧外（IDLE/SEEK）保持 0
    end
    else if (eop_conf_r) begin
        ones_cnt[2:0] <= 3'd0;              // EOP SE0 区：恒 0，不累计
    end
    else if (enter_error) begin
        ones_cnt[2:0] <= 3'd0;              // 进 USB_ERROR 清 0 重计（idle 探针）
    end
    else if (d_bit) begin
        if (ones_cnt[2:0] == STUFF_MAX_ONE) begin
            ones_cnt[2:0] <= 3'd0;          // 7 连 1（DATA 违规 / ERROR 释放）→ 清 0
        end
        else begin
            ones_cnt[2:0] <= ones_cnt[2:0] + 3'd1;       // 又一个 1
        end
    end
    else begin
        ones_cnt[2:0] <= 3'd0;              // bit=0（含 stuffed 0）清零
    end
end

//-----------------------------------------------------------------------------
// 7 连 1 检测（按态分义：DATA = 物理错，ERROR = 静默 idle 探针）
//   eop_conf_r 期间掩掉：EOP SE0 段不是数据，不允许它凑出第 7 个 1 判错。
//-----------------------------------------------------------------------------
assign seven_ones_data = (st_stat_cur[1:0] == USB_DATA)  && (ones_cnt[2:0] == STUFF_MAX_ONE)
                         && d_bit && (~eop_conf_r);
assign seven_ones_err  = (st_stat_cur[1:0] == USB_ERROR) && (ones_cnt[2:0] == STUFF_MAX_ONE)
                         && d_bit && (~eop_conf_r);

// 进 USB_ERROR（由 DATA 内 7 连 1 或 EOP 错触发）→ ones_cnt 重计
assign enter_error = (st_stat_cur[1:0] == USB_DATA) && (eop_err_sync || seven_ones_data);

//-----------------------------------------------------------------------------
// 解填充输出 / 移位使能
//   有效数据 bit = DATA 态 + ones_cnt<6 + 非 EOP SE0 区。stuffed 0 / 7 连 1 违规 /
//   EOP SE0 都不是数据，冻结移位防止 SE0 的解码结果被当数据收进字节。
//-----------------------------------------------------------------------------
assign enable_shift = (st_stat_cur[1:0] == USB_DATA) && (ones_cnt[2:0] != STUFF_MAX_ONE)
                      && (~eop_conf_r);

//-----------------------------------------------------------------------------
// shift_reg：7 位右移，新数据 bit 进 MSB，最早收到的进 LSB
//   第 8 位 b7 只出现在 d_bit 输入上，由 {d_bit, shift_reg[6:0]} 拼整字节，故 7 位即够。
//-----------------------------------------------------------------------------
always @(posedge clk12m or negedge ref_rstn) begin
    if (!ref_rstn) begin
        shift_reg[6:0] <= 7'd0;
    end
    else if (frame_clr) begin
        shift_reg[6:0] <= 7'd0;
    end
    else if (st_stat_cur[1:0] != USB_DATA) begin
        shift_reg[6:0] <= 7'd0;             // SEEK 前 / ERROR 期 / 关包后清 0
    end
    else if (enable_shift) begin
        shift_reg[6:0] <= {d_bit, shift_reg[6:1]};   // 每有效数据 bit 移一拍
    end
end

//-----------------------------------------------------------------------------
// bit_cnt：字节内位计数（仅 DATA 的有效数据位累加，3 bit 自回绕）
//-----------------------------------------------------------------------------
always @(posedge clk12m or negedge ref_rstn) begin
    if (!ref_rstn) begin
        bit_cnt[2:0] <= 3'd0;
    end
    else if (frame_clr) begin
        bit_cnt[2:0] <= 3'd0;
    end
    else if (st_stat_cur[1:0] != USB_DATA) begin
        bit_cnt[2:0] <= 3'd0;
    end
    else if (enable_shift) begin
        bit_cnt[2:0] <= bit_cnt[2:0] + 3'd1;         // 7+1 自然溢出回绕到 0
    end
end

// 第 8 位到齐：bit_cnt==7 且本拍是有效数据位
assign byte_rdy = enable_shift && (bit_cnt[2:0] == 3'd7);

//-----------------------------------------------------------------------------
// 输出寄存器化（规则 7.5：输出 = <输出名>_nxt 线 + 专用 always）
//   三个输出有各自独立的使能条件，故各自一条 D 线；优先级链在 D 线里写完，
//   always 块退化成「复位 → 搬 D 线」。
//-----------------------------------------------------------------------------

//-----------------------------------------------------------------------------
// rx_data：满字节拼出并锁存（维持满字节周期）
//   第 8 位(b7) + 已存 b0~b6，LSb 对齐；非 byte_rdy 拍保持
//-----------------------------------------------------------------------------
assign rx_data_nxt[7:0] = byte_rdy ? {d_bit, shift_reg[6:0]} : rx_data[7:0];

always @(posedge clk12m or negedge ref_rstn) begin
    if (!ref_rstn) begin
        rx_data[7:0] <= 8'd0;
    end
    else begin
        rx_data[7:0] <= rx_data_nxt[7:0];
    end
end

//-----------------------------------------------------------------------------
// rx_valid：byte_rdy 打一拍形成 1 拍脉冲（数据在脉冲拍已经稳定）
//   强退期（自发送 / 中止 / core 复位）强制 0，避免把门控期的 byte_rdy 漏出去
//-----------------------------------------------------------------------------
assign rx_valid_nxt = frame_clr ? 1'b0 : byte_rdy;

always @(posedge clk12m or negedge ref_rstn) begin
    if (!ref_rstn) begin
        rx_valid <= 1'b0;
    end
    else begin
        rx_valid <= rx_valid_nxt;
    end
end

//-----------------------------------------------------------------------------
// rx_error：电平（检错置起 / ERROR 态保持 / 帧机回 idle 即清）
//   置错只在 DATA 态（eop_err_sync 或 7 连 1）；帧机判进 USB_ERROR 后保持。
//   释放判据 = 帧机已回 USB_IDLE（ERROR 由 eop_sync / 7 连 1 idle 探针放行），
//   回 IDLE 当拍即清——不需要 was_frame / frame_just_closed 那种「上一拍在帧内」
//   的关包沿记录（行为等价：rx_error 仍保持到第 1 个 IDLE 周期末，SIE 沿关包沿读得到）。
//-----------------------------------------------------------------------------
assign err_set = (~eop_sync) && (seven_ones_data || eop_err_sync);   // 物理检错条件

assign rx_error_nxt = frame_clr                 ? 1'b0 :             // 中止 / 自发送 / core 复位：立即清
                      err_set                   ? 1'b1 :             // 物理检错：置起（电平）
                      (st_stat_cur[1:0] == USB_IDLE) ? 1'b0 :        // 帧机已回 idle → 释放
                      rx_error;

always @(posedge clk12m or negedge ref_rstn) begin
    if (!ref_rstn) begin
        rx_error <= 1'b0;
    end
    else begin
        rx_error <= rx_error_nxt;
    end
end

//========================================================================
// ref_clk 域 — EOP/SE0 定界（Fig.7 五态 FSM，独立于位流水线）
//========================================================================

//-----------------------------------------------------------------------------
// ref_clk 域采样线电平（每 4× 拍一次，判 se0 / j / 其他）
//   这一份同时送给 usb_bus_state：那边的复位/挂起判据拿它当输入，不再自己采一遍。
//   两个模块对同一段 SE0 数出的是同一批拍，判据可以直接对比（§2.6）
//   复位取 SE0：总线上电前两线被下拉，这是真实电平；两边同一个复位值，时间 0 不会分歧
//   不吃 usb_rst：它就是总线本身，实时采。复位若动了它，复位撤掉那一拍会造一次假线变化
//-----------------------------------------------------------------------------
always @(posedge ref_clk or negedge ref_rstn) begin
    if (!ref_rstn) begin
        line_s[1:0] <= 2'b00;               // 复位取 SE0
    end
    else begin
        line_s[1:0] <= {rxdp, rxdn};
    end
end

assign line_se0 = (line_s[1:0] == 2'b00);   // SE0（D+ 与 D- 同 0）
assign line_j   = (line_s[1:0] == 2'b10);   // J（全速 idle）

//-----------------------------------------------------------------------------
// EOP 定界状态机 · 时序段：现态寄存器（唯一状态更新点）
//-----------------------------------------------------------------------------
always @(posedge ref_clk or negedge ref_rstn) begin
    if (!ref_rstn) begin
        eop_stat_cur[2:0] <= ST_EOP_IDLE;
    end
    else begin
        eop_stat_cur[2:0] <= eop_stat_nxt[2:0];
    end
end

//-----------------------------------------------------------------------------
// EOP 定界状态机 · 组合段
//   帧未开（in_frame=0，含强退路径把帧机打回 IDLE）→ 待命 eop_idle。
//   SE0 每连续一拍进一态，第 3 拍过判决点即 EOP 确认；SE0 中途撤销则作废回 IDLE。
//   usb_rst 不必进本域：帧机被打回 IDLE 后 ~in_frame=0，这里下一拍自动回待命。
//-----------------------------------------------------------------------------
always @(*) begin
    eop_stat_nxt[2:0] = eop_stat_cur[2:0];   // 默认保持现态
    if (~in_frame) begin
        eop_stat_nxt[2:0] = ST_EOP_IDLE;     // 帧未开：待命
    end
    else begin
        case (eop_stat_cur[2:0])
        ST_EOP_IDLE: begin
            if (line_se0) begin
                eop_stat_nxt[2:0] = ST_EOP_SE0_1;   // 见 SE0 → 第 1 拍
            end
            else begin
                eop_stat_nxt[2:0] = ST_EOP_IDLE;
            end
        end
        ST_EOP_SE0_1: begin
            if (line_se0) begin
                eop_stat_nxt[2:0] = ST_EOP_SE0_2;   // 连续 SE0 → 第 2 拍
            end
            else begin
                eop_stat_nxt[2:0] = ST_EOP_IDLE;    // <2 拍作废
            end
        end
        ST_EOP_SE0_2: begin
            if (line_se0) begin
                eop_stat_nxt[2:0] = ST_EOP_SE0_3;   // 连续 SE0 → 第 3 拍（EOP 确认）
            end
            else begin
                eop_stat_nxt[2:0] = ST_EOP_IDLE;    // <3 拍作废
            end
        end
        ST_EOP_SE0_3: begin
            if (line_se0) begin
                eop_stat_nxt[2:0] = ST_EOP_SE0_3;   // 长 SE0 自环
            end
            else if (line_j) begin
                eop_stat_nxt[2:0] = ST_EOP_IDLE;    // 正常 EOP（SE0→J）
            end
            else begin
                eop_stat_nxt[2:0] = ST_EOP_DEAD;    // SE0 后非 J → 异常收尾
            end
        end
        default: begin
            eop_stat_nxt[2:0] = ST_EOP_IDLE;        // ST_EOP_DEAD：异常收尾只待一拍
        end
        endcase
    end
end

//-----------------------------------------------------------------------------
// EOP 事件（ref_clk 域组合）
//   eop_dead 见 J → 补判 eop（宽容收尾）；见非 J → eop_err（EOP 错）。
//-----------------------------------------------------------------------------
assign eop_evt     = in_frame && (eop_stat_cur[2:0] == ST_EOP_SE0_3) && line_j;    // 正常 EOP
assign eop_evt2    = in_frame && (eop_stat_cur[2:0] == ST_EOP_DEAD)  && line_j;    // 宽容收尾
assign eop_err_evt = in_frame && (eop_stat_cur[2:0] == ST_EOP_DEAD)  && (~line_j); // EOP 错

//-----------------------------------------------------------------------------
// eop / eop_err 展宽（plan B：展到 ≥1 个 clk12m 周期再跨域，保证不被漏采）
//-----------------------------------------------------------------------------
assign widen_on = eop_w || eop_err_w;       // 任一展宽进行中

always @(posedge ref_clk or negedge ref_rstn) begin
    if (!ref_rstn) begin
        eop_w <= 1'b0;
    end
    else if (eop_evt || eop_evt2) begin
        eop_w <= 1'b1;                      // eop 事件置起
    end
    else if (widen_on && (widen_cnt[3:0] == EOP_WIDEN_MAX)) begin
        eop_w <= 1'b0;                      // 展宽结束清除
    end
end

always @(posedge ref_clk or negedge ref_rstn) begin
    if (!ref_rstn) begin
        eop_err_w <= 1'b0;
    end
    else if (eop_err_evt) begin
        eop_err_w <= 1'b1;                  // eop_err 事件置起
    end
    else if (widen_on && (widen_cnt[3:0] == EOP_WIDEN_MAX)) begin
        eop_err_w <= 1'b0;                  // 展宽结束清除
    end
end

always @(posedge ref_clk or negedge ref_rstn) begin
    if (!ref_rstn) begin
        widen_cnt[3:0] <= 4'd0;
    end
    else if (widen_on) begin
        if (widen_cnt[3:0] == EOP_WIDEN_MAX) begin
            widen_cnt[3:0] <= 4'd0;         // 到顶归零（维持展宽电平）
        end
        else begin
            widen_cnt[3:0] <= widen_cnt[3:0] + 4'd1;   // 展宽计时
        end
    end
    else begin
        widen_cnt[3:0] <= 4'd0;             // 空闲归零
    end
end

//-----------------------------------------------------------------------------
// 跨到 clk12m 域（边沿对齐，单拍采样，无亚稳态）
//   两时钟都由 ref_clk 派生、上升沿对齐；eop_w 展宽 ≥1 个 clk12m，故不漏检（报告 §2.7）。
//-----------------------------------------------------------------------------
always @(posedge clk12m or negedge ref_rstn) begin
    if (!ref_rstn) begin
        eop_sync <= 1'b0;
    end
    else begin
        eop_sync <= eop_w;
    end
end

always @(posedge clk12m or negedge ref_rstn) begin
    if (!ref_rstn) begin
        eop_err_sync <= 1'b0;
    end
    else begin
        eop_err_sync <= eop_err_w;
    end
end

//-----------------------------------------------------------------------------
// EOP 已确认门控（EOP 假 7 连 1 修复的核心，见文件头 ②）
//   确认 = eop_stat_cur 达 SE0_3（SE0≥3 个采样 ≈62.5ns，过判决点）或进 DEAD（异常收尾）；
//   用 ref_clk 打一拍得 eop_conf_r，供 clk12m 位流水线读。
//   ref/clk12m 是派生同步时钟、上升沿对齐，故 ref 域寄存的信号对 clk12m 是稳定的。
//-----------------------------------------------------------------------------
assign eop_conf = (eop_stat_cur[2:0] == ST_EOP_SE0_3) || (eop_stat_cur[2:0] == ST_EOP_DEAD);

always @(posedge ref_clk or negedge ref_rstn) begin
    if (!ref_rstn) begin
        eop_conf_r <= 1'b0;
    end
    else begin
        eop_conf_r <= eop_conf;
    end
end

endmodule
