//============================================================================
// tb_phy.v — usb_dpll_phy 顶层集成测试顶层
//
// 被测: src/phy/usb_dpll_phy.v —— PHY 五个子模块的唯一边界。
// 本 TB 只实例化**这一个**顶层，五个子模块一律不直连（单元测试各自另有 TB）。
//
// 验的是**接线**，不是子模块内部行为（那些已在 sim/cdr / deserial / tx / clkmux /
// busstate 逐个验过）。接线错了才会挂的几条:
//   ① line_s 只在 deserial 里采一次、bus_state 直接吃 → 线一动就能判出事件（phy_connect）
//   ② tx_en 组合直连 bus_state 当 driving → 设备自己驱的 K/SE0 不报事件（phy_tx_driving）
//   ③ rcv 进 clk_mux、clk12m 出给全层 → 接收期 clk12m=dclk、发送期=clk12s（phy_clk_switch）
//   ④ usb_rst 同送 deserial + bus_state，usb_bus_rst 出到本层并在**此处**并成 usb_rst
//      （PHY 自己不并，见 phy_design.md §3）→ 总线复位清附着、插回重报（phy_bus_rst）
//
// 总线模型（本 TB 的核心部件）:
//   rxdp/rxdn 是 reg，由 usb_pkt_tasks.vh 的 drive_dpdn 直接写 —— 那是**主机侧**
//   电平；DUT 看到的是 bus_dp/bus_dn: tx_en=1（设备在驱）时取设备的 tx_bit/tx_se0，
//   否则取主机侧电平。USB 半双工下两者不会同时驱，故不需要真的做仲裁。
//   空闲 J 由主机侧显式给出（drive_dpdn(1)），与真实设备靠 1.5k 上拉得到的 J 等价。
//
// SIE 侧模型（TB 扮演）:
//   tx_active/tx_data/tx_last/sie_wkup/rx_abort/swrst 由本 TB 驱动；
//   rcv 按 usb_sie_design.md §1.3 的策略现算: rcv = attached & ~driving，
//     driving = tx_active | (sie_susp & sie_wkup)，attached 由 connect_evt 置、usb_rst 清。
//   ★ sie_susp 是 TB 里 SIE 自己那份挂起标志，**只**用来算 rcv：DUT 的唤醒旁路
//     读的是它自己 bus_state 判出的 bus_suspended，不读这里（xiao_yuan 2026-09-29 定）。
//     两者可以不一致：case_clk_switch 就是硬掰 sie_susp 来回切 rcv 的。
//
// ★ 一条实测到的 CDR 行为，全部用例的时序都建立在它上面:
//   CDR 是**自由运转**的 DPLL —— 只要线上出现过一次跳变，dclk 就一直跑 12MHz
//   （实测：单次 SE0→J 后静态 J 100µs 得 1200 个 dclk 沿）。
//   全程无跳变的冷线则 dclk 停摆（DPLL 停在锁存态），此时 rcv 必须为 0，
//   否则 clk12m = dclk = 0，整层时钟停摆。故本 TB 一律从"冷 SE0（未插）"起步。
//
// 用法: vvp phy.vvp +case=<name>   （编译期 VCD=1 才存波形）
//============================================================================

