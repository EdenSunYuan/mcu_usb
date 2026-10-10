//============================================================================
// case_conformant_scan.v — 合规 DATA0 包扫描 (最后数据位+EOP 是否凑 7 连 1)
//
// 目的 (回答"正常 USB 包会不会出现这种情况"):
//   发完全合规的 DATA0 包 (SYNC+PID+载荷+CRC16+EOP, 用公共任务库
//   NRZI/位填充/CRC16), 两个子扫描:
//     A. 1 字节载荷穷举 0x00..0xFF;
//     B. 8 字节载荷随机 ~RAND_N 帧 (真实 setup/control 数据常见长度)。
//   每帧在 EOP 前抓发送端尾状态 (nrzi_lv: 线电平, ones_cnt: 尾连续 1 数),
//   标记 "收尾 K + 尾连续1≥5" 的候选; 关包看 err。
//   - 基线版 (无 CONFORM_EXP_CLEAN): 只统计打印 —— 若候选帧 err=1 即证明
//     合规包确实会被误判。
//   - 门控版 (-DCONFORM_EXP_CLEAN): 断言候选帧 err 必须 =0 (门控应消除)。
//
// 说明: 本场景只关心"误判合规包", 不校验字节内容。
//============================================================================

task case_conformant_scan;
    integer p, i, j, _bc, frame_before, start_errs;
    integer n_cand, n_bad, n_tot;
    reg  [15:0] tx_crc;
    reg  [7:0]  cb [0:7];
    reg         tail_lv;          // 1=J, 0=K (EOP 前最后电平)
    integer     tail_ones;        // EOP 前连续 1 数

    // 子任务 (task 内不能用 task 定义? 用 begin..end 局部循环展开两段相同代码
    // 太长, 抽成 tb 级函数不合适 —— 这里用两段循环, 各维护自己的计数器)
    begin
        start_errs = errors;

        // ---------------- 子扫描 A: 1 字节穷举 ----------------
        n_cand = 0;  n_bad = 0;  n_tot = 0;
        $display("== conformant DATA0 (A: 1B payload exhaustive, CRC16+EOP) ==");
`ifdef CONFORM_EXP_CLEAN
        $display("    MODE: gated — conformant K-tail candidates must close err=0");
`else
        $display("    MODE: baseline — informational (report false-err on conformant packets)");
`endif
        for (p = 0; p < 256; p = p + 1) begin
            frame_before = close_cnt;
            _bc = 0;
            sync_task(4, -1, 4, _bc);
            pid_task(`PID_TYPE_DATA0, 4, -1, 4);
            _bc = _bc + 8;
            byte_task(p[7:0], 4, -1, 4);
            _bc = _bc + 8;
            tx_crc = crc16_tx(p[7:0], 8'h00, 8'h00, 8'h00, 8'h00,
                              8'h00, 8'h00, 8'h00, 7'd1);
            for (i = 15; i >= 0; i = i - 1)
                bit_task(tx_crc[i], 4);

            tail_lv   = nrzi_lv;
            tail_ones = ones_cnt;
            n_tot = n_tot + 1;
            if (tail_lv == 1'b0 && tail_ones >= 5) begin
                n_cand = n_cand + 1;
                if (n_cand <= 8)
                    $display("    CAND p=%02x: K, tail ones=%0d", p[7:0], tail_ones);
            end
            eop_task;
            wait_close(frame_before + 1, 250);
            if (close_cnt < frame_before + 1) begin
                $display("    WARN p=%02x: no frame close", p[7:0]);
            end else if (tail_lv == 1'b0 && tail_ones >= 5 && last_err) begin
                n_bad = n_bad + 1;
`ifdef CONFORM_EXP_CLEAN
                $display("    FAIL: conformant p=%02x closed err=1 under gated", p[7:0]);
                errors = errors + 1;
`endif
            end
            #(BIT_TIME * 6);
        end
        $display("    A: frames=%0d  K-tail>=5 cand=%0d  false-err=%0d", n_tot, n_cand, n_bad);
`ifndef CONFORM_EXP_CLEAN
        if (n_bad > 0)
            $display("    >> BASELINE false-errors on %0d of %0d conformant packets (A)", n_bad, n_tot);
`endif

        // ---------------- 子扫描 B: 8 字节随机 ----------------
        n_cand = 0;  n_bad = 0;  n_tot = 0;
        $display("== conformant DATA0 (B: 8B payload, random, CRC16+EOP) ==");
        for (p = 0; p < 400; p = p + 1) begin
            frame_before = close_cnt;
            for (j = 0; j < 8; j = j + 1)
                cb[j] = $random & 8'hFF;

            _bc = 0;
            sync_task(4, -1, 4, _bc);
            pid_task(`PID_TYPE_DATA0, 4, -1, 4);
            _bc = _bc + 8;
            for (j = 0; j < 8; j = j + 1) begin
                byte_task(cb[j], 4, -1, 4);
                _bc = _bc + 8;
            end
            tx_crc = crc16_tx(cb[0], cb[1], cb[2], cb[3], cb[4], cb[5], cb[6], cb[7], 7'd8);
            for (i = 15; i >= 0; i = i - 1)
                bit_task(tx_crc[i], 4);

            tail_lv   = nrzi_lv;
            tail_ones = ones_cnt;
            n_tot = n_tot + 1;
            if (tail_lv == 1'b0 && tail_ones >= 5) begin
                n_cand = n_cand + 1;
                if (n_cand <= 8) begin
                    $write("    CAND bytes=");
                    for (j = 0; j < 8; j = j + 1) $write("%02x ", cb[j]);
                    $display(": K, tail ones=%0d", tail_ones);
                end
            end
            eop_task;
            wait_close(frame_before + 1, 250);
            if (close_cnt < frame_before + 1) begin
                $display("    WARN frame=%0d: no frame close", p);
            end else if (tail_lv == 1'b0 && tail_ones >= 5 && last_err) begin
                n_bad = n_bad + 1;
`ifdef CONFORM_EXP_CLEAN
                $display("    FAIL: conformant 8B frame closed err=1 under gated");
                errors = errors + 1;
`endif
            end
            #(BIT_TIME * 6);
        end
        $display("    B: frames=%0d  K-tail>=5 cand=%0d  false-err=%0d", n_tot, n_cand, n_bad);
`ifndef CONFORM_EXP_CLEAN
        if (n_bad > 0)
            $display("    >> BASELINE false-errors on %0d of %0d conformant packets (B)", n_bad, n_tot);
`endif

        if (errors == start_errs)
            $display("  PASS: case_conformant_scan (candidates above all closed clean)");
        else
            $display("  FAIL: case_conformant_scan (%0d errors)", errors - start_errs);
    end
endtask
