//==================================================
// Created by        : xxx
// Filename          : usb_sie_pkt_rx.v
// Author            : xiao_yuan
// Created On        : 2026-09-28 15:10
// Last Modified     :
// Update Count      : 2026-09-28 第 1 版
// Description       : USB 1.1 FS SIE 包级接收解析（clk12m 域，无跨包记忆）
//
//   职责：一个包（rx_active↑…↓）独立解析，只出「这个包是什么、字段多少、CRC 好不好」：
//     字节计数 → PID 解码/校验 → 字段提取 → 字节并行 CRC → 长度/溢出护栏
//   不认识端点、不做应答决策、不记得上一个包（那是 usb_sie 事务级的活，§1.2）。
//
//   输入契约（rx_deserial_design.md §3.2，已冻结，不要改）：
//     rx_active↑ = 包开始（SYNC 命中），此后第 1 个 rx_valid 脉冲的字节 = PID；
//     rx_active↓ = 包结束；rx_error 是电平，沿关包沿读得到。
//     没有 rx_start/rx_last，包首包尾全靠本模块自己数。
//
//   2 字节延迟线（§2.5.3）：数据包长度事先未知（靠 EOP 定界），无法直接指出
//     「末两字节是 CRC16」。于是 CRC16 引擎永远吃延迟 2 字节的流——
//       收到 b(i) 时：喂 d1（= b(i-2)）；d1←d2；d2←b(i)
//       包尾：d1 = b(K+1)、d2 = b(K+2) 补喂完 → 查残差 0x800D
//     同一份延迟顺手解决「哪些字节算净荷」：净荷 b1..bK 正好是延迟后仍在流里的
//     字节，CRC 字节进不了写口。token 不需要延迟线（CRC5 的输入恰是 2 个整字节，
//     §2.3），所以 CRC5 走零延迟、CRC16 走延迟，两个引擎各自门控。
//
//   包尾窗口（tail_win / tail_cnt）：rx_active 落之后再数 2 拍补喂 CRC 字节，
//     第 2 拍出 pkt_done。用 frame_seen 而不是光看 rx_active，是因为那 2 拍
//     rx_active 已经为 0，分不出「包刚结束」和「总线空闲」。
//
//   溢出护栏（§2.6）：包尾靠 EOP 定界，EOP 永不到来时靠字节计数兜底——字节数
//     越过本包类型上限立刻拉 rx_abort 回 deserial，且不置 rx_error（那是物理层的）。
//
//   输出取组合（规则 6 同域豁免，与 usb_rx_deserial 对 rx_active 的处理同理）：
//     本模块全部输出都只是内部寄存器的译码，全部在 clk12m 同域内被 usb_sie 在
//     pkt_done 那一拍采样，不出本域、不进模拟。唯一要跨到 PHY 的 rx_abort 是寄存器。
//
//   设计报告：doc/design_rpt/usb_sie_design.md
//     §2.3 token 位序 / §2.4 PID / §2.5 字节并行 CRC / §2.6 长度与 rx_abort
//     §3.2 端口 / §4.2 CRC / §4.4 延迟线 / §4.9 溢出护栏
//==================================================

`timescale 1ns/1ps
`include "usb_const.vh"

///////////////////////////////
//  INSTANCE FILE PATH
///////////////////////////////
// Instance: demo.v
module usb_sie_pkt_rx(/*autoarg*/
    //Inputs
    clk12m, ref_rstn, rx_data, rx_valid, rx_active, rx_error, max_payload,

    //Outputs
    rx_abort, pl_byte, pl_byte_vld, pkt_done, pkt_bad, pkt_cls, pid, pid_ok,
    tok_addr, tok_endp, tok_frame, tok_crc_ok, dat_pid_is1, dat_crc_ok, dat_len);

///////////////////////////////
//  PARAMETER DEFINE
///////////////////////////////
// 包类别（PID 分组解码结果，§2.4）
localparam [1:0] CLS_INVALID   = 2'd0;  // 坏 PID / 不认识的 PID（NYET、PRE）
localparam [1:0] CLS_TOKEN     = 2'd1;  // pid[1:0] = 01
localparam [1:0] CLS_DATA      = 2'd2;  // pid[1:0] = 11
localparam [1:0] CLS_HANDSHAKE = 2'd3;  // pid[1:0] = 10

