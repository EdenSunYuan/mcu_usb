//============================================================================
// case_tx_rx_turn.v — 半双工往返：收 → 发 → 收，换向两次后链路还接得上
//
// 因: 真实事务是收发包交替的（主机 OUT token → 设备应答 → 主机送数据）。
//     换向时 rcv 翻一次：收发器把 clk12m 从 dclk 换到 clk12s（发送期用本地
//     12MHz），发完再换回 dclk（接收期用恢复时钟）。
// 变: ① 收到 OUT token 后拉起 tx_active → rcv 落 0 → clk12m 换源；
//     ② 发完 tx_active 落 → rcv 回 1 → 换回 dclk；
//     ③ 主机紧接着发 DATA0。
// 果: ① 整段 rcv 恰落 1 次、起 1 次（换向两次，不多不少）；
//     ② 设备自己发的包不被自己收下（frame_cnt 在发送期间不动）；
//     ③ 换回 dclk 后主机的 DATA0 仍整包收齐、逐字节对、rx_error=0
//        —— 这是本用例的核心：CDR 停在收 token 时的相位上，换向期间没有
//        可锁的跳变（我们发的时候 rxdp/rxdn 不动），回来还要能接住新包；
//     ④ 整段的 clk12m 沿数与流逝时间相配（12MHz ±5%），收发两段都没掉速。
// 前后文窗口: token 关帧后 gap 2µs → 发 2 字节 → gap 2µs → DATA0。
//   时钟窗口从发 DATA0 前起算，跨过整包到关帧后，覆盖换向边界。
//
// 为什么单发一包不够（phy_tx_line 只发不收、phy_rx_data 只收不发）:
//   两处都存在时，"换回 dclk 之后收不到"这类接缝错误只在往返里露头。
//============================================================================
task case_tx_rx_turn;
    integer r0, d0, c0, f0, rf0, rr0, g, dx, ex;
    real    t0;
    begin
        attach_dev;
        chk_evt(0, 1, "connect_evt before turnaround");

        // ---- 段 1: 主机发 OUT token（接收相） ----
        $display("  [host sends OUT token]");
        nrzi_lv = 1'b1;
        ones_cnt = 0;
        out_packet_task(7'h05, 4'h2, 4, -1, 0);
        drv_j(2000.0);
        wait_frames(1, 40000);

        exp_token(`PID_TYPE_OUT, 7'h05, 4'h2);
        chk_frame(1, 1'b0, "turn: OUT token received");
        chk(rcv === 1'b1, "turn: rcv = 1 in receive phase");

        // ---- 段 2: 设备发 2 字节应答包（发送相） ----
        $display("  [DUT answers with a 2-byte packet]");
        f0  = frame_cnt;
        rf0 = n_rcv_fall;
        rr0 = n_rcv_rise;
        tx_put(8'h5A);
        tx_put(8'h3C);
        r0 = n_tx_ready;
        d0 = n_tx_done;
        tx_start;
        g = 0;
        while ((n_tx_done < d0 + 1) && (g < 40000)) begin
            @(posedge ref_clk);
            g = g + 1;
        end
        tx_finish;
        repeat (40) @(posedge ref_clk);

        chk(n_tx_done == d0 + 1, "turn: tx_done fired exactly once");
        chk((n_tx_ready - r0) == 2, "turn: tx_ready handshaked once per byte");
        chk((n_rcv_fall - rf0) == 1, "turn: rcv fell exactly once (dclk -> clk12s)");
        chk((n_rcv_rise - rr0) == 1, "turn: rcv rose exactly once (clk12s -> dclk)");
        chk(rcv === 1'b1, "turn: rcv back to 1 after transmit");
        chk(tx_en === 1'b0, "turn: driver released after the packet");
        chk(frame_cnt == f0, "turn: own packet not self-received (half duplex)");
        chk(se0_run_max >= 7 && se0_run_max <= 9,
            "turn: EOP SE0 ~2 bit times (8 ref cycles)");

        // ---- 段 3: 主机紧接着发 DATA0，必须整包收齐 ----
        $display("  [host sends DATA0 right after our packet]");
        set_pay(8'hA5, 8'h5A, 8'h0F, 8'hF0,
                8'h11, 8'h22, 8'h33, 8'h44);
        nrzi_lv = 1'b1;
        ones_cnt = 0;
        c0 = n_clk12m_rise;
        t0 = $time;
        data0_packet_task(8'hA5, 8'h5A, 8'h0F, 8'hF0,
                          8'h11, 8'h22, 8'h33, 8'h44, 7'd8, 4, -1, 0);
        drv_j(2000.0);
        wait_frames(f0 + 1, 40000);

        exp_data(`PID_TYPE_DATA0, 8);
        chk_frame(frame_cnt, 1'b0, "turn: DATA0 received after turnaround");

        // 整段（含换向边界）clk12m 必须还是 12MHz：沿数 / 流逝时间 ±5%
        dx = n_clk12m_rise - c0;
        ex = (($time - t0) * 12) / 1000;      // 12MHz，时间单位 1ns
        $display("        tx_rx window: %0d clk12m edges over %0t ns (exp ~%0d)",
                 dx, ($time - t0), ex);
        chk((dx * 100 >= ex * 95) && (dx * 100 <= ex * 105),
            "turn: clk12m stays 12MHz across the turnaround");

        chk(n_rx_active_rise == 2, "turn: rx_active rose once per received packet");
        chk_evt(1, 0, "turn: no usb_bus_rst");
        chk_evt(2, 0, "turn: no suspend_evt");
        chk_evt(3, 0, "turn: no resume_evt");
        chk(rcv === 1'b1, "turn: ends in receive phase");

        if (errors == start_errs) $display("  PASS: phy_tx_rx_turn");
        else $display("  FAIL: phy_tx_rx_turn (%0d errors)", errors - start_errs);
    end
endtask
