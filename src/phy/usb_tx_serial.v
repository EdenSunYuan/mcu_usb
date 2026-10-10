//==================================================
// Created by        : xxx
// Filename          : usb_tx_serial.v
// Author            : xiao_yuan
// Created On        : 2026-09-18 10:55
// Last Modified     :
// Update Count      : 2026-09-18 10:55
// Description       : USB 1.1 FS TX 串行器（字节 → NRZI 位流），1x clk12m 域
//
//   职责：把 SIE 给的字节流送上 USB 线——
//     自产 SYNC(0x80) → 位填充(6 连 1 插 0) → NRZI 编码 → EOP(SE0 x2 + J x1)
//   不碰 CRC / PID / 端点（那是 SIE 的活，本模块不解释字节内容）；
//   不做反压——tx_active 一拉高就必须把整包连续发完（USB 也不允许包中间停）。
//
//   挂起/远程唤醒（bus_suspended / sie_wkup，均 clk12m 域、均为电平）：
//   走旁路，不进状态机。挂起期间状态机仍停在 S_IDLE，两个信号直接压 tx_bit/tx_en：
//     挂起 + sie_wkup=1 → tx_en=1 且 tx_bit=0，线上驱 K（远程唤醒信令）；
//     挂起 + sie_wkup=0 → tx_en=0，交高阻（上拉给出空闲 J）；
//     未挂起           → 两个信号都不生效，包路径照常。
//   挂起态来自 usb_bus_state 的 bus_suspended（判出 suspended 的同步输出版），
//   不是 SIE 回送的副本：旁路判据是"总线已挂起（PHY 自己判的）+ SIE 请求唤醒"，
//   读源少一次往返，主机接管那一段也能同一拍解除武装（xiao_yuan 2026-09-29 定）。
//   为什么不开第 7 个状态：唤醒 K 不需要 SYNC/填充/EOP 任何一条流水，也不参与
//   tx_ready/tx_done 握手，开状态反而要多写一组转移与出口条件。
//
//   状态机（6 态，两段式：次态组合 + 时序寄存）：
//     S_IDLE → S_SYNC → {S_DATA | S_DATA_LAST} → S_EOP1 → S_EOP2 → S_IDLE
//   位填充计数**从 PID 起算、SYNC 不参与**——由 bit_ones_cnt_nxt 在非数据相位
//   无条件清零天然保证，不需要任何额外的复位路径。
//
//   设计报告：doc/design_rpt/tx_serial_design.md
//     §2.6 状态机 / §2.7 握手时序 / §2.8 供字节预算 / §2.10 输出寄存器化
//     §2.11 挂起与远程唤醒的 K 驱动
//==================================================
///////////////////////////////
//  INSTANCE FILE PATH
///////////////////////////////
// Instance: demo.v
module usb_tx_serial(/*autoarg*/
    //Inputs
    clk12m, ref_rstn, tx_active, tx_data, tx_last, bus_suspended, sie_wkup,

    //Outputs
    tx_en, tx_bit, tx_se0, tx_ready, tx_done);

///////////////////////////////
//  PARAMETER DEFINE
///////////////////////////////
// 位状态机状态编码（3 bit，one-hot 无用：只求时序干净，编码值就是状态序号）
localparam [2:0] S_IDLE      = 3'b000;  // 空闲：等 tx_active，线保持 J，tx_en=0
localparam [2:0] S_SYNC      = 3'b001;  // 发 SYNC(0x80)：恒 8 拍纯移位，不跑填充
localparam [2:0] S_DATA      = 3'b010;  // 发普通数据字节：载 tx_data，移 8 拍（过填充）
localparam [2:0] S_DATA_LAST = 3'b011;  // 发末字节：与 S_DATA 行为相同，差别只在出口
localparam [2:0] S_EOP1      = 3'b100;  // EOP 第 1 拍 SE0；兼作尾填充拍
localparam [2:0] S_EOP2      = 3'b101;  // EOP 第 2 拍 SE0

