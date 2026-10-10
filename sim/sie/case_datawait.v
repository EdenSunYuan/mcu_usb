//============================================================================
// case_datawait.v — 数据阶段的收尾与打断 (§2.7.2 / §2.10 / §4.7)
//
// 覆盖:
//   · 周转超时: 计数到 15 拍判超时, 回空闲, 之后的孤立数据包不成事务
//   · 打断并重新武装: 数据阶段里来了新的 OUT token → 按新 token 重新计时,
//     新 token 的数据包照常收下 (§4.7 的鲁棒性要求)
//   · 只有"能派发的 token"才算打断: SOF / IN / 坏 token 只是把数据阶段收尾
//   · 计时器可重复使用: 再孤立一个 token, 又恰好是 15 拍
//============================================================================

task case_datawait;
    integer start_errs, rec0;
    begin
        start_errs = errors;
        $display("== sie_datawait: 周转超时 / 被新 token 打断并重新武装 ==");

        set_cfg(7'd5, 3'b000, 3'b000, 2'b00);

        //--------------------------------------------------------------------
        // 1) 孤立 OUT token → 数据阶段空转 15 拍后超时回空闲, 无应答
        //--------------------------------------------------------------------
        dwait_mark;
        pkt_token(`PID_TYPE_OUT, 7'd5, 4'd1, 1'b0);
        idle_cycles(25);
        chk_dwait(15, "孤立 token 的周转计时");
        chk_tstate(F_IDLE, "超时后");
        resp_chk_none("孤立 token");

        //--------------------------------------------------------------------
        // 2) 超时之后才来的数据包 → 事务已终结, 完全无反应
        //--------------------------------------------------------------------
        pl_fill(4, 8'h12);
        pkt_data(1'b0, 4, 1'b0);
        idle_cycles(6);
        resp_chk_none("超时后的数据包");
        chk_buf_ready(1'b0, "超时后的数据包不写缓冲");
        chk_toggle(3'b000, "超时后的数据包不动 toggle");

        //--------------------------------------------------------------------
        // 3) 数据阶段被新 OUT token 打断 → 按新 token 重新武装, 数据照收
        //    (EP1 的 token 之后没等来数据包, 直接开了 EP2 的事务)
        //--------------------------------------------------------------------
        dwait_mark;
        pkt_token(`PID_TYPE_OUT, 7'd5, 4'd1, 1'b0);
        idle_cycles(8);
        pkt_token(`PID_TYPE_OUT, 7'd5, 4'd2, 1'b0);
        pl_fill(4, 8'h22);
        pkt_data(1'b0, 4, 1'b0);
        idle_cycles(4);
        chk_dwait_gt(15, "新 token 打断");
        resp_chk_one(`PID_ACK, "打断后按新 token 收下");
        chk_toggle(3'b100, "只翻 EP2 的 toggle");
        wait_buf_ready(10);
        chk_buf_cnt(4, "打断后 buf_cnt");
        rec0 = drain_n;
        drain_all;
        chk_drain_pl(rec0, "打断后净荷");

        //--------------------------------------------------------------------
        // 4) 计时器可重复使用: 再孤立一个 token, 又恰好 15 拍
        //--------------------------------------------------------------------
        dwait_mark;
        pkt_token(`PID_TYPE_OUT, 7'd5, 4'd2, 1'b0);
        idle_cycles(25);
        chk_dwait(15, "第二次孤立 token");
        chk_tstate(F_IDLE, "第二次超时后");

        //--------------------------------------------------------------------
        // 5) 打断的边界: SOF 不是"能派发的 token" → 只把数据阶段收尾
        //    (事务已终结, 后面的数据包不该被收下)
        //--------------------------------------------------------------------
        pkt_token(`PID_TYPE_OUT, 7'd5, 4'd1, 1'b0);
        idle_cycles(4);
        pkt_sof(11'h033, 1'b0);
        idle_cycles(6);
        chk_tstate(F_IDLE, "SOF 收尾数据阶段");
        pl_fill(4, 8'h32);
        pkt_data(1'b0, 4, 1'b0);
        idle_cycles(6);
        resp_chk_none("SOF 收尾后的数据包");
        chk_buf_ready(1'b0, "SOF 收尾后不写缓冲");
        chk_toggle(3'b100, "SOF 收尾后 toggle 不变");

        if (errors == start_errs)
            $display("  PASS: case_datawait");
        else
            $display("  FAIL: case_datawait (%0d errors)", errors - start_errs);
    end
endtask
