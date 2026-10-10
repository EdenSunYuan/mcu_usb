//============================================================================
// bs_self_drive — 自己驱总线时四条判据全被挡住（driving = tx_en 组合直连）
//
// 因①: 软件请求远程唤醒 → SIE 拉 tx_en，收发器自己驱 K 1ms（自环把 K 读回线上）
// 变①: driving(=tx_en) 直连进四条判据，同时清计数器
// 果①: 1ms 自驱 K 里不出任何事件（否则自己发的 K 会把自己唤醒）
//
// 因②: 发送包尾 EOP → 自驱 SE0 104µs
// 变②: 同上被 driving 挡住；撤驱动后立刻回 J
// 果②: 不出 usb_bus_rst（自己发的 EOP SE0 不该报总线复位）
//
// 判据: 两个窗口内判据与脉冲都为 0；自驱 K 后 suspended 保持 1
// 前文窗口: 先连接 + 空闲 3ms 进挂起（这样 rsm_cond 的前置成立，门控才有意义）
// 后文窗口: 撤驱动后主机 K ≥2.5µs 仍能唤醒（判据没被自驱动搞坏）
//============================================================================
task case_self_drive;
    begin
        $display("  因①: tx_en=1 期间线被自己驱成 K 1ms（远程唤醒的自环）");
        $display("  变①: driving 直连进四条判据，把判据与计数器一起压住");
        $display("  果①: 窗口内无任何事件，挂起状态不变");
        drive(1, 0, 300);                    // 连接
        drive(1, 0, 144100);                 // 空闲 3ms 进挂起
        chk("pre_suspended", u_dut.suspended, 1);
        win_begin;
        tx_en = 1'b1;
        drive(0, 1, 50000);                  // 自驱 K 1ms
        win_end;
        chk("self_k_no_cond", d_cond[0] + d_cond[1] + d_cond[2] + d_cond[3], 0);
        chk("self_k_no_pulse", d_pulse[0] + d_pulse[1] + d_pulse[2] + d_pulse[3], 0);
        chk("still_suspended_after_self_k", u_dut.suspended, 1);

        $display("  因②: tx_en=1 期间线被自己驱成 SE0 104µs（包尾 EOP）");
        win_begin;
        tx_en = 1'b1;
        drive(0, 0, 5000);                   // 自驱 SE0
        tx_en = 1'b0;
        drive(1, 0, 30);                     // 撤驱动立刻回 idle J
        win_end;
        chk("self_se0_no_cond", d_cond[0] + d_cond[1] + d_cond[2] + d_cond[3], 0);
        chk("self_se0_no_pulse", d_pulse[0] + d_pulse[1] + d_pulse[2] + d_pulse[3], 0);

        $display("  后文窗口: 撤驱动后主机 K 400 拍 —— 唤醒判据照常成立");
        win_begin;
        drive(0, 1, 400);
        win_end;
        chk_chain("host_k_after_drive_off", d_cond[3], d_mid[3], d_pulse[3]);
        chk("suspended_cleared_after_wakeup", u_dut.suspended, 0);
    end
endtask
