//============================================================================
// bs_latency_phase — 事件延迟随 clk12m 相位扫描
//
// 因: 判据落在哪一拍与 clk12m 上升沿的相位没有固定关系（clk12m 由 dclk 或 clk12s 切出）
// 变: 把触发事件的那次线变化整体平移 p 拍（p = 0..3 扫遍 clk12m 的四个相位），
//     判据起拍于是落在四个不同相位上
// 果: 延迟随相位在 [1, 4] ref 拍之间变化，上界 = 一个 clk12m 周期 + 判据到标志位那 1 拍
// 判据: 每个相位下四类事件各出 1 个判据 / 1 个脉冲；四类的延迟都落在 [1, 4] ref 拍；
//       脉冲宽都是 1 个 clk12m 拍；判据总数 = 脉冲总数
// 前文窗口: 每次迭代都是独立的一次事件。connect 要未附着，故每轮先拿 usb_rst 清一次附着
//           （usb_rst 是 core 复位，本模块不自己产生，见 case_bs_usb_rst）
// 后文窗口: win_end 的 drain 让脉冲走完再切下一个相位
//============================================================================
task case_latency_phase;
    integer p, lo, hi;
    begin
        $display("  因: 触发线变化平移 0..3 拍，扫遍 clk12m 的四个相位");
        $display("  变: 判据起拍落在不同相位 → 两拍同步链采到它的时刻跟着变");
        $display("  果: 延迟随相位变化，上界固定");

        // ---- connect：未附着 → J。每轮先 usb_rst 清附着，再让 SE0 长度带 p 拍偏移 ----
        lo = 9999;  hi = 0;
        for (p = 0; p < 4; p = p + 1) begin
            win_begin;
            usb_rst = 1'b1;
            drive(0, 0, 4);
            usb_rst = 1'b0;
            drive(0, 0, 600 + p);            // SE0 静置（长度带相位偏移；未附着，不出 rst_cond）
            drive(1, 0, 300);                // J 6.25µs → con_cond
            win_end;
            chk_chain("phase_connect", d_cond[0], d_mid[0], d_pulse[0]);
            $display("    p=%0d: connect 延迟 %0d ref 拍", p, lat_last[0]);
            if (lat_last[0] < lo) lo = lat_last[0];
            if (lat_last[0] > hi) hi = lat_last[0];
        end
        chk("phase_connect_lat_in_1_4", (lo >= 1) && (hi <= 4), 1);
        $display("    connect 延迟范围 %0d..%0d ref 拍", lo, hi);

        // ---- bus_rst（走翻转位那条路）：已附着 → SE0，相位由前面 J 的长度平移 ----
        lo = 9999;  hi = 0;
        for (p = 0; p < 4; p = p + 1) begin
            win_begin;
            drive(1, 0, 200 + p);            // J 静置（长度带相位偏移；★ 偏移必须在窗口内，
                                             //   窗口外的偏移会被 win_begin 的 drain 对齐掉）
            drive(0, 0, 300);                // SE0 ≥2.5µs → rst_cond
            win_end;
            chk_chain("phase_bus_rst", d_cond[2], d_mid[2], d_pulse[2]);
            $display("    p=%0d: bus_rst 延迟 %0d ref 拍", p, lat_last[2]);
            if (lat_last[2] < lo) lo = lat_last[2];
            if (lat_last[2] > hi) hi = lat_last[2];
        end
        chk("phase_bus_rst_lat_in_1_4", (lo >= 1) && (hi <= 4), 1);
        $display("    bus_rst 延迟范围 %0d..%0d ref 拍", lo, hi);

        // ---- suspend：已附着未挂起 → 空闲 3ms。每轮先用 SE0 把挂起清掉 ----
        lo = 9999;  hi = 0;
        for (p = 0; p < 4; p = p + 1) begin
            win_begin;
            drive(0, 0, 200 + p);            // SE0（清 suspended 走 rst_cond）+ 相位偏移，都在窗口内
            drive(1, 0, 144100);             // J 空闲到 3ms → sus_cond
            win_end;
            chk_chain("phase_suspend", d_cond[1], d_mid[1], d_pulse[1]);
            $display("    p=%0d: suspend 延迟 %0d ref 拍", p, lat_last[1]);
            if (lat_last[1] < lo) lo = lat_last[1];
            if (lat_last[1] > hi) hi = lat_last[1];
        end
        chk("phase_suspend_lat_in_1_4", (lo >= 1) && (hi <= 4), 1);
        $display("    suspend 延迟范围 %0d..%0d ref 拍", lo, hi);

        // ---- resume：挂起中 → 主机 K，相位由前面 SE0 的长度平移 ----
        lo = 9999;  hi = 0;
        for (p = 0; p < 4; p = p + 1) begin
            drive(0, 0, 300);                // SE0 清挂起
            drive(1, 0, 300);                // 回 J 重新附着
            drive(1, 0, 144100);             // 空闲 3ms 再进挂起
            win_begin;
            drive(1, 0, 200 + p);            // J 静置（相位偏移在窗口内）
            drive(0, 1, 400);                // 主机 K ≥2.5µs → rsm_cond
            win_end;
            chk_chain("phase_resume", d_cond[3], d_mid[3], d_pulse[3]);
            $display("    p=%0d: resume 延迟 %0d ref 拍", p, lat_last[3]);
            if (lat_last[3] < lo) lo = lat_last[3];
            if (lat_last[3] > hi) hi = lat_last[3];
        end
        chk("phase_resume_lat_in_1_4", (lo >= 1) && (hi <= 4), 1);
        $display("    resume 延迟范围 %0d..%0d ref 拍", lo, hi);

        // ---- 四个相位下都不许出现多脉冲 / 宽脉冲，且判据数 = 脉冲数 ----
        chk("phase_all_width_1",
            wmax[0] + wmax[1] + wmax[2] + wmax[3], 4);
        chk("phase_all_cond_equals_pulse",
            (n_cond[0] + n_cond[1] + n_cond[2] + n_cond[3]) -
            (n_pulse[0] + n_pulse[1] + n_pulse[2] + n_pulse[3]), 0);
    end
endtask
