//============================================================================
// case_toggle.v — data toggle 序列 (§2.9)
//
// 契约: 期望 DATA0 ⇔ toggle=0; 收下才翻转, 不匹配/丢弃一律不翻。
//   覆盖: 连续两笔正常翻转、重复包 (序列不匹配) 去重不翻转、重发后恢复、
//   CPU 写初值覆盖、端点之间互不干扰。
//============================================================================

task case_toggle;
    integer start_errs, rec0;
    begin
        start_errs = errors;
        $display("== sie_toggle: 序列翻转 / 去重 / CPU 覆盖 / 端点独立 ==");

        set_cfg(7'd5, 3'b000, 3'b000, 2'b00);
        set_toggle(3'b000);                        // 从全 0 起算
        chk_toggle(3'b000, "初值");

        //--------------------------------------------------------------------
        // 1) 连续两笔正常: DATA0 收下 → flips → DATA1 收下
        //    每笔收下后立刻排空缓冲, 否则下一笔撞上"忙" → NAK (那是 §2.8 第 4 行,
        //    不是本用例要看的序列行为)
        //--------------------------------------------------------------------
        pl_fill(2, 8'h01);
        pkt_token(`PID_TYPE_OUT, 7'd5, 4'd1, 1'b0);
        pkt_data(1'b0, 2, 1'b0);
        idle_cycles(4);
        resp_chk_one(`PID_ACK, "DATA0 首笔");
        chk_toggle(3'b010, "首笔收下后");
        wait_buf_ready(10);
        rec0 = drain_n;
        drain_all;
        chk_drain_pl(rec0, "首笔净荷");

        pl_fill(2, 8'h11);
        pkt_token(`PID_TYPE_OUT, 7'd5, 4'd1, 1'b0);
        pkt_data(1'b1, 2, 1'b0);
        idle_cycles(4);
        resp_chk_one(`PID_ACK, "DATA1 次笔");
        chk_toggle(3'b000, "次笔收下后");
        wait_buf_ready(10);
        rec0 = drain_n;
        drain_all;
        chk_drain_pl(rec0, "次笔净荷");

        //--------------------------------------------------------------------
        // 2) 重复包: 主机没收到 ACK 会重发同一笔 → 序列不匹配 → ACK + 丢弃
        //    (去重: 缓冲不写、toggle 不翻)
        //--------------------------------------------------------------------
        pl_fill(2, 8'h21);
        pkt_token(`PID_TYPE_OUT, 7'd5, 4'd1, 1'b0);
        pkt_data(1'b0, 2, 1'b0);                   // 期望 DATA0, 收下 → toggle=1
        idle_cycles(4);
        resp_chk_one(`PID_ACK, "重发前首笔");
        chk_toggle(3'b010, "重发前首笔后");
        wait_buf_ready(10);
        rec0 = drain_n;
        drain_all;
        chk_drain_pl(rec0, "重发前首笔净荷");

        pl_fill(2, 8'h31);                         // 重发的净荷内容无所谓
        pkt_token(`PID_TYPE_OUT, 7'd5, 4'd1, 1'b0);
        pkt_data(1'b0, 2, 1'b0);                   // 同一笔再发一次 → 序列不匹配
        idle_cycles(4);
        resp_chk_one(`PID_ACK, "重复包");
        chk_toggle(3'b010, "重复包不翻 toggle");
        chk_buf_ready(1'b0, "重复包不写缓冲");

        //--------------------------------------------------------------------
        // 3) 重发之后主机改用 DATA1 → 序列匹配, 正常收下
        //--------------------------------------------------------------------
        pl_fill(2, 8'h41);
        pkt_token(`PID_TYPE_OUT, 7'd5, 4'd1, 1'b0);
        pkt_data(1'b1, 2, 1'b0);
        idle_cycles(4);
        resp_chk_one(`PID_ACK, "重发后的 DATA1");
        chk_toggle(3'b000, "重发后收下");
        wait_buf_ready(10);
        rec0 = drain_n;
        drain_all;
        chk_drain_pl(rec0, "重发后净荷");

        //--------------------------------------------------------------------
        // 4) CPU 写初值: toggle_val 是 3 bit 字段, 一次把三个端点全覆盖
        //--------------------------------------------------------------------
        set_toggle(3'b100);                        // EP2 = 1, EP0/EP1 = 0
        chk_toggle(3'b100, "CPU 写初值");

        //--------------------------------------------------------------------
        // 5) 端点独立: 翻 EP1 不动 EP2, 翻 EP2 不动 EP1
        //--------------------------------------------------------------------
        pl_fill(2, 8'h51);
        pkt_token(`PID_TYPE_OUT, 7'd5, 4'd1, 1'b0);
        pkt_data(1'b0, 2, 1'b0);                   // EP1 期望 DATA0 (toggle[EP1]=0)
        idle_cycles(4);
        resp_chk_one(`PID_ACK, "EP1 收下");
        chk_toggle(3'b110, "翻 EP1 不动 EP2");
        wait_buf_ready(10);
        drain_all;

        pl_fill(2, 8'h61);
        pkt_token(`PID_TYPE_OUT, 7'd5, 4'd2, 1'b0);
        pkt_data(1'b1, 2, 1'b0);                   // EP2 期望 DATA1 (toggle[EP2]=1)
        idle_cycles(4);
        resp_chk_one(`PID_ACK, "EP2 收下");
        chk_toggle(3'b010, "翻 EP2 不动 EP1");
        wait_buf_ready(10);
        rec0 = drain_n;
        drain_all;
        chk_drain_pl(rec0, "EP2 净荷");

        //--------------------------------------------------------------------
        // 6) 覆盖其余初值组合: 3'b111 → 3'b000, 让三位的两个方向都走到
        //--------------------------------------------------------------------
        set_toggle(3'b111);
        chk_toggle(3'b111, "CPU 写全 1");
        set_toggle(3'b000);
        chk_toggle(3'b000, "CPU 写回全 0");

        if (errors == start_errs)
            $display("  PASS: case_toggle");
        else
            $display("  FAIL: case_toggle (%0d errors)", errors - start_errs);
    end
endtask
