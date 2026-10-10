//============================================================================
// mux_rcv_midswitch — 切换途中 rcv 反转不中止本次迁移
//
// 因: 已在 ST_RCV 稳态，rcv 1->0 发起 RX→TX，FSM 刚进 ST_HOLD1（还没到 ST_TX）；
//     此刻把 rcv 翻回 1（模拟 SIE 在同一拍内改主意 / 收到新的收方向请求）
// 变: 次态译码只看「现态 + 现态电平」——ST_HOLD1 只认 clk12s 低点，rcv 不在它的
//     条件里；故本次迁移**不被中止**，照走 ST_HOLD1 → ST_TX（设计报告 §2.4 迁移表）
// 果: 先到 ST_TX（完成本次迁移），随即因 rcv=1 在 ST_TX 的高相位重新判决，转回 ST_RCV
// 判据: ① rcv 翻转后仍在 20 拍内到达 ST_TX（证明没被中止）；
//       ② 随后回到 ST_RCV（证明新判决生效）；
//       ③ 全程 glitch_cnt==err_hold==err_rcv==err_tx==0；
//       ④ fsm_visit[HOLD1]>0 且 fsm_visit[HOLD2]>0（两条过渡腿都真走过）
// 前文窗口: 切换前 10 拍 ST_RCV 稳态
//============================================================================
task case_rcv_midswitch;
    begin
        dclk_en = 1'b1;
        rcv     = 1'b1;
        wait_state(F_RCV, 60);
        ref_ticks(10);                  // 前文窗口

        // ★ 同 rx2tx：入口路径必然经过 HOLD2，FSM 统计从切换前重开才不作假。
        fsm_clear;
        ref_ticks(2);

        win_clear;
        rcv = 1'b0;                     // 发起 RX→TX
        wait_state(F_HOLD1, 30);        // 等 FSM 进过渡态
        rcv = 1'b1;                     // ★ 切换途中反转
        $display("  因: rcv 1->0 发起 RX→TX, FSM 进 ST_HOLD1 途中把 rcv 翻回 1");
        wait_state(F_TX, 30);           // 判据①：不被中止，仍走到 ST_TX
        $display("  变: ST_HOLD1 只认 clk12s 低点(不含 rcv), 本次迁移照走完 -> ST_TX");
        wait_state(F_RCV, 40);          // 判据②：rcv=1 使 ST_TX 高相位重新判决，转回 RCV
        ref_ticks(20);                  // 后文窗口
        $display("  果: 到达 ST_TX 后按 rcv=1 重新判决, 回到 ST_RCV; 毛刺 %0d 个", glitch_cnt);

        if (glitch_cnt != 0) begin
            $display("    FAIL: 检出 %0d 个毛刺 (来路不正的输出沿: 上升 %0d / 下降 %0d)",
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
        if ((fsm_visit[F_HOLD1] == 0) || (fsm_visit[F_HOLD2] == 0)) begin
            $display("    FAIL: 两条过渡腿未都走过 (HOLD1=%0d HOLD2=%0d)",
                     fsm_visit[F_HOLD1], fsm_visit[F_HOLD2]);
            errors = errors + 1;
        end
        if (st !== F_RCV) begin
            $display("    FAIL: 末态不是 ST_RCV (现态 %0d)", st);
            errors = errors + 1;
        end
    end
endtask
