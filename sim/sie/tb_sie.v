//============================================================================
// tb_sie.v — usb_sie (SIE 事务层, 只做接收) 单元测试顶层
//
// 层次: 本 tb 把 usb_sie 当 DUT, 输入走 **字节级** 契约
//   (rx_data/rx_valid/rx_active/rx_error) —— 即 PHY 的 usb_rx_deserial 输出,
//   不接 CDR/deserial (位级链路的验证已在 sim/cdr、sim/deserial 完成)。
//   端到端 (CDR→deserial→SIE) 另见 case_sie_e2e (本轮后补)。
//
// DUT 内部 (DUT 侧两级):
//   usb_sie ──┬─ usb_sie_pkt_rx   (包级, 无记忆)
//             ├─ usb_crc5_byte    (字节并行 CRC5)
//             └─ usb_crc16_byte   (字节并行 CRC16)
//
// 监视口径:
//   · 应答: resp_req 拍采 resp_pid → resp_q[] 队列, 用例按序核对
//   · 事件: ep_rx_done / setup_recv / sof_recv / ep_rx_bad / rx_abort 计数
//   · 缓冲: 排出字节记进 drain_rec[] (经 buf_rd_en 逐字节读口, 与 CDC 同口径)
//   · 白盒: u_sie 的事务态 / turn_cnt / toggle / 缓冲指针, 只读不驱动
//
// 复位序列: 先放开 ref_rstn → 拉低制造真 1→0 → 再放开 (与 sim/deserial、
//   sim/tx 同一套路, 保证所有异步复位分支真被执行一次)。
//============================================================================

