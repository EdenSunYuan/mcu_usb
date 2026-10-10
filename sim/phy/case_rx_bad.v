//============================================================================
// case_rx_bad.v — 物理检错必须在整层链路上冒出来，且不跨帧残留
//
// 口径: PHY 的 rx_error 只认**物理**错（位填充违规 / EOP 异常收尾）。
//   CRC 校验是 SIE 的事（`src/common/usb_crc16_byte.v` 在 usb_sie 里用），
//   所以坏 CRC 的包在 PHY 这一层必须"字节照收、错误不置位"——本用例不做这个。
//
// 因: 主机发一个截断包（data_noeop_packet_task）：SYNC+PID+8 字节净荷+CRC16 全部
//     正常发出，只是不发 EOP 的 SE0，直接回 idle J。按 deserial 的定稿行为
//     （sim/deserial/case_err_eop.v E2），线回 J 后 DATA 态的 idle-J 会凑出 7 连 1，
//     物理检错置起 rx_error，再靠 idle 探针自愈回 IDLE。
// 变: 帧机回 idle，rx_error 置起。
// 果: ① 帧照常关，字节流仍是 11 个（PID + 8 净荷 + 2 CRC16）且逐字节正确
//        —— 截断不吞字节，错误是靠标记而不是靠丢数据表达的；
//     ② rx_error = 1；
//     ③ 紧接一个好包，第 2 帧 rx_error 必须回 0（错误电平不跨帧残留）。
// 前后文窗口: 截断包关帧后立即发好包，两帧之间 gap 2µs。
//
// 第 3 条是对照：只查"坏包报错"会放过"rx_error 恒 1"的实现。
//============================================================================
task case_rx_bad;
    begin
        attach_dev;

        set_pay(8'h12, 8'h34, 8'h56, 8'h78, 8'h9A, 8'hBC, 8'hDE, 8'hF0);

        $display("  [host sends a truncated DATA0: body only, no EOP]");
        nrzi_lv = 1'b1;
        ones_cnt = 0;
        data_noeop_packet_task(`PID_TYPE_DATA0, 8'h12, 8'h34, 8'h56, 8'h78,
                               8'h9A, 8'hBC, 8'hDE, 8'hF0, 7'd8, 4, -1, 0);
        drv_j(3000.0);
        wait_frames(1, 40000);

        exp_data(`PID_TYPE_DATA0, 8);
        chk_frame(1, 1'b1, "truncated DATA0: bytes intact, rx_error=1");

        $display("  [then a good DATA0 -> rx_error must clear]");
        nrzi_lv = 1'b1;
        ones_cnt = 0;
        data0_packet_task(8'h12, 8'h34, 8'h56, 8'h78,
                          8'h9A, 8'hBC, 8'hDE, 8'hF0, 7'd8, 4, -1, 0);
        drv_j(2000.0);
        wait_frames(2, 40000);

        chk_frame(2, 1'b0, "good DATA0 -> rx_error back to 0");

        chk(n_rx_active_rise == 2, "two packets, two rx_active rises");
        chk_evt(1, 0, "no usb_bus_rst");
        chk_evt(2, 0, "no suspend_evt");

        if (errors == start_errs) $display("  PASS: phy_rx_bad");
        else $display("  FAIL: phy_rx_bad (%0d errors)", errors - start_errs);
    end
endtask
