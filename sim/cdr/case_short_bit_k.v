//============================================================================
// case_short_bit_k.v — 短 bit (3cyc, data=0/K) 测试 【自检: 因果链 + 量化判据】
//
// 测试目的: 验证 CDR 在 bit 宽度 < 4-cycle 时的频率自适应 (左环 2→5 跳过路径),
//   —— J/data=1 短 bit (case_short_bit_j, 6→1) 的 K/data=0 镜像。
//
// 场景: CRC5[3] (data=0/K 电平, bit 索引 28) 缩短到 3cyc; K 段 = bit28
//   - data=0 bit 在起始翻转进入 K 电平; 缩短它 = K 段压到 3cyc,
//     使段末回 J 的翻转沿比预期早 1 ref_clk。
//
// 因果链 (判据见下):
//   因 : 1 个 K 电平 bit 压到 3cyc → 早到的 J 边沿 (下一 bit 起始回 J);
//   变 : RTL 在左环第 3 态 2 判到提前边沿 (b=1) → 2→5 跳过切环
//        (不经 0/1, 见 src/phy/usb_rx_cdr.v state 2 转移);
//   果 : 该位恢复时钟周期被压到 3 ref_clk (标称 4), 其余位仍 4, 不失锁。
//
// 量化判据 (与 case_short_bit_j 镜像):
//   - short_skip_k2== 1   (恰一次 2→5 提前切环)
//   - short_skip   == 0   (无右环 6→1 误触发 = 两个方向互不串扰)
//   - short_c3     == 1   (恰一个 3-ref_clk 恢复时钟周期)
//   - short_over   == 0   (无 <3 ref_clk 过短周期 = 未过度响应)
//   - locked 保持 + dclk 沿 >= 20 (测量窗口覆盖到数据)
//============================================================================

task case_short_bit_k;
    integer case_start_errors;
    begin
        case_start_errors = errors;
        $display("== case_short_bit_k: short bit data=0/K (3 cycles) ==");
        reset_dout_check();

        // 因果链·短 bit 自适应窗口: 发包前置位测量, 收包后读取断言。
        // 判据与 RTL 的 2→5 转移 / 恢复时钟周期一一对应 (见 tb_cdr.v 注释)。
        short_meas_en = 1;
        short_edges = 0;
        short_c3 = 0;
        short_over = 0;
        short_skip = 0;
        short_skip_k2 = 0;
        short_last = ref_clk_cnt;

        // bit 28 (CRC5[3], data=0/K 电平) → 3cyc
        out_packet_task(7'd5, 4'd1, 4, 28, 3);

        #(BIT_TIME * 10);
        short_meas_en = 0;

        // ---- 因果自检 ----
        if (!locked) begin
            $display("FAIL: CDR lost lock after short bit");
            errors = errors + 1;
        end else begin
            $display("  CDR still locked ✓");
        end

        $display("  短bit(K)因果链: 6→1 跳过 %0d 次 | 2→5 跳过 %0d 次 | 3-ref_clk 周期 %0d 个 | 过短(<3) %0d | dclk 沿 %0d",
                 short_skip, short_skip_k2, short_c3, short_over, short_edges);

        if (short_skip_k2 != 1) begin
            $display("FAIL: 未见 2→5 短 bit 跳过 (预期恰 1, 实测 %0d)", short_skip_k2);
            errors = errors + 1;
        end else
            $display("  [变] 2→5 提前切环 1 次 ✓ (左环第 3 态遇提前 J 边沿)");

        if (short_skip != 0) begin
            $display("FAIL: 出现 %0d 次 6→1 (K case 不应触发右环跳过)", short_skip);
            errors = errors + 1;
        end else
            $display("  [界] 无 6→1 右环跳过 ✓ (J/K 两方向互不串扰)");

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
            $display("  PASS: case_short_bit_k");
        else
            $display("  FAIL: case_short_bit_k (%0d errors)", errors - case_start_errors);
    end
endtask
