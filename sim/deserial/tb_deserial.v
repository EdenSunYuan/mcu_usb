//============================================================================
// tb_deserial.v — usb_rx_deserial 单元测试顶层 (CDR 前端 + EOP 尾研究)
//
// DUT 链: usb_rx_cdr ──dclk/rx_bit──> usb_rx_deserial
//   clk12m 直接接 CDR 的 dclk (恢复时钟), 因 usb_clk_mux 尚未建; 与定稿
//   "接收时 clk12m=dclk 经 mux" 的功能等价 (本 tb 不含冷启动 clk12s 域)。
//
// 本 tb 服务于两条主线:
//   1. 正常包回归: 验证 SYNC 对齐/解填充/字节输出/关包 (case_out_normal)。
//   2. EOP 尾研究: 包尾注入 "K 电平连续 R 个 1 + 真 EOP" (SE0 被解成 K→
//      假 7 连 1 风险), 量每帧关包时的 rx_error / 吐字节数 / 关包时刻,
//      对比"现行 RTL" 与 "EOP SE0 区门控" 两版 (case_tail_scan)。
//   3. 门控风险: 真 7 连 1 (非 SE0) 仍要检错 (case_stuff_viol);
//      SE0 卡死 (≥2.5µs) 行为变化 (case_se0_stuck)。
//
// 帧监视器: 直接读 DUT 内部 in_frame, 沿检测记每帧
//   last_err(关包 rx_error) / last_nbyte / last_bytes[0..] / last_close_t。
// (rx_error 由 DUT 判"帧机回 USB_IDLE 即清" — 关包沿当拍仍可读到错误电平)
//
// 时钟: clk12m = CDR 恢复时钟, 只在实际收包期/锁定后运转; 冷 idle (未锁)
//   dclk 停摆 → deserial 无沿 → 停在 IDLE, 无副作用 (与 mux 场景一致)。
//============================================================================

`timescale 1ns/1ps

module tb_deserial;

    // ---- USB 参数 (usb_pkt_tasks.vh 依赖) ----
    parameter real BIT_TIME     = 1000.0 / 12.0;        // 83.333ns
    parameter real EOP_SE0_TIME = 2.0 * BIT_TIME;
    parameter real EOP_J_TIME   = 1.0 * BIT_TIME;

    // ---- DUT 链 ----
    reg        ref_clk, ref_rstn;
    reg        rxdp, rxdn;
    wire       dclk;
    wire       rx_bit;
    wire       rx_active, rx_error;
    reg  [7:0] rx_data;
    wire       rx_valid;
    wire [1:0] line_state;
    wire [1:0] dut_line_s;      // 白盒: DUT 的 ref 域线采样寄存器 (共用给 usb_bus_state)
    // 刺激控制 (缺省 0, 等价于旧硬接 0; 供异常 case 注入 rx_abort / tx_active / usb_rst 强退)
    reg stim_tx_active = 1'b0;
    reg stim_rx_abort  = 1'b0;
    reg stim_usb_rst   = 1'b0;

    usb_rx_cdr u_cdr (
        .ref_clk (ref_clk),
        .ref_rstn(ref_rstn),
        .rxdp    (rxdp),
        .rxdn    (rxdn),
        .dclk    (dclk),
        .rx_bit  (rx_bit)
    );

    usb_rx_deserial u_dut (
        .clk12m    (dclk),        // 接收时 = 恢复时钟
        .ref_clk   (ref_clk),
        .ref_rstn  (ref_rstn),
        .usb_rst   (stim_usb_rst),
        .rx_bit    (rx_bit),
        .rxdp      (rxdp),
        .rxdn      (rxdn),
        .tx_active (stim_tx_active),
        .rx_abort  (stim_rx_abort),
        .rx_data   (rx_data),
        .rx_valid  (rx_valid),
        .rx_active (rx_active),
        .rx_error  (rx_error),
        .line_state(line_state),
        .line_s    (dut_line_s)
    );

    // ---- 现态定位点 (2026-09-20 规则 7 改名) ----
    // 交付 RTL 按规则 7 把两套 FSM 的现态改名 (st_state -> st_stat_cur);
    // MODE=gate/gatesync/linese0/rawse0/nrzi2 用的是**已冻结的研究副本**
    // sim/deserial/usb_rx_deserial_gate.v, 里面仍叫 st_state —— 副本保持冻结,
    // 故在此按编译宏二选一。TB 与各 case 一律只引用 dut_st_cur,
    // 这样共享的 case 文件不必关心当前 MODE 编译的是哪一份 DUT。
    // 宽度 2 与 RTL 的 `reg [1:0] st_stat_cur` 一致; 纯只读别名, 不驱动 DUT。
`ifdef GATE_VARIANT
    wire [1:0] dut_st_cur = u_dut.st_state;
