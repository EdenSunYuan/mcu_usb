//============================================================================
// case_tx_line.v — 设备发一包：握手、EOP 波形、以及"自驱期间不误判总线事件"
//
// 因: SIE 把 4 个字节（ACK 包的规模不够，用 4 字节的数据包）交给 tx_serial，
//     tx_active 拉起 → rcv 由 1 落 0（driving）→ clk_mux 从 dclk 换回 clk12s，
//     整包的位时序全部落在本地 12MHz 上；tx_en=1 期间总线由设备驱动。
// 变: 每字节取一次（tx_ready 握手，末字节带 tx_last），发完出 tx_done。
// 果: ① 整包 tx_ready 脉冲数 = 字节数；
//     ② tx_done 恰 1 次；
//     ③ EOP 的 SE0 段连续高电平最长 ≈ 2 个位时间（8 个 ref 拍，容 ±1 相位）——
//        这是 EOP 与总线复位（≥2.5µs = 120 拍）区分开的地方，差两个数量级；
//     ④ 整包期间 connect/suspend/resume/bus_rst 四个事件一个都不报：
//        tx_en 直连 bus_state 当 driving 把判据挡掉。若 driving 错接成 tx_active
//        或干脆没接，包里的 K 段与 EOP 的 SE0 会被当成 resume / 总线复位报出来。
// 前后文窗口: 连接后立即发，发完再等 20µs。
//
// 字节值: 0xFC → 0x03 → 0x00 → 0xFE。取值有两层考虑:
//   ① 顶层 tx_data[7:0] 每一位都要出现 0→1 与 1→0（TB 起手把 tx_data 放成 0x00），
//      否则顶层那一排 tx_data 端口会留下从未翻转的点；0x03 翻 b0/b1、0x00 翻回去、
//      0xFC 翻 b2..b7，来回复用三次就全覆盖。
//   ② 末字节取 0xFE: 0xFE 的 6 连 1 从 b1 起，第 6 个连 1 落在 b6，于是末字节那拍
//      `bit_stuff` 已拉高、`S_DATA_LAST` 原地自环一拍补 0（`tx_serial` 的尾填充路径）。
//      0x00/0xE1 那类收尾时计数不足 6，走不到这条支路；
//      另一种收尾形态（0xFC，第 6 个连 1 落在 b7）由 `phy_tx_driving` 的末字节覆盖。
//
// 半双工口径: tx_active 同时送到 deserial，收包帧机在整个发送期间被按在 idle，
// 所以本用例里 frame_cnt 必须保持 0（设备自己发的包不会被自己收下）。
//============================================================================
task case_tx_line;
    integer r0, d0, g;
    begin
        attach_dev;
        chk(rcv === 1'b1, "rcv = 1 before transmit (idle, dclk source)");

        $display("  [DUT transmits 4 bytes]");
        tx_put(8'hFC);                        // 让 tx_data 每一位都翻两个方向
        tx_put(8'h03);
        tx_put(8'h00);
        tx_put(8'hFE);                        // 末字节以 6 连 1 收尾 → 尾填充
        r0 = n_tx_ready;
        d0 = n_tx_done;
        tx_start;

        g = 0;                                // 等 tx_done（ref 拍超时）
        while ((n_tx_done < d0 + 1) && (g < 40000)) begin
            @(posedge ref_clk);
            g = g + 1;
        end
        tx_finish;
        repeat (40) @(posedge ref_clk);

        chk(n_tx_done == d0 + 1, "tx_done fired exactly once");
        chk((n_tx_ready - r0) == 4, "tx_ready handshaked once per byte");
        $display("        tx_ready = %0d, tx_done = %0d, se0_run_max = %0d ref cyc",
                 n_tx_ready - r0, n_tx_done - d0, se0_run_max);
        chk(se0_run_max >= 7 && se0_run_max <= 9,
            "EOP SE0 width ~2 bit times (8 ref cycles)");

        chk_evt(0, 1, "connect_evt only once");
        chk_evt(1, 0, "device-driven packet must not look like a bus reset");
        chk_evt(2, 0, "no suspend_evt");
        chk_evt(3, 0, "no resume_evt");
        chk(frame_cnt == 0, "deserial stays idle while we transmit (half duplex)");
        chk(rcv === 1'b1, "rcv back to 1 after transmit");
        chk(tx_en === 1'b0, "driver released after packet");

        #20000;
        chk_evt(1, 0, "no usb_bus_rst after the packet either");

        if (errors == start_errs) $display("  PASS: phy_tx_line");
        else $display("  FAIL: phy_tx_line (%0d errors)", errors - start_errs);
    end
endtask
