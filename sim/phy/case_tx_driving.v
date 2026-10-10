//============================================================================
// case_tx_driving.v — 挂起中违约发包：旁路把总线压住，一个事件都不报
//
// 因: 总线已空转到挂起（suspended=1，bus_suspended 也跟着为 1）。契约要求挂起中
//     SIE 不得拉 tx_active，本用例**故意违约**：此时发起一个包。
// 变: 唤醒旁路在 tx_bit/tx_en 的 D 链上优先级最高，且它的挂起条件读的是 DUT 自己
//     bus_state 判出的 bus_suspended —— 挂起期间 tx_en 恒 0、tx_bit 恒 J，
//     包路径被压在下面，整包期间线上一动不动。
// 果: ① 发送期间线一直停在主机给的 idle J（line_state 恒 2'b10）；
//     ② resume_evt 一次都不来 —— 线上没有 K，也没有我们自己的驱动；
//     ③ bus_rst 也不来（连 SE0 都没上过线）；
//     ④ suspend_evt 保持挂起前的那 1 次，发完再等 3ms 也不重复
//        —— suspended 只由主机 K 或 usb_rst 清，发一包两者都不是；
//     ⑤ tx_done 照常出 1 次：旁路压的是线，不是 FSM。字节被 FSM 照单收下、
//        一位也没发出去，这是违约路径的代价（契约要求 SIE 不走到这里）。
// 前后文窗口: 挂起已确认起 → 发 1 字节 → 发完 20µs 内观察 → 再等 3ms。
//
// 取单字节包、且字节取 0xFC，是为了把发射路径上两条别的用法例走不到的支路带上:
//   ① 单字节包 → SYNC 移完那拍 `tx_last` 已经是 1，`S_SYNC` 直接进 `S_DATA_LAST`
//      （多字节包走的是 `S_SYNC → S_DATA`，那条路 `phy_tx_line` 已经走过）；
//   ② 0xFC 的 6 连 1 从 b2 起、第 6 个落在 b7，收尾填充不在 `S_DATA_LAST` 而是在
//      下一拍的 `S_EOP1` 自环里补（`phy_tx_line` 的末字节是另一种收尾形态）。
// 这两条支路在 FSM 上照常走到，与线发不发得出去无关，故字节取值仍按覆盖需要挑。
//============================================================================
task case_tx_driving;
    integer d0, g, bad_line;
    begin
        attach_dev;
        wait_evt(2, 1, 200000);               // 空转到挂起
        chk_evt(2, 1, "suspend_evt before transmit");

        $display("  [illegal transmit while suspended: bypass holds the wire]");
        tx_put(8'hFC);                        // 单字节包 + 末字节以 6 连 1 收尾
        d0 = n_tx_done;
        tx_start;
        g = 0;
        bad_line = 0;
        while ((n_tx_done < d0 + 1) && (g < 40000)) begin
            @(posedge ref_clk);
            if (line_state !== 2'b10) bad_line = bad_line + 1;
            g = g + 1;
        end
        tx_finish;
        chk(n_tx_done == d0 + 1, "tx_done fired once while suspended");
        chk(bad_line == 0, "wire stays at host idle J for the whole packet");
        chk(tx_en === 1'b0, "tx_en stays 0 while suspended");
        repeat (40) @(posedge ref_clk);

        chk_evt(3, 0, "no resume_evt while suspended and transmitting");
        chk_evt(1, 0, "no usb_bus_rst from our own EOP SE0");
        chk_evt(2, 1, "suspend_evt count unchanged");

        // 交高阻后线回主机的 idle J。suspended 这一位只由主机 K（resume）或 usb_rst 清，
        // 设备自己发一包既不是主机唤醒也不是复位，所以挂起标志留着、不再报第二次挂起。
        #3000000;
        chk_evt(2, 1, "still suspended: no second suspend_evt");
        chk_evt(3, 0, "still no resume_evt");
        chk_evt(1, 0, "still no usb_bus_rst");

        if (errors == start_errs) $display("  PASS: phy_tx_driving");
        else $display("  FAIL: phy_tx_driving (%0d errors)", errors - start_errs);
    end
endtask
