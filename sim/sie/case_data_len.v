//============================================================================
// case_data_len.v — 数据包长度谱: 0 / 1 / 64 / 8 字节
//
// 覆盖: dat_len 口径 (总字节 − PID − 2 CRC)、净荷写口与 CRC16 延迟线的对齐
//   (写进包缓冲的必须是净荷, 两个 CRC 字节进不去)、buf_cnt 与排出内容、
//   64 字节满包时指针回卷、端点 toggle 相互独立。
//
// 判据口径: 净荷"对不对"不由内部信号自证 —— 一律经 buf_rd_en 读口逐字节排出
//   再与激励侧算的期望字节比 (与 CDC 排出同口径)。
//============================================================================

task case_data_len;
    integer start_errs, rec0;
    begin
        start_errs = errors;
        $display("== sie_data_len: 0 / 1 / 64 / 8 字节数据包 ==");

        set_cfg(7'd5, 3'b000, 3'b000, 2'b00);      // EP1/EP2 都配成 OUT

        //--------------------------------------------------------------------
        // A) EP1 收 0 字节 DATA0 (toggle 初值 0 → 期望 DATA0)
        //--------------------------------------------------------------------
        pl_fill(0, 8'h10);
        pkt_token(`PID_TYPE_OUT, 7'd5, 4'd1, 1'b0);
        pkt_data(1'b0, 0, 1'b0);
        idle_cycles(4);
        chk_pr_nx(`PID_DATA0, 2'd2, 1'b0, "0B 包字段");
        chk_len(0, "0B dat_len");
        resp_chk_one(`PID_ACK, "0B OUT");
        chk_toggle(3'b010, "0B 收下后 toggle[EP1]");
        wait_buf_ready(10);
        chk_buf_cnt(0, "0B buf_cnt");
        rec0 = drain_n;
        drain_all;
        chk_drain_pl(rec0, "0B 净荷");

        //--------------------------------------------------------------------
        // B) EP1 收 1 字节 DATA1 (收下后 toggle 回 0)
        //--------------------------------------------------------------------
        pl_fill(1, 8'h20);                         // 净荷 = 0x21
        pkt_token(`PID_TYPE_OUT, 7'd5, 4'd1, 1'b0);
        pkt_data(1'b1, 1, 1'b0);
        idle_cycles(4);
        chk_pr_nx(`PID_DATA1, 2'd2, 1'b0, "1B 包字段");
        chk_len(1, "1B dat_len");
        resp_chk_one(`PID_ACK, "1B OUT");
        chk_toggle(3'b000, "1B 收下后 toggle[EP1]");
        wait_buf_ready(10);
        chk_buf_cnt(1, "1B buf_cnt");
        rec0 = drain_n;
        drain_all;
        chk_drain_pl(rec0, "1B 净荷");

        //--------------------------------------------------------------------
        // C) EP1 收 64 字节 DATA0 — 满包: 3+64 = 67 字节正好在上限内
        //    写指针走到 63 再回卷, 净荷一个不错位
        //--------------------------------------------------------------------
        pl_fill(64, 8'h30);
        pkt_token(`PID_TYPE_OUT, 7'd5, 4'd1, 1'b0);
        pkt_data(1'b0, 64, 1'b0);
        idle_cycles(4);
        chk_pr_nx(`PID_DATA0, 2'd2, 1'b0, "64B 包字段");
        chk_len(64, "64B dat_len");
        resp_chk_one(`PID_ACK, "64B OUT");
        chk_toggle(3'b010, "64B 收下后 toggle[EP1]");
        wait_buf_ready(10);
        chk_buf_cnt(64, "64B buf_cnt");
        rec0 = drain_n;
        drain_all;
        chk_drain_pl(rec0, "64B 净荷");

        //--------------------------------------------------------------------
        // D) EP2 收 8 字节 DATA0 — EP2 的 toggle 初值仍是 0 (与 EP1 互不干扰)
        //--------------------------------------------------------------------
        pl_fill(8, 8'h40);
        pkt_token(`PID_TYPE_OUT, 7'd5, 4'd2, 1'b0);
        pkt_data(1'b0, 8, 1'b0);
        idle_cycles(4);
        chk_pr_nx(`PID_DATA0, 2'd2, 1'b0, "8B 包字段");
        chk_len(8, "8B dat_len");
        resp_chk_one(`PID_ACK, "8B OUT");
        chk_toggle(3'b110, "8B 收下后 toggle{EP2,EP1,EP0}");
        wait_buf_ready(10);
        chk_buf_cnt(8, "8B buf_cnt");
        rec0 = drain_n;
        drain_all;
        chk_drain_pl(rec0, "8B 净荷");

        if (errors == start_errs)
            $display("  PASS: case_data_len");
        else
            $display("  FAIL: case_data_len (%0d errors)", errors - start_errs);
    end
endtask