`timescale 1ns/1ps

module tb_phy;

    // ---- USB 时间参数 (usb_pkt_tasks.vh 依赖) ----
    parameter real BIT_TIME     = 1000.0 / 12.0;        // 83.333ns
    parameter real EOP_SE0_TIME = 2.0 * BIT_TIME;
    parameter real EOP_J_TIME   = 1.0 * BIT_TIME;

    // ---- 48MHz ref_clk ----
    parameter real CLK_HALF = 1000.0 / 48.0 / 2.0;
    reg ref_clk = 1'b0;
    reg ref_rstn = 1'b0;
    always #(CLK_HALF) ref_clk = ~ref_clk;

    //========================================================================
    // 总线模型
    //========================================================================
    reg  rxdp = 1'b0;                      // 主机侧 D+（drive_dpdn 直接写这两个）
    reg  rxdn = 1'b0;                      // 初值 SE0 = 电缆没插

    wire tx_bit, tx_se0, tx_en, clk12m;
    wire bus_dp = tx_en ? (tx_se0 ? 1'b0 :  tx_bit) : rxdp;
    wire bus_dn = tx_en ? (tx_se0 ? 1'b0 : ~tx_bit) : rxdn;

    //========================================================================
    // SIE 侧激励 (TB 扮 SIE)
    //========================================================================
    reg        tx_active = 1'b0;
    reg        rx_abort  = 1'b0;
    reg        sie_susp  = 1'b0;           // SIE 侧模型的挂起标志，只喂 rcv（DUT 不收，见文件头）
    reg        sie_wkup  = 1'b0;
    reg        swrst     = 1'b0;           // 软复位脉冲（TB 扮 APB control）
    wire [7:0] tx_data;                    // 组合译出，见下
    wire       tx_last;

    // ---- 上层并流: core 复位 = 总线复位 ∪ 软复位（PHY 不并，在此并） ----
    wire usb_bus_rst;
    wire usb_rst = usb_bus_rst | swrst;

    // ---- rcv 策略: attached & ~driving（usb_sie_design.md §1.3） ----
    reg  sie_attached = 1'b0;
    wire sie_driving  = tx_active | (sie_susp & sie_wkup);
    wire rcv          = sie_attached & (~sie_driving);

    //========================================================================
    // DUT — 只有这一个实例
    //========================================================================
    wire [7:0] rx_data;
    wire       rx_valid, rx_active, rx_error;
    wire [1:0] line_state;
    wire       tx_ready, tx_done;
    wire       connect_evt, suspend_evt, resume_evt;

    usb_dpll_phy u_dut (
        .ref_clk    (ref_clk),
        .ref_rstn   (ref_rstn),
        .usb_rst    (usb_rst),
        .rxdp       (bus_dp),
        .rxdn       (bus_dn),
        .rcv        (rcv),
        .tx_active  (tx_active),
        .rx_abort   (rx_abort),
        .tx_data    (tx_data[7:0]),
        .tx_last    (tx_last),
        .sie_wkup   (sie_wkup),
        .clk12m     (clk12m),
        .rx_data    (rx_data[7:0]),
        .rx_valid   (rx_valid),
        .rx_active  (rx_active),
        .rx_error   (rx_error),
        .line_state (line_state[1:0]),
        .tx_ready   (tx_ready),
        .tx_done    (tx_done),
        .connect_evt(connect_evt),
        .usb_bus_rst(usb_bus_rst),
        .suspend_evt(suspend_evt),
        .resume_evt (resume_evt),
        .tx_bit     (tx_bit),
        .tx_se0     (tx_se0),
        .tx_en      (tx_en));

    // ---- attached: connect_evt 置、usb_rst 清 ----
    always @(posedge clk12m or negedge ref_rstn) begin
        if (!ref_rstn)          sie_attached <= 1'b0;
        else if (usb_rst)       sie_attached <= 1'b0;
        else if (connect_evt)   sie_attached <= 1'b1;
    end

    //========================================================================
    // 自检状态
    //========================================================================
    integer errors    = 0;
    integer mon_arm   = 0;                 // 复位序列跑完才开账，避免把上电沿算进来

    // ---- 四个事件: 个数 (ref 域计数) + 最宽 (clk12m 拍) ----
    integer n_evt  [0:3];                  // 0=connect 1=bus_rst 2=suspend 3=resume
    integer w_evt  [0:3];                  // 最宽拍数，必须 = 1
    integer w_cur  [0:3];
    reg  [3:0] evt_d = 4'd0;
    wire [3:0] evt_bus = {resume_evt, suspend_evt, usb_bus_rst, connect_evt};

    // ---- clk12m 相位宽度 (ref 拍): 查切换无毛刺 ----
    integer clk_hi_w, clk_lo_w;            // 当前相位的 ref 拍数
    integer clk_hi_min, clk_lo_min;        // 全程最小（0 = 还没测到）
    reg     clk12m_d = 1'b0;

    // ---- line_state 透传检查 ----
    integer ns_bad = 0;

    // ---- EOP 波形: tx_se0 连续高电平的 ref 拍数（理论 2 bit = 8 拍） ----
    integer se0_run = 0, se0_run_max = 0;

    // ---- 时钟统计: clk12m 沿数 / dclk 沿数（冷线停摆就是靠这两个查出 0） ----
    integer n_clk12m_rise = 0;
    integer n_clk12m_fall = 0;
    integer n_dclk_rise   = 0;
    reg     dclk_d        = 1'b0;
    integer n_ref_rise    = 0;

    // ---- rcv 换向计数（ref 域采样）: 半双工往返用例查"收发各换一次向" ----
    integer n_rcv_rise    = 0;             // 0 -> 1: 交回接收，clk12m 换回 dclk
    integer n_rcv_fall    = 0;             // 1 -> 0: 开始发送，clk12m 换到 clk12s
    reg     rcv_d         = 1'b0;

    always @(posedge clk12m or negedge ref_rstn) begin
        if (!ref_rstn) n_clk12m_rise <= 0;
        else           n_clk12m_rise <= n_clk12m_rise + 1;
    end

    always @(negedge clk12m or negedge ref_rstn) begin
        if (!ref_rstn) n_clk12m_fall <= 0;
        else           n_clk12m_fall <= n_clk12m_fall + 1;
    end

    // ---- 发送侧 (SIE 模型, 抄 sim/tx 的已验收写法) ----
    integer   tx_n    = 0;
    reg [7:0] tx_bytes[0:63];
    reg       tx_req  = 1'b0;
    reg       tx_busy = 1'b0;
    integer   tx_idx  = 0;
    reg       last_taken = 1'b0;
    integer   n_tx_ready = 0;
    integer   n_tx_done  = 0;

    always @(posedge clk12m or negedge ref_rstn) begin
        if (!ref_rstn) begin
            n_tx_ready <= 0;
            n_tx_done  <= 0;
        end else begin
            if (tx_ready) n_tx_ready <= n_tx_ready + 1;
            if (tx_done)  n_tx_done  <= n_tx_done  + 1;
        end
    end

    always @(posedge clk12m or negedge ref_rstn) begin
        if (!ref_rstn) begin
            tx_active <= 1'b0;
            tx_busy   <= 1'b0;
        end else if (!tx_req) begin
            tx_active <= 1'b0;
            tx_busy   <= 1'b0;
        end else if (tx_busy) begin
            tx_active <= 1'b0;
            tx_busy   <= 1'b1;
        end else if (tx_done) begin
            tx_active <= 1'b0;
            tx_busy   <= 1'b1;
        end else begin
            tx_active <= 1'b1;
            tx_busy   <= 1'b0;
        end
    end

    always @(posedge clk12m or negedge ref_rstn) begin
        if (!ref_rstn)
            tx_idx <= 0;
        else if (!tx_active)
            tx_idx <= 0;
        else if (tx_ready) begin
            if (tx_idx < tx_n - 1) tx_idx <= tx_idx + 1;
            else                   tx_idx <= tx_idx;
        end
    end

    always @(posedge clk12m or negedge ref_rstn) begin
        if (!ref_rstn)
            last_taken <= 1'b0;
        else if (!tx_active)
            last_taken <= 1'b0;
        else if (tx_ready && (tx_idx == (tx_n - 1)))
            last_taken <= 1'b1;
    end

    // 连续赋值: 同一时刻改 tx_n 与读 tx_data 时, 显式敏感表的 always 在 Verilator
    // 下会停在旧值（sim/tx 踩过这个坑），连续赋值两家语义一致。
    assign tx_data = (tx_idx < tx_n) ? tx_bytes[tx_idx] : 8'h00;
    assign tx_last = (tx_n > 0) && (tx_idx == (tx_n - 1)) && tx_active && (~last_taken);

    //========================================================================
    // 接收侧监视 (clk12m 域)
    //========================================================================
    // 逐帧留档: 一个用例最多举证 4 帧, 按 frame_cnt-1 直接索引。
    // ★ 只留"最后一帧"不够 —— 连发 token+DATA0 时两帧在用例去查之前就都关完了，
    //   单变量会被后一帧覆盖（本 TB 首版踩过）。
    integer   frame_cnt  = 0;              // 累计关包帧数
    integer   fb_n       = 0;              // 当前帧字节数
    localparam FB_DEPTH = 128;             // fb / hist_b 的字节深度
    reg [7:0] fb [0:FB_DEPTH-1];           // 当前帧字节
    reg       in_frame_d = 1'b0;
    integer   n_rx_active_rise = 0;
    reg       act_d = 1'b0;
    integer   hist_n    [0:3];             // 第 i 帧字节数
    integer   hist_err  [0:3];             // 第 i 帧关包时的 rx_error
    reg [7:0] hist_b    [0:3][0:127];      // 第 i 帧字节（满长包 67B 也要留全，见 hist_copy_max）
    integer   hist_wr    = 0;
    integer   k;

    always @(posedge clk12m or negedge ref_rstn) begin
        if (!ref_rstn) begin
            in_frame_d <= 1'b0;
            act_d      <= 1'b0;
        end else begin
            if (!act_d && rx_active) n_rx_active_rise = n_rx_active_rise + 1;
            act_d <= rx_active;

            if (!in_frame_d && rx_active) fb_n = 0;
            if (in_frame_d && !rx_active) begin
                $display("     [t=%0t] rx_active period %0d closed: %0d bytes, err=%0b",
                         $time, frame_cnt, fb_n, rx_error);
                hist_err[hist_wr] = rx_error;
                hist_n[hist_wr]   = fb_n;
                for (k = 0; k < fb_n && k < FB_DEPTH; k = k + 1)
                    hist_b[hist_wr][k] = fb[k];
                hist_wr   = (hist_wr + 1) & 3;
                frame_cnt = frame_cnt + 1;
            end
            in_frame_d <= rx_active;
            if (rx_valid) begin
                if (fb_n < FB_DEPTH) fb[fb_n] = rx_data;
                fb_n     = fb_n + 1;
            end
        end
    end

    //========================================================================
    // ref_clk 域监视（+1ns: DUT 与本 TB 都用非阻塞同沿更新，1ns 后本拍值已就位）
    //========================================================================
    always @(posedge ref_clk) begin
        #1;
        if (mon_arm) begin
            // --- 四个事件: 数个数 + 量最宽 (clk12m 拍由下一个块数, 这里只数个数) ---
            for (k = 0; k < 4; k = k + 1)
                if (evt_bus[k] && !evt_d[k]) begin
                    n_evt[k] = n_evt[k] + 1;
                    $display("     [t=%0t] event %0d  line_s=%b  rcv=%b tx_en=%b",
                             $time, k, line_state, rcv, tx_en);
                end
            evt_d = evt_bus;

            // --- line_state 透传: 任何一拍都该等于线上电平 ---
            if (line_state !== {bus_dp, bus_dn}) ns_bad = ns_bad + 1;

            // --- EOP: tx_se0 连续高电平最长几拍 (clk12s = ref/4, 1 bit = 4 拍) ---
            if (tx_se0) begin
                se0_run = se0_run + 1;
                if (se0_run > se0_run_max) se0_run_max = se0_run;
            end else se0_run = 0;

            // --- 时钟: dclk 沿数 (冷线应恒 0) / ref 沿数 ---
            n_ref_rise = n_ref_rise + 1;
            if (u_dut.dclk && !dclk_d) n_dclk_rise = n_dclk_rise + 1;
            dclk_d = u_dut.dclk;

            // --- rcv 换向: 收发各一次 = 0/1 各一个沿 ---
            if (rcv && !rcv_d) n_rcv_rise = n_rcv_rise + 1;
            if (!rcv && rcv_d) n_rcv_fall = n_rcv_fall + 1;
            rcv_d = rcv;

            // --- clk12m 相位宽度 (ref 拍) ---
            if (clk12m !== clk12m_d) begin
                if (clk12m_d) begin                       // 刚结束一个高相位
                    if (clk_hi_w > 0 && (clk_hi_min == 0 || clk_hi_w < clk_hi_min))
                        clk_hi_min = clk_hi_w;
                end else begin                            // 刚结束一个低相位
                    if (clk_lo_w > 0 && (clk_lo_min == 0 || clk_lo_w < clk_lo_min))
                        clk_lo_min = clk_lo_w;
                end
                clk_hi_w  = 0;
                clk_lo_w  = 0;
            end
            if (clk12m) clk_hi_w = clk_hi_w + 1;
            else        clk_lo_w = clk_lo_w + 1;
            clk12m_d = clk12m;
        end
    end

    // ---- 事件脉冲宽度 (clk12m 拍): 恒为 1 ----
    reg [3:0] evtq_d = 4'd0;
    always @(posedge clk12m or negedge ref_rstn) begin
        if (!ref_rstn) begin
            evtq_d <= 4'd0;
        end else begin
            for (k = 0; k < 4; k = k + 1) begin
                if (evt_bus[k]) begin
                    w_cur[k] = w_cur[k] + 1;
                    if (w_cur[k] > w_evt[k]) w_evt[k] = w_cur[k];
                end else w_cur[k] = 0;
            end
            evtq_d <= evt_bus;
        end
    end

    //========================================================================
    // 公共任务
    //========================================================================
    `include "usb_pkt_tasks.vh"
    `include "phy_tasks.vh"

    //========================================================================
    // 用例
    //========================================================================
    `include "case_reset_default.v"
    `include "case_connect.v"
    `include "case_suspend.v"
    `include "case_resume.v"
    `include "case_bus_rst.v"
    `include "case_rx_token.v"
    `include "case_rx_data.v"
    `include "case_rx_bad.v"
    `include "case_rx_abort.v"
    `include "case_rx_usb_rst.v"
    `include "case_rx_hshake.v"
    `include "case_rx_maxlen.v"
    `include "case_tx_line.v"
    `include "case_tx_driving.v"
    `include "case_tx_rx_turn.v"
    `include "case_susp_wkup.v"
    `include "case_unplug_susp.v"
    `include "case_clk_switch.v"

    //========================================================================
    // 主激励
    //========================================================================
    reg [255:0] case_name;
    reg [255:0] vcd_name;
    integer     start_errs;

    initial begin
`ifdef VCD_SAVE
        if (!$value$plusargs("vcd=%s", vcd_name))
            vcd_name = "phy.vcd";
        $dumpfile(vcd_name);
        $dumpvars(0, tb_phy);
        $display("INFO: VCD saved to %0s", vcd_name);
