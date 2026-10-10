//============================================================================
// case_err_eop.v — 异常注入 & 状态机恢复 (USB_ERROR → USB_IDLE 各释放路径)
//
// 逐一验证 RX 定稿的物理检错与恢复行为, 每步异常后都跟一个干净 OUT token,
// 证明模块"报错后能回 USB_IDLE、rx_error 回 idle 即清、可继续收下一包"。
//
//   E1 bad-EOP: 帧尾 SE0 后回 K(非 J) → eop_err → USB_ERROR, 关包 err=1;
//               总线随后静默回 J → 7连1 idle 探针 → 释放回 IDLE (路径②/①)。
//   E2 no-EOP : 截断包 (body 后无 SE0, 线直接回 J) → DATA 态 idle-J 凑出 7 连 1
//               → 物理检错 err=1 → ERROR → 探针自愈回 IDLE (零定时器)。
//   E3 rx_abort@DATA : 收包中 SIE 中止 → 强制回 IDLE, 不置 err (路径③)。
//   E4 rx_abort@ERROR: 真 7 连 1 已进 ERROR (rx_error=1) 后中止 → 立即回 IDLE 且
//               rx_error 当场清 0 (不再等 idle 探针)。
//   E5 tx_active     : 自发送门控把收包 FSM 从 DATA 强回 IDLE (路径③, 收发互斥)。
//   E6 usb_rst@DATA  : core 复位 (软复位场景, 线在 J) 一个 clk12m 周期脉冲 → 帧机
//               当拍回 IDLE、不置 err、不漏字节; ref 域 line_s 采样不受影响。
//   E7 usb_rst@SE0   : 总线复位场景 (帧中总线转长 SE0) → 复位脉冲把帧机从 DATA 打回
//               IDLE, 总线回 J 后无幽灵帧, 可继续收包。
//   E8 usb_rst@ERROR : 已置的错误电平 (rx_error=1) 跟 core 复位一起清, 不等 idle 探针。
//============================================================================

