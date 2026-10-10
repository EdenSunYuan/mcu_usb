//============================================================================
// mux_toggle_stress — 连续反向切换 20 次，累计毛刺 = 0
//
// 因: 已在 ST_TX 稳态，rcv 以"每次切到目标态后再跑 5 拍"的节奏连续翻转 20 次
//     （模拟一帧里多次事务相位交替：Token→握手→Token→…）
// 变: 每次都要完整走两拍过渡（断离 → 等电平 → 接入），且断离/接入相位随 dclk 的
//     3/4/5 拍抖动而变化 —— 若某次在错误的相位切换，就会在这里冒毛刺
// 果: 20 次切换全程无毛刺、三态恒定判据零违例
// 判据: glitch_cnt==0；err_hold==err_rcv==err_tx==0；
//       fsm_arc[TX][HOLD2]==10 且 fsm_arc[RCV][HOLD1]==10（20 次切换 = 10 个来回）
// 前文窗口: 起振后 20 拍 ST_TX 稳态
//============================================================================
task case_toggle_stress;
    integer k;
    integer sw;
    begin
        dclk_en = 1'b1;
        rcv     = 1'b0;
        wait_state(F_TX, 60);
        ref_ticks(20);                  // 前文窗口

        win_clear;
        sw = 0;
        for (k = 0; k < 20; k = k + 1) begin
            if ((k % 2) == 0) begin
                rcv = 1'b1;
                wait_state(F_RCV, 40);
            end
            else begin
                rcv = 1'b0;
                wait_state(F_TX, 40);
            end
            sw = sw + 1;
            ref_ticks(5);               // 切到目标态后再稳态跑 5 拍
        end

        $display("  因: ST_TX 稳态后 rcv 连续翻转 20 次(每次切到位再跑 5 拍)");
        $display("  变: 每次都由 3/4/5 拍抖动的 dclk 决定断离/接入相位");
        $display("  果: 完成 %0d 次切换; 毛刺 %0d 个; 上升沿间隔 %0d..%0d 拍",
                 sw, glitch_cnt, min_period, max_period);
        $display("      弧计数 TX->HOLD2=%0d  RCV->HOLD1=%0d",
                 fsm_arc[F_TX][F_HOLD2], fsm_arc[F_RCV][F_HOLD1]);

        if (sw != 20) begin
            $display("    FAIL: 只完成 %0d 次切换 (期望 20)", sw);
            errors = errors + 1;
        end
        if (glitch_cnt != 0) begin
            $display("    FAIL: 20 次切换累计 %0d 个毛刺 (来路不正的输出沿: 上升 %0d / 下降 %0d)",
                     glitch_cnt, spur_rise, spur_fall);
            errors = errors + 1;
        end
        if (err_hold != 0) begin
            $display("    FAIL: 过渡态下 clk12m != 0 有 %0d 拍", err_hold);
            errors = errors + 1;
        end
        if (err_rcv != 0) begin
            $display("    FAIL: ST_RCV 下 clk12m != dclk 有 %0d 拍", err_rcv);
            errors = errors + 1;
        end
        if (err_tx != 0) begin
            $display("    FAIL: ST_TX 下 clk12m != clk12s 有 %0d 拍", err_tx);
            errors = errors + 1;
        end
        if (fsm_arc[F_TX][F_HOLD2] < 10) begin
            $display("    FAIL: TX->HOLD2 只发生 %0d 次 (期望 10)", fsm_arc[F_TX][F_HOLD2]);
            errors = errors + 1;
        end
        if (fsm_arc[F_RCV][F_HOLD1] < 10) begin
            $display("    FAIL: RCV->HOLD1 只发生 %0d 次 (期望 10)", fsm_arc[F_RCV][F_HOLD1]);
            errors = errors + 1;
        end
    end
endtask
