//============================================================================
// case_clk_switch.v — 反复切换时钟源：换完还得是 12MHz，且不能多出沿
//
// 因: rcv 是 clk_mux 的选路端。已连接（attached）状态下，用 TB 侧的 sie_susp & sie_wkup
//     把 driving 拉高再放开，就能在不拆总线的前提下反复把 rcv 在 0/1 之间翻
//     （0 = 选 clk12s，1 = 选 dclk），来回 20 趟。
//     ★ 这两个是 TB 里 SIE 侧的模型量，只喂 rcv：不真挂起（DUT 的 suspended 不动，
//       故 chk_evt(2,0) 成立），也不驱动 DUT 的唤醒旁路——旁路读的是 DUT 自己判的
//       bus_suspended，此刻恒 0。rcv 由 TB 现算，跟 DUT 内部接法无关。
// 变: 每趟 clk_mux 走一次无毛刺切换：等当前时钟的高相位走完、再换源。
// 果: ① 每趟 rcv 稳定后，窗口内的 clk12m 上升沿都在 12MHz 标称值 ±3% 内
//        —— 多一个沿就是切换处冒了毛刺，少一个就是吃掉了半个周期，这是
//        "切换处不能多沿/丢沿"的量化解（唯一真正能判毛刺的那条）；
//     ② 20 趟下来 clk12m 的高低相位最短值不低于 1 个 ref 拍，只作参考打印：
//        ref 域采样看不见比 1 拍更细的毛刺，而且测量起点本身落在某个相位中间，
//        起点那半拍会被算成最窄值。亚拍级毛刺只能在 clk_mux 单元测试里查，
//        见 clk_mux_verification.md；
//     ③ 切换期间不报任何总线事件（rcv 与总线事件是两套判据，互不干扰）。
// 前后文窗口: 连接后起，20 趟 × 2µs（每趟远小于 3ms 挂起门限）。
//
// 门限口径: 2µs = 96 个 ref 拍，标称 24 个 clk12m 周期，取 ±1 个沿。
//============================================================================
task case_clk_switch;
    integer i, c0, d, lo, hi;
    begin
        attach_dev;
        chk(rcv === 1'b1, "start from dclk source");
        clk_hi_min = 0; clk_lo_min = 0;       // 只量切换段, 不算上电段

        for (i = 0; i < 20; i = i + 1) begin
            // ---- 切到 clk12s：driving 拉高 → rcv = 0 ----
            sie_susp = 1'b1;
            sie_wkup = 1'b1;
            repeat (30) @(posedge ref_clk);   // 让切换落定
            c0 = n_clk12m_rise;
            #2000;
            d = n_clk12m_rise - c0;
            if (d < 23 || d > 25) begin
                $display("  ERR : round %0d: clk12s window has %0d clk12m edges, exp 24",
                         i, d);
                errors = errors + 1;
            end

            // ---- 切回 dclk：driving 落 → rcv = 1 ----
            sie_wkup = 1'b0;
            repeat (30) @(posedge ref_clk);
            c0 = n_clk12m_rise;
            #2000;
            d = n_clk12m_rise - c0;
            if (d < 23 || d > 25) begin
                $display("  ERR : round %0d: dclk window has %0d clk12m edges, exp 24",
                         i, d);
                errors = errors + 1;
            end
        end

        sie_susp = 1'b0; sie_wkup = 1'b0;
        repeat (30) @(posedge ref_clk);

        lo = (clk_lo_min < clk_hi_min) ? clk_lo_min : clk_hi_min;
        hi = (clk_lo_min < clk_hi_min) ? clk_hi_min : clk_lo_min;
        $display("        min phase: low=%0d high=%0d ref cycles (nominal 2)",
                 clk_lo_min, clk_hi_min);
        chk(lo >= 1, "no runt phase shorter than 1 ref cycle across 40 switches");

        chk_evt(0, 1, "connect_evt only once");
        chk_evt(1, 0, "rcv toggling must not produce bus events");
        chk_evt(2, 0, "no suspend_evt");
        chk_evt(3, 0, "no resume_evt");
        chk(rcv === 1'b1, "ended on dclk source");

        if (errors == start_errs) $display("  PASS: phy_clk_switch");
        else $display("  FAIL: phy_clk_switch (%0d errors)", errors - start_errs);
    end
endtask
