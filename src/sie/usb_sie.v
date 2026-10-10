//==================================================
// Created by        : xxx
// Filename          : usb_sie.v
// Author            : xiao_yuan
// Created On        : 2026-09-28 16:40
// Last Modified     :
// Update Count      : 2026-09-28 第 1 版（只做接收，发包先不做）
// Description       : USB 1.1 FS 串行接口引擎·事务层（clk12m 域，跨包记忆）
//
//   职责：把包级结论（usb_sie_pkt_rx 的 pkt_done/pkt_bad/字段）翻译成事务行为——
//     事务状态机（T_IDLE/T_DATA_WAIT）、应答决策（§2.8 真值表）、data toggle、
//     周转超时、64B 包缓冲与端点事件；并产出 rcv 给 usb_clk_mux。
//   不解析位、不解析字节（那是 PHY 与 pkt_rx 的活）；本轮不发送任何东西
//     （IN 事务、应答的物理发送、CDC 对接、FIFO/APB/寄存器都不在本轮）。
//
//   两级状态机（usb_sie_design.md §2.2）：
//     usb_sie_pkt_rx  包级·无记忆：一个包出一次结论
//     usb_sie（本模块）事务级·跨包记忆：记住「刚认了哪个端点、哪个方向」
//   一个 USB 事务跨 2~3 个独立包（token / data / handshake 各有 SYNC、EOP、CRC），
//   所以事务级必须有跨包记忆，而包级可以纯组合加小计数、易于穷举。
//
//   事务状态机（本轮只实现前两个，后两个是编码预留，不实现也不跳入）：
//     T_IDLE      → 等 token；OUT/SETUP 收妥 → T_DATA_WAIT
//     T_DATA_WAIT → 数据阶段收尾（应答决策）；新 OUT/SETUP TOKEN 重新武装该态，
//       其余任何包的结论或周转超时 → T_IDLE
//     ★ T_DATA_WAIT 能被新 TOKEN 打断（§4.7）：主机在 token 后未必总发数据包
//       （帧末、错误恢复）。做法是「任何包都先按包级结论分类、再按跳转表分派」，
//       打断情形天然被覆盖，没有「等数据包」的特例代码。
//
//   应答优先级（§2.8，从上到下，写反最容易出错）：
//     坏包 → 不应答 ｜ OUT 打到 IN 端点 → 不应答 ｜ halt → STALL
//     ｜ 序列不匹配 → ACK+丢弃（去重，不翻转）｜ 忙 → NAK ｜ 其余 → ACK+收下+翻转
//   SETUP 走独立分支：不查 stall/nak/toggle，包好就无条件 ACK 并把 toggle[EP0] 置 1。
//
//   包缓冲（§2.11，坏包隔离）：收包期字节只写 SIE 内部 pkt_buf，包尾校验通过且决定
//     「收下」才置 buf_ready 给 CDC 逐字节排出；坏包与 NAK 的包写指针从头来过，
//     端点 FIFO 完全不受污染。
//
//   复位与附着：
//     ref_rstn        异步复位，与 usb_rx_deserial 同一根复位网络
//     usb_rst         core 复位（软复位 ∪ 总线复位）同步脉冲，宽 1 个 clk12m 周期；
//                     清事务状态机 / toggle / 包缓冲 / 附着（§2.7 的 reset 口径）
//     connect_evt     来自 usb_bus_state 的 clk12m 单拍脉冲 → 置 attached
//     rcv = attached & ~driving，交给 usb_clk_mux 选 dclk / clk12s。
//       复位后必须为 0：CDR 未锁时 dclk 常 0，若 rcv 初值为 1 则 clk12m 常 0，
//       SIE 自己都起不了振（usb_sie_design.md §1.3）。
//
//   设计报告：doc/design_rpt/usb_sie_design.md
//     §2.7 事务状态机 / §2.8 应答真值表 / §2.9 toggle / §2.10 周转超时
//     §2.11 包缓冲 / §2.12 准静态跨域 / §3.1 端口 / §1.3 rcv
//==================================================

`timescale 1ns/1ps
`include "usb_const.vh"

///////////////////////////////
//  INSTANCE FILE PATH
///////////////////////////////
// Instance: demo.v
module usb_sie(/*autoarg*/
    //Inputs
    clk12m, ref_rstn, usb_rst, connect_evt,
    rx_data, rx_valid, rx_active, rx_error,
    buf_rd_en, dev_addr, ep_stall, ep_nak, ep_dir, toggle_set, toggle_val,

    //Outputs
    rcv, rx_abort, resp_req, resp_pid, buf_rd_data, buf_cnt, buf_ready,
    ep_rx_done, ep_rx_bad, setup_recv, sof_recv, frame_no);

///////////////////////////////
//  PARAMETER DEFINE
///////////////////////////////
// 事务状态机编码（3 bit）
localparam [2:0] T_IDLE      = 3'd0;  // 空闲，等 token
localparam [2:0] T_DATA_WAIT = 3'd1;  // OUT/SETUP token 收妥，等数据包
localparam [2:0] T_TX        = 3'd2;  // IN token 收妥，发数据（下一步，本轮不跳入）
localparam [2:0] T_HS_WAIT   = 3'd3;  // 数据发完等握手（下一步，本轮不跳入）

