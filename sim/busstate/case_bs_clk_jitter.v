//============================================================================
// bs_clk_jitter — clk12m 换成抖动的 dclk（周期 3/4/5 拍）时四类事件照常
//
// 因: clk12m 不是规整的 ÷4，而是 3/4/5 拍轮转（DPLL 用 4× 量化掰出来的恢复时钟就长这样）
// 变: 事件跨域靠的是两拍同步链 + 翻转通知，不数拍、不假设周期长度
// 果: 四类事件各恰好一个脉冲，宽度仍是 1 个 clk12m 拍
// 判据: 每类三处计数都 == 1；四类脉冲宽度都 == 1 个 clk12m 拍；输出互斥
// 前置: 需 +jit=1（Makefile 对本用例自动加；不加则本用例直接判 FAIL）
//============================================================================
task case_clk_jitter;
    begin
        if (!clk_jit) begin
            errors = errors + 1;
            $display("    FAIL bs_clk_jitter 需 +jit=1（clk12m 未切到抖动模式）");
        end
        $display("  因: clk12m 周期 3/4/5 拍轮转（dclk 形状），四类事件依次来一遍");
        $display("  变: 两拍同步链 + 翻转通知，不依赖 clk12m 周期长度");
        $display("  果: 四类事件各一个脉冲，宽度都是 1 个 clk12m 拍");
        win_begin;
        drive(1, 0, 400);                    // 插入 → connect
        win_end;
        chk_chain("jit_connect", d_cond[0], d_mid[0], d_pulse[0]);

        win_begin;
        drive(1, 0, 144100);                 // 空闲 3ms → suspend
        win_end;
        chk_chain("jit_suspend", d_cond[1], d_mid[1], d_pulse[1]);

        win_begin;
        drive(0, 1, 400);                    // 主机 K → resume
        win_end;
        chk_chain("jit_resume", d_cond[3], d_mid[3], d_pulse[3]);

        win_begin;
        drive(0, 0, 400);                    // SE0 → bus_rst
        win_end;
        chk_chain("jit_bus_rst", d_cond[2], d_mid[2], d_pulse[2]);

        chk("jit_connect_width_1", wmax[0], 1);
        chk("jit_suspend_width_1", wmax[1], 1);
        chk("jit_bus_rst_width_1", wmax[2], 1);
        chk("jit_resume_width_1", wmax[3], 1);
        $display("  延迟(ref 拍): connect %0d..%0d, suspend %0d..%0d, bus_rst %0d..%0d, resume %0d..%0d",
                 lat_min[0], lat_max[0], lat_min[1], lat_max[1],
                 lat_min[2], lat_max[2], lat_min[3], lat_max[3]);
    end
endtask
