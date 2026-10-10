//============================================================================
// case_stuff_pos_scan.v — 用例 16 (新增): 填充 0 落在字节内每个位置
//
// 位填充的一个实现陷阱是"插 0 那拍该不该移位 / 位计数该不该前进"。
// 本用例构造一批字节, 让第 6 个连 1 恰好落在字节内 bit0~bit7 的每一个位置,
// 从而把 hold 逻辑在每个相位上都压一遍; 再叠一个"6 连 1 恰好跨字节边界"的序列。
//
// 判据: 逐位 oracle + 回环全过 (oracle 独立算出插 0 的位置, 位序错一位就报错)。
//============================================================================

task case_stuff_pos_scan;
    integer k, n, ones, m;
    reg [7:0] b;
    begin
        $display("== tx_stuff_pos_scan: 第 6 个连 1 落在字节内每个位置 ==");

        // ---- 第 6 个连 1 落在 bit k (k=5..7 才可能; k<5 时前面必须是 0 起头) ----
        // 构造: 前导 0 到使 ones 在 bit k 处正好到 6。
        //   ones 在 bit k 处 = 6  →  bit(k-5)..bit k 全 1 且 bit(k-5) 之前一个 0
        for (k = 5; k <= 7; k = k + 1) begin
            b = 8'h00;
            for (m = 0; m <= k - 5; m = m + 1)
                b[k - 5 - m] = 1'b1;                // 起点前一位放 0 (bd 保持 0)
            for (m = k - 4; m <= k; m = m + 1)
                b[m] = 1'b1;                        // 第 6 个 1 落在 bit k
            clr_pkt; put(`PID_DATA0); put(b); put(8'h00);
            run_pkt("pos", 1, 1);
        end

        // ---- 第 6 个连 1 落在字节最末位 (末位触发, 下拍插 0) ----
        //   b1=0, b2..b7=1 → b7 恰是第 6 个 1 → 收尾填充
        b = 8'hFC;
        clr_pkt; put(`PID_DATA0); put(b);
        run_pkt("pos_tail", 1, 1);
        if (rec_n != 25) begin
            $display("    FAIL: 末位触发填充时位流 %0d 位, 应 25", rec_n);
            errors = errors + 1;
        end

        // ---- 连 1 跨字节边界: 前字节尾部 3 连 1 + 后字节头部 4 连 1 ----
        //   前 0xF8 = 0001_1111 (LSb 先: 1,1,1,1,1,0,0,0 → 尾 0)
        //   用 0x0F (LSb 先: 1,1,1,1,0,0,0,0 → 头 4 连 1) 配 0xFC (LSb 先: 0,0,1,1,1,1,1,1)
        clr_pkt; put(`PID_DATA0); put(8'hFC); put(8'h0F);
        run_pkt("pos_cross1", 1, 1);

        clr_pkt; put(`PID_DATA0); put(8'hFD); put(8'h0F);
        run_pkt("pos_cross2", 1, 1);

        // ---- 连续多个字节都触发填充 (每字节内一次), 检查 hold 不累积错位 ----
        clr_pkt; put(`PID_DATA1);
        for (n = 0; n < 8; n = n + 1)
            put(8'hFE);                             // 每字节插 1 个 0
        put(8'h3C); put(8'h5A);
        run_pkt("pos_multi", 1, 1);

        // 8 × 0xFE: 每字节插 1 个 0 → 纯数据 80 位 + 填充 8 位
        ones = 96 + 8;
        $display("    第 6 连 1 相位扫描完成 (末条位流 %0d 位, 括号参考 %0d)", rec_n, ones);
    end
endtask
