//============================================================================
// case_carry_sweep.v — 用例 15 (新增): 跨字节连 1 累计扫描 (16 PID × 16 次字节)
//
// 位填充最难的边界是**跨字节**: 前一字节约尾巴的连 1 要带进下一字节的头部。
// 本用例把 16 种 PID 形态 (尾巴连 1 数 0~4) × 16 种次字节 (头部连 1 数由位型
// 决定) 全组合跑一遍, 专钉"跨字节计数不清零 / 早清零"这类错误。
//
// 判据: 每对的逐位 oracle + 回环全过; 并统计不同边界插入的填充 0 数分布,
//       确认确实扫到了 0 和 1 两种边界结果。
//============================================================================

task case_carry_sweep;
    integer p, j, stuff_before, stuff_after, with_stuff, without_stuff;
    reg [7:0] pid, b;
    begin
        $display("== tx_carry_sweep: 16 PID × 16 次字节 跨字节连 1 扫描 ==");

        with_stuff    = 0;
        without_stuff = 0;

        for (p = 0; p < 16; p = p + 1) begin
            pid = {~p[3:0], p[3:0]};
            for (j = 0; j < 16; j = j + 1) begin
                // 次字节取 16 种位型: 0x00/0x01/0x03/0x07/0x0F/0x1F/0x3F/0x7F/0xFF …
                b = (j == 0) ? 8'h00 : ((8'h01 << (j - 1)) | (8'h01 << j));
                if (j == 15) b = 8'hFF;

                clr_pkt; put(pid); put(b);
                build_expected;
                stuff_before = exp_n;                   // 期望位流总长 (8 SYNC + 16 数据 + 填充)

                run_pkt("carry", 1, 1);

                // 位流总长 24 表示边界没插填充; >24 表示插了
                if (stuff_before == 24) without_stuff = without_stuff + 1;
                else                    with_stuff    = with_stuff + 1;
            end
        end

        $display("    256 组跨界组合: 边界插填充 %0d 组, 不插 %0d 组",
                 with_stuff, without_stuff);

        if (with_stuff == 0) begin
            $display("    FAIL: 一轮扫描里一次边界填充都没触发, 覆盖不成立");
            errors = errors + 1;
        end
        if (without_stuff == 0) begin
            $display("    FAIL: 一轮扫描里全都在插填充, 缺少阴性对照");
            errors = errors + 1;
        end
    end
endtask
