//============================================================================
// bs_bus_rst — 已附着后 SE0 ≥2.5µs 报 usb_bus_rst，长 SE0 里只报一次
//
// 因: 已附着后主机在总线上驱 SE0 保持 10ms（总线复位信令）
// 变: cnt 数到 120 拍时 cnt_2p5u=1，加 line_se0、~driving、connected → rst_cond=1
//     → rst_tgl 翻一位 → 两拍同步链新旧不同 → usb_bus_rst 出 1 拍
// 果: usb_bus_rst 恰好一个脉冲；10ms 长 SE0 一路保持不再报（判据只此一拍）
// 判据: 三处计数都 == 1；脉冲宽 1 个 clk12m 拍；connected 仍为 1
// 前文窗口: 先插入连接
// 后文窗口: ① 长 SE0 再保持 10ms 不重复；② 线回 J 2.5µs 不重报 connect
//   （connected 由集成侧的 usb_rst 清，模块内不自己清——见设计报告 §2.5）
//============================================================================
task case_bus_rst;
    begin
        $display("  因: 已附着后主机驱 SE0 保持 10ms");
        $display("  变: cnt 数到 120 拍 → rst_cond=1 → rst_tgl 翻一位 → 同步链 XOR 出脉冲");
        $display("  果: usb_bus_rst 一个脉冲；connected 模块内不动");
        drive(1, 0, 300);                    // 前窗: 先连接
        win_begin;
        drive(0, 0, 480000);                 // 10ms SE0
        win_end;

        chk_chain("bus_rst_chain", d_cond[2], d_mid[2], d_pulse[2]);
        chk("usb_bus_rst_width_1clk12m", wmax[2], 1);
        chk("bus_rst_no_other_cond", d_cond[0] + d_cond[1] + d_cond[3], 0);
        chk("bus_rst_no_other_pulse", d_pulse[0] + d_pulse[1] + d_pulse[3], 0);
        chk("module_keeps_connected", u_dut.connected, 1);
        $display("  延迟: 判据 → 脉冲 %0d..%0d ref 拍", lat_min[2], lat_max[2]);

        $display("  后文窗口①: 长 SE0 继续 10ms，不许重复报");
        win_begin;
        drive(0, 0, 480000);
        win_end;
        chk("bus_rst_once_in_long_se0", d_cond[2] + d_pulse[2], 0);

        $display("  后文窗口②: 线回 J 6.25µs —— 附着还在，不许重报 connect");
        win_begin;
        drive(1, 0, 300);
        win_end;
        chk("no_reconnect_on_j", d_cond[0] + d_pulse[0], 0);
        chk("connected_kept", u_dut.connected, 1);
    end
endtask
