//============================================================================
// case_bad_pkt.v — 坏包一律不成事务
//
// 覆盖: 坏 CRC16 / 坏 PID / 非数据类包闯进数据阶段 / 物理错 (rx_error) /
//   截断包, 五种坏法都必须是"不应答 + 不写缓冲 + 不动 toggle", 且各有各的
//   事件口径 (只有数据类的坏包才出 ep_rx_bad, 见 §2.8/§2.11)。
//   末尾补一个好包, 证明坏包没留下残留状态 (rx_abort / 写指针 / 事务态)。
//============================================================================

task case_bad_pkt;
    integer start_errs, bad0, done0, ab0, rec0;
    reg [15:0] c16;
    begin
        start_errs = errors;
        $display("== sie_bad_pkt: 坏 PID / 坏 CRC16 / 物理错 / 截断, 不收不应答 ==");

        set_cfg(7'd5, 3'b000, 3'b000, 2'b00);
        bad0 = ev_bad; done0 = ev_done; ab0 = ev_abort;

        //--------------------------------------------------------------------
        // 1) CRC16 坏 (DATA0, 4 字节净荷, 末位单 bit 错)
        //--------------------------------------------------------------------
        pl_fill(4, 8'h60);
        pkt_token(`PID_TYPE_OUT, 7'd5, 4'd1, 1'b0);
        pkt_data(1'b0, 4, 1'b1);
        idle_cycles(4);
        chk_pr_nx(`PID_DATA0, 2'd2, 1'b1, "坏 CRC16 判坏");
        resp_chk_none("坏 CRC16");
        chk_evt(ev_bad - bad0, 1, "坏 CRC16 ep_rx_bad");
        chk_evt(ev_done - done0, 0, "坏 CRC16 ep_rx_done");
        chk_buf_ready(1'b0, "坏 CRC16 不写缓冲");
        chk_toggle(3'b000, "坏 CRC16 不翻 toggle");
        chk_tstate(F_IDLE, "坏 CRC16 后回空闲");

        //--------------------------------------------------------------------
        // 2) 坏 PID (DATA0 的补码位翻转 → 8'hC2) — 类别都判不出来, 更不该有事件
        //--------------------------------------------------------------------
        bad0 = ev_bad; done0 = ev_done;
        pkt_raw(8'hC2, 6, 8'h55);
        idle_cycles(4);
        chk_pr_nx(8'hC2, 2'd0, 1'b1, "坏 PID 归类无效");
        resp_chk_none("坏 PID");
        chk_evt(ev_bad - bad0, 0, "坏 PID 无 ep_rx_bad (非数据类)");
        chk_evt(ev_done - done0, 0, "坏 PID 无 ep_rx_done");
        chk_buf_ready(1'b0, "坏 PID 不写缓冲");

        //--------------------------------------------------------------------
        // 2b) 合法 PID 但属 special 类 (PRE 0x3C: 校验半字节合法, pid[1:0]=00)
        //     类别译码的最后一跳 (CLS_INVALID 兜底) 走的是这一支, 不是坏 PID 那一支
        //--------------------------------------------------------------------
        bad0 = ev_bad; done0 = ev_done;
        pkt_raw(8'h3C, 3, 8'h66);
        idle_cycles(4);
        chk_pr_nx(8'h3C, 2'd0, 1'b0, "special 类归 INVALID (PID 本身合法)");
        resp_chk_none("special 类包");
        chk_evt(ev_bad - bad0, 0, "special 类无 ep_rx_bad");
        chk_evt(ev_done - done0, 0, "special 类无 ep_rx_done");
        chk_buf_ready(1'b0, "special 类不写缓冲");

        //--------------------------------------------------------------------
        // 3) 非数据类包闯进数据阶段 (NYET = HANDSHAKE 类, PID 本身合法)
        //    数据阶段以任何包级结论收尾 → 回空闲, 但不应答
        //--------------------------------------------------------------------
        pkt_token(`PID_TYPE_OUT, 7'd5, 4'd1, 1'b0);
        pkt_hs(`PID_TYPE_NYET);
        idle_cycles(4);
        chk_pr_nx(`PID_NYET, 2'd3, 1'b0, "NYET 归类握手");
        resp_chk_none("数据阶段里的 NYET");
        chk_tstate(F_IDLE, "NYET 结束数据阶段");

        //--------------------------------------------------------------------
        // 4) 物理错: 包中途拉 rx_error (电平, 包尾锁存进 pkt_bad)
        //--------------------------------------------------------------------
        pl_fill(3, 8'h70);
        c16 = crc16_tx_pl(3);
        bad0 = ev_bad;
        pkt_token(`PID_TYPE_OUT, 7'd5, 4'd1, 1'b0);
        pkt_open;
        byte_send(pid_byte(`PID_TYPE_DATA0));
        byte_send(pl_buf[0]);
        rxerr_pulse(1);                            // 物理错注入
        byte_send(pl_buf[1]);
        byte_send(pl_buf[2]);
        byte_send(crc16_b0(c16));
        byte_send(crc16_b1(c16));
        pkt_close;
        idle_cycles(4);
        chk_pr_nx(`PID_DATA0, 2'd2, 1'b1, "物理错判坏");
        resp_chk_none("物理错");
        chk_evt(ev_bad - bad0, 1, "物理错 ep_rx_bad");
        chk_buf_ready(1'b0, "物理错不写缓冲");
        chk_toggle(3'b000, "物理错不翻 toggle");

        //--------------------------------------------------------------------
        // 5) 截断包: 只有 PID + 1 字节, 不足 3 字节下限
        //--------------------------------------------------------------------
        bad0 = ev_bad;
        pkt_token(`PID_TYPE_OUT, 7'd5, 4'd1, 1'b0);
        pkt_raw(pid_byte(`PID_TYPE_DATA0), 1, 8'h11);
        idle_cycles(4);
        chk_pr_nx(`PID_DATA0, 2'd2, 1'b1, "截断包判坏");
        resp_chk_none("截断包");
        chk_evt(ev_bad - bad0, 1, "截断包 ep_rx_bad");
        chk_buf_ready(1'b0, "截断包不写缓冲");

        // 以上坏包都不该碰长度护栏
        chk_evt(ev_abort - ab0, 0, "坏包不触发 rx_abort");

        //--------------------------------------------------------------------
        // 6) 收尾: 好包照收 (toggle 一路没被动过, 仍期望 DATA0)
        //--------------------------------------------------------------------
        pl_fill(8, 8'h80);
        pkt_token(`PID_TYPE_OUT, 7'd5, 4'd1, 1'b0);
        pkt_data(1'b0, 8, 1'b0);
        idle_cycles(4);
        resp_chk_one(`PID_ACK, "坏包之后的好包");
        wait_buf_ready(10);
        chk_buf_cnt(8, "好包 buf_cnt");
        chk_toggle(3'b010, "好包收下后 toggle");
        rec0 = drain_n;
        drain_all;
        chk_drain_pl(rec0, "好包净荷");

        if (errors == start_errs)
            $display("  PASS: case_bad_pkt");
        else
            $display("  FAIL: case_bad_pkt (%0d errors)", errors - start_errs);
    end
endtask
