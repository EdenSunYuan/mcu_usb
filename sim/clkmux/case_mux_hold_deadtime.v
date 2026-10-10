//============================================================================
// mux_hold_deadtime — 过渡态"拉低缓冲"到底把低电平拉长了多少拍
//
// 因: 已在 ST_RCV 稳态输出 dclk，rcv 1->0 发起 RX→TX
// 变: ST_RCV 在 dclk 低相位断离 → ST_HOLD1 输出恒 0（等 clk12s 低点）→ ST_TX 接入 clk12s；
//     这段"cut 完到新时钟第一个上升沿"之间的低电平就是切换开销
// 果: 该低电平窗口 = 正常低电平(2 拍) + 过渡态引入的额外拉低
// 判据: low_result ∈ [2,6] 拍 ——
//         下界 2 = 正常低电平本身（过渡态没被绕过）；
//         上界 6 = 1(切离相位) + 2(HOLD1 等 clk12s 低) + 1(等到的低点) + 2(clk12s 半周期)
//       ≈ 42~125 ns，量级与设计报告 §4.2 的记账一致；
//       同时 glitch_cnt==0（拉低是真拉低，不是抖出来的）
// 前文窗口: 切换前 20 拍 ST_RCV 稳态（保证 dclk 相位随机化，不是每次都从同一相位切）
//============================================================================
task case_hold_deadtime;
    begin
        dclk_en = 1'b1;
        rcv     = 1'b1;
        wait_state(F_RCV, 60);
        ref_ticks(20);                  // 前文窗口

        win_clear;
        low_arm = 1'b1;                 // 武装：下一个 clk12m 上升沿记下之前的低电平宽度
        rcv = 1'b0;                     // 发起 RX→TX
        wait_state(F_TX, 40);
        ref_ticks(20);                  // 让 low_arm 一定被消费掉

        $display("  因: ST_RCV 稳态 20 拍后 rcv 1->0");
        $display("  变: 断离 dclk -> HOLD1 输出恒 0 -> 等 clk12s 低点 -> ST_TX 接入");
        $display("  果: 该次切换的低电平窗口 = %0d 拍 (≈%0.1f ns), 毛刺 %0d 个",
                 low_result, low_result * (1000.0 / 48.0), glitch_cnt);

        if (low_result < 0) begin
            $display("    FAIL: low_arm 未被消费（切换后没有出现 clk12m 上升沿）");
            errors = errors + 1;
        end
        else if ((low_result < 2) || (low_result > 6)) begin
            $display("    FAIL: 低电平窗口 %0d 拍 超出 [2,6]（过渡态被绕过或拉低过长）",
                     low_result);
            errors = errors + 1;
        end
        if (glitch_cnt != 0) begin
            $display("    FAIL: 检出 %0d 个毛刺 (来路不正的输出沿: 上升 %0d / 下降 %0d)",
                     glitch_cnt, spur_rise, spur_fall);
            errors = errors + 1;
        end
        if (err_hold != 0) begin
            $display("    FAIL: 过渡态下 clk12m != 0 有 %0d 拍", err_hold);
            errors = errors + 1;
        end
        if (st !== F_TX) begin
            $display("    FAIL: 末态不是 ST_TX (现态 %0d)", st);
            errors = errors + 1;
        end
    end
endtask