// 字节数上限 / 下限（含 PID，§2.6）
localparam [7:0] LIM_TOKEN = 8'd3;      // token / SOF：PID + 2 字节
localparam [7:0] LIM_HS    = 8'd1;      // handshake：只有 PID
localparam [7:0] LIM_ERR   = 8'd67;     // 类别不明时的兜底上界 = 3 + 64
localparam [7:0] MIN_TOKEN = 8'd3;      // token / 数据包至少 3 字节
localparam [7:0] MIN_HS    = 8'd1;      // handshake 至少 1 字节

// CRC 残差（规范魔法数，§2.5.2）
localparam [4:0]  CRC5_RESID  = 5'h0C;
localparam [15:0] CRC16_RESID = 16'h800D;

// 延迟线深度固定 2 拍（§2.5.3）；包尾补喂到第 2 拍出 pkt_done
localparam [1:0] TAIL_DONE = 2'd2;

// 数据包净荷区的起始字节下标（0 = PID，1 起是净荷）
localparam [7:0] PL_FIRST = 8'd3;

///////////////////////////////
//  INPUT & OUTPUT
///////////////////////////////
input           clk12m;       //clock 1x 位时钟（接收时 = dclk 经 usb_clk_mux）
input           ref_rstn;     //reset 异步复位，低有效
input [7:0]     rx_data;      // 恢复字节（线序，bit0 先发）
input           rx_valid;     // 每字节一拍脉冲
input           rx_active;    // 帧中；下降沿 = 包结束
input           rx_error;     // 物理层错误电平（位填充违规 / EOP 错）
input [6:0]     max_payload;  // 本包允许的最大净荷字节数（usb_sie 按 ep_sel 查表驱动）

// to phy
output          rx_abort;     // 字节数超上限 → 中止本包（回 usb_rx_deserial）

// to sie
output [7:0]    pl_byte;      // 净荷字节（延迟 2 字节后）
output          pl_byte_vld;  // 净荷字节有效（与净荷区对齐，不含 PID 与 CRC16）
output          pkt_done;     // 一包结论有效脉冲：包尾 + 2 拍补喂 CRC 之后
output          pkt_bad;      // 本包坏（物理错 / PID / CRC / 长度越界）
output [1:0]    pkt_cls;      // 包类别：INVALID / TOKEN / DATA / HANDSHAKE
output [7:0]    pid;          // 收到的 PID 字节
output          pid_ok;       // PID 校验位正确
output [6:0]    tok_addr;     // token 的 ADDR[6:0]
output [3:0]    tok_endp;     // token 的 ENDP[3:0]
output [10:0]   tok_frame;    // SOF 帧号
output          tok_crc_ok;   // token CRC5 残差 = 0x0C
output          dat_pid_is1;  // 数据包 PID = DATA1（0 = DATA0）
output          dat_crc_ok;   // 数据包 CRC16 残差 = 0x800D
output [6:0]    dat_len;      // 数据包净荷长度

///////////////////////////////
//  WIRE  & REG DECLARE
///////////////////////////////
/*autodefine*/
// Define flip-flop registers here
reg  [7:0]      byte_cnt;        // 本包已收字节数；值 = 当前到达字节的下标（0 = PID）
reg  [7:0]      pid_reg;         // 锁存的 PID 字节（下标 0 那拍载入）
reg  [7:0]      byte1_reg;       // token 第 1 个数据字节（下标 1）
reg  [7:0]      byte2_reg;       // token 第 2 个数据字节（下标 2）
reg  [7:0]      d1;              // 2 字节延迟线：早 2 拍（既喂 CRC16 又出净荷）
reg  [7:0]      d2;              // 2 字节延迟线：早 1 拍
reg             frame_seen;      // 本包在收（rx_active↑ 置起、pkt_done 落）
reg  [1:0]      tail_cnt;        // 包尾补喂计数：0 喂 d1 / 1 喂 d2 / 2 出结论
reg             rx_active_dly;   // rx_active 打一拍，用于做上升沿检测
reg             rx_err_lat;      // 本包见过的物理错（锁存给 pkt_bad 用）
reg             rx_abort;        // 中止标志（输出寄存器；rx_active 落即清）
// Define combination registers here
// Define wires here
wire [7:0]      byte_cnt_nxt;    // byte_cnt 次值
wire [7:0]      pid_reg_nxt;     // pid_reg 次值
wire [7:0]      byte1_reg_nxt;   // byte1_reg 次值
wire [7:0]      byte2_reg_nxt;   // byte2_reg 次值
wire [7:0]      d1_nxt;          // d1 次值
wire [7:0]      d2_nxt;          // d2 次值
wire            frame_seen_nxt;  // frame_seen 次值
wire [1:0]      tail_cnt_nxt;    // tail_cnt 次值
wire            rx_active_dly_nxt;// rx_active_dly 次值
wire            rx_err_lat_nxt;  // rx_err_lat 次值
wire            rx_abort_nxt;    // rx_abort 次值
wire            rx_active_pos;   // rx_active 上升沿 = 包首那一拍
wire            byte_take;       // 本拍到达一个有效字节
wire            tail_win;        // 包尾补喂窗口（包已开始且 rx_active 已落）
wire            tail_done;       // 补喂已满 2 拍
wire            crc5_clr;        // CRC5 载种子
wire            crc5_en;         // CRC5 收一字节
wire            crc16_clr;       // CRC16 载种子
wire            crc16_en;        // CRC16 收一字节
wire [7:0]      crc16_d;         // CRC16 输入字节（包内 = d1，包尾 = d1/d2）
wire            pl_wr_en;        // 净荷写口有效
wire [7:0]      byte_limit;      // 本包类型的字节数上限（含 PID）
wire [7:0]      min_len;         // 本包类型的字节数下限
wire            overflow;        // 字节数越过上限
wire            len_bad;         // 字节数不足下限（截断包）
wire            crc_bad;         // 本包类型的 CRC 残差不对
// Define instances' ouput wires here
wire [4:0]      crc5_b;          // CRC5 字节并行余数（u_crc5 输出）
wire [15:0]     crc16_b;         // CRC16 字节并行余数（u_crc16 输出）
// End of automatic define

