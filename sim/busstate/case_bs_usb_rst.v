//============================================================================
// bs_usb_rst — usb_rst 清两个标志位，但绝不动两个翻转位（不造假事件）
//
// 因: usb_rst 来一拍（软复位，或集成侧把总线复位并进来的 core 复位）
// 变: cnt 清零；connected / suspended 清 0；rst_tgl / rsm_tgl 不吃 usb_rst
// 果: 四个输出无脉冲。★ 若 usb_rst 清了翻转位，clk12m 侧的同步链会看见一次跳变，
//     凭空多出一个 usb_bus_rst / resume_evt —— 本用例就是钉这条
// 判据: 清 cnt / 清两标志位；翻转位保持；窗口内无脉冲；清后再来 J 2.5µs 重报 connect
// 前文窗口: 先制造一次总线复位与一次唤醒，让两个翻转位都停在 1（非零态才验得出"没被清"）
// 后文窗口①: 线还在 J → 重新附着，重报 connect_evt
// 后文窗口②: 已附着态再来一次 usb_rst → 附着跟着作废（状态机 ATT→未附着）
//============================================================================
task case_usb_rst;
    reg rst_tgl_save, rsm_tgl_save;
    begin
        $display("  因: 前窗先把两个翻转位都置到 1（一次总线复位 + 一次唤醒）");
        drive(1, 0, 300);                    // 插入
        drive(0, 0, 400);                    // 总线复位 → rst_tgl = 1
        drive(1, 0, 600);
        chk("pre_rst_tgl_1", u_dut.rst_tgl, 1);
        drive(1, 0, 144100);                 // 空闲 3ms 进挂起
        chk("pre_suspended", u_dut.suspended, 1);
        drive(0, 1, 400);                    // 主机 K → 唤醒 → rsm_tgl = 1
        chk("pre_rsm_tgl_1", u_dut.rsm_tgl, 1);
        drive(1, 0, 144100);                 // 再进挂起
        chk("pre_suspended_2nd", u_dut.suspended, 1);

        $display("  因: usb_rst 一拍；变: 清 cnt 与两个标志位；果: 无脉冲、翻转位不变");
        rst_tgl_save = u_dut.rst_tgl;
        rsm_tgl_save = u_dut.rsm_tgl;
        win_begin;
        usb_rst = 1'b1;
        drive(1, 0, 4);
        chk("usb_rst_clears_cnt", u_dut.cnt, 0);
        chk("usb_rst_clears_connected", u_dut.connected, 0);
        chk("usb_rst_clears_suspended", u_dut.suspended, 0);
        usb_rst = 1'b0;
        drive(1, 0, 4);
        win_end;
        chk("usb_rst_no_pulse", d_pulse[0] + d_pulse[1] + d_pulse[2] + d_pulse[3], 0);
        chk("usb_rst_keeps_rst_tgl", u_dut.rst_tgl, rst_tgl_save);
        chk("usb_rst_keeps_rsm_tgl", u_dut.rsm_tgl, rsm_tgl_save);

        $display("  后文窗口①: 线还在 J → 2.5µs 后重新附着");
        win_begin;
        drive(1, 0, 400);
        win_end;
        chk_chain("reconnect_after_usb_rst", d_cond[0], d_mid[0], d_pulse[0]);
        chk("connected_after_reconnect", u_dut.connected, 1);

        $display("  后文窗口②: 已附着态再来一次 usb_rst → 附着作废");
        win_begin;
        usb_rst = 1'b1;
        drive(1, 0, 4);
        usb_rst = 1'b0;
        drive(1, 0, 4);
        win_end;
        chk("usb_rst_at_att_clears_connected", u_dut.connected, 0);
        chk("usb_rst_at_att_no_pulse", d_pulse[0] + d_pulse[1] + d_pulse[2] + d_pulse[3], 0);
    end
endtask
