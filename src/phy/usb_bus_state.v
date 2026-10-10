//==================================================
// Created by        : xxx
// Filename          : usb_bus_state.v
// Author            : xiao_yuan
// Created On        : 2026-09-23 10:20
// Last Modified     : 2026-09-28 line_s 改由 usb_rx_deserial 采好送入（共用采样寄存器）
// Update Count      : 2026-09-28 第 3 版
// Description       : USB 1.1 FS 总线状态检测（连接 / 复位 / 挂起 / 唤醒）
//                     判据跑 ref_clk 域，四个输出是 clk12m 域单拍脉冲
//
//   职责：只看线电平（`line_s`，取自 usb_rx_deserial 的采样寄存器），按「保持了多久」
//     判出四个总线宏观事件，
//     出单拍脉冲给 SIE——connect_evt / usb_bus_rst / suspend_evt / resume_evt。
//   不解析位、不解析字节（那是 usb_rx_deserial 的活）；不产生 rcv、不给远程唤醒
//     发驱动许可、不碰寄存器堆。usb_rst 不由这里产生，来源与集成位置待定（§2.8）
//   「USB 复位」有两种来源：芯片自己的软件复位，和主机在总线上发的 SE0 ≥2.5µs。
//     两者在外面并成 usb_rst 一根进来（那就是 core 复位），模块内不再自己并一次
//
//   结构 = 一条计数器 + 两个标志位 + 两个翻转位，没有状态机：
//     任何线变化、或我们自己在驱（driving = usb_tx_serial 的 tx_en）都清零计数器，
//     「线变化就清零」这一个动作把保持时长量了出来，三个 2.5µs 门限于是共用一条计数器。
//     计数上界随线状态走：J 态 3ms、其余态 2.5µs，到顶就停；计到门限那一拍看线状态
//     与标志位出事件。
//
//   线电平不在本模块采：`line_s` 由 usb_rx_deserial 采样后送来（两个模块在 PHY 顶层
//     挨着实例化），本模块只用它出「线变化」，另存一拍 line_s_dly 做比较
//
//   两域分工：
//     ref_clk (4×) — 全部判据、计数器、两个标志位、两个翻转位
//     clk12m (1×)  — 事件跨域（两拍同步 + 取沿），组合出单拍脉冲
//   两域都由 ref_clk 派生、上升沿对齐（clk12m 的两个来源 dclk / clk12s 都在 ref_clk 域
//   寄存产生），所以 driving 组合直连、事件单拍采样都不是异步 CDC。
//
//   设计报告：doc/design_rpt/bus_state_design.md
//     §2.2 线状态分类与 driving / §2.3 一条计数器四个判据 / §2.4 两个标志位
//     §2.5 复位与附着（总线复位经 usb_rst 清 connected）/ §2.6 事件跨域 / §2.8 复位口径
//==================================================

