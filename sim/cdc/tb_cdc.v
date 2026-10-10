//============================================================================
// tb_cdc.v — usb_sie_cdc 四相闭环握手 CDC 测试台
//
// 目的:
//   1) 验证 RX (SIE→FIFO) 与 TX (FIFO→SIE) 双向字节流能无损跨域；
//   2) 验证侧带位 rx_start/rx_last/rx_error 随字节一起正确跨域；
//   3) 通过 +phase=<ps> 扫 pclk 相对 clk12m 的相位，覆盖异步 CDC 的
//      相位竞态窗口，确认无采样错误/丢字节。
//
// 结构:
//   tb_cdc 例化 dut(usb_sie_cdc)；
//   SIE 侧模型: 四相 push(RX) / pull(TX) 状态机，clk12m 域；
//   FIFO 侧模型: 四相 收(RX) / 供(TX) 状态机，pclk 域；
//   两侧用已知字节序列，收完自检，不匹配 $fatal。
//
// 运行:
//   vvp cdc.vvp +phase=20000          # 单相位
//   vvp cdc.vvp +phase=20000 +vcd     # 同时生成 cdc.vcd 供渲染波形
//============================================================================
`timescale 1ps/1ps

module tb_cdc;

    //------------------------------------------------------------------------
    // 参数
    //------------------------------------------------------------------------
    localparam N_BYTES = 32;                 // 每方向字节数

    //------------------------------------------------------------------------
    // 时钟 / 复位
    //------------------------------------------------------------------------
    reg       clk12m   = 1'b0;               // 12MHz (SIE 侧)
    reg       pclk     = 1'b0;               // 24MHz (FIFO 侧)
    reg       sie_rstn = 1'b0;
    reg       p_rstn   = 1'b0;
    integer   phase = 0;                     // pclk 相位偏移 (ps)

    //------------------------------------------------------------------------
    // DUT 接口
    //------------------------------------------------------------------------
    // RX (SIE → FIFO)
    reg  [7:0] rx_data;
    reg        rx_start, rx_last, rx_error;
    reg        rx_req;
    wire       rx_ack;
    // TX (FIFO → SIE)
    reg        tx_req;
    wire       tx_ack;
    wire [7:0] tx_data;
    // FIFO 侧
    wire [7:0] s_rx_data;
    wire       s_rx_start, s_rx_last, s_rx_error;
    wire       s_rx_valid;
    reg        s_rx_ack;
    wire       s_tx_req;
    reg  [7:0] s_tx_data;
    reg        s_tx_ack;

    //------------------------------------------------------------------------
    // 时钟生成: clk12m 12MHz (周期 83334ps), pclk 24MHz (周期 41666ps)
    //   pclk 初始相位 = +phase (ps)，用于相位扫描。
    //------------------------------------------------------------------------
    initial begin
        if (!$value$plusargs("phase=%d", phase))
            phase = 0;
    end

    always #41667 clk12m = ~clk12m;          // 半周期 41667 → 周期 83334ps

    initial begin
        #phase;
        forever #20833 pclk = ~pclk;         // 半周期 20833 → 周期 41666ps
    end

    //------------------------------------------------------------------------
    // 复位
    //------------------------------------------------------------------------
    initial begin
        repeat (3) @(posedge clk12m);
        sie_rstn = 1'b1;
        p_rstn   = 1'b1;
    end

    //------------------------------------------------------------------------
    // DUT
    //------------------------------------------------------------------------
    usb_sie_cdc dut (
        .clk12m      (clk12m),
        .sie_rstn    (sie_rstn),
        .rx_data     (rx_data),
        .rx_start    (rx_start),
        .rx_last     (rx_last),
        .rx_error    (rx_error),
        .rx_req      (rx_req),
        .rx_ack      (rx_ack),
        .tx_req      (tx_req),
        .tx_ack      (tx_ack),
        .tx_data     (tx_data),
        .pclk        (pclk),
        .p_rstn      (p_rstn),
        .s_rx_data   (s_rx_data),
        .s_rx_start  (s_rx_start),
        .s_rx_last   (s_rx_last),
        .s_rx_error  (s_rx_error),
        .s_rx_valid  (s_rx_valid),
        .s_rx_ack    (s_rx_ack),
        .s_tx_req    (s_tx_req),
        .s_tx_data   (s_tx_data),
        .s_tx_ack    (s_tx_ack)
    );

    //========================================================================
    // SIE 侧模型 — RX push (四相: req↑ → ack↑ → req↓ → ack↓)
    //========================================================================
    localparam SIE_RX_IDLE = 2'd0, SIE_RX_WAIT_ACK_HI = 2'd1, SIE_RX_WAIT_ACK_LO = 2'd2;
    reg [1:0]  sie_rx_st;
    reg [7:0]  sie_send_byte;
    integer    rx_sent;

    always @(posedge clk12m or negedge sie_rstn) begin
        if (!sie_rstn) begin
            rx_req    <= 1'b0;
            rx_data   <= 8'd0;
            rx_start  <= 1'b0;
            rx_last   <= 1'b0;
            rx_error  <= 1'b0;
            rx_sent   <= 0;
            sie_rx_st <= SIE_RX_IDLE;
        end else begin
            case (sie_rx_st)
                SIE_RX_IDLE: begin
                    if (rx_sent < N_BYTES) begin
                        rx_data   <= rx_sent[7:0];        // 字节值 = 序号
                        rx_start  <= (rx_sent == 0);
                        rx_last   <= (rx_sent == N_BYTES-1);
                        rx_error  <= 1'b0;
                        rx_req    <= 1'b1;                 // 阶段1: req↑
                        sie_rx_st <= SIE_RX_WAIT_ACK_HI;
                    end
                end
                SIE_RX_WAIT_ACK_HI: begin
                    if (rx_ack) begin                      // 阶段2: ack↑
                        rx_req    <= 1'b0;                 // 阶段3: req↓
                        sie_rx_st <= SIE_RX_WAIT_ACK_LO;
                    end
                end
                SIE_RX_WAIT_ACK_LO: begin
                    if (!rx_ack) begin                     // 阶段4: ack↓
                        rx_sent   <= rx_sent + 1;
                        sie_rx_st <= SIE_RX_IDLE;
                    end
                end
            endcase
        end
    end

    //========================================================================
    // FIFO 侧模型 — RX 收 (四相: valid↑ → ack↑ → valid↓ → ack↓)
    //========================================================================
    localparam FIFO_RX_IDLE = 1'd0, FIFO_RX_WAIT_VALID_LO = 1'd1;
    reg        fifo_rx_st;
    reg [7:0]  fifo_rx_q [0:N_BYTES-1];
    reg        fifo_rx_start_q [0:N_BYTES-1];
    reg        fifo_rx_last_q  [0:N_BYTES-1];
    integer    fifo_rx_cnt;

    always @(posedge pclk or negedge p_rstn) begin
        if (!p_rstn) begin
            s_rx_ack    <= 1'b0;
            fifo_rx_cnt <= 0;
            fifo_rx_st  <= FIFO_RX_IDLE;
        end else begin
            case (fifo_rx_st)
                FIFO_RX_IDLE: begin
                    if (s_rx_valid) begin                    // 阶段1: valid↑
                        fifo_rx_q[fifo_rx_cnt]       <= s_rx_data;
                        fifo_rx_start_q[fifo_rx_cnt] <= s_rx_start;
                        fifo_rx_last_q[fifo_rx_cnt]  <= s_rx_last;
                        s_rx_ack   <= 1'b1;                  // 阶段2: ack↑
                        fifo_rx_cnt <= fifo_rx_cnt + 1;
                        fifo_rx_st <= FIFO_RX_WAIT_VALID_LO;
                    end
                end
                FIFO_RX_WAIT_VALID_LO: begin
                    if (!s_rx_valid) begin                   // 阶段3: valid↓
                        s_rx_ack  <= 1'b0;                   // 阶段4: ack↓
                        fifo_rx_st <= FIFO_RX_IDLE;
                    end
                end
            endcase
        end
    end

    //========================================================================
    // SIE 侧模型 — TX pull (四相: req↑ → ack↑ → req↓ → ack↓)
    //========================================================================
    localparam SIE_TX_IDLE = 2'd0, SIE_TX_WAIT_ACK_HI = 2'd1, SIE_TX_WAIT_ACK_LO = 2'd2;
    reg [1:0]  sie_tx_st;
    integer    tx_got;

    always @(posedge clk12m or negedge sie_rstn) begin
        if (!sie_rstn) begin
            tx_req    <= 1'b0;
            tx_got    <= 0;
            sie_tx_st <= SIE_TX_IDLE;
        end else begin
            case (sie_tx_st)
                SIE_TX_IDLE: begin
                    if (tx_got < N_BYTES) begin
                        tx_req    <= 1'b1;                 // 阶段1: req↑
                        sie_tx_st <= SIE_TX_WAIT_ACK_HI;
                    end
                end
                SIE_TX_WAIT_ACK_HI: begin
                    if (tx_ack) begin                      // 阶段2: ack↑
                        // 校验 FIFO 给回的数据 (期望 0x80 + 序号)
                        if (tx_data != (8'h80 + tx_got[7:0]))
                            $fatal(1, "TX byte %0d mismatch: got %h exp %h",
                                   tx_got, tx_data, 8'h80 + tx_got[7:0]);
                        tx_req    <= 1'b0;                 // 阶段3: req↓
                        sie_tx_st <= SIE_TX_WAIT_ACK_LO;
                    end
                end
                SIE_TX_WAIT_ACK_LO: begin
                    if (!tx_ack) begin                     // 阶段4: ack↓
                        tx_got    <= tx_got + 1;
                        sie_tx_st <= SIE_TX_IDLE;
                    end
                end
            endcase
        end
    end

    //========================================================================
    // FIFO 侧模型 — TX 供 (四相: req_sync↑ → ack↑ → req_sync↓ → ack↓)
    //========================================================================
    localparam FIFO_TX_IDLE = 1'd0, FIFO_TX_WAIT_REQ_LO = 1'd1;
    reg        fifo_tx_st;
    integer    fifo_tx_cnt;

    always @(posedge pclk or negedge p_rstn) begin
        if (!p_rstn) begin
            s_tx_data   <= 8'd0;
            s_tx_ack    <= 1'b0;
            fifo_tx_cnt <= 0;
            fifo_tx_st  <= FIFO_TX_IDLE;
        end else begin
            case (fifo_tx_st)
                FIFO_TX_IDLE: begin
                    if (s_tx_req) begin                     // 阶段1: req_sync↑
                        s_tx_data  <= 8'h80 + fifo_tx_cnt[7:0]; // 已知字节
                        s_tx_ack   <= 1'b1;                 // 阶段2: ack↑
                        fifo_tx_cnt <= fifo_tx_cnt + 1;
                        fifo_tx_st <= FIFO_TX_WAIT_REQ_LO;
                    end
                end
                FIFO_TX_WAIT_REQ_LO: begin
                    if (!s_tx_req) begin                    // 阶段3: req_sync↓
                        s_tx_ack  <= 1'b0;                  // 阶段4: ack↓
                        fifo_tx_st <= FIFO_TX_IDLE;
                    end
                end
            endcase
        end
    end

    //========================================================================
    // 结束检测 + RX 自检
    //========================================================================
    always @(posedge clk12m) begin
        if (sie_rstn && rx_sent == N_BYTES && tx_got == N_BYTES &&
            !rx_req && !tx_req) begin
            begin
                integer i;
                integer ok;
                ok = 1;
                for (i = 0; i < N_BYTES; i = i + 1) begin
                    if (fifo_rx_q[i] != i[7:0]) begin
                        $display("RX byte %0d mismatch: got %h exp %h",
                                 i, fifo_rx_q[i], i[7:0]);
                        ok = 0;
                    end
                    if (fifo_rx_start_q[i] != (i == 0)) begin
                        $display("RX byte %0d start flag mismatch (exp %0d)",
                                 i, (i == 0));
                        ok = 0;
                    end
                    if (fifo_rx_last_q[i] != (i == N_BYTES-1)) begin
                        $display("RX byte %0d last flag mismatch (exp %0d)",
                                 i, (i == N_BYTES-1));
                        ok = 0;
                    end
                end
                if (ok) begin
                    $display("PASS: phase=%0d  RX %0d bytes + TX %0d bytes OK",
                             phase, N_BYTES, N_BYTES);
                    $finish(0);
                end else begin
                    $fatal(1, "FAIL at phase=%0d", phase);
                end
            end
        end
    end

    //------------------------------------------------------------------------
    // 看门狗: 超时判失败 (每个字节 ~8 拍 clk12m + 裕量)
    //------------------------------------------------------------------------
    initial begin
        #(N_BYTES * 16 * 83334 + 2000000);
        $display("TIMEOUT at phase=%0d", phase);
        $fatal(1, "timeout");
    end

    //------------------------------------------------------------------------
    // VCD 波形 (仅 +vcd 时)
    //------------------------------------------------------------------------
    initial begin
        if ($test$plusargs("vcd")) begin
            $dumpfile("cdc.vcd");
            $dumpvars(0, tb_cdc);
        end
    end

endmodule
