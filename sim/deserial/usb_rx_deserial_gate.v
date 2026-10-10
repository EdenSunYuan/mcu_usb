//============================================================================
// usb_rx_deserial.v — RX 反序列化 / 字节恢复 (定稿版, clk12m 域位流水线)
// RX Deserializer (byte recovery) — final: clk12m bit pipeline
//
// usb_dpll_phy 的子模块 (PHY 最末端, 位→字节恢复; 2026-09-20 由 SIE 改挂 PHY):
//   把 PHY(CDR+clk_mux) 恢复的位时钟 clk12m + NRZI 电平 rx_bit,
//   变成 SIE 事务逻辑能直接消费的对齐字节流 + 包边界信号。
//
// ★★ 本文件 = sim/deserial 实验副本 ★★
//   在 src/phy/usb_rx_deserial.v 定稿基础上, 仅多出「EOP SE0 区门控」实验
//   (g_eop_se0: eop_state∈{se0_1,se0_2,se0_3} 期间掩 7 连 1/冻 ones_cnt/停移位),
//   用于仿真验证"尾部 K 连 1 + 真 EOP"假 7 连 1 修复。定稿文件保持不动。
//   Makefile 用 RTL=../ 指回定稿跑基线, 用本文件跑门控对照。
//
// ★ 本文件按 doc/design_rpt/rx_deserial_design.md 定稿重写:
//   - 位流水线 (NRZI/SYNC/解填充/字节对齐) 直接跑 clk12m(1×) 域, 每 bit 一拍;
//   - EOP/SE0 定界留在 ref_clk(4×) 域, Fig.7 5 态 FSM
//     (eop_idle/eop_se0_1/2/3/eop_dead), eop/eop_err 展宽跨到 clk12m 域;
//   - 收包帧状态机 4 态: USB_IDLE/USB_SYNC_SEEK/USB_DATA/USB_ERROR;
//     rx_active = (st_state==USB_DATA)||(st_state==USB_ERROR) 组合解码;
//   - rx_error 电平: 物理检错置起, 等总线回 idle 关包, 关包后晚一拍清 0;
//   - shift_reg 7 位 [6:0], 字节 {d_bit, shift_reg[6:0]} 第 8 位到齐拼出。
//
// 输出契约 = 纯 clk12m 1× 域同步信号, 直交同域 SIE (无 CDC 语义)。
//
// 参考: doc/design_rpt/rx_deserial_design.md (定稿)
//============================================================================

