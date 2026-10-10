//============================================================================
// case_bus_rst.v — 总线复位：连接后长 SE0 → usb_bus_rst，出去并进 usb_rst 清附着
//
// 因: 已连接的设备遇到 SE0 保持 ≥2.5µs（120 ref 拍）—— 主机复位信令，也是拔出
//     （拔掉后线被下拉成 SE0）在协议上走的那条路。bus_state 的 rst_cond 要求
//     connected=1，所以未插入时的长 SE0 不报（见 phy_reset_default）。
// 变: usb_bus_rst 脉冲出到本层之外；TB 在此处把它与软复位并成 usb_rst
//     （PHY 自己不并，见 phy_design.md §3），usb_rst 清 SIE 侧模型里的 sie_attached。
// 果: ① usb_bus_rst 恰 1 次、宽 1 个 clk12m 拍；
//     ② 紧接着 rcv 由 1 落 0 → clk12m 换回 clk12s，且换完仍在跑（此刻总线是静态
//        SE0，CDR 没有可锁的边沿；若时钟源还留在 dclk 上，整层就开始看运气）；
//     ③ 附着清掉后，线回 J 会重新判 connect → 第二次 connect_evt；
//     ④ 全程 suspend/resume 一次都不报（长 SE0 不是 J 也不是 K）。
// 前后文窗口: 从已连接空闲 J 起，SE0 3µs（> 2.5µs），再回 J 等 100µs（< 3ms）。
//============================================================================
task case_bus_rst;
    integer c0;
    begin
        attach_dev;
        chk_evt(0, 1, "connect_evt before bus reset");

        $display("  [connected, then SE0 for 3us -> expect usb_bus_rst]");
        drv_se0(3000.0);
        repeat (20) @(posedge ref_clk);
        chk_evt(1, 1, "usb_bus_rst after SE0 >= 2.5us while connected");
        chk(sie_attached === 1'b0, "attached cleared by usb_rst (TB ORs rst)");
        chk(rcv === 1'b0, "rcv = 0 after usb_rst");

        // 换回 clk12s 后必须还在跑：若 rcv 落不下去，静态 SE0 上就没有备用时钟了。
        c0 = n_clk12m_rise;
        repeat (200) @(posedge ref_clk);
        chk(n_clk12m_rise > c0, "clk12m still ticking on SE0 after usb_rst");

        $display("  [back to J -> expect a second connect_evt]");
        drv_j(3000.0);
        repeat (60) @(posedge ref_clk);
        chk_evt(0, 2, "second connect_evt after re-attach");
        chk(rcv === 1'b1, "rcv = 1 after re-attach");

        chk_evt(2, 0, "no suspend_evt");
        chk_evt(3, 0, "no resume_evt");

        if (errors == start_errs) $display("  PASS: phy_bus_rst");
        else $display("  FAIL: phy_bus_rst (%0d errors)", errors - start_errs);
    end
endtask