// 应答决策码（组合，pkt_done 拍有效）
localparam [1:0] DEC_NONE  = 2'd0;    // 无应答
localparam [1:0] DEC_ACK   = 2'd1;
localparam [1:0] DEC_NAK   = 2'd2;
localparam [1:0] DEC_STALL = 2'd3;

// 端点点号（4 bit = token 的 ENDP 字段）
localparam [3:0] EP0 = 4'd0;          // 控制端点，恒双向
localparam [3:0] EP1 = 4'd1;
localparam [3:0] EP2 = 4'd2;
localparam [3:0] EP_MAX = 4'd2;       // 本轮实现的端点数（> EP2 一律忽略）

// 周转超时阈值：计数起点是 pkt_done（比 EOP 晚 2 拍补喂 CRC），计数到 15 的那一拍
//   判超时、次拍回 T_IDLE → 放弃点 = pkt_done + 16 = EOP 后 18 bit time，规范上限（§2.10）。
//   从 pkt_done 起算 15 而不是 16，是因为判决拍与"回空闲"拍差一拍，不扣掉这一拍就落到
//   EOP 后 19，超上限。
localparam [4:0] TURNAROUND_MAX = 5'd15;

// 净荷上限按端点查表（§2.6 / §2.14④）。EP0 枚举初期为 8（协议要求 EP0 必须支持 8），
//   EP1/EP2 = 64；寄存器落地后改由 CPU 配置。
localparam [6:0] MAXP_EP0 = 7'd8;
localparam [6:0] MAXP_EP1 = 7'd64;
localparam [6:0] MAXP_EP2 = 7'd64;

// 无应答时 resp_pid 的占位值
localparam [7:0] RESP_NONE = 8'h00;

///////////////////////////////
//  INPUT & OUTPUT
///////////////////////////////
input           clk12m;       //clock 1x 位时钟（接收时 = dclk 经 usb_clk_mux），本模块唯一时钟
input           ref_rstn;     //reset 异步复位，低有效（异步置位，不依赖 clk12m 是否在振）
input           usb_rst;      //reset core 复位（软复位 ∪ 总线复位），同步脉冲，宽 1 个 clk12m 周期
input           connect_evt;  // 附着事件（usb_bus_state 的 clk12m 单拍脉冲）

// from phy
input [7:0]     rx_data;      // 恢复字节（直连 usb_rx_deserial）
input           rx_valid;     // 每字节一拍脉冲
input           rx_active;    // 帧中；下降沿 = 包结束
input           rx_error;     // 物理层错误电平

// from cdc
input           buf_rd_en;    // 包缓冲逐字节读使能（四相握手驱动，下一步接 usb_sie_cdc）

// from apb（pclk 准静态，2-FF 同步进本域）
input [6:0]     dev_addr;     // 设备地址（复位后默认 0，枚举时 CPU 写）
input [2:0]     ep_stall;     // 端点 halt 标志 {EP2,EP1,EP0}
input [2:0]     ep_nak;       // 端点忙标志 {EP2,EP1,EP0}
input [1:0]     ep_dir;       // {EP2,EP1} 方向，1 = IN；EP0 恒双向
input [2:0]     toggle_set;   // CPU 写 toggle 初值使能
input [2:0]     toggle_val;   // CPU 写的 toggle 初值

// to phy
output          rcv;          // 接收模式标志（→ usb_clk_mux 选 dclk / clk12s）
output          rx_abort;     // 字节数超上限（透传 usb_sie_pkt_rx）

// to tx（下一步接 usb_tx_serial）
output          resp_req;     // 应答请求（1 拍脉冲），与 resp_pid 同拍有效
output [7:0]    resp_pid;     // 应答 PID：ACK / NAK / STALL

// to cdc（下一步）
output [7:0]    buf_rd_data;  // 包缓冲读数据（整包已校验通过）
output [6:0]    buf_cnt;      // 缓冲内净荷字节数，buf_ready=1 期间有效
output          buf_ready;    // 缓冲内有一个校验通过、待排出的完整包

// to ep（下一步经 CDC）
output          ep_rx_done;   // OUT/SETUP 数据包完好且已决定收下（1 拍脉冲）
output          ep_rx_bad;    // 收到的数据包坏（1 拍脉冲，诊断用）
output          setup_recv;   // SETUP 事务收妥（1 拍脉冲）

// to reg
output          sof_recv;     // 收到 SOF token（1 拍脉冲）
output [10:0]   frame_no;     // 最近一次 SOF 的帧号

