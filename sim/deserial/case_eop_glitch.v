//============================================================================
// case_eop_glitch.v — 帧内"亚判决点"SE0 毛刺 (EOP 定界的下限行为)
//
// 背景 (2026-09-16 覆盖率排查): DUT 域合并覆盖跑完后, 只剩这两条**真实可达**
// 的功能路径没被任何用例走到, 本 case 专门补激励:
//   L525 / L533 : eop_stat_cur 在 SE0_1 / SE0_2 上被"SE0 撤销"打断 → 作废回 IDLE;
//   L559 / L571 : eop_evt2 —— SE0 后**先回 K 再回 J** 的宽容收尾。
//   (行号 2026-09-20 按规则 7 改造后的 src/phy/usb_rx_deserial.v 重算。)
//
// 设计意图 (见 usb_rx_deserial.v 的 EOP FSM 注释):
//   - EOP 判决点 = eop_stat_cur 走到 ST_EOP_SE0_3, 即 SE0 连续 ≥3 个 ref_clk 采样
//     (≈62.5ns)。短于此的 SE0 是总线毛刺, 必须**作废、不关包** —— 否则线上
//     一个几十 ns 的抖动就能把正在收的帧截断;
//   - SE0 达判决点后若**不是** J 而是别的电平 → DEAD (异常收尾); 但若 DEAD 的
//     下一拍就是 J, 说明只是收尾抖动 → 宽容补判 eop (eop_evt2), 不判 eop_err。
//
// 时序依据 (可精确构造 1 拍 / 2 拍 SE0): TB 的电平跳变全部落在 BIT_TIME 整数倍,
//   而 ref_clk 上升沿落在 BIT_TIME 的 1/8、3/8、5/8、7/8 处 —— 即跳变点恰好
//   在两个上升沿**正中间**。故宽 w*(BIT_TIME/4) 的脉冲必被 line_s 采到**恰好 w 次**
//   (line_s 在 posedge ref_clk 采 {rxdp,rxdn}, 打 1 拍后 eop FSM 才见到)。
//
// 子步:
//   G1  SE0×1 拍 (0.25 bit): IDLE→SE0_1→IDLE 作废 (L525); 帧保持 DATA, 无 eop/eop_err
//   G2  SE0×2 拍 (0.5  bit): IDLE→SE0_1→SE0_2→IDLE 作废 (L533); 同上
//   G3  SE0×3 拍 + K×1 拍 + J : SE0_3→DEAD→(见 J) eop_evt2 宽容关包 (L559/L571)
//   G4  后窗: 毛刺后干净 OUT token 仍正常关包 (模块可复用)
//   每步都跟打印 因/变/果 三段证据 (见 sim/common/README.md 仿真确认规范)。
//============================================================================

// ---- 亚字节 SE0 毛刺: 宽 w 个 ref_clk 采样, 之后回到 lv (1=J / 0=K) ----
// 不加位填充、不经 bit_task —— 模拟的是线上真实电平抖动而非合法数据位。
task se0_glitch(input integer w, input integer lv);
    begin
        rxdp = 1'b0; rxdn = 1'b0;                       // 拉 SE0 (双线低)
        #(BIT_TIME * w / 4.0);                          // 保持 w 拍 ref_clk
        if (lv) begin rxdp = 1'b1; rxdn = 1'b0; end     // 回 J (D+ 高)
        else    begin rxdp = 1'b0; rxdn = 1'b1; end     // 回 K (D+ 低)
        nrzi_lv = lv;
    end
endtask

// ---- 观察窗: n 拍 ref_clk 内 eop_w / eop_err_w 是否曾置起 ----
// 展宽后两个电平各维持 ≥1 clk12m 周期 (667ns), 逐 ref_clk 采样不会漏沿。
task glitch_watch(input integer n, output reg saw_eop, output reg saw_err);
    integer k;
    begin
        saw_eop = 1'b0; saw_err = 1'b0;
        for (k = 0; k < n; k = k + 1) begin
            #(BIT_TIME / 4.0);                          // 1 拍 ref_clk
            if (u_dut.eop_w)     saw_eop = 1'b1;
            if (u_dut.eop_err_w) saw_err = 1'b1;
        end
    end
endtask