`timescale 1ns/1ps

///////////////////////////////
//  INSTANCE FILE PATH
///////////////////////////////
// Instance: demo.v
module usb_bus_state(/*autoarg*/
    //Inputs
    clk12m, ref_clk, ref_rstn, usb_rst, line_s, tx_en,

    //Outputs
    connect_evt, usb_bus_rst, suspend_evt, resume_evt, bus_suspended);

///////////////////////////////
//  PARAMETER DEFINE
///////////////////////////////
// 门限常量（ref_clk = 48MHz，1 拍 = 20.83ns）
localparam [17:0] CNT_2P5U      = 18'd120;     // 2.5µs：连接 / 复位 / 被动唤醒共用一个门限
localparam [17:0] CNT_3MS       = 18'd144000;  // 3ms：挂起门限
// 计数上界 = 门限 + 1：判定点落在门限那一拍，计数再走一拍才停。停在门限本身的话，
//   cnt == 门限 就成了一段长电平，两个走翻转通知的判据（rst / rsm）在这段电平里每拍翻一次，
//   翻转位到 clk12m 一侧就采不出这一次事件（推导见 bus_state_design.md §2.3）
localparam [17:0] CNT_2P5U_TOP  = CNT_2P5U + 18'd1;
localparam [17:0] CNT_3MS_TOP   = CNT_3MS  + 18'd1;

///////////////////////////////
//  INPUT & OUTPUT
///////////////////////////////
input           clk12m;     //clock 恢复的 12MHz（clk_mux 切出）：事件跨域与输出寄存的时钟
input           ref_clk;    //clock 48MHz 参考时钟：全部判据跑这个域
input           ref_rstn;   //reset 异步复位，低有效（与 usb_rx_deserial 同一根复位网络）
input           usb_rst;    //reset core 复位（软复位 ∪ 总线复位），同步高有效，只进 ref_clk 域；集成位置待定（§2.8）；判据状态与两个标志位吃它，共用的 line_s 与两个翻转位不吃
input  [1:0]    line_s;     // 线电平 {D+, D-}，来自 usb_rx_deserial 的采样寄存器（ref_clk 域，2026-09-28 起共用）
input           tx_en;      // usb_tx_serial 的驱动器使能 = driving 的来源（组合直连，§2.2）

// to sie
output          connect_evt;// 连接事件脉冲：J 保持 ≥2.5µs 且此前未连接过
output          usb_bus_rst;// 总线复位事件脉冲：SE0 保持 ≥2.5µs 且已连接过
output          suspend_evt;// 挂起事件脉冲：总线空闲（J）≥3ms
output          resume_evt; // 被动唤醒事件脉冲：挂起中主机驱 K ≥2.5µs
output          bus_suspended;// 挂起状态（电平，clk12m 域）：suspended 经 sus_s 同步链的输出版，给 usb_tx_serial 的唤醒旁路用

///////////////////////////////
//  WIRE  & REG DECLARE
///////////////////////////////
/*autodefine*/
// Define flip-flop registers here
reg  [17:0]     cnt;             // 唯一计数器：距上次线变化多少拍，上界随线状态（J=3ms，其余=2.5µs）
reg  [1:0]      con_s;           // 连接事件：clk12m 域两拍同步链，源是 connected 标志位
reg             connected;       // 连接标志：总线空闲态曾经成立（清于 usb_rst = core 复位）
reg  [1:0]      line_s_dly;      // line_s 打一拍，与它比较出线变化
reg  [1:0]      rst_s;           // 总线复位事件：clk12m 域两拍同步链，源是 rst_tgl 翻转位
reg             rst_tgl;         // 总线复位事件：ref_clk 域翻转位（判据单拍 → 翻一次）
reg  [1:0]      rsm_s;           // 被动唤醒事件：clk12m 域两拍同步链，源是 rsm_tgl 翻转位
reg             rsm_tgl;         // 被动唤醒事件：ref_clk 域翻转位（判据单拍 → 翻一次）
reg  [1:0]      sus_s;           // 挂起事件：clk12m 域两拍同步链，源是 suspended 标志位
reg             suspended;       // 挂起标志：总线空闲 J 已 ≥3ms
// Define combination registers here
// Define wires here
wire            bus_suspended;   // 挂起状态（电平，clk12m 域）：sus_s[0] 直出
wire            cnt_2p5u;        // 计数器命中 2.5µs 门限，且本拍线没变
wire            cnt_3ms;         // 计数器命中 3ms 门限，且本拍线没变
wire            cnt_at_top;      // 计数器已到本轮上界（到顶后不再前进）
wire            cnt_clr;         // 计数器清零（线变化 / 我们自己在驱）
wire [17:0]     cnt_nxt;         // cnt 的 D 线
wire            con_cond;        // 连接判据：2.5µs + J + 未连接
wire [1:0]      con_s_nxt;       // con_s 的 D 线
wire            connect_evt;     // 连接事件脉冲（组合直出，clk12m 一拍）
wire            connected_nxt;   // connected 的 D 线
wire            driving;         // 驱动器使能（组合直连 tx_en），门控与清零共用
wire            line_chg;        // 本拍线状态与上一拍不同
wire            line_j;          // 线状态：J（D+ 高、D- 低）
wire            line_k;          // 线状态：K（D+ 低、D- 高）
wire [1:0]      line_s_dly_nxt;  // line_s_dly 的 D 线
wire            line_se0;        // 线状态：SE0（两线同低）
wire            resume_evt;      // 被动唤醒事件脉冲（组合直出，clk12m 一拍）
wire            rst_cond;        // 总线复位判据：2.5µs + SE0 + 已连接
wire [1:0]      rst_s_nxt;       // rst_s 的 D 线
wire            rst_tgl_nxt;     // rst_tgl 的 D 线
wire            rsm_cond;        // 被动唤醒判据：2.5µs + K + 挂起中
wire [1:0]      rsm_s_nxt;       // rsm_s 的 D 线
wire            rsm_tgl_nxt;     // rsm_tgl 的 D 线
wire            sus_cond;        // 挂起判据：3ms + J + 已连接 + 未挂起
wire [1:0]      sus_s_nxt;       // sus_s 的 D 线
wire            suspend_evt;     // 挂起事件脉冲（组合直出，clk12m 一拍）
wire            suspended_nxt;   // suspended 的 D 线
wire            usb_bus_rst;     // 总线复位事件脉冲（组合直出，clk12m 一拍）
// Define instances' ouput wires here
// End of automatic define

///////////////////////////////
//  RTL LOGIC
///////////////////////////////

//========================================================================
// ref_clk 域 — 判据（线状态 / 计数器 / 四个判据 / 两个标志位 / 两个翻转位）
//========================================================================

//-----------------------------------------------------------------------------
// line_s：线电平，usb_rx_deserial 在 ref_clk 域采好送过来（xiao_yuan 2026-09-28 定：共用）
//   本模块不再自己采一遍：同一对线在同一批 ref 拍上，两级串联的采样器永远给同一个值，
//   白白多两个触发器。共用之后哪边采都一样，两个模块在 PHY 顶层挨着放，端口直连
//   共用寄存器位于 deserial 内，只吃 ref_rstn、不吃 usb_rst（它就是总线本身，实时采）；
//     复位若动了它，复位撤掉那一拍会造一次假线变化
//   门限都是 120 拍量级，采样值滞后一拍不影响判据
//-----------------------------------------------------------------------------

//-----------------------------------------------------------------------------
// line_s_dly：打一拍，与 line_s 比较出「线变化」
//   纯打拍，不吃 usb_rst：line_s 自己就不吃（见上），它再打一拍自然跟着走；
//   加进来只会让两者差一拍，把线变化量歪
//-----------------------------------------------------------------------------
assign line_s_dly_nxt[1:0] = line_s[1:0];

always @(posedge ref_clk or negedge ref_rstn) begin
    if (!ref_rstn) begin
        line_s_dly[1:0] <= 2'b00;
    end
    else begin
        line_s_dly[1:0] <= line_s_dly_nxt[1:0];
    end
end

//-----------------------------------------------------------------------------
// 线状态分类：只认 J / K / SE0 三态
//   SE1(2'b11) 不作判据（规范里只是交叉瞬间；真持续说明 PHY 坏了，SE0/J 停摆同样
//   看得出来），但它仍会清零计数器——它也是一次线变化（§2.3）
//-----------------------------------------------------------------------------
assign line_j   = (line_s[1:0] == 2'b10);   // D+ 高、D- 低：全速 idle
assign line_k   = (line_s[1:0] == 2'b01);   // D+ 低、D- 高：数据位 / 主机 resume 信令
assign line_se0 = (line_s[1:0] == 2'b00);   // 两线同低：EOP(≈160ns) / 总线复位(≥2.5µs)

//-----------------------------------------------------------------------------
// driving：组合直连 usb_tx_serial 的 tx_en（xiao_yuan 2026-09-22 定：不打拍、不同步）
//   取 tx_en 不取 SIE 的 tx_active：tx_active 是「发送请求」，tx_en 是「驱动器真的在驱」。
//   clk12m 的两个来源都在 ref_clk 域寄存产生，故这里读 clk12m 域寄存器无亚稳（§2.2）。
//   它挡住两件事：包尾我们自己的 EOP SE0、远程唤醒那 1~15ms 的 K（§2.7）
//-----------------------------------------------------------------------------
assign driving = tx_en;

//-----------------------------------------------------------------------------
// cnt：唯一计数器，计数值的含义 =「当前线状态保持了多久」
//   清零：线变了，或我们自己在驱（driving）
//   上界：J 态 3ms、SE0/K/SE1 态 2.5µs。每个线状态只留它可能用到的那个门限，到顶就停：
//     J 要等挂起的 3ms，SE0 与 K 只要 2.5µs（复位与被动唤醒），停在 2.5µs 顺带让长时间
//     SE0（复位挂着）的高位计数器不再翻转。
//   上界取「门限 + 1」而不是门限本身，理由见门限命中那段
//-----------------------------------------------------------------------------
assign line_chg = (line_s[1:0] != line_s_dly[1:0]);
assign cnt_clr  = driving | line_chg;

assign cnt_at_top = line_j ? (cnt[17:0] == CNT_3MS_TOP) :
                             (cnt[17:0] == CNT_2P5U_TOP);

assign cnt_nxt[17:0] = usb_rst    ? 18'd0     :
                       cnt_clr    ? 18'd0     :
                       cnt_at_top ? cnt[17:0] :
                       (cnt[17:0] + 18'd1);

always @(posedge ref_clk or negedge ref_rstn) begin
    if (!ref_rstn) begin
        cnt[17:0] <= 18'd0;
    end
    else begin
        cnt[17:0] <= cnt_nxt[17:0];
    end
end

//-----------------------------------------------------------------------------
// 门限命中：计数到位，且「本拍线没变」
//   ★ 第二项不可省：line_s 刚更新那一拍，cnt 还是旧值而线已取新水平，若此刻 cnt 恰好
//     等于门限，判据就会拿「旧计数 + 新线状态」去比——2.5µs 的 K 会被算成主机 resume。
//     加上它之后，判据的含义严格是「当前这个线水平已保持 120 / 144000 拍」
//   ★ 上界取「门限 + 1」是为这条脉冲只此一拍：停在门限上的话，两个走翻转通知的判据
//     会每拍翻一次，翻转位到 clk12m 一侧就采不出这次事件（见 §2.3）
//-----------------------------------------------------------------------------
assign cnt_2p5u = (cnt[17:0] == CNT_2P5U) & (~line_chg);
assign cnt_3ms  = (cnt[17:0] == CNT_3MS)  & (~line_chg);

//-----------------------------------------------------------------------------
// 四个判据 = 门限 + 线状态 + 标志位（§2.3 表）
//   每条再带一个 ~driving 是第二重保险：计数器清零与判据求值在同一拍上有竞争窗口（§2.3）
//   四条互斥：120 与 144000 之间隔着 143880 拍，线上的 J/K/SE0 又只能取一个值（§2.6）
//   ★ rst_cond 里的 connected 只挡「从没连过」那一段 SE0（没插线时线长期停在 SE0）。
//     拔出走的正是这一条：线拔掉后总线落回 SE0，够 2.5µs 判出一次总线复位，这个事件
//     在外面并进 usb_rst，附着状态随之作废，线再插回来总线回 J，2.5µs 后重新报 connect。
//     集成放在哪里待定（§2.8），本模块不自己并
//-----------------------------------------------------------------------------
assign con_cond = cnt_2p5u & line_j   & (~driving) & (~connected);
assign sus_cond = cnt_3ms  & line_j   & (~driving) & connected & (~suspended);
assign rst_cond = cnt_2p5u & line_se0 & (~driving) & connected;
assign rsm_cond = cnt_2p5u & line_k   & (~driving) & suspended;

//-----------------------------------------------------------------------------
// connected：连接标志，清于 usb_rst 与上电复位 ref_rstn
//   三个用途：connect_evt 只报一次（就是它的上升沿）/ 挂起判据的前置 / 复位判据的前置
//     （没连过就谈不上复位：电缆没插时线可能长期停在 SE0，§2.2）
//   清于 usb_rst（xiao_yuan 2026-09-24 定）：这个输入是 core 复位，软复位把 core 状态清掉，
//     主机发起的总线复位把协议状态清掉，两种都得重新从总线判一次附着。复位结束后总线
//     若回到空闲 J，2.5µs 后重报一次 connect_evt，SIE 靠它把 rcv 重新拉起来
//   ★ 模块内不再另并一条 rst_cond（xiao_yuan 2026-09-24 定）：总线复位那一路从 usb_rst 进来，
//     集成逻辑放在外面，本模块单跑时它不会动这一位
//   拔出落在这同一条上：线拔掉后总线是长 SE0，判出总线复位，外面把它并进 usb_rst 后这一位
//     被清，线再插回来会重新报 connect_evt。剩下的空缺只有「自供电设备拔出后线读成 J」
//     那种前端，要靠 usb_vbus 才分得开（§4.7）
//-----------------------------------------------------------------------------
assign connected_nxt = usb_rst ? 1'b0 : (con_cond ? 1'b1 : connected);

always @(posedge ref_clk or negedge ref_rstn) begin
    if (!ref_rstn) begin
        connected <= 1'b0;
    end
    else begin
        connected <= connected_nxt;
    end
end

//-----------------------------------------------------------------------------
// suspended：挂起标志，置于 3ms 空闲 J，清于 usb_rst / 主机 resume 的 K / 判出的总线复位
//   与 connected 同一把复位，两个观察一起作废重新量起：总线若还空闲，connect 2.5µs 后、
//     挂起 3ms 后各自重报一次
//   ★ 这里比 connected 多列一条 rst_cond：总线复位说明总线刚被主机驱动过，不可能还在挂起。
//     这一位若留着，复位后总线上的 K 会被误判成主机 resume。等外面把总线复位并进 usb_rst
//     之后这一条是冗余的，留着不改变行为
//   sus_cond 里的 ~suspended 是语义上的「只报一次」：进了挂起就不再重复报同一段空闲
//   （脉冲形状由 cnt 上界保证，不靠这一项兜）
//   ★ 它的上升沿就是 suspend_evt；下降沿不是任何事件（reset / resume 各有自己的通路）
//-----------------------------------------------------------------------------
assign suspended_nxt = usb_rst  ? 1'b0     :
                       sus_cond ? 1'b1     :
                       (rsm_cond | rst_cond) ? 1'b0 : suspended;

always @(posedge ref_clk or negedge ref_rstn) begin
    if (!ref_rstn) begin
        suspended <= 1'b0;
    end
    else begin
        suspended <= suspended_nxt;
    end
end

//-----------------------------------------------------------------------------
// rst_tgl / rsm_tgl：两个判据类事件的翻转位（xiao_yuan 2026-09-28 定，跨域用）
//   为什么不用「判据展宽成电平再同步」：展宽要盖住一个 clk12m 周期，得凭空造一条计时器；
//     翻转位在源域是持续电平，同步链一定采得到，两拍之差就是一个脉冲。
//   为什么能翻：rst_cond / rsm_cond 是单拍判据（cnt_2p5u 只此一拍），一次事件只翻一次。
//     两次同类事件至少隔 2.5µs，远大于一个 clk12m 周期，不会两翻相消。
//   ★ 只吃 ref_rstn，不吃 usb_rst：usb_rst 若清它，clk12m 侧会看见一次跳变，
//     凭空多出一个事件脉冲。它不表示任何状态，纯粹是「刚发生过一次」的载体
//-----------------------------------------------------------------------------
assign rst_tgl_nxt = rst_cond ? (~rst_tgl) : rst_tgl;

always @(posedge ref_clk or negedge ref_rstn) begin
    if (!ref_rstn) begin
        rst_tgl <= 1'b0;
    end
    else begin
        rst_tgl <= rst_tgl_nxt;
    end
end

assign rsm_tgl_nxt = rsm_cond ? (~rsm_tgl) : rsm_tgl;

always @(posedge ref_clk or negedge ref_rstn) begin
    if (!ref_rstn) begin
        rsm_tgl <= 1'b0;
    end
    else begin
        rsm_tgl <= rsm_tgl_nxt;
    end
end

//========================================================================
// clk12m 域 — 两拍同步 + 取沿 + 输出寄存（单拍脉冲）
//   只吃 ref_rstn、不混 usb_rst：一个域里不混两种复位（§2.8）
//   链位序：con_s[0] 是新采到的样本、con_s[1] 是上一拍
//   四个事件源分两类（xiao_yuan 2026-09-28 定）：
//     标志位类 connected / suspended —— 本身就是长电平（连上/挂起之后一直保持），
//       取上升沿即事件，不需要任何额外的保持手段；
//     判据类 rst_cond / rsm_cond —— ref_clk 域单拍脉冲，取不了沿，改用翻转位通知
//       （rst_tgl / rsm_tgl），两拍同步链里新旧值不同即一个脉冲。
//   两域由 ref_clk 派生、上升沿对齐，这两拍不是为了防亚稳，是为了对齐边沿（§2.2）
//   ★ 四个输出都是组合直出（xiao_yuan 2026-09-28 定，规则 6 的特例）：它们只送同域的
//     SIE，不直连 pad、不进模拟 PHY、不跨域，规则 6 要寄存的那三条理由一条都不沾。
//     取沿的两位都是同一个同步链上的相邻触发器，每个 clk12m 沿最多变一位，
//     与/异或都不出毛刺；脉冲宽度就是 1 个 clk12m 周期
//========================================================================

//-----------------------------------------------------------------------------
// connect_evt：连接事件脉冲（clk12m 一拍，组合直出）
//   源是 connected 标志位：它由 con_cond 置起、只清于 usb_rst，是一个长电平
//   （con_cond 自己只有一拍宽，直接送过来是采不到的）
//   延迟 = 判据起拍 → 脉冲起拍 1..4 个 ref 拍，随 clk12m 相位循环（4 个相位下 3/2/1/4），
//   上界 4 拍 = 一个 clk12m 周期 ≈83ns（§4.6）
//-----------------------------------------------------------------------------
assign con_s_nxt[1:0]  = {con_s[0], connected};
assign connect_evt     = con_s[0] & (~con_s[1]);

always @(posedge clk12m or negedge ref_rstn) begin
    if (!ref_rstn) begin
        con_s[1:0] <= 2'b00;
    end
    else begin
        con_s[1:0] <= con_s_nxt[1:0];
    end
end

//-----------------------------------------------------------------------------
// usb_bus_rst：总线复位事件脉冲（clk12m 一拍，组合直出）
//   ★ 名字与输入 usb_rst 只差一个词：usb_rst 是复位来源，这个是判出来的总线复位事件
//   源是 rst_tgl 翻转位，取「新旧不同」（异或）而不是上升沿
//-----------------------------------------------------------------------------
assign rst_s_nxt[1:0]  = {rst_s[0], rst_tgl};
assign usb_bus_rst     = rst_s[0] ^ rst_s[1];

always @(posedge clk12m or negedge ref_rstn) begin
    if (!ref_rstn) begin
        rst_s[1:0] <= 2'b00;
    end
    else begin
        rst_s[1:0] <= rst_s_nxt[1:0];
    end
end

//-----------------------------------------------------------------------------
// suspend_evt：挂起事件脉冲（clk12m 一拍，组合直出）
//   源是 suspended 标志位：它由 sus_cond 置起（3ms 空闲 J），清于 resume / 总线复位，
//   置起之后最少也保持 120 拍（要等下一个够长的 K 或 SE0 才清），足够同步链采到
//-----------------------------------------------------------------------------
assign sus_s_nxt[1:0]  = {sus_s[0], suspended};
assign suspend_evt     = sus_s[0] & (~sus_s[1]);

//-----------------------------------------------------------------------------
// bus_suspended：挂起状态（电平，clk12m 域）
//   同一条 sus_s 链的输出级，不再另开一条同步链：上位机驱动的挂起态与本模块判出的
//   suspended 是同一件事，usb_tx_serial 的唤醒旁路读这里、不再读 SIE 回送的那一份
//   （xiao_yuan 2026-09-29 定）。边沿与 suspend_evt 同一拍。
//   ★ 本模块的翻新只走 ref_rstn：usb_rst 落下 suspended 后，这一侧还要 1~2 个
//     clk12m 拍才跟下来，那几拍读到的是旧值（同 suspend_evt，见 §2.8）
//-----------------------------------------------------------------------------
assign bus_suspended   = sus_s[0];

always @(posedge clk12m or negedge ref_rstn) begin
    if (!ref_rstn) begin
        sus_s[1:0] <= 2'b00;
    end
    else begin
        sus_s[1:0] <= sus_s_nxt[1:0];
    end
end

//-----------------------------------------------------------------------------
// resume_evt：被动唤醒事件脉冲（clk12m 一拍，组合直出）
//   只认主机驱的 K：挂起中 K 保持 ≥2.5µs。自己驱的 K 期间 driving=1，判据被挡（§2.7）
//   源是 rsm_tgl 翻转位。★ 不能拿 rsm_cond 的电平来同步：suspended 恰好是被 rsm_cond
//     清的，门控与事件同拍翻转，那样得到的电平恒为一拍宽，与 K 有多长无关
//-----------------------------------------------------------------------------
assign rsm_s_nxt[1:0]  = {rsm_s[0], rsm_tgl};
assign resume_evt      = rsm_s[0] ^ rsm_s[1];

always @(posedge clk12m or negedge ref_rstn) begin
    if (!ref_rstn) begin
        rsm_s[1:0] <= 2'b00;
    end
    else begin
        rsm_s[1:0] <= rsm_s_nxt[1:0];
    end
end

endmodule
