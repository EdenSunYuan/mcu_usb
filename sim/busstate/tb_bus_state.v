//============================================================================
// tb_bus_state.v — usb_bus_state（总线状态检测：连接 / 复位 / 挂起 / 唤醒）单元测试顶层
//
// 使用方法:
//   vvp busstate.vvp +case=bs_connect              # 单个 case（编译期 VCD=1 才存波形）
//   vvp busstate.vvp +case=bs_clk_jitter +jit=1    # clk12m 抖动模式（周期 3/4/5 拍轮转）
//
// 被测: src/phy/usb_bus_state.v
//   一条计数器 + 两个标志位 + 两个翻转位，无状态机；判据跑 ref_clk（4×），
//   四个事件脉冲在 clk12m（1×）组合直出。
//
// 判据分三层（本 TB 的核心）:
//   【一 · 三处计数相等】每类事件在三个位置各数一遍，必须相等，这就是
//     "因 → 变 → 果" 的量化解，多一个少一个都算挂:
//       判据次数 n_cond[i]  — ref_clk 域，如 rst_cond（单拍）
//     == 载体次数 n_mid[i]   — ref_clk 域：标志位取上升沿 / 翻转位取变化
//     == 脉冲个数 n_pulse[i] — clk12m 域，输出的上升沿
//     相等即证明「一次判据 → 一次翻转/置位 → 恰好一个脉冲」。
//   【二 · 脉冲形状】四个输出的高电平最宽恒为 1 个 clk12m 拍（wmax[i] <= 1），
//     且任意 clk12m 拍至多一路为高（互斥）。
//   【三 · 跨域延迟】判据起拍 → 脉冲起拍 的拍数逐事件记录，打印 min..max。
//     实测 1..4 个 ref 拍，随判据落在 clk12m 的哪个相位而变（bs_latency_phase 扫四相位
//     = 3/2/1/4），上界 4 拍 = 一个 clk12m 周期 ≈83ns，见设计报告 §4.6。
//
// 时钟: ref_clk 48MHz（半周期 ≈10.417ns）；clk12m 由 ref_clk 派生、边沿对齐
//   （÷4 标称；+jit=1 时按 3/4/5 拍轮转，模拟 DPLL 恢复时钟 dclk 的抖动）。
//   真实系统里 clk12m 的两路来源（dclk / clk12s）都在 ref_clk 域寄存产生，
//   本 TB 的产生方式与之一致。
//
// Case 文件（+case= 选择，见 sim/busstate/README.md）:
//   bs_reset_default  — 复位清零 + 冷启动长 SE0 不报总线复位（未附着谈不上复位）
//   bs_connect        — J ≥2.5µs 报 connect_evt 一次；不到 3ms 不报挂起、不重报
//   bs_suspend        — 空闲 J ≥3ms 报 suspend_evt 一次；再等 3ms 不重复
//   bs_resume         — 挂起中主机 K ≥2.5µs 报 resume_evt 一次，挂起随之解除
//   bs_short_k        — 挂起中短 K（包内数据 28 拍）不报 resume，挂起保持
//   bs_threshold_scan — 2.5µs 门限扫描（SE0 与 K 各 116..130 拍，逐段隔离）
//   bs_self_drive     — 自驱 K（远程唤醒）/ 自驱 SE0（包尾 EOP）不报事件
//   bs_bus_rst        — 连接后 SE0 ≥2.5µs 报 usb_bus_rst；长 SE0 里只报一次
//   bs_two_resets     — 两次总线复位各报一次（翻转通知不会两翻相消）
//   bs_usb_rst        — usb_rst 清两个标志位、不动两个翻转位（不造假脉冲）、清后重连
//   bs_k_when_awake   — 未挂起时的长 K 不报 resume，回 J 后仍能正常挂起
//   bs_se1_stuck      — SE1 持续（PHY 异常）不报任何事件
//   bs_clk_jitter     — clk12m 周期 3/4/5 拍轮转时四类事件照常（需 +jit=1）
//   bs_latency_phase  — 触发沿平移 0..3 拍扫 clk12m 四相位，四类事件延迟都在 1..4 ref 拍
//============================================================================

