//============================================================================
// case_susp_wkup.v — 用例 20 (新增): 挂起与远程唤醒的 K 驱动
//
// 判据: 挂起态（bus_suspended=1）下包路径停、线交高阻；sie_wkup=1 时线上驱 K，
//       撤下后立刻回高阻；唤醒结束后紧跟一包仍能正常回环。
//
// 因果链（每条都带前后窗与量化判据，见各段 $display）:
//   因 bus_suspended↑ → 变 tx_en 下一拍落 0 → 果 线回高阻（rxdp=1/rxdn=0，上拉 J）
//   因 sie_wkup↑ → 变 tx_en 下一拍起 1、tx_bit 落 0 → 果 线上 K（rxdp=0/rxdn=1）
//   因 sie_wkup↓ → 变 tx_en 下一拍落 0 → 果 线回 J（不驱到 J，靠 1.5k 上拉）
//
// ★ 为什么不能只测 K 的电平: 唤醒信令是"连续 K"，接收链看不到 SYNC → 不该解出
//   任何字节。所以每段都要顺带查 rx_frames/rx_valid 不动 —— 否则一个"发了半包"
//   的实现也能骗过电平检查。
//============================================================================

task case_susp_wkup;
    integer f0, n0, k;
    integer t_susp_hi, t_en_lo, t_wkup_hi, t_en_hi, t_wkup_lo, t_en_lo2;
    integer k_width, off_ok;
    begin
        $display("== tx_susp_wkup: 挂起 + 远程唤醒 K ==");

        // ---- 段 0: 基线一包（证明挂起路径没被接线碰坏）----
        clr_pkt; put(`PID_OUT); put(8'h22); put(8'h10);
        run_pkt("susp_base", 1, 1);
        eop_check("susp_base");
        if (rxdp !== 1'b1 || rxdn !== 1'b0) begin
            $display("    FAIL: 基线包后线不是 J");
            errors = errors + 1;
        end

        // ---- 段 1: bus_suspended↑ → 交高阻（前窗: 上面已确认空闲 J 且 tx_en=0）----
        f0 = rx_frames;
        @(posedge clk12s);
        t_susp_hi = cyc;
        bus_suspended = 1'b1;
        @(posedge clk12s);
        t_en_lo = cyc;
        if (tx_en !== 1'b0) begin
            $display("    FAIL: bus_suspended↑ 后 tx_en 未落 0 (仍为 %b)", tx_en);
            errors = errors + 1;
        end
        if (tx_bit !== 1'b1) begin
            $display("    FAIL: 挂起且未请求唤醒时 tx_bit 不是 J(=1)，实为 %b", tx_bit);
            errors = errors + 1;
        end
        repeat (40) @(posedge clk12s);              // 挂起持续 40 拍 (>2 个包时间)
        if (rxdp !== 1'b1 || rxdn !== 1'b0) begin
            $display("    FAIL: 挂起期间线不是 J (rxdp=%b rxdn=%b)", rxdp, rxdn);
            errors = errors + 1;
        end
        if (rx_frames != f0) begin
            $display("    FAIL: 挂起期间出现幽灵帧 (+%0d)", rx_frames - f0);
            errors = errors + 1;
        end
        $display("  因果链·[susp] 因: bus_suspended↑ @cyc %0d (线在 idle、tx_en 已为 0)", t_susp_hi);
        $display("  因果链·[susp] 变: tx_en @cyc %0d = %b（挂起 + 无唤醒请求 → 交高阻）", t_en_lo, tx_en);
        $display("  因果链·[susp] 果: 挂起 40 拍内 rxdp/rxdn 恒 J、rx_frames 无新增（判据: 无幽灵帧）");

        // ---- 段 2: sie_wkup↑ → 线上驱 K（唤醒信令）----
        f0 = rx_frames;
        @(posedge clk12s);
        t_wkup_hi = cyc;
        sie_wkup = 1'b1;
        @(posedge clk12s);
        t_en_hi = cyc;
        if (tx_en !== 1'b1) begin
            $display("    FAIL: sie_wkup↑ 后 tx_en 未起 1 (仍为 %b)", tx_en);
            errors = errors + 1;
        end
        if (tx_bit !== 1'b0) begin
            $display("    FAIL: sie_wkup↑ 后 tx_bit 不是 K(=0)，实为 %b", tx_bit);
            errors = errors + 1;
        end
        if (rxdp !== 1'b0 || rxdn !== 1'b1) begin
            $display("    FAIL: 线上不是 K (rxdp=%b rxdn=%b)", rxdp, rxdn);
            errors = errors + 1;
        end

        // 持续 120 拍 (= 120 bit 时间 ≈ 10µs, 折合设备侧的 2.5µs 门限已远超; 真实
        // 远程唤醒是 1~15ms, 仿真里按拍数等比缩短, 不影响本模块的行为判据)
        k_width = 120;
        for (k = 0; k < k_width; k = k + 1) begin
            @(posedge clk12s);
            if (rxdp !== 1'b0 || rxdn !== 1'b1) begin
                $display("    FAIL: K 期间第 %0d 拍线不是 K (rxdp=%b rxdn=%b)", k, rxdp, rxdn);
                errors = errors + 1;
                k = k_width;
            end
        end
        if (rx_frames != f0) begin
            $display("    FAIL: 唤醒 K 被接收链解成了帧 (+%0d, 末帧 %0d 字节)", rx_frames - f0, rx_last_nb);
            errors = errors + 1;
        end
        $display("  因果链·[wkup] 因: sie_wkup↑ @cyc %0d（挂起中）", t_wkup_hi);
        $display("  因果链·[wkup] 变: tx_en @cyc %0d 起 1、tx_bit 落 0（K = 驱动 + 线电平 0）", t_en_hi);
        $display("  因果链·[wkup] 果: 线上 K 连续 %0d 拍（判据: 逐拍 rxdp=0/rxdn=1），且 rx_frames 无新增", k_width);

        // ---- 段 3: sie_wkup↓ → 交高阻回 J（规范: 结束不驱到 J）----
        @(posedge clk12s);
        t_wkup_lo = cyc;
        sie_wkup = 1'b0;
        @(posedge clk12s);
        t_en_lo2 = cyc;
        if (tx_en !== 1'b0) begin
            $display("    FAIL: 撤 sie_wkup 后 tx_en 未落 0 (仍为 %b)", tx_en);
            errors = errors + 1;
        end
        if (tx_bit !== 1'b1) begin
            $display("    FAIL: 唤醒结束后 tx_bit 未回 J，实为 %b", tx_bit);
            errors = errors + 1;
        end
        #(BIT_TIME * 20);                           // 等线上稳定
        if (rxdp !== 1'b1 || rxdn !== 1'b0) begin
            $display("    FAIL: 唤醒结束后线不是 J (rxdp=%b rxdn=%b)", rxdp, rxdn);
            errors = errors + 1;
        end
        $display("  因果链·[wkup] 因: sie_wkup↓ @cyc %0d → 变 tx_en @cyc %0d 落 0 → 果 交高阻，线由 1.5k 上拉回 J（不驱到 J）",
                 t_wkup_lo, t_en_lo2);

        // ---- 段 4: 挂起期间误发 tx_active —— 契约外的一次刻意违约, 只作记录 ----
        // 契约(报告 §2.11, 用户 2026-09-22 定): 唤醒期间 SIE 不得拉 tx_active、不得摆新
        // tx_data, 协调归 SIE。本段故意违约, 记录的事实是"违约也不会把包发出去" ——
        // 那是旁路分支在 D 链上优先级最高的副产品, 不是本模块的保证。
        f0 = rx_frames;
        drv_req = 1'b1;                             // 故意在挂起中提发送请求
        repeat (12) @(posedge clk12s);              // 放任状态机跑一会
        off_ok = 0;
        if (tx_en === 1'b0 && rxdp === 1'b1 && rxdn === 1'b0) off_ok = 1;
        // ★ 两个字符串不要写成三元表达式再喂 %0s: iverilog 会把三元结果当定宽向量,
        //   中文多字节被按位截断成乱码。分开印。
        if (off_ok == 1)
            $display("  说明[wkup] 契约外违约: 挂起中误发 tx_active 12 拍 → tx_en=%b, 线=%b/%b, st=%0d (驱动被压住, 线上无残留; 非设计要求)",
                     tx_en, rxdp, rxdn, u_tx.tx_stat_cur);
        else
            $display("  说明[wkup] 契约外违约: 挂起中误发 tx_active 12 拍 → tx_en=%b, 线=%b/%b, st=%0d ★ 线被动过",
                     tx_en, rxdp, rxdn, u_tx.tx_stat_cur);
        if (off_ok != 1) begin
            $display("    FAIL: 挂起中 tx_active 把驱动器带起来了 (tx_en=%b rxdp=%b rxdn=%b)", tx_en, rxdp, rxdn);
            errors = errors + 1;
        end
        if (rx_frames != f0) begin
            $display("    FAIL: 挂起中误发请求在线上留下了帧 (+%0d)", rx_frames - f0);
            errors = errors + 1;
        end
        drv_req = 1'b0;                             // 撤请求（DUT 走中止路径回 S_IDLE）
        repeat (4) @(posedge clk12s);
        clr_pkt;                                    // 幻包留下的字节队列清掉
        drv_idx  = 0;
        drv_busy = 1'b0;

        // ---- 段 5: 撤挂起 → 唤醒后收发正常（回归门）----
        bus_suspended = 1'b0;
        repeat (8) @(posedge clk12s);
        n0 = rx_frames;
        clr_pkt; put(`PID_IN); put(8'h33); put(8'h44); put(8'h12);
        run_pkt("after_wake", 1, 1);
        eop_check("after_wake");
        if (rx_frames <= n0) begin
            $display("    FAIL: 唤醒后回环没有收到帧");
            errors = errors + 1;
        end
        $display("  说明[wkup] 撤挂起后发包正常回环 (新帧 %0d 个, 末帧 %0d 字节)",
                 rx_frames - n0, rx_last_nb);

        // ---- 收尾: 无挂起时 sie_wkup 单独为 1 不生效（防 SIE 接错线）----
        @(posedge clk12s);
        sie_wkup = 1'b1;
        repeat (6) @(posedge clk12s);
        if (tx_en !== 1'b0 || tx_bit !== 1'b1) begin
            $display("    FAIL: 未挂起时 sie_wkup 单独为 1 竟然开了驱动器 (tx_en=%b)", tx_en);
            errors = errors + 1;
        end else
            $display("  说明[wkup] 未挂起时 sie_wkup 单独为 1: 驱动器仍关（唤醒请求只在挂起态生效）");
        sie_wkup = 1'b0;
        #(BIT_TIME * 4);
    end
endtask
