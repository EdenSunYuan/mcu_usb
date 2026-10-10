//============================================================================
// case_eop_timing.v — 用例 8: EOP 时长与交高阻时机 (报告 §4.3)
//
// 判据: tx_se0 恰 2 拍 (166.7ns, 规范 160-175ns); 其后 J 恰 1 拍 (tx_done 拍);
//       EOP 期间不出数据位; tx_done 后 tx_en↓ (tx_active 撤) → 线交高阻回 J。
//
// 独立判据: 不用内部信号, 只看端口 + 线上电平 (rxdp/rxdn)。
//============================================================================

task case_eop_timing;
    integer f0;
    begin
        $display("== tx_eop_timing: SE0 恰 2 拍 + J 恰 1 拍 + 交高阻 ==");

        clr_pkt; put(`PID_ACK);
        run_pkt("eop_ack", 1, 1);
        causal_print("eop_timing/ACK");         // 因果链证据: 无填充包的干净 EOP (报告 §4.8 规范)
        eop_check("eop_ack");

        clr_pkt; put(`PID_DATA0); put(8'h55); put(8'hAA); put(8'h3C); put(8'h5A);
        run_pkt("eop_data", 1, 1);
        eop_check("eop_data");

        // ---- EOP 后线电平必须回 J (tx_en↓ → 高阻 → 上拉/下拉分压) ----
        if (rxdp !== 1'b1 || rxdn !== 1'b0) begin
            $display("    FAIL: EOP 后线未回空闲 J (dp=%b dn=%b)", rxdp, rxdn);
            errors = errors + 1;
        end

        // ---- EOP 后长时间空闲: 不得再关包 (无幽灵帧) ----
        f0 = rx_frames;
        #(BIT_TIME * 200);
        if (rx_frames != f0) begin
            $display("    FAIL: EOP 后空闲期出现幽灵关包 (%0d 次)", rx_frames - f0);
            errors = errors + 1;
        end

        // ---- 多包连发, 每包 EOP 时长都要对 ----
        clr_pkt; put(`PID_IN); put(8'h03); put(8'h10);
        run_pkt("eop_in", 1, 1);
        eop_check("eop_in");
        if (eop_se0_n != 2) begin
            $display("    FAIL: IN token EOP SE0 %0d 拍", eop_se0_n);
            errors = errors + 1;
        end

        $display("    EOP 量化: SE0=%0d 拍 (%.1fns), J=%0d 拍 (%.1fns)",
                 eop_se0_n, eop_se0_n * BIT_TIME, eop_j_n, eop_j_n * BIT_TIME);
    end
endtask
