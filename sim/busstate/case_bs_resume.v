//============================================================================
// bs_resume — 挂起中主机驱 K ≥2.5µs 报 resume_evt（被动唤醒）
//
// 因: 挂起中主机驱 K（D- 高、D+ 低）保持 20ms
// 变: cnt 数到 120 拍时 cnt_2p5u=1，加 line_k、~driving、suspended → rsm_cond=1
//     → suspended 清 0；同时 rsm_tgl 翻一位 → 同步链新旧不同 → resume_evt 出 1 拍
// 果: resume_evt 恰好一个脉冲，suspended 清 0；20ms 长 K 里只出一个
// 判据: 三处计数都 == 1；suspended==0；脉冲宽 1 个 clk12m 拍；窗口内无其它事件
// 前文窗口: 连接 → 空闲 3ms 进挂起（rsm_cond 的前置是 suspended）
// 后文窗口: 20ms 长 K 全程只此一个脉冲（判据单拍 → 翻转只一次）
//============================================================================
task case_resume;
    begin
        $display("  因: 挂起中主机驱 K 保持 20ms（远程唤醒信令）");
        $display("  变: cnt 数到 120 拍 → rsm_cond=1 → suspended 清 0 + rsm_tgl 翻一位");
        $display("  果: resume_evt 一个脉冲，suspended=0");
        drive(1, 0, 300);                    // 连接
        drive(1, 0, 144100);                 // 空闲 3ms 进挂起
        chk("pre_suspended", u_dut.suspended, 1);
        win_begin;
        drive(0, 1, 960000);                 // 主机 K 20ms
        win_end;

        chk_chain("resume_chain", d_cond[3], d_mid[3], d_pulse[3]);
        chk("suspended_cleared_after_resume", u_dut.suspended, 0);
        chk("resume_no_other_cond", d_cond[0] + d_cond[1] + d_cond[2], 0);
        chk("resume_no_other_pulse", d_pulse[0] + d_pulse[1] + d_pulse[2], 0);
        chk("resume_evt_width_1clk12m", wmax[3], 1);
        $display("  延迟: 判据 → 脉冲 %0d..%0d ref 拍", lat_min[3], lat_max[3]);
    end
endtask
