//============================================================================
// case_pid_only.v — 用例 1: 单字节包 (ACK/NAK/STALL/NYET/PRE)
//
// 判据: 回环收到 1 字节且相等; 位流 = SYNC(8) + 字节(8) + EOP; tx_ready 恰 1 拍。
// 覆盖: 报告 §2.5 (SYNC 恒 8 拍)、§2.7 (握手)、§2.3 (EOP)。
//============================================================================

task case_pid_only;
    begin
        $display("== tx_pid_only: 单字节包 (握手/特殊) ==");

        clr_pkt; put(`PID_ACK);   run_pkt("ACK",   1, 1);
        causal_print("pid_only/ACK");           // 因果链证据 (只打印, 不判) — 报告 §4.8 规范
        clr_pkt; put(`PID_NAK);   run_pkt("NAK",   1, 1);
        clr_pkt; put(`PID_STALL); run_pkt("STALL", 1, 1);
        clr_pkt; put(`PID_NYET);  run_pkt("NYET",  1, 1);
        clr_pkt; put(`PID_PRE);   run_pkt("PRE",   1, 1);

        // 单字节包守恒: 期望位流恒 = 8 (SYNC) + 8 (PID) = 16, 无填充位
        if (exp_n != 16) begin
            $display("    FAIL: 单字节包期望位流 %0d 位, 应 16", exp_n);
            errors = errors + 1;
        end

        // 每个单字节包: EOP 恒 3 拍 (SE0×2 + J×1)
        eop_check("pid_only");
    end
endtask
