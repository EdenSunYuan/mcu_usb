//============================================================================
// mux_reset_default — 复位默认态 ST_TX：clk12m 立即可用 = clk12s
//
// 因: 复位撤销后 rcv=0（发送/空闲方向），dclk_en=0（DPLL 未锁、线上没有数据，
//     真实场景 = 上电后主机还没发过包）
// 变: FSM 停在 ST_TX，输出 MUX 选 clk12s；div_cnt 从 0 起振
// 果: clk12m 是一路干净的 12MHz——周期恒 4 拍、高/低电平恒 2 拍（50% 占空比）
// 判据: st==F_TX；min_period==max_period==4；min_high==max_high==2；min_low==max_low==2；
//       err_tx==err_rcv==err_hold==glitch_cnt==0
// 前文窗口: 复位撤销起 200 个 ref_clk 拍（含起振 + 稳态）
//============================================================================
task case_reset_default;
    begin
        dclk_en = 1'b0;                 // DPLL 未锁：dclk 恒 0
        rcv     = 1'b0;
        win_clear;
        ref_ticks(200);

        $display("  因: 复位撤销, rcv=0, dclk 恒 0（DPLL 未锁）");
        $display("  变: FSM 停 ST_TX, 输出选 clk12s（div_cnt 从 0 起振）");
        $display("  果: clk12m 周期 %0d..%0d 拍, 高电平 %0d..%0d 拍, 低电平 %0d..%0d 拍, 上升沿 %0d 个",
                 min_period, max_period, min_high, max_high, min_low, max_low, clk12m_edges);

        if (st !== F_TX) begin
            $display("    FAIL: 复位后未停在 ST_TX (现态 %0d)", st);
            errors = errors + 1;
        end
        if ((min_period != 4) || (max_period != 4)) begin
            $display("    FAIL: clk12s 周期非恒 4 拍 (%0d..%0d)", min_period, max_period);
            errors = errors + 1;
        end
        if ((min_high != 2) || (max_high != 2)) begin
            $display("    FAIL: clk12s 高电平非恒 2 拍 (%0d..%0d)", min_high, max_high);
            errors = errors + 1;
        end
        if ((min_low != 2) || (max_low != 2)) begin
            $display("    FAIL: clk12s 低电平非恒 2 拍 (%0d..%0d)", min_low, max_low);
            errors = errors + 1;
        end
        if (clk12m_edges < 40) begin
            $display("    FAIL: 200 拍内 clk12m 上升沿只有 %0d 个 (期望 >=40)", clk12m_edges);
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
        if (err_hold != 0) begin
            $display("    FAIL: 过渡态下 clk12m != 0 有 %0d 拍", err_hold);
            errors = errors + 1;
        end
        if (glitch_cnt != 0) begin
            $display("    FAIL: 检出 %0d 个毛刺 (来路不正的输出沿: 上升 %0d / 下降 %0d)",
                     glitch_cnt, spur_rise, spur_fall);
            errors = errors + 1;
        end
    end
endtask
