//============================================================================
// case_unplug_susp.v — 挂起中拔出：长 SE0 走总线复位那条路，插回来重报 connect
//
// 因: 设备挂起后整条线还在主机手里，被拔掉时线被下拉成 SE0 —— 协议上这就是
//     总线复位信令，与主机主动复位无法区分。所以"拔出"与"复位"共用一条判据：
//     connected=1 下的长 SE0 → usb_bus_rst。
// 变: ① SE0 保持 ≥2.5µs → 出 usb_bus_rst；usb_rst = usb_bus_rst | swrst 进来，
//        清挂起标志、清附着；
//     ② 线回 J → 计数器重来，2.5µs 后判 connect，出第二次 connect_evt。
// 果: ① 挂起中的拔出照样出 usb_bus_rst，且**挂起标志被清**（bus_suspended 落 0）
//        —— 这一条是本用例的主判据，若总线复位没接进 bus_state，标志会留着，
//        后面第 ④ 条就会误报 resume；
//     ② 未插入期间长 SE0 不再重复报复位（connected 已清，判据要求 connected=1）；
//     ③ 插回后第二次 connect_evt、rcv 回 1；
//     ④ 插回后再驱 3µs K **不报** resume_evt —— 挂起标志真被清掉了，
//        K 只是线变了，不是唤醒。
// 前后文窗口: 挂起已确认 → SE0 3µs → 空转 100µs → 回 J 等 2.5µs 门限 → K 3µs → J 100µs。
//
// 与 phy_bus_rst 的分工: 那条从"已连接且活跃"的 J 上复位，本用例多走一段挂起，
//   专门盯"挂起标志与附着的清法"以及"拔出再插回"这个真实使用场景。
//============================================================================
task case_unplug_susp;
    integer c0;
    begin
        attach_dev;
        wait_evt(2, 1, 200000);
        chk_evt(2, 1, "suspend_evt before unplug");
        chk(u_dut.bus_suspended === 1'b1, "bus_suspended = 1 while suspended");

        $display("  [unplug while suspended: long SE0 -> usb_bus_rst]");
        drv_se0(3000.0);
        repeat (20) @(posedge ref_clk);
        chk_evt(1, 1, "usb_bus_rst on unplug while suspended");
        chk(sie_attached === 1'b0, "attached cleared by usb_rst");
        chk(rcv === 1'b0, "rcv = 0 after unplug");
        chk(u_dut.bus_suspended === 1'b0, "bus reset clears the suspend flag");

        // 换回 clk12s 后必须还在跑：静态 SE0 上 CDR 没有可锁的边沿
        c0 = n_clk12m_rise;
        repeat (400) @(posedge ref_clk);
        chk(n_clk12m_rise > c0, "clk12m still ticking on SE0 after unplug");

        $display("  [stay unplugged 100us: no repeats]");
        #100000;
        chk_evt(1, 1, "no second usb_bus_rst while unplugged");
        chk_evt(2, 1, "no second suspend_evt while unplugged");
        chk_evt(3, 0, "no resume_evt while unplugged");
        chk_evt(0, 1, "no connect_evt while line is SE0");

        $display("  [plug back in -> second connect_evt]");
        drv_j(3000.0);
        repeat (60) @(posedge ref_clk);
        chk_evt(0, 2, "second connect_evt after re-plug");
        chk(rcv === 1'b1, "rcv = 1 after re-plug");

        $display("  [3us K after re-plug is not a resume]");
        drv_k(3000.0);
        repeat (20) @(posedge ref_clk);
        chk_evt(3, 0, "re-plugged: 3us K is not resume_evt (flag was cleared)");
        drv_j(100000.0);
        chk_evt(3, 0, "no resume_evt afterwards either");
        chk_evt(2, 1, "still one suspend_evt (100us < 3ms)");
        chk(line_state === 2'b10, "line back to J");

        if (errors == start_errs) $display("  PASS: phy_unplug_susp");
        else $display("  FAIL: phy_unplug_susp (%0d errors)", errors - start_errs);
    end
endtask