///////////////////////////////
//  INPUT & OUTPUT
///////////////////////////////
input           clk12m;    //clock 发送位时钟：1 拍 = 1 bit（83336 ps）
input           ref_rstn;   //reset 异步复位，低有效
input           tx_active;  // SIE 的发送请求：上升沿起包，中途拉低 = 中止
input [7:0]     tx_data;    // SIE 送来的待发字节（LSb 先发）
input           tx_last;    // 「本字节是最后一个」标志：与末字节同拍拉起，见该字节的 tx_ready 即可拉低（§2.7）
input           bus_suspended;// 总线挂起状态（电平，clk12m 域）：来自 usb_bus_state 的 bus_suspended，1 = 总线已挂起，包路径应停
input           sie_wkup;   // SIE 的远程唤醒请求（电平，clk12m 域）：挂起中为 1 时线上驱 K

// to phy
output          tx_en;      // 驱动器使能：1 = 驱动总线，0 = 交高阻（包间/空闲）
output          tx_bit;     // NRZI 线电平（D+ 数据线电平），S_EOP 段被 tx_se0 顶替
output          tx_se0;     // SE0 标志：1 = 两线同时拉低（EOP），优先级高于 tx_bit

// to sie
output          tx_ready;   // 「当前字节已取走」握手脉冲，每个字节都发（含最后一个）
output          tx_done;    // 整包发完（EOP 结束）脉冲，SIE 见它才撤 tx_active

///////////////////////////////
//  WIRE  & REG DECLARE
///////////////////////////////
/*autodefine*/
// Define flip-flop registers here
reg  [2:0]      bit_cnt;         // 字节内已发出的位数计数 (0..7)，满 8 进下一字节
reg  [2:0]      bit_ones_cnt;    // 已连续发出的 1 的个数 (0..6)，凑满 6 要插一个 0
reg  [7:0]      data_shift;      // 发送移位寄存器，bit[0] 是当前要发的那一位
reg             tx_active_dly;   // tx_active 打一拍，用于做上升沿检测
reg             tx_bit;          // 线电平输出寄存器（NRZI 的翻转基准就是它自己的现态）
reg             tx_done;         // 完成脉冲输出寄存器
reg             tx_en;           // 驱动器使能输出寄存器
reg             tx_ready;        // 取字节握手脉冲输出寄存器
reg             tx_se0;          // SE0 输出寄存器
reg  [2:0]      tx_stat_cur;     // 位状态机：现态寄存器
// Define combination registers here
reg  [2:0]      tx_stat_nxt;     // 位状态机：次态组合值
// Define wires here
wire            bit_cnt_7;       // 字节内 8 位已发满 (bit_cnt == 7)，可换下一字节
wire [2:0]      bit_cnt_nxt;     // bit_cnt 次值
wire [2:0]      bit_ones_cnt_nxt;// bit_ones_cnt 次值
wire            bit_stuff;       // 本拍要插填充 0（已凑满 6 连 1）；被 5 处引用，语义单一
wire            data_load_en;    // 本拍载入 tx_data 进移位寄存器
wire            data_shift_en;   // 本拍移位寄存器右移 1 位（填充拍被压住不移位）
wire [7:0]      data_shift_nxt;  // data_shift 次值（优先级下降链：清/载 SYNC/载数据/移/保持）
wire            tx_active_pos;   // tx_active 上升沿，起包判据
wire            tx_bit_nxt;      // tx_bit 的 D 线（NRZI 就地编码）
wire            tx_done_nxt;     // tx_done 的 D 线
wire            tx_ready_nxt;    // tx_ready 的 D 线
wire            tx_se0_nxt;      // tx_se0 的 D 线
// Define instances' ouput wires here
// End of automatic define

///////////////////////////////
//  RTL LOGIC
///////////////////////////////

//-----------------------------------------------------------------------------
// 位状态机 · 时序段：现态寄存器
//-----------------------------------------------------------------------------
always @(posedge clk12m or negedge ref_rstn) begin
    if (!ref_rstn) begin
        tx_stat_cur[2:0] <= S_IDLE;
    end
    else begin
        tx_stat_cur[2:0] <= tx_stat_nxt[2:0];
    end
end

