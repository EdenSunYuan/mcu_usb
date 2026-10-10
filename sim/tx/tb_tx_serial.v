//============================================================================
// tb_tx_serial.v — usb_tx_serial 单元测试顶层 (PHY 模型 + 已验收发链回环)
//
// DUT 链 (设计报告 §4.8.1):
//
//   usb_tx_serial ──tx_bit/tx_se0/tx_en──> phy_model ──rxdp/rxdn──┐
//                                                                  │
//   usb_rx_cdr (ref_clk 48MHz) ──dclk(恢复 12MHz)+rx_bit──> usb_rx_deserial
//                                                                  │
//                                          rx_valid/rx_data ───────┘ → 回环比对
//
// 三条独立判据 (报告 §4.8.3):
//   A 端到端回环 (主): 收到的字节流 == 发出的字节流
//   B 逐位 oracle (定位): TB 自写位流生成器 vs 线上 NRZI 解码出的位流逐位比
//   C 跨语言旁证: tools/gen_tx_timing.py --dump 的逐拍 trace (脚本侧人工复核)
//
// ★ 回环里 usb_rx_deserial 的 tx_active / rx_abort / usb_rst 必须接 0 (报告 §4.8.2):
//   deserial 的 tx_active 是自收发门控 (为 1 时被摁在 USB_IDLE, 什么都收不到)。
//   USB 是半双工 —— 发送时接收侧恒为"非发送"。接错的现象是"回环永远收不到"。
//   usb_rst 是 core 复位同步脉冲: 悬空 = z, 会把 frame_clr 拉成 x, rx_valid/帧态跟着变 x,
//   现象同上 (回环收不到字节)。本 TB 无 core 复位, 恒接 0。
//
// 本 TB 扮演 SIE 侧角色: 直接驱动 tx_active/tx_data/tx_last, 不建 USB 包 builder
// (TX 的输入是数字字节流, 不涉及物理波形)。
//============================================================================

`timescale 1ns/1ps

`include "usb_const.vh"        // PID 线上字节值 (src/inc, 需 -I)