// ---- 等 DUT 帧状态机回到 USB_IDLE 且 rx_active=0 (内部白盒) ----
task wait_dut_idle(input integer tmo, output reg ok);
    integer guard;
    begin
        ok = 1'b0; guard = 0;
        while (dut_st_cur != 2'd0 && guard < tmo) begin
            #(BIT_TIME);
            guard = guard + 1;
        end
        if (dut_st_cur != 2'd0) begin
            $display("    FAIL: DUT not back to USB_IDLE (st=%0d)", dut_st_cur);
            errors = errors + 1;
        end else if (u_dut.rx_active) begin
            $display("    FAIL: rx_active still high in USB_IDLE");
            errors = errors + 1;
        end else
            ok = 1'b1;
    end
endtask

// ---- 干净 OUT token (addr=5,endp=0) 恢复校验: 证明报错后模块可复用 ----
task chk_clean_out(input integer idx);
    integer frame_before, k;
    reg [4:0] c5;
    reg [6:0] ad;
    reg [7:0] b1, b2;
    begin
        frame_before = close_cnt;
        out_packet_task(7'd5, 4'd0, 4, -1, 4);
        wait_close(frame_before + 1, 300);
        c5 = crc5_tx(7'd5, 4'd0);
        ad = 7'd5;
        b1 = 8'h00; b2 = 8'h00;
        for (k = 0; k < 7; k = k + 1) b1[k] = ad[k];     // b1 = addr (endp0)
        for (k = 0; k < 5; k = k + 1) b2[k+3] = c5[4-k]; // b2 = crc5 上移 (endp[1:3]=0, MSB first)
        chk_frame(idx, 3, 1'b0, 8'hE1, b1, b2, 8'h00, 8'h00, 8'h00);
    end
endtask

task case_err_eop;
    integer start_errs, frame_before, bc;
    reg okd;
    reg [1:0] ls_pre, ls_post;
    begin
        start_errs = errors;
        okd = 1'b0;
        stim_rx_abort = 0; stim_tx_active = 0;
        $display("== deserial_err_eop: bad-EOP / no-EOP / abort / tx_active recovery ==");

        //--------------------------------------------------------------------
        // E1: bad-EOP 尾 (SE0 → K → J idle) — EOP 错 → ERROR, 探针自愈, err=1
        //--------------------------------------------------------------------
        frame_before = close_cnt;
        body_ready_k0();                 // SYNC+PID(OUT), 停 K, ones=0, 已进 DATA
        raw_se0(2.0 * BIT_TIME);         // EOP SE0 (≥3 采样 → 确认)
        drive_dpdn(1'b0, BIT_TIME);      // SE0 后回 K (非 J) → eop_err (EOP 错)
        rxdp = 1'b1; rxdn = 1'b0; nrzi_lv = 1'b1;   // 总线静默回 idle J
        wait_close(frame_before + 1, 300);
        if (close_cnt < frame_before + 1)
            $display("    FAIL: E1 no close (bad-EOP did not self-heal)");
        else if (last_err !== 1'b1) begin
            $display("    FAIL: E1 err=%0d, expected 1 (SE0->K bad EOP must flag)", last_err);
            errors = errors + 1;
        end else
            $display("    E1 ok: bad-EOP(SE0->K) -> err=1, self-released");
        // 因果链打印 (2026-09-07: 仅证据, 不参与 pass/fail)
        if (close_cnt >= frame_before + 1) begin
            causal_print("E1 bad-EOP 探针自愈", 1);
            causal_post("E1");
        end
        wait_dut_idle(200, okd);         // 确保已回 IDLE (探针释放完成)
        #(BIT_TIME * 8);
        chk_clean_out(10);               // 报错后能继续收干净包

        //--------------------------------------------------------------------
        // E2: 截断 token (无 EOP, body 后线回 J) — DATA 内 idle 7连1 → err=1 自愈
        //--------------------------------------------------------------------
        frame_before = close_cnt;
        token_noeop_packet_task(`PID_TYPE_OUT, 7'd5, 4'd0, 4, -1, 4);
        wait_close(frame_before + 1, 300);
        if (close_cnt < frame_before + 1)
            $display("    FAIL: E2 no close (no-EOP did not self-heal)");
        else if (last_err !== 1'b1) begin
            $display("    FAIL: E2 err=%0d, expected 1 (no-EOP idle must self-heal)", last_err);
            errors = errors + 1;
        end else
            $display("    E2 ok: no-EOP truncated pkt -> err=1, self-released (zero-timer)");
        wait_dut_idle(200, okd);
        #(BIT_TIME * 8);
        chk_clean_out(11);

        //--------------------------------------------------------------------
        // E3: rx_abort @DATA (PID 已入, body 未完) — 强制回 IDLE, 不置 err
        //--------------------------------------------------------------------
        frame_before = close_cnt;
        bc = 0;
        sync_task(4, -1, 4, bc);
        pid_task(`PID_TYPE_OUT, 4, -1, 4);   // 进 DATA, PID 字节已收
        #(BIT_TIME * 2);
        stim_rx_abort = 1;
        #(BIT_TIME * 3);
        stim_rx_abort = 0;
        rxdp = 1'b1; rxdn = 1'b0; nrzi_lv = 1'b1;
        wait_dut_idle(200, okd);             // 中止一拍回 IDLE
        if (rx_error !== 1'b0) begin
            $display("    FAIL: E3 rx_abort left rx_error=1");
            errors = errors + 1;
        end else
            $display("    E3 ok: rx_abort@DATA -> IDLE, rx_error=0");
        #(BIT_TIME * 4);
        chk_clean_out(12);

        //--------------------------------------------------------------------
        // E4: rx_abort @ERROR — 真 7 连 1 已进 ERROR(rx_error=1), 中止立即清并回 IDLE
        //--------------------------------------------------------------------
        body_ready_k0();                     // DATA, K, ones=0
        raw_hold(1'b0, 8);                   // K×8 → 数据中段真 7 连 1 → ERROR
        #(BIT_TIME * 2);                     // 稳定在 ERROR (探针尚未放行)
        if (rx_error !== 1'b1) begin
            $display("    FAIL: E4 never reached ERROR (rx_error=%0d)", rx_error);
            errors = errors + 1;
        end else if (dut_st_cur != 2'd3) begin
            $display("    FAIL: E4 st_stat_cur=%0d, expected USB_ERROR=3", dut_st_cur);
            errors = errors + 1;
        end else begin
            stim_rx_abort = 1;
            #(BIT_TIME * 3);
            stim_rx_abort = 0;
            rxdp = 1'b1; rxdn = 1'b0; nrzi_lv = 1'b1;
            if (rx_error !== 1'b0) begin
                $display("    FAIL: E4 rx_abort@ERROR did not clear rx_error");
                errors = errors + 1;
            end else
                $display("    E4 ok: rx_abort@ERROR -> IDLE, rx_error cleared immediately");
            // 因果链打印 (2026-09-07: 仅证据, 不参与 pass/fail)
            // E4 的"果"是 abort 立即释放 (非坏包 EOP/7连1 自愈关包), 单独成形——
            // 上面断言未推时间, rx_error 仍为当场采样值 (期望 0 = 已清)。
            $display("因果链·E4 rx_abort@ERROR 立即清");
            if (causal_bad)
                $display("  变: 帧中真 7 连 1 检错 → st: USB_DATA→USB_ERROR @%0t (进 ERROR 前已出 %0d 字节, rx_error=1 保持)",
                         causal_t_err, causal_fbn_err);
            else
                $display("  变: (未记录到 DATA→USB_ERROR, 注入前未达 ERROR)");
            $display("  果: rx_abort@ERROR 注入 → 采样 rx_error=%0d (期望 0 = 当场清, 与坏包自愈的 err=1 区分); 回 USB_IDLE 由后窗复验; 判据: 中止不回走 7连1 探针",
                     rx_error);
            causal_post("E4");
            wait_dut_idle(200, okd);
            #(BIT_TIME * 4);
            chk_clean_out(13);
        end

        //--------------------------------------------------------------------
        // E5: tx_active @DATA (自发送门控) — 与接收互斥, 强回 IDLE
        //--------------------------------------------------------------------
        bc = 0;
        sync_task(4, -1, 4, bc);
        pid_task(`PID_TYPE_OUT, 4, -1, 4);
        #(BIT_TIME * 2);
        stim_tx_active = 1;
        #(BIT_TIME * 3);
        stim_tx_active = 0;
        rxdp = 1'b1; rxdn = 1'b0; nrzi_lv = 1'b1;
        wait_dut_idle(200, okd);
        if (rx_error !== 1'b0) begin
            $display("    FAIL: E5 tx_active left rx_error=1");
            errors = errors + 1;
        end else
            $display("    E5 ok: tx_active@DATA -> IDLE, rx_error=0");
        #(BIT_TIME * 4);
        chk_clean_out(14);

        //--------------------------------------------------------------------
        // E6: usb_rst @DATA (软复位场景: 总线静止在 J) — 1 个 clk12m 周期脉冲
        //     果: 帧机当拍回 IDLE、rx_error 保持 0、本帧只吐 PID 一个字节;
        //     因: core 复位脉冲 → frame_clr → st_stat_nxt=USB_IDLE (与 rx_abort 同路)
        //     附: ref 域 line_s 采样寄存器不被复位碰 (线是 J, 被打成 SE0 会污染
        //         共用它的 usb_bus_state) — 观测窗内线钉住不动, 逐 ref 沿比对
        //--------------------------------------------------------------------
        frame_before = close_cnt;
        bc = 0;
        sync_task(4, -1, 4, bc);
        pid_task(`PID_TYPE_OUT, 4, -1, 4);   // 进 DATA, PID 字节已吐
        #(BIT_TIME * 2);
        rxdp = 1'b1; rxdn = 1'b0; nrzi_lv = 1'b1;   // 线回 idle J 并钉住 (软复位: 总线上没动作)
        #(BIT_TIME * 2);
        ls_pre  = dut_line_s;
        ls_dirty = 1'b0; ls_watch = 1'b1;           // 开观测窗 (窗内线必须静止)
        pulse_usb_rst();                            // 恰 1 个 clk12m 周期
        #(BIT_TIME);                                // 过一个 ref 沿再看采样寄存器
        ls_post = dut_line_s;
        ls_watch = 1'b0;
        if (dut_st_cur != 2'd0 || u_dut.rx_active !== 1'b0) begin
            $display("    FAIL: E6 usb_rst did not force frame machine to IDLE (st=%0d rx_active=%b)",
                     dut_st_cur, u_dut.rx_active);
            errors = errors + 1;
        end else if (rx_error !== 1'b0) begin
            $display("    FAIL: E6 usb_rst set rx_error (must stay 0)");
            errors = errors + 1;
        end else if (u_dut.rx_valid !== 1'b0) begin
            $display("    FAIL: E6 rx_valid high right after usb_rst");
            errors = errors + 1;
        end else if (ls_pre !== 2'b10 || ls_post !== 2'b10 || ls_dirty) begin
            $display("    FAIL: E6 line_s disturbed by usb_rst (pre=%b post=%b dirty=%b, line=J)",
                     ls_pre, ls_post, ls_dirty);
            errors = errors + 1;
        end else
            $display("    E6 ok: usb_rst@DATA(J) -> IDLE in 1 clk12m, err=0, line_s untouched");
        wait_close(frame_before + 1, 200);
        if (close_cnt < frame_before + 1)
            $display("    FAIL: E6 frame never closed by usb_rst");
        else if (last_nbyte != 1 || last_err !== 1'b0)
            $display("    FAIL: E6 closed frame nbyte=%0d err=%0d (expect 1 byte = PID, err=0)",
                     last_nbyte, last_err);
        else
            $display("    E6 ok: frame closed with nbyte=1 (PID only), err=0");
        #(BIT_TIME * 4);
        chk_clean_out(15);

        //--------------------------------------------------------------------
        // E7: usb_rst @长 SE0 (总线复位场景) — 帧中总线转 SE0, 帧还开着时来复位脉冲
        //     (usb_bus_state 判出总线复位 → 并进 usb_rst, 就是这个时序)
        //--------------------------------------------------------------------
        frame_before = close_cnt;
        body_ready_k0();                     // 进 DATA, 线停在 K
        raw_se0(2.0 * BIT_TIME);             // 总线转 SE0 (≥3 ref 采样 → EOP FSM 到 se0_3 自环)
        if (dut_st_cur != 2'd2 || u_dut.rx_active !== 1'b1) begin
            $display("    FAIL: E7 frame not open during SE0 (st=%0d rx_active=%b)",
                     dut_st_cur, u_dut.rx_active);
            errors = errors + 1;
        end else begin
            pulse_usb_rst();                 // 线仍 SE0, 帧开着 → 复位脉冲
            if (dut_st_cur != 2'd0 || u_dut.rx_active !== 1'b0) begin
                $display("    FAIL: E7 usb_rst@SE0 did not force IDLE (st=%0d rx_active=%b)",
                         dut_st_cur, u_dut.rx_active);
                errors = errors + 1;
            end else
                $display("    E7 ok: usb_rst@SE0 -> IDLE, frame dropped");
            rxdp = 1'b1; rxdn = 1'b0; nrzi_lv = 1'b1;   // 总线静默回 idle J
            wait_close(frame_before + 1, 200);
            if (close_cnt < frame_before + 1)
                $display("    FAIL: E7 frame never closed");
            else if (last_err !== 1'b0)
                $display("    FAIL: E7 err=%0d, expected 0 (usb_rst 不是检错)", last_err);
            else
                $display("    E7 ok: closed err=0, no ghost frame on SE0->J");
        end
        wait_dut_idle(200, okd);
        #(BIT_TIME * 4);
        chk_clean_out(16);

        //--------------------------------------------------------------------
        // E8: usb_rst @ERROR — 已置的错误电平跟 core 复位一起清 (不等 idle 探针)
        //--------------------------------------------------------------------
        body_ready_k0();                     // DATA, K, ones=0
        raw_hold(1'b0, 8);                   // K×8 → 数据中段真 7 连 1 → ERROR
        #(BIT_TIME * 2);                     // 稳定在 ERROR (探针尚未放行)
        if (rx_error !== 1'b1) begin
            $display("    FAIL: E8 never reached ERROR (rx_error=%0d)", rx_error);
            errors = errors + 1;
        end else if (dut_st_cur != 2'd3) begin
            $display("    FAIL: E8 st_stat_cur=%0d, expected USB_ERROR=3", dut_st_cur);
            errors = errors + 1;
        end else begin
            pulse_usb_rst();
            if (dut_st_cur != 2'd0) begin
                $display("    FAIL: E8 usb_rst@ERROR did not force IDLE (st=%0d)", dut_st_cur);
                errors = errors + 1;
            end else if (rx_error !== 1'b0) begin
                $display("    FAIL: E8 usb_rst@ERROR did not clear rx_error");
                errors = errors + 1;
            end else
                $display("    E8 ok: usb_rst@ERROR -> IDLE, rx_error cleared immediately");
            rxdp = 1'b1; rxdn = 1'b0; nrzi_lv = 1'b1;
            wait_dut_idle(200, okd);
            #(BIT_TIME * 4);
            chk_clean_out(17);
        end

        if (errors == start_errs) $display("  PASS: case_err_eop (bad-EOP/no-EOP/abort/tx_active/usb_rst all recover to IDLE)");
        else                      $display("  FAIL: case_err_eop (%0d errors)", errors - start_errs);
    end
endtask