///////////////////////////////
//  WIRE  & REG DECLARE
///////////////////////////////
/*autodefine*/
// Define flip-flop registers here
reg  [2:0]      t_state_cur;     // 事务状态机：现态寄存器
reg  [3:0]      ep_sel;          // 当前事务的端点点号（token 收妥时锁存）
reg             is_setup;        // 当前事务是 SETUP（决定强制 ACK 与 toggle 置 1）
reg  [2:0]      toggle;          // 每端点 data toggle {EP2,EP1,EP0}
reg  [4:0]      turn_cnt;        // 周转超时计数（T_DATA_WAIT 中累加）
reg  [10:0]     frame_no;        // 最近一次 SOF 的帧号
reg             resp_req;        // 应答请求脉冲输出寄存器
reg  [7:0]      resp_pid;        // 应答 PID 输出寄存器
reg             buf_ready;       // 缓冲内有一个校验通过、待排出的包
reg  [6:0]      buf_cnt;         // 缓冲内净荷字节数（0~64）
reg  [6:0]      wr_ptr;          // 包缓冲写指针（暂存 128 用，只取低 6 位）
reg  [6:0]      rd_ptr;          // 包缓冲读指针（同上）
reg  [7:0]      pkt_buf[0:63];   // 包缓冲（64×8，坏包隔离）
reg             pkt_wr_ok;       // 包首采样「缓冲可用」，全程不变
reg             attached;        // 已附着（connect_evt 置起，usb_rst 清）
reg             rx_active_dly;   // rx_active 打一拍，用于做上升沿检测
reg  [13:0]     dev_addr_s;      // 设备地址两拍同步链 {同步值[13:7], 第一级[6:0]}
reg  [5:0]      ep_stall_s;      // 端点 halt 同步链，同上打包
reg  [5:0]      ep_nak_s;        // 端点忙同步链，同上打包
reg  [3:0]      ep_dir_s;        // 端点方向同步链，同上打包
reg  [5:0]      toggle_set_s;    // toggle 初值使能同步链，同上打包
reg  [5:0]      toggle_val_s;    // toggle 初值同步链，同上打包
reg             ep_rx_done;      // 端点事件脉冲输出寄存器
reg             ep_rx_bad;       // 端点坏包脉冲输出寄存器
reg             setup_recv;      // SETUP 收妥脉冲输出寄存器
reg             sof_recv;        // SOF 脉冲输出寄存器
reg             rcv;             // 接收模式标志输出寄存器
// Define combination registers here
reg  [2:0]      t_state_nxt;     // 事务状态机次态组合值
// Define wires here
wire [3:0]      ep_sel_nxt;      // ep_sel 次值
wire            is_setup_nxt;    // is_setup 次值
wire [2:0]      toggle_nxt;      // toggle 次值
wire [4:0]      turn_cnt_nxt;    // turn_cnt 次值
wire [10:0]     frame_no_nxt;    // frame_no 次值
wire            resp_req_nxt;    // resp_req 次值
wire [7:0]      resp_pid_nxt;    // resp_pid 次值
wire            buf_ready_nxt;   // buf_ready 次值
wire [6:0]      buf_cnt_nxt;     // buf_cnt 次值
wire [6:0]      wr_ptr_nxt;      // wr_ptr 次值
wire [6:0]      rd_ptr_nxt;      // rd_ptr 次值
wire            pkt_wr_ok_nxt;   // pkt_wr_ok 次值
wire            attached_nxt;    // attached 次值
wire            rx_active_dly_nxt;// rx_active_dly 次值
wire [13:0]     dev_addr_s_nxt;  // dev_addr_s 次值
wire [5:0]      ep_stall_s_nxt;  // ep_stall_s 次值
wire [5:0]      ep_nak_s_nxt;    // ep_nak_s 次值
wire [3:0]      ep_dir_s_nxt;    // ep_dir_s 次值
wire [5:0]      toggle_set_s_nxt;// toggle_set_s 次值
wire [5:0]      toggle_val_s_nxt;// toggle_val_s 次值
wire            ep_rx_done_nxt;  // ep_rx_done 次值
wire            ep_rx_bad_nxt;   // ep_rx_bad 次值
wire            setup_recv_nxt;  // setup_recv 次值
wire            sof_recv_nxt;    // sof_recv 次值
wire            rcv_nxt;         // rcv 次值
wire [6:0]      dev_addr_q;      // 同步后的设备地址
wire [2:0]      ep_stall_q;      // 同步后的端点 halt
wire [2:0]      ep_nak_q;        // 同步后的端点忙
wire [1:0]      ep_dir_q;        // 同步后的端点方向
wire [2:0]      toggle_set_q;    // 同步后的 toggle 初值使能
wire [2:0]      toggle_val_q;    // 同步后的 toggle 初值
wire            rx_active_pos;   // rx_active 上升沿 = 包首
wire            driving;         // 设备是否在驱总线（本轮恒 0，见下）
wire            tobuf_wr_en;     // 净荷写包缓冲（延迟线净荷拍 + 缓冲可用）
wire [6:0]      max_payload;     // 驱动 pkt_rx 的净荷上限（按 ep_sel 查表）
wire            tfsm_go_dwait;   // 事务分派：进数据阶段
wire            tfsm_dat_evt;    // 事务分派：处于数据阶段且本包是数据包结论
wire            tfsm_stay_wait;  // 事务状态机：下一拍仍停在 T_DATA_WAIT
wire            turn_done;       // 周转超时到
wire            addr_ok;         // token 地址匹配
wire            ep_ok;           // token 端点点号在实现范围内
wire            tok_good;        // 本拍是一包完好的 token
wire            tok_sof;         // …且 PID = SOF
wire            tok_dispatch;    // …且 OUT/SETUP 且地址/端点匹配
wire            dat_pid_is1;     // 数据包 PID = DATA1
wire            pl_byte_vld;     // pkt_rx 的净荷写口有效
wire [7:0]      pl_byte;         // pkt_rx 的净荷字节
wire            pkt_done;        // pkt_rx 的包级结论脉冲
wire            pkt_bad;         // pkt_rx 的本包判坏
wire [1:0]      pkt_cls;         // pkt_rx 的包类别
wire [7:0]      pkt_pid;         // pkt_rx 收到的 PID
wire [6:0]      tok_addr;        // pkt_rx 的 token ADDR
wire [3:0]      tok_endp;        // pkt_rx 的 token ENDP
wire [10:0]     tok_frame;       // pkt_rx 的 SOF 帧号
wire [6:0]      dat_len;         // pkt_rx 的数据包净荷长度
wire            ep_dir_bad;      // OUT 事务打到了 IN 配置的端点
wire            ep_stall_sel;    // ep_sel 端点的 halt
wire            ep_nak_sel;      // ep_sel 端点的忙
wire            toggle_sel;      // ep_sel 端点的 data toggle
wire            toggle_match;    // 序列位匹配（期望 DATA0 ⇔ toggle = 0）
wire            busy_sel;        // 决定「能不能收」：端点忙 或 包缓冲未排空
wire [1:0]      dec;             // 应答决策码
wire            acc_setup;       // 决定收下（SETUP）
wire            acc_out;         // 决定收下（OUT）
wire            acc_evt;         // 决定收下（合）
wire [2:0]      tog_flip;        // 本拍要翻转的 toggle 位
wire [2:0]      tog_set;         // 本拍要置 1 的 toggle 位
wire [2:0]      tog_mid;         // 翻转/置位后的 toggle（CPU 覆盖之前）
wire            buf_drain_act;   // 本次读使能真的消耗一个字节
wire            buf_drain_end;   // 本次读使能排空缓冲
// Define instances' ouput wires here
wire            pkt_rx_abort;    // usb_sie_pkt_rx 的 rx_abort 输出
// End of automatic define

