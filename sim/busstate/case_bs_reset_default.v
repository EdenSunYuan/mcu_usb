//============================================================================
// bs_reset_default — 复位清零 + 冷启动长 SE0 不报总线复位
//
// 因: 复位撤销后线一直停在 SE0（电缆没插，两线都被下拉到低）
// 变: line_s 采到 SE0，line_chg 只在第一拍有效，之后 cnt 从 0 数到 2.5µs 上界 121 停住；
//     connected 一直是 0
// 果: 四条判据全 0、四个输出无脉冲——没附着过就谈不上总线复位
// 判据: 无判据、无脉冲；cnt==121（到顶饱和）；connected==0；suspended==0
// 前文窗口: ref_rstn 低电平期间异步复位分支真跑一次（所有寄存器被清）
// 后文窗口: 10ms SE0（远长于 2.5µs 门限）持续保持仍不出事件
//============================================================================
task case_reset_default;
    begin
        $display("  因: 复位撤销后线停在 SE0（未插线）");
        $display("  变: cnt 数到 2.5µs 上界 121 停住；connected 仍 0 → rst_cond 的 connected 项不成立");
        $display("  果: 四条判据全 0，四个输出无脉冲");
        win_begin;
        drive(0, 0, 480000);                 // 10ms SE0
        win_end;
        $display("  后文窗口: cnt=%0d, connected=%0d, suspended=%0d, line_s=%b",
                 u_dut.cnt, u_dut.connected, u_dut.suspended, u_dut.line_s);

        chk("cold_no_cond", d_cond[0] + d_cond[1] + d_cond[2] + d_cond[3], 0);
        chk("cold_no_pulse", d_pulse[0] + d_pulse[1] + d_pulse[2] + d_pulse[3], 0);
        chk("cold_cnt_at_2p5u_top", u_dut.cnt, 121);
        chk("cold_not_connected", u_dut.connected, 0);
        chk("cold_not_suspended", u_dut.suspended, 0);
    end
endtask
