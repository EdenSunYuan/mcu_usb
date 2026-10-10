//============================================================================
// case_multi_pkt.v — 多包事务数据/时钟恢复测试 【新增】
//
// 测试目的: 验证 CDR 在连续多个 USB 包之间仍能正确恢复数据与时钟。
//   单包测试只验证一次锁存 + 一个包的恢复；真实总线是连续事务流，
//   包与包之间隔着 EOP + idle J，CDR 必须在每个 SYNC 重新对齐相位。
//
// 事务 (3 个包, 模拟一次 SETUP 控制传输):
//   pkt1  SETUP token   : SYNC + PID(SETUP) + ADDR + ENDP + CRC5 + EOP
//   pkt2  DATA0 (8字节) : SYNC + PID(DATA0) + payload + CRC16 + EOP
//   pkt3  ACK handshake : SYNC + PID(ACK) + EOP
//   (payload 含 0x7F 触发位填充, 验证 CDR 通过 stuffed bit)
//
// 自检点:
//   1. locked   : 每个包后仍保持锁存 (不丢锁)
//   2. clk12m  : 恢复时钟持续翻转, 周期恒为 3~5 ref_clk (标称 4 = 12MHz)
//   3. d_out    : 恢复的 NRZI 电平跟踪差分线 (信息性统计)
//
// 预期结果: locked 恒为 1, clk12m 周期全部正常, errors=0
//============================================================================

task case_multi_pkt;
    integer case_start_errors;
    begin
        case_start_errors = errors;
        $display("== case_multi_pkt: 3-packet transaction (SETUP + DATA0 + ACK) ==");
        reset_dout_check();
        clk12m_meas_en = 0;
        clk12m_edges = 0;
        clk12m_bad_periods = 0;

        // ---- pkt1: SETUP token (让 CDR 锁存) ----
        setup_packet_task(7'd5, 4'd0, 4, -1, 4);
        #(BIT_TIME * 4);            // inter-packet gap (idle J)

        if (!locked) begin
            $display("FAIL: CDR not locked after SETUP token");
            errors = errors + 1;
        end else
            $display("  [pkt1 SETUP ] locked ✓");

        // ---- 打开时钟恢复测量 (避开初始锁存阶段) ----
        clk12m_meas_en = 1;
        clk12m_edges = 0;
        clk12m_bad_periods = 0;
        last_ref_cnt = ref_clk_cnt;

        // ---- pkt2: DATA0 (8 字节, 含 0x7F 触发位填充) ----
        data_packet_task(`PID_TYPE_DATA0,
                         8'h80, 8'h06, 8'h00, 8'h01, 8'h7F, 8'h7F, 8'h40, 8'h00,
                         7'd8, 4, -1, 4);
        #(BIT_TIME * 4);            // inter-packet gap (idle J)

        if (!locked) begin
            $display("FAIL: CDR lost lock during DATA0");
            errors = errors + 1;
        end else
            $display("  [pkt2 DATA0 ] locked ✓");

        // ---- pkt3: ACK handshake ----
        handshake_packet_task(`PID_TYPE_ACK, 4, -1, 4);
        #(BIT_TIME * 2);            // 让最后一个沿采样完成

        clk12m_meas_en = 0;

        if (!locked) begin
            $display("FAIL: CDR lost lock after ACK");
            errors = errors + 1;
        end else
            $display("  [pkt3 ACK   ] locked ✓");

        // ---- 自检: 恢复时钟 ----
        // 测量窗口 ≈ DATA0(96) + EOP(3) + gap(4) + ACK(16) + EOP(3) + 尾(2)
        //           ≈ 124 bit-time, 每 bit-time 1 个 clk12m 周期
        $display("  dclk: %0d rising edges (expect ~124), %0d bad periods",
                 clk12m_edges, clk12m_bad_periods);

        // 边沿数 sanity: 时钟必须持续翻转 (若 < 100 说明恢复时钟中断/停滞)
        if (clk12m_edges < 100) begin
            $display("FAIL: recovered clock edges too few (%0d < 100)", clk12m_edges);
            errors = errors + 1;
        end else
            $display("  recovered clock running ✓ (%0d edges)", clk12m_edges);

        // 周期检查: 所有 clk12m 周期应落在 3~5 ref_clk (标称 4 = 12MHz)
        if (clk12m_bad_periods != 0) begin
            $display("FAIL: %0d recovered-clock periods out of 3~5 ref_clk", clk12m_bad_periods);
            errors = errors + 1;
        end else
            $display("  clock period ✓ (all 3~5 ref_clk ≈ 12MHz)");

        // ---- 自检: 恢复数据 ----
        // d_out 是恢复的 NRZI 电平, 除每个翻转沿后 1~2 ref_clk 的流水延迟外,
        // 应与差分线一致。若连续不一致超过 6 ref_clk (1.5 bit), 说明 DPLL 丢电平。
        $display("  rx_bit tracking: %0d mismatches, max run %0d ref_clk",
                 d_out_mismatches, d_out_max_run);
        if (d_out_max_run > 6) begin
            $display("FAIL: d_out lost data level for %0d ref_clk (> 6)", d_out_max_run);
            errors = errors + 1;
        end else
            $display("  data recovered ✓ (max d_out lag %0d ref_clk ≤ 6)", d_out_max_run);

        if (errors == case_start_errors)
            $display("  PASS: case_multi_pkt");
        else
            $display("  FAIL: case_multi_pkt (%0d errors)", errors - case_start_errors);
    end
endtask