task case_eop_glitch;
    integer start_errs, frame_before;
    reg     saw_eop, saw_err;
    begin
        start_errs = errors;
        stim_rx_abort = 0; stim_tx_active = 0;
        $display("== deserial_eop_glitch: 帧内亚判决点 SE0 (1/2 拍作废, SE0->K->J 宽容收尾) ==");

        //--------------------------------------------------------------------
        // G1: SE0×1 拍 (0.25 bit) — 在 EOP 判决点 (3 拍) 之下, 必须作废不关包
        //--------------------------------------------------------------------
        frame_before = close_cnt;
        body_ready_k0();                     // SYNC+PID(OUT), 停 K, ones=0, 已进 DATA
        se0_glitch(1, 1'b0);                 // SE0×1 拍 → 回 K
        glitch_watch(6, saw_eop, saw_err);   // 观察 6 拍 ref_clk
        if (close_cnt != frame_before) begin
            $display("    FAIL: G1 SE0×1 拍把关中的帧关掉了 (close_cnt %0d->%0d)",
                     frame_before, close_cnt);
            errors = errors + 1;
        end else if (saw_eop || saw_err) begin
            $display("    FAIL: G1 SE0×1 拍起了 eop=%0d / eop_err=%0d (应全 0)",
                     saw_eop, saw_err);
            errors = errors + 1;
        end else if (dut_st_cur != 2'd2) begin
            $display("    FAIL: G1 帧未保持 USB_DATA (st=%0d)", dut_st_cur);
            errors = errors + 1;
        end else
            $display("    G1 ok: 因 SE0×1 拍 → 变 eop_stat_cur IDLE→SE0_1→IDLE (L525 作废) → 果 帧仍 DATA, 无 eop/eop_err");
        // 后窗: 毛刺后补一个真 EOP, 帧应正常关包且 err=0 (毛刺没留下副作用)
        eop_task;
        wait_close(frame_before + 1, 300);
        if (close_cnt < frame_before + 1) begin
            $display("    FAIL: G1 毛刺后真 EOP 未关包");
            errors = errors + 1;
        end else if (last_err !== 1'b0) begin
            $display("    FAIL: G1 毛刺后真 EOP 关包 err=%0d (应 0)", last_err);
            errors = errors + 1;
        end else
            $display("    G1 后窗 ok: 毛刺后真 EOP 正常关包 err=0");
        #(BIT_TIME * 6);

        //--------------------------------------------------------------------
        // G2: SE0×2 拍 (0.5 bit) — 仍差 1 拍到判决点, 同样作废
        //--------------------------------------------------------------------
        frame_before = close_cnt;
        body_ready_k0();
        se0_glitch(2, 1'b0);                 // SE0×2 拍 → 回 K
        glitch_watch(6, saw_eop, saw_err);
        if (close_cnt != frame_before) begin
            $display("    FAIL: G2 SE0×2 拍把关中的帧关掉了 (close_cnt %0d->%0d)",
                     frame_before, close_cnt);
            errors = errors + 1;
        end else if (saw_eop || saw_err) begin
            $display("    FAIL: G2 SE0×2 拍起了 eop=%0d / eop_err=%0d (应全 0)",
                     saw_eop, saw_err);
            errors = errors + 1;
        end else if (dut_st_cur != 2'd2) begin
            $display("    FAIL: G2 帧未保持 USB_DATA (st=%0d)", dut_st_cur);
            errors = errors + 1;
        end else
            $display("    G2 ok: 因 SE0×2 拍 → 变 eop_stat_cur IDLE→SE0_1→SE0_2→IDLE (L533 作废) → 果 帧仍 DATA, 无 eop/eop_err");
        eop_task;
        wait_close(frame_before + 1, 300);
        if (close_cnt < frame_before + 1) begin
            $display("    FAIL: G2 毛刺后真 EOP 未关包");
            errors = errors + 1;
        end else if (last_err !== 1'b0) begin
            $display("    FAIL: G2 毛刺后真 EOP 关包 err=%0d (应 0)", last_err);
            errors = errors + 1;
        end else
            $display("    G2 后窗 ok: 毛刺后真 EOP 正常关包 err=0");
        #(BIT_TIME * 6);

        //--------------------------------------------------------------------
        // G3: SE0×3 拍 (达判决点) + K×1 拍 + J — DEAD 态见 J → 宽容补判 eop
        //     判据: 关包 err 必须 =0 (走 eop_evt2 而非 eop_err_evt)
        //--------------------------------------------------------------------
        frame_before = close_cnt;
        body_ready_k0();
        se0_glitch(3, 1'b0);                 // SE0×3 拍 → 回 K (达判决点 SE0_3)
        #(BIT_TIME / 4.0);                   // K 保持恰好 1 拍 (SE0_3 见非 J → DEAD)
        rxdp = 1'b1; rxdn = 1'b0;            // 回 idle J (DEAD 下一拍见 J)
        nrzi_lv = 1'b1;
        wait_close(frame_before + 1, 300);
        if (close_cnt < frame_before + 1) begin
            $display("    FAIL: G3 SE0→K→J 未关包 (宽容收尾 eop_evt2 未生效)");
            errors = errors + 1;
        end else if (last_err !== 1'b0) begin
            $display("    FAIL: G3 关包 err=%0d (eop_evt2 应判 eop, 不该判 eop_err)", last_err);
            errors = errors + 1;
        end else
            $display("    G3 ok: 因 SE0×3+K×1+J → 变 eop_stat_cur SE0_3→DEAD→(见 J) eop_evt2 (L559/L571) → 果 宽容关包 err=0");
        #(BIT_TIME * 6);

        //--------------------------------------------------------------------
        // G4: 后窗 — 毛刺/异常收尾之后, 干净包必须照常收 (模块可复用)
        //--------------------------------------------------------------------
        frame_before = close_cnt;
        out_packet_task(7'd5, 4'd0, 4, -1, 4);
        wait_close(frame_before + 1, 300);
        if (close_cnt < frame_before + 1) begin
            $display("    FAIL: G4 毛刺后干净 OUT token 未关包");
            errors = errors + 1;
        end else if (last_err !== 1'b0) begin
            $display("    FAIL: G4 干净 OUT token 关包 err=%0d (应 0)", last_err);
            errors = errors + 1;
        end else
            $display("    G4 后窗 ok: 毛刺后干净 OUT token 正常关包 err=0 (nbyte=%0d)", last_nbyte);

        if (errors == start_errs)
            $display("  PASS: case_eop_glitch (亚判决点 SE0 作废 + DEAD 见 J 宽容收尾)");
        else
            $display("  FAIL: case_eop_glitch (%0d errors)", errors - start_errs);
    end
endtask
