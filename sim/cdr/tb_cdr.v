//============================================================================
// tb_cdr.v — CDR 时钟数据恢复单元测试顶层
//
// 使用方法:
//   vvp cdr.vvp +case=cdr_case_nominal           # 单个 case (无 VCD)
//   vvp cdr.vvp +case=cdr_case_nominal           # 编译时 VCD=1 则保存 VCD
//
// 验证点:
//   1. 锁存: C(12)→D(13)→5 路径正确
//   2. 环路: 左环(1→3→2→0) + 右环(5→7→6→4) 循环正确
//   3. d_out: 锁存后 d_out 应跟踪 rxdp (NRZI 电平: J=1, K=0)
//   4. clk12m: 恢复时钟周期 = 4 ref_clk ≈ 83.3ns
//   5. F 绕行: 长 bit (J 电平) → 状态 3→F(15)→6
//   6. B 绕行: 长 bit (K 电平) → 状态 7→B(11)→2
//   7. SE0: DP=DN=0 时不误锁，之后能重新锁存
//   8. 随机: 随机宽度的 bit 流验证 d_out 跟踪
//
// 自检机制:
//   锁存后在 ref_clk posedge 采样 d_out 和 rxdp，
//   d_out 应等于 rxdp (CDR 恢复的 NRZI 电平 = 差分线电平)
//   统计不匹配次数 (信息性, 因 DPLL 内部流水延迟)
//   真正的 pass/fail 基于: lock 状态, F/B 绕行检测, SE0 恢复
//
// Case 文件 (通过 +case= 选择):
//   cdr_case_nominal     — 标称 4-cycle OUT Token
//   cdr_case_long_bit_f  — 长 bit (J电平) → F 绕行
//   cdr_case_long_bit_b  — 长 bit (K电平) → B 绕行
//   cdr_case_short_bit_j — 短 bit (3cyc, data=1/J) → 右环 6→1 频率自适应
//   cdr_case_short_bit_k — 短 bit (3cyc, data=0/K) → 左环 2→5 频率自适应
//   cdr_case_se0         — SE0/EOP 处理
//   cdr_case_random      — 随机化激励
//   cdr_case_multi_pkt   — 多包事务 (SETUP+DATA0+ACK) 数据/时钟恢复
//   cdr_case_loopback    — 端到端回环: 用 clk12m+d_out 还原数据位 vs 发送位
//   cdr_case_pkt_all     — 端到端回环: 全部 9 类合法 USB1.1 正常包 (全包型推广)
//============================================================================