///////////////////////////////
//  RTL LOGIC
///////////////////////////////

//-----------------------------------------------------------------------------
// 准静态配置跨域（§2.12）：pclk 域 → clk12m，两拍同步链
//   这些信号只在配置事件（CPU 写寄存器）时变化，事务进行中恒定，不要求逐拍正确。
//   打包成一根同步：高半段 = 同步后的值，低半段 = 第一级。
//-----------------------------------------------------------------------------
assign dev_addr_s_nxt[13:0]   = {dev_addr_s[6:0],   dev_addr[6:0]};
assign ep_stall_s_nxt[5:0]    = {ep_stall_s[2:0],   ep_stall[2:0]};
assign ep_nak_s_nxt[5:0]      = {ep_nak_s[2:0],     ep_nak[2:0]};
assign ep_dir_s_nxt[3:0]      = {ep_dir_s[1:0],     ep_dir[1:0]};
assign toggle_set_s_nxt[5:0]  = {toggle_set_s[2:0], toggle_set[2:0]};
assign toggle_val_s_nxt[5:0]  = {toggle_val_s[2:0], toggle_val[2:0]};

assign dev_addr_q[6:0]   = dev_addr_s[13:7];
assign ep_stall_q[2:0]   = ep_stall_s[5:3];
assign ep_nak_q[2:0]     = ep_nak_s[5:3];
assign ep_dir_q[1:0]     = ep_dir_s[3:2];
assign toggle_set_q[2:0] = toggle_set_s[5:3];
assign toggle_val_q[2:0] = toggle_val_s[5:3];

//-----------------------------------------------------------------------------
// rcv：接收模式标志（→ usb_clk_mux 选 dclk / clk12s）
//   rcv = attached & ~driving。复位后 attached = 0 → rcv = 0 → clk12m 走 clk12s，
//   SIE 才有时钟起振（dclk 未锁时常 0）。
//   driving 本轮恒 0：发包的 tx_active 与远程唤醒的 sie_susp & sie_wkup 都要等
//   对应轮次接进来，接的时候在这里补上，rcv 表达式不动（§1.3）。
//-----------------------------------------------------------------------------
assign driving = 1'b0;
assign rcv_nxt = attached & ~driving;

// 附着：总线插入事件置起，core 复位（含总线复位）清（§2.5）
assign attached_nxt = connect_evt ? 1'b1 : (usb_rst ? 1'b0 : attached);

