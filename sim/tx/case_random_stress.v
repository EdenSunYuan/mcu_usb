//============================================================================
// case_random_stress.v — 用例 19 (新增): 随机长度 / 随机字节密集压测
//
// 定向用例把"已知会出问题的形状"逐条压过一遍; 本用例反过来, 用固定种子的伪随机
// 序列在形状空间里撒网, 专门制造跨字节边界、字节末位、连续多字节的填充组合 ——
// 本模块两个已修缺陷 (NRZI 电平在插 0 拍漏更新、data_end 把中途插 0 误判成收尾)
// 都落在这一片, 随机撒网是防回归最便宜的网。
//
// 判据: 每包同跑 A 回环 + B 逐位 oracle, 任一不符即报错并带出包内容。
//       种子由 +seed=<n> 指定 (默认固定), 换种子即可换一批样本。
//============================================================================

task case_random_stress;
    integer k, n, nb, seed, seed0, r;
    reg [7:0] b;
    begin
        $display("== tx_random_stress: 随机长度/随机字节 密集压测 ==");
        if (!$value$plusargs("seed=%d", seed))
            seed = 32'h1234_5678;               // 默认固定种子 (可复现)
        seed0 = seed;                            // $random 会就地改写 seed, 留一份原值打印

        for (k = 0; k < 300; k = k + 1) begin
            // ---- 包长 2~17 字节 (PID + 1~16 数据) ----
            r  = $random(seed);
            nb = (r % 16);
            if (nb < 0) nb = -nb;
            nb = nb + 2;

            clr_pkt;
            put(`PID_DATA0);

            for (n = 1; n < nb; n = n + 1) begin
                b = $random(seed) & 8'hFF;
                // 1/4 概率换成长连 1 字节: 把样本密度推到填充逻辑最密的地方
                r = $random(seed);
                if (r[1:0] == 2'd0) b = 8'hFF;  // 8 连 1 (字节内必插 1 次)
                else if (r[1:0] == 2'd1) b = 8'hFE;  // 7 连 1 (第 6 个落在 bit6)
                else if (r[1:0] == 2'd2) b = 8'hFC;  // 6 连 1 (第 6 个落在 bit7)
                if (n == (nb - 1))
                    put(~b);                    // 末字节取反, 让收尾填充形态也随机
                else
                    put(b);
            end

            run_pkt("rand", 1, 1);
        end

        eop_check("rand");
        $display("    随机压测 300 包全过 (seed0=%08x)", seed0);
    end
endtask
