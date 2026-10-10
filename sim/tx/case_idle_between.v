//============================================================================
// case_idle_between.v — 用例 18 (新增): 包间长空闲与连续多包混合
//
// 判据: 包间空闲期线恒为 J、无幽灵帧; 空闲长度从几拍到十几微秒变化时,
//       下一包仍能正常起 (CDR 重新锁定 + NRZI 复位 + SOP 正确)。
//
// 这条对应真实总线: 包与包之间的间隔由主机调度决定, 长短不一; 且设备端
// tx_en=0 交高阻期间总线靠上拉维持 J (报告 §4.8.2)。
//============================================================================

task case_idle_between;
    integer k, f0;
    begin
        $display("== tx_idle_between: 包间空闲 (长短不一) ==");

        // ---- 短间隔 (几拍) 连续 5 包 ----
        for (k = 0; k < 5; k = k + 1) begin
            clr_pkt; put(`PID_OUT); put(k[7:0]); put(8'h10);
            run_pkt("idle_short", 1, 1);
            if (rxdp !== 1'b1 || rxdn !== 1'b0) begin
                $display("    FAIL: 包间空闲线不是 J (k=%0d)", k);
                errors = errors + 1;
            end
        end

        // ---- 长空闲 (≈10µs = 120 bit 时间) 后发包 ----
        f0 = rx_frames;
        #(BIT_TIME * 120);
        if (rx_frames != f0) begin
            $display("    FAIL: 长空闲期出现幽灵关包");
            errors = errors + 1;
        end
        if (rxdp !== 1'b1 || rxdn !== 1'b0) begin
            $display("    FAIL: 长空闲期线不是 J");
            errors = errors + 1;
        end
        clr_pkt; put(`PID_SETUP); put(8'h00); put(8'h10);
        run_pkt("idle_after_long", 1, 1);
        eop_check("idle_after_long");

        // ---- 长短间隔交替 ----
        for (k = 0; k < 4; k = k + 1) begin
            #(BIT_TIME * (20 * (k + 1)));
            clr_pkt; put(`PID_DATA0); put(8'h00 + k[7:0]); put(8'hFC); put(8'h3C); put(8'h5A);
            run_pkt("idle_alt", 1, 1);
            eop_check("idle_alt");
        end

        // ---- 收尾: 长空闲后总线上不得有残留 (最后一次收尾填充也不许漏) ----
        #(BIT_TIME * 200);
        if (rxdp !== 1'b1 || rxdn !== 1'b0) begin
            $display("    FAIL: 收尾长空闲线不是 J");
            errors = errors + 1;
        end

        $display("    包间空闲: 累计关包 %0d 帧, 线全程保持 J", rx_frames);
    end
endtask
