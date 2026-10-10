//============================================================================
// tb_clk_mux.v — usb_clk_mux 无毛刺时钟切换单元测试顶层
//
// 使用方法:
//   vvp clkmux.vvp +case=mux_reset_default      # 单个 case (编译期 VCD=1 才存波形)
//
// 被测: src/phy/usb_clk_mux.v（ref_clk 域 4 态切换 FSM + ÷4 分频 + 组合 MUX）
//
// 判据分两层（这是本 TB 的核心，其它模块没有第二层）:
//   【恒定判据】逐拍比对 clk12m 与"当前状态应选的那路时钟"——三态互斥：
//       ST_RCV  → clk12m 必须 == dclk
//       ST_TX   → clk12m 必须 == clk12s
//       过渡态  → clk12m 必须 == 0
//     ★ 这条覆盖是**完备**的：clk12m 的两路来源 dclk/clk12s 边沿都对齐 ref_clk，
//       状态机也只在 ref_clk 沿变 → clk12m 在两次采样之间恒为常数，不存在藏在
//       采样点之间的 runt。故"逐拍采样 + 三态比对"等于对波形的完整刻画。
//   【量化判据 · 沿的来路】clk12m 的**每一个跳变，都必须是当拍所选时钟自己的跳变**。
//       这是"无毛刺"的严格定义：MUX 只是把三路（dclk / clk12s / 恒 0）选一路输出，
//       所以输出的沿只允许来自"被选中的那一路"。若某个沿不是所选源自己的沿
//       （典型场景：切换时把还高着的旧时钟一刀切断，输出被提前拉低），就多出一个
//       原时钟没有的沿 —— 这正是 runt，计入 glitch_cnt。
//       另统计高/低电平宽度极值与上升沿间隔，给切换开销一个可复现的数字。
//
// dclk 建模: 不用"简单 ÷4"，而是**边沿对齐 ref_clk、周期在 3/4/5 拍之间轮转**的
//   恢复时钟——这正是 DPLL 用 4× 量化把主机相位"掰"到 ref_clk 格子上后的样子。
//   只有非整除的 dclk 才能真正验证「切换只等电平、不数拍」（数拍的实现会在这里挂）。
//
// Case 文件 (通过 +case= 选择, 见 sim/clkmux/README.md):
//   mux_reset_default        — 复位默认 ST_TX：clk12m 立即可用 = clk12s
//   mux_tx2rx_glitchfree     — TX→RX 无毛刺切换
//   mux_rx2tx_glitchfree     — RX→TX 无毛刺切换
//   mux_hold_deadtime        — 过渡态"拉低缓冲"的低电平窗口宽度
//   mux_rcv_midswitch        — 切换途中 rcv 反转不中止本次迁移
//   mux_toggle_stress        — 连续反向切换 20 次，累计毛刺 = 0
//   mux_noclk_at_reset       — dclk 恒 0（DPLL 未锁）时本地时钟仍可用
//============================================================================