//-----------------------------------------------------------------------------
// 包首沿与净荷上限
//-----------------------------------------------------------------------------
// rx_active 打一拍：做上升沿检测
assign rx_active_dly_nxt = rx_active;
assign rx_active_pos     = rx_active & ~rx_active_dly;

// 净荷上限按端点查表，驱动 pkt_rx 的长度护栏（§2.6）
assign max_payload[6:0] = (ep_sel[3:0] == EP0) ? MAXP_EP0 :
                          (ep_sel[3:0] == EP1) ? MAXP_EP1 : MAXP_EP2;

//-----------------------------------------------------------------------------
// 包级结论分派（§2.7.2：先按类别分，再对 OUT/IN/SETUP 做地址匹配）
//   SOF 的 11 bit 是帧号不是地址，所以它不过地址匹配——这就是 SOF 单独一行的原因。
//-----------------------------------------------------------------------------
assign addr_ok   = (tok_addr[6:0] == dev_addr_q[6:0]);
assign ep_ok     = (tok_endp[3:0] <= EP_MAX);

assign tok_good     = pkt_done & (pkt_cls[1:0] == 2'd1) & ~pkt_bad;
assign tok_sof      = tok_good & (pkt_pid[7:0] == `PID_SOF);
assign tok_dispatch = tok_good & (pkt_pid[7:0] == `PID_OUT   ? addr_ok & ep_ok :
                                  pkt_pid[7:0] == `PID_SETUP ? addr_ok & ep_ok : 1'b0);
// 本轮没有 T_TX：IN token 收妥后无处可去，静默忽略、留在 T_IDLE（发包下一轮做）

// 处在数据阶段且本包是完好的数据包 —— 应答决策就在这一拍（§2.8）
assign tfsm_dat_evt = pkt_done & (pkt_cls[1:0] == 2'd2)
                      & (t_state_cur[2:0] == T_DATA_WAIT) & ~pkt_bad;

//-----------------------------------------------------------------------------
// 事务状态机（两段式：次态组合 + 时序寄存）
//   次态只用现态与包级结论译码；四条出口对应跳转表的四组行。
//-----------------------------------------------------------------------------
assign tfsm_go_dwait = tok_dispatch;                       // token 收妥 → 进数据阶段
// 超时判决：计数到 TURNAROUND_MAX。若正好这一拍有包首（SOP），让包首赢（计数已被它
//   清零），不然规范允许的最后一个数据包会被判在门外
assign turn_done     = (t_state_cur[2:0] == T_DATA_WAIT) & (turn_cnt[4:0] == TURNAROUND_MAX)
                       & ~rx_active_pos;

// 次态译码（规则 5 两段式状态机，与样板 usb_tx_serial.v 同形）
always @(*) begin
    if (usb_rst) begin
        t_state_nxt[2:0] = T_IDLE;
    end else begin
        case (t_state_cur[2:0])
            T_IDLE: begin
                // OUT/SETUP token 收妥 → 进数据阶段；其余包（含 IN、SOF、坏包）留在本态
                t_state_nxt[2:0] = tfsm_go_dwait ? T_DATA_WAIT : T_IDLE;
            end
            T_DATA_WAIT: begin
                // ★ 新 TOKEN 的派遣优先：主机放弃数据阶段时会直接开下一个事务，
                //   此时必须按新 TOKEN 重新武装（等价于"回 T_IDLE 再进 T_DATA_WAIT"），
                //   否则新 token 的数据阶段没了着落（§2.7.2 跳转表第 9 行）。
                //   其余包（数据包 / 握手 / 坏包）的 pkt_done 或周转超时 → 回空闲。
                t_state_nxt[2:0] = tfsm_go_dwait                          ? T_DATA_WAIT :
                                   ((turn_done | pkt_done) ? T_IDLE : T_DATA_WAIT);
            end
            T_TX: begin
                t_state_nxt[2:0] = T_IDLE;      // 发包轮落地前不跳入
            end
            T_HS_WAIT: begin
                t_state_nxt[2:0] = T_IDLE;      // 发包轮落地前不跳入
            end
            default: begin
                t_state_nxt[2:0] = T_IDLE;
            end
        endcase
    end
end

// 进数据阶段时锁存端点点号与事务类型（max_payload 也靠它）
assign ep_sel_nxt[3:0] = tfsm_go_dwait ? tok_endp[3:0] : ep_sel[3:0];
assign is_setup_nxt    = tfsm_go_dwait ? (pkt_pid[7:0] == `PID_SETUP) : is_setup;

// 周转计时：计数起点 = 进 T_DATA_WAIT 那一拍（= token 的 pkt_done，比 EOP 晚 2 拍），
//   任何包的包首（rx_active↑）也清零（§2.10）。到 TURNAROUND_MAX 就停住，不回卷。
//   ★ 帧中（rx_active=1）压住不计数：数据包本身几十上百拍，一压不住计数早就到顶、
//     包还没收完就被判超时，应答全丢。计时器量的是"token 与数据之间的空档"，不是包长。
assign tfsm_stay_wait = (t_state_cur[2:0] == T_DATA_WAIT) & (t_state_nxt[2:0] == T_DATA_WAIT);
assign turn_cnt_nxt[4:0] = (tfsm_stay_wait & ~rx_active_pos & ~rx_active)
                           ? ((turn_cnt[4:0] == TURNAROUND_MAX) ? TURNAROUND_MAX
                                                                : (turn_cnt[4:0] + 5'd1))
                           : 5'd1;

//-----------------------------------------------------------------------------
// 应答决策（§2.8 规范真值表，按优先级从上到下）
//   坏包（tfsm_dat_evt 里已排除）→ 不应答；OUT 打到 IN 端点 → 不应答（§2.14①）；
//   halt → STALL；序列不匹配 → ACK + 丢弃（去重，不翻转）；忙 → NAK；其余 → ACK + 收下。
//   ★ 「序列不匹配」排在「忙」前面：数据本来就要丢，谈不上收不收得下。
//-----------------------------------------------------------------------------
assign ep_dir_bad = (ep_sel[3:0] == EP2) ? ep_dir_q[1] :
                    (ep_sel[3:0] == EP1) ? ep_dir_q[0] : 1'b0;

assign ep_stall_sel = (ep_sel[3:0] == EP2) ? ep_stall_q[2] :
                      (ep_sel[3:0] == EP1) ? ep_stall_q[1] : ep_stall_q[0];
assign ep_nak_sel   = (ep_sel[3:0] == EP2) ? ep_nak_q[2] :
                      (ep_sel[3:0] == EP1) ? ep_nak_q[1] : ep_nak_q[0];
assign toggle_sel   = (ep_sel[3:0] == EP2) ? toggle[2] :
                      (ep_sel[3:0] == EP1) ? toggle[1] : toggle[0];

// 期望 DATA0 ⇔ toggle = 0（§2.9）
assign toggle_match = (dat_pid_is1 == toggle_sel);
// 「能收」= 端点不忙 且 本包开始时包缓冲可用（pkt_wr_ok 全程不变：中途 CDC 排空
//   也不能让本包变得可收——前半段净荷字节已经被门控丢掉了）
assign busy_sel     = ep_nak_sel | ~pkt_wr_ok;

assign dec[1:0] = ~tfsm_dat_evt                                             ? DEC_NONE :
                  (is_setup & (dat_pid_is1 | (ep_sel[3:0] != EP0)))         ? DEC_NONE :
                  (~is_setup & ep_dir_bad)                                  ? DEC_NONE :
                  (~is_setup & ep_stall_sel)                                ? DEC_STALL :
                  (~is_setup & ~toggle_match)                               ? DEC_ACK :
                  (~is_setup & busy_sel)                                    ? DEC_NAK :
                                                                              DEC_ACK;

assign resp_req_nxt = (dec[1:0] != DEC_NONE);
assign resp_pid_nxt[7:0] = (dec[1:0] == DEC_ACK)   ? `PID_ACK :
                           (dec[1:0] == DEC_NAK)   ? `PID_NAK :
                           (dec[1:0] == DEC_STALL) ? `PID_STALL : RESP_NONE;

// 决定收下：SETUP 无条件（不查 toggle）；OUT 只在序列匹配、第 6 行那个 ACK 上
assign acc_setup = tfsm_dat_evt & is_setup & (dec[1:0] == DEC_ACK);
assign acc_out   = tfsm_dat_evt & ~is_setup & (dec[1:0] == DEC_ACK) & toggle_match;
assign acc_evt   = acc_setup | acc_out;

//-----------------------------------------------------------------------------
// data toggle（§2.9）
//   SETUP 收妥 → 置 1（收发序列位都初始化）；OUT 收下 → 翻转；
//   不匹配 / NAK / STALL / 坏包 → 不翻转。CPU 的 toggle_set 最后覆盖。
//-----------------------------------------------------------------------------
assign tog_flip[2:0]  = acc_out   ? (3'b001 << ep_sel[1:0]) : 3'b000;
assign tog_set[2:0]   = acc_setup ? 3'b001 : 3'b000;          // SETUP 只针对 EP0
assign tog_mid[2:0]   = (toggle[2:0] ^ tog_flip[2:0]) | tog_set[2:0];
assign toggle_nxt[2:0] = usb_rst ? 3'b000 :
                         (tog_mid[2:0] & ~toggle_set_q[2:0])
                         | (toggle_val_q[2:0] & toggle_set_q[2:0]);

//-----------------------------------------------------------------------------
// 包缓冲（§2.11）：收包期写、校验通过且决定收下才置 buf_ready 排出
//-----------------------------------------------------------------------------
// pkt_wr_ok：包首采样「缓冲可用」，全程不变
assign pkt_wr_ok_nxt = rx_active_pos ? ~buf_ready : pkt_wr_ok;

// 净荷写口：写指针每次包首回 0（坏包 / NAK 的包自然也从头来过）
assign tobuf_wr_en = pl_byte_vld & pkt_wr_ok;
assign wr_ptr_nxt[6:0] = (rx_active_pos | usb_rst) ? 7'd0 :
                         tobuf_wr_en ? (wr_ptr[6:0] + 7'd1) : wr_ptr[6:0];

// 排出：buf_rd_en 逐字节消耗。buf_cnt 读到 0 即排空；零长度包（buf_cnt=0）靠
//   一次读脉冲直接收口，省得留一个 buf_ready=1 的死角（§2.14③）
assign buf_drain_act = buf_rd_en & buf_ready;
assign buf_drain_end = buf_drain_act & (buf_cnt[6:0] <= 7'd1);

assign buf_ready_nxt = usb_rst  ? 1'b0 :
                       acc_evt  ? 1'b1 :
                       buf_drain_end ? 1'b0 : buf_ready;
assign buf_cnt_nxt[6:0] = usb_rst    ? 7'd0 :
                          acc_evt    ? dat_len[6:0] :
                          (buf_drain_act & (buf_cnt[6:0] != 7'd0)) ? (buf_cnt[6:0] - 7'd1)
                                                                   : buf_cnt[6:0];
assign rd_ptr_nxt[6:0] = (usb_rst | acc_evt) ? 7'd0 :
                         (buf_drain_act & (buf_cnt[6:0] != 7'd0)) ? (rd_ptr[6:0] + 7'd1)
                                                                  : rd_ptr[6:0];

// 缓冲 64 深，指针只取低 6 位；空包（cnt=0）读出的是上次残留，不会被采纳
assign buf_rd_data[7:0] = pkt_buf[rd_ptr[5:0]];

//-----------------------------------------------------------------------------
// 端点事件与 SOF
//-----------------------------------------------------------------------------
assign ep_rx_done_nxt = acc_evt;
assign setup_recv_nxt = acc_setup;
assign ep_rx_bad_nxt  = pkt_done & (pkt_cls[1:0] == 2'd2) & pkt_bad;
assign sof_recv_nxt   = tok_sof;
assign frame_no_nxt[10:0] = tok_sof ? tok_frame[10:0] : frame_no[10:0];

//-----------------------------------------------------------------------------
// 时序段（规则 8：每个寄存器一条 _nxt + 一个 always）
//-----------------------------------------------------------------------------
always @(posedge clk12m or negedge ref_rstn) begin
    if (!ref_rstn) begin
        t_state_cur[2:0] <= T_IDLE;
    end else begin
        t_state_cur[2:0] <= t_state_nxt[2:0];
    end
end

always @(posedge clk12m or negedge ref_rstn) begin
    if (!ref_rstn) begin
        ep_sel[3:0] <= EP0;
    end else begin
        ep_sel[3:0] <= ep_sel_nxt[3:0];
    end
end

always @(posedge clk12m or negedge ref_rstn) begin
    if (!ref_rstn) begin
        is_setup <= 1'b0;
    end else begin
        is_setup <= is_setup_nxt;
    end
end

always @(posedge clk12m or negedge ref_rstn) begin
    if (!ref_rstn) begin
        toggle[2:0] <= 3'b000;
    end else begin
        toggle[2:0] <= toggle_nxt[2:0];
    end
end

always @(posedge clk12m or negedge ref_rstn) begin
    if (!ref_rstn) begin
        turn_cnt[4:0] <= 5'd1;
    end else begin
        turn_cnt[4:0] <= turn_cnt_nxt[4:0];
    end
end

always @(posedge clk12m or negedge ref_rstn) begin
    if (!ref_rstn) begin
        frame_no[10:0] <= 11'd0;
    end else begin
        frame_no[10:0] <= frame_no_nxt[10:0];
    end
end

always @(posedge clk12m or negedge ref_rstn) begin
    if (!ref_rstn) begin
        resp_req <= 1'b0;
    end else begin
        resp_req <= resp_req_nxt;
    end
end

always @(posedge clk12m or negedge ref_rstn) begin
    if (!ref_rstn) begin
        resp_pid[7:0] <= RESP_NONE;
    end else begin
        resp_pid[7:0] <= resp_pid_nxt[7:0];
    end
end

always @(posedge clk12m or negedge ref_rstn) begin
    if (!ref_rstn) begin
        buf_ready <= 1'b0;
    end else begin
        buf_ready <= buf_ready_nxt;
    end
end

always @(posedge clk12m or negedge ref_rstn) begin
    if (!ref_rstn) begin
        buf_cnt[6:0] <= 7'd0;
    end else begin
        buf_cnt[6:0] <= buf_cnt_nxt[6:0];
    end
end

always @(posedge clk12m or negedge ref_rstn) begin
    if (!ref_rstn) begin
        wr_ptr[6:0] <= 7'd0;
    end else begin
        wr_ptr[6:0] <= wr_ptr_nxt[6:0];
    end
end

always @(posedge clk12m or negedge ref_rstn) begin
    if (!ref_rstn) begin
        rd_ptr[6:0] <= 7'd0;
    end else begin
        rd_ptr[6:0] <= rd_ptr_nxt[6:0];
    end
end

// 包缓冲本体：只写在收包期、只读在排出期，且读出前必被本包写满（收下才算数），
//   所以不接复位——64 字节的复位网络不值当，也读不到没写过的位置
always @(posedge clk12m) begin
    if (tobuf_wr_en) begin
        pkt_buf[wr_ptr[5:0]] <= pl_byte[7:0];
    end
end

always @(posedge clk12m or negedge ref_rstn) begin
    if (!ref_rstn) begin
        pkt_wr_ok <= 1'b0;
    end else begin
        pkt_wr_ok <= pkt_wr_ok_nxt;
    end
end

always @(posedge clk12m or negedge ref_rstn) begin
    if (!ref_rstn) begin
        attached <= 1'b0;
    end else begin
        attached <= attached_nxt;
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
        rcv <= 1'b0;
    end else begin
        rcv <= rcv_nxt;
    end
end

always @(posedge clk12m or negedge ref_rstn) begin
    if (!ref_rstn) begin
        ep_rx_done <= 1'b0;
    end else begin
        ep_rx_done <= ep_rx_done_nxt;
    end
end

always @(posedge clk12m or negedge ref_rstn) begin
    if (!ref_rstn) begin
        ep_rx_bad <= 1'b0;
    end else begin
        ep_rx_bad <= ep_rx_bad_nxt;
    end
end

always @(posedge clk12m or negedge ref_rstn) begin
    if (!ref_rstn) begin
        setup_recv <= 1'b0;
    end else begin
        setup_recv <= setup_recv_nxt;
    end
end

always @(posedge clk12m or negedge ref_rstn) begin
    if (!ref_rstn) begin
        sof_recv <= 1'b0;
    end else begin
        sof_recv <= sof_recv_nxt;
    end
end

always @(posedge clk12m or negedge ref_rstn) begin
    if (!ref_rstn) begin
        dev_addr_s[13:0] <= 14'd0;
    end else begin
        dev_addr_s[13:0] <= dev_addr_s_nxt[13:0];
    end
end

always @(posedge clk12m or negedge ref_rstn) begin
    if (!ref_rstn) begin
        ep_stall_s[5:0] <= 6'd0;
    end else begin
        ep_stall_s[5:0] <= ep_stall_s_nxt[5:0];
    end
end

always @(posedge clk12m or negedge ref_rstn) begin
    if (!ref_rstn) begin
        ep_nak_s[5:0] <= 6'd0;
    end else begin
        ep_nak_s[5:0] <= ep_nak_s_nxt[5:0];
    end
end

always @(posedge clk12m or negedge ref_rstn) begin
    if (!ref_rstn) begin
        ep_dir_s[3:0] <= 4'd0;
    end else begin
        ep_dir_s[3:0] <= ep_dir_s_nxt[3:0];
    end
end

always @(posedge clk12m or negedge ref_rstn) begin
    if (!ref_rstn) begin
        toggle_set_s[5:0] <= 6'd0;
    end else begin
        toggle_set_s[5:0] <= toggle_set_s_nxt[5:0];
    end
end

always @(posedge clk12m or negedge ref_rstn) begin
    if (!ref_rstn) begin
        toggle_val_s[5:0] <= 6'd0;
    end else begin
        toggle_val_s[5:0] <= toggle_val_s_nxt[5:0];
    end
end

///////////////////////////////
//  INSTANTIATION
///////////////////////////////
// 包级接收解析（无跨包记忆）。pid_ok / tok_crc_ok / dat_crc_ok 是 pkt_rx 的判据
//   中间量，只供仿真探针用，本层不再往外引（pkt_bad 已把它们收进去）。
/* verilator lint_off PINCONNECTEMPTY */
usb_sie_pkt_rx u_pkt_rx (
    .clk12m       (clk12m),
    .ref_rstn     (ref_rstn),
    .rx_data      (rx_data[7:0]),
    .rx_valid     (rx_valid),
    .rx_active    (rx_active),
    .rx_error     (rx_error),
    .max_payload  (max_payload[6:0]),
    .rx_abort     (pkt_rx_abort),
    .pl_byte      (pl_byte[7:0]),
    .pl_byte_vld  (pl_byte_vld),
    .pkt_done     (pkt_done),
    .pkt_bad      (pkt_bad),
    .pkt_cls      (pkt_cls[1:0]),
    .pid          (pkt_pid[7:0]),
    .pid_ok       (),
    .tok_addr     (tok_addr[6:0]),
    .tok_endp     (tok_endp[3:0]),
    .tok_frame    (tok_frame[10:0]),
    .tok_crc_ok   (),
    .dat_pid_is1  (dat_pid_is1),
    .dat_crc_ok   (),
    .dat_len      (dat_len[6:0]));
/* verilator lint_on PINCONNECTEMPTY */

// rx_abort 是纯输入直通（规则 6 兜底条款）：它由 pkt_rx 寄存后出来，直连
//   usb_rx_deserial 的 frame_clr，要当拍生效，本层不能再打一拍。
assign rx_abort = pkt_rx_abort;

endmodule
