//============================================================================
// case_rx_maxlen.v — 满长包：64 字节净荷（整帧 67 字节）
//
// 因: 全速设备最大包长 64 字节，EP0/EP1/EP2 的 FIFO 也都按 64B 设计。这是
//     接收链路上最长的一条：位填充计数要挺过 64 个字节，帧缓冲要装下
//     PID + 64 净荷 + CRC16 = 67 字节。
// 变: 一帧内出 67 个 rx_valid，EOP 关帧。
// 果: ① 帧长恰 67 字节（PID + 64 + CRC16），不多不少；
//     ② 67 个字节逐字节等于参考值，含 CRC16 两字节的 MSB-first 落位；
//     ③ rx_error = 0；
//     ④ 净荷故意选长 1 串与长 0 串交替（0xFF/0x00/0xAA/0x55），把位填充
//        压到每 7 个 1 补一个 0 的最密处 —— 填充计数若在字节边界上漏算，
//        错位会一路累积到 CRC，第 2 条必然挂。
// 前后文窗口: 关帧后 20µs 无新帧。
//
// 交叉核对: exp_data_n 的逐字节 CRC（crc16_pay）对 8 字节以内必须等于既有的
//   crc16_tx，否则"67 字节都对"只能证明两边一起错。故本用例先比一次 8 字节。
//============================================================================
task case_rx_maxlen;
    integer i, c0;
    real    t0;
    begin
        attach_dev;
        chk_evt(0, 1, "connect_evt before max-length rx");

        // ---- 交叉核对: 8 字节以内两种 CRC 写法必须一致 ----
        set_pay(8'h12, 8'h34, 8'h56, 8'h78, 8'h9A, 8'hBC, 8'hDE, 8'hF0);
        chk(crc16_pay(8) === crc16_tx(8'h12, 8'h34, 8'h56, 8'h78,
                                      8'h9A, 8'hBC, 8'hDE, 8'hF0, 7'd8),
            "crc16_pay matches crc16_tx for 8 bytes");

        // ---- 64 字节净荷 ----
        for (i = 0; i < 64; i = i + 1) begin
            case (i % 4)
                0: pay[i] = 8'hFF;            // 8 连 1: 最密的位填充
                1: pay[i] = 8'h00;            // 8 连 0: 跨字节的跳变边界
                2: pay[i] = 8'hAA;
                default: pay[i] = 8'h55;
            endcase
        end

        $display("  [host sends a max-length DATA0: 64-byte payload]");
        t0 = $time;
        nrzi_lv = 1'b1;
        ones_cnt = 0;
        send_data_pay(`PID_TYPE_DATA0, 64, 4, -1, 0);
        drv_j(2000.0);
        wait_frames(1, 200000);

        exp_data_n(`PID_TYPE_DATA0, 64);
        chk_frame(1, 1'b0, "max-length DATA0: payload + CRC16 byte-exact");
        chk(hist_n[0] == 67, "frame length is 67 bytes (PID + 64 + CRC16)");
        $display("        frame bytes = %0d (exp 67), packet time = %0t ns",
                 hist_n[0], $time - t0);

        chk(n_rx_active_rise == 1, "one packet, one rx_active rise");

        #20000;
        chk(frame_cnt == 1, "no extra frame after the max-length packet");
        chk_evt(1, 0, "no usb_bus_rst");
        chk_evt(2, 0, "no suspend_evt");
        chk_evt(3, 0, "no resume_evt");

        if (errors == start_errs) $display("  PASS: phy_rx_maxlen");
        else $display("  FAIL: phy_rx_maxlen (%0d errors)", errors - start_errs);
    end
endtask