`timescale 1ns/1ps

module tb_cdr;

    // ---- DUT ----
    reg        clk, rstn;
    reg        rxdp, rxdn;
    wire       dclk;
    wire       rx_bit;

    usb_rx_cdr dut (
        .ref_clk (clk),
        .ref_rstn(rstn),
        .rxdp    (rxdp),
        .rxdn    (rxdn),
        .dclk (dclk),
        .rx_bit   (rx_bit)
    );

    // ---- 48MHz 时钟 (period = 1000/48 ≈ 20.833ns) ----
    parameter real CLK_HALF = 1000.0 / 48.0 / 2.0;   // ~10.417ns
    always #(CLK_HALF) clk = ~clk;

    // ---- USB 参数 ----
    parameter real BIT_TIME    = 1000.0 / 12.0;       // 1/12Mbps = 83.333ns
    parameter real EOP_SE0_TIME = 2.0 * BIT_TIME;
    parameter real EOP_J_TIME   = 1.0 * BIT_TIME;

    // ---- 自检状态 ----
    reg        locked;             // CDR 锁存标志
    reg [3:0]  prev_state;         // 前一个状态 (绕行检测)
    reg        f_detected;
    reg        b_detected;
    reg        se0_survived;
    integer    d_out_mismatches;   // 本 case 的 d_out 不匹配计数
    integer    d_out_cur_run;      // 当前连续不匹配长度
    integer    d_out_max_run;      // 最大连续不匹配长度 (判数据恢复质量)
    integer    errors;             // 全局错误计数 (自检判定)

    // ---- 时钟恢复监测 (仅 case_multi_pkt 使用) ----
    // clk12m_meas_en 的驱动在 case_multi_pkt.v (置 1 开测量 / 清 0 关测量)。
    // 此处只声明 + 复位为 0 + 下面 always 块读取, 故单看 tb 会像"一直是 0"。
    reg        clk12m_meas_en;     // 测量使能
    integer    clk12m_edges;       // clk12m 上升沿计数
    integer    clk12m_bad_periods; // 周期异常 (不在 3~5 ref_clk 内) 计数
    reg [31:0] ref_clk_cnt;        // 自由运行 ref_clk 计数器
    integer    last_ref_cnt;       // 上一个 clk12m 上升沿时的 ref_clk 计数

    // ---- 短 bit 自适应监测 (case_short_bit_j / case_short_bit_k) ----
    // 把 1 个 bit 压到 3cyc → 边沿比标称早 1 ref_clk:
    //   J/data=1 短 bit: 早到的 K 边沿打在右环第 3 态 6 (b=0) → 6→1 跳过切环;
    //   K/data=0 短 bit: 早到的 J 边沿打在左环第 3 态 2 (b=1) → 2→5 跳过切环。
    // 两者都使该位恢复时钟周期压到 3 ref_clk (见 usb_rx_cdr.v state 6/2 转移)。这里在
    // 测量窗口内统计周期 + 两种跳过路径, 由 case 断言: 短 bit 被真正"吸收" (恰一次对应
    // 跳过 + 恰一个 3-ref_clk 周期), 且不过度 (无 <3 周期)。
    reg        short_meas_en;      // 短 bit 测量使能 (case_short_bit_j/k 置位)
    integer    short_edges;        // 窗口内 dclk 上升沿总数
    integer    short_c3;           // 周期恰 3 ref_clk 的次数 (= 短 bit 自适应)
    integer    short_over;         // 周期 <3 ref_clk 的次数 (过短 = 失步, 预期 0)
    integer    short_last;         // 上一个 dclk 上升沿时的 ref_clk 计数
    integer    short_skip;         // 状态 6→1 提前切环次数 (J/data=1 短 bit: 右环遇提前 K 边沿)
    integer    short_skip_k2;      // 状态 2→5 提前切环次数 (K/data=0 短 bit: 左环遇提前 J 边沿)

    // ---- 端到端回环验证 (case_loopback): 用 clk12m+d_out 恢复数据位 ----
    reg        rx_capture_en;      // 接收捕获使能
    reg  [7:0] rx_q [0:511];       // 恢复出的数据位 (NRZI 解码后)
    integer    rx_wptr;            // 恢复位写指针
    reg        rx_prev_lv;         // 上一拍恢复电平 (NRZI 解码)
    reg        rx_have_prev;       // 是否已有上一拍

    // ---- 锁存因果窗口记录 (case_nominal / case_pkt_all 首包) ----
    // 目标: 按「因果链 + 前后文窗口」确认锁存，而非只看一个 locked 标志。
    //   每个 ref_clk 采样 dut.stat_cur 进时间线; 由 case 首包前开 causal_arm、
    //   首包后 causal_lock_check 断言:
    //     前窗 idle J      : state 恒 C(12)、恢复时钟 dclk 恒 0 (无数据不吐时钟)
    //     因① SYNC 首 0     : 线上出现 K → DPLL 离开 C 进入 D(13)
    //     因② 回到 J        : D → 5(右环) 锁存
    //     果               : 锁存后 dclk 起振、rx_bit 跟踪 NRZI 电平
    reg        causal_hist_en;     // 因果时间线记录使能
    integer    causal_hist_wp;     // 时间线写指针
    reg  [3:0] causal_state [0:2047]; // state 时间线 (ref_clk posedge 采样)
    reg [31:0] causal_tick  [0:2047]; // 对应 ref_clk 计数
    reg        causal_dclk  [0:2047]; // 对应 dclk 电平 (看恢复时钟何时起振)

    // ---- 锁存检测: 首次进入右环 (stat_cur==5, stat_nxt==7) ----
    // 说明: 这只给出"已锁存"的最终结果; 锁存的"因果链 + 前后文"验证
    //       (idle 前窗 state=C → C→D → D→5 → dclk 起振) 由下述
    //       causal_arm/causal_lock_check 任务在 case_nominal/case_pkt_all 里完成。
    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            locked <= 0;
            prev_state <= 4'd12;
        end else begin
            prev_state <= dut.stat_cur;
            if (!locked && dut.stat_cur == 4'd5 && dut.stat_nxt == 4'd7)
                locked <= 1;
        end
    end

    // ---- F 绕行检测: state 3→15 ----
    always @(posedge clk) begin
        if (prev_state == 4'd3 && dut.stat_cur == 4'd15)
            f_detected <= 1;
    end

    // ---- B 绕行检测: state 7→11 ----
    always @(posedge clk) begin
        if (prev_state == 4'd7 && dut.stat_cur == 4'd11)
            b_detected <= 1;
    end

    // ---- 自检: 锁存后在 posedge ref_clk 检查 d_out 是否跟踪 rxdp ----
    // posedge 时 state 刚更新, d_out=state[2] 反映当前 NRZI 电平判断
    // 允许少数沿边沿不匹配 (锁存和环路切换时)
    always @(posedge clk) begin
        if (locked && rstn) begin
            if (rx_bit !== rxdp) begin
                d_out_mismatches = d_out_mismatches + 1;
                d_out_cur_run = d_out_cur_run + 1;
                if (d_out_cur_run > d_out_max_run)
                    d_out_max_run = d_out_cur_run;
            end else begin
                d_out_cur_run = 0;
            end
        end
    end

    // ---- ref_clk 自由计数器 (测 clk12m 周期用) ----
    always @(posedge clk or negedge rstn) begin
        if (!rstn) ref_clk_cnt <= 32'd0;
        else       ref_clk_cnt <= ref_clk_cnt + 32'd1;
    end

    // ---- clk12m 恢复时钟监测: 统计上升沿 + 相邻沿间 ref_clk 周期数 ----
    // 标称周期 = 4 ref_clk (12MHz); 绕行/短 bit 时 3~5 ref_clk
    // 仅当 case_multi_pkt 置 clk12m_meas_en=1 时才统计 (见 case_multi_pkt.v:43/64)
    always @(posedge dclk) begin
        if (clk12m_meas_en) begin
            if (clk12m_edges > 0) begin
                if ((ref_clk_cnt - last_ref_cnt) < 3 ||
                    (ref_clk_cnt - last_ref_cnt) > 5)
                    clk12m_bad_periods = clk12m_bad_periods + 1;
            end
            last_ref_cnt = ref_clk_cnt;
            clk12m_edges = clk12m_edges + 1;
        end
    end

    // ---- 短 bit 周期统计: dclk 上升沿间 ref_clk 数, 记 3-ref_clk 短周期与 <3 过短 ----
    always @(posedge dclk) begin
        if (short_meas_en) begin
            if (short_edges > 0) begin
                if ((ref_clk_cnt - short_last) == 3)
                    short_c3 = short_c3 + 1;
                else if ((ref_clk_cnt - short_last) < 3)
                    short_over = short_over + 1;
            end
            short_last = ref_clk_cnt;
            short_edges = short_edges + 1;
        end
    end

    // ---- 短 bit 跳过检测 1: 状态 6→1 (J/data=1 短 bit) ----
    // 右环第 3 态 6 遇提前 K 边沿 (b=0), 跳过 4/5 直接切左环 (见 usb_rx_cdr.v state 6 转移)。
    // prev_state 由锁存检测块打拍 (posedge clk), 故这里同步采样无需另设本地打拍。
    always @(posedge clk) begin
        if (short_meas_en) begin
            if (prev_state == 4'd6 && dut.stat_cur == 4'd1)
                short_skip = short_skip + 1;
        end
    end

    // ---- 短 bit 跳过检测 2: 状态 2→5 (K/data=0 短 bit) ----
    // 左环第 3 态 2 遇提前 J 边沿 (b=1), 跳过 0/1 直接切右环 (见 usb_rx_cdr.v state 2 转移)。
    // 与 6→1 对称: 短 data=0 bit 使 K→J 翻转沿早 1 ref_clk, 左环状态 2 判 b=1 → 2→5。
    always @(posedge clk) begin
        if (short_meas_en) begin
            if (prev_state == 4'd2 && dut.stat_cur == 4'd5)
                short_skip_k2 = short_skip_k2 + 1;
        end
    end

    // ---- 端到端回环: 在 clk12m 上升沿采样 d_out, NRZI 解码还原数据位 ----
    // NRZI 解码: 电平变化 -> 0, 电平不变 -> 1
    always @(posedge dclk) begin
        if (rx_capture_en) begin
            if (rx_have_prev) begin
                rx_q[rx_wptr] = (rx_bit == rx_prev_lv) ? 1'b1 : 1'b0;
                rx_wptr = rx_wptr + 1;
            end
            rx_prev_lv = rx_bit;
            rx_have_prev = 1'b1;
        end
    end

    // ---- 清 d_out 统计 ----
    task reset_dout_check;
        begin
            d_out_mismatches = 0;
            d_out_cur_run = 0;
            d_out_max_run = 0;
        end
    endtask

    // ---- 因果时间线采样: 每个 ref_clk posedge 记录 (state, ref_clk 计数, dclk) ----
    // 供 causal_lock_check 用前后文窗口回看锁存过程 (见 case_nominal / case_pkt_all)。
    always @(posedge clk) begin
        if (causal_hist_en && causal_hist_wp < 2048) begin
            causal_state[causal_hist_wp] = dut.stat_cur;
            causal_tick [causal_hist_wp] = ref_clk_cnt;
            causal_dclk [causal_hist_wp] = dclk;
            causal_hist_wp = causal_hist_wp + 1;
        end
    end

    // ---- 因果链任务 1: 开启锁存窗口记录 (发首包前调用) ----
    // 调用前保持线上 idle J; 任务自身在调用点当前时刻开始逐拍记录 state/dclk。
    task causal_arm;
        begin
            causal_hist_wp = 0;
            causal_hist_en = 1;
        end
    endtask

    // ---- 因果链任务 2: 检查锁存因果链 (发完首包后调用) ----
    // 判据与设计报告 02_cdr_design.md §2.4 / §4.1 的锁存路径 C→D→5 逐条对应,
    // 观察带前后文窗口而非只看 locked 标志:
    //   [前窗] idle J : state 恒 C(12) 且 dclk=0 —— 无数据流时恢复时钟不运行
    //   [因①] 线上首 K (SYNC 首 0) → 首个非 C 状态必须直接是 D(13) (C→D, b=0)
    //   [因②] 线上回 J            → D(13)→5 锁定, 两次边沿间隔 ≈ 1 bit(=4 ref_clk)
    //   [果]  进入右环后 dclk 起振 (锁定后 16 ref_clk 内 ≥2 个上升沿 = 12MHz 在跑)
    // 任一条不满足都计入 errors (FAIL)。
    task causal_lock_check;
        integer i;
        integer idle_run;    // 前窗中 state==C 的连续拍数 (idle J 持续长度)
        integer idle_bad;    // 前窗中 dclk 出现过非 0
        integer iC2D;        // 首次 C→D 的 history 下标
        integer iLock;       // 首次进入 5(锁定) 的 history 下标
        integer iD2L;        // 锁存延迟 D→5 (ref_clk 数)
        integer rises;       // 锁定后窗内 dclk 上升沿数
        integer wend;        // 锁定后窗上界
        reg prev_d;          // 数 dclk 上升沿时的上一拍电平
        begin
            causal_hist_en = 0;              // 窗口结束, 停止记录

            // ---- 前窗: idle J 下 state 恒 C ----
            idle_run = 0;
            while (idle_run < causal_hist_wp && causal_state[idle_run] == 4'd12)
                idle_run = idle_run + 1;
            if (idle_run < 3) begin
                $display("    FAIL(因果链·前窗): idle 期 state=C 仅 %0d 拍 (<3), 无稳定空闲前窗",
                         idle_run);
                errors = errors + 1;
            end else begin
                // 前窗 dclk 必须恒 0 (无数据不吐恢复时钟)
                idle_bad = 0;
                for (i = 0; i < idle_run && idle_bad == 0; i = i + 1) begin
                    if (causal_dclk[i] !== 1'b0) idle_bad = 1;
                end
                if (idle_bad != 0) begin
                    $display("    FAIL(因果链·前窗): idle 期 dclk 出现 1 (应恒 0, 无数据不吐时钟)");
                    errors = errors + 1;
                end
                if (idle_bad == 0)
                    $display("    因果链·前窗: idle J 下 state=C 持续 %0d ref_clk, dclk 恒 0 (无数据不吐时钟) ✓",
                             idle_run);
            end

            // ---- 因①: 首个非 C 必须直接是 D (C→D) ----
            iC2D = -1;
            for (i = idle_run; i < causal_hist_wp; i = i + 1) begin
                if (causal_state[i] != 4'd12) begin
                    iC2D = i;
                    i = causal_hist_wp;       // 退出扫描
                end
            end
            if (iC2D >= 0 && causal_state[iC2D] == 4'd13) begin
                $display("    因果链·因①: 线上首 K (SYNC 首 0) → C(12)→D(13) @ref_clk#%0d ✓",
                         causal_tick[iC2D]);
            end else begin
                if (iC2D >= 0)
                    $display("    FAIL(因果链·因①): 首个非 C 状态=%0h (期望 D=13, 首 K 应触发 C→D)",
                             causal_state[iC2D]);
                else
                    $display("    FAIL(因果链·因①): 全程未离开 C (未捕获到 SYNC 首 K)");
                errors = errors + 1;
            end

            // ---- 因②: D→5 锁定 (线上回 J), 检查两次边沿间隔 ----
            iLock = -1;
            for (i = iC2D + 1; i < causal_hist_wp; i = i + 1) begin
                if (causal_state[i] == 4'd5) begin
                    iLock = i;
                    i = causal_hist_wp;       // 退出扫描
                end
            end
            if (iLock < 0) begin
                $display("    FAIL(因果链·因②): 未见 D→5 锁定 (无 state=5)");
                errors = errors + 1;
            end else begin
                iD2L = causal_tick[iLock] - causal_tick[iC2D];
                $display("    因果链·因②: 线上回 J → D(13)→5 锁定 @ref_clk#%0d, 锁存延迟 %0d ref_clk",
                         causal_tick[iLock], iD2L);
                // 判据: 两次边沿 (K→J) 间隔 ≈ 1 bit = 4 ref_clk; 留采样相位余量, 上限 8
                if (iD2L < 1 || iD2L > 8) begin
                    $display("    FAIL(因果链·因②): 锁存延迟 %0d ref_clk 不在 [1,8] (两次边沿应 ~1 bit=4 ref_clk)",
                             iD2L);
                    errors = errors + 1;
                end else begin
                    $display("      (判据: 延迟 %0d ref_clk ∈ [1,8], 对应 SYNC 0→0 两次边沿间隔 ~4 ref_clk) ✓",
                             iD2L);
                end
            end

            // ---- 果: 锁定后窗内 dclk 起振 (恢复时钟开始运行) ----
            if (iLock >= 0) begin
                wend = iLock + 16;
                if (wend > causal_hist_wp) wend = causal_hist_wp;
                rises = 0;
                prev_d = causal_dclk[iLock];
                for (i = iLock + 1; i < wend; i = i + 1) begin
                    if (causal_dclk[i] === 1'b1 && prev_d === 1'b0)
                        rises = rises + 1;
                    prev_d = causal_dclk[i];
                end
                if (rises < 2) begin
                    $display("    FAIL(因果链·果): 锁定后 %0d ref_clk 内 dclk 上升沿 %0d 个 (<2), 恢复时钟未起振",
                             wend - iLock, rises);
                    errors = errors + 1;
                end else
                    $display("    因果链·果: 锁定后 %0d ref_clk 内 dclk 上升沿 %0d 个 → 12MHz 恢复时钟运行 ✓",
                             wend - iLock, rises);
            end
        end
    endtask

    // ---- include 公共任务 (sim/common) + case 文件 ----
    `include "usb_pkt_tasks.vh"
    `include "case_nominal.v"
    `include "case_long_bit_f.v"
    `include "case_long_bit_b.v"
    `include "case_short_bit_j.v"
    `include "case_short_bit_k.v"
    `include "case_se0.v"
    `include "case_random.v"
    `include "case_multi_pkt.v"
    `include "case_loopback.v"
    `include "case_pkt_all.v"

    // ---- 测试主流程 ----
    reg [8*63:0] case_name;
    reg [8*63:0] vcd_name;

    initial begin
        // 获取 case 名称 (通过 +case=xxx 传入)
        if (!$value$plusargs("case=%s", case_name)) begin
            $display("ERROR: +case=<name> required");
            $display("  Available cases:");
            $display("    cdr_case_nominal");
            $display("    cdr_case_long_bit_f");
            $display("    cdr_case_long_bit_b");
            $display("    cdr_case_short_bit_j");
            $display("    cdr_case_short_bit_k");
            $display("    cdr_case_se0");
            $display("    cdr_case_random");
            $display("    cdr_case_multi_pkt");
            $display("    cdr_case_loopback");
            $display("    cdr_case_pkt_all");
            $finish(1);
        end

        // VCD: 每个 case 单独保存 (由 Makefile 传入完整文件名)
