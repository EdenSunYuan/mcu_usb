//============================================================================
// case_resume.v — 被动唤醒：挂起中主机驱 K ≥2.5µs
//
// 因: 挂起态（connected=1, suspended=1）下主机把线拉到 K。K 是数据态的电平，
//     但挂起标志在，bus_state 判的是 resume 而不是"线变了"。
// 变: K 保持到 2.5µs（120 ref 拍）→ 出 resume_evt，同时 suspended 落。
// 果: ① resume_evt 恰 1 次、宽 1 个 clk12m 拍；
//     ② resume 后 100µs 内不再报（K 已撤、suspended 已落，回 J 后重新起 3ms 计时）；
//     ③ suspend_evt 仍是 1 次（这 100µs 远不到 3ms）；
//     ④ 全程 rcv 保持 1（主机在驱、设备没驱），clk12m 仍由 dclk 供。
// 前后文窗口: 挂起已确认起，K 保持 3µs（> 2.5µs 门限），观察窗口 100µs（< 3ms）。
//
// 对照：设备自己驱的 K（远程唤醒那段）走的是 tx_en 挡判据那条路，见 case_tx_driving。
//============================================================================
task case_resume;
    integer c0;
    begin
        attach_dev;
        wait_evt(2, 1, 200000);
        chk_evt(2, 1, "suspend_evt before resume");
        chk(rcv === 1'b1, "rcv = 1 while suspended and host idle");

        $display("  [host drives K for 3us while suspended -> expect resume_evt]");
        drv_k(3000.0);
        repeat (20) @(posedge ref_clk);       // 让脉冲过去、事件跨域落地
        chk_evt(3, 1, "resume_evt after host K >= 2.5us");
        chk(rcv === 1'b1, "rcv still 1 (host driving, we are not)");

        $display("  [back to idle J for 100us -> expect no repeat]");
        drv_j(100000.0);
        chk_evt(3, 1, "resume_evt not repeated");
        chk_evt(2, 1, "suspend_evt still 1");
        chk_evt(1, 0, "no usb_bus_rst");
        chk(line_state === 2'b10, "line back to J");

        if (errors == start_errs) $display("  PASS: phy_resume");
        else $display("  FAIL: phy_resume (%0d errors)", errors - start_errs);
    end
endtask
