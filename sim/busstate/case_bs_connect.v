//============================================================================
// bs_connect — 插入：J 保持 ≥2.5µs 报 connect_evt，且只报一次
//
// 因: 电缆插入 → 线从 SE0 变 J（D+ 高、D- 低），保持 6.25µs
// 变: line_chg 清 cnt → 数到 120 拍时 cnt_2p5u=1，加 line_j 与 ~connected → con_cond=1
//     → connected 置 1；connected 是长电平，两拍同步链取其上升沿 → connect_evt 出 1 拍
// 果: connect_evt 恰好一个 clk12m 拍，connected=1；窗口内无其它事件
// 判据: 判据/载体/脉冲三处计数都 == 1；connected==1；事件延迟落在 [5,8] ref 拍
// 后文窗口: 继续 J 到 2ms（过了 2.5µs、不到 3ms）——connect 不重复、挂起不提前报
//============================================================================
task case_connect;
    begin
        $display("  因: 线从 SE0 变 J 保持 6.25µs（插入）");
        $display("  变: cnt 数到 120 拍 → con_cond=1 → connected 置 1 → 两拍同步链取上升沿");
        $display("  果: connect_evt 一个脉冲，connected=1");
        win_begin;
        drive(1, 0, 300);                    // J 6.25µs
        win_end;

        chk_chain("connect_chain", d_cond[0], d_mid[0], d_pulse[0]);
        chk("connected_after_connect", u_dut.connected, 1);
        chk("connect_no_other_cond", d_cond[1] + d_cond[2] + d_cond[3], 0);
        chk("connect_no_other_pulse", d_pulse[1] + d_pulse[2] + d_pulse[3], 0);
        chk("connect_evt_width_1clk12m", wmax[0], 1);
        $display("  延迟: 判据 → 脉冲 %0d..%0d ref 拍", lat_min[0], lat_max[0]);

        $display("  后文窗口: 继续 J 2ms（过 2.5µs 门限、不到 3ms 挂起门限）");
        win_begin;
        drive(1, 0, 96000);                  // 2ms
        win_end;
        chk("connect_not_repeated", d_cond[0] + d_pulse[0], 0);
        chk("suspend_not_early", d_cond[1] + d_pulse[1], 0);
    end
endtask
