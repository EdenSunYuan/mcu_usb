//============================================================================
// case_random.v — 随机化激励测试 【新增】
//
// 测试目的: 用随机 bit 宽度 (3/4/5 cycle) 和随机数据位测试 CDR
//
// 测试方法:
//   1. 用 LFSR 生成 64 bit 伪随机数据和随机宽度
//   2. 按标准 USB bit_task 流程发送 (NRZI + 位填充)
//   3. 验证 CDR 保持锁存
//
// 预期结果: CDR 在整个随机序列中保持锁存
//============================================================================

task case_random;
    integer case_start_errors;
    integer i;
    reg [5:0] lfsr;
    reg [1:0] width_sel;
    integer n_bits;
    begin
        case_start_errors = errors;
        n_bits = 64;
        $display("== case_random: random stimulus (%0d bits) ==", n_bits);
        reset_dout_check();

        // 先发 SYNC 让 CDR 锁存
        $display("  Sending SYNC to establish lock...");
        for (i = 0; i < 7; i = i + 1)
            bit_task(1'b0, 4.0);
        bit_task(1'b1, 4.0);

        #(BIT_TIME * 4);

        if (!locked) begin
            $display("FAIL: CDR did not lock after SYNC");
            errors = errors + 1;
        end else begin
            $display("  CDR locked ✓");
        end

        // 伪随机序列
        lfsr = 6'b101011;
        $display("  Sending %0d random bits...", n_bits);

        for (i = 0; i < n_bits; i = i + 1) begin
            width_sel = lfsr[2:1];

            // 用 LFSR bit 控制宽度选择
            case (width_sel)
                2'd0: bit_task(lfsr[0], 3.0);   // 短 bit
                2'd1: bit_task(lfsr[0], 4.0);   // 标称
                2'd2: bit_task(lfsr[0], 5.0);   // 长 bit
                2'd3: bit_task(lfsr[0], 4.0);   // 标称
            endcase

            // 推进 LFSR: x^6 + x^5 + 1
            lfsr = {lfsr[4:0], lfsr[5] ^ lfsr[4]};
        end

        #(BIT_TIME * 16);

        if (!locked) begin
            $display("FAIL: CDR lost lock during random test");
            errors = errors + 1;
        end else begin
            $display("  CDR still locked ✓");
        end

        $display("  d_out tracking: %0d mismatches in this case (info only)", d_out_mismatches);
        $display("  Random test complete (%0d bits)", n_bits);

        if (errors == case_start_errors)
            $display("  PASS: case_random");
        else
            $display("  FAIL: case_random (%0d errors)", errors - case_start_errors);
    end
endtask
