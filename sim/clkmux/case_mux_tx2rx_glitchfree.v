//============================================================================
// mux_tx2rx_glitchfree — TX→RX 无毛刺切换
//
// 因: 已在 ST_TX 稳态输出 clk12s（前文窗口 40 拍），SIE 把 rcv 由 0 拉高（收到主机包）
// 变: ST_TX 只在 clk12s **低相位**离开 → ST_HOLD2（输出恒 0，拉低缓冲）→ 等 dclk 低点
//     接入 → ST_RCV（输出 dclk）；断离发生在 clk12s 已为 0 时，输出 0→0 无缝，
//     既不截短旧时钟的高电平、也不多出一个 clk12s 自己没有的下降沿
// 果: 全程无毛刺；过渡态每拍 clk12m 恒 0；稳态后 clk12m == dclk（周期回到 3/4/5 拍摆动）
// 判据: glitch_cnt==0；err_hold==err_tx==err_rcv==0；fsm_visit[HOLD2]>0（确实走过过渡态）；
//       fsm_visit[HOLD1]==0（本方向不该进 HOLD1）；末态 st==F_RCV 且 clk12m_edges>=8
//       （后文窗口 40 拍里 dclk 周期 3/4/5 拍 → 期望 8~13 个上升沿）
// 前文窗口: 切换前 40 拍 ST_TX 稳态；后文窗口: 到达 ST_RCV 后再跑 40 拍
//
// ★ 本用例是 2026-09-20 那次仿真修正的现场：改成低点断离前，rcv 若恰在 clk12s 上升沿
//   那一拍起来，高电平会被截成 1 拍、并多出一个下降沿（spur_fall=1、最短间隔 2 拍）。
//============================================================================
task case_tx2rx_glitchfree;
    begin
        dclk_en = 1'b1;                 // DPLL 已锁：dclk 自由运转（周期 3/4/5 拍摆动）
        rcv     = 1'b0;
        wait_state(F_TX, 60);           // 先确保在 ST_TX
        ref_ticks(40);                  // 前文窗口：ST_TX 稳态

        // ★ FSM 统计从"切换前一刻"重开：fsm_clear 后的第一拍只用来对齐基准、不入账，
        //   故先跑 2 拍让对齐落在稳态里，再发起切换 —— 保证下面的 HOLD1/HOLD2 断言
        //   说的就是本次切换，而不是 case 入口路径。
        fsm_clear;
        ref_ticks(2);

        win_clear;
        rcv = 1'b1;                     // 发起 TX→RX
        wait_state(F_RCV, 40);
        ref_ticks(40);                  // 后文窗口：ST_RCV 稳态

        $display("  因: ST_TX 稳态输出 clk12s 40 拍后 rcv 0->1");
        $display("  变: ST_TX 在 clk12s 低相位断离 -> HOLD2(输出 0) -> 等 dclk 低接入 -> ST_RCV");
        $display("  果: 上升沿 %0d 个 / 最短间隔 %0d 拍 / 最长间隔 %0d 拍; 过渡停留 HOLD2=%0d 拍",
                 clk12m_edges, min_period, max_period, fsm_visit[F_HOLD2]);

        if (glitch_cnt != 0) begin
            $display("    FAIL: 切换过程检出 %0d 个毛刺 (来路不正的输出沿: 上升 %0d / 下降 %0d)",
                     glitch_cnt, spur_rise, spur_fall);
            errors = errors + 1;
        end
        if (err_hold != 0) begin
            $display("    FAIL: 过渡态下 clk12m != 0 有 %0d 拍", err_hold);
            errors = errors + 1;
        end
        if (err_tx != 0) begin
            $display("    FAIL: ST_TX 下 clk12m != clk12s 有 %0d 拍", err_tx);
            errors = errors + 1;
        end
        if (err_rcv != 0) begin
            $display("    FAIL: ST_RCV 下 clk12m != dclk 有 %0d 拍", err_rcv);
            errors = errors + 1;
        end
        if (fsm_visit[F_HOLD2] == 0) begin
            $display("    FAIL: 未经过 HOLD2 过渡态 (切换条件可能被绕过)");
            errors = errors + 1;
        end
        if (fsm_visit[F_HOLD1] != 0) begin
            $display("    FAIL: 本方向不应进 HOLD1, 却停了 %0d 拍", fsm_visit[F_HOLD1]);
            errors = errors + 1;
        end
        if (st !== F_RCV) begin
            $display("    FAIL: 末态不是 ST_RCV (现态 %0d)", st);
            errors = errors + 1;
        end
        if (clk12m_edges < 8) begin
            $display("    FAIL: 切换后 clk12m 只在 %0d 个上升沿恢复 (期望 >=8)", clk12m_edges);
            errors = errors + 1;
        end
    end
endtask