`ifdef VCD_SAVE
        if ($value$plusargs("vcd=%s", vcd_name)) begin
            $dumpfile(vcd_name);
            $dumpvars(0, tb_cdr);
            $display("INFO: VCD saved to %0s", vcd_name);
        end
`endif

        // 初始化
        clk   = 0;
        rstn  = 0;
        rxdp  = 1;  rxdn  = 0;     // idle J
        nrzi_lv = 1'b1;
        ones_cnt = 0;
        errors = 0;
        f_detected = 0;
        b_detected = 0;
        se0_survived = 0;
        d_out_mismatches = 0;
        d_out_cur_run = 0;
        d_out_max_run = 0;
        clk12m_meas_en = 0;
        clk12m_edges = 0;
        clk12m_bad_periods = 0;
        ref_clk_cnt = 0;
        last_ref_cnt = 0;
        short_meas_en = 0;
        short_edges = 0;
        short_c3 = 0;
        short_over = 0;
        short_last = 0;
        short_skip = 0;
        short_skip_k2 = 0;
        record_en = 0;
        exp_tx_wptr = 0;
        rx_capture_en = 0;
        rx_wptr = 0;
        rx_prev_lv = 0;
        rx_have_prev = 0;

        // 复位
        #200;
        rstn = 1;
        #200;

        $display("==============================================");
        $display("  CDR Test Case: %0s", case_name);
        $display("==============================================");

        // 分发到对应 case
        case (case_name)
            "cdr_case_nominal":     case_nominal;
            "cdr_case_long_bit_f":  case_long_bit_f;
            "cdr_case_long_bit_b":  case_long_bit_b;
            "cdr_case_short_bit_j": case_short_bit_j;
            "cdr_case_short_bit_k": case_short_bit_k;
            "cdr_case_se0":         case_se0;
            "cdr_case_random":      case_random;
            "cdr_case_multi_pkt":   case_multi_pkt;
            "cdr_case_loopback":    case_loopback;
            "cdr_case_pkt_all":     case_pkt_all;
            default: begin
                $display("ERROR: unknown case '%0s'", case_name);
                $finish(1);
            end
        endcase

        // ---- 汇总结果 ----
        $display("==============================================");
        if (errors == 0) begin
            $display("  TEST PASSED: usb_rx_cdr (%0s)", case_name);
            $display("==============================================");
            $finish(0);
        end else begin
            $display("  TEST FAILED: usb_rx_cdr (%0s) — %0d errors", case_name, errors);
            $display("==============================================");
            $fatal(1, "testbench abort");
        end
    end

endmodule
