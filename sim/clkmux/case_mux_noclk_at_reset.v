//============================================================================
// mux_noclk_at_reset — dclk 恒 0（DPLL 未锁 / 主机不发包）时本地时钟仍可用
//
// 因: 上电后 DPLL 未锁、恢复时钟 dclk 恒 0 —— 这是设备接入后的**第一个真实场景**
//     （总线空闲在 J 态，DPLL 没有可锁的跳变，rcv 也没起来）
// 变: ① 段A: rcv=0 停在默认态 ST_TX, MUX 选本地 clk12s（不依赖 dclk，故照常跑）
//     ② 段B: rcv=1 请求收方向, FSM 照走 ST_TX→HOLD2→ST_RCV, 但 ST_RCV 选中的
//            dclk 恒 0 → clk12m 被"正确地"停住（不是毛刺、不是悬空）
//     ③ 段C: rcv=0 回到 ST_TX, clk12m 立刻恢复成 clk12s
// 果: 本地时钟路径全程可用；恢复时钟缺失时输出是"干净的低", 不是亚稳态或抖动
// 判据: 段A err_*==0 且周期恒 4 拍、上升沿 >=8；
//       段B 进入 ST_RCV 后上升沿增量 == 0 且 err_rcv==0（clk12m == dclk == 0）；
//       段C err_*==0 且周期回到恒 4 拍、上升沿 >=8；
//       三条腿 HOLD1 / HOLD2 都被走过
// 前文窗口: 段A 前先停在 ST_TX；段B/段C 各自 40 拍观察窗
//============================================================================
task case_noclk_at_reset;
    integer a_edges, a_glitch, a_min, a_max, a_err;
    integer b_edges_in, b_edges, b_err;
    integer c_edges, c_min, c_max, c_err;
    begin
        //--------------------------------------------------------------------
        // 段A：dclk 未锁 + rcv=0 → 默认态 ST_TX，本地 clk12s 独立运转
        //--------------------------------------------------------------------
        dclk_en = 1'b0;                 // 恢复时钟恒 0
        rcv     = 1'b0;
        wait_state(F_TX, 60);           // 上电默认态即 ST_TX

        win_clear;
        ref_ticks(40);
        a_edges  = clk12m_edges;
        a_glitch = glitch_cnt;
        a_min    = min_period;
        a_max    = max_period;
        a_err    = err_rcv + err_tx + err_hold;

        //--------------------------------------------------------------------
        // 段B：dclk 仍未锁，但 rcv=1 请求收方向 → FSM 进 ST_RCV，clk12m 跟着 dclk 停住
        //--------------------------------------------------------------------
        win_clear;
        rcv = 1'b1;
        wait_state(F_RCV, 40);          // 过渡只有 1 拍（dclk 恒低，HOLD2 立即离开）
        b_edges_in = clk12m_edges;      // 过渡期可能数到 1 个沿，基线记在这里
        ref_ticks(40);                  // 在 ST_RCV 里观察 40 拍
        b_edges = clk12m_edges - b_edges_in;
        b_err   = err_rcv + err_tx + err_hold;

        //--------------------------------------------------------------------
        // 段C：rcv=0 回到发送/空闲方向，clk12m 恢复成本地 clk12s
        //--------------------------------------------------------------------
        win_clear;
        rcv = 1'b0;
        wait_state(F_TX, 40);
        ref_ticks(40);
        c_edges = clk12m_edges;
        c_min   = min_period;
        c_max   = max_period;
        c_err   = err_rcv + err_tx + err_hold;

        $display("  因: DPLL 未锁, dclk 恒 0 (rcv 也一直没起来)");
        $display("  变: A 段 rcv=0 走本地 clk12s -> B 段 rcv=1 进 ST_RCV 选到恒 0 的 dclk -> C 段回 ST_TX");
        $display("  果: A 段上升沿 %0d 个/周期 %0d..%0d 拍; B 段 ST_RCV 内上升沿 %0d 个; C 段上升沿 %0d 个/周期 %0d..%0d 拍",
                 a_edges, a_min, a_max, b_edges, c_edges, c_min, c_max);
        $display("      三腿停留拍数 HOLD1=%0d HOLD2=%0d", fsm_visit[F_HOLD1], fsm_visit[F_HOLD2]);

        // ---- 段A：本地时钟不依赖 dclk ----
        if (a_err != 0) begin
            $display("    FAIL: 段A 三态恒定判据违例 %0d 拍", a_err);
            errors = errors + 1;
        end
        if ((a_min != 4) || (a_max != 4)) begin
            $display("    FAIL: 段A clk12m 周期非恒 4 拍 (%0d..%0d)", a_min, a_max);
            errors = errors + 1;
        end
        if (a_edges < 8) begin
            $display("    FAIL: 段A 40 拍内只数到 %0d 个上升沿 (期望 >=8)", a_edges);
            errors = errors + 1;
        end
        if (a_glitch != 0) begin
            $display("    FAIL: 段A 检出 %0d 个毛刺", a_glitch);
            errors = errors + 1;
        end

        // ---- 段B：dclk 恒 0 时 ST_RCV 输出应"干净地停住" ----
        if (b_edges != 0) begin
            $display("    FAIL: 段B ST_RCV 内仍有 %0d 个上升沿 (dclk 恒 0 却输出了跳变)", b_edges);
            errors = errors + 1;
        end
        if (b_err != 0) begin
            $display("    FAIL: 段B 三态恒定判据违例 %0d 拍", b_err);
            errors = errors + 1;
        end

        // ---- 段C：恢复方向后本地时钟立刻回来 ----
        if (c_err != 0) begin
            $display("    FAIL: 段C 三态恒定判据违例 %0d 拍", c_err);
            errors = errors + 1;
        end
        if ((c_min != 4) || (c_max != 4)) begin
            $display("    FAIL: 段C clk12m 周期非恒 4 拍 (%0d..%0d)", c_min, c_max);
            errors = errors + 1;
        end
        if (c_edges < 8) begin
            $display("    FAIL: 段C 40 拍内只数到 %0d 个上升沿 (期望 >=8)", c_edges);
            errors = errors + 1;
        end
        if ((fsm_visit[F_HOLD1] == 0) || (fsm_visit[F_HOLD2] == 0)) begin
            $display("    FAIL: 两条过渡腿未都走过 (HOLD1=%0d HOLD2=%0d)",
                     fsm_visit[F_HOLD1], fsm_visit[F_HOLD2]);
            errors = errors + 1;
        end
        if (st !== F_TX) begin
            $display("    FAIL: 末态不是 ST_TX (现态 %0d)", st);
            errors = errors + 1;
        end
    end
endtask
