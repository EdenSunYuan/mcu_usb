//============================================================================
// case_resp_prio.v — 应答真值表 (§2.8) 与优先级
//
// 规范优先级 (从上到下, 顺序写反必错):
//   坏包 → 不应答 ＞ OUT 打到 IN 端点 → 不应答 ＞ halt → STALL
//   ＞ 序列不匹配 → ACK+丢弃 (不翻转) ＞ 忙 → NAK ＞ 其余 → ACK+收下+翻转
//
// 每条都单独验, 并验相邻两级的"压过": 坏包压 halt、方向压 halt、
//   halt 压序列、序列压忙。响应走应答队列核对, 收没收下走 buf_ready + toggle。
//============================================================================

task case_resp_prio;
    integer start_errs, rec0;
    begin
        start_errs = errors;
        $display("== sie_resp_prio: 应答真值表与优先级 ==");

        pl_fill(4, 8'h90);                         // 本节净荷 (内容不是重点)

        //--------------------------------------------------------------------
        // (a) OUT 打到 IN 配置的端点 → 不应答 (§2.14①)
        //--------------------------------------------------------------------
        set_cfg(7'd5, 3'b000, 3'b000, 2'b01);      // EP1 = IN
        pkt_token(`PID_TYPE_OUT, 7'd5, 4'd1, 1'b0);
        pkt_data(1'b0, 4, 1'b0);
        idle_cycles(4);
        resp_chk_none("OUT 打到 IN 端点");
        chk_buf_ready(1'b0, "方向错不写缓冲");

        //--------------------------------------------------------------------
        // (b) 方向错 + halt 同时成立 → 仍不应答 (方向优先于 halt)
        //--------------------------------------------------------------------
        set_cfg(7'd5, 3'b010, 3'b000, 2'b01);
        pkt_token(`PID_TYPE_OUT, 7'd5, 4'd1, 1'b0);
        pkt_data(1'b0, 4, 1'b0);
        idle_cycles(4);
        resp_chk_none("方向错压过 halt");

        //--------------------------------------------------------------------
        // (c) halt → STALL (方向已配回 OUT)
        //--------------------------------------------------------------------
        set_cfg(7'd5, 3'b010, 3'b000, 2'b00);
        pkt_token(`PID_TYPE_OUT, 7'd5, 4'd1, 1'b0);
        pkt_data(1'b0, 4, 1'b0);
        idle_cycles(4);
        resp_chk_one(`PID_STALL, "halt");
        chk_buf_ready(1'b0, "halt 不写缓冲");
        chk_toggle(3'b000, "halt 不翻 toggle");

        //--------------------------------------------------------------------
        // (d) halt + 序列不匹配 → 仍 STALL
        //--------------------------------------------------------------------
        pkt_token(`PID_TYPE_OUT, 7'd5, 4'd1, 1'b0);
        pkt_data(1'b1, 4, 1'b0);
        idle_cycles(4);
        resp_chk_one(`PID_STALL, "halt 压过序列不匹配");

        //--------------------------------------------------------------------
        // (e) 序列不匹配 → ACK + 丢弃 (去重: 不翻转、不写缓冲)
        //--------------------------------------------------------------------
        set_cfg(7'd5, 3'b000, 3'b000, 2'b00);
        pkt_token(`PID_TYPE_OUT, 7'd5, 4'd1, 1'b0);
        pkt_data(1'b1, 4, 1'b0);                   // toggle[EP1]=0, 期望 DATA0
        idle_cycles(4);
        resp_chk_one(`PID_ACK, "序列不匹配");
        chk_buf_ready(1'b0, "序列不匹配不写缓冲");
        chk_toggle(3'b000, "序列不匹配不翻 toggle");

        //--------------------------------------------------------------------
        // (f) 序列不匹配 + 端点忙 → 仍 ACK (序列优先于忙: 数据本来就要丢)
        //--------------------------------------------------------------------
        set_cfg(7'd5, 3'b000, 3'b010, 2'b00);
        pkt_token(`PID_TYPE_OUT, 7'd5, 4'd1, 1'b0);
        pkt_data(1'b1, 4, 1'b0);
        idle_cycles(4);
        resp_chk_one(`PID_ACK, "序列不匹配压过忙");

        //--------------------------------------------------------------------
        // (g) 端点忙 → NAK
        //--------------------------------------------------------------------
        pkt_token(`PID_TYPE_OUT, 7'd5, 4'd1, 1'b0);
        pkt_data(1'b0, 4, 1'b0);                   // 序列匹配, 但端点忙
        idle_cycles(4);
        resp_chk_one(`PID_NAK, "端点忙");
        chk_buf_ready(1'b0, "NAK 不写缓冲");
        chk_toggle(3'b000, "NAK 不翻 toggle");

        //--------------------------------------------------------------------
        // (h) 一路 Clear → ACK + 收下 + 翻转
        //--------------------------------------------------------------------
        set_cfg(7'd5, 3'b000, 3'b000, 2'b00);
        pkt_token(`PID_TYPE_OUT, 7'd5, 4'd1, 1'b0);
        pkt_data(1'b0, 4, 1'b0);
        idle_cycles(4);
        resp_chk_one(`PID_ACK, "正常收下");
        chk_toggle(3'b010, "正常收下翻 toggle[EP1]");
        wait_buf_ready(10);
        chk_buf_cnt(4, "正常收下 buf_cnt");
        rec0 = drain_n;
        drain_all;
        chk_drain_pl(rec0, "正常收下净荷");

        //--------------------------------------------------------------------
        // (i) 坏包压过一切 (halt + 忙 同时挂着也不该出 STALL/NAK)
        //--------------------------------------------------------------------
        set_cfg(7'd5, 3'b010, 3'b010, 2'b00);
        pkt_token(`PID_TYPE_OUT, 7'd5, 4'd1, 1'b0);
        pkt_data(1'b1, 4, 1'b1);                   // 序列匹配但 CRC 坏
        idle_cycles(4);
        chk_pr_nx(`PID_DATA1, 2'd2, 1'b1, "坏 CRC16 判坏");
        resp_chk_none("坏包压过 halt/忙");
        chk_buf_ready(1'b0, "坏包不写缓冲");

        set_cfg(7'd5, 3'b000, 3'b000, 2'b00);

        //--------------------------------------------------------------------
        // (j) EP2 的三个配置位各走一遍 (判据同一套, 但取的是 bit2/bit1 那几位,
        //     只打 EP1 的话这几位永远不动)
        //--------------------------------------------------------------------
        set_cfg(7'd5, 3'b000, 3'b000, 2'b10);      // EP2 = IN
        pkt_token(`PID_TYPE_OUT, 7'd5, 4'd2, 1'b0);
        pkt_data(1'b0, 4, 1'b0);
        idle_cycles(4);
        resp_chk_none("EP2 配成 IN");
        chk_buf_ready(1'b0, "EP2 方向错不写缓冲");

        set_cfg(7'd5, 3'b100, 3'b000, 2'b00);      // EP2 = halt
        pkt_token(`PID_TYPE_OUT, 7'd5, 4'd2, 1'b0);
        pkt_data(1'b0, 4, 1'b0);
        idle_cycles(4);
        resp_chk_one(`PID_STALL, "EP2 halt");
        chk_toggle(3'b010, "EP2 halt 不翻 toggle (EP1 仍是 1)");

        set_cfg(7'd5, 3'b000, 3'b100, 2'b00);      // EP2 = 忙
        pkt_token(`PID_TYPE_OUT, 7'd5, 4'd2, 1'b0);
        pkt_data(1'b0, 4, 1'b0);
        idle_cycles(4);
        resp_chk_one(`PID_NAK, "EP2 忙");

        set_cfg(7'd5, 3'b000, 3'b000, 2'b00);
        pkt_token(`PID_TYPE_OUT, 7'd5, 4'd2, 1'b0);
        pkt_data(1'b0, 4, 1'b0);
        idle_cycles(4);
        resp_chk_one(`PID_ACK, "EP2 正常收下");
        chk_toggle(3'b110, "EP2 收下翻 toggle[EP2]");
        wait_buf_ready(10);
        rec0 = drain_n;
        drain_all;
        chk_drain_pl(rec0, "EP2 净荷");

        if (errors == start_errs)
            $display("  PASS: case_resp_prio");
        else
            $display("  FAIL: case_resp_prio (%0d errors)", errors - start_errs);
    end
endtask
