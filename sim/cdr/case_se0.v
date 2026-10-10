//============================================================================
// case_se0.v — SE0 / EOP 处理测试 【新增】
//
// 测试目的: 验证 CDR 在 USB 总线 SE0 状态 (DP=0, DN=0) 下的行为
//
// SE0 是 USB EOP 的一部分: SE0 持续 2 bit-time → J 1 bit-time
// DP=0, DN=0 (差分电压为 0) 不同于 J (1,0) 或 K (0,1)
//
// 测试步骤:
//   1. 先发送 OUT Token 让 CDR 正常锁存
//   2. 注入额外 SE0 (DP=0, DN=0) 持续 2 bit-time
//   3. 回到 idle J
//   4. 再发一个 OUT Token 验证 CDR 能重新锁存
//
// 预期结果:
//   - SE0 后 CDR 重新锁存 (locked=1)
//============================================================================

task case_se0;
    integer case_start_errors;
    begin
        case_start_errors = errors;
        se0_survived = 0;
        $display("== case_se0: SE0/EOP handling ==");
        reset_dout_check();

        // Phase 1: 正常发送 OUT Token
        out_packet_task(7'd5, 4'd1, 4, -1, 4);
        #(BIT_TIME * 10);

        // Phase 2: 注入额外 SE0
        $display("  Injecting extra SE0 (DP=0, DN=0) for 2 bit-times...");
        rxdp = 1'b0; rxdn = 1'b0;
        #(EOP_SE0_TIME);
        // 回到 idle J
        rxdp = 1'b1; rxdn = 1'b0;
        nrzi_lv = 1'b1;
        #(EOP_J_TIME * 2);

        // Phase 3: 再发 OUT Token 验证重新锁存
        $display("  Sending second OUT token after SE0...");
        reset_dout_check();
        locked = 0;
        out_packet_task(7'd5, 4'd1, 4, -1, 4);
        #(BIT_TIME * 10);

        if (!locked) begin
            $display("FAIL: CDR did not re-lock after SE0");
            errors = errors + 1;
        end else begin
            se0_survived = 1;
            $display("  CDR re-locked after SE0 ✓");
        end

        if (errors == case_start_errors)
            $display("  PASS: case_se0");
        else
            $display("  FAIL: case_se0 (%0d errors)", errors - case_start_errors);
    end
endtask