`timescale 1ns/1ps

module tb_clk_mux;

    // ---- USB / 时钟参数 ----
    parameter real REF_HALF = 1000.0 / 48.0 / 2.0;   // ref_clk 半周期 ≈ 10.417ns

    // ---- DUT ----
    reg        ref_clk = 1'b0;
    reg        ref_rstn = 1'b0;
    reg        dclk;                 // 由本 TB 产生（模拟 DPLL 恢复时钟）
    reg        rcv = 1'b0;
    wire       clk12m;

    usb_clk_mux u_dut (
        .ref_clk (ref_clk),
        .ref_rstn(ref_rstn),
        .dclk    (dclk),
        .rcv     (rcv),
        .clk12m  (clk12m)
    );

    always #(REF_HALF) ref_clk = ~ref_clk;

    // ---- 只读探针（本 TB 判据用；不驱动 DUT）----
    wire [1:0] st      = u_dut.stat_cur;      // DUT 现态
    wire       clk12s  = u_dut.div_cnt[1];    // DUT 内部本地时钟（= 输出 MUX 的一路）

    // TB 侧独立再写一遍状态编码（故意不复用 RTL 的 localparam：
    // 改了 RTL 编码这里不会跟着变，才能发现编码漂移）
    localparam [1:0] F_RCV   = 2'd0;
    localparam [1:0] F_HOLD1 = 2'd1;
    localparam [1:0] F_HOLD2 = 2'd2;
    localparam [1:0] F_TX    = 2'd3;

    //========================================================================
    // dclk 发生器：边沿对齐 ref_clk，周期按 3/4/5 拍轮转
    //
    // 半周期序列（单位 = ref_clk 拍）: 2,1 → 周期 3；2,2 → 周期 4；3,2 → 周期 5；2,2 → 周期 4
    // 平均 4 拍 = 12MHz，但单周期在 ±25% 内摆动 —— 与 DPLL 的量化粒度一致。
    // dclk_en=0 时 dclk 恒 0（模拟"DPLL 未锁、无恢复时钟"）。
    //========================================================================
    reg [3:0] dclk_hp_seq [0:7];
    reg [2:0] dclk_idx;
    reg [3:0] dclk_cnt;
    reg       dclk_en = 1'b0;

    initial begin
        dclk_hp_seq[0] = 4'd2;  dclk_hp_seq[1] = 4'd1;   // 周期 3 拍（偏快）
        dclk_hp_seq[2] = 4'd2;  dclk_hp_seq[3] = 4'd2;   // 周期 4 拍（标称）
        dclk_hp_seq[4] = 4'd3;  dclk_hp_seq[5] = 4'd2;   // 周期 5 拍（偏慢）
        dclk_hp_seq[6] = 4'd2;  dclk_hp_seq[7] = 4'd2;   // 周期 4 拍（标称）
    end

    always @(posedge ref_clk) begin
        if (!dclk_en) begin
            dclk     <= 1'b0;
            dclk_cnt <= 4'd0;
            dclk_idx <= 3'd0;
        end
        else if (dclk_cnt + 4'd1 >= dclk_hp_seq[dclk_idx]) begin
            dclk     <= ~dclk;
            dclk_cnt <= 4'd0;
            dclk_idx <= dclk_idx + 3'd1;
        end
        else begin
            dclk_cnt <= dclk_cnt + 4'd1;
        end
    end

    //========================================================================
    // 逐拍采样与统计
    //
    // ★ 在 ref_clk 上升沿后 1ns 采样：DUT 与本 TB 的 dclk/div_cnt 都用非阻塞赋值
    //   在 posedge ref_clk 更新，1ns 后本拍新值已就位、离下一拍（≈10.4ns）还远，
    //   既不与 DUT 抢同一个时刻，也不落进下一次更新。
    //========================================================================
    integer tick;                  // 采样拍序号（仅在复位撤销后累加）
    reg     clk12m_d;              // 上一拍的 clk12m 采样值（边沿检测用）
    reg     clk12s_d, dclk_d;      // 上一拍两路源时钟的电平（判"沿的来路"用）
    reg [1:0] src, src_d;          // 本拍/上拍 clk12m 的来源: 0=dclk 1=clk12s 2=恒 0
    integer last_rise;             // 上一个上升沿所在拍号，-1 = 还没见过
    integer period;                // 本次上升沿距上一个上升沿的拍数
    integer min_period, max_period;
    integer clk12m_edges;          // 窗口内上升沿计数
    integer glitch_cnt;            // ★ 主判据: 来路不正的输出沿数（= spur_rise + spur_fall）
    integer spur_rise, spur_fall;  // 细分之一：多出来的上升沿 / 下降沿
    integer fast_cnt;              // 附判据: 上升沿间隔 < 3 拍的次数（干净设计下应恒 0）
    integer high_run, low_run;     // 当前连续高 / 低拍数
    integer min_high, max_high;    // 高电平宽度极值（拍）
    integer min_low, max_low;      // 低电平宽度极值（拍）
    reg     seg_first;             // 窗口首段"跨边界、只有半截"，其结算值不进极值
    integer err_rcv;               // ST_RCV 下 clk12m != dclk 的拍数
    integer err_tx;                // ST_TX  下 clk12m != clk12s 的拍数
    integer err_hold;              // 过渡态下 clk12m != 0 的拍数

    // ---- 单次"低电平窗口"测量（case_hold_deadtime 用）----
    // 用途：量"过渡态拉低缓冲"到底把低电平拉长了多少拍。
    // 用法：发起切换前置 arm=1，下一个 clk12m 上升沿就把这之前的连续低拍数记进 result。
    reg     low_arm  = 1'b0;
    integer low_result;

    // FSM 覆盖（Verilator 认不出两段式 FSM，故由 TB 数；见 tools/merge_fsm_cov.py）
    integer   fsm_visit [0:3];
    integer   fsm_arc   [0:3][0:3];
    reg [1:0] fsm_prev;
    reg       fsm_first = 1'b1;

    task fsm_clear;
        integer a, b;
        begin
            for (a = 0; a < 4; a = a + 1) begin
                fsm_visit[a] = 0;
                for (b = 0; b < 4; b = b + 1) fsm_arc[a][b] = 0;
            end
            fsm_first = 1'b1;
        end
    endtask

    // 窗口统计清零（每个 case 在自己的"前文窗口"开始前调用一次）
    //   ★ clk12m_d/两路时钟/来源都以**当前值**打底，不是清 0：窗口起点不落在时钟沿上，
    //     若把 clk12m_d 清 0，而此刻 clk12m 恰为高，就会凭空造出一个"上升沿"，
    //     再减去真实沿 → 虚假的 3 拍周期（改造前 mux_reset_default 报 3..4 就是这个）。
    task win_clear;
        begin
            tick = 0; last_rise = -1; period = 0;
            min_period = 9999; max_period = 0; clk12m_edges = 0;
            glitch_cnt = 0; spur_rise = 0; spur_fall = 0; fast_cnt = 0;
            high_run = 0; low_run = 0;
            min_high = 9999; max_high = 0; min_low = 9999; max_low = 0;
            seg_first = 1'b1;
            err_rcv = 0; err_tx = 0; err_hold = 0;
            low_arm = 1'b0; low_result = -1;
            clk12m_d = clk12m; clk12s_d = clk12s; dclk_d = dclk;
            src_d = src;
        end
    endtask

    always @(posedge ref_clk) begin
        #1;
        if (ref_rstn) begin
            tick = tick + 1;

            // ---- ① 恒定判据（三态互斥，逐拍完备）----
            if      (st == F_RCV) begin src = 2'd0; if (clk12m !== dclk)   err_rcv  = err_rcv  + 1; end
            else if (st == F_TX ) begin src = 2'd1; if (clk12m !== clk12s) err_tx   = err_tx   + 1; end
            else                  begin src = 2'd2; if (clk12m !== 1'b0)   err_hold = err_hold + 1; end

            // ---- ② 主判据: 输出的每个沿都必须是"当拍所选源"自己的沿 ----
            //   上升沿: 新选的源自己在本拍由 0→1（连上时它必须已是 0，故只能是它自己升）
            //   下降沿: 上拍选中的源自己在本拍由 1→0（切离时若旧源还高，这次下降就是多出来的）
            if (clk12m && !clk12m_d) begin
                if (!((src   == 2'd0 &&  dclk && !dclk_d) ||
                      (src   == 2'd1 && clk12s && !clk12s_d))) begin
                    spur_rise  = spur_rise  + 1;
                    glitch_cnt = glitch_cnt + 1;
                end
            end
            else if (!clk12m && clk12m_d) begin
                if (!((src_d == 2'd0 && !dclk &&  dclk_d) ||
                      (src_d == 2'd1 && !clk12s && clk12s_d))) begin
                    spur_fall  = spur_fall  + 1;
                    glitch_cnt = glitch_cnt + 1;
                end
            end

            // ---- ③ 边沿 / 宽度统计 ----
            if (clk12m && !clk12m_d) begin
                clk12m_edges = clk12m_edges + 1;
                if (last_rise >= 0) begin
                    period = tick - last_rise;
                    if (period < min_period) min_period = period;
                    if (period > max_period) max_period = period;
                    if (period < 3) fast_cnt = fast_cnt + 1;   // 干净设计下最短间隔 >= 3 拍
                end
                last_rise = tick;
                // ★ low_run 此刻仍等于"本上升沿之前连续低了几拍"——正是要量的低电平窗口
                if (low_arm) begin
                    low_result = low_run;
                    low_arm    = 1'b0;
                end
                // 本上升沿结束了一段低电平：首段跨窗口边界（只有半截）不参与极值
                if (seg_first) seg_first = 1'b0;
                else if (low_run < min_low) min_low = low_run;
            end
            else if (!clk12m && clk12m_d) begin
                // 本下降沿结束了一段高电平：同上，首段丢弃
                if (seg_first) seg_first = 1'b0;
                else if (high_run < min_high) min_high = high_run;
            end
            if (clk12m) begin high_run = high_run + 1; low_run  = 0; end
            else        begin low_run  = low_run  + 1; high_run = 0; end
            if (high_run > max_high) max_high = high_run;
            if (low_run  > max_low ) max_low  = low_run;
            clk12m_d = clk12m; clk12s_d = clk12s; dclk_d = dclk; src_d = src;

            // ---- ③ FSM 状态 / 弧 ----
            if (fsm_first) begin
                fsm_first = 1'b0;
                fsm_prev  = st;                 // 复位后第一拍只对齐基准
            end
            else begin
                fsm_visit[st] = fsm_visit[st] + 1;
                fsm_arc[fsm_prev][st] = fsm_arc[fsm_prev][st] + 1;
                fsm_prev = st;
            end
        end
    end

    //========================================================================
    // 辅助任务
    //========================================================================
    // 等 n 个 ref_clk 上升沿
    task ref_ticks;
        input integer n;
        integer k;
        begin
            for (k = 0; k < n; k = k + 1) @(posedge ref_clk);
        end
    endtask

    // 等 FSM 到达指定态（带超时，避免挂死）
    task wait_state;
        input [1:0]   want;
        input integer tmo;
        integer k;
        begin
            k = 0;
            while ((st !== want) && (k < tmo)) begin
                @(posedge ref_clk);
                k = k + 1;
            end
            if (st !== want) begin
                $display("    FAIL: 等状态 %0d 超时 (现态 %0d, 已等 %0d 拍)", want, st, k);
                errors = errors + 1;
            end
        end
    endtask

    //========================================================================
    // FSM 状态/弧覆盖打印（格式须与 tools/merge_fsm_cov.py 的 profile 对齐）
    //========================================================================
    task print_fsm_coverage;
        integer i, j;
        begin
            $display("---- FSM 状态/弧覆盖 (u_dut, %0s) ----", case_name);
            $display("  停留拍数: RCV=%0d HOLD1=%0d HOLD2=%0d TX=%0d",
                     fsm_visit[F_RCV], fsm_visit[F_HOLD1], fsm_visit[F_HOLD2], fsm_visit[F_TX]);
            $display("  迁移矩阵 (行=from 列=to, 单位: 拍):");
            $display("            to:     RCV  HOLD1  HOLD2     TX");
            for (i = 0; i < 4; i = i + 1) begin
                $write("    from %0d:  ", i);
                for (j = 0; j < 4; j = j + 1)
                    $write("%6d ", fsm_arc[i][j]);
                $write("\n");
            end
        end
    endtask

    //========================================================================
    // 自检状态
    //========================================================================
    integer errors = 0;                 // 全局错误计数（pass/fail 唯一依据）
    integer errs_before;                // 本 case 起点（用于分 case 报错数）

    reg [255:0] case_name;
    reg [255:0] vcd_name;

    //========================================================================
    // 主激励
    //========================================================================
    initial begin
`ifdef VCD_SAVE
        if (!$value$plusargs("vcd=%s", vcd_name))
            vcd_name = "clkmux.vcd";
        $dumpfile(vcd_name);
        $dumpvars(0, tb_clk_mux);
        $display("INFO: VCD saved to %0s", vcd_name);
