//============================================================================
// case_pkt_all.v — 全部 9 类合法 USB1.1 正常包的 CDR 端到端回环验证 【新增】
//
// 测试目的: 把 USB1.1 Full-Speed 的全部合法正常包类型逐个走完整 CDR 链路,
//   用恢复出的 clk12m + d_out 还原原始包数据位, 与发送位逐 bit 对比。
//   这是 case_loopback (仅 SETUP+DATA0+ACK 3 包) 在全包型上的推广:
//
//     Token     : OUT / IN / SETUP / SOF     (PID + 字段 + CRC5)
//     Data      : DATA0 / DATA1              (PID + payload + CRC16)
//     Handshake : ACK / NAK / STALL          (仅 PID)
//
// 覆盖位填充 (bit-stuffing): SOF frame=0x7FF、DATA payload 含 0x7F/0xFF,
//   强制 SYNC/PID→帧号 及 payload 内部触发 stuffed 0 —— 恢复流必须原样还原
//   这些 stuffed bit, 证明 CDR 不丢、不错插任何一位。
//
// 复用 case_loopback.v 里模块级的 roundtrip_begin / roundtrip_check:
//   - roundtrip_begin : 开 record(记录发送位含 stuffed) + 开 rx 捕获
//   - roundtrip_check : 关记录/捕获, 找 SYNC 尾巴定位, PID 起逐 bit 对比
//
// 预期结果: 每个包恢复数据位与发送位 0 差异, errors=0, locked 全程保持。
//============================================================================

