//============================================================================
// case_long_bit_f.v — 长 bit (J 电平) → F 绕行测试
//
// 测试目的: 验证 CDR 在 J 电平遇到长 bit 时触发 F 绕行
//
// 场景: PID bit 5 (data=1, bit 索引 13) 拉长到 5-cycle
//   - CDR 在右环 (J 电平), 状态在 5→7→6→4 循环
//   - 走到状态 3 时，a_reg=1 (D+ 仍为 J)
//   - 触发 3→F→6→4→5 绕行
//
// 预期结果: f_detected 标志置位 (state 3→15)
//============================================================================

task case_long_bit_f;
    integer case_start_errors;
    begin
        case_start_errors = errors;
        f_detected = 0;
        $display("== case_long_bit_f: long bit (J level) → F detour ==");
        reset_dout_check();

        // bit 13 (PID[5], data=1) → 5cyc, 在 J 电平 → 触发 F 绕行
        out_packet_task(7'd5, 4'd1, 4, 13, 5);

        #(BIT_TIME * 10);

        // F 绕行检查 — 关键 pass/fail 条件
        if (!f_detected) begin
            $display("FAIL: F detour (state 3→15) not triggered");
            errors = errors + 1;
        end else begin
            $display("  F detour (3→F→6) detected ✓");
        end

        $display("  d_out tracking: %0d mismatches in this case (info only)", d_out_mismatches);

        if (errors == case_start_errors)
            $display("  PASS: case_long_bit_f");
        else
            $display("  FAIL: case_long_bit_f (%0d errors)", errors - case_start_errors);
    end
endtask
