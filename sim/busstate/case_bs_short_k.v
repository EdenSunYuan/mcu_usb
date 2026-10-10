//============================================================================
// bs_short_k — 挂起中短 K（包内数据）不报 resume，挂起保持
//
// 因: 挂起中线上出现 28 拍 K（≈583ns，包内数据位 / 握手包的形状）
// 变: 线变化清 cnt，只数到 27 拍就到头，rsm_cond 不成立；suspended 无人清它
// 果: 不出 resume_evt；短 K 不解除挂起
// 判据: 窗口内无判据无脉冲；suspended 保持 1
// 前文窗口: 已挂起
// 后文窗口: 紧接着再来一次够长的 K（≥2.5µs），唤醒判据照常成立（挂起 → 已附着）
//============================================================================
task case_short_k;
    begin
        $display("  因: 挂起中线上出现短 K 28 拍（包内数据，不是唤醒信令）");
        $display("  变: 线变化清 cnt，数到 27 拍就到头 → rsm_cond 不成立");
        $display("  果: 无 resume_evt，suspended 保持 1");
        drive(1, 0, 300);
        drive(1, 0, 144100);
        chk("pre_suspended", u_dut.suspended, 1);
        win_begin;
        drive(0, 1, 28);                     // 短 K
        drive(1, 0, 40);                     // 回 idle
        win_end;

        chk("short_k_no_cond", d_cond[3] + d_cond[0] + d_cond[1] + d_cond[2], 0);
        chk("short_k_no_pulse", d_pulse[3] + d_pulse[0] + d_pulse[1] + d_pulse[2], 0);
        chk("still_suspended_after_short_k", u_dut.suspended, 1);

        $display("  后文窗口: 接着来一次够长的 K（400 拍 ≈8.3µs）");
        win_begin;
        drive(0, 1, 400);
        win_end;
        chk_chain("long_k_after_short_k", d_cond[3], d_mid[3], d_pulse[3]);
        chk("suspended_cleared_after_long_k", u_dut.suspended, 0);
    end
endtask
