//============================================================================
// case_addr_stray.v — 地址过滤与杂散包
//
// 覆盖: 设备地址失配（含坏 CRC5 的 token、端点点号越界）一律"静默忽略";
//   没有 token 前导的数据包 / 握手包（杂散包）什么都不做;
//   设备地址经 2-FF 准静态同步链换进本域后立即生效（§2.12）。
//============================================================================

task case_addr_stray;
    integer start_errs, bad0, done0, rec0;
    begin
        start_errs = errors;
        $display("== sie_addr_stray: 地址失配 / 杂散包 / 地址同步 ==");

        set_cfg(7'd5, 3'b000, 3'b000, 2'b00);
        bad0 = ev_bad; done0 = ev_done;

        //--------------------------------------------------------------------
        // 1) 地址失配 (设备 5, token 打到 3) → token 与数据包都静默
        //--------------------------------------------------------------------
        pl_fill(4, 8'h14);
        pkt_token(`PID_TYPE_OUT, 7'd3, 4'd1, 1'b0);
        pkt_data(1'b0, 4, 1'b0);
        idle_cycles(4);
        resp_chk_none("地址失配");
        chk_buf_ready(1'b0, "地址失配不写缓冲");

        //--------------------------------------------------------------------
        // 2) 端点点号越界 (endp=3 > EP_MAX) → 忽略
        //--------------------------------------------------------------------
        pl_fill(4, 8'h24);
        pkt_token(`PID_TYPE_OUT, 7'd5, 4'd3, 1'b0);
        pkt_data(1'b0, 4, 1'b0);
        idle_cycles(4);
        resp_chk_none("端点越界");

        //--------------------------------------------------------------------
        // 3) token 坏 CRC5 (地址/端点都对) → 整笔忽略
        //--------------------------------------------------------------------
        pl_fill(4, 8'h34);
        pkt_token(`PID_TYPE_OUT, 7'd5, 4'd1, 1'b1);
        pkt_data(1'b0, 4, 1'b0);
        idle_cycles(4);
        resp_chk_none("坏 CRC5 token + 数据包");
        chk_buf_ready(1'b0, "坏 token 后不写缓冲");

        //--------------------------------------------------------------------
        // 4) 杂散数据包 (无 token 前导, 自身完好) → 无应答、无端点事件
        //--------------------------------------------------------------------
        bad0 = ev_bad; done0 = ev_done;
        pl_fill(4, 8'h44);
        pkt_data(1'b0, 4, 1'b0);
        idle_cycles(4);
        resp_chk_none("杂散数据包");
        chk_evt(ev_done - done0, 0, "杂散包无 ep_rx_done");
        chk_evt(ev_bad - bad0, 0, "杂散包无 ep_rx_bad (包本身是好的)");
        chk_buf_ready(1'b0, "杂散包不写缓冲");

        //--------------------------------------------------------------------
        // 5) 杂散握手包 (主机 ACK, 设备这里不该有反应)
        //--------------------------------------------------------------------
        pkt_hs(`PID_TYPE_ACK);
        idle_cycles(4);
        resp_chk_none("杂散握手包");

        //--------------------------------------------------------------------
        // 6) 改设备地址 = 0x2A → 只认新地址, 旧地址失效
        //--------------------------------------------------------------------
        set_cfg(7'd42, 3'b000, 3'b000, 2'b00);
        pl_fill(4, 8'h54);
        pkt_token(`PID_TYPE_OUT, 7'd42, 4'd1, 1'b0);
        pkt_data(1'b0, 4, 1'b0);
        idle_cycles(4);
        resp_chk_one(`PID_ACK, "新地址");
        chk_toggle(3'b010, "新地址收下");
        wait_buf_ready(10);
        rec0 = drain_n;
        drain_all;
        chk_drain_pl(rec0, "新地址净荷");

        pl_fill(4, 8'h64);
        pkt_token(`PID_TYPE_OUT, 7'd5, 4'd1, 1'b0);
        pkt_data(1'b0, 4, 1'b0);
        idle_cycles(4);
        resp_chk_none("旧地址已失效");

        //--------------------------------------------------------------------
        // 7) 地址 0x7F / 0x00: 让 7 个地址位都走满两个方向 (只写 5 与 42 时,
        //    有些位的回翻方向走不到)。顺带把端点点号在 EP2 → EP1 之间来回,
        //    让 ep_sel 的位也走满。
        //--------------------------------------------------------------------
        set_cfg(7'd127, 3'b000, 3'b000, 2'b00);
        pl_fill(2, 8'h74);
        pkt_token(`PID_TYPE_OUT, 7'd127, 4'd2, 1'b0);   // 打到 EP2
        pkt_data(1'b0, 2, 1'b0);                       // toggle[EP2]=0 → 期望 DATA0
        idle_cycles(4);
        resp_chk_one(`PID_ACK, "地址 0x7F / EP2");
        chk_toggle(3'b110, "EP2 收下 (EP1 仍是 1)");
        wait_buf_ready(10);
        drain_all;

        set_cfg(7'd0, 3'b000, 3'b000, 2'b00);
        pl_fill(2, 8'h04);
        pkt_token(`PID_TYPE_OUT, 7'd0, 4'd1, 1'b0);     // 打到 EP1
        pkt_data(1'b1, 2, 1'b0);                       // toggle[EP1]=1 (第 6 步翻过)
        idle_cycles(4);
        resp_chk_one(`PID_ACK, "地址 0x00 / EP1");
        wait_buf_ready(10);
        rec0 = drain_n;
        drain_all;
        chk_drain_pl(rec0, "地址 0x00 净荷");

        if (errors == start_errs)
            $display("  PASS: case_addr_stray");
        else
            $display("  FAIL: case_addr_stray (%0d errors)", errors - start_errs);
    end
endtask
