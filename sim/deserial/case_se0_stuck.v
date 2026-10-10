//============================================================================
// case_se0_stuck.v — SE0 卡死 (≥2.5µs, disconnect 场景) 行为对照
//
// 注入: SYNC+PID+归零到 K(ones=0), 然后物理 SE0 长 2.6µs, 再回 idle J 释放。
//
// 预期差异 (本次研究要量化的风险):
//   现行 RTL: SE0 卡死被解成连续 1 → ~7 个后进 USB_ERROR, 再过 ~7 个在
//             ERROR 态 7 连 1 → 回 IDLE (零定时器自愈, ~1.2µs 即自行关包,
//             err=1), 剩余 SE0 期间停在 IDLE, 回 J 无动作。
//   门控版:   SE0 区 7 连 1 被掩 → 不检错不自愈, 停在 DATA (rx_active 高、
//             不吐字节), 直到 SE0→J 才经 eop 干净关包 (err=0, 时长≈2.6µs)。
//
// 本 case 只测量打印 (两版差异本身即"要记入报告"的结论), 不自动判定。
//============================================================================

task case_se0_stuck;
    integer start_errs;
    time     t_start;
    begin
        start_errs = errors;
        $display("== deserial_se0_stuck: SE0 held 2.6us then J release ==");

        body_ready_k0();                    // SYNC+PID, 停到 K, ones=0
        t_start = $time;
        $display("    t=%0t  SE0 asserted (frame should be open)", t_start);
        raw_se0(2600.0);                    // SE0 卡死 2.6us (> 2.5us 插拔阈值)
        // 回 idle J 释放
        rxdp = 1'b1; rxdn = 1'b0; nrzi_lv = 1'b1;
        $display("    t=%0t  J released", $time);

        wait_close(1, 200);                 // 等关包 (若已自愈则早已 close)
        if (close_cnt < 1) begin
            $display("    RISK: no frame close even after SE0->J (frame stuck?)");
            errors = errors + 1;
        end else begin
            $display("    frame: open@%0t close@%0t  dur=%0t  nbyte=%0d  err=%0d",
                     last_open_t, last_close_t, last_close_t - last_open_t,
                     last_nbyte, last_err);
            $display("    NOTE: dur≈%.1fus + err=%0d => %0s",
                     (last_close_t - last_open_t) / 1000.0, last_err,
                     (last_err) ? "self-heal via 7-ones (baseline path)"
                                : "clean release on SE0->J (gated path)");
        end

        #(BIT_TIME * 10);
        if (errors == start_errs) $display("  PASS: case_se0_stuck");
        else                      $display("  FAIL: case_se0_stuck (%0d errors)", errors - start_errs);
    end
endtask