`timescale 1ns/1ps

module tb_bus_state;

    // ---- 时钟参数 ----
    parameter real REF_HALF = 1000.0 / 48.0 / 2.0;   // ref_clk 半周期 ≈ 10.417ns

    // ---- DUT ----
    reg        ref_clk  = 1'b0;
    reg        ref_rstn = 1'b0;
    reg        usb_rst  = 1'b0;
    reg        tx_en    = 1'b0;
    reg  [1:0] line_ext = 2'b00;     // 外部线电平 {D+,D-}；初值 SE0：模拟"电缆没插、两线被下拉"
    reg  [1:0] line_s   = 2'b00;     // 模型 usb_rx_deserial 的采样寄存器：line_ext 打一拍
    reg        clk12m   = 1'b0;
    wire       connect_evt, usb_bus_rst, suspend_evt, resume_evt;
    wire       bus_suspended;        // 挂起状态（电平，clk12m 域）：给 usb_tx_serial 的唤醒旁路用

    // 上游模型：deserial 在 ref_clk 域采一次线电平，DUT 吃这一份（端口时序与
    //   DUT 自己采时完全一致，故门限/延迟读数不变）
    always @(posedge ref_clk or negedge ref_rstn) begin
        if (!ref_rstn) begin
            line_s <= 2'b00;
        end
        else begin
            line_s <= line_ext;
        end
    end

    usb_bus_state u_dut (
        .clk12m      (clk12m),
        .ref_clk     (ref_clk),
        .ref_rstn    (ref_rstn),
        .usb_rst     (usb_rst),
        .line_s      (line_s),
        .tx_en       (tx_en),
        .connect_evt (connect_evt),
        .usb_bus_rst (usb_bus_rst),
        .suspend_evt (suspend_evt),
        .resume_evt  (resume_evt),
        .bus_suspended (bus_suspended)
    );

    always #(REF_HALF) ref_clk = ~ref_clk;

    //========================================================================
    // clk12m 发生器：两种模式，都是"边沿落在 ref_clk 上升沿上的 12MHz 左右时钟"
    //   标称 (clk_jit=0): div4 计 0..3，clk12m = div4[1] → 周期恒 4 拍、占空比 50%，
    //     与 clk_mux 输出的 clk12s 同构；
    //   抖动 (clk_jit=1): 半周期按 2,1 / 2,2 / 3,2 / 2,2 轮转 → 周期 3/4/5 拍，
    //     与 DPLL 用 4× 量化掰出来的 dclk 同构（切过去的路上 dclk 就这样）。
    //========================================================================
    reg       clk_jit = 1'b0;
    reg [1:0] div4    = 2'd0;
    reg [2:0] hp_idx  = 3'd0;
    reg [3:0] hp_cnt  = 4'd0;
    reg [3:0] hp_seq [0:7];

    initial begin
        hp_seq[0] = 4'd2;  hp_seq[1] = 4'd1;   // 周期 3 拍（偏快）
        hp_seq[2] = 4'd2;  hp_seq[3] = 4'd2;   // 周期 4 拍（标称）
        hp_seq[4] = 4'd3;  hp_seq[5] = 4'd2;   // 周期 5 拍（偏慢）
        hp_seq[6] = 4'd2;  hp_seq[7] = 4'd2;   // 周期 4 拍（标称）
    end

    always @(posedge ref_clk) begin
        if (!clk_jit) begin
            div4   <= div4 + 2'd1;
            clk12m <= div4[1];
        end
        else if (hp_cnt + 4'd1 >= hp_seq[hp_idx]) begin
            clk12m <= ~clk12m;
            hp_cnt <= 4'd0;
            hp_idx <= hp_idx + 3'd1;
        end
        else begin
            hp_cnt <= hp_cnt + 4'd1;
        end
    end

    //========================================================================
    // 三组观测总线（bit0=connect, 1=suspend, 2=bus_rst, 3=resume）
    //   cond_bus  — 四条判据（ref_clk 域组合）
    //   pulse_bus — 四个输出脉冲（clk12m 域组合直出）
    //   载体单列：标志位只认上升沿（下降沿不是事件，复位/唤醒各有自己的路），
    //     翻转位两个方向都算（它就是"发生过一次"的载体）
    //========================================================================
    wire [3:0] cond_bus  = {u_dut.rsm_cond, u_dut.rst_cond, u_dut.sus_cond, u_dut.con_cond};
    wire [3:0] pulse_bus = {resume_evt, usb_bus_rst, suspend_evt, connect_evt};

    reg con_d = 1'b0, sus_d = 1'b0, rst_tgl_d = 1'b0, rsm_tgl_d = 1'b0;
    wire con_rise = u_dut.connected & (~con_d);
    wire sus_rise = u_dut.suspended & (~sus_d);
    wire rst_chg  = u_dut.rst_tgl   ^ rst_tgl_d;
    wire rsm_chg  = u_dut.rsm_tgl   ^ rsm_tgl_d;
    wire [3:0] mid_evt = {rsm_chg, rst_chg, sus_rise, con_rise};

    //========================================================================
    // 统计量
    //========================================================================
    integer tick;                        // ref_clk 拍序号（复位撤销后开始累加）
    integer n_cond  [0:3];               // 判据上升次数（ref 域）
    integer n_mid   [0:3];               // 载体次数（ref 域）
    integer n_pulse [0:3];               // 输出脉冲个数（clk12m 域）
    integer w_cur   [0:3];               // 判据当前连高拍数（ref 拍）
    integer wmax_cond [0:3];             // 判据最宽（ref 拍）—— 判据类必须是 1
    integer w_curp  [0:3];               // 脉冲当前连高拍数（clk12m 拍）
    integer wmax  [0:3];                 // 脉冲最宽（clk12m 拍）—— 必须是 1
    integer lat_min [0:3];               // 判据起拍 → 脉冲起拍（ref 拍）
    integer lat_max [0:3];
    integer lat_t   [0:3];               // 最近一次判据所在拍
    integer lat_last[0:3];               // 最近一个脉冲的延迟（判据起拍 → 脉冲起拍）
    reg [3:0] cond_d = 4'd0, pulse_d = 4'd0;
    integer n_mutex;                     // 同拍多路输出为高的次数 —— 必须 0

    // ---- bus_suspended 的接线检查（两条，都只在 clk12m 沿上采）----
    reg     bus_susp_d = 1'b0;           // bus_suspended 打一拍，找它的上升沿
    integer n_bsus_ne;                   // 与 sus_s[0] 不等的拍数 —— 必须 0（防止改接成 ref_clk 域的 suspended）
    integer n_bsus_edge;                 // 上升沿与 suspend_evt 不同拍的次数 —— 必须 0（同一条链的判据）
    integer n_con_fall, n_sus_fall;      // 两个标志位的下降次数（只由 usb_rst 造成）
    reg     con_dd = 1'b0, sus_dd = 1'b0;

    // ---- 标志位状态矩阵（fsm 维度：本模块无状态机，状态 = {connected,suspended}）----
    integer   st_visit [0:2];
    integer   st_arc   [0:2][0:2];
    integer   n_impl;                    // 组合 (connected=0 & suspended=1) 出现拍数
    reg [1:0] st_prev;
    reg       st_first = 1'b1;
    reg [1:0] st_now;

    integer i, k;

    //========================================================================
    // ref_clk 域采样（+1ns：DUT 与本 TB 都用非阻塞在同沿更新，1ns 后本拍值已就位）
    //   ★ 脉冲也在这一侧数：输出是 clk12m 域组合直出，而 clk12m 本身也在 ref_clk
    //     沿上寄存产生，故每个输出沿都落在 ref_clk 的采样格子上，两个域的时间戳
    //     统一用 tick，延迟差值不存在跨域取样误差。
    //     脉冲"宽度 1 个 clk12m 拍"另由 clk12m 域采样块数（见下）。
    //========================================================================
    always @(posedge ref_clk) begin
        #1;
        if (ref_rstn) begin
            for (i = 0; i < 4; i = i + 1) begin
                if (cond_bus[i] && !cond_d[i]) begin
                    n_cond[i] = n_cond[i] + 1;
                    lat_t[i]  = tick;
                end
                if (mid_evt[i]) n_mid[i] = n_mid[i] + 1;
                if (pulse_bus[i] && !pulse_d[i]) begin
                    n_pulse[i] = n_pulse[i] + 1;
                    if (lat_t[i] >= 0) begin
                        k = tick - lat_t[i];
                        lat_last[i] = k;
                        if (k < lat_min[i]) lat_min[i] = k;
                        if (k > lat_max[i]) lat_max[i] = k;
                    end
                end
                w_cur[i] = cond_bus[i] ? (w_cur[i] + 1) : 0;
                if (w_cur[i] > wmax_cond[i]) wmax_cond[i] = w_cur[i];
            end

            // 两个标志位的下降（usb_rst 造成的清附着 / 清挂起）
            if (con_dd && !u_dut.connected) n_con_fall = n_con_fall + 1;
            if (sus_dd && !u_dut.suspended) n_sus_fall = n_sus_fall + 1;
            con_dd = u_dut.connected;  sus_dd = u_dut.suspended;

            // 状态停留 / 迁移（不可达组合单独数）
            if (!u_dut.connected && u_dut.suspended) n_impl = n_impl + 1;
            st_now = u_dut.connected ? (u_dut.suspended ? 2'd2 : 2'd1) : 2'd0;
            if (st_first) begin
                st_first = 1'b0;
                st_prev  = st_now;
            end
            else begin
                st_visit[st_now] = st_visit[st_now] + 1;
                st_arc[st_prev][st_now] = st_arc[st_prev][st_now] + 1;
                st_prev = st_now;
            end

            tick = tick + 1;
        end
        cond_d = cond_bus;
        pulse_d = pulse_bus;
        rst_tgl_d = u_dut.rst_tgl;
        rsm_tgl_d = u_dut.rsm_tgl;
        con_d  = u_dut.connected;
        sus_d  = u_dut.suspended;
    end

    //========================================================================
    // clk12m 域采样：只数脉冲宽度（clk12m 拍）与互斥
    //   脉冲恰好占一个 clk12m 周期，每个上升沿采到一次，故"连续采到为高的次数"
    //   就是它的宽度（clk12m 拍）。
    //========================================================================
    always @(posedge clk12m) begin
        #1;
        if (ref_rstn) begin
            for (i = 0; i < 4; i = i + 1) begin
                w_curp[i] = pulse_bus[i] ? (w_curp[i] + 1) : 0;
                if (w_curp[i] > wmax[i]) wmax[i] = w_curp[i];
            end
            if ((pulse_bus[0] + pulse_bus[1] + pulse_bus[2] + pulse_bus[3]) > 1)
                n_mutex = n_mutex + 1;

            // bus_suspended：必须逐拍等于 sus_s[0]（同一条同步链的输出级），
            //   且它的上升沿与 suspend_evt 同拍。两条一起把"改接成 ref_clk 域的
            //   suspended"这种错法挡住——那样电平会早 1 个 clk12m 拍起跳。
            if (bus_suspended !== u_dut.sus_s[0]) n_bsus_ne = n_bsus_ne + 1;
            if (bus_suspended && !bus_susp_d && !suspend_evt) n_bsus_edge = n_bsus_edge + 1;
            bus_susp_d = bus_suspended;
        end
    end

    //========================================================================
    // 辅助任务
    //========================================================================
    task ref_wait;                       // 等 n 个 ref_clk 上升沿
        input integer n;
        integer m;
        begin
            for (m = 0; m < n; m = m + 1) @(posedge ref_clk);
        end
    endtask

    task drive;                          // 驱两线到 (a,b) 并保持 n 个 ref_clk 拍
        input a;
        input b;
        input integer n;
        begin
            line_ext = {a, b};
            ref_wait(n);
        end
    endtask

    task clk_wait;                       // 等 n 个 clk12m 上升沿
        input integer n;
        integer m;
        begin
            for (m = 0; m < n; m = m + 1) @(posedge clk12m);
        end
    endtask

    // 排空：等 8 个 clk12m 拍（≈667ns），让在途的跨域脉冲全部落地。
    //   ★ 远小于 2.5µs 最小门限，排空本身不会造出新事件。
    task drain;
        begin
            clk_wait(8);
        end
    endtask

    // ---- 窗口快照（每个观察窗口前后各取一次，比对差值）----
    integer s_cond [0:3], s_mid [0:3], s_pulse [0:3];
    integer s_confall, s_susfall;
    integer d_cond [0:3], d_mid [0:3], d_pulse [0:3];
    integer d_confall, d_susfall;

    task win_begin;
        begin
            drain;
            for (i = 0; i < 4; i = i + 1) begin
                s_cond[i] = n_cond[i];  s_mid[i] = n_mid[i];  s_pulse[i] = n_pulse[i];
            end
            s_confall = n_con_fall;  s_susfall = n_sus_fall;
        end
    endtask

    task win_end;
        begin
            drain;
            for (i = 0; i < 4; i = i + 1) begin
                d_cond[i]  = n_cond[i]  - s_cond[i];
                d_mid[i]   = n_mid[i]   - s_mid[i];
                d_pulse[i] = n_pulse[i] - s_pulse[i];
            end
            d_confall = n_con_fall - s_confall;
            d_susfall = n_sus_fall - s_susfall;
        end
    endtask

    task stats_clear;                    // 每个 case 起点：清极值与状态矩阵
        integer a, b;
        begin
            for (a = 0; a < 4; a = a + 1) begin
                n_cond[a] = 0;  n_mid[a] = 0;  n_pulse[a] = 0;
                w_cur[a] = 0;   wmax_cond[a] = 0;
                w_curp[a] = 0;  wmax[a] = 0;
                lat_min[a] = 9999;  lat_max[a] = 0;  lat_t[a] = -1;  lat_last[a] = 0;
            end
            n_con_fall = 0;  n_sus_fall = 0;  n_mutex = 0;  tick = 0;
            n_bsus_ne = 0;   n_bsus_edge = 0;
            for (a = 0; a < 3; a = a + 1) begin
                st_visit[a] = 0;
                for (b = 0; b < 3; b = b + 1) st_arc[a][b] = 0;
            end
            st_first = 1'b1;  n_impl = 0;
        end
    endtask

    task chk;                            // 布尔判据
        input [255:0] name;
        input integer got;
        input integer want;
        begin
            if (got !== want) begin
                errors = errors + 1;
                $display("    FAIL %0s: got %0d, want %0d", name, got, want);
            end
            else $display("    PASS %0s: %0d", name, got);
        end
    endtask

    // 三处计数相等（因→变→果）
    task chk_chain;
        input [255:0] tag;
        input integer c;
        input integer m;
        input integer p;
        begin
            $display("    %0s: 判据 %0d → 载体 %0d → 脉冲 %0d", tag, c, m, p);
            if ((c !== m) || (m !== p)) begin
                errors = errors + 1;
                $display("    FAIL %0s 三处计数不等", tag);
            end
            else $display("    PASS %0s 三处计数相等", tag);
        end
    endtask

    //========================================================================
    // 标志位状态/迁移打印（格式须与 tools/merge_fsm_cov.py 的 busstate profile 对齐）
    //========================================================================
    task print_fsm_coverage;
        integer r, c;
        begin
            $display("---- 标志位状态/迁移覆盖 (u_dut, %0s) ----", case_name);
            $display("  停留拍数: OFF=%0d ATT=%0d SUSP=%0d",
                     st_visit[0], st_visit[1], st_visit[2]);
            $display("  迁移矩阵 (行=from 列=to, 单位: 拍):");
            $display("            to:       OFF       ATT      SUSP");
            for (r = 0; r < 3; r = r + 1) begin
                $write("    from %0d:  ", r);
                for (c = 0; c < 3; c = c + 1) $write("%8d ", st_arc[r][c]);
                $write("\n");
            end
            $display("  不可达组合 (connected=0 & suspended=1) 停留拍数: %0d", n_impl);
        end
    endtask

    //========================================================================
    // 自检状态
    //========================================================================
    integer errors = 0;
    reg [255:0] case_name;
    reg [255:0] vcd_name;
    integer jit_arg;

    //========================================================================
    // 主激励
    //========================================================================
    initial begin
`ifdef VCD_SAVE
        if (!$value$plusargs("vcd=%s", vcd_name)) vcd_name = "busstate.vcd";
        $dumpfile(vcd_name);
        $dumpvars(0, tb_bus_state);
        $display("INFO: VCD saved to %0s", vcd_name);
