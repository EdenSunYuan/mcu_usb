//============================================================================
// usb_sie_cdc.v — SIE ↔ 端点 FIFO 四相闭环握手 CDC 桥
//
// 位置: SIE(clk12m 1× 域) 与 端点FIFO(pclk 域) 之间，唯一的异步时钟边界。
// 职责: 只做"数据稳定 + 握手信号 2-FF 同步"，把字节安全搬过时钟域，不丢不错。
//
// 四相闭环握手协议(READY/ACK 四沿)由两端点实现，本模块只提供:
//   - 多比特数据: 直通（发送端在握手期间保持稳定，接收端在使能沿采样）
//   - 握手 req : 2-FF 同步 (clk12m→pclk)
//   - 握手 ack : 2-FF 同步 (pclk→clk12m)
//
// RX (SIE→FIFO, push): SIE 置 rx_req=1 并保持 rx_data 稳定
//     → FIFO 见 s_rx_valid 取数、回 s_rx_ack=1
//     → SIE 见 rx_ack 撤 rx_req=0 → FIFO 撤 s_rx_ack=0 → 下一字节。
// TX (FIFO→SIE, pull): SIE 置 tx_req=1
//     → FIFO 见 s_tx_req 放 s_tx_data、回 s_tx_ack=1
//     → SIE 见 tx_ack 取走 tx_data 撤 tx_req=0 → FIFO 撤 s_tx_ack=0 → 下一字节。
//
// 参考: doc/intel_sie_whitepaper_notes.md §6 (four phase closed loop signaling)
//============================================================================

module usb_sie_cdc (
    // ---- clk12m 域 (SIE 侧) ----
    input  wire       clk12m,
    input  wire       sie_rstn,          // clk12m 域异步复位，低有效
    // RX: SIE push 字节
    input  wire [7:0] rx_data,           // SIE 解析出的字节（握手期间保持稳定）
    input  wire       rx_start,          // 包首（=PID 字节）
    input  wire       rx_last,           // 包尾
    input  wire       rx_error,          // 包错
    input  wire       rx_req,            // SIE: 字节就绪（保持到 rx_ack）
    output wire       rx_ack,            // FIFO: 已取走本字节
    // TX: SIE pull 字节
    input  wire       tx_req,            // SIE: 请求字节（保持到 tx_ack）
    output wire       tx_ack,            // FIFO: 字节就绪（随 tx_data 有效）
    output wire [7:0] tx_data,           // FIFO 提供的字节（随 tx_ack 有效）

    // ---- pclk 域 (端点 FIFO 侧) ----
    input  wire       pclk,
    input  wire       p_rstn,            // pclk 域异步复位，低有效
    // RX: FIFO 收字节
    output wire [7:0] s_rx_data,         // 同步后的字节（s_rx_valid 有效时稳定）
    output wire       s_rx_start,
    output wire       s_rx_last,
    output wire       s_rx_error,
    output wire       s_rx_valid,        // 字节有效（= rx_req 同步后，电平非脉冲）
    input  wire       s_rx_ack,          // FIFO: 已取走本字节
    // TX: FIFO 供字节
    output wire       s_tx_req,          // tx_req 同步后（电平非脉冲）
    input  wire [7:0] s_tx_data,         // FIFO 提供的字节（s_tx_ack 期间保持稳定）
    input  wire       s_tx_ack           // FIFO: 字节就绪
);

    //------------------------------------------------------------------------
    // RX req: clk12m → pclk 2-FF 同步
    //------------------------------------------------------------------------
    reg rx_req_s1, rx_req_s2;
    always @(posedge pclk or negedge p_rstn) begin
        if (!p_rstn)      {rx_req_s2, rx_req_s1} <= 2'b00;
        else              {rx_req_s2, rx_req_s1} <= {rx_req_s1, rx_req};
    end
    assign s_rx_valid = rx_req_s2;

    //------------------------------------------------------------------------
    // RX ack: pclk → clk12m 2-FF 同步
    //------------------------------------------------------------------------
    reg rx_ack_s1, rx_ack_s2;
    always @(posedge clk12m or negedge sie_rstn) begin
        if (!sie_rstn)    {rx_ack_s2, rx_ack_s1} <= 2'b00;
        else              {rx_ack_s2, rx_ack_s1} <= {rx_ack_s1, s_rx_ack};
    end
    assign rx_ack = rx_ack_s2;

    //------------------------------------------------------------------------
    // RX 数据 + 侧带: 直通（发送端在握手期间保持稳定，接收端在 s_rx_valid 沿采样）
    //------------------------------------------------------------------------
    assign s_rx_data  = rx_data;
    assign s_rx_start = rx_start;
    assign s_rx_last  = rx_last;
    assign s_rx_error = rx_error;

    //------------------------------------------------------------------------
    // TX req: clk12m → pclk 2-FF 同步
    //------------------------------------------------------------------------
    reg tx_req_s1, tx_req_s2;
    always @(posedge pclk or negedge p_rstn) begin
        if (!p_rstn)      {tx_req_s2, tx_req_s1} <= 2'b00;
        else              {tx_req_s2, tx_req_s1} <= {tx_req_s1, tx_req};
    end
    assign s_tx_req = tx_req_s2;

    //------------------------------------------------------------------------
    // TX ack: pclk → clk12m 2-FF 同步
    //------------------------------------------------------------------------
    reg tx_ack_s1, tx_ack_s2;
    always @(posedge clk12m or negedge sie_rstn) begin
        if (!sie_rstn)    {tx_ack_s2, tx_ack_s1} <= 2'b00;
        else              {tx_ack_s2, tx_ack_s1} <= {tx_ack_s1, s_tx_ack};
    end
    assign tx_ack = tx_ack_s2;

    //------------------------------------------------------------------------
    // TX 数据: 直通 pclk → clk12m（FIFO 在 s_tx_ack 期间保持稳定）
    //------------------------------------------------------------------------
    assign tx_data = s_tx_data;

endmodule
