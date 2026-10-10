//============================================================================
// bs_two_resets — 两次总线复位各出一个脉冲（翻转通知不会两翻相消）
//
// 因: 已附着后 SE0 ≥2.5µs（第 1 次复位）→ 回 J 一段 → 再 SE0 ≥2.5µs（第 2 次）
// 变: rst_tgl 先 0→1，再 1→0；两拍同步链用的是"新旧不同"（异或），两个方向都认
// 果: 两次各出一个 usb_bus_rst，三处计数累计都是 2，翻转位回到 0
// 判据: 每个窗口三处计数都 == 1；两次之间无事件；累计判据数 = 累计脉冲数 = 2
// 前文窗口: 先插入连接
//============================================================================
task case_two_resets;
    begin
        $display("  因: 两次总线复位（中间隔 600 拍空闲 J）");
        $display("  变: rst_tgl 翻两次：0→1、1→0；异或对两个方向都出脉冲");
        $display("  果: 两个 usb_bus_rst，累计三处计数都是 2");
        drive(1, 0, 300);                    // 插入
        win_begin;
        drive(0, 0, 400);                    // 第 1 次复位
        win_end;
        chk_chain("bus_rst_1", d_cond[2], d_mid[2], d_pulse[2]);

        win_begin;
        drive(1, 0, 600);                    // 中间空闲
        win_end;
        chk("no_event_between_resets", d_cond[2] + d_pulse[2], 0);

        win_begin;
        drive(0, 0, 400);                    // 第 2 次复位
        win_end;
        chk_chain("bus_rst_2", d_cond[2], d_mid[2], d_pulse[2]);

        chk("two_resets_counts_all_2",
            n_cond[2] + n_mid[2] + n_pulse[2], 6);
        chk("rst_tgl_back_to_0", u_dut.rst_tgl, 0);
    end
endtask
