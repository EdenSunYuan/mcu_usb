//============================================================================
// bs_suspend — 空闲 J ≥3ms 报 suspend_evt，且只报一次
//
// 因: 已附着后总线继续空闲 J（主机不发 SOF / 包，挂起的前兆）
// 变: cnt 从线变 J 起数，144000 拍（=3ms）时 cnt_3ms=1，加 line_j、connected、~suspended
//     → sus_cond=1 → suspended 置 1；suspended 是长电平，同步链取上升沿 → suspend_evt
// 果: suspend_evt 恰好一个脉冲，suspended=1；窗口内无其它事件
// 判据: 三处计数都 == 1；suspended==1；脉冲宽 1 个 clk12m 拍
// 前文窗口: 先连接（suspended 的前置是 connected）
// 后文窗口: 再空闲 3ms——suspended 已置起，同一段空闲不许重复报
//============================================================================
task case_suspend;
    begin
        $display("  因: 已附着后总线空闲 J 持续 3ms");
        $display("  变: cnt 数到 144000 拍 → sus_cond=1 → suspended 置 1 → 同步链取上升沿");
        $display("  果: suspend_evt 一个脉冲，suspended=1");
        drive(1, 0, 300);                    // 前窗: 先连接
        win_begin;
        drive(1, 0, 144100);                 // 空闲到 3ms
        win_end;

        chk_chain("suspend_chain", d_cond[1], d_mid[1], d_pulse[1]);
        chk("suspended_set_after_suspend", u_dut.suspended, 1);
        chk("suspend_no_other_cond", d_cond[0] + d_cond[2] + d_cond[3], 0);
        chk("suspend_no_other_pulse", d_pulse[0] + d_pulse[2] + d_pulse[3], 0);
        chk("suspend_evt_width_1clk12m", wmax[1], 1);
        $display("  延迟: 判据 → 脉冲 %0d..%0d ref 拍", lat_min[1], lat_max[1]);

        $display("  后文窗口: 再空闲 3ms，同一段空闲不许重复报");
        win_begin;
        drive(1, 0, 144100);
        win_end;
        chk("suspend_not_repeated", d_cond[1] + d_pulse[1], 0);
    end
endtask
