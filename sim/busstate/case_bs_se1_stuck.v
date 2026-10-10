//============================================================================
// bs_se1_stuck — SE1 持续（两线同时为高）不报任何事件
//
// 因: 两线同时为高保持 10ms。规范里 SE1 只是 J/K 交叉的瞬间，真持续说明前端坏了
// 变: SE1 不落进 J/K/SE0 任一分类，四条判据的线状态项全不成立；
//     计数上界取"非 J 态"那条（2.5µs），cnt 数到 121 后停住
// 果: 不出任何事件
// 判据: 无判据、无脉冲；cnt==121；未附着
// 前文窗口: 复位后直接进 SE1（未附着）
//============================================================================
task case_se1_stuck;
    begin
        $display("  因: 两线同时为高（SE1）持续 10ms");
        $display("  变: SE1 不落进 J/K/SE0，四条判据全不成立；cnt 停在 2.5µs 上界 121");
        $display("  果: 无任何事件");
        win_begin;
        drive(1, 1, 480000);                 // 10ms SE1
        win_end;
        chk("se1_no_cond", d_cond[0] + d_cond[1] + d_cond[2] + d_cond[3], 0);
        chk("se1_no_pulse", d_pulse[0] + d_pulse[1] + d_pulse[2] + d_pulse[3], 0);
        chk("se1_cnt_at_2p5u_top", u_dut.cnt, 121);
        chk("se1_not_connected", u_dut.connected, 0);
    end
endtask