`endif

        if (!$value$plusargs("case=%s", case_name)) begin
            $display("ERROR: +case=<name> required");
            $finish(1);
        end

        // ---- 复位序列 ----
        // 目标：让 DUT 的 `always @(posedge ref_clk or negedge ref_rstn)` 的**异步
        // 复位分支真正执行一次**（否则复位路径零覆盖，且寄存器初值只能靠仿真器默认值
        // —— iverilog 是 x、Verilator 是 0，两家会漂移）。
        // 做法：先放开让 ref_clk/div_cnt 跑起来，再拉低制造 negedge，最后正式撤复位。
        ref_rstn = 1'b1;
        repeat (8) @(posedge ref_clk);
        ref_rstn = 1'b0;                    // ① 制造 ref_rstn 的 1→0 翻转
        #200;
        ref_rstn = 1'b1;                    // ② 正式撤复位
        #200;

        $display("==============================================");
        $display("  clk_mux Test Case: %0s", case_name);
        $display("==============================================");

        win_clear;
        fsm_clear;

        case (case_name)
            "mux_reset_default":     case_reset_default;
            "mux_tx2rx_glitchfree":  case_tx2rx_glitchfree;
            "mux_rx2tx_glitchfree":  case_rx2tx_glitchfree;
            "mux_hold_deadtime":     case_hold_deadtime;
            "mux_rcv_midswitch":     case_rcv_midswitch;
            "mux_toggle_stress":     case_toggle_stress;
            "mux_noclk_at_reset":    case_noclk_at_reset;
            default: begin
                $display("ERROR: unknown case '%0s'", case_name);
                $finish(1);
            end
        endcase

        print_fsm_coverage;

        // ---- 汇总 ----
        $display("==============================================");
        if (errors == 0) begin
            $display("  TEST PASSED: usb_clk_mux (%0s)", case_name);
            $display("==============================================");
            $finish(0);
        end else begin
            $display("  TEST FAILED: usb_clk_mux (%0s) — %0d errors", case_name, errors);
            $display("==============================================");
            $finish(1);
        end
    end

    // ---- 各 case（每个用例一个文件，与 sim/cdr、sim/deserial 同构）----
    `include "case_mux_reset_default.v"
    `include "case_mux_tx2rx_glitchfree.v"
    `include "case_mux_rx2tx_glitchfree.v"
    `include "case_mux_hold_deadtime.v"
    `include "case_mux_rcv_midswitch.v"
    `include "case_mux_toggle_stress.v"
    `include "case_mux_noclk_at_reset.v"

endmodule