`else
    wire [1:0] dut_st_cur = u_dut.st_stat_cur;
`endif

    // ---- 48MHz ref_clk ----
    parameter real CLK_HALF = 1000.0 / 48.0 / 2.0;
    always #(CLK_HALF) ref_clk = ~ref_clk;

    // ---- 自检状态 ----
    integer errors = 0;

    // usb_pkt_tasks.vh 会自行声明 record_en/exp_tx_wptr/exp_tx_q/ones_cnt/nrzi_lv,
    // 勿在此重复声明; 并在本文件 textually 先于 helper task (宏 PID_TYPE_OUT 等)
    // 处 include 一次, 供 helper 内使用。

    // ---- 帧监视器结果 (最近一帧) ----
    integer    close_cnt = 0;       // 已关包帧数
    time       last_open_t;         // 本帧开时刻
    time       last_close_t;
    reg        last_err;            // 关包当拍 rx_error (帧错误标志)
    integer    last_nbyte;          // 本帧吐字节数
    reg [7:0]  last_bytes [0:31];   // 本帧字节
    reg [7:0]  fb_q [0:31];         // 正在收帧的字节缓冲
    integer    fb_n;                // 缓冲写指针
    reg        frame_on;            // 当前帧开
    reg        in_frame_d;          // in_frame 上一拍 (边沿检测)

    // ---- 因果链辅助 (2026-09-07) ----
    // 只记录逐帧关键 tick / 打印证据, 不参与 pass/fail (断言仍归各 case 的 errors 与 oracle)。
    // st_stat_cur: USB_IDLE=0 / USB_SYNC_SEEK=1 / USB_DATA=2 / USB_ERROR=3。
    reg  [1:0] causal_prev_st = 2'd0;   // st_stat_cur 上一拍 (逐拍跟踪)
    integer    causal_nbytes  = 0;      // 本帧已吐字节数 (仅 DATA 期自计)
    integer    causal_fbn_err = 0;      // 进 USB_ERROR 前已吐字节数
    integer    causal_ones_data = 0;    // 进 USB_DATA 时 ones_cnt (期望 0: 解填充从 PID 起算)
    integer    causal_idle_run = 0;     // "线 J(idle) 且 st=IDLE" 的累计 ref_clk 拍
    integer    causal_idle_ref = 0;     // 本帧首沿前刚结束的 idle 长 (ref_clk 拍, 前窗)
    reg        causal_bad = 1'b0;       // 本帧进过 USB_ERROR
    time       causal_t_seek = 0;       // IDLE→SYNC_SEEK (因: 首个 0)
    time       causal_t_data = 0;       // SYNC_SEEK→DATA (变: SYNC 尾巴命中)
    time       causal_t_err  = 0;       // DATA→USB_ERROR (变: 检错)
    time       causal_t_rel  = 0;       // USB_ERROR→IDLE (果: 释放)

    // ---- line_s 观测 (ref_clk 域) ----
    // 验「usb_rst 不碰 ref 域的线采样寄存器」: 窗内把线钉住不动, 于是
    // line_s 每个 ref 沿都该等于引脚; 一旦被复位打成 2'b00 (假 SE0), 这里置位。
    // 只在 ls_watch=1 且线静止时判, 平时 line_s 落后引脚一拍是正常的。
    reg ls_watch = 1'b0;
    reg ls_dirty = 1'b0;
    always @(posedge ref_clk) begin
        if (ref_rstn && ls_watch && (dut_line_s !== {rxdp, rxdn}))
            ls_dirty <= 1'b1;
    end

    // ---- 帧/字节监视 (clk12m 域) ----
    always @(posedge dclk) begin
        // 帧开沿 (in_frame 0→1, 跨拍比较)
        if (!in_frame_d && u_dut.in_frame) begin
            frame_on = 1;
            fb_n     = 0;
            last_open_t = $time;
        end
        // 帧关沿 (in_frame 1→0): 记关包 rx_error (该拍仍是帧错误电平, 晚一拍才清)
        if (in_frame_d && !u_dut.in_frame) begin
            frame_on = 0;
            last_err     = u_dut.rx_error;
            last_nbyte   = fb_n;
            last_close_t = $time;
            begin : copyb
                integer k;
                for (k = 0; k < fb_n; k = k + 1)
                    last_bytes[k] = fb_q[k];
            end
            close_cnt = close_cnt + 1;
        end
        in_frame_d <= u_dut.in_frame;

        // 字节收集
        if (u_dut.rx_valid) begin
            fb_q[fb_n] = u_dut.rx_data;
            fb_n = fb_n + 1;
        end
    end

    // ---------------------------------------------------------------------
    // 因果链记录器 (clk12m 域): 逐拍跟踪 st_stat_cur 变化, 记关键 tick。
    // 只写本组 causal_* 信号 (单驱动), 不读/改帧监视器变量 → 无跨 always 竞态。
    // ---------------------------------------------------------------------
    always @(posedge dclk) begin
        if (ref_rstn) begin
            if (dut_st_cur !== causal_prev_st) begin
                if (dut_st_cur == 2'd1 && causal_prev_st == 2'd0) begin
                    // 因: 首个 0 (SYNC 首 K) 离开 idle → SYNC_SEEK = 本帧起点
                    causal_t_seek = $time;
                    causal_bad    = 1'b0;      // 帧内标志: 到本帧起点才重记
                    causal_nbytes = 0;
                end
                else if (dut_st_cur == 2'd2 && causal_prev_st == 2'd1) begin
                    causal_t_data    = $time;          // 变: SYNC 尾巴 ≥4 个 0 + 1 命中
                    causal_ones_data = u_dut.ones_cnt; // 进 DATA 时 ones_cnt (从 PID 起算 → 期望 0)
                end
                else if (dut_st_cur == 2'd3) begin
                    causal_t_err   = $time;            // 变: 检错进 USB_ERROR
                    causal_fbn_err = causal_nbytes;    // 进 ERROR 前已吐字节 (此后停吐)
                    causal_bad     = 1'b1;
                end
                else if (dut_st_cur == 2'd0 && causal_prev_st == 2'd3)
                    causal_t_rel = $time;              // 果: ERROR 释放回 IDLE
                causal_prev_st = dut_st_cur;
            end
            if (dut_st_cur == 2'd2 && u_dut.rx_valid)
                causal_nbytes = causal_nbytes + 1;     // 帧内字节自计 (仅 DATA 期吐字节)
        end
    end

    // ---------------------------------------------------------------------
    // 填充规则断言 (clk12m 域, 2026-09-16): 解填充计数从 PID 起算。
    // 依据 (设计报告 §2.4): SYNC 之后必是 PID, PID = code + ~code 结构上最多
    // 4 连 1, 与 SYNC 尾 1 合起来 5 < 6 → SYNC/PID 段不可能出现填充位,
    // 故进 USB_DATA 的当拍 ones_cnt 必须为 0 (SYNC 尾 1 不参与计数)。
    // 全用例通用; 若有人把窗口退回旧写法 (只 IDLE 保持 0), 本断言立刻报错。
    // ---------------------------------------------------------------------
    reg [1:0] rones_prev_st = 2'd0;        // 上一拍 st_stat_cur (仅本断言使用)
    always @(posedge dclk) begin
        if (ref_rstn) begin
            if (dut_st_cur == 2'd2 && rones_prev_st != 2'd2) begin
                if (u_dut.ones_cnt !== 3'd0) begin
                    $display("  ERROR: 进 USB_DATA 时 ones_cnt=%0d (应为 0: 解填充从 PID 起算)",
                             u_dut.ones_cnt);
                    errors = errors + 1;
                end
            end
            rones_prev_st <= dut_st_cur;
        end
    end

    // 前窗计量 (ref_clk 域): 逐拍累计 "线 J(idle) 且 DUT 停 USB_IDLE" 的拍数;
    // 任一非 J 沿 (SYNC 首 K / SE0 / 数据 K) 把刚结束的 idle 长锁进 causal_idle_ref
    // 并归零重计 → causal_idle_ref = 本帧从多干净的 idle 起 (前窗证据)。
    always @(posedge ref_clk) begin
        if (!ref_rstn) begin
            causal_idle_run <= 0;
            causal_idle_ref <= 0;
        end
        else if (line_state == 2'b10 && dut_st_cur == 2'd0)
            causal_idle_run <= causal_idle_run + 1;
        else begin
            causal_idle_ref <= causal_idle_run;
            causal_idle_run <= 0;
        end
    end

    // ---------------------------------------------------------------------
    // SYNC 判决记录器 (clk12m 域, 2026-09-14): 只记录, 不参与 pass/fail。
    // 目的: 把 SYNC 检测的"判决点"定格 —— 每次 SEEK→DATA(命中) / SEEK→IDLE(拒收),
    //   同时记两个量, 供 case_sync_scan 对窗口 [4,7] 下判据:
    //     · run = tb 自数的"解码连续 0"物理长度 (黑盒输入侧, 不受 DUT 内部影响)
    //     · cnt = DUT 的 zero_cnt 折算出的"本轮 SEEK 计入 0 个数" (白盒)
    //   两者在每次注入的**首个**判决上必须相等 —— 这条交叉核对把"zero_cnt 数得对不对"
    //   钉死, 之后再用 cnt 判窗口就不会陷入自证 (DUT 的数器和判据都用 DUT 的)。
    // 判决由该拍 d_bit 触发 → d_bit=1 (命中/0 太少) 时 run = sync_zrun;
    //                         d_bit=0 (第 8 个 0, 0 太多) 时 run = sync_zrun + 1。
    // ★ 判决定格用"上一拍状态 + 上一拍值"回放, 不引 DUT 内部 st_nxt:
    //   本 TB 还要跑 sim 本地实验副本 (1 段式 FSM, 无 st_nxt), 引 st_nxt 会
    //   在那些 MODE 下 elaborate 失败; 回放法对两种 DUT 写法都成立。
    //   同一拍内先寄存 d_bit/zero_cnt/sync_zrun 的现值, 等下一拍看到
    //   "SEEK→非 SEEK"时, 读到的正是判决拍的值 (与旧写法逐位等价)。
    // 只写本组 sync_* 信号 (单驱动), 不读/改帧监视器 → 无跨 always 竞态。
    // ---------------------------------------------------------------------
    integer   sync_dec_n = 0;              // SEEK 判决序号 (单调递增)
    reg [1:0] sync_code_q [0:31];          // 判决 n: 0=命中 1=拒收-0太少 2=拒收-0太多(第8个0)
    reg [7:0] sync_run_q  [0:31];          // 判决 n: tb 实测"解码连续 0"长度 (物理输入)
    reg [3:0] sync_cnt_q  [0:31];          // 判决 n: DUT 侧本轮 SEEK 计入的 0 个数
    integer   sync_t_q    [0:31];          // 判决 n: 时刻
    integer   sync_wptr   = 0;             // 环形写指针 (32 深)
    reg [7:0] sync_zrun   = 8'd0;          // 当前连续解码 0 长度 (逐拍, 物理)
    reg [1:0] sync_prev_st = 2'd0;         // 上一拍 st_stat_cur (判决回放用)
    reg       sync_bit_q   = 1'b0;         // 上一拍 d_bit (判决拍的解码位)
    reg [2:0] sync_zc_q    = 3'd0;         // 上一拍 zero_cnt (判决拍的 DUT 计入 0 数)
    reg [7:0] sync_zr_q    = 8'd0;         // 上一拍 sync_zrun (判决拍的实测连跑)
    integer   sync_t_prev  = 0;            // 上一拍 $time (判决拍时刻, 回放用)

    always @(posedge dclk) begin
        if (!ref_rstn) begin
            sync_zrun <= 8'd0;
        end
        else begin
            if (!u_dut.d_bit) sync_zrun <= sync_zrun + 8'd1;   // 又一个解码 0
            else              sync_zrun <= 8'd0;               // 遇 1, 连跑清零

            // 判决回放: 本拍 st_stat_cur 已离开 SEEK, 上一拍在 SEEK → 判决发生在上一拍。
            //   SEEK → DATA: 命中 / SEEK → IDLE: 拒收
            // d_bit 区分两种拒收: 1=0 太少(1 来早了) / 0=0 太多(第 8 个 0)
            if (sync_prev_st == 2'd1 && dut_st_cur != 2'd1) begin
                if (dut_st_cur == 2'd2) sync_code_q[sync_wptr] = 2'd0;   // 命中
                else if (sync_bit_q)        sync_code_q[sync_wptr] = 2'd1;   // 0 太少
                else                        sync_code_q[sync_wptr] = 2'd2;   // 0 太多
                // 判决由该拍 bit 触发: d_bit=1 时 run = 已累计 0 数;
                //                       d_bit=0 (第 8 个 0) 时 = 已累计 + 1
                sync_run_q[sync_wptr] = sync_bit_q ? sync_zr_q : (sync_zr_q + 8'd1);
                sync_cnt_q[sync_wptr] = sync_bit_q ? sync_zc_q : (sync_zc_q + 3'd1);
                sync_t_q  [sync_wptr] = sync_t_prev;   // 判决拍时刻 (非本拍)
                sync_wptr  = (sync_wptr + 1) % 32;
                sync_dec_n = sync_dec_n + 1;
            end

            sync_prev_st <= dut_st_cur;   // 本拍值留给下一拍回放
            sync_bit_q   <= u_dut.d_bit;
            sync_zc_q    <= u_dut.zero_cnt;
            sync_zr_q    <= sync_zrun;
            sync_t_prev  <= $time;
        end
    end

    // ---- 打印最近一帧摘要 ----
    task dump_last_frame;
        integer k;
        begin
            $write("    [frame] close@%0t nbyte=%0d err=%0d bytes=",
                   last_close_t, last_nbyte, last_err);
            for (k = 0; k < last_nbyte; k = k + 1)
                $write("%02x ", last_bytes[k]);
            $write("\n");
        end
    endtask

    // ---- 因果链打印: 前窗 / 因 / 变 / 果 (2026-09-07; 仅证据, 不参与 pass/fail) ----
    task causal_print;
        input [8*63:0] tag;
        input integer expect_err;          // 期望关包 err: 0=正常包, 1=坏包
        begin
            $display("因果链·%0s", tag);
            $display("  前窗: 本帧首沿前 线保持 J(idle) 且 st=USB_IDLE 共 %0d ref_clk 拍 (干净 idle 起点, 非脏起点)",
                     causal_idle_ref);
            $display("  因: 首个 0 (SYNC 首 K) 离开 idle → st: USB_IDLE→USB_SYNC_SEEK @%0t", causal_t_seek);
            $display("  变: SYNC 尾 ≥4 个 0 + 1 命中 → st: USB_SYNC_SEEK→USB_DATA @%0t (进 DATA 时 ones_cnt=%0d, 解填充从 PID 起算=0)",
                     causal_t_data, causal_ones_data);
            if (causal_bad)
                $display("  变: 帧中检错 → st: USB_DATA→USB_ERROR @%0t, 停吐 (进 ERROR 前已出 %0d 字节); 关包采样:",
                         causal_t_err, causal_fbn_err);
            else
                $display("  果: 正常 EOP 关包 (st: USB_DATA→USB_IDLE), 关包采样:");
            dump_last_frame();
            // 判据直书 (避免字符串字面量过 ?: 拓宽致 UTF-8 错乱, 2026-09-07)
            if (expect_err)
                $display("    (期望 err=1, 判据: 坏包必于关包沿采到 err=1)");
            else
                $display("    (期望 err=0, 判据: 正常包必于关包沿采到 err=0)");
        end
    endtask

    // ---- 因果链 后窗: 关包后再采 4 ref_clk, 报 rx_error 最值与末拍 st ----
    task causal_post;
        input [8*63:0] tag;
        integer i;
        reg    post_max;
        begin
            post_max = 1'b0;
            for (i = 0; i < 4; i = i + 1) begin
                #(CLK_HALF * 2);                    // 约 1 ref_clk
                if (rx_error) post_max = 1'b1;
            end
            $display("因果链·%0s 后窗: 关包后 4 ref_clk 内 rx_error 最值=%0d (期望 0 = 晚一拍已清), 末拍 st=%0d (期望 0 = USB_IDLE)",
                     tag, post_max, dut_st_cur);
        end
    endtask

    // ---- 等第 tgt 帧关包 (带超时, 单位 bit time) ----
    task wait_close(input integer tgt, input integer timeout_bt);
        integer guard;
        begin
            guard = 0;
            while (close_cnt < tgt && guard < timeout_bt) begin
                #(BIT_TIME);
                guard = guard + 1;
            end
            if (close_cnt < tgt)
                $display("    WARN: timeout waiting for frame #%0d close (have %0d)", tgt, close_cnt);
        end
    endtask

    // ---- include 公共任务 (定义 PID 宏 / bit_task / sync_task / eop_task...) ----
    // 放这里: 宏 textually 先于下方 helper, 且 record_en 等由其声明。
    `include "usb_pkt_tasks.vh"

    // ---- 驱动到 "K 电平 + 数据 ones=0" 的包首 (SYNC + PID(OUT) + 归零) ----
    // 归零: 依据 bit_task 维护的 nrzi_lv 电平, 用最少个 0 把线停到 K 且清掉
    // deserial 的解填充 ones_cnt (最后一个数据 0 把 ones 清零)。
    task body_ready_k0;
        integer _bc;
        begin
            _bc = 0;
            sync_task(4, -1, 4, _bc);            // SYNC → 进 DATA
            pid_task(`PID_TYPE_OUT, 4, -1, 4);   // PID 0xE1 (发完在 K 电平)
            if (nrzi_lv == 1'b0) begin
                bit_task(1'b0, 4);               // K→J
                bit_task(1'b0, 4);               // J→K, ones=0
            end else begin
                bit_task(1'b0, 4);               // J→K, ones=0
            end
        end
    endtask

    // ---- 驱动一个"SYNC+PID+归零 + K 电平 R 个 1 + EOP"的帧 ----
    // 返回后 deserial 已进 DATA; 帧关包随后发生。R = 包尾数据 1 连跑长度,
    // 在 K 电平后接真 EOP → 注入假 7 连 1 场景 (SE0 无跳变被解成 1)。
    task send_tail_pkt(input integer R);
        integer k;
        begin
            body_ready_k0;                       // 停到 K、ones=0
            for (k = 0; k < R; k = k + 1)
                bit_task(1'b1, 4);               // K 电平 R 个 1 = 包尾 1 连跑
            eop_task;                            // SE0×2 + J (真 EOP 帧尾)
        end
    endtask

    // ---- 物理保持某电平 n 个 bit (不经 bit_task, 无位填充) ----
    // lv=1 → J (D+高), lv=0 → K (D+低); 用于真违规(7连1)与长 SE0 注入。
    task raw_hold(input integer lv, input integer nbit);
        integer k;
        begin
            for (k = 0; k < nbit; k = k + 1) begin
                if (lv) begin rxdp = 1'b1; rxdn = 1'b0; end
                else    begin rxdp = 1'b0; rxdn = 1'b1; end
                #(BIT_TIME);
            end
            nrzi_lv = lv;
        end
    endtask

    // ---- 物理长 SE0 (双线低) 持续 t ----
    task raw_se0(input real t);
        begin
            rxdp = 1'b0; rxdn = 1'b0;
            #(t);
        end
    endtask

    // ---- usb_rst 同步脉冲: 恰 1 个 clk12m 周期 (契约宽度, 沿之间拉起/撤销) ----
    // 用 negedge 定位是为了避开 DUT 采样沿: 脉冲覆盖且只覆盖一个 posedge(dclk),
    // 若 RTL 写成"沿上多采一拍才生效"或"脉宽不够", 这里立刻暴露。
    task pulse_usb_rst;
        begin
            @(negedge dclk); stim_usb_rst = 1'b1;
            @(negedge dclk); stim_usb_rst = 1'b0;
        end
    endtask

    // ---- include 各 case 文件 ----
    `include "case_out_normal.v"
    `include "case_tail_scan.v"
    `include "case_stuff_viol.v"
    `include "case_se0_stuck.v"
    `include "case_conformant_scan.v"
    `include "case_byte_exact.v"
    `include "case_tail7.v"
    `include "case_pkt_all.v"
    `include "case_err_eop.v"
    `include "case_sync_scan.v"
    `include "case_eop_glitch.v"

    // ---------------------------------------------------------------------
    // FSM 状态 / 迁移弧覆盖 (自建, 补 Verilator 之缺)
    //
    // ★ 与 sim/tx 同一个理由: Verilator 的 --coverage-fsm 只识别单段式 FSM,
    //   认不出本 DUT 的两段式 (组合算 st_stat_nxt + 时序搬 st_stat_cur), 且 case 外
    //   套了 if (tx_active || rx_abort) → merged.dat 里 0 条 fsm 记录。
    //   不改已验收的 RTL, 改在 TB 侧分层引用 dut_st_cur 自己数。
    //
    // 口径: 每个 dclk 沿采一次 st_stat_cur (dclk = CDR 恢复时钟, 未锁停摆时不计数
    //   —— 与 DUT 实际拿不到沿的语义一致)。统计各态停留拍数 + 4×4 迁移。
    // ---------------------------------------------------------------------
    localparam [1:0] F_IDLE  = 2'd0;        // 与 DUT localparam 一一对应
    localparam [1:0] F_SEEK  = 2'd1;        // (TB 侧独立再写一遍, 免得改了
    localparam [1:0] F_DATA  = 2'd2;        //   RTL 编码 TB 却"跟着变")
    localparam [1:0] F_ERROR = 2'd3;

    integer fsm_visit [0:3];                // 各态停留拍数
    integer fsm_arc   [0:3][0:3];           // [from][to] 迁移次数

    reg [1:0] fsm_prev  = F_IDLE;           // 上一拍状态
    reg       fsm_armed = 1'b0;             // 复位撤除后才开始计数

    integer fi, fj;                         // 初始化/打印用

    always @(posedge dclk or negedge ref_rstn) begin
        if (!ref_rstn) begin
            fsm_prev  <= F_IDLE;
            fsm_armed <= 1'b0;
        end else if (!fsm_armed) begin
            fsm_prev  <= dut_st_cur;    // 复位后的第一拍只对齐基准
            fsm_armed <= 1'b1;
        end else begin
            fsm_visit[dut_st_cur] = fsm_visit[dut_st_cur] + 1;
            fsm_arc[fsm_prev][dut_st_cur] = fsm_arc[fsm_prev][dut_st_cur] + 1;
            fsm_prev  <= dut_st_cur;
        end
    end

    task print_fsm_coverage;
        begin
            $display("---- FSM 状态/弧覆盖 (u_dut, %0s) ----", case_name);
            $display("  停留拍数: IDLE=%0d SEEK=%0d DATA=%0d ERROR=%0d",
                     fsm_visit[F_IDLE], fsm_visit[F_SEEK],
                     fsm_visit[F_DATA], fsm_visit[F_ERROR]);
            $display("  迁移矩阵 (行=from 列=to, 单位: 拍):");
            $display("            to:  IDLE   SEEK   DATA  ERROR");
            for (fi = 0; fi < 4; fi = fi + 1) begin
                $write("    from %0d:  ", fi);
                for (fj = 0; fj < 4; fj = fj + 1)
                    $write("%6d ", fsm_arc[fi][fj]);
                $write("\n");
            end
        end
    endtask

    // ---- 测试主流程 ----
    reg [8*63:0] case_name;
    reg [8*63:0] vcd_name;

    initial begin
        if (!$value$plusargs("case=%s", case_name)) begin
            $display("ERROR: +case=<name> required");
            $display("  Available cases:");
            $display("    deserial_out_normal   — valid OUT token 回归 (clean close)");
            $display("    deserial_tail_scan    — 包尾 K 连 R 个 1 + EOP, 扫描 R");
            $display("    deserial_stuff_viol   — 真 7 连 1 违规 (非 SE0) 仍检错");
            $display("    deserial_se0_stuck    — SE0 卡死 ≥2.5us 行为");
            $display("    deserial_conformant_scan — 合规 DATA0 全扫 (K 尾 1 连跑) 找误判");
            $display("    deserial_byte_exact    — 整帧字节流 vs 理想 (PID/payload/CRC + rx_valid 数)");
            $display("    deserial_tail7         — 末字节 7 个 1: 正常填充 vs 填充错误");
            $display("    deserial_pkt_all       — 全部 USB1.1 包类型逐字节校验 (IN/SETUP/SOF/握手/PRE/坏PID/坏CRC)");
            $display("    deserial_err_eop       — EOP错(SE0→K)/无EOP自愈/rx_abort&tx_active&usb_rst 强退恢复");
            $display("    deserial_sync_scan     — SYNC 接受窗口扫描 (0 多/0 少, 判据用实测解码 0 长度)");
            $display("    deserial_eop_glitch    — 帧内亚判决点 SE0 (1/2 拍作废 + SE0→K→J 宽容收尾)");
            $finish(1);
        end

`ifdef VCD_SAVE
        if ($value$plusargs("vcd=%s", vcd_name)) begin
            $dumpfile(vcd_name);
            $dumpvars(0, tb_deserial);
            $display("INFO: VCD saved to %0s", vcd_name);
        end
`endif

        // 初始化
        ref_clk = 0;
        rxdp = 1'b1; rxdn = 1'b0;       // idle J
        nrzi_lv = 1'b1;
        ones_cnt = 0;
        errors = 0;
        record_en = 0;
        exp_tx_wptr = 0;
        stim_tx_active = 0;
        stim_rx_abort  = 0;
        stim_usb_rst   = 0;

        // FSM 覆盖计数清零
        for (fi = 0; fi < 4; fi = fi + 1) begin
            fsm_visit[fi] = 0;
            for (fj = 0; fj < 4; fj = fj + 1)
                fsm_arc[fi][fj] = 0;
        end

        // ---- 复位序列 (★ 三步顺序不可换, 与 sim/tx 同一类缺陷) ----
        // 目标: 让 DUT/TB 里所有 `always @(posedge dclk or negedge ref_rstn)` 的
        // **异步复位分支真正执行一次**。必须是"放开 → 拉低制造真 1→0 → 再放开":
        //   ① Verilator 里 reg 初值是 0, 开头直接 `ref_rstn = 0` 属 **0→0 不产生沿**,
        //      复位分支一次都不执行 (原来就是这么写的, 覆盖率把它标了出来);
        //   ② dclk 是 CDR 恢复时钟, 冷启动未锁时停摆 → 想 `@(posedge dclk)` 等沿
        //      等不到; 但异步复位分支由 `negedge ref_rstn` 触发, **与时钟无关**,
        //      只要做出一次真的 1→0 就能命中, 不需要 dclk 在跑。
        // 不这么做的双重危害: ① 复位路径零覆盖; ② 寄存器初值退化成仿真器默认值
        //   (iverilog=x, Verilator=0), 两家行为漂移, 会悄悄放过错误。
        ref_rstn = 1'b1;                            // ① 先放开 (Verilator 初值本就是 0)
        #200;
        ref_rstn = 1'b0;                            // ② 1→0 → 触发异步复位分支
        #200;
        ref_rstn = 1'b1;                            // ③ 正式撤复位
        #200;

        // 校准打印: 确定 $time 单位 (重标度校验, 一次即可)
        $display("CAL: t0=$time=%0t  $realtime=%0t  (ref_half=%0t)", $time, $realtime, $realtime);
        #1000;
        $display("CAL: after #1000 -> $time=%0t", $time);

        $display("==============================================");
        $display("  deserial Test Case: %0s", case_name);
        $display("==============================================");

        case (case_name)
            "deserial_out_normal":  case_out_normal;
            "deserial_tail_scan":   case_tail_scan;
            "deserial_stuff_viol":  case_stuff_viol;
            "deserial_se0_stuck":   case_se0_stuck;
            "deserial_conformant_scan": case_conformant_scan;
            "deserial_byte_exact": case_byte_exact;
            "deserial_tail7": case_tail7;
            "deserial_pkt_all": case_pkt_all;
            "deserial_err_eop": case_err_eop;
            "deserial_sync_scan": case_sync_scan;
            "deserial_eop_glitch": case_eop_glitch;
            default: begin
                $display("ERROR: unknown case '%0s'", case_name);
                $finish(1);
            end
        endcase

        // ---- FSM 覆盖 (每 case 一份; 合并口径见 tools/README_merge_fsm_cov.md) ----
        print_fsm_coverage;

        // ---- 汇总 ----
        $display("==============================================");
        if (errors == 0) begin
            $display("  TEST PASSED: usb_rx_deserial (%0s)", case_name);
            $display("==============================================");
            $finish(0);
        end else begin
            $display("  TEST FAILED: usb_rx_deserial (%0s) — %0d errors", case_name, errors);
            $display("==============================================");
            $finish(1);
        end
    end

endmodule
