//============================================================================
// case_nominal.v — 标称 4-cycle OUT Token 测试
//
// 测试目的: 验证 CDR 在标称 4-cycle bit 宽度下的基本功能
//   1. 锁存过程 C(12)→D(13)→5
//   2. 右环(电平 J)循环 5→7→6→4
//   3. 左环(电平 K)循环 1→3→2→0
//   4. d_out 锁存后跟踪 NRZI 电平 (统计信息)
//   5. clk12m = 12MHz
//
// 预期结果:
//   - locked 信号在 OUT Token 中或之后置位
//   - d_out 大致跟踪 rxdp (允许 DPLL 内部流水延迟)
//============================================================================

task case_nominal;
    integer case_start_errors;
    begin
        case_start_errors = errors;
        $display("== case_nominal: nominal 4-cycle OUT token ==");
        reset_dout_check();

        // 因果链·锁存窗口: 首包前记录 idle 前窗 (state=C / dclk=0),
        // 发完 OUT token 后由 causal_lock_check 按前后文断言 C→D→5 + 恢复时钟起振。
        causal_arm();
        #(BIT_TIME * 2);              // idle J 前窗 (~8 ref_clk)
        out_packet_task(7'd5, 4'd1, 4, -1, 4);
        causal_lock_check();

        #(BIT_TIME * 10);

        // 检查锁存 — 这是关键 pass/fail 条件
        if (!locked) begin
            $display("FAIL: CDR did not lock after nominal packet");
            errors = errors + 1;
        end else begin
            $display("  CDR locked ✓");
        end

        // d_out 跟踪: 信息性检查 (DPLL 有内部流水延迟, 不强制完全匹配)
        $display("  rx_bit tracking: %0d mismatches in this case (info only)", d_out_mismatches);

        if (errors == case_start_errors)
            $display("  PASS: case_nominal");
        else
            $display("  FAIL: case_nominal (%0d errors)", errors - case_start_errors);
    end
endtask
