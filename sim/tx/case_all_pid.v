//============================================================================
// case_all_pid.v — 用例 14 (新增): 16 种 PID 形态各作单字节包
//
// 判据: 回环 1 字节相等; 位流恰 16 位 (SYNC 8 + PID 8, 无填充)。
// 与用例 6 的区别: 用例 6 用位级判据专攻"不插填充位", 本用例走完整回环,
// 验"PID 字节本身经 NRZI + 回环还原后一字不差"。
//============================================================================

task case_all_pid;
    integer p;
    reg [7:0] pid;
    begin
        $display("== tx_all_pid: 16 种 PID 形态单字节包 ==");

        for (p = 0; p < 16; p = p + 1) begin
            pid = {~p[3:0], p[3:0]};
            clr_pkt; put(pid);
            run_pkt("all_pid", 1, 1);
            sync_pid_nostuff_check("all_pid", pid);
            if (rec_n != 16) begin
                $display("    FAIL: PID %02x 单字节包位流 %0d 位, 应 16", pid, rec_n);
                errors = errors + 1;
            end
            eop_check("all_pid");
        end

        // 11 种有定义的 PID 单独再走一遍, 确认常量表与结构一致
        clr_pkt; put(`PID_OUT);   run_pkt("OUT",   1, 1);
        clr_pkt; put(`PID_IN);    run_pkt("IN",    1, 1);
        clr_pkt; put(`PID_SOF);   run_pkt("SOF",   1, 1);
        clr_pkt; put(`PID_SETUP); run_pkt("SETUP", 1, 1);
        clr_pkt; put(`PID_DATA0); run_pkt("DATA0", 1, 1);
        clr_pkt; put(`PID_DATA1); run_pkt("DATA1", 1, 1);
        clr_pkt; put(`PID_ACK);   run_pkt("ACK",   1, 1);
        clr_pkt; put(`PID_NAK);   run_pkt("NAK",   1, 1);
        clr_pkt; put(`PID_STALL); run_pkt("STALL", 1, 1);
        clr_pkt; put(`PID_NYET);  run_pkt("NYET",  1, 1);
        clr_pkt; put(`PID_PRE);   run_pkt("PRE",   1, 1);

        $display("    16 种形态 + 11 种有定义 PID 全部回环一致");
    end
endtask
