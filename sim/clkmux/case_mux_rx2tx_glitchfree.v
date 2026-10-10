//============================================================================
// mux_rx2tx_glitchfree — RX→TX 无毛刺切换（mux_tx2rx 的反方向）
//
// 因: 已在 ST_RCV 稳态输出 dclk（前文窗口 40 拍），SIE 把 rcv 拉低（包收完要回发）
// 变: ST_RCV 只在 dclk 的低相位离开 → ST_HOLD1（输出恒 0）→ 等 clk12s 低点接入 → ST_TX
//     断离发生在 dclk 低相位，故 clk12m 的 1→0 与 dclk 自己的下降沿重合，同样是干净下降沿
// 果: 全程无毛刺；过渡态每拍 clk12m 恒 0；稳态后 clk12m == clk12s（周期回到恒 4 拍）
// 判据: glitch_cnt==0；err_hold==err_rcv==err_tx==0；fsm_visit[HOLD1]>0；
//       fsm_visit[HOLD2]==0；末态 st==F_TX 且 min_period==max_period==4
// 前文窗口: 切换前 40 拍 ST_RCV 稳态；后文窗口: 到达 ST_TX 后再跑 40 拍
//============================================================================
task case_rx2tx_glitchfree;
    integer seg_glitch, seg_err, seg_hold, seg_edges, seg_min, seg_max, seg_hi;
    begin
        dclk_en = 1'b1;
        rcv     = 1'b1;
        wait_state(F_RCV, 60);
        ref_ticks(40);                  // 前文窗口：ST_RCV 稳态

        // ★ FSM 统计从"切换前一刻"重开：本 case 必须先进到 ST_RCV，而复位默认态是
        //   ST_TX，于是入口路径必然走 ST_TX→HOLD2→ST_RCV。若不重开，HOLD2 会被记成
        //   "本方向也进了 HOLD2"，把下面那条断言弄成假阳性（实测确实如此）。
        fsm_clear;
        ref_ticks(2);

        win_clear;
        rcv = 1'b0;                     // 发起 RX→TX
        wait_state(F_TX, 40);
        ref_ticks(40);                  // 后文窗口：ST_TX 稳态

        // ★ 先把"切换段 + 后文段"整窗的数记下来 —— 这一窗里混着 dclk（周期 3/4/5 拍
        //   摆动），所以只判毛刺/恒定判据，不判周期恒 4；周期恒 4 要另开纯 ST_TX 窗。
        seg_glitch = glitch_cnt;
        seg_err    = err_rcv + err_tx + err_hold;
        seg_hold   = fsm_visit[F_HOLD1];
        seg_edges  = clk12m_edges;
        seg_min    = min_period;
        seg_max    = max_period;

        win_clear;                      // 重开窗口：此时已在 ST_TX
        ref_ticks(40);                  // 纯 ST_TX 稳态窗口
        seg_hi = clk12m_edges;

        $display("  因: ST_RCV 稳态输出 dclk 40 拍后 rcv 1->0");
        $display("  变: ST_RCV 在 dclk 低相位断离 -> HOLD1(输出 0) -> 等 clk12s 低接入 -> ST_TX");
        $display("  果: 切换段上升沿 %0d 个 / 间隔 %0d..%0d 拍 / 毛刺 %0d 个; 过渡停留 HOLD1=%0d 拍",
                 seg_edges, seg_min, seg_max, seg_glitch, seg_hold);
        $display("      回到 ST_TX 后 40 拍: 上升沿 %0d 个 / 周期 %0d..%0d 拍 / 高电平 %0d..%0d 拍",
                 seg_hi, min_period, max_period, min_high, max_high);

        if (seg_glitch != 0) begin
            $display("    FAIL: 切换过程检出 %0d 个毛刺 (来路不正的输出沿: 上升 %0d / 下降 %0d)",
                     seg_glitch, spur_rise, spur_fall);
            errors = errors + 1;
        end
        if (seg_err != 0) begin
            $display("    FAIL: 三态恒定判据违例 %0d 拍 (过渡 %0d / 收 %0d / 发 %0d)",
                     seg_err, err_hold, err_rcv, err_tx);
            errors = errors + 1;
        end
        if (seg_hold == 0) begin
            $display("    FAIL: 未经过 HOLD1 过渡态 (切换条件可能被绕过)");
            errors = errors + 1;
        end
        if (fsm_visit[F_HOLD2] != 0) begin
            $display("    FAIL: 本方向不应进 HOLD2, 却停了 %0d 拍", fsm_visit[F_HOLD2]);
            errors = errors + 1;
        end
        if (st !== F_TX) begin
            $display("    FAIL: 末态不是 ST_TX (现态 %0d)", st);
            errors = errors + 1;
        end
        if ((min_period != 4) || (max_period != 4)) begin
            $display("    FAIL: 回 ST_TX 后周期非恒 4 拍 (%0d..%0d)", min_period, max_period);
            errors = errors + 1;
        end
        if ((min_high != 2) || (max_high != 2)) begin
            $display("    FAIL: 回 ST_TX 后高电平非恒 2 拍 (%0d..%0d)", min_high, max_high);
            errors = errors + 1;
        end
        if (seg_hi < 8) begin
            $display("    FAIL: 回 ST_TX 后 40 拍内只数到 %0d 个上升沿 (期望 >=8)", seg_hi);
            errors = errors + 1;
        end
    end
endtask