module usb_rx_deserial (
    input  wire       clk12m,           // 位流水线主时钟 12MHz (接收时 = dclk 经 usb_clk_mux)
    input  wire       ref_clk,          // 48MHz 参考时钟 (EOP/SE0 定界域, 4×)
    input  wire       ref_rstn,         // 异步复位 低有效 / async reset active-low
    input  wire       rx_bit,           // CDR 恢复的 NRZI 电平 (0=K,1=J), 领先 dclk 1 ref_clk
    input  wire       rxdp,             // USB D+ 单端 (SE0/EOP 检测, ref_clk 域采样)
    input  wire       rxdn,             // USB D- 单端 (SE0/EOP 检测, ref_clk 域采样)
    input  wire       tx_active,        // 设备正在发送 (自收发门控) / TX gating
    input  wire       rx_abort,         // SIE 溢出中止 (回 USB_IDLE, 不置 rx_error)
    output reg  [7:0] rx_data,          // 恢复的接收字节 (LSb 对齐, 维持满 667ns 字节周期)
    output reg        rx_valid,         // 每字节一拍脉冲 = 字节有效标记 (UTMI RXValid)
    output wire       rx_active,        // 帧中: (st_state==USB_DATA)||(st_state==USB_ERROR) 组合解码
    output reg        rx_error,         // 接收错误电平 (位填充违规 / EOP 错), 关包后晚一拍清
    output wire [1:0] line_state        // 单端电平 {rxdp,rxdn} (透传)
);

    // ---- 常量 ----
    // 收包帧状态机 (clk12m 域)
    localparam USB_IDLE      = 2'd0;   // 空闲 (搜索 SYNC 前的 0)
    localparam USB_SYNC_SEEK = 2'd1;   // 数 0 (SYNC 尾巴, 找 ≥SYNC_MIN_ZERO 个 0 + 1)
    localparam USB_DATA      = 2'd2;   // 数据接收 (PID 起; rx_active=1 且吐字节)
    localparam USB_ERROR     = 2'd3;   // 错误保持 (rx_active=1 但不吐字节, 等总线回 idle)
    localparam SYNC_MIN_ZERO = 4;      // SYNC 尾巴最少 0 个数 (容忍 CDR 吃 1~2 个 0)
    localparam STUFF_MAX_ONE = 6;      // 位填充上限: 连续 6 个 1 后插 0

    // EOP FSM (ref_clk 域, Fig.7)
    localparam ST_EOP_IDLE   = 3'd0;   // 空闲 (待 SE0)
    localparam ST_EOP_SE0_1  = 3'd1;   // SE0 第 1 拍
    localparam ST_EOP_SE0_2  = 3'd2;   // SE0 第 2 拍
    localparam ST_EOP_SE0_3  = 3'd3;   // SE0 第 3 拍 (≈62.5ns, 达判决点)
    localparam ST_EOP_DEAD   = 3'd4;   // SE0 后非 J 异常收尾 (只待一拍, j 补判 eop)
    localparam EOP_WIDEN_MAX = 4'd8;   // eop/eop_err 展宽 ≥1 clk12m 周期 (plan B)

    //========================================================================
    // clk12m 域 — 位流水线
    //========================================================================

    // ---- line_state: {rxdp,rxdn} 透传 ----
    assign line_state = {rxdp, rxdn};

    // ---- NRZI 解码: 电平不变 → 数据 1; 电平跳变 → 数据 0 ----
    // 采样原则: 在 clk12m 上升沿采样 rx_bit (其组合输出领先 dclk 1 ref_clk,
    // 处稳定窗口), 与上一拍锁存的 nrzi_prev 比较 (报告 §2.2/§4.2)。
`ifdef NRZI2
    // (实验 2) NRZI2: rx_bit 打 2 级寄存, 相邻两拍直接同或出解码 (无跳变→1)。
    // 与默认单拍比较解的是同一跳变区间 [N-1,N], 解码位序列/时序一致, 仅实现
    // 改为全寄存、不组合依赖实时 rx_bit。本实验关掉 EOP 门控 (g_eop_se0=0),
    // 专测"2 拍异或解码本身能否消除 SE0 假 7 连 1"。
    reg rx_d1, rx_d2;
    always @(posedge clk12m or negedge ref_rstn) begin
        if (!ref_rstn) begin
            rx_d1 <= 1'b1;                    // idle J
            rx_d2 <= 1'b1;
        end else if (tx_active) begin
            rx_d1 <= 1'b1;                    // 自发送期对齐到 idle J
            rx_d2 <= 1'b1;
        end else begin
            rx_d2 <= rx_d1;                   // 打 2 拍 (rx_bit → rx_d1 → rx_d2)
            rx_d1 <= rx_bit;
        end
    end
    wire d_bit = (rx_d1 == rx_d2) ? 1'b1 : 1'b0;   // 相邻两拍同或 = 无跳变→1
`else
    reg nrzi_prev;
    always @(posedge clk12m or negedge ref_rstn) begin
        if (!ref_rstn)
            nrzi_prev <= 1'b1;                 // idle J
        else if (tx_active)
            nrzi_prev <= 1'b1;                 // 自发送期对齐到 idle J
        else
            nrzi_prev <= rx_bit;               // 锁存上一拍电平
    end
    wire d_bit = (rx_bit == nrzi_prev) ? 1'b1 : 1'b0;   // 解码位 / decoded bit
