//============================================================================
// bs_k_when_awake — 未挂起时的长 K 不报 resume（挂起是唤醒判据的前置）
//
// 因: 已附着、未挂起时，线上出现 100µs 长 K
// 变: cnt 数到 120 拍时 cnt_2p5u=1 且 line_k，但 suspended=0 → rsm_cond 不成立
//     （K 只把计数器清零）
// 果: 不出 resume_evt；回 J 后重新数 3ms 照常报挂起
// 判据: 窗口内无事件；suspended 全程 0；后文窗口挂起正常报出
// 前文窗口: 先插入连接
//============================================================================
task case_k_when_awake;
    begin
        $display("  因: 未挂起时线上出现 100µs 长 K");
        $display("  变: 门限命中了，但 suspended=0 挡住 rsm_cond");
        $display("  果: 无 resume_evt；K 只是清了计数器");
        drive(1, 0, 300);                    // 只连接，不挂起
        chk("pre_not_suspended", u_dut.suspended, 0);
        win_begin;
        drive(0, 1, 4800);                   // 100µs K
        drive(1, 0, 200);
        win_end;
        chk("k_when_awake_no_cond", d_cond[0] + d_cond[1] + d_cond[2] + d_cond[3], 0);
        chk("k_when_awake_no_pulse", d_pulse[0] + d_pulse[1] + d_pulse[2] + d_pulse[3], 0);
        chk("not_suspended_after_k", u_dut.suspended, 0);

        $display("  后文窗口: 回 J 空闲 3ms —— 挂起判据照常成立");
        win_begin;
        drive(1, 0, 144100);
        win_end;
        chk_chain("suspend_after_k", d_cond[1], d_mid[1], d_pulse[1]);
        chk("suspended_set", u_dut.suspended, 1);
    end
endtask
