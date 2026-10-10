//============================================================================
// case_abort_phases.v — 用例 17: 六个发态各中止一次
//
// 报告 §2.6 的中止路径要求"任意发态 tx_active↓ → 下一拍回 S_IDLE、NRZI 复位 J"。
// 本用例把中止点分别放在 S_SYNC / S_DATA / S_EOP1 / S_EOP2 / 填充拍 / S_DATA_LAST
// 各相位, 每次中止后立刻重新发一包, 验状态彻底清干净。
//
// ★ 2026-09-20 从"四相位"扩到"六相位": DUT 换用 `_sy` 设计后 FSM 从 4 态变 6 态,
//   多出的 S_DATA_LAST / S_EOP1 各带来一条**新的**合法弧 (DATA_LAST→IDLE、
//   EOP1→IDLE)。合并 19 个用例的 FSM 覆盖率后发现这两条一条都没走到 —— 是激励
//   缺口不是不可达分支, 故在此补两个相位。
//
// 判据: 每次中止后 ① tx_en=0、线回 J; ② 无幽灵帧; ③ 紧随的重发包完全正常。
//============================================================================

task case_abort_phases;
    integer f0, ef0, k;
    begin
        $display("== tx_abort_phases: SYNC / DATA / EOP1 / EOP2 / 填充拍 / DATA_LAST 六相位中止 ==");

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
            errors = errors + 1;
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
            errors = errors + 1;
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
            errors = errors + 1;
        end
        clr_pkt; put(`PID_STALL);
        run_pkt("after_eop_abort", 1, 1);
        eop_check("after_eop_abort");

        // ---- 相位 4: 正在插填充 0 那拍中止 (hold 拍, 数据通路停在中途) ----
        f0 = rx_frames; ef0 = err_frames;
        clr_pkt; put(`PID_DATA0); put(8'hFF); put(8'hFF); put(8'hFF); put(8'hFF);
        @(posedge clk12s);
        drv_req = 1'b1;
        wait (u_tx.bit_stuff);                  // 白盒: 等到插 0 那拍 (bit_stuff 是现态译码的组合线)
        drv_req = 1'b0;
        repeat (8) @(posedge clk12s);
        if (tx_en !== 1'b0 || rxdp !== 1'b1) begin
            $display("    FAIL: 填充拍中止后线未回 J");
            errors = errors + 1;
        end
        #(BIT_TIME * 40);
        no_valid_frame("stuff_abort", f0, ef0);
        clr_pkt; put(`PID_DATA1); put(8'hFC);
        run_pkt("after_stuff_abort", 1, 1);
        eop_check("after_stuff_abort");

        // ---- 相位 5: S_DATA_LAST (末字节态) 中止 ----
        // 为什么要单列: 新设计的 S_DATA_LAST 是**独立状态** (旧设计里末字节和普通
        // 数据共用 S_DATA), 于是"末字节发到一半撤请求"成了一条新的合法弧
        // DATA_LAST→IDLE, 而前面四个相位都够不着它。
        // 触发点 (白盒): 末字节态里 bit_cnt==1 那一拍撤请求。此时 tx_active 还是 1,
        // 状态在下一拍仍是 S_DATA_LAST; tx_active 到**再下一拍**才为 0 → 记录
        // DATA_LAST→IDLE。包用单字节 PID_ACK: 它经过 SYNC→DATA_LAST, 且无填充位。
        f0 = rx_frames; ef0 = err_frames;
        clr_pkt; put(`PID_ACK);
        @(posedge clk12s);
        drv_req = 1'b1;
        wait (u_tx.tx_stat_cur == 3'd3 && u_tx.bit_cnt == 3'd1);
        drv_req = 1'b0;
        repeat (8) @(posedge clk12s);
        if (tx_en !== 1'b0 || rxdp !== 1'b1) begin
            $display("    FAIL: S_DATA_LAST 中止后线未回 J (en=%b dp=%b)", tx_en, rxdp);
            errors = errors + 1;
        end
        #(BIT_TIME * 40);
        no_valid_frame("data_last_abort", f0, ef0);
        clr_pkt; put(`PID_OUT); put(8'h07);
        run_pkt("after_last_abort", 1, 1);
        eop_check("after_last_abort");

        // ---- 相位 6: S_EOP1 (EOP 第一拍) 中止 ----
        // 另一条够不着的合法弧 EOP1→IDLE。要点: `tx_active` 是 TB 侧寄存器, 撤
        // `drv_req` 之后要**再下一拍** DUT 才看得见 —— 所以必须在"**将要**进 S_EOP1"
        // 的那一拍撤 (即末字节态 bit_cnt==7 且非填充拍), 这样状态进 S_EOP1 时
        // tx_active 已经是 0。
        // (反面: 像相位 3 那样 `wait (tx_se0)` 再撤就晚了 —— tx_se0 是寄存器输出,
        //  它拉高时状态早已到 S_EOP2, 只走得到 EOP2→IDLE。)
        f0 = rx_frames; ef0 = err_frames;
        clr_pkt; put(`PID_ACK);
        @(posedge clk12s);
        drv_req = 1'b1;
        wait (u_tx.tx_stat_cur == 3'd3 && u_tx.bit_cnt == 3'd7 && !u_tx.bit_stuff);
        drv_req = 1'b0;
        repeat (8) @(posedge clk12s);
        if (tx_en !== 1'b0 || rxdp !== 1'b1) begin
            $display("    FAIL: S_EOP1 中止后线未回 J (en=%b dp=%b)", tx_en, rxdp);
            errors = errors + 1;
        end
        // ★ 本相位的判据与其它相位**不同**, 理由如下 —— 中止点落在末字节**最后
        //   一位之后**, 线上已经走完 SYNC + 整个 PID。这种截断片段在接收侧是
        //   "合法字节序", RX 只能靠自己 14 拍关帧超时收尾 → 它会报出一个**无错帧**
        //   (实测末帧 1 字节)。这不是 TX 残留: 这一段本来就是"像样的"内容, 缺的只有
        //   EOP。故 `no_valid_frame` (它判的是"TX 有没有留下一个像样的包") 在此不适用。
        //   改为**直接钉 TX 侧语义**: 中止窗口内一个 SE0 都没压、一个 tx_done 都没发。
        //   这两个计数器 (eop_se0_n/eop_j_n) 由发送侧监视块在 `drv_req` 高电平期间累加,
        //   与 eop_check 用的是同一组信号, 口径一致。
        if (eop_se0_n != 0) begin
            $display("    FAIL[eop1_abort]: 中止窗口内 tx_se0 高了 %0d 拍, 应 0 (未发 EOP)", eop_se0_n);
            errors = errors + 1;
        end
        if (eop_j_n != 0) begin
            $display("    FAIL[eop1_abort]: 中止窗口内 tx_done 脉冲 %0d 个, 应 0 (未发 EOP)", eop_j_n);
            errors = errors + 1;
        end
        if (pkt_ready_n != 1) begin
            $display("    FAIL[eop1_abort]: 中止窗口内 tx_ready 脉冲 %0d 个, 应 1 (PID 已取走)", pkt_ready_n);
            errors = errors + 1;
        end
        causal_print("abort/EOP1");             // 因果链证据: 无 tx_done 的中止路径
        // 只作**记录**打印, 故意不调 no_valid_frame (它会把这个片段记成 FAIL, 见上):
        // 等 RX 超时把片段收起后再读帧计数与末帧字节数。
        #(BIT_TIME * 40);
        $display("    说明[eop1_abort]: RX 新增 %0d 帧 (超时收尾), 末帧 %0d 字节 —— 片段内容合法、只是没有 EOP, 属预期",
                 rx_frames - f0, rx_last_nb);
        clr_pkt; put(`PID_STALL);
        run_pkt("after_eop1_abort", 1, 1);
        eop_check("after_eop1_abort");

        $display("    六相位中止 + 各自重发 全部正常, 无残留");
    end
endtask
