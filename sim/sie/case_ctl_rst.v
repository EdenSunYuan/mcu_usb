//============================================================================
// case_ctl_rst.v — rcv 策略 · 附着 · core 复位 (§1.3 / §2.5)
//
// 契约:
//   · rcv = attached & ~driving, 复位后必须为 0 (CDR 未锁时 dclk 常 0, 若 rcv
//     初值为 1 则 clk12m 恒 0, SIE 自己都起不了振)
//   · connect_evt 置 attached, 总线复位/软复位走的 usb_rst 清附着
//   · usb_rst 清: 事务态机 / turn_cnt / toggle / 包缓冲 / 附着; 复位后能立刻
//     正常收包 (不是"清完就废")
//============================================================================

task case_ctl_rst;
    integer start_errs, rec0;
    begin
        start_errs = errors;
        $display("== sie_ctl_rst: rcv 策略 / 附着 / usb_rst 清状态 ==");

        //--------------------------------------------------------------------
        // 1) 复位后: 未附着 → rcv = 0
        //--------------------------------------------------------------------
        chk_rcv(1'b0, "复位后 rcv");

        //--------------------------------------------------------------------
        // 2) connect_evt (插上) → attached 置起 → rcv = 1 (clk12m 切到 dclk)
        //--------------------------------------------------------------------
        pulse_connect_evt;
        idle_cycles(3);
        chk_rcv(1'b1, "附着后 rcv");

        //--------------------------------------------------------------------
        // 3) 攒出一整套"该被清掉"的状态: toggle[EP1]=1 + 缓冲满 + 数据阶段中
        //--------------------------------------------------------------------
        set_cfg(7'd5, 3'b000, 3'b000, 2'b00);
        pl_fill(8, 8'h15);
        pkt_token(`PID_TYPE_OUT, 7'd5, 4'd1, 1'b0);
        pkt_data(1'b0, 8, 1'b0);
        idle_cycles(4);
        resp_chk_one(`PID_ACK, "复位前收下的包");
        chk_toggle(3'b010, "复位前 toggle");
        chk_buf_cnt(8, "复位前 buf_cnt");
        pkt_token(`PID_TYPE_OUT, 7'd5, 4'd1, 1'b0);   // 停在数据阶段
        chk_tstate(F_DWAIT, "复位前事务态");

        //--------------------------------------------------------------------
        // 4) usb_rst 脉冲 → 上面全部清零, 附着一起作废 (rcv 回 0)
        //--------------------------------------------------------------------
        pulse_usb_rst;
        idle_cycles(3);
        chk_tstate(F_IDLE, "usb_rst 后事务态");
        chk_toggle(3'b000, "usb_rst 后 toggle");
        chk_buf_ready(1'b0, "usb_rst 后 buf_ready");
        if (buf_cnt !== 7'd0) begin
            $display("    FAIL: usb_rst 后 buf_cnt=%0d, 期望 0", buf_cnt);
            errors = errors + 1;
        end else $display("    OK  : usb_rst 后 buf_cnt=0");
        chk_rcv(1'b0, "usb_rst 后 rcv (附着作废)");
        if (dut_turn_cnt !== 5'd1) begin
            $display("    FAIL: usb_rst 后 turn_cnt=%0d, 期望 1", dut_turn_cnt);
            errors = errors + 1;
        end else $display("    OK  : usb_rst 后 turn_cnt=1");

        //--------------------------------------------------------------------
        // 5) 复位后重新附着 → 立刻能正常收包 (toggle 也回到了 0)
        //--------------------------------------------------------------------
        pulse_connect_evt;
        idle_cycles(3);
        chk_rcv(1'b1, "重新附着 rcv");
        pl_fill(4, 8'h25);
        pkt_token(`PID_TYPE_OUT, 7'd5, 4'd1, 1'b0);
        pkt_data(1'b0, 4, 1'b0);                   // toggle 已清 0 → 期望 DATA0
        idle_cycles(4);
        resp_chk_one(`PID_ACK, "复位后重新收包");
        chk_toggle(3'b010, "复位后收包翻 toggle");
        wait_buf_ready(10);
        chk_buf_cnt(4, "复位后 buf_cnt");
        rec0 = drain_n;
        drain_all;
        chk_drain_pl(rec0, "复位后净荷");

        if (errors == start_errs)
            $display("  PASS: case_ctl_rst");
        else
            $display("  FAIL: case_ctl_rst (%0d errors)", errors - start_errs);
    end
endtask
