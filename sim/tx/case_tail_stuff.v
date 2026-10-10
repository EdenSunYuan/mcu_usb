//============================================================================
// case_tail_stuff.v — 用例 5: 末字节以 6 连 1 收尾 (报告 §4.7 缺陷回归)
//
// 判据: EOP 前仍插 0 (欠的填充 0 不丢); EOP 恒 3 拍。
//
// 背景: 参考模型最初在末字节正好凑满 6 连 1 时直接进 EOP, 把欠下的那个填充 0
//       丢掉了 —— 线上变成 6 连 1 直接接 EOP。修正 = S_DATA 出口加
//       stuff_pend=0 条件。本用例就是钉这条的。
//
// 触发字节: b1=0, b2~b7=1 且前导不提前凑满 6 → 末位 b7 恰是第 6 个 1。
//   0xFC = 0011_1111 (b0=0,b1=0,b2..b7=1)
//   0xFD = 1011_1111 (b0=1,b1=0,b2..b7=1)
//============================================================================

task case_tail_stuff;
    integer k, bad;
    begin
        $display("== tx_tail_stuff: 末字节 6 连 1 收尾 ==");

        // ---- 末字节 0xFC (2 字节包) ----
        clr_pkt; put(`PID_DATA0); put(8'hFC);
        run_pkt("tail_FC", 1, 1);
        causal_print("tail_stuff/FC");          // 因果链证据: 收尾那个填充 0 的 hold 拍 (报告 §4.8 规范)
        eop_check("tail_FC");
        // 位流 = SYNC 8 + PID 8(无填充) + 0xFC 8 位 + 收尾填充 0 = 25 位
        if (rec_n != 25) begin
            $display("    FAIL: 末字节 0xFC 位流 %0d 位, 应 25 (8+8+8+收尾填充0)", rec_n);
            errors = errors + 1;
        end
        // 线上最后一个数据位之后必须紧跟一个 0 (收尾填充), 再进 EOP
        if (rec_n >= 25 && rec_bits[24] !== 1'b0) begin
            $display("    FAIL: 第 25 位 (收尾填充) 不是 0");
            errors = errors + 1;
        end

        // ---- 末字节 0xFD ----
        clr_pkt; put(`PID_DATA1); put(8'hFD);
        run_pkt("tail_FD", 1, 1);
        eop_check("tail_FD");
        if (rec_n != 25) begin
            $display("    FAIL: 末字节 0xFD 位流 %0d 位, 应 25", rec_n);
            errors = errors + 1;
        end

        // ---- 末字节 0xFC 放在长包末尾 (前面字节也参与连 1 计数) ----
        clr_pkt; put(`PID_DATA0); put(8'hFF); put(8'hFF); put(8'hFC);
        run_pkt("tail_FF_FF_FC", 1, 1);
        eop_check("tail_FF_FF_FC");

        // ---- 反过来: 末字节不是 6 连 1 收尾时, 位流长度应正好 (无多余填充) ----
        clr_pkt; put(`PID_DATA1); put(8'h00);
        run_pkt("tail_00", 1, 1);
        if (rec_n != 24) begin
            $display("    FAIL: 末字节 0x00 位流 %0d 位, 应 24 (无填充)", rec_n);
            errors = errors + 1;
        end

        bad = 0;
        for (k = 0; k < rec_n; k = k + 1)
            if (rec_bits[k] !== exp_bits[k]) bad = bad + 1;
        $display("    末字节收尾扫描完成, 累计位不符 %0d", bad);
    end
endtask
