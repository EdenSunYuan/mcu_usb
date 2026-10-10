//============================================================================
// case_sync_scan.v — SYNC 检测接受窗口扫描 (0 多 / 0 少 / 边界)
//
// 【被测规则】(usb_rx_deserial.v 的 USB_SYNC_SEEK 分支, SYNC_MIN_ZERO=4)
//   检测器"数连续解码 0, 凑够 N 个再来个 1"才算命中:
//     · 命中:   第 1 个 1 到达且 zero_cnt >= 4          → 进 USB_DATA (开包)
//     · 拒收①:  1 到达但 zero_cnt < 4  (0 太少, 假触发) → 回 USB_IDLE
//     · 拒收②:  zero_cnt 已 =7 又来一个 0 (第 8 个 0)   → 回 USB_IDLE (0 太多)
//   ⇒ 接受窗口 = 判决时"本轮计入的连续 0 个数" cnt ∈ [4, 7]
//
// 【判据为什么用实测 cnt 而不是"我发了几个 0"】
//   发射端发 z 个 0 后, 经 CDR 锁相/吃位 (见 case_tail_scan 注释: 帧间 idle 后
//   下一个 SYNC 会吃 1 bit), 到达 deserial 的连跑长度可能是 z、z-1 或 z-2。
//   用发射值下判据会被 CDR 吃位污染。
//   故 tb 侧记录器在判决拍定格两个量 (见 tb_deserial.v "SYNC 判决记录器"):
//     run = tb 自数的解码 0 连跑 (黑盒, 物理输入)  ·  cnt = DUT zero_cnt 折算 (白盒)
//   判据: 用 cnt 判窗口; 每次注入**首个**判决额外断言 run == cnt —— 把"zero_cnt
//   数得对不对"用黑盒钉死, 之后再用 cnt 判窗口就不是自证。
//
// 【注入】把 SYNC 的 7 个 0 改成 z 个 0, 扫 z = 1..11:
//   · z ∈ {1,2,3}   0 太少带: 只发 SYNC 替身 + J 长保持 → 必拒收, 且不得开包
//   · z ∈ {4..9}    扫描带:   SYNC 替身 + 真 token body → 按实测 cnt 判 (收/拒都要对)
//   · z ∈ {10,11}   0 太多带: 只发 SYNC 替身 + J 长保持 → 必拒收, 且不得开包
//   (J 长保持 = 后续解码全 1, 杜绝残余 0 再凑出假 SYNC, 使"不开包"成为确定判据;
//    z 上限取 11: 第 8 个 0 已触发拒收, 余下 z-8 ≤3 个 0 即便再进 SEEK 也够不到 4,
//    不会出现"合法重触发"污染"无命中"判据。)
//
// 【判据】
//   1. 逐判决: 命中 ⟹ cnt ∈ [4,7]; 空拒(0 太少) ⟹ cnt ≤ 3; 满拒(0 太多) ⟹ cnt ≥ 8
//   2. 每次注入首个判决: 实测 run == DUT 侧 cnt           (黑盒↔白盒交叉核对)
//   3. z ∈ {1,2,3,10,11}: 本次注入 0 次命中 且 close_cnt 不变   (无幽灵帧)
//   4. 本次注入首个判决即命中: 后随 token 须干净解出 e1 05 58 且 err=0
//                                                          (SYNC 对齐正确)
//   5. 全扫收口(窗口边界): 接受最小 cnt >= 4; 0 太少最大 cnt <= 3; 0 太多最小 cnt >= 8
//   6. 收尾: 再发标准 OUT 须正常收下                        (状态机无卡死)
//============================================================================