`endif

    // ---- 收包帧状态 (组合解码 rx_active) ----
    wire in_frame = (st_state == USB_DATA) || (st_state == USB_ERROR);
    assign rx_active = in_frame;               // 帧中有效信号 (UTMI RXActive)

    reg [1:0] st_state;                        // 收包帧状态机
    reg [2:0] zero_cnt;                        // SYNC 连续 0 计数 (仅 SEEK)
    reg [2:0] ones_cnt;                        // 解填充连续 1 计数 (帧中 = rx_active)
    reg [6:0] shift_reg;                       // 字节移位寄存器 (存 b0~b6)
    reg [2:0] bit_cnt;                         // 字节内位计数 0~7 (3-bit 自回绕)

    // 帧状态机 (报告 §2.3 状态表 / §2.6 释放条件)
    // 次态只由当前态 + 解码位/事件决定, 与零一计数各寄存器同时更新 (读当前值)。
    // 进位优先级: eop_sync(正常关包) > eop_err_sync/7连1(错误) ; ERROR 态释放 = eop/7连1。
    always @(posedge clk12m or negedge ref_rstn) begin
        if (!ref_rstn)
            st_state <= USB_IDLE;
        else if (tx_active || rx_abort)
            st_state <= USB_IDLE;              // 自发送/中止 → 回空闲
        else begin
            case (st_state)
                USB_IDLE: begin
                    if (!d_bit)
                        st_state <= USB_SYNC_SEEK;   // 首个 0 = 包开始候选
                end
                USB_SYNC_SEEK: begin
                    if (!d_bit && (zero_cnt == 3'd7))
                        st_state <= USB_IDLE;        // 0 过多 (第 8 个 0) 非法
                    else if (d_bit && (zero_cnt >= SYNC_MIN_ZERO))
                        st_state <= USB_DATA;        // SYNC 命中 (≥4 个 0 + 1)
                    else if (d_bit)
                        st_state <= USB_IDLE;        // 假触发 (0 太少)
                    // else: 又一个 0, 继续 SEEK
                end
                USB_DATA: begin
                    if (eop_sync)
                        st_state <= USB_IDLE;        // 正常关包 (EOP FSM 拉 eop, SE0→J)
                    else if (eop_err_sync)
                        st_state <= USB_ERROR;       // EOP 错 (SE0 后非 J)
                    else if (seven_ones_data)
                        st_state <= USB_ERROR;       // 位填充违规 7 连 1 → 错误保持
                end
                USB_ERROR: begin
                    if (eop_sync)
                        st_state <= USB_IDLE;        // 坏帧仍以 SE0→J 帧尾结束 → 释放
                    else if (seven_ones_err)
                        st_state <= USB_IDLE;        // 静默回 J, 7 连 1 再现 → 释放 (idle 探针)
                end
                default: st_state <= USB_IDLE;
            endcase
        end
    end

    // ---- zero_cnt: SYNC 连续 0 计数 (窗口仅 USB_SYNC_SEEK) ----
    always @(posedge clk12m or negedge ref_rstn) begin
        if (!ref_rstn)
            zero_cnt <= 3'd0;
        else if (tx_active || rx_abort)
            zero_cnt <= 3'd0;
        else begin
            case (st_state)
                USB_IDLE:      zero_cnt <= (!d_bit) ? 3'd1 : 3'd0;   // 首个 0 起数
                USB_SYNC_SEEK: begin
                    if (!d_bit)
                        zero_cnt <= (zero_cnt == 3'd7) ? 3'd0 : zero_cnt + 3'd1;
                    else
                        zero_cnt <= 3'd0;           // 命中/假触发 → 清 0
                end
                default:       zero_cnt <= 3'd0;    // DATA/ERROR 保持 0
            endcase
        end
    end

    // ---- ones_cnt: 解填充连续 1 计数 ----
    // 窗口 = rx_active (DATA/ERROR, 帧中), 帧外 (IDLE/SEEK) 保持 0;
    // 计数从 PID 起算 → 进 DATA 时 = 0 (SYNC 尾 1 不计入, 见定稿文件同处说明);
    // bit=1 自加(封顶 6), bit=0 清零;
    // 数满 6 后下一个 bit 是 stuffed 0 (丢弃清零) 或 7 连 1 违规;
    // 违规/错误清零重计 (ERROR 期当 idle 探针)。
    // 本副本与定稿文件保持同一套填充规则, 唯一变量仍是下面的 g_eop_se0 门控。
    always @(posedge clk12m or negedge ref_rstn) begin
        if (!ref_rstn)
            ones_cnt <= 3'd0;
        else if (tx_active || rx_abort)
            ones_cnt <= 3'd0;
        else if (!rx_active)
            ones_cnt <= 3'd0;                      // 帧外 (IDLE/SEEK) 保持 0
        else if (enter_error)
            ones_cnt <= 3'd0;                      // 进 USB_ERROR 清 0 重计 (idle 探针)
        else if (g_eop_se0)
            ones_cnt <= 3'd0;                      // (实验门控) EOP SE0 区: 恒 0, 不累计
        else if (d_bit) begin
            if (ones_cnt == STUFF_MAX_ONE)
                ones_cnt <= 3'd0;                  // 7 连 1 (DATA 违规/ERROR 释放) → 清 0
            else
                ones_cnt <= ones_cnt + 3'd1;
        end else begin
            ones_cnt <= 3'd0;                      // bit=0 (含 stuffed 0) 清零
        end
    end

    // ---- 7 连 1 检测 (按态分义: DATA=物理错, ERROR=静默 idle 探针) ----
    wire seven_ones_data = (st_state == USB_DATA)  && (ones_cnt == STUFF_MAX_ONE) && d_bit && !g_eop_se0;
    wire seven_ones_err  = (st_state == USB_ERROR) && (ones_cnt == STUFF_MAX_ONE) && d_bit && !g_eop_se0;
    // 进 USB_ERROR (由 DATA 内 7 连 1 或 EOP 错触发) → ones_cnt 重计
    wire enter_error = (st_state == USB_DATA) && (eop_err_sync || seven_ones_data);

    // ---- 解填充输出 / 移位使能 ----
    // 有效数据 bit = DATA 态 + ones_cnt<6 (stuffed 0 / 7连1 违规都不是数据)。
    wire enable_shift = (st_state == USB_DATA) && (ones_cnt != STUFF_MAX_ONE) && !g_eop_se0;

    // ---- shift_reg: 7 位右移, 新数据 bit 进 MSB, 最早收到进 LSB ----
    // 第 8 位 b7 只出现在 d_bit 输入上, 由 {d_bit, shift_reg[6:0]} 拼整字节, 故 7 位即够。
    always @(posedge clk12m or negedge ref_rstn) begin
        if (!ref_rstn)
            shift_reg <= 7'd0;
        else if (tx_active || rx_abort)
            shift_reg <= 7'd0;
        else if (st_state != USB_DATA)
            shift_reg <= 7'd0;                     // SEEK 前 / ERROR 期 / 关包后清 0
        else if (enable_shift)
            shift_reg <= {d_bit, shift_reg[6:1]};  // 每有效数据 bit 移一拍
    end

    // ---- bit_cnt: 字节内位计数 (仅 DATA 有效数据位累加, 3-bit 自回绕) ----
    always @(posedge clk12m or negedge ref_rstn) begin
        if (!ref_rstn)
            bit_cnt <= 3'd0;
        else if (tx_active || rx_abort)
            bit_cnt <= 3'd0;
        else if (st_state != USB_DATA)
            bit_cnt <= 3'd0;
        else if (enable_shift)
            bit_cnt <= bit_cnt + 3'd1;             // 7+1 自然溢出回绕到 0
    end

    // ---- byte_rdy: 第 8 位到齐 (bit_cnt==7 且为有效数据位) ----
    wire byte_rdy = enable_shift && (bit_cnt == 3'd7);

    // ---- rx_data: 满字节拼出并锁存 (维持满字节周期) ----
    always @(posedge clk12m or negedge ref_rstn) begin
        if (!ref_rstn)
            rx_data <= 8'd0;
        else if (byte_rdy)
            rx_data <= {d_bit, shift_reg[6:0]};    // 第 8 位(b7) + 已存 b0~b6, LSb 对齐
    end

    // ---- rx_valid: byte_rdy 打一拍产生 1 拍脉冲 (数据已在脉冲拍稳定) ----
    always @(posedge clk12m or negedge ref_rstn) begin
        if (!ref_rstn)
            rx_valid <= 1'b0;
        else if (tx_active || rx_abort)
            rx_valid <= 1'b0;
        else
            rx_valid <= byte_rdy;
    end

    // ---- rx_error 晚一拍清 0 的依据: 记上一拍是否在帧内 ----
    // rx_active 是组合解码, st_state 离开帧态当拍即落 0; SIE 下一拍才采到下降沿,
    // 故 rx_error 在关包后第 1 个 IDLE 周期仍为 1, 第 2 个周期起为 0 (报告 §2.6)。
    reg was_frame;
    always @(posedge clk12m or negedge ref_rstn) begin
        if (!ref_rstn)
            was_frame <= 1'b0;
        else
            was_frame <= in_frame;                 // 上一拍 in_frame (关包沿后一拍为 1)
    end
    wire frame_just_closed = was_frame && !in_frame;   // 关包后第 1 个 IDLE 周期

    // ---- rx_error: 电平 (检错置起 / ERROR 保持 / 关包晚一拍清) ----
    // eop_err_sync 只在 DATA 态置错 (进 ERROR 由帧机裁决); eop_sync 优先则不算错。
    wire err_set = (!eop_sync) && (seven_ones_data || eop_err_sync);
    always @(posedge clk12m or negedge ref_rstn) begin
        if (!ref_rstn)
            rx_error <= 1'b0;
        else if (tx_active || rx_abort)
            rx_error <= 1'b0;                      // 中止/自发送: 立即清
        else if (err_set)
            rx_error <= 1'b1;                      // 物理检错: 置起 (电平)
        else if (frame_just_closed)
            rx_error <= 1'b0;                      // 关包后晚一拍清 0
    end

    //========================================================================
    // ref_clk 域 — EOP/SE0 定界 (Fig.7, 独立于位流水线)
    //========================================================================

    // ---- ref_clk 域采样 line_state (每 4× 拍一次, 判 se0/j/其他) ----
    reg [1:0] line_s;
    always @(posedge ref_clk or negedge ref_rstn) begin
        if (!ref_rstn)
            line_s <= 2'b10;                       // 复位回 idle J
        else
            line_s <= {rxdp, rxdn};
    end
    wire line_se0 = (line_s == 2'b00);             // SE0 (D+ 与 D- 同 0)
    wire line_j   = (line_s == 2'b10);             // J (全速 idle)

    // ---- EOP FSM (仅 rx_active=1 时运行, 否则停在 eop_idle) ----
    reg [2:0] eop_state;
    always @(posedge ref_clk or negedge ref_rstn) begin
        if (!ref_rstn)
            eop_state <= ST_EOP_IDLE;
        else if (!in_frame)
            eop_state <= ST_EOP_IDLE;              // 帧未开 (含 tx_active 强制回 IDLE): 待命
        else begin
            case (eop_state)
                ST_EOP_IDLE:
                    eop_state <= line_se0 ? ST_EOP_SE0_1 : ST_EOP_IDLE;
                ST_EOP_SE0_1:
                    eop_state <= line_se0 ? ST_EOP_SE0_2 : ST_EOP_IDLE; // <2 拍作废
                ST_EOP_SE0_2:
                    eop_state <= line_se0 ? ST_EOP_SE0_3 : ST_EOP_IDLE; // <3 拍作废
                ST_EOP_SE0_3:
                    if (line_se0)      eop_state <= ST_EOP_SE0_3;       // 长 SE0 自环
                    else if (line_j)   eop_state <= ST_EOP_IDLE;        // 正常 EOP (SE0→J)
                    else               eop_state <= ST_EOP_DEAD;        // SE0 后非 J
                default: // ST_EOP_DEAD
                    eop_state <= ST_EOP_IDLE;       // 异常收尾只待一拍
            endcase
        end
    end

    // ---- (实验门控) EOP SE0 区指示 → clk12m 域 ----
    // 目的: 假 7 连 1 来自"SE0 被解成 K → 连续 1 累计", 故在"线已见 SE0"期间,
    //   把 7 连 1/计数/移位全部关掉 (g_eop_se0=1)。
    // 仅仿真实验用 (sim/deserial 副本), 未入 src/phy/usb_rx_deserial.v 定稿。
    // 门控源可选 (Makefile 定义, 决定"SE0 指示"多早/多干净):
    //   默认       : 组合直接读 ref 域 eop_state ∈ {se0_1,2,3} (FSM 态, 需 in_frame)
    //   GATE_SYNC  : 同上但打一拍跨到 clk12m (多 ~1 clk12m, 看漏拦首个 SE0 解码)
    //   GATE_LINESE0: 组合读 ref 域 line_se0 (line_s==00, 原始单端双线采样, 无 FSM 依赖)
    //   GATE_RAWSE0 : 组合直读模块输入引脚 !rxdp&&!rxdn (零 ref 打拍, 最"实时")
    wire eop_se0_region = (eop_state == ST_EOP_SE0_1) || (eop_state == ST_EOP_SE0_2) ||
                          (eop_state == ST_EOP_SE0_3);
    wire g_eop_se0;
`ifdef GATE_SYNC
    reg g_eop_se0_r;
    always @(posedge clk12m or negedge ref_rstn) begin
        if (!ref_rstn)
            g_eop_se0_r <= 1'b0;
        else
            g_eop_se0_r <= eop_se0_region;
    end
    assign g_eop_se0 = g_eop_se0_r;