`timescale 1ns/1ps

module tb_sie;

    // ---- 时钟: clk12m 就是 DUT 的时钟 (接收期 = dclk, 本 tb 直接给 12MHz) ----
    parameter real BIT_TIME = 1000.0 / 12.0;            // 83.333ns
    parameter real CLK_HALF = BIT_TIME / 2.0;

    reg clk12m;
    reg ref_rstn;

    always #(CLK_HALF) clk12m = ~clk12m;

    // ---- DUT 输入 (全部由 tb / sie_tasks.vh 驱动) ----
    reg        usb_rst      = 1'b0;
    reg        connect_evt  = 1'b0;
    reg  [7:0] rx_data      = 8'd0;
    reg        rx_valid     = 1'b0;
    reg        rx_active    = 1'b0;
    reg        rx_error     = 1'b0;
    reg        buf_rd_en    = 1'b0;
    reg  [6:0] dev_addr     = 7'd0;
    reg  [2:0] ep_stall     = 3'b000;
    reg  [2:0] ep_nak       = 3'b000;
    reg  [1:0] ep_dir       = 2'b00;
    reg  [2:0] toggle_set   = 3'b000;
    reg  [2:0] toggle_val   = 3'b000;

    // ---- DUT 输出 ----
    wire       rcv;
    wire       rx_abort;
    wire       resp_req;
    wire [7:0] resp_pid;
    wire [7:0] buf_rd_data;
    wire [6:0] buf_cnt;
    wire       buf_ready;
    wire       ep_rx_done;
    wire       ep_rx_bad;
    wire       setup_recv;
    wire       sof_recv;
    wire [10:0] frame_no;

    usb_sie u_sie (
        .clk12m      (clk12m),
        .ref_rstn    (ref_rstn),
        .usb_rst     (usb_rst),
        .connect_evt (connect_evt),
        .rx_data     (rx_data),
        .rx_valid    (rx_valid),
        .rx_active   (rx_active),
        .rx_error    (rx_error),
        .buf_rd_en   (buf_rd_en),
        .dev_addr    (dev_addr),
        .ep_stall    (ep_stall),
        .ep_nak      (ep_nak),
        .ep_dir      (ep_dir),
        .toggle_set  (toggle_set),
        .toggle_val  (toggle_val),
        .rcv         (rcv),
        .rx_abort    (rx_abort),
        .resp_req    (resp_req),
        .resp_pid    (resp_pid),
        .buf_rd_data (buf_rd_data),
        .buf_cnt     (buf_cnt),
        .buf_ready   (buf_ready),
        .ep_rx_done  (ep_rx_done),
        .ep_rx_bad   (ep_rx_bad),
        .setup_recv  (setup_recv),
        .sof_recv    (sof_recv),
        .frame_no    (frame_no)
    );

    // ---- 白盒只读别名 (诊断 + 覆盖率用, 不驱动 DUT) ----
    wire [2:0] dut_t_state  = u_sie.t_state_cur;
    wire [4:0] dut_turn_cnt = u_sie.turn_cnt;
    wire [2:0] dut_toggle   = u_sie.toggle;
    wire [6:0] dut_wr_ptr   = u_sie.wr_ptr;
    wire [6:0] dut_rd_ptr   = u_sie.rd_ptr;
    wire       dut_pkt_wr_ok= u_sie.pkt_wr_ok;
    wire       dut_attached = u_sie.attached;
    wire       dut_pkt_done = u_sie.pkt_done;

    // ---- 白盒探针: 在 pkt_done 拍采 pkt_rx 的包级字段 (字段解析的直接证据) ----
    reg  [6:0]  pr_tok_addr  = 7'd0;
    reg  [3:0]  pr_tok_endp  = 4'd0;
    reg  [10:0] pr_tok_frame = 11'd0;
    reg  [7:0]  pr_pid       = 8'd0;
    reg  [1:0]  pr_cls       = 2'd0;
    reg  [6:0]  pr_dat_len   = 7'd0;
    reg         pr_bad       = 1'b0;
    integer     pr_cnt       = 0;      // pkt_done 次数 (等包尾结论用)

    always @(posedge clk12m) begin
        if (u_sie.pkt_done) begin
            pr_tok_addr  <= u_sie.tok_addr;
            pr_tok_endp  <= u_sie.tok_endp;
            pr_tok_frame <= u_sie.tok_frame;
            pr_pid       <= u_sie.pkt_pid;
            pr_cls       <= u_sie.pkt_cls;
            pr_dat_len   <= u_sie.dat_len;
            pr_bad       <= u_sie.pkt_bad;
            pr_cnt       <= pr_cnt + 1;
        end
    end

    // ---- 自检状态 ----
    integer errors = 0;

    // ---- 监视: 应答队列 / 事件计数 / 排出字节 ----
    reg  [7:0] resp_q [0:63];
    integer    resp_wr  = 0;
    integer    resp_n   = 0;
    integer    resp_idx = 0;      // 已核对到的位置
    reg  [7:0] drain_rec [0:255];
    integer    drain_n  = 0;
    integer    ev_done  = 0;      // ep_rx_done 次数
    integer    ev_bad   = 0;      // ep_rx_bad 次数
    integer    ev_setup = 0;      // setup_recv 次数
    integer    ev_sof   = 0;      // sof_recv 次数
    integer    ev_abort = 0;      // rx_abort 上升沿次数
    reg        abort_d  = 1'b0;

    always @(posedge clk12m) begin
        if (resp_req) begin
            if (resp_wr < 64) resp_q[resp_wr] = resp_pid;
            resp_wr = resp_wr + 1;
            resp_n  = resp_n + 1;
        end
        if (ep_rx_done) ev_done  = ev_done  + 1;
        if (ep_rx_bad)  ev_bad   = ev_bad   + 1;
        if (setup_recv) ev_setup = ev_setup + 1;
        if (sof_recv)   ev_sof   = ev_sof   + 1;
        if (rx_abort && !abort_d) ev_abort = ev_abort + 1;
        abort_d <= rx_abort;
    end

    // ---- 应答核对 (顺序队列) ----
    task resp_chk_one;
        input [7:0] exp_pid;
        input [8*63:0] tag;
        begin
            if (resp_idx >= resp_n) begin
                $display("    FAIL: %0s 期望应答 %02x, 实际无应答", tag, exp_pid);
                errors = errors + 1;
            end else begin
                if (resp_q[resp_idx] !== exp_pid) begin
                    $display("    FAIL: %0s 应答 %02x, 期望 %02x", tag, resp_q[resp_idx], exp_pid);
                    errors = errors + 1;
                end else
                    $display("    OK  : %0s 应答 %02x", tag, resp_q[resp_idx]);
                resp_idx = resp_idx + 1;
            end
        end
    endtask

    task resp_chk_none;
        input [8*63:0] tag;
        begin
            if (resp_idx < resp_n) begin
                $display("    FAIL: %0s 不应答, 实际出了 %0d 个 (首个 %02x, @序号 %0d)",
                         tag, resp_n - resp_idx, resp_q[resp_idx], resp_idx);
                errors = errors + 1;
                resp_idx = resp_n;
            end else
                $display("    OK  : %0s 无应答", tag);
        end
    endtask

    //========================================================================
    // FSM 状态 / 迁移弧覆盖 (自建, 补覆盖率工具之缺)
    //
    // 工具的 --coverage-fsm 认不出规则 5 要求的两段式 FSM (见
    // tools/merge_fsm_cov.py 与 tx_serial_verification.md §8), 故 TB 侧直接
    // 引 u_sie.t_state_cur 自己数。本位只有 T_IDLE / T_DATA_WAIT 两态可达
    // (T_TX / T_HS_WAIT 是发包轮的编码预留), 矩阵仍按 4×4 统计。
    //========================================================================
    localparam [2:0] F_IDLE  = 3'd0;    // 与 DUT localparam 一一对应
    localparam [2:0] F_DWAIT = 3'd1;    // (TB 侧独立再写一遍, 免得 RTL 改码 TB 跟着变)
    localparam [2:0] F_TX    = 3'd2;
    localparam [2:0] F_HSW   = 3'd3;

    integer fsm_visit [0:3];
    integer fsm_arc   [0:3][0:3];
    reg [2:0] fsm_prev  = F_IDLE;
    reg       fsm_armed = 1'b0;
    integer   fi, fj;

    initial begin
        for (fi = 0; fi < 4; fi = fi + 1) begin
            fsm_visit[fi] = 0;
            for (fj = 0; fj < 4; fj = fj + 1)
                fsm_arc[fi][fj] = 0;
        end
    end

    always @(posedge clk12m or negedge ref_rstn) begin
        if (!ref_rstn) begin
            fsm_prev  <= F_IDLE;
            fsm_armed <= 1'b0;
        end else if (!fsm_armed) begin
            fsm_prev  <= dut_t_state;
            fsm_armed <= 1'b1;
        end else begin
            fsm_visit[dut_t_state] = fsm_visit[dut_t_state] + 1;
            fsm_arc[fsm_prev][dut_t_state] = fsm_arc[fsm_prev][dut_t_state] + 1;
            fsm_prev <= dut_t_state;
        end
    end

    task print_fsm_coverage;
        begin
            $display("---- FSM 状态/弧覆盖 (u_sie, %0s) ----", case_name);
            $display("  停留拍数: IDLE=%0d DWAIT=%0d TX=%0d HSW=%0d",
                     fsm_visit[F_IDLE], fsm_visit[F_DWAIT],
                     fsm_visit[F_TX], fsm_visit[F_HSW]);
            $display("  迁移矩阵 (行=from 列=to, 单位: 拍):");
            $display("            to:    IDLE  DWAIT     TX    HSW");
            for (fi = 0; fi < 4; fi = fi + 1) begin
                $write("    from %0d:  ", fi);
                for (fj = 0; fj < 4; fj = fj + 1)
                    $write("%7d ", fsm_arc[fi][fj]);
                $write("\n");
            end
        end
    endtask

    // ---- 数据阶段停留拍数核对 (周转超时口径, 见 usb_sie_design.md §2.10) ----
    integer dw_mark = 0;

    task dwait_mark;
        begin
            dw_mark = fsm_visit[F_DWAIT];
        end
    endtask

    task chk_dwait;
        input integer exp;
        input [8*47:0] tag;
        begin
            if ((fsm_visit[F_DWAIT] - dw_mark) != exp) begin
                $display("    FAIL: %0s 数据阶段停留 %0d 拍, 期望 %0d",
                         tag, fsm_visit[F_DWAIT] - dw_mark, exp);
                errors = errors + 1;
            end else
                $display("    OK  : %0s 数据阶段停留 %0d 拍", tag, exp);
            dw_mark = fsm_visit[F_DWAIT];
        end
    endtask

    // 下界核对 (打断/重新武装用: 一旦周转计时被重启, 停留拍数必然越过阈值)
    task chk_dwait_gt;
        input integer min;
        input [8*47:0] tag;
        begin
            if ((fsm_visit[F_DWAIT] - dw_mark) <= min) begin
                $display("    FAIL: %0s 数据阶段只停留 %0d 拍, 应超过 %0d (计时没被重启)",
                         tag, fsm_visit[F_DWAIT] - dw_mark, min);
                errors = errors + 1;
            end else
                $display("    OK  : %0s 数据阶段停留 %0d 拍 (> %0d, 计时被重启)",
                         tag, fsm_visit[F_DWAIT] - dw_mark, min);
            dw_mark = fsm_visit[F_DWAIT];
        end
    endtask

    // ---- 其它单值核对 ----
    task chk_len;                       // 包级探针里的净荷长度
        input integer exp;
        input [8*47:0] tag;
        begin
            if (pr_dat_len !== exp[6:0]) begin
                $display("    FAIL: %0s dat_len=%0d, 期望 %0d", tag, pr_dat_len, exp);
                errors = errors + 1;
            end else
                $display("    OK  : %0s dat_len=%0d", tag, pr_dat_len);
        end
    endtask

    task chk_toggle;                    // 每端点 data toggle {EP2,EP1,EP0} (白盒)
        input [2:0] exp;
        input [8*47:0] tag;
        begin
            if (dut_toggle !== exp) begin
                $display("    FAIL: %0s toggle=%b, 期望 %b", tag, dut_toggle, exp);
                errors = errors + 1;
            end else
                $display("    OK  : %0s toggle=%b", tag, dut_toggle);
        end
    endtask

    task chk_evt;                       // 事件脉冲计数 (传差值)
        input integer got;
        input integer exp;
        input [8*47:0] tag;
        begin
            if (got != exp) begin
                $display("    FAIL: %0s %0d 次, 期望 %0d", tag, got, exp);
                errors = errors + 1;
            end else
                $display("    OK  : %0s %0d 次", tag, got);
        end
    endtask

    task chk_rcv;
        input exp;
        input [8*47:0] tag;
        begin
            if (rcv !== exp) begin
                $display("    FAIL: %0s rcv=%b, 期望 %b (attached=%b)",
                         tag, rcv, exp, dut_attached);
                errors = errors + 1;
            end else
                $display("    OK  : %0s rcv=%b (attached=%b)", tag, rcv, dut_attached);
        end
    endtask

    // ---- 只核类别/PID/坏标志 (非 token 包不谈 addr/endp: pkt_rx 只在 token
    //      的两个数据字节下标上写 byte1/byte2, 数据包读出来是上一个 token 的残留)
    task chk_pr_nx;
        input [7:0]  ep;
        input [1:0]  ec;
        input        eb;
        input [8*47:0] tag;
        begin
            if ((pr_pid !== ep) || (pr_cls !== ec) || (pr_bad !== eb)) begin
                $display("    FAIL: %0s 字段 pid=%02x cls=%0d bad=%b",
                         tag, pr_pid, pr_cls, pr_bad);
                $display("          期望 pid=%02x cls=%0d bad=%b", ep, ec, eb);
                errors = errors + 1;
            end else
                $display("    OK  : %0s 字段 pid=%02x cls=%0d bad=%b", tag, pr_pid, pr_cls, pr_bad);
        end
    endtask

    // ---- 包级字段核对 (白盒探针 pr_*, pkt_done 拍采到的值) ----
    task chk_pr;
        input [6:0]  ea;      // tok_addr
        input [3:0]  ee;      // tok_endp
        input [7:0]  ep;      // pid
        input [1:0]  ec;      // pkt_cls
        input        eb;      // pkt_bad
        input [8*47:0] tag;
        begin
            if ((pr_tok_addr !== ea) || (pr_tok_endp !== ee) || (pr_pid !== ep) ||
                (pr_cls !== ec) || (pr_bad !== eb)) begin
                $display("    FAIL: %0s 字段 addr=%0d endp=%0d pid=%02x cls=%0d bad=%b",
                         tag, pr_tok_addr, pr_tok_endp, pr_pid, pr_cls, pr_bad);
                $display("          期望      addr=%0d endp=%0d pid=%02x cls=%0d bad=%b",
                         ea, ee, ep, ec, eb);
                errors = errors + 1;
            end else
                $display("    OK  : %0s 字段 addr=%0d endp=%0d pid=%02x cls=%0d bad=%b",
                         tag, pr_tok_addr, pr_tok_endp, pr_pid, pr_cls, pr_bad);
        end
    endtask

    // ---- include 公共激励任务 (字节级) ----
    `include "sie_tasks.vh"

    // ---- include 各 case 文件 ----
    `include "case_token.v"
    `include "case_data_len.v"
    `include "case_bad_pkt.v"
    `include "case_resp_prio.v"
    `include "case_setup.v"
    `include "case_toggle.v"
    `include "case_datawait.v"
    `include "case_oversize.v"
    `include "case_addr_stray.v"
    `include "case_buf_isolate.v"
    `include "case_ctl_rst.v"
    `include "case_tail_tight.v"

    //========================================================================
    // 主流程
    //========================================================================
    reg [8*63:0] case_name;
    reg [8*63:0] vcd_name;

    initial begin
        if (!$value$plusargs("case=%s", case_name)) begin
            $display("ERROR: +case=<name> required");
            $display("  Available cases:");
            $display("    sie_token        — token/SOF 字段解析 + CRC5 残差 + 坏 CRC");
            $display("    sie_data_len     — DATA 各类长度: 0 / 1 / 8 / 64B, 净荷与长度");
            $display("    sie_bad_pkt      — 坏 PID / 坏 CRC16 / rx_error: 不收不应答");
            $display("    sie_resp_prio    — 应答真值表优先级 (§2.8)");
            $display("    sie_setup        — SETUP 特例: 强制 ACK + toggle[EP0]→1");
            $display("    sie_toggle       — data toggle 序列: 匹配收下翻转 / 不匹配丢弃");
            $display("    sie_datawait     — T_DATA_WAIT 被新 token 打断 / 周转超时");
            $display("    sie_oversize     — 超长包 rx_abort + 坏包隔离");
            $display("    sie_addr_stray   — 地址失配 / 杂散包忽略");
            $display("    sie_buf_isolate  — 缓冲未排空: NAK 流控 + 坏包不动缓冲");
            $display("    sie_ctl_rst      — rcv 策略 / connect_evt / usb_rst 清状态");
            $display("    sie_tail_tight   — 字节背靠背 + 最短包尾间隔 (最紧时序)");
            $finish(1);
        end