task case_pkt_all;
    integer start_errs;
    integer pkt_errors;
    integer npkts, nbad;
    begin
        start_errs = errors;
        npkts = 0;
        nbad  = 0;
        $display("== case_pkt_all: all 9 legal USB1.1 packets, bit-level round-trip ==");
        reset_dout_check();

        //====================================================================
        // 1: Token OUT (addr=5, endp=0) — PID E1 — 首包锁存 (吃 2 SYNC 位)
        //====================================================================
        $display("  [OUT  token] round-trip:");
        // 首包 = 从复位锁存事件: 记录 idle 前窗后发 OUT, 发完按因果链断言锁存
        causal_arm();
        #(BIT_TIME * 2);              // idle J 前窗 (~8 ref_clk)
        pkt_errors = errors;
        roundtrip_begin();
        out_packet_task(7'd5, 4'd0, 4, -1, 4);
        roundtrip_check();
        causal_lock_check();          // C→D→5 因果链 + 恢复时钟起振 (前后文窗口)
        npkts = npkts + 1;
        if (errors != pkt_errors) nbad = nbad + 1;
        if (!locked) begin
            $display("    FAIL: CDR not locked after OUT");
            errors = errors + 1;
        end
        #(BIT_TIME * 4);

        //====================================================================
        // 2: Token IN (addr=5, endp=2) — PID 69
        //====================================================================
        $display("  [IN   token] round-trip:");
        pkt_errors = errors;
        roundtrip_begin();
        in_packet_task(7'd5, 4'd2, 4, -1, 4);
        roundtrip_check();
        npkts = npkts + 1;
        if (errors != pkt_errors) nbad = nbad + 1;
        if (!locked) begin
            $display("    FAIL: CDR lost lock during IN");
            errors = errors + 1;
        end
        #(BIT_TIME * 4);

        //====================================================================
        // 3: Token SETUP (addr=5, endp=0) — PID 2D
        //====================================================================
        $display("  [SETUP token] round-trip:");
        pkt_errors = errors;
        roundtrip_begin();
        setup_packet_task(7'd5, 4'd0, 4, -1, 4);
        roundtrip_check();
        npkts = npkts + 1;
        if (errors != pkt_errors) nbad = nbad + 1;
        if (!locked) begin
            $display("    FAIL: CDR lost lock during SETUP");
            errors = errors + 1;
        end
        #(BIT_TIME * 4);

        //====================================================================
        // 4: SOF frame=0x7FF (低 11 位全 1, 强制 PID→帧号跨边界 + 帧内位填充)
        //    — PID A5
        //====================================================================
        $display("  [SOF  frame=0x7FF] round-trip:");
        pkt_errors = errors;
        roundtrip_begin();
        sof_packet_task(11'h7FF, 4, -1, 4);
        roundtrip_check();
        npkts = npkts + 1;
        if (errors != pkt_errors) nbad = nbad + 1;
        if (!locked) begin
            $display("    FAIL: CDR lost lock during SOF");
            errors = errors + 1;
        end
        #(BIT_TIME * 4);

        //====================================================================
        // 5: DATA0 — payload 含 0x7F / 0xFF (强制 stuffed 0), 8B+CRC16 — PID C3
        //====================================================================
        $display("  [DATA0 8B] round-trip:");
        pkt_errors = errors;
        roundtrip_begin();
        data0_packet_task(8'h80, 8'h06, 8'h7F, 8'hFF, 8'hFF, 8'h7F, 8'h40, 8'h00,
                          7'd8, 4, -1, 4);
        roundtrip_check();
        npkts = npkts + 1;
        if (errors != pkt_errors) nbad = nbad + 1;
        if (!locked) begin
            $display("    FAIL: CDR lost lock during DATA0");
            errors = errors + 1;
        end
        #(BIT_TIME * 4);

        //====================================================================
        // 6: DATA1 — payload 含 0xFF, 3B+CRC16 — PID 4B
        //====================================================================
        $display("  [DATA1 3B] round-trip:");
        pkt_errors = errors;
        roundtrip_begin();
        data1_packet_task(8'hAA, 8'h55, 8'hFF, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00,
                          7'd3, 4, -1, 4);
        roundtrip_check();
        npkts = npkts + 1;
        if (errors != pkt_errors) nbad = nbad + 1;
        if (!locked) begin
            $display("    FAIL: CDR lost lock during DATA1");
            errors = errors + 1;
        end
        #(BIT_TIME * 4);

        //====================================================================
        // 7: Handshake ACK — PID D2 (仅 PID)
        //====================================================================
        $display("  [ACK] round-trip:");
        pkt_errors = errors;
        roundtrip_begin();
        ack_packet_task(4, -1, 4);
        roundtrip_check();
        npkts = npkts + 1;
        if (errors != pkt_errors) nbad = nbad + 1;
        if (!locked) begin
            $display("    FAIL: CDR lost lock during ACK");
            errors = errors + 1;
        end
        #(BIT_TIME * 4);

        //====================================================================
        // 8: Handshake NAK — PID 5A (仅 PID)
        //====================================================================
        $display("  [NAK] round-trip:");
        pkt_errors = errors;
        roundtrip_begin();
        nak_packet_task(4, -1, 4);
        roundtrip_check();
        npkts = npkts + 1;
        if (errors != pkt_errors) nbad = nbad + 1;
        if (!locked) begin
            $display("    FAIL: CDR lost lock during NAK");
            errors = errors + 1;
        end
        #(BIT_TIME * 4);

        //====================================================================
        // 9: Handshake STALL — PID 1E (仅 PID)
        //====================================================================
        $display("  [STALL] round-trip:");
        pkt_errors = errors;
        roundtrip_begin();
        stall_packet_task(4, -1, 4);
        roundtrip_check();
        npkts = npkts + 1;
        if (errors != pkt_errors) nbad = nbad + 1;
        if (!locked) begin
            $display("    FAIL: CDR lost lock during STALL");
            errors = errors + 1;
        end
        #(BIT_TIME * 2);

        // ---- 汇总 ----
        $display("  %0d/9 packets round-trip bit-exact, %0d bit mismatches",
                 npkts - nbad, nbad);
        if (errors == start_errs)
            $display("  PASS: case_pkt_all (9 legal packet types bit-exact)");
        else
            $display("  FAIL: case_pkt_all (%0d errors)", errors - start_errs);
    end
endtask