//-----------------------------------------------------------------------------
// 位状态机 · 组合段：次态译码
//   ★ 最外层 if(~tx_active) 在 case 之外 → 优先级最高，=「中止」：
//      SIE 撤请求后下一拍必回 S_IDLE，bit_cnt/data_shift/bit_ones_cnt 同拍被清。
//   ★ 所有条件只用「现态 + 现态各寄存器值」译码，不引任何次值线（规则 6）。
//-----------------------------------------------------------------------------
always @(*) begin
    if(~tx_active)
        tx_stat_nxt[2:0] = S_IDLE;
    else begin
        case(tx_stat_cur[2:0])
        S_IDLE: begin
            // 起包看上升沿（tx_active_pos）而非电平——电平另有「中止」含义，两者分开
            tx_stat_nxt[2:0] = tx_active_pos ? S_SYNC : S_IDLE;
        end
        S_SYNC: begin
            // SYNC 恒 8 拍：不跑填充（bit_ones_cnt 在 S_SYNC 恒 0），故无需 hold
            tx_stat_nxt[2:0] = bit_cnt_7 ? (tx_last ? S_DATA_LAST : S_DATA) : S_SYNC;
        end
        S_DATA: begin
            // 满 8 位且非填充拍才换字节；tx_last 在字节边界直接采端口（无 last_q 锁存）
            tx_stat_nxt[2:0] = (bit_cnt_7 && (~bit_stuff) && tx_last) ? S_DATA_LAST : S_DATA;
        end
        S_DATA_LAST: begin
            // 末字节与 S_DATA 行为相同，差别只在出口：发完即转 EOP，不再载入
            // 正插尾填充 0 的那拍 (~bit_stuff)=0 → 自环一拍把 0 补上
            tx_stat_nxt[2:0] = (bit_cnt_7 && (~bit_stuff)) ? S_EOP1 : S_DATA_LAST;
        end
        S_EOP1: begin
            // ★ 兼尾填充拍：进态那拍若恰好攒满 6 连 1（如末字节 0xFC 的 b7 收尾），
            //   自环一拍把填充 0 补在数据位与 SE0 之间，否则接收端会把它算进 SE0
            tx_stat_nxt[2:0] = bit_stuff ? S_EOP1 : S_EOP2;
        end
        S_EOP2: begin
            // SE0 第 2 拍完即回 IDLE；tx_done 在回 IDLE 那一拍输出（见 tx_done_nxt）
            tx_stat_nxt[2:0] = S_IDLE;
        end
        default: begin
            tx_stat_nxt[2:0] = S_IDLE;
        end
        endcase
    end
end

//-----------------------------------------------------------------------------
// tx_active 打一拍，用于上升沿检测
//-----------------------------------------------------------------------------
always @(posedge clk12m or negedge ref_rstn) begin
    if (!ref_rstn) begin
        tx_active_dly <= 1'b0;
    end
    else begin
        tx_active_dly <= tx_active;
    end
end

// 起包标志：tx_active 由 0→1 的那一拍（电平本身只用来判中止）
assign tx_active_pos = tx_active & (~tx_active_dly);

//-----------------------------------------------------------------------------
// 移位寄存器控制：载入 / 移位
//-----------------------------------------------------------------------------
// 换字节：上一字节 8 位发完（bit_cnt_7）且当拍不是填充拍 → 下一拍载入新字节
assign data_load_en = ((tx_stat_cur[2:0] == S_SYNC) || (tx_stat_cur[2:0] == S_DATA))
                      && bit_cnt_7 && (~bit_stuff) ;

// 移位使能：数据相位都要移；但填充拍置 0 → 数据通路 hold 一拍（插 0 的那拍）
assign data_shift_en =  ((tx_stat_cur[2:0] == S_SYNC)
                      || (tx_stat_cur[2:0] == S_DATA)
                      || (tx_stat_cur[2:0] == S_DATA_LAST))
                      && (~bit_stuff) ;

