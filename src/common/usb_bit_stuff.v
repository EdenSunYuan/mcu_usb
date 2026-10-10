//============================================================================
// usb_bit_stuff.v — 位填充器
// Bit Stuffer (USB 1.1 spec 7.1.9)
//
// 规则: 数据流中连续6个1之后插入一个0
// Rule: insert a '0' after six consecutive '1's in the data stream
//
// 实现: 流式处理, 2深FIFO缓冲 + 直通旁路
// Implementation: streaming with 2-deep FIFO + bypass
//   - 无插入时直通 (零延迟)
//   - 插入stuffed 0时输入推迟一拍, FIFO缓冲
//============================================================================
`timescale 1ns/1ps

module usb_bit_stuff (
    input  wire       clk,        // 时钟 / clock
    input  wire       rstn,       // 异步复位 低有效 / async reset active-low
    input  wire       d_in,       // 输入数据位 / input data bit
    input  wire       d_valid,    // 输入位有效 / input bit valid
    output reg        d_out,      // 输出数据位(含stuffed bit)
    output reg        d_out_valid // 输出位有效
);

    // ---- 内部信号 ----
    // Internal signals
    reg        fifo [0:1];        // 2深位缓冲 / 2-deep bit buffer
    reg        head, tail;        // FIFO读写指针
    reg  [1:0] cnt;               // FIFO深度 (0..2) / FIFO depth
    reg  [2:0] ones_cnt;          // 已输出连续1计数(0..6) / consecutive-ones count
    reg        stuff_nxt;         // 下一拍输出stuffed 0 / stuff next slot

    wire       empty = (cnt == 2'd0);

    // ---- 输出选择 (组合逻辑) ----
    // Output mux (combinational)
    reg  d_out_c;
    reg  d_out_valid_c;
    always @* begin
        if (stuff_nxt) begin
            d_out_c       = 1'b0;
            d_out_valid_c = 1'b1;
        end else if (!empty) begin
            d_out_c       = fifo[head];
            d_out_valid_c = 1'b1;
        end else if (d_valid) begin
            d_out_c       = d_in;
            d_out_valid_c = 1'b1;
        end else begin
            d_out_c       = 1'b0;
            d_out_valid_c = 1'b0;
        end
    end

    // 控制信号 (组合)
    // Control signals (combinational)
    wire pop      = d_out_valid_c && !stuff_nxt && !empty;
    wire bypass   = empty && d_valid && !stuff_nxt;
    wire push     = d_valid && !bypass;
    wire out_one  = d_out_valid_c && d_out_c;
    wire set_stuff = out_one && (ones_cnt == 3'd5);

    // ---- 输出寄存器 ----
    // Output register
    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            d_out       <= 1'b0;
            d_out_valid <= 1'b0;
        end else begin
            d_out       <= d_out_c;
            d_out_valid <= d_out_valid_c;
        end
    end

    // ---- stuff_nxt 寄存器 ----
    // stuff_nxt register
    always @(posedge clk or negedge rstn) begin
        if (!rstn)
            stuff_nxt <= 1'b0;
        else
            stuff_nxt <= set_stuff;
    end

    // ---- 连续1计数 ----
    // Consecutive-ones counter
    always @(posedge clk or negedge rstn) begin
        if (!rstn)
            ones_cnt <= 3'd0;
        else if (stuff_nxt)
            ones_cnt <= 3'd0;
        else if (out_one)
            ones_cnt <= ones_cnt + 1'b1;
        else
            ones_cnt <= 3'd0;
    end

    // ---- FIFO head 指针 ----
    // FIFO head pointer
    always @(posedge clk or negedge rstn) begin
        if (!rstn)
            head <= 1'b0;
        else if (pop)
            head <= head + 1'b1;
    end

    // ---- FIFO tail 指针 ----
    // FIFO tail pointer
    always @(posedge clk or negedge rstn) begin
        if (!rstn)
            tail <= 1'b0;
        else if (push)
            tail <= tail + 1'b1;
    end

    // ---- FIFO 深度计数 ----
    // FIFO depth counter
    always @(posedge clk or negedge rstn) begin
        if (!rstn)
            cnt <= 2'd0;
        else if (push && !pop)
            cnt <= cnt + 1'b1;
        else if (!push && pop)
            cnt <= cnt - 1'b1;
    end

    // ---- FIFO 写入 ----
    // FIFO write (both entries)
    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            fifo[0] <= 1'b0;
            fifo[1] <= 1'b0;
        end else if (push) begin
            fifo[tail] <= d_in;
        end
    end

endmodule
