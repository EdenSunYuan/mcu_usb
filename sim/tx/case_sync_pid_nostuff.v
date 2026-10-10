//============================================================================
// case_sync_pid_nostuff.v — 用例 6: 16 种合法 PID × 8 种后续字节
//
// 判据: SYNC+PID 段**一个填充位都不插** (线上前 16 位 = SYNC + PID 原样)。
//
// 原理 (报告 §2.5): PID = code(4) + ~code(4), LSb 先发 code 再发 ~code;
// 跨 nibble 的连 1 成立要求 code[3]=1 且 code[0]=0, 与 4 连 1 要求的
// code[0]=1 矛盾 → 任意合法 PID 内最多 4 连 1。SYNC 尾 1 接上这 4 个 = 5 < 6。
//
// 独立判据: 直接比对线上前 16 位 (不依赖 build_expected 的填充模型)。
//============================================================================

task case_sync_pid_nostuff;
    integer p, j, ones, k, bad;
    reg [7:0] pid;
    reg [7:0] follow [0:7];
    begin
        $display("== tx_sync_pid_nostuff: SYNC/PID 段不插填充位 ==");

        follow[0] = 8'h00; follow[1] = 8'hFF; follow[2] = 8'h07; follow[3] = 8'hF0;
        follow[4] = 8'h3F; follow[5] = 8'hFC; follow[6] = 8'hA5; follow[7] = 8'h0E;

        // ---- 16 种 XX~XX 形态全覆盖 ----
        // pid = {~code, code}: 低 4 位 = code, 高 4 位 = ~code。跑遍 code 的
        // 全部 16 个取值 —— 11 个有定义的 PID (OUT/IN/SOF/…) 只是其中的子集,
        // 结构证明 (§2.5) 对全部 16 种形态成立, 这里就全扫一遍。
        for (p = 0; p < 16; p = p + 1) begin
            pid = {~p[3:0], p[3:0]};

            // 单字节包: SYNC + PID
            clr_pkt; put(pid);
            run_pkt("sync_pid", 1, 1);
            sync_pid_nostuff_check("sync_pid", pid);

            // 结构自检: PID 字节内最多 4 连 1 (证明前提本身成立)
            ones = 0; bad = 0;
            for (k = 0; k < 8; k = k + 1) begin
                if (pid[k]) ones = ones + 1;
                else        ones = 0;
                if (ones > 4) bad = 1;
            end
            if (bad) begin
                $display("    FAIL: PID %02x 字节内连 1 超过 4 (前提不成立)", pid);
                errors = errors + 1;
            end

            // 两字节包: PID + 各种后续字节 (边界处由 PID 尾巴 + 后续字节头决定)
            for (j = 0; j < 8; j = j + 1) begin
                clr_pkt; put(pid); put(follow[j]);
                run_pkt("sync_pid2", 1, 1);
                sync_pid_nostuff_check("sync_pid2", pid);
            end
        end

        $display("    16 PID × (1 + 8) 包全部通过 SYNC/PID 段无填充位检查");
    end
endtask
