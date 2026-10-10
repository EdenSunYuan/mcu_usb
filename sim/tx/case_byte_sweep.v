//============================================================================
// case_byte_sweep.v — 用例 13 (新增): 全部 256 种字节值扫描
//
// 每个字节值各发一包 (PID + 该字节), 逐位 oracle + 回环比对。
// 这是最彻底的"位序 / 填充 / hold"覆盖: 任何在某个位型下才暴露的错误
// (填充插入位置错、hold 条件错、末字节收尾错) 都会被这 256 包扫出来。
//============================================================================

task case_byte_sweep;
    integer v, bad;
    begin
        $display("== tx_byte_sweep: 256 种字节值全覆盖 ==");

        bad = 0;
        for (v = 0; v < 256; v = v + 1) begin
            clr_pkt; put(`PID_DATA0); put(v[7:0]);
            run_pkt("sweep", 1, 1);
            if (errors > 0) begin
                $display("    FAIL: 字节值 0x%02x 出错 (累计 %0d)", v, errors);
                bad = bad + 1;
                if (bad > 4) disable case_byte_sweep;   // 别把日志刷爆
            end
        end

        // 反向扫描: 字节放在 PID 位置不放 (PID 必须是合法值), 所以第二遍改成
        // 把该字节同时作为载荷的首/尾字节, 覆盖"跨字节连 1 累计"的另一侧。
        for (v = 0; v < 256; v = v + 1) begin
            clr_pkt; put(`PID_DATA1); put(v[7:0]); put(v[7:0]);
            run_pkt("sweep2", 1, 1);
            if (errors > 0) begin
                $display("    FAIL: 字节值 0x%02x (双字节) 出错", v);
                disable case_byte_sweep;
            end
        end

        $display("    256 × 2 种字节组合全部通过 (逐位 oracle + 回环)");
    end
endtask
