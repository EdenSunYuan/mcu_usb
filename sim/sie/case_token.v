//============================================================================
// case_token.v — token / SOF 的字段解析、CRC5 残差、坏 CRC 的行为
//
// 覆盖: 字段提取 (tok_addr/tok_endp/tok_frame)、CRC5 残差判据、坏 PID/坏 CRC5
//   一律不成事务、IN token 本轮无出口、地址失配不派发、SOF 不过地址匹配。
//
// 判据口径: 字段本身走白盒探针 pr_* (在 pkt_done 拍采), 行为走应答队列与
//   事务态停留拍数 —— token 单独出现不产生任何应答, 所以"有没有进数据阶段"
//   用 FSM 在 T_DATA_WAIT 的停留拍数当证据 (进了就是 15 拍超时, 没进就是 0)。
//============================================================================

task case_token;
    integer start_errs, sof0, dw0;
    begin
        start_errs = errors;
        $display("== sie_token: token/SOF 字段解析 + CRC5 残差 + 坏 CRC5 ==");

        set_cfg(7'd5, 3'b000, 3'b000, 2'b00);      // 设备地址 5, 不 stall 不忙

        //--------------------------------------------------------------------
        // 1) IN token (addr=5, endp=3) — 本轮无 T_TX: 字段照样解析, 但无出口
        //--------------------------------------------------------------------
        dwait_mark;
        pkt_token(`PID_TYPE_IN, 7'd5, 4'd3, 1'b0);
        idle_cycles(6);
        chk_pr(7'd5, 4'd3, `PID_IN, 2'd1, 1'b0, "IN token 字段");
        resp_chk_none("IN token");
        chk_tstate(F_IDLE, "IN token 后");
        chk_dwait(0, "IN token 不进数据阶段");

        //--------------------------------------------------------------------
        // 2) SOF frame=0x2AA — 低 7 位 = 0x2A ≠ 设备地址 5, 仍必须收下
        //    (SOF 的 11 bit 是帧号, 不过地址匹配, 见 §2.7.2)
        //    字段口径: 解析器不认类型, 就按位凑 addr=fn[6:0] / endp={fn[10:8],fn[7]},
        //    所以 fn=2AA → addr=2A=42 / endp={010,1}=5。这两个数只是帧号的重排,
        //    不参与地址匹配 (匹配逻辑对 SOF 单独开路), 下面照实核对。
        //--------------------------------------------------------------------
        sof0 = ev_sof;
        dwait_mark;
        pkt_sof(11'h2AA, 1'b0);
        idle_cycles(6);
        chk_pr(7'd42, 4'd5, `PID_SOF, 2'd1, 1'b0, "SOF 字段 (帧号重排)");
        if (pr_tok_frame !== 11'h2AA) begin
            $display("    FAIL: SOF 帧号 %03x, 期望 2AA", pr_tok_frame);
            errors = errors + 1;
        end else $display("    OK  : SOF 帧号 2AA");
        if (frame_no !== 11'h2AA) begin
            $display("    FAIL: frame_no 输出 %03x, 期望 2AA", frame_no);
            errors = errors + 1;
        end else $display("    OK  : frame_no 输出 2AA");
        if ((ev_sof - sof0) != 1) begin
            $display("    FAIL: sof_recv 脉冲 %0d 次, 期望 1", ev_sof - sof0);
            errors = errors + 1;
        end else $display("    OK  : sof_recv 脉冲 1 次");
        resp_chk_none("SOF");
        chk_dwait(0, "SOF 不进数据阶段");

        //--------------------------------------------------------------------
        // 3) SOF 坏 CRC5 — tok_good 要求 ~pkt_bad, 故无 sof_recv, frame_no 不变
        //--------------------------------------------------------------------
        sof0 = ev_sof;
        pkt_sof(11'h155, 1'b1);
        idle_cycles(6);
        chk_pr(7'd85, 4'd2, `PID_SOF, 2'd1, 1'b1, "坏 CRC5 SOF 判坏");
        if ((ev_sof - sof0) != 0) begin
            $display("    FAIL: 坏 CRC5 SOF 仍出 sof_recv (%0d 次)", ev_sof - sof0);
            errors = errors + 1;
        end else $display("    OK  : 坏 CRC5 SOF 无 sof_recv");
        if (frame_no !== 11'h2AA) begin
            $display("    FAIL: 坏 CRC5 SOF 改了 frame_no (%03x)", frame_no);
            errors = errors + 1;
        end else $display("    OK  : 坏 CRC5 SOF 不动 frame_no");
        resp_chk_none("坏 CRC5 SOF");

        //--------------------------------------------------------------------
        // 3b) 帧号走两端 (7FF / 000): 只发 2AA 与 155 时, 11 位里有几位的回翻
        //     方向走不到。SOF 只更新 frame_no, 不应答、不入数据阶段。
        //--------------------------------------------------------------------
        pkt_sof(11'h7FF, 1'b0);
        idle_cycles(6);
        if (frame_no !== 11'h7FF) begin
            $display("    FAIL: 帧号 7FF 未载入 (%03x)", frame_no);
            errors = errors + 1;
        end else $display("    OK  : 帧号 7FF 载入");
        pkt_sof(11'h000, 1'b0);
        idle_cycles(6);
        if (frame_no !== 11'h000) begin
            $display("    FAIL: 帧号 000 未载入 (%03x)", frame_no);
            errors = errors + 1;
        end else $display("    OK  : 帧号 000 载入");
        resp_chk_none("帧号两端 SOF");

        //--------------------------------------------------------------------
        // 4) OUT token 地址失配 (addr=3, 设备地址 5) — 不派发
        //--------------------------------------------------------------------
        dwait_mark;
        pkt_token(`PID_TYPE_OUT, 7'd3, 4'd1, 1'b0);
        idle_cycles(6);
        chk_pr(7'd3, 4'd1, `PID_OUT, 2'd1, 1'b0, "地址失配 token 字段");
        chk_dwait(0, "地址失配不进数据阶段");

        //--------------------------------------------------------------------
        // 5) OUT token 端点点号越界 (endp=3 > EP_MAX) — 不派发
        //--------------------------------------------------------------------
        dwait_mark;
        pkt_token(`PID_TYPE_OUT, 7'd5, 4'd3, 1'b0);
        idle_cycles(6);
        chk_pr(7'd5, 4'd3, `PID_OUT, 2'd1, 1'b0, "越界端点 token 字段");
        chk_dwait(0, "端点越界不进数据阶段");

        //--------------------------------------------------------------------
        // 6) OUT token 坏 CRC5 (addr/endp 都对) — pkt_bad → 不派发
        //--------------------------------------------------------------------
        dwait_mark;
        pkt_token(`PID_TYPE_OUT, 7'd5, 4'd1, 1'b1);
        idle_cycles(6);
        chk_pr(7'd5, 4'd1, `PID_OUT, 2'd1, 1'b1, "坏 CRC5 token 判坏");
        chk_dwait(0, "坏 CRC5 token 不进数据阶段");

        //--------------------------------------------------------------------
        // 7) OUT token 正常 — 进数据阶段, 主机不发数据包 → 周转超时回空闲
        //    停留拍数应为 TURNAROUND_MAX = 15 (§2.10 计数口径)
        //--------------------------------------------------------------------
        dwait_mark;
        pkt_token(`PID_TYPE_OUT, 7'd5, 4'd1, 1'b0);
        idle_cycles(25);                            // 等超时判决 + 回空闲
        chk_pr(7'd5, 4'd1, `PID_OUT, 2'd1, 1'b0, "正常 OUT token 字段");
        chk_dwait(15, "周转超时");
        chk_tstate(F_IDLE, "超时后");
        resp_chk_none("孤立 token");

        if (errors == start_errs)
            $display("  PASS: case_token");
        else
            $display("  FAIL: case_token (%0d errors)", errors - start_errs);
    end
endtask
