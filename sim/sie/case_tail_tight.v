//============================================================================
// case_tail_tight.v — 最紧时序边界
//
// 三个可调量 (见 sie_tasks.vh 文件头) 同时收到物理下限:
//   · byte_period  = 8   每字节 8 拍 (12Mbit 的字节节拍, 一个填充位都没有)
//   · pkt_tail_gap = 0   末字节之后立刻落 rx_active (EOP 检出的最早可能)
//   · pkt_idle_gap = 2   rx_active 只连续低 3 拍 (pkt_rx 补完两个 CRC 字节的
//                        最小窗口: tail_cnt 0→1→2), 下一个包紧接着就抬起来
//
// 这一档专门压 pkt_rx 的包尾窗口: 少一拍就丢包尾结论 (应答/收下全没), 多一拍
// 就不是边界。整段的应答与净荷内容都对, 才算包尾时序站得住。
//============================================================================

task case_tail_tight;
    integer start_errs, rec0;
    begin
        start_errs = errors;
        $display("== sie_tail_tight: 字节背靠背 + 最短包尾窗口 ==");

        byte_period  = 8;
        pkt_tail_gap = 0;
        pkt_idle_gap = 2;
        set_cfg(7'd5, 3'b000, 3'b000, 2'b00);

        //--------------------------------------------------------------------
        // 1) 坏包与好包背靠背: 中间的 rx_active 只低 3 拍, 两个结论都必须出
        //--------------------------------------------------------------------
        pl_fill(4, 8'h16);
        pkt_token(`PID_TYPE_OUT, 7'd5, 4'd1, 1'b0);
        pkt_data(1'b0, 4, 1'b1);                   // 坏 CRC16 → 不应答
        idle_cycles(2);
        resp_chk_none("紧间隔下的坏包");

        pl_fill(4, 8'h26);
        pkt_token(`PID_TYPE_OUT, 7'd5, 4'd1, 1'b0);
        pkt_data(1'b0, 4, 1'b0);                   // 好包 → 应答并收下
        idle_cycles(2);
        resp_chk_one(`PID_ACK, "紧间隔下的好包");
        chk_toggle(3'b010, "紧间隔下收下");
        wait_buf_ready(10);
        chk_buf_cnt(4, "紧间隔下 buf_cnt");
        rec0 = drain_n;
        drain_all;
        chk_drain_pl(rec0, "紧间隔下净荷");

        //--------------------------------------------------------------------
        // 2) 好包与忙包背靠背: 好包收下后缓冲未排空, 下一笔序列匹配 → NAK
        //    (同样只有 3 拍间隔, 包尾结论与应答都不能少)
        //--------------------------------------------------------------------
        pl_fill(8, 8'h36);
        pl_keep;
        pkt_token(`PID_TYPE_OUT, 7'd5, 4'd1, 1'b0);
        pkt_data(1'b1, 8, 1'b0);                   // toggle[EP1]=1 → 匹配
        idle_cycles(2);
        resp_chk_one(`PID_ACK, "紧间隔下第二笔好包");
        chk_toggle(3'b000, "紧间隔下第二笔收下");

        pl_fill(8, 8'h46);
        pkt_token(`PID_TYPE_OUT, 7'd5, 4'd1, 1'b0);
        pkt_data(1'b0, 8, 1'b0);                   // toggle[EP1]=0 → 匹配但缓冲忙
        idle_cycles(2);
        resp_chk_one(`PID_NAK, "紧间隔下的忙包");
        rec0 = drain_n;
        drain_all;
        chk_drain_exp(rec0, "紧间隔下排出内容未被忙包污染");

        //--------------------------------------------------------------------
        // 3) 位填充拉长的字节节拍 (9 拍/字节) 叠在紧包尾上
        //--------------------------------------------------------------------
        byte_period = 9;
        pl_fill(2, 8'h56);
        pkt_token(`PID_TYPE_OUT, 7'd5, 4'd1, 1'b0);
        pkt_data(1'b0, 2, 1'b0);                   // toggle[EP1]=0 (忙包没翻) → 匹配
        idle_cycles(2);
        resp_chk_one(`PID_ACK, "9 拍字节 + 紧包尾");
        wait_buf_ready(10);
        chk_buf_cnt(2, "9 拍字节 buf_cnt");
        rec0 = drain_n;
        drain_all;
        chk_drain_pl(rec0, "9 拍字节净荷");

        // 还原激励口径 (本用例是最后一个也要还原, 免得污染后续补的用例)
        byte_period  = 8;
        pkt_tail_gap = 1;
        pkt_idle_gap = 4;

        if (errors == start_errs)
            $display("  PASS: case_tail_tight");
        else
            $display("  FAIL: case_tail_tight (%0d errors)", errors - start_errs);
    end
endtask