// ---- 发 z 个 0 + 1 个 1, 再 J 长保持 16 bit (后续全 1, 杜绝假 SYNC) ----
task sync_scan_send_bare(input integer z);
    integer k;
    begin
        for (k = 0; k < z; k = k + 1)
            bit_task(1'b0, 4);                 // 连续 0 (NRZI 每拍翻转)
        bit_task(1'b1, 4);                     // SYNC 尾 1 (电平保持)
        raw_hold(1, 16);                       // J 保持 = 解码全 1, 不会再凑出 0 连跑
    end
endtask

// ---- 发 SYNC 替身 (z 个 0 + 1) 后接真 OUT token body + EOP ----
// body 完全照抄 token_packet_task 里 SYNC 之后的部分 (PID/ADDR/ENDP/CRC5/EOP)
task sync_scan_send_token(input integer z, input [6:0] addr, input [3:0] endp);
    integer k, i;
    reg [4:0] c5;
    begin
        for (k = 0; k < z; k = k + 1)
            bit_task(1'b0, 4);
        bit_task(1'b1, 4);

        pid_task(`PID_TYPE_OUT, 4, -1, 4);
        for (i = 0; i < 7; i = i + 1) bit_task(addr[i], 4);
        for (i = 0; i < 4; i = i + 1) bit_task(endp[i], 4);
        c5 = crc5_tx(addr, endp);
        for (i = 0; i < 5; i = i + 1) bit_task(c5[4-i], 4);   // CRC5 MSB first
        eop_task;
    end
endtask

task case_sync_scan;
    integer start_errs;
    integer z, d, dec_before, dec_after, cl_before, n_dec;
    integer nacc, nfew, nmany;                 // 三类判决计数
    integer acc_min, few_max, many_min;        // 三类判决的 cnt 极值
    integer hit_any, hit_first, cnt_this, run_this;
    reg [1:0] code_this;
    begin
        start_errs = errors;
        nacc = 0; nfew = 0; nmany = 0;
        acc_min = 99; few_max = -1; many_min = 99;
        $display("== deserial_sync_scan: SYNC 接受窗口扫描 (SYNC 的 0 个数 z=1..11) ==");
        $display("   规则: 命中 ⟺ 判决时本轮计入 0 个数 cnt ∈ [4,7]  (SYNC_MIN_ZERO=4)");

        // ---- 预热: 标准 OUT token, 先锁 CDR + 自检 ----
        cl_before = close_cnt;
        out_packet_task(7'd5, 4'd1, 4, -1, 4);
        wait_close(cl_before + 1, 250);
        if (close_cnt < cl_before + 1)
            begin $display("    FAIL: 预热帧未关包"); errors = errors + 1; end
        else if (last_nbyte != 3 || last_bytes[0] != 8'hE1 || last_err)
            begin
                $display("    FAIL: 预热帧字节错 (nbyte=%0d b0=%02x err=%0d)",
                         last_nbyte, last_bytes[0], last_err);
                errors = errors + 1;
            end
        else
            $display("    预热: 标准 OUT token 干净收下 (e1 05 58, err=0)");
        #(BIT_TIME * 8);

        // ---- 扫描 z = 1..11 ----
        for (z = 1; z <= 11; z = z + 1) begin
            dec_before = sync_dec_n;
            cl_before  = close_cnt;

            if (z <= 3 || z >= 10) sync_scan_send_bare(z);               // 拒绝带
            else                   sync_scan_send_token(z, 7'd5, 4'd1);  // 扫描带

            #(BIT_TIME * 4);

            dec_after = sync_dec_n;
            n_dec = dec_after - dec_before;
            hit_any = 0; hit_first = 0;

            $write("    z=%0d:", z);
            if (n_dec == 0) $write(" 无判决");

            for (d = dec_before; d < dec_after; d = d + 1) begin
                code_this = sync_code_q[d % 32];
                run_this  = sync_run_q[d % 32];
                cnt_this  = sync_cnt_q[d % 32];
                if (d == dec_before) hit_first = (code_this == 2'd0);
                if (code_this == 2'd0) hit_any = 1;

                // 打印: run 与 cnt 不同则一并显示 (扫描带后续判决 run 会跨多次 SEEK)
                if (run_this == cnt_this) begin
                    if (code_this == 2'd0) $write("  [命中 run=%0d]", run_this);
                    else if (code_this == 2'd1) $write("  [拒收-0少 run=%0d]", run_this);
                    else $write("  [拒收-0多 run=%0d]", run_this);
                end
                else begin
                    if (code_this == 2'd0) $write("  [命中 run=%0d cnt=%0d]", run_this, cnt_this);
                    else if (code_this == 2'd1) $write("  [拒收-0少 run=%0d cnt=%0d]", run_this, cnt_this);
                    else $write("  [拒收-0多 run=%0d cnt=%0d]", run_this, cnt_this);
                end

                // 判据 1: 判决 ⟺ cnt 落在哪个区间
                if (code_this == 2'd0) begin
                    nacc = nacc + 1;
                    if (cnt_this < acc_min) acc_min = cnt_this;
                    if (!(cnt_this >= 4 && cnt_this <= 7)) begin
                        $display("    FAIL: z=%0d 判决#%0d 命中但 cnt=%0d 越出窗口 [4,7]",
                                 z, d, cnt_this);
                        errors = errors + 1;
                    end
                end
                else if (code_this == 2'd1) begin
                    nfew = nfew + 1;
                    if (cnt_this > few_max) few_max = cnt_this;
                    if (cnt_this > 3) begin
                        $display("    FAIL: z=%0d 判决#%0d 以'0 太少'拒收但 cnt=%0d > 3",
                                 z, d, cnt_this);
                        errors = errors + 1;
                    end
                end
                else begin
                    nmany = nmany + 1;
                    if (cnt_this < many_min) many_min = cnt_this;
                    if (cnt_this < 8) begin
                        $display("    FAIL: z=%0d 判决#%0d 以'0 太多'拒收但 cnt=%0d < 8",
                                 z, d, cnt_this);
                        errors = errors + 1;
                    end
                end

                // 判据 2: 本次注入首个判决, 黑盒实测 run 必须等于白盒 cnt
                if (d == dec_before && run_this != cnt_this) begin
                    $display("    FAIL: z=%0d 首个判决 run=%0d != cnt=%0d (zero_cnt 与物理 0 连跑不符)",
                             z, run_this, cnt_this);
                    errors = errors + 1;
                end
            end
            $write("   close_delta=%0d\n", close_cnt - cl_before);

            // 判据 3: 0 太少 / 0 太多带, 不得开包
            if ((z <= 3 || z >= 10) && (hit_any || close_cnt != cl_before)) begin
                $display("    FAIL: z=%0d 0 个数越界却开了包 (hit=%0d close_delta=%0d)",
                         z, hit_any, close_cnt - cl_before);
                errors = errors + 1;
            end

            // 判据 4: 首个判决即命中 → 后随 token 必须干净解出 (SYNC 对齐正确)
            if (hit_first) begin
                wait_close(cl_before + 1, 250);
                if (close_cnt < cl_before + 1) begin
                    $display("    FAIL: z=%0d 命中但未关包", z);
                    errors = errors + 1;
                end
                else if (last_nbyte != 3 || last_bytes[0] != 8'hE1 || last_err) begin
                    $display("    FAIL: z=%0d 命中后字节错 (nbyte=%0d b0=%02x err=%0d)",
                             z, last_nbyte, last_bytes[0], last_err);
                    errors = errors + 1;
                end
            end

            #(BIT_TIME * 8);
        end

        // ---- 判据 5: 窗口边界 (三类判决的 cnt 极值) ----
        $display("    判决统计: 命中 %0d 次 (最小 cnt=%0d) / 拒收-0少 %0d 次 (最大 cnt=%0d) / 拒收-0多 %0d 次 (最小 cnt=%0d)",
                 nacc, acc_min, nfew, few_max, nmany, many_min);
        if (nacc == 0 || nfew == 0 || nmany == 0) begin
            $display("    FAIL: 扫描未覆盖全部三类判决 (命中=%0d 0少=%0d 0多=%0d)",
                     nacc, nfew, nmany);
            errors = errors + 1;
        end
        if (acc_min < 4) begin
            $display("    FAIL: 命中最小 cnt=%0d < 4 — SYNC_MIN_ZERO 应等于 4", acc_min);
            errors = errors + 1;
        end
        if (few_max > 3) begin
            $display("    FAIL: '0 太少'最大 cnt=%0d > 3 — 窗口下边界不是 4", few_max);
            errors = errors + 1;
        end
        if (many_min < 8) begin
            $display("    FAIL: '0 太多'最小 cnt=%0d < 8 — 窗口上边界不是 7", many_min);
            errors = errors + 1;
        end

        // ---- 判据 6: 收尾拿标准 token, 证明状态机无卡死 ----
        cl_before = close_cnt;
        out_packet_task(7'd5, 4'd1, 4, -1, 4);
        wait_close(cl_before + 1, 250);
        if (close_cnt < cl_before + 1)
            begin $display("    FAIL: 收尾帧未关包 (状态机可能卡死)"); errors = errors + 1; end
        else if (last_nbyte != 3 || last_bytes[0] != 8'hE1 || last_err)
            begin
                $display("    FAIL: 收尾帧字节错 (nbyte=%0d b0=%02x err=%0d)",
                         last_nbyte, last_bytes[0], last_err);
                errors = errors + 1;
            end
        else
            $display("    收尾: 扫描后标准 OUT token 仍干净收下 (无卡死)");

        #(BIT_TIME * 10);
        if (errors == start_errs) $display("  PASS: case_sync_scan");
        else                      $display("  FAIL: case_sync_scan (%0d errors)", errors - start_errs);
    end
endtask