`elsif GATE_LINESE0
    assign g_eop_se0 = line_se0;                    // line_s==00 (1 ref 打拍后组合读)
`elsif GATE_RAWSE0
    assign g_eop_se0 = (!rxdp && !rxdn);            // 原始引脚, 零打拍
`elsif NRZI2
    assign g_eop_se0 = 1'b0;                        // 实验2: 关掉 SE0 门控, 纯测 2 拍解码
`else
    assign g_eop_se0 = eop_se0_region;              // eop FSM 态组合读 (默认)
`endif

    // ---- EOP 事件 (ref_clk 域组合): eop / eop_err ----
    // eop_dead 见 j → 补判 eop (宽容收尾); 见非 j → eop_err (EOP 错)。
    wire eop_evt   = in_frame && (eop_state == ST_EOP_SE0_3) && line_j;
    wire eop_evt2  = in_frame && (eop_state == ST_EOP_DEAD)  && line_j;
    wire eop_err_evt = in_frame && (eop_state == ST_EOP_DEAD) && !line_j;

    // ---- eop/eop_err 展宽 (plan B: 展到 ≥1 clk12m 周期再跨域) ----
    reg        eop_w;         // eop 展宽电平 (ref_clk 域)
    reg        eop_err_w;     // eop_err 展宽电平 (ref_clk 域)
    reg [3:0]  widen_cnt;     // 共享展宽计时
    wire widen_on = eop_w || eop_err_w;

    always @(posedge ref_clk or negedge ref_rstn) begin
        if (!ref_rstn)
            eop_w <= 1'b0;
        else if (eop_evt || eop_evt2)
            eop_w <= 1'b1;                         // eop 事件置起
        else if (widen_on && (widen_cnt == EOP_WIDEN_MAX))
            eop_w <= 1'b0;                         // 展宽结束清除
    end

    always @(posedge ref_clk or negedge ref_rstn) begin
        if (!ref_rstn)
            eop_err_w <= 1'b0;
        else if (eop_err_evt)
            eop_err_w <= 1'b1;                     // eop_err 事件置起
        else if (widen_on && (widen_cnt == EOP_WIDEN_MAX))
            eop_err_w <= 1'b0;                     // 展宽结束清除
    end

    always @(posedge ref_clk or negedge ref_rstn) begin
        if (!ref_rstn)
            widen_cnt <= 4'd0;
        else if (widen_on)
            widen_cnt <= (widen_cnt == EOP_WIDEN_MAX) ? 4'd0 : widen_cnt + 4'd1;
        else
            widen_cnt <= 4'd0;
    end

    // ---- 跨到 clk12m 域 (边沿对齐, 单拍采样, 无亚稳态) ----
    // 两时钟由 ref_clk 派生、上升沿对齐, eop_w 展宽 ≥1 clk12m 故不漏检 (报告 §2.7)。
    reg eop_sync;
    always @(posedge clk12m or negedge ref_rstn) begin
        if (!ref_rstn)
            eop_sync <= 1'b0;
        else
            eop_sync <= eop_w;
    end

    reg eop_err_sync;
    always @(posedge clk12m or negedge ref_rstn) begin
        if (!ref_rstn)
            eop_err_sync <= 1'b0;
        else
            eop_err_sync <= eop_err_w;
    end

endmodule
