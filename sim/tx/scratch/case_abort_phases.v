//============================================================================
// case_abort_phases.v — 用例 17 (新增): 三个发态各中止一次
//
// 报告 §2.6 的中止路径要求"任意发态 tx_active↓ → 下一拍回 S_IDLE、NRZI 复位 J"。
// 本用例把中止点分别放在 S_SYNC / S_DATA / S_EOP 三个相位 (含"正在插填充 0 那拍"),
// 每次中止后立刻重新发一包, 验状态彻底清干净。
//
// 判据: 每次中止后 ① tx_en=0、线回 J; ② 无幽灵帧; ③ 紧随的重发包完全正常。
//============================================================================

task case_abort_phases;
    integer f0, ef0, k;
    begin
        $display("== tx_abort_phases: SYNC / DATA / EOP / 填充拍 四相位中止 ==");

        // ---- 相位 1: SYNC 段中间中止 ----
        f0 = rx_frames; ef0 = err_frames;
        clr_pkt; put(`PID_DATA0); put(8'hFF); put(8'hFF); put(8'h3C); put(8'h5A);
        @(posedge clk12s);
        drv_req = 1'b1;
        repeat (4) @(posedge clk12s);           // SYNC 第 3~4 拍
        drv_req = 1'b0;
        repeat (8) @(posedge clk12s);
        if (tx_en !== 1'b0 || rxdp !== 1'b1 || rxdn !== 1'b0) begin
            $display("    FAIL: SYNC 期中止后线未回 J (en=%b dp=%b dn=%b)", tx_en, rxdp, rxdn);
            err_hit(E_ABORT_LINE);
        end
        #(BIT_TIME * 40);
        no_valid_frame("sync_abort", f0, ef0);
        clr_pkt; put(`PID_ACK);
        run_pkt("after_sync_abort", 1, 1);

        // ---- 相位 2: 数据段中间中止 (已发若干字节) ----
        f0 = rx_frames; ef0 = err_frames;
        clr_pkt; put(`PID_DATA1);
        for (k = 0; k < 8; k = k + 1)
            put(8'hFF);
        put(8'h3C); put(8'h5A);
        @(posedge clk12s);
        drv_req = 1'b1;
        repeat (40) @(posedge clk12s);          // SYNC 8 + 数据 ~32 拍 = 4 个字节
        drv_req = 1'b0;
        repeat (8) @(posedge clk12s);
        if (tx_en !== 1'b0 || rxdp !== 1'b1) begin
            $display("    FAIL: 数据段中止后线未回 J");
            err_hit(E_ABORT_LINE);
        end
        #(BIT_TIME * 40);
        no_valid_frame("data_abort", f0, ef0);
        clr_pkt; put(`PID_NAK);
        run_pkt("after_data_abort", 1, 1);
        eop_check("after_data_abort");

        // ---- 相位 3: EOP 的 SE0 段中止 ----
        f0 = rx_frames; ef0 = err_frames;
        clr_pkt; put(`PID_ACK);
        @(posedge clk12s);
        drv_req = 1'b1;
        wait (tx_se0);                          // 等到 SE0 那一拍
        drv_req = 1'b0;
        repeat (8) @(posedge clk12s);
        if (tx_en !== 1'b0 || rxdp !== 1'b1 || rxdn !== 1'b0) begin
            $display("    FAIL: EOP SE0 期中止后线未回 J (dp=%b dn=%b)", rxdp, rxdn);
            err_hit(E_ABORT_LINE);
        end
        clr_pkt; put(`PID_STALL);
        run_pkt("after_eop_abort", 1, 1);
        eop_check("after_eop_abort");

        // ---- 相位 4: 正在插填充 0 那拍中止 (hold 拍, 数据通路停在中途) ----
        f0 = rx_frames; ef0 = err_frames;
        clr_pkt; put(`PID_DATA0); put(8'hFF); put(8'hFF); put(8'hFF); put(8'hFF);
        @(posedge clk12s);
        drv_req = 1'b1;
        wait (u_tx.bit_stuff);                 // 白盒: 等到插 0 那拍
        drv_req = 1'b0;
        repeat (8) @(posedge clk12s);
        if (tx_en !== 1'b0 || rxdp !== 1'b1) begin
            $display("    FAIL: 填充拍中止后线未回 J");
            err_hit(E_ABORT_LINE);
        end
        #(BIT_TIME * 40);
        no_valid_frame("stuff_abort", f0, ef0);
        clr_pkt; put(`PID_DATA1); put(8'hFC);
        run_pkt("after_stuff_abort", 1, 1);
        eop_check("after_stuff_abort");

        $display("    四相位中止 + 各自重发 全部正常, 无残留");
    end
endtask
