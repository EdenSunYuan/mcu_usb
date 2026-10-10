//============================================================================
// case_abort.v — 用例 10: 发送中途 tx_active↓ (中止, 报告 §2.6)
//
// 语义: tx_en = tx_active 直通 → 撤请求当拍线路就交高阻; 模块在下一个 clk12m
//       沿回 S_IDLE 并复位 NRZI 到 J, 不留残留填充/半字节。
// 判据: ① tx_active 立即失效、线回 J; ② 接收侧**无幽灵帧**;
//       ③ 中止后重新发包能正常起来 (状态无残留)。
//============================================================================

task case_abort;
    integer f0, ef0;
    begin
        $display("== tx_abort: 发送中途撤请求 ==");

        // ---- 数据段中止 ----
        f0 = rx_frames; ef0 = err_frames;
        clr_pkt; put(`PID_DATA0); put(8'hFF); put(8'hFF); put(8'h3C); put(8'h5A);
        @(posedge clk12s);
        drv_req = 1'b1;
        repeat (14) @(posedge clk12s);      // SYNC 8 拍 + 数据段若干拍
        drv_req = 1'b0;
        @(posedge clk12s);
        repeat (4) @(posedge clk12s);

        if (tx_active !== 1'b0) begin
            $display("    FAIL: 中止后 tx_active 未撤");
            errors = errors + 1;
        end
        if (tx_en !== 1'b0) begin
            $display("    FAIL: 中止后 tx_en 未撤 (驱动未交高阻)");
            errors = errors + 1;
        end
        if (rxdp !== 1'b1 || rxdn !== 1'b0) begin
            $display("    FAIL: 中止后线未回 J (dp=%b dn=%b)", rxdp, rxdn);
            errors = errors + 1;
        end
        #(BIT_TIME * 50);
        no_valid_frame("data_abort", f0, ef0);

        // ---- 中止后重新发一包: 必须完全正常 (无残留半字节/填充计数) ----
        clr_pkt; put(`PID_OUT); put(8'h07); put(8'h10);
        run_pkt("after_abort", 1, 1);
        eop_check("after_abort");

        // ---- 连发两包, 中间夹一次中止 ----
        clr_pkt; put(`PID_ACK);
        run_pkt("before_abort", 1, 1);

        f0 = rx_frames; ef0 = err_frames;
        clr_pkt; put(`PID_DATA1); put(8'h55); put(8'hAA); put(8'h3C); put(8'h5A);
        @(posedge clk12s);
        drv_req = 1'b1;
        repeat (3) @(posedge clk12s);       // 刚进 SYNC 就撤
        drv_req = 1'b0;
        // ★ 间隔必须 > RX 关帧超时, 否则截断片段和下一包会粘成一帧 (2026-09-20 修):
        //   中止后线回 J 而不是 SE0, RX 收不到 EOP, 要靠自己的超时 (实测 14 拍 ≈1.17us)
        //   才关帧。原来只等 6 拍 → 片段帧还开着下一包就来了, 两段位流并成一帧,
        //   after_abort2 收到 2 字节 (1f 50) 被判 FAIL; 同时 no_valid_frame 那一拍
        //   rx_frames 还没变, 判据空转 (日志里连"说明[sync_abort]"都不打)。
        #(BIT_TIME * 30);                       // 30 拍 ≈2.5us, 留足余量 (同第 1 段的 50 拍)
        causal_print("abort/SYNC");             // 因果链证据: 无 tx_done 的中止路径 (报告 §4.8 规范)
        no_valid_frame("sync_abort", f0, ef0);

        clr_pkt; put(`PID_NAK);
        run_pkt("after_abort2", 1, 1);

        $display("    中止语义: 撤请求即交高阻 + 下一拍回空闲, 无幽灵帧, 重发正常");
    end
endtask
