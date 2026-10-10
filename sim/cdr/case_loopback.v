//============================================================================
// case_loopback.v — 端到端回环验证 【新增】
//
// 测试目的: 直接用 CDR 恢复的 clk12m + d_out 重建原始包数据, 与发送的包
//   逐 bit 对比。这是对 CDR 最严格的验证——不再依赖"电平跟踪"等间接判据,
//   而是走完整链路:
//
//   发送 bit_task (NRZI + 位填充) ──> 差分线 ──> CDR ──> clk12m + d_out
//                                                       └─ 采样 d_out @clk12m
//                                                       └─ NRZI 解码
//                                                       └─ 恢复数据位
//   对比: 恢复数据位 vs bit_task 记录的实际发送数据位 (含 stuffed bit)
//
// 关键设计:
//   - bit_task 记录发送位到 exp_tx_q (含 stuffed bit, SYNC 在前)
//   - 用 clk12m 上升沿采样 d_out, NRZI 解码 (变->0, 不变->1) 到 rx_q
//   - CDR 相位对齐会"吃掉"SYNC 开头 1~2 bit (首包 2 bit, 后续包 1 bit),
//     所以用 SYNC 尾巴 (连续 ≥4 个 0 + 1) 定位, 对齐后从 PID 开始对比
//
// 覆盖 3 种包: SETUP token (CRC5) + DATA0 (CRC16 + 位填充) + ACK (无 CRC)
//
// 预期结果: 每个包的恢复数据位与发送位完全一致 (0 bit 差异)
//============================================================================

// 回环准备工作: 开启记录/捕获, 清指针
task roundtrip_begin;
    begin
        record_en     = 1;
        rx_capture_en = 1;
        exp_tx_wptr   = 0;
        rx_wptr       = 0;
        rx_have_prev  = 0;
    end
endtask

// 回环检查: 关闭记录/捕获, 找 SYNC 结束位对齐, 逐 bit 对比 PID 及之后的数据
//
// 关键理解: CDR 的时钟相位对齐会"吃掉" SYNC 开头 1~2 个 bit (锁存/再对齐阶段)。
//   这正是 USB 用 SYNC 的目的——SIE 只用 SYNC 对齐采样时钟, 从 PID 开始解码数据。
//   因此恢复流里 SYNC 可能只剩 5~6 个 0 (而不是完整 7 个 0), 且其余数据位
//   与发送位完全一致 (经验证 0 bit 差异)。所以这里用 SYNC 的"尾巴"
//   (连续 ≥4 个 0 后跟 1) 定位包起点, 对齐后从 PID 开始逐 bit 对比。
task roundtrip_check;
    integer i, run, sync_end, n_err, n_cmp;
    begin
        record_en     = 0;
        rx_capture_en = 0;
        #(BIT_TIME);                     // 让最后一个 clk12m 沿捕获完成

        // 找 SYNC 结束位: 连续 ≥4 个 0 后跟一个 1 (那个 1 就是 SYNC 最后一位)
        // 阈值 4 足够容忍 0~3 个被吃掉的 SYNC 位, 且不会误匹配后续数据
        // (SYNC 之前只有 idle=全1, 不存在 0 连跑, 所以第一个匹配必是 SYNC)
        sync_end = -1;
        run = 0;
        for (i = 0; i < rx_wptr; i = i + 1) begin
            if (rx_q[i] == 1'b0) run = run + 1;
            else begin
                if (run >= 4) begin
                    sync_end = i;        // rx 上 SYNC 最后一位的位置
                    i = rx_wptr;         // 跳出循环
                end
                run = 0;
            end
        end

        if (sync_end < 0) begin
            $display("    FAIL: SYNC not found in recovered stream (%0d bits)",
                     rx_wptr);
            errors = errors + 1;
        end else begin
            // sync_end(rx) 对应 exp[7] (SYNC 最后一位)。对比 PID 及之后:
            //   rx[sync_end+1+m] vs exp[8+m]
            n_err = 0;
            n_cmp = 0;
            for (i = 0; (sync_end + 1 + i) < rx_wptr && (8 + i) < exp_tx_wptr; i = i + 1) begin
                if (rx_q[sync_end + 1 + i] !== exp_tx_q[8 + i]) begin
                    if (n_err < 5)
                        $display("      bit[%0d] rx=%0d exp=%0d",
                                 8 + i, rx_q[sync_end+1+i], exp_tx_q[8+i]);
                    n_err = n_err + 1;
                end
                n_cmp = n_cmp + 1;
            end

            if (n_err == 0 && n_cmp == exp_tx_wptr - 8) begin
                $display("    ✓ %0d data bits (PID+…) recovered identical (SYNC end @rx[%0d], 吃掉 %0d SYNC 位)",
                         n_cmp, sync_end, 7 - sync_end);
            end else begin
                $display("    FAIL: %0d/%0d data bits differ (SYNC end @rx[%0d], rx=%0d bits)",
                         n_err, exp_tx_wptr - 8, sync_end, rx_wptr);
                // debug dump
                begin : dbg_dump
                    integer k;
                    $write("      exp[%0d]: ", exp_tx_wptr);
                    for (k = 0; k < exp_tx_wptr; k = k + 1) $write("%0d", exp_tx_q[k]);
                    $write("\n      rx [%0d]: ", rx_wptr);
                    for (k = 0; k < rx_wptr; k = k + 1) $write("%0d", rx_q[k]);
                    $write("\n");
                end
                errors = errors + 1;
            end
        end
    end
endtask

task case_loopback;
    integer case_start_errors;
    begin
        case_start_errors = errors;
        $display("== case_loopback: end-to-end bit-level round-trip ==");
        reset_dout_check();

        // ---- pkt1: SETUP token (锁存 + 回环) ----
        $display("  [SETUP token] round-trip:");
        roundtrip_begin();
        setup_packet_task(7'd5, 4'd0, 4, -1, 4);
        roundtrip_check();

        if (!locked) begin
            $display("    FAIL: CDR not locked");
            errors = errors + 1;
        end

        #(BIT_TIME * 4);                 // inter-packet gap

        // ---- pkt2: DATA0 (含 0x7F 触发位填充) ----
        $display("  [DATA0] round-trip:");
        roundtrip_begin();
        data_packet_task(`PID_TYPE_DATA0,
                         8'h80, 8'h06, 8'h00, 8'h01, 8'h7F, 8'h7F, 8'h40, 8'h00,
                         7'd8, 4, -1, 4);
        roundtrip_check();

        #(BIT_TIME * 4);                 // inter-packet gap

        // ---- pkt3: ACK handshake ----
        $display("  [ACK] round-trip:");
        roundtrip_begin();
        handshake_packet_task(`PID_TYPE_ACK, 4, -1, 4);
        roundtrip_check();

        // ---- 汇总 ----
        if (errors == case_start_errors)
            $display("  PASS: case_loopback");
        else
            $display("  FAIL: case_loopback (%0d errors)", errors - case_start_errors);
    end
endtask
