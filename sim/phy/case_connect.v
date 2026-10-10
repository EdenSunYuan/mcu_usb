//============================================================================
// case_connect.v — 插入：SE0 → J，一次 connect_evt，时钟源从 clk12s 换到 dclk
//
// 因: 冷 SE0 上把线拉到 J（全速 idle）。这一下同时做三件事：
//     (a) line_s（deserial 里 ref 域采的那一份）出现 10→00→10 跳变；
//     (b) CDR 的 DPLL 被这一次跳变踢起来，dclk 开始自由运转；
//     (c) bus_state 的计数器清零后重新计数，J 保持到 2.5µs（120 ref 拍）判 connect。
// 变: connect_evt 起 → rcv 由 0 变 1 → clk_mux 从 clk12s 切到 dclk。
// 果: ① connect_evt 恰 1 次、宽 1 个 clk12m 拍；
//     ② 之后 100µs 内 clk12m 上升沿仍是 ~1200（dclk 同样 12MHz，换源不掉速）；
//     ③ 3ms 内不重报 connect（connected 已置）、也还没到挂起；
//     ④ line_state 恒 J。
// 前后文窗口: 从冷 SE0 拉 J 起，到 connect 后 100µs（< 3ms 挂起门限、> 2.5µs 连接门限）。
//
// 这条是 line_s 接线的直接判据：若把 rxdp/rxdn 直连给 bus_state（绕过 deserial 的
// 采样寄存器），跳变检测的相位就与判据计数错开一拍，2.5µs 门限会差 1 拍而扫描边界时暴露；
// 本用例只查"能不能报"，边界精度由 busstate 单元测试保证。
//============================================================================
task case_connect;
    integer c0;
    begin
        chk_evt(0, 0, "connect_evt before plug-in");
        chk(n_dclk_rise == 0, "dclk parked before plug-in");

        $display("  [plug in: SE0 -> J]");
        attach_dev;                       // 驱 J + 等 connect_evt + 稳 60 拍

        chk_evt(0, 1, "connect_evt after plug-in");
        chk(rcv === 1'b1, "rcv = 1 after connect (clk12m <- dclk)");
        chk(n_dclk_rise > 0, "dclk started by the plug-in transition");
        $display("        dclk edges = %0d", n_dclk_rise);

        c0 = n_clk12m_rise;
        #100000;
        chk((n_clk12m_rise - c0) >= 1170 && (n_clk12m_rise - c0) <= 1230,
            "clk12m still 12MHz after switching to dclk");
        $display("        clk12m edges in 100us = %0d (exp ~1200)",
                 n_clk12m_rise - c0);

        chk_evt(0, 1, "connect_evt not repeated");
        chk_evt(2, 0, "no suspend_evt within 3ms");
        chk_evt(1, 0, "no usb_bus_rst while idle J");
        chk(line_state === 2'b10, "line_state = J while idle");
        chk(ns_bad == 0, "line_state tracks the wire every ref cycle");

        if (errors == start_errs) $display("  PASS: phy_connect");
        else $display("  FAIL: phy_connect (%0d errors)", errors - start_errs);
    end
endtask
