//============================================================================
// case_rx_usb_rst.v — core 复位从 PHY 唯一入口进得来：收包中途打软复位
//
// 因: 收包进行到净荷中段，上层（APB control）发一个宽 1 个 clk12m 周期的软复位脉冲；
//     TB 在这里把它与总线复位并成 usb_rst —— PHY 自己不并（phy_design.md §3），
//     所以这一根线要真的从端口进来，再分到 deserial 与 bus_state 两处。
// 变: deserial 里 usb_rst 与 rx_abort/tx_active 并成同一根 frame_clr，帧机当拍回
//     USB_IDLE；bus_state 的两个标志位被清，connected 落。
// 果: ① rx_active 立即落，那一段的字节数不足整包；
//     ② rx_error 保持 0（复位不是收错）；
//     ③ connected 落 → 线回 J 要重新判 connect（第二次 connect_evt）；
//     ④ 复位后立刻可用：再发一个好包能整包收齐、字节逐字节正确。
// 前后文窗口: 复位脉冲前已收 ≥1 字节，复位后 5µs 查字节数，再发好包观察最后一段。
//
// 与 case_rx_abort 的区别在路径：中止走 deserial 的 rx_abort 单根线，复位要从**层外**
// 经 usb_rst 端口进来再分到两个子模块。两根线接反、或 usb_rst 漏接到其中一个，
// 两条用例至少有一条会挂。包尾重新开出中间段的现象与 case_rx_abort 同源，见那边的说明。
//============================================================================
task case_rx_usb_rst;
    integer c0, nper;
    begin
        attach_dev;
        chk(sie_attached === 1'b1, "attached before swrst");

        $display("  [host sends DATA0, SWRST pulses mid-payload]");
        nrzi_lv = 1'b1;
        ones_cnt = 0;
        fork
            data0_packet_task(8'hFF, 8'hFF, 8'hFF, 8'hFF,
                              8'hFF, 8'hFF, 8'hFF, 8'hFF, 7'd8, 4, -1, 0);
            begin
                #5000;
                c0 = frame_cnt;
                pulse_swrst;                 // 宽 1 个 clk12m 周期
                repeat (12) @(posedge clk12m);
                chk(rx_active === 1'b0, "rx_active dropped right after usb_rst");
            end
        join
        chk(sie_attached === 1'b0, "usb_rst cleared attached (bus_state flags)");
        chk(frame_cnt == c0 + 1, "interrupted rx_active period was closed");
        chk(hist_n[c0 & 3] < 11, "interrupted period is short");
        chk(hist_err[c0 & 3] == 0, "usb_rst is not a receive error");
        $display("        interrupted period: %0d bytes, rx_error=%0b (full packet = 11)",
                 hist_n[c0 & 3], hist_err[c0 & 3]);

        drv_j(5000.0);
        chk_evt(0, 2, "second connect_evt after usb_rst re-attach");

        $display("  [then a good DATA0 is still received cleanly]");
        set_pay(8'h01, 8'h23, 8'h45, 8'h67, 8'h89, 8'hAB, 8'hCD, 8'hEF);
        nrzi_lv = 1'b1;
        ones_cnt = 0;
        data0_packet_task(8'h01, 8'h23, 8'h45, 8'h67,
                          8'h89, 8'hAB, 8'hCD, 8'hEF, 7'd8, 4, -1, 0);
        drv_j(2000.0);
        wait_frames(c0 + 2, 40000);
        nper = frame_cnt - c0;

        exp_data(`PID_TYPE_DATA0, 8);
        chk_frame(frame_cnt, 1'b0, "last period after usb_rst is the good DATA0");

        begin : tail_chk
            integer i, bad;
            bad = 0;
            for (i = c0 + 1; i < frame_cnt - 1; i = i + 1)
                if (hist_n[i & 3] != 0 || hist_err[i & 3] != 0) bad = 1;
            if (bad) begin
                $display("  ERR : tail period after usb_rst carries bytes or errors");
                errors = errors + 1;
            end else
                $display("  ok  : tail periods after usb_rst carry 0 bytes, no error");
        end

        dump_periods(nper);

        if (errors == start_errs) $display("  PASS: phy_rx_usb_rst");
        else $display("  FAIL: phy_rx_usb_rst (%0d errors)", errors - start_errs);
    end
endtask
