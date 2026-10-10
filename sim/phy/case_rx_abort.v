//============================================================================
// case_rx_abort.v — 接收中止：rx_abort 中途拉高，整层立刻收干净且不留后遗症
//
// 因: 主机发一个 8 字节净荷的 DATA0（净荷填满 0xFF，位填充把字节时间拉长，
//     好让中止落在净荷中段），设备侧在收包一半时把 rx_abort 拉高
//     —— 这是 SIE 发现净荷超出端点上限时的动作。
// 变: deserial 里 rx_abort 与 tx_active/usb_rst 并成同一根 frame_clr：
//     帧机当拍回 USB_IDLE、位流水线冻结、rx_valid 停摆。
// 果: ① rx_active 在中止后 ≤2 个 clk12m 拍内落；
//     ② 这一段落的字节数严格少于整包（11 = PID+8+CRC16），说明是真被打断而不是收完；
//     ③ rx_error 保持 0 —— frame_clr 是"强退"，不是物理检错；
//     ④ 随后线回 idle J，再发一个好包能整包收齐、字节逐字节正确。
// 前后文窗口: 中止点落在净荷中段（#5000 ≈ 60 bit 时间，已过 SYNC+PID），
//   中止后 5µs 内查这一段落的字节数，再发包观察最后一段。
//
// 口径: 本 TB 把 rx_active 的一段高电平叫"一段"。frame_clr 会让 rx_active 提前落，
//   所以在外部看来**也会**关一段，只是字节数不足。第 4 条才是真正查"不留后遗症"的：
//   帧机若停在非 idle 态，下一个包的 SYNC 会被当成续包，字节数会多出上一段的残骸。
//
// ★ 实测到的一段中间段（本用例首次把"中止后包尾仍在线上"这件事跑出来，
//   sim/deserial 的 E3 是中止后立刻把线收回 J，没覆盖这一种）:
//   中止只是把帧机打回 IDLE，主机并不知道、包尾照发。帧机在 IDLE 上看到数据 0 就
//   重新进 SEEK，包尾的数据里凑够 ≥4 个 0 加一个 1 就重新进 USB_DATA，
//   于是多出**一段 0 字节、无错误**的 rx_active。对 PHY 而言这不算错（无字节、无错误、
//   下一个好包照收），但它是一个"SIE 必须忽略"的接口事实：收到没有 SYNC/PID 支撑的
//   rx_active 段不能当成新包。已记入 phy_verification.md 的接口项。
//============================================================================
task case_rx_abort;
    integer c0, nper;
    begin
        attach_dev;

        $display("  [host starts a DATA0, DUT aborts mid-payload]");
        nrzi_lv = 1'b1;
        ones_cnt = 0;
        fork
            data0_packet_task(8'hFF, 8'hFF, 8'hFF, 8'hFF,
                              8'hFF, 8'hFF, 8'hFF, 8'hFF, 7'd8, 4, -1, 0);
            begin
                #5000;
                c0 = frame_cnt;
                rx_abort = 1'b1;
                repeat (12) @(posedge clk12m);
                chk(rx_active === 1'b0, "rx_active dropped right after rx_abort");
                rx_abort = 1'b0;
            end
        join

        chk(frame_cnt == c0 + 1, "aborted rx_active period was closed");
        chk(hist_n[c0 & 3] < 11, "aborted period is short (did not run to completion)");
        chk(hist_err[c0 & 3] == 0, "rx_abort is a graceful stop: rx_error stays 0");
        $display("        aborted period: %0d bytes, rx_error=%0b (full packet = 11)",
                 hist_n[c0 & 3], hist_err[c0 & 3]);

        drv_j(5000.0);

        $display("  [then a good DATA0 is still received cleanly]");
        set_pay(8'hA5, 8'h5A, 8'h0F, 8'hF0, 8'h11, 8'h22, 8'h33, 8'h44);
        nrzi_lv = 1'b1;
        ones_cnt = 0;
        data0_packet_task(8'hA5, 8'h5A, 8'h0F, 8'hF0,
                          8'h11, 8'h22, 8'h33, 8'h44, 7'd8, 4, -1, 0);
        drv_j(2000.0);
        wait_frames(c0 + 2, 40000);
        nper = frame_cnt - c0;                // 中止之后一共关了几段

        exp_data(`PID_TYPE_DATA0, 8);
        chk_frame(frame_cnt, 1'b0, "last period after abort is the good DATA0");

        // 中间那些段（包尾在线上重新开出来的）必须一律 0 字节、无错误
        begin : tail_chk
            integer i, bad;
            bad = 0;
            for (i = c0 + 1; i < frame_cnt - 1; i = i + 1)
                if (hist_n[i & 3] != 0 || hist_err[i & 3] != 0) bad = 1;
            if (bad) begin
                $display("  ERR : tail period after rx_abort carries bytes or errors");
                errors = errors + 1;
            end else
                $display("  ok  : tail periods after rx_abort carry 0 bytes, no error");
        end

        chk_evt(1, 0, "no usb_bus_rst");
        chk_evt(2, 0, "no suspend_evt");
        dump_periods(nper);

        if (errors == start_errs) $display("  PASS: phy_rx_abort");
        else $display("  FAIL: phy_rx_abort (%0d errors)", errors - start_errs);
    end
endtask
