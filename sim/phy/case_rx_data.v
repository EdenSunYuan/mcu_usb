//============================================================================
// case_rx_data.v — 主机连发 OUT token + DATA0，两帧字节流都逐字节复现
//
// 因: 一个完整的 OUT 事务 = token 包 + 数据包，两包之间有包间 gap（idle J）。
//     净荷选 8 字节高密度（0xFF/0xFE/0xFC 混排），压位填充跨字节与长 1 串。
// 变: deserial 出两段独立的 rx_active（每包一段），各自关包记一帧。
// 果: ① frame_cnt = 2，rx_active 上升沿恰好 2 次；
//     ② 第 1 帧 3 字节 = token 参考值，第 2 帧 11 字节 = PID + 8 净荷 + 2 CRC16；
//     ③ 两帧 rx_error 全 0；
//     ④ CRC16 那两字节按 MSB-first 落位（先发的 c16[15] 落在第一个 CRC 字节 bit0），
//        与净荷的 LSB-first 位序相反 —— 接错一位这里就挂。
// 前后文窗口: 两包之间 gap 2µs，关第二帧后 20µs 无新帧。
//
// 这条同时压出"包缓冲不能跨包残留"：第 2 帧必须干净地从 fb_n=0 起算，
// 若 deserial 的字节计数没在第一帧 EOP 时清干净，第 2 帧会带上第 1 帧的尾巴。
//============================================================================
task case_rx_data;
    begin
        attach_dev;
        chk_evt(0, 1, "connect_evt before rx");

        set_pay(8'hFF, 8'hFE, 8'hFC, 8'h00, 8'hAA, 8'h55, 8'h80, 8'h01);

        $display("  [host sends OUT token + DATA0 (8 bytes)]");
        nrzi_lv = 1'b1;
        ones_cnt = 0;
        out_packet_task(7'h03, 4'h1, 4, -1, 0);
        drv_j(2000.0);
        nrzi_lv = 1'b1;
        ones_cnt = 0;
        data0_packet_task(8'hFF, 8'hFE, 8'hFC, 8'h00,
                          8'hAA, 8'h55, 8'h80, 8'h01, 7'd8, 4, -1, 0);
        drv_j(2000.0);
        wait_frames(2, 40000);

        exp_token(`PID_TYPE_OUT, 7'h03, 4'h1);
        chk_frame(1, 1'b0, "OUT token");

        exp_data(`PID_TYPE_DATA0, 8);
        chk_frame(2, 1'b0, "DATA0 payload+CRC16");

        chk(n_rx_active_rise == 2, "rx_active rose once per packet");
        chk_evt(1, 0, "no usb_bus_rst");
        chk_evt(2, 0, "no suspend_evt");

        if (errors == start_errs) $display("  PASS: phy_rx_data");
        else $display("  FAIL: phy_rx_data (%0d errors)", errors - start_errs);
    end
endtask
