//============================================================================
// case_oversize.v — 长度护栏 rx_abort (§2.6 / §4.9)
//
// 覆盖: 字节数越过本端点净荷上限 → 立刻拉 rx_abort (回 deserial 中止本包),
//   但**不置 rx_error** (那是物理层的)、不应答、不写缓冲; 且 rx_abort 必须随
//   rx_active 落干净 —— 留着会把下一个包一起毙掉 (它在 deserial 那边是 frame_clr).
//   上限按端点查表: EP0 = 8, EP1/EP2 = 64。
//============================================================================

task case_oversize;
    integer start_errs, ab0, bad0, rec0;
    begin
        start_errs = errors;
        $display("== sie_oversize: 长度护栏 rx_abort (EP0 8B / EP1 64B) ==");

        set_cfg(7'd5, 3'b000, 3'b000, 2'b00);

        //--------------------------------------------------------------------
        // 1) EP0 上限 8: 发 9 字节净荷 (总 12 字节 > 11) → abort
        //--------------------------------------------------------------------
        ab0 = ev_abort; bad0 = ev_bad;
        pl_fill(9, 8'h13);
        pkt_token(`PID_TYPE_OUT, 7'd5, 4'd0, 1'b0);
        pkt_data(1'b0, 9, 1'b0);
        idle_cycles(6);
        chk_evt(ev_abort - ab0, 1, "EP0 超 1 字节 rx_abort");
        chk_evt(ev_bad - bad0, 1, "超长包 ep_rx_bad");
        if (rx_error !== 1'b0) begin
            $display("    FAIL: 超长包不该置 rx_error");
            errors = errors + 1;
        end else $display("    OK  : 超长包不置 rx_error");
        resp_chk_none("EP0 超长包");
        chk_buf_ready(1'b0, "超长包不写缓冲");
        chk_tstate(F_IDLE, "超长包后回空闲");

        //--------------------------------------------------------------------
        // 2) 紧跟一个好包 → rx_abort 已落干净, 照收不误
        //    (若 abort 残留, 净荷写口与 CRC 使能都被门控掉, 这一包必然收不下)
        //--------------------------------------------------------------------
        if (rx_abort !== 1'b0) begin
            $display("    FAIL: 包尾后 rx_abort 仍为 1");
            errors = errors + 1;
        end else $display("    OK  : 包尾后 rx_abort 已落");
        pl_fill(8, 8'h23);
        pkt_token(`PID_TYPE_OUT, 7'd5, 4'd0, 1'b0);
        pkt_data(1'b0, 8, 1'b0);
        idle_cycles(4);
        resp_chk_one(`PID_ACK, "abort 之后的好包");
        chk_toggle(3'b001, "abort 之后好包收下");
        wait_buf_ready(10);
        chk_buf_cnt(8, "abort 之后 buf_cnt");
        rec0 = drain_n;
        drain_all;
        chk_drain_pl(rec0, "abort 之后净荷");

        //--------------------------------------------------------------------
        // 3) EP1 上限 64: 发 68 字节 (裸包造数, 反正走不到 CRC) → abort
        //--------------------------------------------------------------------
        ab0 = ev_abort;
        pkt_token(`PID_TYPE_OUT, 7'd5, 4'd1, 1'b0);
        pkt_raw(pid_byte(`PID_TYPE_DATA0), 67, 8'hAA);
        idle_cycles(6);
        chk_evt(ev_abort - ab0, 1, "EP1 超上限 rx_abort");
        resp_chk_none("EP1 超长包");
        chk_buf_ready(1'b0, "EP1 超长包不写缓冲");

        //--------------------------------------------------------------------
        // 4) 恰好 64 字节 (总 67 = 上限) → 不该 abort, 正常收下
        //--------------------------------------------------------------------
        ab0 = ev_abort;
        pl_fill(64, 8'h33);
        pkt_token(`PID_TYPE_OUT, 7'd5, 4'd1, 1'b0);
        pkt_data(1'b0, 64, 1'b0);
        idle_cycles(4);
        chk_evt(ev_abort - ab0, 0, "满包不 abort");
        resp_chk_one(`PID_ACK, "满包");
        wait_buf_ready(10);
        chk_buf_cnt(64, "满包 buf_cnt");
        rec0 = drain_n;
        drain_all;
        chk_drain_pl(rec0, "满包净荷");

        if (errors == start_errs)
            $display("  PASS: case_oversize");
        else
            $display("  FAIL: case_oversize (%0d errors)", errors - start_errs);
    end
endtask
