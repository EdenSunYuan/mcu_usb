//============================================================================
// case_stuff_viol.v — 真位填充违规 (7 连 1, 非 SE0) 仍须检错
//
// 目的 (门控版风险项): EOP SE0 区门控只该掐"SE0 被解成 1"的假阳性;
// 真 7 连 1 发生在 K 电平 (D+ 低, D- 高), 线不是 SE0 → EOP FSM 停在 eop_idle
// → 门控不生效 → 7 连 1 必须照常进 USB_ERROR 并置 rx_error。
//
// 注入: SYNC+PID+归零到 K(ones=0) 后, 用 raw_hold 物理再发 7 个 K 位
// (跨越位数连续 = 7 连 1, 数据中段真违规), 然后 EOP 收尾。
// 预期两版一致: 关包 err=1。
//============================================================================

task case_stuff_viol;
    integer start_errs;
    begin
        start_errs = errors;
        $display("== deserial_stuff_viol: genuine 7-ones in DATA (line K, not SE0) ==");

        body_ready_k0();                    // SYNC+PID, 停到 K, deserial ones=0
        raw_hold(1'b0, 7);                  // 物理 7 个 K 位 = 7 连 1 (数据中段违规)
        eop_task;                           // EOP 收尾

        wait_close(1, 250);
        dump_last_frame();

        if (close_cnt < 1) begin
            $display("    FAIL: no frame close observed");
            errors = errors + 1;
        end else begin
            if (!last_err) begin
                $display("    FAIL: genuine 7-ones NOT flagged (err=0 at close)");
                errors = errors + 1;
            end else begin
                $display("    OK: genuine 7-ones flagged (err=1 at close)");
            end
        end

        // 因果链打印 (2026-09-07: 仅证据, 不参与 pass/fail)
        if (close_cnt >= 1) begin
            causal_print("stuff_viol 真7连1 错保持+释放", 1);
            causal_post("stuff_viol");
        end

        #(BIT_TIME * 10);
        if (errors == start_errs) $display("  PASS: case_stuff_viol");
        else                      $display("  FAIL: case_stuff_viol (%0d errors)", errors - start_errs);
    end
endtask