`ifdef VCD_SAVE
        if ($value$plusargs("vcd=%s", vcd_name)) begin
            $dumpfile(vcd_name);
            $dumpvars(0, tb_sie);
            $display("INFO: VCD saved to %0s", vcd_name);
        end
`endif

        // ---- 初始化 ----
        clk12m = 1'b0;
        ref_rstn = 1'b1;
        errors = 0;

        // ---- 复位序列: 放开 → 真 1→0 → 再放开 (异步复位分支必须执行一次) ----
        #200;
        ref_rstn = 1'b0;
        #200;
        ref_rstn = 1'b1;
        #200;

        $display("==============================================");
        $display("  SIE Test Case: %0s", case_name);
        $display("==============================================");

        case (case_name)
            "sie_token":        case_token;
            "sie_data_len":     case_data_len;
            "sie_bad_pkt":      case_bad_pkt;
            "sie_resp_prio":    case_resp_prio;
            "sie_setup":        case_setup;
            "sie_toggle":       case_toggle;
            "sie_datawait":     case_datawait;
            "sie_oversize":     case_oversize;
            "sie_addr_stray":   case_addr_stray;
            "sie_buf_isolate":  case_buf_isolate;
            "sie_ctl_rst":      case_ctl_rst;
            "sie_tail_tight":   case_tail_tight;
            default: begin
                $display("ERROR: unknown case '%0s'", case_name);
                $finish(1);
            end
        endcase

        print_fsm_coverage;

        $display("==============================================");
        if (errors == 0) begin
            $display("  TEST PASSED: usb_sie (%0s)", case_name);
            $display("==============================================");
            $finish(0);
        end else begin
            $display("  TEST FAILED: usb_sie (%0s) — %0d errors", case_name, errors);
            $display("==============================================");
            $finish(1);
        end
    end

endmodule