`endif

        if (!$value$plusargs("case=%s", case_name)) begin
            $display("ERROR: +case=<name> required");
            $finish(1);
        end
        if (!$value$plusargs("jit=%d", jit_arg)) jit_arg = 0;
        clk_jit = (jit_arg != 0);

        // ---- 复位序列 ----
        // 让 DUT 的 `always @(posedge ref_clk or negedge ref_rstn)` 异步复位分支真跑一次
        // （否则复位路径零覆盖，且初值只能靠仿真器默认值，iverilog 是 x、Verilator 是 0）。
        ref_rstn = 1'b1;
        repeat (8) @(posedge ref_clk);
        ref_rstn = 1'b0;
        #200;
        ref_rstn = 1'b1;
        #200;

        $display("==============================================");
        // ★ 本例标签走 %0s 参数传入, 只能是 ASCII —— iverilog 的 %0s 按字节截断,
        //   传中文会变乱码 (中文写在 $display 的直接字面量里才安全)
        $display("  usb_bus_state Test Case: %0s (clk12m %0s)",
                 case_name, clk_jit ? "jit 3/4/5" : "nominal /4");
        $display("==============================================");

        stats_clear;

        case (case_name)
            "bs_reset_default":  case_reset_default;
            "bs_connect":        case_connect;
            "bs_suspend":        case_suspend;
            "bs_resume":         case_resume;
            "bs_short_k":        case_short_k;
            "bs_threshold_scan": case_threshold_scan;
            "bs_self_drive":     case_self_drive;
            "bs_bus_rst":        case_bus_rst;
            "bs_two_resets":     case_two_resets;
            "bs_usb_rst":        case_usb_rst;
            "bs_k_when_awake":   case_k_when_awake;
            "bs_se1_stuck":      case_se1_stuck;
            "bs_clk_jitter":     case_clk_jitter;
            "bs_latency_phase":  case_latency_phase;
            default: begin
                $display("ERROR: unknown case '%0s'", case_name);
                $finish(1);
            end
        endcase

        print_fsm_coverage;

        // ---- 全局不变量（与 case 无关，整轮跑完再判）----
        $display("---- 全局不变量 ----");
        drain;
        for (i = 0; i < 4; i = i + 1) begin
            chk_chain(event_name(i), n_cond[i], n_mid[i], n_pulse[i]);
            if (wmax[i] > 1) begin
                errors = errors + 1;
                $display("    FAIL %0s 脉冲宽度 %0d 个 clk12m 拍 (>1)", event_name(i), wmax[i]);
            end
            else if (wmax[i] == 1)
                $display("    PASS %0s 脉冲宽度 1 个 clk12m 拍 (延迟 %0d..%0d ref 拍)",
                         event_name(i), lat_min[i], lat_max[i]);
        end
        chk("global_output_mutex", n_mutex, 0);
        chk("global_unreachable_flag_combo", n_impl, 0);
        // bus_suspended 的接线：整轮逐拍等于 sus_s[0]，上升沿与 suspend_evt 同拍
        chk("global_bus_suspended_same_chain", n_bsus_ne, 0);
        chk("global_bus_suspended_edge_with_pulse", n_bsus_edge, 0);

        $display("==============================================");
        if (errors == 0) begin
            $display("  TEST PASSED: usb_bus_state (%0s)", case_name);
            $display("==============================================");
            $finish(0);
        end else begin
            $display("  TEST FAILED: usb_bus_state (%0s) — %0d errors", case_name, errors);
            $display("==============================================");
            $finish(1);
        end
    end

    // 事件名（打印用）
    function [255:0] event_name;
        input integer idx;
        begin
            case (idx)
                0: event_name = "connect_evt ";
                1: event_name = "suspend_evt ";
                2: event_name = "usb_bus_rst ";
                3: event_name = "resume_evt  ";
                default: event_name = "?           ";
            endcase
        end
    endfunction

    // ---- 各 case（一个用例一个文件，与 sim/clkmux、sim/tx 同构）----
    `include "case_bs_reset_default.v"
    `include "case_bs_connect.v"
    `include "case_bs_suspend.v"
    `include "case_bs_resume.v"
    `include "case_bs_short_k.v"
    `include "case_bs_threshold_scan.v"
    `include "case_bs_self_drive.v"
    `include "case_bs_bus_rst.v"
    `include "case_bs_two_resets.v"
    `include "case_bs_usb_rst.v"
    `include "case_bs_k_when_awake.v"
    `include "case_bs_se1_stuck.v"
    `include "case_bs_clk_jitter.v"
    `include "case_bs_latency_phase.v"

endmodule
