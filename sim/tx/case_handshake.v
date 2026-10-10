//============================================================================
// case_handshake.v — 用例 11: 载入节拍与供字节预算 (报告 §2.7/§2.8)
//
// 判据: 相邻两次载入 (tx_ready 脉冲) 间隔下界 ≥8 拍 —— 即 SIE 从"看到 tx_ready"
//       到"必须备好下一字节"至少有一个字节的移位时间 (667ns)。
//       含填充 hold 的时间隙只会更长。
//
// 量化: 记录每个 tx_ready 脉冲所在的 clk12s 拍号, 逐对求差。
//============================================================================

task case_handshake;
    integer k, gap, min_gap;
    begin
        $display("== tx_handshake: 载入间隔 ≥8 拍 ==");

        // ---- 短包: 相邻载入间隔应正好 8 拍 ----
        clr_pkt; put(`PID_OUT); put(8'h07); put(8'h10);
        run_pkt("hs_short", 1, 1);
        min_gap = 999;
        for (k = 1; k < pkt_ready_n; k = k + 1) begin
            gap = ready_t[k] - ready_t[k-1];
            if (gap < min_gap) min_gap = gap;
        end
        $display("    短包 (%0d 字节): 载入 %0d 次, 最小间隔 %0d 拍", tx_n, pkt_ready_n, min_gap);
        ready_gap_check("hs_short");

        // ---- 长包: 含填充时载入间隔被 hold 拉长 ----
        clr_pkt; put(`PID_DATA0);
        for (k = 0; k < 20; k = k + 1) begin
            put(8'hFF); put(8'h55); put(8'hAA); put(8'h0F);
        end
        put(8'h3C); put(8'h5A);
        run_pkt("hs_long", 1, 1);
        min_gap = 999;
        for (k = 1; k < pkt_ready_n; k = k + 1) begin
            gap = ready_t[k] - ready_t[k-1];
            if (gap < min_gap) min_gap = gap;
        end
        $display("    长包 (%0d 字节): 载入 %0d 次, 最小间隔 %0d 拍", tx_n, pkt_ready_n, min_gap);
        ready_gap_check("hs_long");

        // ---- 全 1 长包: 每个字节都插填充, 间隔恒 >8 拍 ----
        clr_pkt; put(`PID_DATA1);
        for (k = 0; k < 16; k = k + 1)
            put(8'hFF);
        put(8'h3C); put(8'h5A);
        run_pkt("hs_stuff", 1, 1);
        min_gap = 999;
        for (k = 1; k < pkt_ready_n; k = k + 1) begin
            gap = ready_t[k] - ready_t[k-1];
            if (gap < min_gap) min_gap = gap;
        end
        $display("    全 1 长包 (%0d 字节): 最小间隔 %0d 拍 (含填充 hold)", tx_n, min_gap);
        ready_gap_check("hs_stuff");

        if (pkt_ready_n != tx_n) begin
            $display("    FAIL: 载入次数 %0d != 字节数 %0d", pkt_ready_n, tx_n);
            errors = errors + 1;
        end
    end
endtask
