//============================================================================
// case_setup.v — SETUP 事务的特例分支 (§2.8 独立一条)
//
// 契约: SETUP 不查 stall / nak / 序列位 —— 好包且 DATA0 且打到 EP0 就无条件
//   ACK, 并把 toggle[EP0] 置 1 (收方向序列位复位)。其余情况一律不应答:
//   PID 不是 DATA0、端点点号不是 EP0、包坏。
//   末尾验控制读/写来回的 toggle[EP0] 序列 (1 → 0 → 1)。
//============================================================================

task case_setup;
    integer start_errs, sup0, rec0;
    begin
        start_errs = errors;
        $display("== sie_setup: SETUP 强制 ACK + toggle[EP0] 置 1 ==");

        set_cfg(7'd5, 3'b000, 3'b000, 2'b00);
        sup0 = ev_setup;

        //--------------------------------------------------------------------
        // 1) 标准 8 字节 SETUP → ACK + setup_recv + toggle[EP0] 置 1
        //--------------------------------------------------------------------
        pl_fill(8, 8'hB0);
        pkt_token(`PID_TYPE_SETUP, 7'd5, 4'd0, 1'b0);
        chk_pr(7'd5, 4'd0, `PID_SETUP, 2'd1, 1'b0, "SETUP token 字段");
        pkt_data(1'b0, 8, 1'b0);
        idle_cycles(4);
        chk_pr_nx(`PID_DATA0, 2'd2, 1'b0, "SETUP 数据包字段");
        chk_len(8, "SETUP dat_len");
        resp_chk_one(`PID_ACK, "SETUP");
        chk_evt(ev_setup - sup0, 1, "setup_recv");
        chk_toggle(3'b001, "SETUP 后 toggle[EP0]");
        wait_buf_ready(10);
        chk_buf_cnt(8, "SETUP buf_cnt");
        rec0 = drain_n;
        drain_all;
        chk_drain_pl(rec0, "SETUP 净荷");

        //--------------------------------------------------------------------
        // 2) SETUP + DATA1 → 不应答 (SETUP 的数据阶段只认 DATA0)
        //--------------------------------------------------------------------
        sup0 = ev_setup;
        pl_fill(4, 8'hC0);
        pkt_token(`PID_TYPE_SETUP, 7'd5, 4'd0, 1'b0);
        pkt_data(1'b1, 4, 1'b0);
        idle_cycles(4);
        resp_chk_none("SETUP + DATA1");
        chk_evt(ev_setup - sup0, 0, "SETUP + DATA1 无 setup_recv");
        chk_buf_ready(1'b0, "SETUP + DATA1 不写缓冲");
        chk_toggle(3'b001, "SETUP + DATA1 不动 toggle");

        //--------------------------------------------------------------------
        // 3) SETUP 坏 CRC → 不应答 (pkt_bad 先把它挡掉)
        //--------------------------------------------------------------------
        sup0 = ev_setup;
        pkt_token(`PID_TYPE_SETUP, 7'd5, 4'd0, 1'b0);
        pkt_data(1'b0, 4, 1'b1);
        idle_cycles(4);
        resp_chk_none("SETUP 坏 CRC");
        chk_evt(ev_setup - sup0, 0, "SETUP 坏 CRC 无 setup_recv");

        //--------------------------------------------------------------------
        // 4) SETUP 在 halt 下仍无条件 ACK (不查 stall)
        //--------------------------------------------------------------------
        set_cfg(7'd5, 3'b001, 3'b001, 2'b00);      // EP0 halt + 忙
        sup0 = ev_setup;
        pkt_token(`PID_TYPE_SETUP, 7'd5, 4'd0, 1'b0);
        pkt_data(1'b0, 8, 1'b0);
        idle_cycles(4);
        resp_chk_one(`PID_ACK, "halt/忙 下的 SETUP");
        chk_evt(ev_setup - sup0, 1, "halt 下 setup_recv");
        chk_buf_ready(1'b1, "halt 下 SETUP 照收");
        drain_all;
        set_cfg(7'd5, 3'b000, 3'b000, 2'b00);

        //--------------------------------------------------------------------
        // 5) SETUP 打到非 EP0 端点 → 不应答 (SETUP 只对控制端点有意义)
        //--------------------------------------------------------------------
        sup0 = ev_setup;
        pl_fill(4, 8'hD0);
        pkt_token(`PID_TYPE_SETUP, 7'd5, 4'd1, 1'b0);
        pkt_data(1'b0, 4, 1'b0);
        idle_cycles(4);
        resp_chk_none("SETUP 打到 EP1");
        chk_evt(ev_setup - sup0, 0, "非 EP0 无 setup_recv");
        chk_buf_ready(1'b0, "非 EP0 SETUP 不写缓冲");
        chk_toggle(3'b001, "非 EP0 SETUP 不动 toggle[EP0]");

        //--------------------------------------------------------------------
        // 6) SETUP 之后控制传输的数据阶段: toggle[EP0]=1 → 期望 DATA1
        //--------------------------------------------------------------------
        pl_fill(4, 8'hE0);
        pkt_token(`PID_TYPE_OUT, 7'd5, 4'd0, 1'b0);
        pkt_data(1'b1, 4, 1'b0);                   // 匹配 (toggle[EP0]=1)
        idle_cycles(4);
        resp_chk_one(`PID_ACK, "SETUP 后 DATA1 匹配");
        chk_toggle(3'b000, "收下 DATA1 后 toggle[EP0]");
        wait_buf_ready(10);
        rec0 = drain_n;
        drain_all;
        chk_drain_pl(rec0, "控制数据阶段净荷");

        // 再一回: 现在期望 DATA0
        pl_fill(4, 8'hF0);
        pkt_token(`PID_TYPE_OUT, 7'd5, 4'd0, 1'b0);
        pkt_data(1'b0, 4, 1'b0);
        idle_cycles(4);
        resp_chk_one(`PID_ACK, "再一回 DATA0 匹配");
        chk_toggle(3'b001, "再收下后 toggle[EP0]");
        drain_all;

        if (errors == start_errs)
            $display("  PASS: case_setup");
        else
            $display("  FAIL: case_setup (%0d errors)", errors - start_errs);
    end
endtask