///////////////////////////////
//  RTL LOGIC
///////////////////////////////

//-----------------------------------------------------------------------------
// 包首 / 包尾时序骨架
//-----------------------------------------------------------------------------
// rx_active 打一拍：做上升沿检测
assign rx_active_dly_nxt = rx_active;

// 包首那一拍（本包一切计数从这里清零）
assign rx_active_pos = rx_active & ~rx_active_dly;

// frame_seen：本包在收。★ 不能用 rx_active 自己代替——包尾后还要补喂 2 拍，
//   那 2 拍 rx_active 已经是 0，光看它分不出「包刚结束」和「总线空闲」。
assign frame_seen_nxt = rx_active_pos ? 1'b1 :
                        pkt_done       ? 1'b0 : frame_seen;

// 包尾补喂窗口
assign tail_win = frame_seen & ~rx_active;

// 补喂计数：0 喂 d1、1 喂 d2、2 出 pkt_done
assign tail_done = (tail_cnt[1:0] == TAIL_DONE);
assign tail_cnt_nxt[1:0] = (tail_win & ~tail_done) ? (tail_cnt[1:0] + 2'd1) : 2'd0;

// 一包结论有效：包尾 + 2 拍（两个 CRC 字节喂完，残差这一刻才是最终的）
assign pkt_done = tail_win & tail_done;

//-----------------------------------------------------------------------------
// 字节计数与字段锁存
//-----------------------------------------------------------------------------
// 本拍到达一个有效字节（deserial 契约：rx_valid 每字节恰一拍脉冲）
assign byte_take = rx_valid & rx_active;

// 字节计数：包首清零，每收一字节 +1；值 = 当前到达字节的下标，0 即 PID
assign byte_cnt_nxt[7:0] = rx_active_pos ? 8'd0 :
                           byte_take     ? (byte_cnt[7:0] + 8'd1) : byte_cnt[7:0];

// PID：下标 0
assign pid_reg_nxt[7:0] = (byte_take & (byte_cnt[7:0] == 8'd0)) ? rx_data[7:0] : pid_reg[7:0];

// token 的两个数据字节：下标 1 / 2
assign byte1_reg_nxt[7:0] = (byte_take & (byte_cnt[7:0] == 8'd1)) ? rx_data[7:0] : byte1_reg[7:0];
assign byte2_reg_nxt[7:0] = (byte_take & (byte_cnt[7:0] == 8'd2)) ? rx_data[7:0] : byte2_reg[7:0];

//-----------------------------------------------------------------------------
// 2 字节延迟线 + 净荷写口（§2.5.3：一份延迟，两个职责）
//-----------------------------------------------------------------------------
// 每到一个字节整体移一拍；喂 CRC16 与出净荷都用 d1（= 到达字节早 2 拍那个）
assign d2_nxt[7:0] = byte_take ? rx_data[7:0] : d2[7:0];
assign d1_nxt[7:0] = byte_take ? d2[7:0]     : d1[7:0];

// 净荷写口：下标 < 3 的字节是 PID 与 token 字段，不写。数据包从下标 3 起，
//   d1 正好落在净荷区（b1..bK），两个 CRC 字节进不来。
assign pl_wr_en     = byte_take & (pkt_cls[1:0] == CLS_DATA)
                      & (byte_cnt[7:0] >= PL_FIRST) & ~rx_abort;
assign pl_byte[7:0] = d1[7:0];
assign pl_byte_vld  = pl_wr_en;

//-----------------------------------------------------------------------------
// 字节并行 CRC（§2.5）
//-----------------------------------------------------------------------------
// CRC5：token 用。包首载种子，喂下标 1、2 两个字节——ADDR+ENDP+收到的 CRC 位
//   正好 16 bit 两个整字节，喂完直接查残差 0x0C（§2.3 位序便利点）。
assign crc5_clr = rx_active_pos;
assign crc5_en  = byte_take & (pkt_cls[1:0] == CLS_TOKEN)
                  & ((byte_cnt[7:0] == 8'd1) | (byte_cnt[7:0] == 8'd2));

// CRC16：数据包用。包内喂延迟 2 拍的 d1（下标 ≥3 起），包尾补喂 d1/d2 两个 CRC 字节
assign crc16_clr    = rx_active_pos;
assign crc16_d[7:0] = (tail_win & (tail_cnt[1:0] == 2'd1)) ? d2[7:0] : d1[7:0];
assign crc16_en     = ~rx_abort & (pkt_cls[1:0] == CLS_DATA)
                      & ((byte_take & (byte_cnt[7:0] >= PL_FIRST))
                         | (tail_win & ~tail_done));

//-----------------------------------------------------------------------------
// 包级结论（组合；usb_sie 在 pkt_done 那一拍采样）
//-----------------------------------------------------------------------------
// PID 校验：类型半字节与校验半字节互为反码（§2.4）
assign pid_ok = (pid_reg[7:4] == ~pid_reg[3:0]);

// 包类别：先按 pid[1:0] 分组，坏 PID 一律 INVALID（NYET / PRE 归 INVALID，不参与）
assign pkt_cls[1:0] = ~pid_ok                 ? CLS_INVALID :
                      (pid_reg[1:0] == 2'b01) ? CLS_TOKEN :
                      (pid_reg[1:0] == 2'b11) ? CLS_DATA :
                      (pid_reg[1:0] == 2'b10) ? CLS_HANDSHAKE : CLS_INVALID;

// 字节数上限（含 PID）：token/SOF 3、handshake 1、data 3+max_payload。
//   类不明（坏 PID / special）给 3+64 的有限兜底——这类包已判坏，上界只为防止
//   无 EOP 的乱码流把计数撑爆。
assign byte_limit[7:0] = (pkt_cls[1:0] == CLS_TOKEN)     ? LIM_TOKEN :
                         (pkt_cls[1:0] == CLS_HANDSHAKE) ? LIM_HS :
                         (pkt_cls[1:0] == CLS_DATA)      ? ({1'b0, max_payload[6:0]} + 8'd3)
                                                         : LIM_ERR;

// 字节数下限（截断包判坏）
assign min_len[7:0] = (pkt_cls[1:0] == CLS_HANDSHAKE) ? MIN_HS :
                      (pkt_cls[1:0] == CLS_INVALID)   ? 8'd0 : MIN_TOKEN;

// 残差判据：喂完整包（含 CRC 位）看余数是否等于规范魔法数（§2.5.2）
assign tok_crc_ok = (crc5_b[4:0]  == CRC5_RESID);
assign dat_crc_ok = (crc16_b[15:0] == CRC16_RESID);

// CRC 判坏：按类别对号入座（handshake 无 CRC，不参与）
assign crc_bad = (pkt_cls[1:0] == CLS_TOKEN) ? ~tok_crc_ok :
                 (pkt_cls[1:0] == CLS_DATA)  ? ~dat_crc_ok : 1'b0;

// 长度判坏：字节数不足下限
assign len_bad = (byte_cnt[7:0] < min_len[7:0]);

// 本包坏：物理错 / PID / 长度（含溢出中止）/ CRC，任一条即坏
assign pkt_bad = ~pid_ok | rx_err_lat | rx_abort | len_bad | crc_bad;

// 字段输出
assign pid[7:0]        = pid_reg[7:0];
assign tok_addr[6:0]   = byte1_reg[6:0];
assign tok_endp[3:0]   = {byte2_reg[2:0], byte1_reg[7]};
assign tok_frame[10:0] = {byte2_reg[2:0], byte1_reg[7:0]};
assign dat_pid_is1     = (pid_reg[7:0] == `PID_DATA1);

// 净荷长度 = 本包总字节数 − PID − 2 个 CRC 字节（包尾字节数已冻结）。
//   取 7 bit：字节上限 3+64，byte_cnt 不会越过 127（越界早被 rx_abort 拦下）。
assign dat_len[6:0] = byte_cnt[6:0] - 7'd3;

//-----------------------------------------------------------------------------
// 溢出护栏（§2.6）与物理错锁存
//-----------------------------------------------------------------------------
// 本拍到达的字节已越过本包类型上限（byte_cnt 就是已在包内的字节数）
assign overflow = byte_take & (byte_cnt[7:0] >= byte_limit[7:0]);

// rx_abort：越上限即置起，保持到 rx_active 落。★ 必须跟 rx_active 一起落干净：
//   它在 deserial 那边是 frame_clr 的一项，留着会把下一个包一起毙掉。
assign rx_abort_nxt = rx_active ? (rx_abort | overflow) : 1'b0;

// 物理错锁存：rx_error 是电平、包尾 1 拍就清，本包见过就锁住，供 pkt_bad 用
assign rx_err_lat_nxt = rx_active_pos             ? 1'b0 :
                        (rx_error & frame_seen)   ? 1'b1 : rx_err_lat;

//-----------------------------------------------------------------------------
// 时序段（规则 8：每个寄存器一条 _nxt + 一个 always）
//-----------------------------------------------------------------------------
always @(posedge clk12m or negedge ref_rstn) begin
    if (!ref_rstn) begin
        byte_cnt[7:0] <= 8'd0;
    end else begin
        byte_cnt[7:0] <= byte_cnt_nxt[7:0];
    end
end

always @(posedge clk12m or negedge ref_rstn) begin
    if (!ref_rstn) begin
        pid_reg[7:0] <= 8'd0;
    end else begin
        pid_reg[7:0] <= pid_reg_nxt[7:0];
    end
end

always @(posedge clk12m or negedge ref_rstn) begin
    if (!ref_rstn) begin
        byte1_reg[7:0] <= 8'd0;
    end else begin
        byte1_reg[7:0] <= byte1_reg_nxt[7:0];
    end
end

always @(posedge clk12m or negedge ref_rstn) begin
    if (!ref_rstn) begin
        byte2_reg[7:0] <= 8'd0;
    end else begin
        byte2_reg[7:0] <= byte2_reg_nxt[7:0];
    end
end

always @(posedge clk12m or negedge ref_rstn) begin
    if (!ref_rstn) begin
        d1[7:0] <= 8'd0;
    end else begin
        d1[7:0] <= d1_nxt[7:0];
    end
end

always @(posedge clk12m or negedge ref_rstn) begin
    if (!ref_rstn) begin
        d2[7:0] <= 8'd0;
    end else begin
        d2[7:0] <= d2_nxt[7:0];
    end
end

always @(posedge clk12m or negedge ref_rstn) begin
    if (!ref_rstn) begin
        frame_seen <= 1'b0;
    end else begin
        frame_seen <= frame_seen_nxt;
    end
end

always @(posedge clk12m or negedge ref_rstn) begin
    if (!ref_rstn) begin
        tail_cnt[1:0] <= 2'd0;
    end else begin
        tail_cnt[1:0] <= tail_cnt_nxt[1:0];
    end
end

always @(posedge clk12m or negedge ref_rstn) begin
    if (!ref_rstn) begin
        rx_active_dly <= 1'b0;
    end else begin
        rx_active_dly <= rx_active_dly_nxt;
    end
end

always @(posedge clk12m or negedge ref_rstn) begin
    if (!ref_rstn) begin
        rx_err_lat <= 1'b0;
    end else begin
        rx_err_lat <= rx_err_lat_nxt;
    end
end

always @(posedge clk12m or negedge ref_rstn) begin
    if (!ref_rstn) begin
        rx_abort <= 1'b0;
    end else begin
        rx_abort <= rx_abort_nxt;
    end
end

///////////////////////////////
//  INSTANTIATION
///////////////////////////////
// 字节并行 CRC5（token）
usb_crc5_byte u_crc5 (
    .clk     (clk12m),
    .rstn    (ref_rstn),
    .crc_en  (crc5_en),
    .crc_clr (crc5_clr),
    .d_in    (rx_data[7:0]),
    .crc_out (crc5_b[4:0]));

// 字节并行 CRC16（数据包）
usb_crc16_byte u_crc16 (
    .clk     (clk12m),
    .rstn    (ref_rstn),
    .crc_en  (crc16_en),
    .crc_clr (crc16_clr),
    .d_in    (crc16_d[7:0]),
    .crc_out (crc16_b[15:0]));

endmodule
