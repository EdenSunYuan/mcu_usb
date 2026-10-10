//============================================================================
// case_short_bit_j.v — 短 bit (3cyc, data=1/J) 测试 【自检: 因果链 + 量化判据】
//
// 测试目的: 验证 CDR 在 bit 宽度 < 4-cycle 时的频率自适应 (右环 6→1 跳过路径),
//   而不只是"不失锁"。对应 K/data=0 的镜像 case 见 case_short_bit_k.v (2→5)。
//
// 场景: ENDP[0] (data=1/J 电平, bit 索引 23) 缩短到 3cyc; J 段 = bit22~23,
//   段末 (23/24 边界) 翻 K
//   - 3cyc 短 bit 使其后 NRZI 翻转沿比预期早 1 ref_clk
//
// 因果链 (判据见下):
//   因 : J 段末 bit 压到 3cyc → 早到的 K 边沿 (段末翻转);
//   变 : RTL 在右环第 3 态 6 判到提前边沿 (b=0) → 6→1 跳过切环
//        (不经 4/5, 见 src/phy/usb_rx_cdr.v state 6 转移);
//   果 : 该位恢复时钟周期被压到 3 ref_clk (标称 4), 其余位仍 4, 不失锁。
//
// 量化判据:
//   - short_skip   == 1   (恰一次 6→1 提前切环)
//   - short_skip_k2== 0   (无左环 2→5 误触发 = 两个方向互不串扰)
//   - short_c3     == 1   (恰一个 3-ref_clk 恢复时钟周期)
//   - short_over   == 0   (无 <3 ref_clk 过短周期 = 未过度响应)
//   - locked 保持 + dclk 沿 >= 20 (测量窗口覆盖到数据)
//============================================================================

task case_short_bit_j;
    integer case_start_errors;
    begin
        case_start_errors = errors;
        $display("== case_short_bit_j: short bit data=1/J (3 cycles) ==");
        reset_dout_check();

        // 因果链·短 bit 自适应窗口: 发包前置位测量, 收包后读取断言。
        // 判据与 RTL 的 6→1 转移 / 恢复时钟周期一一对应 (见 tb_cdr.v 注释)。
        short_meas_en = 1;
        short_edges = 0;
        short_c3 = 0;
        short_over = 0;
        short_skip = 0;
        short_skip_k2 = 0;
        short_last = ref_clk_cnt;

        // bit 23 (ENDP[0], data=1/J 电平) → 3cyc
        out_packet_task(7'd5, 4'd1, 4, 23, 3);

        #(BIT_TIME * 10);
        short_meas_en = 0;

        // ---- 因果自检 ----
        if (!locked) begin
            $display("FAIL: CDR lost lock after short bit");
            errors = errors + 1;
        end else begin
            $display("  CDR still locked ✓");
        end

        $display("  短bit(J)因果链: 6→1 跳过 %0d 次 | 2→5 跳过 %0d 次 | 3-ref_clk 周期 %0d 个 | 过短(<3) %0d | dclk 沿 %0d",
                 short_skip, short_skip_k2, short_c3, short_over, short_edges);

        if (short_skip != 1) begin
            $display("FAIL: 未见 6→1 短 bit 跳过 (预期恰 1, 实测 %0d)", short_skip);
            errors = errors + 1;
        end else
            $display("  [变] 6→1 提前切环 1 次 ✓ (右环第 3 态遇提前 K 边沿)");

        if (short_skip_k2 != 0) begin
            $display("FAIL: 出现 %0d 次 2→5 (J case 不应触发左环跳过)", short_skip_k2);
            errors = errors + 1;
        end else
            $display("  [界] 无 2→5 左环跳过 ✓ (J/K 两方向互不串扰)");

        if (short_c3 != 1) begin
            $display("FAIL: 短 bit 未把恢复时钟压到 3 ref_clk (预期恰 1, 实测 %0d)",
                     short_c3);
            errors = errors + 1;
        end else
            $display("  [果] 该位恢复时钟 = 3 ref_clk ✓ (其余位 4)");

        if (short_over != 0) begin
            $display("FAIL: 出现 %0d 个 <3 ref_clk 过短周期 (CDR 过度响应)",
                     short_over);
            errors = errors + 1;
        end else
            $display("  [界] 无 <3 ref_clk 过短周期 ✓ (自适应不过冲)");

        if (short_edges < 20) begin
            $display("FAIL: dclk 沿过少 (%0d<20), 测量窗口可能没覆盖数据", short_edges);
            errors = errors + 1;
        end else
            $display("  恢复时钟持续运行 ✓ (%0d 沿)", short_edges);

        if (errors == case_start_errors)
            $display("  PASS: case_short_bit_j");
        else
            $display("  FAIL: case_short_bit_j (%0d errors)", errors - case_start_errors);
    end
endtask
