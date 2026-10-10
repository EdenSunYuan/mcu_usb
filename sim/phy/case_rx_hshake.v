//============================================================================
// case_rx_hshake.v — 单字节握手包：EOP 紧跟在 PID 后面关帧
//
// 因: 握手包（ACK/NAK/STALL）是结构最短的包 —— SYNC + PID + EOP，没有数据字段
//     也没有 CRC。对 deserial 的帧机来说，"进 DATA 态后第一个字节收完就是包尾"，
//     与 token/data 那种"要等 EOP 定界"的收尾路径不是同一段。
// 变: 整包只出 1 个 rx_valid，紧接的 EOP 把帧关掉。
// 果: ① 帧长恰 1 字节，值 = 线上 PID（ACK → 0xD2）；
//     ② rx_error = 0（短包不是异常收尾）；
//     ③ rx_active 上升沿每包 1 次；
//     ④ 连发三个不同握手包（ACK/NAK/STALL），三帧各自干净，字节不串
//        —— 单字节帧最容易串的就是"把上一帧的尾巴带进来"或"把包间 idle J
//        当成续包"，所以第 4 条按三个包连查。
// 前后文窗口: 每包之间 gap 2µs，第三包关帧后 20µs 无新帧。
//
// 口径: PHY 只做物理层，ACK 是"主机发的"还是"设备发的"它不管。本用例让主机
//   发这三个包，考的是接收链路对最短包的处理，不是事务语义。
//============================================================================
task case_rx_hshake;
    begin
        attach_dev;
        chk_evt(0, 1, "connect_evt before handshake rx");

        $display("  [host sends ACK / NAK / STALL, one byte each]");
        nrzi_lv = 1'b1;
        ones_cnt = 0;
        handshake_packet_task(`PID_TYPE_ACK, 4, -1, 0);
        drv_j(2000.0);
        nrzi_lv = 1'b1;
        ones_cnt = 0;
        handshake_packet_task(`PID_TYPE_NAK, 4, -1, 0);
        drv_j(2000.0);
        nrzi_lv = 1'b1;
        ones_cnt = 0;
        handshake_packet_task(`PID_TYPE_STALL, 4, -1, 0);
        drv_j(2000.0);
        wait_frames(3, 60000);

        exp_hshake(`PID_TYPE_ACK);
        chk_frame(1, 1'b0, "ACK handshake");

        exp_hshake(`PID_TYPE_NAK);
        chk_frame(2, 1'b0, "NAK handshake");

        exp_hshake(`PID_TYPE_STALL);
        chk_frame(3, 1'b0, "STALL handshake");

        chk(n_rx_active_rise == 3, "three handshake packets, three rx_active rises");

        #20000;
        chk(frame_cnt == 3, "no extra frame after the handshakes");
        chk_evt(1, 0, "no usb_bus_rst");
        chk_evt(2, 0, "no suspend_evt");
        chk_evt(3, 0, "no resume_evt");

        if (errors == start_errs) $display("  PASS: phy_rx_hshake");
        else $display("  FAIL: phy_rx_hshake (%0d errors)", errors - start_errs);
    end
endtask