`endif

        if (!$value$plusargs("case=%s", case_name)) begin
            $display("ERROR: +case=<name> required");
            $finish(1);
        end

        // ---- 复位序列 (三步顺序与 sim/tx 同: 释放 → 起振 → 拉低制造 negedge → 撤) ----
        // ★ 不能"按住复位等 clk12m 沿": clk12m 由 DUT 的 clk_mux 出，复位期 stat_cur=ST_TX、
        //   div_cnt=0 → clk12m 恒 0，复位窗口里一个沿都没有。故按 ref_clk 计步。
        ref_rstn = 1'b1;
        repeat (8) @(posedge ref_clk);
        ref_rstn = 1'b0;
        #200;
        ref_rstn = 1'b1;
        #200;

        // ---- 初始化 (必须在复位序列之后) ----
        rxdp = 1'b0; rxdn = 1'b0;              // 冷 SE0: 未插
        nrzi_lv  = 1'b1;                       // usb_pkt_tasks 的全局状态
        ones_cnt = 0;
        record_en = 0;
        errors   = 0;
        n_rx_active_rise = 0;
        frame_cnt = 0;
        ns_bad    = 0;
        se0_run = 0; se0_run_max = 0;
        n_clk12m_rise = 0; n_clk12m_fall = 0; n_dclk_rise = 0; n_ref_rise = 0;
        dclk_d = 1'b0;
        n_rcv_rise = 0; n_rcv_fall = 0; rcv_d = 1'b0;
        n_tx_ready = 0; n_tx_done = 0;
        tx_n = 0; tx_req = 0; tx_busy = 0; tx_idx = 0; last_taken = 0;
        rx_abort = 0; sie_susp = 0; sie_wkup = 0; swrst = 0;
        clk_hi_min = 0; clk_lo_min = 0;
        clk_hi_w = 0; clk_lo_w = 0; clk12m_d = clk12m;
        for (k = 0; k < 4; k = k + 1) begin
            n_evt[k] = 0; w_evt[k] = 0; w_cur[k] = 0;
        end
        mon_arm = 1;

        $display("==============================================");
        $display("  PHY Test Case: %0s", case_name);
        $display("==============================================");

        start_errs = errors;

        case (case_name)
            "phy_reset_default": case_reset_default;
            "phy_connect":       case_connect;
            "phy_suspend":       case_suspend;
            "phy_resume":        case_resume;
            "phy_bus_rst":       case_bus_rst;
            "phy_rx_token":      case_rx_token;
            "phy_rx_data":       case_rx_data;
            "phy_rx_bad":        case_rx_bad;
            "phy_rx_abort":      case_rx_abort;
            "phy_rx_usb_rst":    case_rx_usb_rst;
            "phy_rx_hshake":     case_rx_hshake;
            "phy_rx_maxlen":     case_rx_maxlen;
            "phy_tx_line":       case_tx_line;
            "phy_tx_driving":    case_tx_driving;
            "phy_tx_rx_turn":    case_tx_rx_turn;
            "phy_susp_wkup":     case_susp_wkup;
            "phy_unplug_susp":   case_unplug_susp;
            "phy_clk_switch":    case_clk_switch;
            default: begin
                $display("ERROR: unknown case '%0s'", case_name);
                $finish(1);
            end
        endcase

        print_evt_summary;

        $display("==============================================");
        if (errors == 0) begin
            $display("  TEST PASSED: usb_dpll_phy (%0s)", case_name);
            $display("==============================================");
            $finish(0);
        end else begin
            $display("  TEST FAILED: usb_dpll_phy (%0s) — %0d errors", case_name, errors);
            $display("==============================================");
            $finish(1);
        end
    end

endmodule
