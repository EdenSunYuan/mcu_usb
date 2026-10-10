//============================================================================
// case_reset_default.v — 冷启动：电缆没插（长 SE0），整层能不能自己转起来
//
// 因: 上电后 D+/D- 都被下拉，线上恒 SE0 且**一次跳变都没有**。
//     此时 SIE 还没附着 → rcv = attached & ~driving = 0 → clk_mux 选 clk12s
//     （ref_clk ÷ 4 自己分出来的），clk12m 有沿；CDR 的 DPLL 没被任何跳变踢，
//     停在锁存态 → dclk 恒 0。
// 变: 等 100µs（1200 个标称 clk12m 周期）。
// 果: ① clk12m 上升沿 ≈ 1200（±2%），高频是 clk12m 在跑、低就是 clk12s 起振失败；
//     ② dclk 上升沿 = 0（没有任何跳变踢 DPLL）；
//     ③ 四个事件全 0 —— 没附着谈不上 connection，SE0 在没有 connected 时不判总线复位；
//     ④ 总线复位门限 2.5µs 远小于这 100µs，若"未附着也判复位"这里必然多报。
// 前后文窗口: 复位序列结束（mon_arm=1）起，到 100µs 后。
//
// 这条同时锁住"上电能不能起振"这个死锁风险：若 rcv 复位初值为 1（选 dclk），
// clk12m 会恒 0，SIE 与 bus_state 的事件跨域段全都没沿，整层死透。
//============================================================================
task case_reset_default;
    integer c0;
    begin
        $display("  [冷 SE0 保持 100us]");
        c0 = n_clk12m_rise;
        #100000;

        chk((n_clk12m_rise - c0) >= 1170 && (n_clk12m_rise - c0) <= 1230,
            "clk12m running at 12MHz on cold SE0 (clk12s source)");
        $display("        clk12m edges in 100us = %0d (exp ~1200)",
                 n_clk12m_rise - c0);

        chk(n_dclk_rise == 0, "dclk parked (no line transition yet)");
        $display("        dclk edges = %0d", n_dclk_rise);

        chk_evt(0, 0, "connect_evt");
        chk_evt(1, 0, "usb_bus_rst");
        chk_evt(2, 0, "suspend_evt");
        chk_evt(3, 0, "resume_evt");

        chk(line_state === 2'b00, "line_state = SE0 while cable unplugged");
        chk(ns_bad == 0, "line_state tracks the wire every ref cycle");
        chk(rcv === 1'b0, "rcv = 0 (not attached)");

        if (errors == start_errs) $display("  PASS: phy_reset_default");
        else $display("  FAIL: phy_reset_default (%0d errors)", errors - start_errs);
    end
endtask
