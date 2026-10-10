//============================================================================
// case_tail_scan.v — EOP 尾假 7 连 1 扫描 (基线 vs 门控 的核心对照)
//
// 对 R∈[rmin,rmax] 各发一帧: SYNC+PID+归零+K 电平 R 个 1+真 EOP。
// 对每帧打印: 关包时刻 / 吐字节数 / 关包 rx_error。
//   R=4  → 安全;  R=5 → SE0 解出的 1 补到第 7 个(需 2 个 SE0 解码);  R=6 → 首个
//          SE0 解码即第 7 个(最危险)。扫描 R 可看出"现行版在哪断 / 门控版是否全清"。
//
// 自检: TAIL_EXP_CLEAN(门控编译 -D) 时所有帧 err 必须 =0; 可用 +exp_clean=0/1 覆盖。
//============================================================================

task case_tail_scan;
    integer rmin, rmax, R, frame_before, exp_clean, start_errs;
    begin
        start_errs = errors;
        rmin = 3;  rmax = 6;
        if (!$value$plusargs("rmin=%0d", rmin)) ;
        if (!$value$plusargs("rmax=%0d", rmax)) ;
        exp_clean = 0;
`ifdef TAIL_EXP_CLEAN
        exp_clean = 1;
`endif
        if (!$value$plusargs("exp_clean=%0d", exp_clean)) ;   // 可选覆盖 (用返回值, 免 as-task warning)
        $display("== deserial_tail_scan: trailing K-run R=%0d..%0d + real EOP (exp_clean=%0d) ==",
                 rmin, rmax, exp_clean);

        for (R = rmin; R <= rmax; R = R + 1) begin
            frame_before = close_cnt;
            send_tail_pkt(R);
            wait_close(frame_before + 1, 250);
            if (close_cnt < frame_before + 1) begin
                $display("    R=%0d:  NO CLOSE (timeout)  <-- RISK", R);
                errors = errors + 1;
            end else begin
                $display("    R=%0d:  open@%0t close@%0t  dur=%0t  nbyte=%0d  err=%0d",
                         R, last_open_t, last_close_t, last_close_t - last_open_t,
                         last_nbyte, last_err);
                if (exp_clean && last_err) begin
                    $display("    FAIL: exp_clean but err=1 at R=%0d", R);
                    errors = errors + 1;
                end
            end
            #(BIT_TIME * 6);                 // 帧间 idle (CDR 保持锁相, 后续 SYNC 吃 1 bit)
        end

        if (errors == start_errs) $display("  PASS: case_tail_scan");
        else                      $display("  FAIL: case_tail_scan (%0d errors)", errors - start_errs);
    end
endtask
