//============================================================================
// case_susp_wkup.v — 远程唤醒旁路：bus_state 判出的挂起 + sie_wkup 直通到线驱动
//
// 因: 挂起态下 SIE 把 sie_wkup 拉高（软件写了 wkup_req）。tx_serial 的旁路挂在
//     tx_bit/tx_en 的 D 链尾、优先级最高，两个条件是「总线挂起」+「唤醒请求」；
//     挂起那一位读的是 DUT 自己 bus_state 判出的 bus_suspended。
// 变: tx_en 由 0 变 1、tx_bit 取 K —— 注意这条路径不经过 FSM，不摆 tx_data、
//     不发 SYNC/填充/EOP，也不参与 tx_ready/tx_done 握手。
// 果: ① 未挂起时单拉 sie_wkup 线上什么都不动（旁路没武装，本用例新增的一段）；
//     ② 挂起后 sie_wkup 拉起，线上读出 K（line_state = 2'b01）；
//     ③ tx_en = 1（驱动器真的在驱）；
//     ④ 设备侧同时把 rcv 拉 0（driving = tx_active | (sie_susp & sie_wkup)），
//        时钟换回 clk12s —— 这是 SIE 侧策略，本 TB 现算，其中 sie_susp 是
//        TB 里 SIE 自己那份挂起标志（DUT 不读它）；
//     ⑤ 撤掉 sie_wkup 后 tx_en 落回 0、线交回主机（回 idle J）；
//     ⑥ 全程 tx_ready/tx_done 一个都不来（唤醒不是包），四个总线事件也不报
//        —— 唤醒期间设备自己在驱，driving 同样挡掉判据。
// 前后文窗口: 未挂起时试拉 40 拍 → 挂起已确认 → 驱 K 100µs → 撤 100µs。
//
// 这段 K 是"软件自知、总线尚未恢复"的那半段，按设计不置 resume 标志；
// 主机接管后驱的那 ≥20ms K 才是 resume_evt 的来源，已由 case_resume 覆盖。
//============================================================================
task case_susp_wkup;
    integer r0, d0;
    begin
        attach_dev;

        // ---- 段 0: 还没挂起，单拉 sie_wkup 不该驱 K ----
        // 旁路读 DUT 自己的 bus_suspended；此刻它还是 0（连接后只过了几微秒）。
        // 这一段是本次改动（挂起态改读源）的直接判据：若错接成 TB 的 sie_susp
        // 或者干脆少了挂起这一项，这里就会冒出 K。
        $display("  [not suspended yet: sie_wkup alone must not drive K]");
        sie_wkup = 1'b1;
        repeat (40) @(posedge ref_clk);
        chk(tx_en === 1'b0, "wakeup request must not drive before suspend");
        chk(line_state === 2'b10, "line stays idle J before suspend");
        sie_wkup = 1'b0;
        repeat (40) @(posedge ref_clk);

        wait_evt(2, 1, 200000);
        chk_evt(2, 1, "suspend_evt before remote wakeup");

        r0 = n_tx_ready;
        d0 = n_tx_done;

        $display("  [suspended + sie_wkup=1 -> line K]");
        sie_susp = 1'b1;                      // TB 侧 SIE 的挂起标志：只为了让 rcv 也跟着落 0
        sie_wkup = 1'b1;
        repeat (40) @(posedge ref_clk);
        chk(tx_en === 1'b1, "tx_en asserted by the wakeup bypass");
        chk(line_state === 2'b01, "line driven to K during remote wakeup");
        chk(rcv === 1'b0, "rcv = 0 while we drive K (clk12m <- clk12s)");

        #100000;
        chk(tx_en === 1'b1, "K held while sie_wkup is high");
        chk(n_tx_ready == r0 && n_tx_done == d0,
            "wakeup bypass must not touch tx_ready/tx_done handshake");
        chk_evt(3, 0, "self-driven K is not resume_evt");
        chk_evt(1, 0, "no usb_bus_rst");
        chk_evt(2, 1, "suspend_evt unchanged during wakeup");

        $display("  [drop sie_wkup -> line released back to the host]");
        sie_wkup = 1'b0;
        repeat (40) @(posedge ref_clk);
        chk(tx_en === 1'b0, "tx_en released after sie_wkup drops");
        // sie_susp 仍为 1，但 wkup 落了：driving 的两项都要求成立才为 1
        chk(rcv === 1'b1, "rcv back to 1 (no longer driving)");
        #100000;
        chk_evt(3, 0, "still no resume_evt (host has not taken over)");
        chk(line_state === 2'b10, "line back to host idle J");

        sie_susp = 1'b0;

        if (errors == start_errs) $display("  PASS: phy_susp_wkup");
        else $display("  FAIL: phy_susp_wkup (%0d errors)", errors - start_errs);
    end
endtask
