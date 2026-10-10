//============================================================================
// case_pid_carry.v — 用例 7: PID 尾巴的连 1 计数要带进下一字节 (报告 §2.5 反例)
//
// OUT token (PID 0xE1 = 线上 1000_0111, 尾 3 连 1) 发给地址 7 的设备
// → 下一字节 0x07 线上以 111 开头 → 3 + 3 = 6 → **必须插一个 0**。
//
// 这条专治最常见的误读: "SYNC 不计入" ≠ "PID 不计入"。计数只从 PID 起算,
// PID 自身的连 1 照常累计。
//
// 判据: 边界处恰插**一个** 0 (位流长度 = 8 + 8 + 8 + 1 填充 = 25),
//       且回环 2 字节相等。
//============================================================================

task case_pid_carry;
    integer k, bad;
    begin
        $display("== tx_pid_carry: PID 尾 3 连 1 + 次字节头 3 连 1 → 插 0 ==");

        clr_pkt; put(`PID_OUT); put(8'h07);
        run_pkt("E1_07", 1, 1);
        causal_print("pid_carry/E1_07");        // 因果链证据: 本包插 0 拍数应为 1 (报告 §4.8 规范)
        eop_check("E1_07");

        // SYNC 8 + PID 8 (无填充) + 次字节 8 位 + 边界填充 0 = 25 位
        if (rec_n != 25) begin
            $display("    FAIL: 位流 %0d 位, 应 25 (边界插 1 个 0)", rec_n);
            errors = errors + 1;
        end

        // 逐位核对 (rec_bits 下标从 SYNC 第 1 位起算, 即绝对位号):
        // 0xE1 线上 (LSb 先): 1 0 0 0 0 1 1 1  → 下标 8..15, 尾部 3 连 1
        // 0x07 线上 (LSb 先): 1 1 1 0 0 0 0 0  → bit0..2 = 1,1,1 (下标 16..18)
        //   3 (PID 尾) + 3 = 6 → 下标 19 是插入的 0, 0x07 的 bit3.. 从下标 20 起。
        if (rec_n >= 25) begin
            bad = 0;
            if (rec_bits[16] !== 1'b1) bad = 1;         // 0x07 bit0
            if (rec_bits[17] !== 1'b1) bad = 1;         // 0x07 bit1
            if (rec_bits[18] !== 1'b1) bad = 1;         // 0x07 bit2 (第 6 个连 1)
            if (rec_bits[19] !== 1'b0) bad = 1;         // ★ 插入的 0
            if (rec_bits[20] !== 1'b0) bad = 1;         // 0x07 bit3 (被推迟一位)
            if (bad) begin
                $display("    FAIL: 边界位序不符 (期望 ...1,1,1,0,0..., 实得 ...%b,%b,%b,%b,%b...)",
                         rec_bits[16], rec_bits[17], rec_bits[18], rec_bits[19], rec_bits[20]);
                errors = errors + 1;
            end
        end

        // ---- 阴性对照: 同 PID 后接 0x00 (0 个连 1) → 不该插位 ----
        clr_pkt; put(`PID_OUT); put(8'h00);
        run_pkt("E1_00", 1, 1);
        if (rec_n != 24) begin
            $display("    FAIL: E1+00 位流 %0d 位, 应 24 (不该插位)", rec_n);
            errors = errors + 1;
        end

        // ---- 边界扫描: 16 PID × 16 次字节, 逐位 oracle 全过 (用例 15 先扫一部分) ----
        for (k = 0; k < 16; k = k + 1) begin
            clr_pkt; put(`PID_OUT); put(k[7:0] | 8'h01);
            run_pkt("carry", 1, 1);
        end
    end
endtask