// 移位寄存器次值，优先级从高到低：
//   撤请求 → 清 0；起包 → 载 SYNC(0x80 = LSb 先发正好是「7 个 0 + 1 个 1」)；
//   换字节 → 载 tx_data；数据相位 → 右移（bit[0] 是当前要发的位，故 LSb first）；否则保持
assign data_shift_nxt[7:0] = (~tx_active)     ? 8'b0000_0000 :
                             tx_active_pos    ? 8'b1000_0000 :
                             data_load_en     ? tx_data[7:0] :
                             data_shift_en    ? {1'b0,data_shift[7:1]} :
                             data_shift[7:0];

always @(posedge clk12m or negedge ref_rstn) begin
    if (!ref_rstn) begin
        data_shift[7:0] <= 8'b0000_0000;
    end
    else begin
        data_shift[7:0] <= data_shift_nxt[7:0];
    end
end

//-----------------------------------------------------------------------------
// 字节内位计数：进 IDLE 清零，每移一位 +1（填充拍不移位故不前进）
//-----------------------------------------------------------------------------
assign bit_cnt_nxt[2:0] = (tx_stat_cur[2:0] == S_IDLE) ? 3'b000 :
                          data_shift_en ? (bit_cnt[2:0] + 1'b1) :
                          bit_cnt[2:0];

// 字节发满（bit_cnt 是 0..7，==7 表示本位是字节内最后一位）
assign bit_cnt_7 = bit_cnt[2:0] == 3'b111;

always @(posedge clk12m or negedge ref_rstn) begin
    if (!ref_rstn) begin
        bit_cnt[2:0] <= 3'b000;
    end
    else begin
        bit_cnt[2:0] <= bit_cnt_nxt[2:0];
    end
end

//-----------------------------------------------------------------------------
// 连 1 计数（位填充用）
//   非数据相位（含 SYNC、EOP、IDLE）无条件清零 → 填充计数天然「从 PID 起算」，
//   SYNC 段攒不出连 1，且 EOP/中止/包间也不会有残留计数。
//   数据相位：刚插过 0 → 重新起数；否则按本拍发出的数据位 data_shift[0] 累加/清零。
//-----------------------------------------------------------------------------
assign bit_ones_cnt_nxt[2:0] = ~((tx_stat_cur[2:0] == S_DATA)
                               || (tx_stat_cur[2:0] == S_DATA_LAST)) ? 3'b000 :
                               (bit_stuff ? 3'b000 :
                               data_shift[0] ? (bit_ones_cnt[2:0] + 1'b1) : 3'b000);

// 已凑满 6 连 1 → 本拍要插填充 0。
// 语义单一：是 1 就表示「本拍线上出的是填充 0，不是数据位」，被 5 处引用——
//   data_shift_en(hold 一拍) / data_load_en(不在填充拍换字节) / bit_cnt_nxt(间接不前进)
//   / tx_bit_nxt(强制翻转) / tx_se0_nxt(在 S_EOP1 压住 SE0)
assign bit_stuff = bit_ones_cnt[2:0] == 3'b110;

always @(posedge clk12m or negedge ref_rstn) begin
    if (!ref_rstn) begin
        bit_ones_cnt[2:0] <= 3'b000;
    end
    else begin
        bit_ones_cnt[2:0] <= bit_ones_cnt_nxt[2:0];
    end
end

///////////////////////////////
//  输出寄存器化（DFF 直出，现态译码 D = f(现态)）
//  规则 6：tx_bit/tx_se0/tx_en 直连模拟 PHY，必须是寄存器直出。
//  代价 = 每个输出整体后移一拍（tx_ready 因此比组合版晚一拍给，
//  SIE 备下一字节的余量由 8 拍降到 7 拍，已在设计报告 §2.8/§2.10 记账）。
//  挂起旁路也落在同一条链上：bus_suspended/sie_wkup 到线电平同样晚一拍（§2.11）。
///////////////////////////////

//-----------------------------------------------------------------------------
// tx_ready：「当前字节已取走」握手脉冲（每个字节都发，含义恒定）
//   判据与 data_load_en 相同，但寄存一拍 → 出现在载入之后那一拍
//-----------------------------------------------------------------------------
assign tx_ready_nxt = ((tx_stat_cur[2:0] == S_SYNC) || (tx_stat_cur[2:0] == S_DATA))
                      && bit_cnt_7 && (~bit_stuff);

always @(posedge clk12m or negedge ref_rstn) begin
    if (!ref_rstn) begin
        tx_ready <= 1'b0;
    end
    else begin
        tx_ready <= tx_ready_nxt;
    end
end

//-----------------------------------------------------------------------------
// tx_done：整包发完脉冲（现态 == S_EOP2 时寄存 → 回 S_IDLE 那一拍输出）
//-----------------------------------------------------------------------------
assign tx_done_nxt = tx_stat_cur[2:0] == S_EOP2;

always @(posedge clk12m or negedge ref_rstn) begin
    if (!ref_rstn) begin
        tx_done <= 1'b0;
    end
    else begin
        tx_done <= tx_done_nxt;
    end
end

//-----------------------------------------------------------------------------
// tx_bit：NRZI 就地编码（不复用 usb_nrzi_enc，翻转基准就是 tx_bit 自己的现态）
//   ① 非数据相位（IDLE / S_EOP2 / 非填充拍的 S_EOP1）→ 强制 J，
//      EOP 段的线电平由 tx_se0 顶替，tx_bit 的值在那里无意义但仍保持 J 便于回 idle；
//   ② 填充拍 / 数据位 0 → 翻转；数据位 1 → 保持；
//   ③ 挂起旁路（优先级最高）：K 就是 tx_bit=0（J=1/K=0），故挂起中取 ~sie_wkup——
//      sie_wkup=1 线电平给 0（配 tx_en=1 成 K），sie_wkup=0 给回 J 待命。
//-----------------------------------------------------------------------------
assign tx_bit_nxt = ~((tx_stat_cur[2:0] == S_SYNC)
                   || (tx_stat_cur[2:0] == S_DATA)
                   || ((tx_stat_cur[2:0] == S_EOP1) && bit_stuff)
                   || (tx_stat_cur[2:0] == S_DATA_LAST)) ? 1'b1 :
                   (bit_stuff ? (~tx_bit) :
                   data_shift[0] ? tx_bit : (~tx_bit));

always @(posedge clk12m or negedge ref_rstn) begin
    if (!ref_rstn) begin
        tx_bit <= 1'b1;                     // 复位到 J（USB 空闲电平）
    end
    else if(bus_suspended)begin
        tx_bit <= ~sie_wkup;                // 挂起中：线电平只由唤醒请求定（K = 0 / J = 1）
    end
    else begin
        tx_bit <= tx_bit_nxt;
    end
end

//-----------------------------------------------------------------------------
// tx_se0：SE0 = 两线同时拉低，只在 EOP 拉高
//   填充拍的 S_EOP1 被 bit_stuff 压住 → 尾填充那拍不拉 SE0
//-----------------------------------------------------------------------------
assign tx_se0_nxt = ((tx_stat_cur[2:0] == S_EOP1) && (~bit_stuff))
                 || (tx_stat_cur[2:0] == S_EOP2) ;

always @(posedge clk12m or negedge ref_rstn) begin
    if (!ref_rstn) begin
        tx_se0 <= 1'b0;
    end
    else begin
        tx_se0 <= tx_se0_nxt;
    end
end

//-----------------------------------------------------------------------------
// tx_en：驱动器使能（唯一不能纯现态译码的输出）
//   D 无法预知输入 tx_active 下一拍掉不掉，所以写成带进入/退出条件的寄存器：
//     起包：tx_active 上升沿置 1（比状态晚一拍，那拍线上还是 J，无影响）；
//     退出：模块自己的收尾条件 st == S_IDLE 清 0 → 与 EOP 尾拍严丝合缝，
//           线路正好多驱动 J 一位时间再交高阻（与组合版同拍）。
//   代价落在中止路径：撤 tx_active 后 tx_en 晚一拍才掉，线上多驱动 1 位数据位
//   ——USB 不允许包中间停，属错误路径（用例 tx_abort / tx_abort_phases）。
//   挂起旁路（优先级最高）：挂起中使能只跟 sie_wkup 走——要唤醒就驱（配 tx_bit=0
//   成 K），唤醒撤了立刻交高阻（回归规范要求的"信号结束不驱到 J"）。此时状态机
//   即使被误发的 tx_active 带离 S_IDLE，也驱不动总线（用例 tx_susp_wkup 验过）。
//-----------------------------------------------------------------------------
always @(posedge clk12m or negedge ref_rstn) begin
    if (!ref_rstn) begin
        tx_en <= 1'b0;
    end
    else if(bus_suspended)begin
        tx_en <= sie_wkup;                  // 挂起中：只有远程唤醒请求能开驱动器
    end
    else if(tx_active_pos)begin
        tx_en <= 1'b1;
    end
    else if(tx_stat_cur[2:0] == S_IDLE)begin
        tx_en <= 1'b0;
    end
    else begin
        tx_en <= tx_en;
    end
end

endmodule
