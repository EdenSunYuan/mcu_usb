//============================================================================
// case_buf_isolate.v — 包缓冲的流控与坏包隔离 (§2.11 / §4.8)
//
// 契约: 包缓冲一次只端得住一个"已校验通过、待排出"的包。
//   · 未排空时来新包 → NAK 流控 (主机重试), 缓冲内容一个字节都不能动
//   · 坏包在缓冲空闲时也不落地 (buf_ready 不置、cnt 不置), 且不影响下一包的
//     写指针 (下一包从 0 重写, 读口不会读到上一包或坏包的残留)
//   · 零长度包也要能收下并排空 (cnt=0 不是死角)
//
// 判据口径: "缓冲没被动过" 一律以排出内容比对为准 (对内不可见的写口不采信)。
//============================================================================

task case_buf_isolate;
    integer start_errs, rec0, bad0;
    begin
        start_errs = errors;
        $display("== sie_buf_isolate: NAK 流控 / 坏包隔离 / 零长包 ==");

        set_cfg(7'd5, 3'b000, 3'b000, 2'b00);

        //--------------------------------------------------------------------
        // A) 收下第一包 (8 字节, 不排空), 冻结它的净荷作基准
        //--------------------------------------------------------------------
        pl_fill(8, 8'h01);
        pl_keep;                                   // pl_exp = A 的净荷
        pkt_token(`PID_TYPE_OUT, 7'd5, 4'd1, 1'b0);
        pkt_data(1'b0, 8, 1'b0);
        idle_cycles(4);
        resp_chk_one(`PID_ACK, "A 包");
        chk_toggle(3'b010, "A 包收下");
        wait_buf_ready(10);
        chk_buf_cnt(8, "A 包 buf_cnt");

        //--------------------------------------------------------------------
        // B) 缓冲未排空 → 序列匹配的 B 包被 NAK, 缓冲内容仍是 A
        //--------------------------------------------------------------------
        pl_fill(12, 8'h50);
        pkt_token(`PID_TYPE_OUT, 7'd5, 4'd1, 1'b0);
        pkt_data(1'b1, 12, 1'b0);                  // toggle[EP1]=1 → 序列匹配
        idle_cycles(4);
        resp_chk_one(`PID_NAK, "缓冲未排空的 B 包");
        chk_buf_cnt(8, "NAK 后 buf_cnt 不变");
        chk_toggle(3'b010, "NAK 不动 toggle");
        rec0 = drain_n;
        drain_all;
        chk_drain_exp(rec0, "NAK 后排出内容仍是 A 包");

        //--------------------------------------------------------------------
        // C) 坏包不落地: 出 10 字节的坏包 → 不应答、buf_ready 保持 0
        //--------------------------------------------------------------------
        pl_fill(10, 8'h60);
        bad0 = ev_bad;
        pkt_token(`PID_TYPE_OUT, 7'd5, 4'd1, 1'b0);
        pkt_data(1'b1, 10, 1'b1);                  // 坏 CRC16
        idle_cycles(4);
        resp_chk_none("坏包");
        chk_evt(ev_bad - bad0, 1, "坏包 ep_rx_bad");
        chk_buf_ready(1'b0, "坏包不落地");
        // 坏包不留长度: buf_ready=0 已经是黑盒判据, 这里再核一次"长度寄存器也回了 0",
        // 免得下游按残留长度去读一包根本没校验通过的数据
        if (buf_cnt !== 7'd0) begin
            $display("    FAIL: 坏包后 buf_cnt=%0d, 期望 0", buf_cnt);
            errors = errors + 1;
        end else $display("    OK  : 坏包后 buf_cnt=0");

        //--------------------------------------------------------------------
        // D) 紧随其后的短好包 (4 字节) → 照收, 且读口读不到坏包的残留
        //    (坏包写了 10 字节进缓冲, 写指针必须从 0 重来)
        //--------------------------------------------------------------------
        pl_fill(4, 8'h70);
        pkt_token(`PID_TYPE_OUT, 7'd5, 4'd1, 1'b0);
        pkt_data(1'b1, 4, 1'b0);
        idle_cycles(4);
        resp_chk_one(`PID_ACK, "坏包后的短好包");
        chk_toggle(3'b000, "短好包收下");
        wait_buf_ready(10);
        chk_buf_cnt(4, "短好包 buf_cnt");
        rec0 = drain_n;
        drain_all;
        chk_drain_pl(rec0, "短好包净荷");

        //--------------------------------------------------------------------
        // E) 缓冲忙时来坏包 → 坏包优先 (不应答), 忙包的缓冲一个字节不动
        //--------------------------------------------------------------------
        pl_fill(8, 8'h80);
        pl_keep;
        pkt_token(`PID_TYPE_OUT, 7'd5, 4'd1, 1'b0);
        pkt_data(1'b0, 8, 1'b0);                   // toggle[EP1]=0 → 收下
        idle_cycles(4);
        resp_chk_one(`PID_ACK, "E 包");
        chk_buf_cnt(8, "E 包 buf_cnt");

        pl_fill(8, 8'h90);
        bad0 = ev_bad;
        pkt_token(`PID_TYPE_OUT, 7'd5, 4'd1, 1'b0);
        pkt_data(1'b1, 8, 1'b1);                   // 序列匹配但 CRC 坏
        idle_cycles(4);
        resp_chk_none("忙时的坏包");
        chk_evt(ev_bad - bad0, 1, "忙时坏包 ep_rx_bad");
        chk_buf_cnt(8, "忙时坏包不动 buf_cnt");
        rec0 = drain_n;
        drain_all;
        chk_drain_exp(rec0, "忙时坏包后排出内容仍是 E 包");

        //--------------------------------------------------------------------
        // F) 零长包: 收下 → cnt=0, 一次读脉冲收口
        //--------------------------------------------------------------------
        pl_fill(0, 8'hA0);
        pkt_token(`PID_TYPE_OUT, 7'd5, 4'd1, 1'b0);
        pkt_data(1'b1, 0, 1'b0);                   // toggle[EP1]=1 (E 包翻过)
        idle_cycles(4);
        resp_chk_one(`PID_ACK, "零长包");
        chk_toggle(3'b000, "零长包收下");
        wait_buf_ready(10);
        chk_buf_cnt(0, "零长包 buf_cnt");
        rec0 = drain_n;
        drain_all;
        chk_drain_pl(rec0, "零长包净荷");

        if (errors == start_errs)
            $display("  PASS: case_buf_isolate");
        else
            $display("  FAIL: case_buf_isolate (%0d errors)", errors - start_errs);
    end
endtask