module tb_tx_serial;

    // ---- USB 时间参数 ----
    parameter real BIT_TIME = 1000.0 / 12.0;        // 83.333ns

    // ---- 48MHz ref_clk ----
    parameter real CLK_HALF = 1000.0 / 48.0 / 2.0;
    reg ref_clk = 1'b0;
    reg ref_rstn = 1'b0;
    always #(CLK_HALF) ref_clk = ~ref_clk;

    // ---- clk12s = ref_clk ÷ 4 (发送期 TX 的 clk12m, 与 usb_clk_mux 输出等价) ----
    reg [1:0] div_cnt = 2'd0;                       // ref_clk 四分频计数 (★ 带声明初值:
                                                    // 复位序列会先放开 ref_rstn 再拉低,
                                                    // 其间计数器不能被复位, 靠初值定 0)
    always @(posedge ref_clk or negedge ref_rstn) begin
        if (!ref_rstn)
            div_cnt <= 2'd0;
        else
            div_cnt <= div_cnt + 2'd1;
    end
    wire clk12s = div_cnt[1];                       // 12MHz, 上升沿对齐 ref_clk

    //========================================================================
    // DUT + 回环链
    //========================================================================

    reg        tx_active;                           // SIE 发送请求 (TB 驱动)
    reg        bus_suspended = 1'b0;                     // 总线挂起状态 (TB 驱动, clk12m 域电平, 来自 usb_bus_state)
    reg        sie_wkup = 1'b0;                     // SIE 远程唤醒请求 (TB 驱动, clk12m 域电平)
                                                    // ★ 声明即定值: 同 drv_req 的理由 ——
                                                    //   两个信号进 DUT 的是**无兜底 if-else 链**
                                                    //   的头一级, x 会让挂起旁路在复位序列期间
                                                    //   误生效。
    wire [7:0] tx_data;                             // 待发字节 (组合译出, 见下)
    wire       tx_last;                             // 最后一个字节标志 (组合译出)
    wire       tx_ready, tx_done, tx_bit, tx_se0, tx_en;

    usb_tx_serial u_tx (
        .clk12m  (clk12s),                         // 发送期 clk12m 即本地 clk12s（ref_clk÷4）
        .ref_rstn (ref_rstn),
        .tx_active(tx_active),
        .tx_data  (tx_data),
        .tx_last  (tx_last),
        .bus_suspended (bus_suspended),
        .sie_wkup (sie_wkup),
        .tx_ready (tx_ready),
        .tx_done  (tx_done),
        .tx_bit   (tx_bit),
        .tx_se0   (tx_se0),
        .tx_en    (tx_en)
    );

    wire       rxdp, rxdn;                          // 差分总线 (phy_model 驱动)
    phy_model u_phy (
        .tx_bit(tx_bit),
        .tx_se0(tx_se0),
        .tx_en (tx_en),
        .rxdp  (rxdp),
        .rxdn  (rxdn)
    );

    wire       dclk, rx_bit;
    usb_rx_cdr u_cdr (
        .ref_clk (ref_clk),
        .ref_rstn(ref_rstn),
        .rxdp    (rxdp),
        .rxdn    (rxdn),
        .dclk    (dclk),
        .rx_bit  (rx_bit)
    );

    wire [7:0] rx_data;
    wire       rx_valid, rx_active, rx_error;
    usb_rx_deserial u_rx (
        .clk12m    (dclk),
        .ref_clk   (ref_clk),
        .ref_rstn  (ref_rstn),
        .rx_bit    (rx_bit),
        .rxdp      (rxdp),
        .rxdn      (rxdn),
        .tx_active (1'b0),                          // ★ 半双工: 接收侧恒非发送
        .rx_abort  (1'b0),
        .usb_rst   (1'b0),                          // ★ 回环无 core 复位 (悬空会让 frame_clr 变 x)
        .rx_data   (rx_data),
        .rx_valid  (rx_valid),
        .rx_active (rx_active),
        .rx_error  (rx_error),
        .line_state()
    );

    //========================================================================
    // 自检状态
    //========================================================================

    integer errors = 0;                             // 全局错误计数 (PASS/FAIL 判据)

    // ---- 本包待发字节 (TB 扮演 SIE: 摆上 tx_data 的队列) ----
    integer   tx_n    = 0;                          // 本包字节数
    reg [7:0] tx_bytes[0:255];                      // 本包字节

    // ---- 发送侧观测 ----
    integer   pkt_ready_n;                          // 本包 tx_ready 脉冲数
    integer   ready_t [0:255];                      // 各 tx_ready 脉冲所在 clk12s 拍号
                                                    // ★ 深度必须 >= 最大包字节数 (tx_bytes 同深):
                                                    //   原 0:63 放不下 83 字节包 → 越界项在 iverilog 里
                                                    //   是 x (比较恒假 → 悄悄漏检), Verilator 2 态里是 0
                                                    //   → 负间隔假失败。见 ready_gap_check。
    reg       ready_d;                              // tx_ready 上一拍 (边沿检测)
    integer   cyc     = 0;                          // clk12s 自由拍计数
    integer   eop_se0_n;                            // 本包 tx_se0 高电平拍数
    integer   eop_j_n;                              // 本包 EOP J 拍数 (tx_done 拍)
    reg       done_seen;                            // 本包已见 tx_done
    reg       drv_req_d;                            // drv_req 上一拍 (包起始沿)

    // ---- 逐位 oracle ----
    reg       exp_bits[0:4095];                     // 期望位流 (TB 自写生成器)
    integer   exp_n;                                // 期望位数
    reg       rec_bits[0:4095];                     // 线上解码出的位流
    integer   rec_n;                                // 解码位数
    reg       rec_started;                          // 已见 SOP (首个 K 电平)
    reg       rec_prev_lv;                          // 上一拍 NRZI 电平

    // ---- 接收侧观测 (回环) ----
    integer   rx_nb;                                // 本帧已收字节数
    reg [7:0] rx_buf [0:255];                       // 本帧收到的字节
    integer   rx_frames = 0;                        // 累计关包帧数
    integer   err_frames = 0;                       // 其中被 RX 判错的帧 (rx_error=1)
    reg       rx_last_err;                          // 最近一帧关包时的 rx_error
    reg       in_frame_d;                           // rx_active 上一拍
    integer   rx_last_nb;                           // 最近一帧字节数
    reg [7:0] rx_last_buf [0:255];                  // 最近一帧字节 (帧关时快照)

    //========================================================================
    // SIE 侧驱动 (clk12s 域) — 扮演 SIE: 摆字节 + 握手
    //========================================================================

    // ★ 声明即定值 (2026-09-20): 复位序列 (下方 initial 块的 ①②③) 跑完之前,
    //   `drv_req`/`drv_busy` 本来是 x; 而下面 `tx_active` 的产生块是一条无兜底的
    //   if-else 链 —— x 会落到最后那个 else → **凭空拉起 tx_active**, 在总线上留下
    //   一个幽灵 SYNC 头, 把整包的字节对齐带偏。
    //   触发条件很隐蔽: 只要 DUT 的 `tx_ready`/`tx_done` **复位值是 1'b1**, 幽灵包
    //   就被 drv_busy 误锁而"看起来没事"; 复位值改回与项目 RTL 一致的 1'b0 后,
    //   立刻 19 个用例全挂 (报"位流长度 19, 期望 16"这类错位)。是 TB 的锅, 不是 DUT 的。
    reg       drv_req  = 1'b0;                      // TB 请求发送 (case 任务置位)
    reg       drv_busy = 1'b0;                      // 本包已完, 等 TB 撤请求
    integer   drv_idx;                              // 当前摆在 tx_data 上的字节序号
    reg       last_taken = 1'b0;                    // 末字节的 tx_ready 已看到 → tx_last 可以落

    // ---- tx_active: 由请求 + tx_done 产生 (不自己产生, 报告 §2.7) ----
    always @(posedge clk12s or negedge ref_rstn) begin
        if (!ref_rstn) begin
            tx_active <= 1'b0;
            drv_busy  <= 1'b0;
        end else if (!drv_req) begin
            tx_active <= 1'b0;                      // TB 未请求 / 已撤 (中止或收尾)
            drv_busy  <= 1'b0;
        end else if (drv_busy) begin
            tx_active <= 1'b0;                      // 本包已完, 等 TB 撤请求
            drv_busy  <= 1'b1;
        end else if (tx_done) begin
            tx_active <= 1'b0;                      // EOP 发完 → 下一拍撤请求
            drv_busy  <= 1'b1;
        end else begin
            tx_active <= 1'b1;                      // 请求中 → 保持发送
            drv_busy  <= 1'b0;
        end
    end

    // ---- drv_idx: 看到 tx_ready 就前进到下一字节 (最后一个不再前进) ----
    always @(posedge clk12s or negedge ref_rstn) begin
        if (!ref_rstn)
            drv_idx <= 0;
        else if (!tx_active)
            drv_idx <= 0;                           // 空闲/中止: 回到队首
        else if (tx_ready) begin
            if (drv_idx < tx_n - 1)
                drv_idx <= drv_idx + 1;             // 取走一个, 摆上下一个
            else
                drv_idx <= drv_idx;                 // 末字节之后不再前进
        end else
            drv_idx <= drv_idx;
    end

    // ---- last_taken: 看到**末字节**那一拍的 tx_ready → 下一拍把 tx_last 落掉 ----
    // 这就是 SIE 侧最省事的做法 (§2.7 契约): 不必盯 tx_done, 也不必保持到包尾。
    always @(posedge clk12s or negedge ref_rstn) begin
        if (!ref_rstn)
            last_taken <= 1'b0;
        else if (!tx_active)
            last_taken <= 1'b0;                     // 新包 / 中止: 重新武装
        else if (tx_ready && (drv_idx == (tx_n - 1)))
            last_taken <= 1'b1;                     // 末字节已被取走
        else
            last_taken <= last_taken;               // 保持 (显式写出)
    end

    // ---- tx_data / tx_last: 由当前字节序号组合译出 ----
    // ★ 必须是连续赋值, 不能写成 `always @(drv_idx or tx_n)`:
    //   本 TB 的 clr_pkt + put 在**同一时刻**里先后改 tx_n (1→0→1), 而 Verilator
    //   对显式敏感表的 always 只按"净变化"判要不要重算 → 该块不触发, tx_data 停在
    //   上一包的字节 (现象: 第 2 包起每包都发第 1 包的字节, 回环比对全挂)。
    //   连续赋值在两家的语义都恒为最新值。不用 @* 是因为 @* 对 256 字数组全敏感,
    //   Icarus 会告警。
    //   已用最小例子双证: 同一时刻 clr+put 后, 连续赋值 iverilog/Verilator 都给新值,
    //   显式敏感表 Verilator 给旧值。
    // ---- tx_last: 末字节标志, 与末字节同拍拉起, 看到它的 tx_ready 即落 ----
    // 契约 (tx_serial_design.md §2.7, 用户 2026-09-21 定):
    //   DUT 只在 S_SYNC/S_DATA 的**字节载入边界**采样 tx_last (载入末字节那一拍);
    //   末字节载入后 FSM 进 S_DATA_LAST 并自环 8 拍, 全程不再引用它,
    //   `tx_ready_nxt`/`tx_done_nxt` 也不含它。
    //   → SIE **看到末字节那一拍的 tx_ready 就可以拉低** (`last_taken`), 既不用盯
    //     `tx_done`, 也不用保持到包尾; 反过来保持到包尾同样合法 —— DUT 都不再看它。
    //   唯一硬约束: **不能跨包残留** —— 下一包首字节载入前必须为 0。本模型靠
    //   `!tx_active` 把 `last_taken` 复位 + `&& tx_active` 锚在包内, 两条路径
    //   (正常收尾 / 中途中止) 都天然满足。
    assign tx_data = (drv_idx < tx_n) ? tx_bytes[drv_idx] : 8'h00;
    assign tx_last = (tx_n > 0) && (drv_idx == (tx_n - 1)) && tx_active && (~last_taken);

    //========================================================================
    // 发送侧监视: tx_ready 脉冲 / tx_se0 宽度 / 逐位 oracle
    //========================================================================

    always @(posedge clk12s or negedge ref_rstn) begin
        if (!ref_rstn) begin
            cyc           <= 0;
            pkt_ready_n   <= 0;
            ready_d       <= 1'b0;
            eop_se0_n     <= 0;
            eop_j_n       <= 0;
            done_seen     <= 1'b0;
            rec_started   <= 1'b0;
            rec_n         <= 0;
            rec_prev_lv   <= 1'b1;
        end else begin
            cyc      <= cyc + 1;
            drv_req_d <= drv_req;

            // --- 包起始 (drv_req 上升沿): 清本包观测 ---
            // 只在包起始清, 不在 drv_req 拉低时清 —— 观测值要留到 run_pkt 判完。
            if (drv_req && !drv_req_d) begin
                pkt_ready_n <= 0;
                ready_d     <= 1'b0;
                eop_se0_n   <= 0;
                eop_j_n     <= 0;
                done_seen   <= 1'b0;
                rec_started <= 1'b0;
                rec_n       <= 0;
                rec_prev_lv <= 1'b1;
            end else if (drv_req) begin
                // --- tx_ready 脉冲: 记拍号, 顺带查"不得跨两拍" ---
                if (tx_ready && !ready_d) begin
                    if (pkt_ready_n < 256)
                        ready_t[pkt_ready_n] = cyc;
                    pkt_ready_n <= pkt_ready_n + 1;
                end
                if (tx_ready && ready_d) begin
                    $display("    FAIL: tx_ready 连续两拍为高 (应恒为 1 拍脉冲) @%0t", $time);
                    errors = errors + 1;
                end
                ready_d <= tx_ready;


                // --- EOP 观测: SE0 拍数 / J 拍数 ---
                if (tx_se0) eop_se0_n <= eop_se0_n + 1;
                if (tx_done) eop_j_n  <= eop_j_n + 1;

                // --- 逐位 oracle (路径 B) ---
                // 从 SOP 起: 线上 NRZI 电平 J→K 的那个沿 = 第 1 个 SYNC 位 (0)。
                // 之后每拍电平不变 → 数据 1, 电平翻转 → 数据 0。EOP 段 (SE0 / J 拍)
                // 不是数据, 跳过; tx_en=0 的高阻拍也不算。
                if (!rec_started) begin
                    if (tx_en && !tx_se0 && !tx_bit) begin
                        rec_started <= 1'b1;
                        rec_prev_lv <= tx_bit;      // 参考电平更新为 K (J→K = 这一位 0)
                        rec_bits[rec_n] = 1'b0;     // 首位必是 0 (J→K 翻转)
                        rec_n <= rec_n + 1;
                    end
                end else if (!done_seen) begin
                    if (tx_done) begin
                        done_seen <= 1'b1;          // EOP 的 J 拍: 不是数据位
                    end else if (tx_en && !tx_se0) begin
                        rec_bits[rec_n] = (tx_bit == rec_prev_lv) ? 1'b1 : 1'b0;
                        rec_n       <= rec_n + 1;
                        rec_prev_lv <= tx_bit;
                    end
                end
            end
        end
    end

    //========================================================================
    // 规则 6 结构守卫: 输出必须是 DFF 直出 (无组合逻辑锥) —— 2026-09-20 重写
    //
    // 判据: `tx_bit`/`tx_se0`/`tx_done`/`tx_ready` 都是寄存器输出且直连模拟 PHY。
    // 组合译码的输出会**跟着输入在任意时刻变** (不在时钟沿上), 那正是规则 6 要挡的:
    // 多比特同时翻转出假脉冲、直通管脚没有建立/保持预算。所以这里只断言一条**结构**
    // 性质: 这四个输出只允许在 clk12s 上升沿变。
    //
    // ★ 旧的「寄存器 Q == 现态组合值」等价性断言已删。它断言的是 2026-09-17 选的
    //   **次态译码** (`Q(n) === 现态组合值(n)`); `_sy` 设计改用**现态译码** (规则 6
    //   现在的默认写法), 变成 `Q(n) === 现态组合值(n-1)`, 旧式子在每个数据位都差一拍。
    //   同一处的 `tx_en === tx_active` 直通契约也随之作废: 新设计的 `tx_en` 是寄存器
    //   (tx_active↑ 之后一拍才拉高), 刻意如此 (报告 §2.6)。
    //   删了不亏 —— 输出"发的是什么"由路径 B (`exp_bits` 逐位 oracle) 与路径 A (回环
    //   逐字节) 独立把关, 本块只补"怎么变"这条结构性质。
    //========================================================================

    integer last_edge_t = -1;                       // 最近一次 clk12s 上升沿时刻
    // ★ 用阻塞赋值, 且只在本时钟这一处写: 寄存器输出是 NBA 更新, 落在本拍 active 区
    //   **之后**, 所以输出跟着沿变的那一刻, 这里读到的已经是本拍时刻 (不会误判)。
    always @(posedge clk12s) last_edge_t = $time;

    // ---- out_edge_check: 输出变化只准落在时钟沿上 ----
    task out_edge_check(input [255:0] sig_name);
        begin
            // 复位撤除前不查: 复位值是复位沿给的, 本来就不在时钟沿上
            if (ref_rstn && (last_edge_t >= 0) && ($time !== last_edge_t)) begin
                $display("    FAIL: %0s 在非 clk12s 沿变化 (@%0t, 最近沿 %0t) —— 不是 DFF 直出",
                         sig_name, $time, last_edge_t);
                errors = errors + 1;
            end
        end
    endtask

    always @(tx_bit)   out_edge_check("tx_bit");
    always @(tx_se0)   out_edge_check("tx_se0");
    always @(tx_done)  out_edge_check("tx_done");
    always @(tx_ready) out_edge_check("tx_ready");

    //========================================================================
    // 接收侧监视 (回环链, dclk 域)
    //========================================================================

    always @(posedge dclk or negedge ref_rstn) begin
        if (!ref_rstn) begin
            in_frame_d <= 1'b0;
        end else begin
            // 帧开沿: 清本帧字节缓冲
            if (!in_frame_d && rx_active) begin
                rx_nb = 0;
            end
            // 帧关沿: 快照字节 + 关包错误标志
            if (in_frame_d && !rx_active) begin
                rx_last_err = rx_error;
                rx_last_nb  = rx_nb;
                begin : snap
                    integer k;
                    for (k = 0; k < rx_nb; k = k + 1)
                        rx_last_buf[k] = rx_buf[k];
                end
                rx_frames = rx_frames + 1;
                if (rx_error)
                    err_frames = err_frames + 1;
            end
            in_frame_d <= rx_active;
            // 字节收集
            if (rx_valid) begin
                rx_buf[rx_nb] = rx_data;
                rx_nb = rx_nb + 1;
            end
        end
    end

    //========================================================================
    // 因果链记录器 (sim/common/README「仿真结果确认规范」规则 1~3)
    //
    // 只记录 + 打印, **不参与 PASS/FAIL** (规则 4: 断言负责判错, 打印负责给证据)。
    //   前窗 = 包起前"线 J 且 DUT 停 S_IDLE"的连续拍数 (证干净空闲起点);
    //   因   = tx_active↑; 变 = 状态迁移 + 插 0 拍数; 果 = tx_done + 回 S_IDLE;
    //   后窗 = tx_done 后线仍 J 且 DUT 仍 S_IDLE 的连续拍数 (证交高阻=电气空闲)。
    // 前窗计数**不依赖 cs_rec**, 否则上一包的后窗会把下一包的前窗吃掉。
    //
    // ★ 必须带声明初值: 本 TB 第一个 clk12s 上升沿在 t=240ns, 而 ref_rstn 在 t=200ns
    //   就抬高了 → 所有 `if (!ref_rstn)` 分支**一次都不会执行**。所以全 TB 的
    //   clk12s 域状态都靠声明初值/initial 块 (如 `integer cyc = 0;`) 定初值,
    //   本记录器照此办理; 漏了初值就会整片印成 x (rec 恒 x → 一个包也记不到)。
    //========================================================================

    integer   cs_pre_idle = 0;                      // 前窗: 包起前干净空闲拍数 (锁存)
    integer   cs_pre_cur  = 0;                      // 前窗当前累计
    integer   cs_t_active = 0;                      // 因: tx_active↑ 拍号
    integer   cs_t_sync   = 0;                      // 变①: 进 S_SYNC
    integer   cs_t_data   = 0;                      // 变②: 进 S_DATA (SYNC 移完)
    integer   cs_t_eop    = 0;                      // 变③: 进 S_EOP
    integer   cs_t_done   = 0;                      // 果①: tx_done 拍
    integer   cs_t_idle   = 0;                      // 果②: 回 S_IDLE 拍
    integer   cs_t_en_lo  = 0;                      // 果③: tx_en 落 0 (交高阻) 拍
    integer   cs_stuff_n  = 0;                      // 本包插 0 (hold) 拍数
    integer   cs_post_idle= 0;                      // 后窗: tx_done 后干净空闲拍数
    reg       cs_rec        = 1'b0;                 // 本包记录中
    reg       cs_done_seen  = 1'b0;                 // 本包已见 tx_done
    reg       cs_aborted    = 1'b0;                 // 本包未发完就被撤请求 (中止路径)
    reg [2:0] cs_prev_st    = 3'd0;                 // u_tx.tx_stat_cur 上一拍
    reg       cs_act_d      = 1'b0;                 // tx_active 上一拍 (取"起包"上升沿)

    always @(posedge clk12s or negedge ref_rstn) begin
        if (!ref_rstn) begin
            cs_pre_cur  <= 0;
            cs_pre_idle <= 0;
            cs_t_active <= 0;
            cs_t_sync   <= 0;
            cs_t_data   <= 0;
            cs_t_eop    <= 0;
            cs_t_done   <= 0;
            cs_t_idle   <= 0;
            cs_t_en_lo  <= 0;
            cs_stuff_n  <= 0;
            cs_post_idle<= 0;
            cs_rec      <= 1'b0;
            cs_done_seen<= 1'b0;
            cs_aborted  <= 1'b0;
            cs_prev_st  <= 3'd0;
        end else begin
            cs_prev_st <= u_tx.tx_stat_cur;
            cs_act_d   <= tx_active;

            // --- 前窗 (与 cs_rec 无关, 每拍都算) ---
            if (!tx_active && (u_tx.tx_stat_cur == 3'd0) && rxdp && !rxdn)
                cs_pre_cur <= cs_pre_cur + 1;
            else
                cs_pre_cur <= 0;

            // --- 因: tx_active↑ → 起一包, 锁前窗、清本包观测 ---
            // ★ 起包判据必须是 **tx_active 的上升沿**, 不能写 `tx_active && !cs_rec`:
            //   上一包的记录要等 `cs_post_idle>=8` 才退, 若下一包起得早 (实测相隔
            //   3~6 拍), 起包那一刻 cs_rec 还是 1 → 判据漏掉起包拍, 于是本次
            //   IDLE→S_SYNC 这条迁移被记进**上一条记录**, 紧接着真起包时又被清零
            //   冲掉 → 日志印成 "st S_IDLE→S_SYNC @cyc 0" (2026-09-20 修)。
            if (tx_active && !cs_act_d) begin
                cs_rec       <= 1'b1;
                cs_pre_idle  <= cs_pre_cur;
                cs_t_active  <= cyc;
                cs_t_sync    <= 0;                  // 本包还没到的相位先归零,
                cs_t_data    <= 0;                  // 否则中止包会印出**上一包**的拍号
                cs_t_eop     <= 0;
                cs_t_done    <= 0;
                cs_t_idle    <= 0;
                cs_t_en_lo   <= 0;
                cs_stuff_n   <= 0;
                cs_post_idle <= 0;
                cs_done_seen <= 1'b0;
                cs_aborted   <= 1'b0;
            end

            // --- 中止 (撤请求时还没等到 tx_done): 本包没有"果", 结束记录 ---
            // 不结束的话 cs_rec 一直是 1, 下一包 (tx_active↑ 那条) 就进不来了。
            if (cs_rec && !cs_done_seen && !tx_active) begin
                cs_rec     <= 1'b0;
                cs_aborted <= 1'b1;
            end

            // --- 变: 状态迁移拍号 (6 态: 0=IDLE 1=SYNC 2=DATA 3=DATA_LAST 4=EOP1 5=EOP2) ---
            if (cs_rec && (u_tx.tx_stat_cur != cs_prev_st)) begin
                case (u_tx.tx_stat_cur)
                    3'd1:       cs_t_sync <= cyc;               // 进 SYNC 相位
                    3'd2, 3'd3: if (cs_t_data == 0)             // 进数据相位 (S_DATA 或
                                    cs_t_data <= cyc;           //  末字节态 S_DATA_LAST)
                                else cs_t_data <= cs_t_data;
                    3'd4, 3'd5: cs_t_eop  <= cyc;               // 进 EOP 相位 (SE0 拍 / J 拍)
                    default:    cs_t_sync <= cs_t_sync;
                endcase
            end

            // --- 变: 插 0 (hold) 拍数 ---
            // 新设计里"正在插 0"= `bit_stuff` 为高那一拍 (占位不推进 bit_cnt/data_shift,
            // 线上电平翻转出一个 0)。尾填充那拍在 S_EOP1 里, 同样是合法的插入 0。
            if (cs_rec && u_tx.bit_stuff)
                cs_stuff_n <= cs_stuff_n + 1;

            // --- 果 + 后窗 ---
            if (cs_rec) begin
                if (tx_done) begin
                    cs_t_done    <= cyc;
                    cs_done_seen <= 1'b1;
                end
                if (cs_done_seen) begin
                    if (u_tx.tx_stat_cur == 3'd0) begin
                        if (cs_post_idle == 0)
                            cs_t_idle <= cyc;
                        cs_post_idle <= cs_post_idle + 1;
                    end
                    // 果③: tx_en 落 0 = 驱动交高阻。tx_en 是寄存器, 清条件是 st==S_IDLE,
                    //       而 tx_done 与 st==S_IDLE 同拍 → tx_en 必晚 tx_done 一拍落。
                    if (!tx_en)
                        cs_t_en_lo <= (cs_t_en_lo == 0) ? cyc : cs_t_en_lo;
                    else
                        cs_t_en_lo <= cs_t_en_lo;
                    if (cs_post_idle >= 8)
                        cs_rec <= 1'b0;             // 记录够了就停, 等下一包
                end
            end
        end
    end

    //========================================================================
    // 辅助任务
    //========================================================================

    // ---- causal_print: 打印一条 因→变→果 + 前后窗 + 量化判据 ----
    task causal_print(input [255:0] tag);
        begin
            $display("  因果链·[%0s] 前窗: 包起前线保持 J 且 st=S_IDLE 共 %0d 拍 (干净空闲起点, 判据 >=2)",
                     tag, cs_pre_idle);
            $display("  因果链·[%0s] 因:   tx_active↑ @cyc %0d → st S_IDLE→S_SYNC @cyc %0d",
                     tag, cs_t_active, cs_t_sync);
            // 0 = 本包没走到那个相位 (中止), 印 "-" 免得跟真拍号 0 混
            if (cs_t_data == 0)
                $display("  因果链·[%0s] 变:   数据相位 (S_DATA/S_DATA_LAST) 与 EOP 相位均未到达 (本包中止在早期相位)", tag);
            else
                $display("  因果链·[%0s] 变:   st S_SYNC→S_DATA(DATA_LAST) @cyc %0d (SYNC 移完, 载首字节 + tx_ready); 数据段→S_EOP1 @cyc %0d (末字节+尾填充移完)",
                         tag, cs_t_data, cs_t_eop);
            $display("  因果链·[%0s] 变:   本包插 0 (hold) 拍数 = %0d (判据: 等于 oracle 位流里的填充 0 个数)",
                     tag, cs_stuff_n);
            if (cs_aborted)
                $display("  因果链·[%0s] 果:   中止 (tx_active↓) — 本包无 tx_done, 不进 EOP; 次拍 st→S_IDLE、NRZI 复位 J",
                         tag);
            else begin
                $display("  因果链·[%0s] 果:   tx_done @cyc %0d (EOP 的 J 拍, 与回 S_IDLE 同拍); tx_en↓ @cyc %0d → 交高阻 (tx_en 是寄存器, 条件 st==S_IDLE, 故晚 tx_done 一拍)",
                         tag, cs_t_done, cs_t_en_lo);
                $display("  因果链·[%0s] 后窗: tx_done 后线保持 J 且 st=S_IDLE 共 %0d 拍 (判据 >=4: 交高阻=电气空闲 J)",
                         tag, cs_post_idle);
            end
        end
    endtask

    // ---- build_expected: 逐位 oracle 的期望位流 (路径 B, 独立于 RTL 实现) ----
    // SYNC (0x80, LSb 先, 不参与填充计数) + 每字节 LSb 先 (满 6 连 1 插 0) + 收尾填充。
    task build_expected;
        integer i, k, ones;
        reg [7:0] b;
        begin
            exp_n = 0;
            // SYNC: 7 个 0 + 1 个 1; 计数从 PID 起算, SYNC 段不跑填充 (报告 §2.5)
            for (k = 0; k < 8; k = k + 1) begin
                exp_bits[exp_n] = (8'h80 >> k) & 1'b1;
                exp_n = exp_n + 1;
            end
            ones = 0;
            for (i = 0; i < tx_n; i = i + 1) begin
                b = tx_bytes[i];
                for (k = 0; k < 8; k = k + 1) begin
                    if (ones == 6) begin
                        exp_bits[exp_n] = 1'b0;     // 插 0
                        exp_n = exp_n + 1;
                        ones  = 0;
                    end
                    exp_bits[exp_n] = b[k];
                    exp_n = exp_n + 1;
                    if (b[k]) ones = ones + 1;
                    else      ones = 0;
                end
            end
            // 末字节收尾恰好满 6 连 1: 欠的填充 0 也要发 (报告 §4.7 缺陷回归)
            if (ones == 6) begin
                exp_bits[exp_n] = 1'b0;
                exp_n = exp_n + 1;
            end
        end
    endtask

    // ---- pkt_start: 拉高 tx_active, 从头发本包 ----
    task pkt_start;
        begin
            @(posedge clk12s);
            drv_req = 1'b1;
        end
    endtask

    // ---- pkt_abort: 发送中途撤请求 (中止, 报告 §2.6) ----
    task pkt_abort;
        begin
            @(posedge clk12s);
            drv_req = 1'b0;
        end
    endtask

    // ---- dump_bits: 位流不符时打印出错点前后各 24 位 (实际/期望对照) ----
    task dump_bits(input integer at);
        integer k, lo, hi;
        begin
            lo = (at > 12) ? at - 12 : 0;
            hi = (at + 12 < exp_n) ? at + 12 : exp_n - 1;
            $write("      位流 @%0d: 实际 ", lo);
            for (k = lo; k <= hi; k = k + 1) $write("%b", rec_bits[k]);
            $write("\n      位流 @%0d: 期望 ", lo);
            for (k = lo; k <= hi; k = k + 1) $write("%b", exp_bits[k]);
            $write("\n      发出字节: ");
            for (k = 0; k < tx_n; k = k + 1) $write("%02x ", tx_bytes[k]);
            $write("\n");
        end
    endtask

    // ---- run_pkt: 发一包 + 等收完 + 三条判据 ----
    // chk_bits=1 做逐位比对; chk_loop=1 做回环比对。
    task run_pkt(input [255:0] tag, input chk_bits, input chk_loop);
        integer f0, guard;
        // ★ 命名块 + `disable body` 而非 `disable run_pkt`: Verilator 会把
        //   "disable 自身任务名" 解析歪 —— 任务被判成 0 个端口, 于是所有
        //   run_pkt(...) 调用都报 "Too many arguments in call to task"。
        //   改成 disable 命名块后 iverilog / Verilator 行为一致。
        begin : body
            build_expected;
            f0 = rx_frames;
            pkt_start;
            // 等 tx_done (用 wait 直接等组合脉冲)
            guard = 0;
            while (!tx_done && guard < 200000) begin
                #(BIT_TIME / 4.0);
                guard = guard + 1;
            end
            if (guard >= 200000) begin
                $display("    FAIL[%0s]: 等不到 tx_done (TX 挂死)", tag);
                errors = errors + 1;
                drv_req = 1'b0;
                disable body;
            end
            @(posedge clk12s);
            @(posedge clk12s);
            drv_req = 1'b0;
            // 等回环帧关包
            guard = 0;
            while ((rx_frames == f0) && (guard < 20000)) begin
                @(posedge clk12s);
                guard = guard + 1;
            end
            if (rx_frames == f0) begin
                $display("    FAIL[%0s]: 回环未关包 (timeout)", tag);
                errors = errors + 1;
            end
            #(BIT_TIME * 4);

            // ---- 判据 1: tx_ready 脉冲数 = 字节数 ----
            if (pkt_ready_n != tx_n) begin
                $display("    FAIL[%0s]: tx_ready 脉冲 %0d 个, 应为 %0d", tag, pkt_ready_n, tx_n);
                errors = errors + 1;
            end

            // ---- 判据 2: 逐位 oracle (路径 B) ----
            if (chk_bits) begin
                if (rec_n != exp_n) begin
                    $display("    FAIL[%0s]: 位流长度 %0d, 期望 %0d", tag, rec_n, exp_n);
                    errors = errors + 1;
                end else begin : bitcmp
                    integer k, bad;
                    bad = -1;
                    for (k = 0; k < exp_n; k = k + 1)
                        if (bad < 0 && rec_bits[k] !== exp_bits[k])
                            bad = k;
                    if (bad >= 0) begin
                        $display("    FAIL[%0s]: 第 %0d 位不符 (实际 %b, 期望 %b)",
                                 tag, bad, rec_bits[bad], exp_bits[bad]);
                        errors = errors + 1;
                        dump_bits(bad);
                    end
                end
            end

            // ---- 判据 3: 端到端回环 (路径 A, 主判据) ----
            if (chk_loop) begin
                if (rx_last_nb != tx_n) begin
                    $display("    FAIL[%0s]: 回环收到 %0d 字节, 应 %0d", tag, rx_last_nb, tx_n);
                    errors = errors + 1;
                end else begin : loopcmp
                    integer k, bad;
                    bad = -1;
                    for (k = 0; k < tx_n; k = k + 1)
                        if (bad < 0 && rx_last_buf[k] !== tx_bytes[k])
                            bad = k;
                    if (bad >= 0) begin
                        $display("    FAIL[%0s]: 回环第 %0d 字节不符 (收到 %02x, 发出 %02x)",
                                 tag, bad, rx_last_buf[bad], tx_bytes[bad]);
                        errors = errors + 1;
                    end
                end
                if (rx_last_err) begin
                    $display("    FAIL[%0s]: 回环关包 rx_error=1", tag);
                    errors = errors + 1;
                end
            end

        end
    endtask

    // ---- eop_check: EOP 时长 (SE0 恰 2 拍 + J 恰 1 拍) ----
    task eop_check(input [255:0] tag);
        begin
            if (eop_se0_n != 2) begin
                $display("    FAIL[%0s]: tx_se0 高 %0d 拍, 应 2 拍", tag, eop_se0_n);
                errors = errors + 1;
            end
            if (eop_j_n != 1) begin
                $display("    FAIL[%0s]: tx_done 脉冲 %0d 拍, 应 1 拍", tag, eop_j_n);
                errors = errors + 1;
            end
        end
    endtask

    // ---- no_valid_frame: 中止后接收侧不得出现"无错帧" ----
    // 中途中止必然在线上留一个截断包, RX 会进帧再掉出 —— 这是截断包的正常收场,
    // 不是 TX 残留。TX 侧要保证的是: 新出现的帧**全部被 RX 判错** (rx_error=1);
    // 出现无错帧才说明 TX 留下了一个像样的包。
    task no_valid_frame(input [255:0] tag, input integer f0, input integer ef0);
        begin
            if (rx_frames == f0)
                ;                                       // 没进帧, 最干净
            else if (err_frames - ef0 != rx_frames - f0) begin
                $display("    FAIL[%0s]: 中止留下无错帧 (新增 %0d 帧, 其中仅 %0d 被判错, 末帧 %0d 字节)",
                         tag, rx_frames - f0, err_frames - ef0, rx_last_nb);
                errors = errors + 1;
            end else
                $display("    说明[%0s]: 截断帧 %0d 个 / 末帧 %0d 字节, RX 全部判错 → 无残留",
                         tag, rx_frames - f0, rx_last_nb);
        end
    endtask

    // ---- sync_pid_nostuff_check: SYNC+PID 段 (前 16 位) 一个填充位都不许插 ----
    // 独立于 build_expected 的直接比对: 线上前 8 位必须是 SYNC(0x80 LSb 先),
    // 紧接 8 位必须是 PID 本身。若 SYNC/PID 段插了填充位, 这里位序立刻错位报错。
    task sync_pid_nostuff_check(input [255:0] tag, input [7:0] pid);
        integer k, bad;
        begin
            bad = -1;
            if (rec_n < 16) begin
                $display("    FAIL[%0s]: SYNC/PID 段不足 16 位 (rec_n=%0d)", tag, rec_n);
                errors = errors + 1;
            end else begin
                for (k = 0; k < 8; k = k + 1)
                    if (bad < 0 && rec_bits[k] !== ((8'h80 >> k) & 1'b1))
                        bad = k;
                for (k = 0; k < 8; k = k + 1)
                    if (bad < 0 && rec_bits[8+k] !== pid[k])
                        bad = 8 + k;
                if (bad >= 0) begin
                    $display("    FAIL[%0s]: SYNC/PID 段第 %0d 位不符 (插了填充位/位序错)", tag, bad);
                    errors = errors + 1;
                end
            end
        end
    endtask

    // ---- ready_gap_check: 相邻载入间隔下界 ≥8 拍 (报告 §2.8) ----
    task ready_gap_check(input [255:0] tag);
        integer k, gap;
        begin
            for (k = 1; k < pkt_ready_n; k = k + 1) begin
                gap = ready_t[k] - ready_t[k-1];
                if (gap < 8) begin
                    $display("    FAIL[%0s]: 载入间隔 %0d 拍 < 8", tag, gap);
                    errors = errors + 1;
                end
            end
        end
    endtask

    //========================================================================
    // 激励装载辅助 (供 case 复用)
    //========================================================================

    // ---- put: 顺序填包字节 (自动推进 tx_n) ----
    task put(input [7:0] b);
        begin
            tx_bytes[tx_n] = b;
            tx_n = tx_n + 1;
        end
    endtask

    // ---- clr_pkt: 清空待发队列 ----
    task clr_pkt;
        begin
            tx_n = 0;
        end
    endtask

    //========================================================================
    // 用例
    //========================================================================

    `include "case_pid_only.v"
    `include "case_pkt_all.v"
    `include "case_len_scan.v"
    `include "case_stuff_dense.v"
    `include "case_tail_stuff.v"
    `include "case_sync_pid_nostuff.v"
    `include "case_pid_carry.v"
    `include "case_eop_timing.v"
    `include "case_back2back.v"
    `include "case_abort.v"
    `include "case_handshake.v"
    `include "case_long_loopback.v"
    `include "case_byte_sweep.v"
    `include "case_all_pid.v"
    `include "case_carry_sweep.v"
    `include "case_stuff_pos_scan.v"
    `include "case_abort_phases.v"
    `include "case_idle_between.v"
`include "case_susp_wkup.v"
`include "case_random_stress.v"

    //========================================================================
    // FSM 状态 / 迁移弧覆盖 (自建, 补 Verilator 之缺)
    //
    // ★ 为什么要自建: Verilator 的 `--coverage-fsm` **认不出本 DUT 的 FSM** ——
    //   它只识别"状态变量在组合块里被直接 case 赋值"的单段式写法, 而本模块是
    //   `code_rtl.md` 要求的**两段式** (组合算 tx_stat_nxt + 时序搬 tx_stat_cur), 且 case
    //   外面还套了一层 `if (!tx_active)` 优先分支 → 检测器直接放弃, 报告里
    //   fsm_state/fsm_arc 恒为 0/0 (实测: merged.dat 里 0 条 fsm 记录)。
    //   与其为了工具改已验收的 RTL, 不如在 TB 侧分层引用 u_tx.tx_stat_cur 自己数。
    //
    // 口径: 每个 clk12s 沿采一次 tx_stat_cur, 统计
    //   ① 各态停留拍数 (6 个 S_*); ② 相邻拍的状态迁移 (6×6 = 36 条可能弧)。
    //   复位期间不计 (复位不是"迁移", 是初值)。
    // ★ 2026-09-20: `_sy` 设计把 FSM 从 4 态扩到 6 态 (多出 S_DATA_LAST / S_EOP1 /
    //   S_EOP2, 把"末字节"和"EOP 两拍"显式化成状态), 本块随之扩到 6×6。
    //========================================================================
    localparam [2:0] F_IDLE      = 3'd0;            // 与 DUT localparam 一一对应
    localparam [2:0] F_SYNC      = 3'd1;            // (TB 侧独立再写一遍, 免得
    localparam [2:0] F_DATA      = 3'd2;            //  改了 RTL 编码 TB 却"跟着变")
    localparam [2:0] F_DATA_LAST = 3'd3;
    localparam [2:0] F_EOP1      = 3'd4;
    localparam [2:0] F_EOP2      = 3'd5;

    integer fsm_visit [0:5];                        // 各态停留拍数
    integer fsm_arc   [0:5][0:5];                   // [from][to] 迁移次数

    reg [2:0] fsm_prev  = F_IDLE;                   // 上一拍状态
    reg       fsm_armed = 1'b0;                     // 复位撤除后才开始计数

    integer i, j;                                   // 初始化/打印用

    // ★ 必须先清零再过门: integer 数组在 iverilog 里初值是 x, 而 `x + 1` 还是 x ——
    //   没走过的格子会一路保持 x (现象: 矩阵里冒 `x`, 且已经被走过的格子也因为
    //   "x+1=x" 永远算不出来)。4 态时格子少、每个用例恰好都走全才没暴露, 扩到
    //   6 态后 S_DATA 在单字节包里完全不走 → 立刻现形。
    initial begin
        for (i = 0; i < 6; i = i + 1) begin
            fsm_visit[i] = 0;
            for (j = 0; j < 6; j = j + 1)
                fsm_arc[i][j] = 0;
        end
    end

    // ---- 采样: 每个 clk12s 沿记一次状态与迁移 ----
    always @(posedge clk12s or negedge ref_rstn) begin
        if (!ref_rstn) begin
            fsm_prev  <= F_IDLE;
            fsm_armed <= 1'b0;
        end else if (!fsm_armed) begin
            fsm_prev  <= u_tx.tx_stat_cur;             // 复位后的第一拍只对齐基准
            fsm_armed <= 1'b1;
        end else begin
            fsm_visit[u_tx.tx_stat_cur] = fsm_visit[u_tx.tx_stat_cur] + 1;
            fsm_arc[fsm_prev][u_tx.tx_stat_cur] = fsm_arc[fsm_prev][u_tx.tx_stat_cur] + 1;
            fsm_prev  <= u_tx.tx_stat_cur;
        end
    end

    // ---- 打印 6×6 迁移矩阵 + 未覆盖判定 ----
    task print_fsm_coverage;
        begin
            $display("---- FSM 状态/弧覆盖 (u_tx, %0s) ----", case_name);
            $display("  停留拍数: IDLE=%0d SYNC=%0d DATA=%0d DATA_LAST=%0d EOP1=%0d EOP2=%0d",
                     fsm_visit[F_IDLE], fsm_visit[F_SYNC], fsm_visit[F_DATA],
                     fsm_visit[F_DATA_LAST], fsm_visit[F_EOP1], fsm_visit[F_EOP2]);
            $display("  迁移矩阵 (行=from 列=to, 单位: 拍):");
            $display("            to:    IDLE   SYNC   DATA   LAST   EOP1   EOP2");
            for (i = 0; i < 6; i = i + 1) begin
                $write("    from %0d:  ", i);
                for (j = 0; j < 6; j = j + 1)
                    $write("%6d ", fsm_arc[i][j]);
                $write("\n");
            end
        end
    endtask

    //========================================================================
    // 主激励
    //========================================================================

    reg [255:0] case_name;
    reg [255:0] vcd_name;
    integer     start_errs;

    initial begin
`ifdef VCD_SAVE
        if (!$value$plusargs("vcd=%s", vcd_name))
            vcd_name = "tx.vcd";
        $dumpfile(vcd_name);
        $dumpvars(0, tb_tx_serial);
        $display("INFO: VCD saved to %0s", vcd_name);
`endif

        if (!$value$plusargs("case=%s", case_name)) begin
            $display("ERROR: +case=<name> required");
            $finish(1);
        end

        // ---- 复位序列 (★ 三步顺序不可换, 见下) ----
        // 目标: 让 DUT/TB 里所有 `always @(posedge clk12m or negedge ref_rstn)` 的
        // **异步复位分支真正执行一次**。做不到的话有双重危害:
        //   ① 复位路径零覆盖 (Verilator 覆盖率会直接标出来);
        //   ② 寄存器初值只能靠仿真器默认值 —— iverilog 是 x, Verilator 是 0,
        //      两家行为会漂移 (x 参与比较恒假, 会悄悄放过错误)。
        //
        // ★ 不能简单地"按住复位等 clk12m 沿": clk12m 由本 TB 的 ref_clk 四分频器
        //   (div_cnt) 产生, 而 div_cnt 自己就被 ref_rstn 复位 → 复位期间 clk12s 恒 0,
        //   复位窗口内**一个 clk12m 沿都没有**, 等多久都白等 (这是先前的踩坑点)。
        //   正确做法是"放开 → 起振 → 拉低制造 negedge → 再放开"。
        ref_rstn = 1'b1;                            // ① 放开复位, 让四分频器起振
        repeat (4) @(posedge clk12s);               //    等 12MHz 时钟跑稳
        ref_rstn = 1'b0;                            // ② 拉低 → negedge 触发异步复位分支
        #200;                                       //    (顺带覆盖 ref_rstn 的 1→0 翻转)
        ref_rstn = 1'b1;                            // ③ 正式撤复位
        #200;

        // ---- 初始化 (★ 必须在复位序列之后: 上面 ② 的复位会把这些状态清掉) ----
        tx_active = 1'b0;
        bus_suspended  = 1'b0;
        sie_wkup  = 1'b0;
        drv_req   = 1'b0;
        drv_busy  = 1'b0;
        drv_idx   = 0;
        tx_n      = 0;
        errors    = 0;
        rx_frames = 0;

        // FSM 覆盖计数清零 (必须放在复位序列之后: 撤复位后时钟已在跑, 采样块
        // 会先记下几拍, 不在这里抹掉就会把复位后的空转算进覆盖率)
        for (i = 0; i < 4; i = i + 1) begin
            fsm_visit[i] = 0;
            for (j = 0; j < 4; j = j + 1)
                fsm_arc[i][j] = 0;
        end

        $display("==============================================");
        $display("  TX Test Case: %0s", case_name);
        $display("==============================================");

        start_errs = errors;

        case (case_name)
            "tx_pid_only":         case_pid_only;
            "tx_pkt_all":          case_pkt_all;
            "tx_len_scan":         case_len_scan;
            "tx_stuff_dense":      case_stuff_dense;
            "tx_tail_stuff":       case_tail_stuff;
            "tx_sync_pid_nostuff": case_sync_pid_nostuff;
            "tx_pid_carry":        case_pid_carry;
            "tx_eop_timing":       case_eop_timing;
            "tx_back2back":        case_back2back;
            "tx_abort":            case_abort;
            "tx_handshake":        case_handshake;
            "tx_long_loopback":    case_long_loopback;
            "tx_byte_sweep":       case_byte_sweep;
            "tx_all_pid":          case_all_pid;
            "tx_carry_sweep":      case_carry_sweep;
            "tx_stuff_pos_scan":   case_stuff_pos_scan;
            "tx_abort_phases":     case_abort_phases;
            "tx_idle_between":     case_idle_between;
            "tx_susp_wkup":        case_susp_wkup;
            "tx_random_stress":    case_random_stress;
            default: begin
                $display("ERROR: unknown case '%0s'", case_name);
                $finish(1);
            end
        endcase

        // ---- FSM 覆盖 (每 case 一份, 合并口径见 doc/design_rpt/tx_serial_verification.md §8.3) ----
        print_fsm_coverage;

        // ---- 汇总 ----
        $display("==============================================");
        if (errors == 0) begin
            $display("  TEST PASSED: usb_tx_serial (%0s)", case_name);
            $display("==============================================");
            $finish(0);
        end else begin
            $display("  TEST FAILED: usb_tx_serial (%0s) — %0d errors", case_name, errors);
            $display("==============================================");
            $finish(1);
        end
    end

endmodule
