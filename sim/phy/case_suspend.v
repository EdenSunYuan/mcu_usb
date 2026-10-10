//============================================================================
// case_suspend.v — 挂起：连接后总线空闲 J 满 3ms
//
// 因: 插入后主机不给任何包，线保持 J。bus_state 的计数器在 J 上累加，
//     到 144000 个 ref 拍（3ms）时判 suspend_evt（suspended 由 0 置 1 后不再复判）。
// 变: 3ms 到点 → 出 1 个 suspend_evt 脉冲。
// 果: ① suspend_evt 恰 1 次、宽 1 个 clk12m 拍；
//     ② 之后再等 3ms 不重复（suspended 标志已置）；
//     ③ 期间 connect_evt 不再来、无 resume、无总线复位；
//     ④ 全程 clk12m 保持 12MHz（挂起不改变 rcv，仍由 dclk 供）。
// 前后文窗口: 连接后立即起，观察 3ms（到点）再 3ms（不重复）。
//
// 3ms 是全局最长的等待，本用例占仿真时间的大头；门限的 ±1 拍精度由
// busstate 单元测试的阈值扫描覆盖，这里只查"到点报一次、且只报一次"。
//============================================================================
task case_suspend;
    integer c0;
    begin
        attach_dev;
        chk_evt(0, 1, "connect_evt");

        $display("  [idle J for 3ms -> expect suspend_evt]");
        c0 = n_evt[2];
        wait_evt(2, c0 + 1, 200000);          // 3ms = 144000 ref 拍
        chk_evt(2, c0 + 1, "suspend_evt after 3ms idle J");
        chk((n_ref_rise > 0), "ref_clk alive");

        $display("  [idle J for another 3ms -> expect no repeat]");
        #3000000;
        chk_evt(2, c0 + 1, "suspend_evt not repeated");
        chk_evt(0, 1, "connect_evt still 1");
        chk_evt(3, 0, "no resume_evt");
        chk_evt(1, 0, "no usb_bus_rst");
        chk(line_state === 2'b10, "line still J");

        if (errors == start_errs) $display("  PASS: phy_suspend");
        else $display("  FAIL: phy_suspend (%0d errors)", errors - start_errs);
    end
endtask
