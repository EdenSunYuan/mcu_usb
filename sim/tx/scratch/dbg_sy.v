//============================================================================
// dbg_sy.v — 审查 usb_tx_serial_sy.v 用的临时 TB (用完即弃)
//
// 用法: iverilog -g2012 -Wall -o dbg_sy.vvp dbg_sy.v <repo>/src/phy/usb_tx_serial_sy.v
//       vvp dbg_sy.vvp
// 做法: 逐拍打印内部状态 + 把线上电平重新 NRZI 解码回数据位 (解码器独立于 DUT)。
// TB 侧扮演 SIE 的方式**与真 TB 完全一致**: tx_data 组合译出, drv_idx 见到
// tx_ready 才前进 —— 这样 tx_ready 的语义错误会直接表现成"字节不前进"。
//============================================================================

`timescale 1ns/1ps

module dbg_sy;

    reg        clk_12m = 1'b0;
    reg        ref_rstn = 1'b0;
    reg        tx_active;
    wire [7:0] tx_data;
    wire       tx_last;
    wire       tx_en, tx_bit, tx_se0, tx_ready, tx_done;

    always #41.6665 clk_12m = ~clk_12m;

    usb_tx_serial u_tx (
        .clk_12m   (clk_12m),
        .ref_rstn  (ref_rstn),
        .tx_active (tx_active),
        .tx_data   (tx_data),
        .tx_last   (tx_last),
        .tx_en     (tx_en),
        .tx_bit    (tx_bit),
        .tx_se0    (tx_se0),
        .tx_ready  (tx_ready),
        .tx_done   (tx_done)
    );

    integer   n_byte = 0;
    reg [7:0] bytes [0:7];
    integer   idx = 0;

    assign tx_data = (idx < n_byte) ? bytes[idx] : 8'h00;
    assign tx_last = (idx == (n_byte - 1)) && (n_byte > 0);

    always @(posedge clk_12m or negedge ref_rstn) begin
        if (!ref_rstn)       idx <= 0;
        else if (!tx_active) idx <= 0;
        else if (tx_ready)   idx <= (idx < n_byte - 1) ? idx + 1 : idx;
        else                 idx <= idx;
    end

    reg drv_req = 1'b0;
    reg drv_busy = 1'b0;
    always @(posedge clk_12m or negedge ref_rstn) begin
        if (!ref_rstn)     begin tx_active <= 1'b0; drv_busy <= 1'b0; end
        else if (!drv_req) begin tx_active <= 1'b0; drv_busy <= 1'b0; end
        else if (drv_busy) begin tx_active <= 1'b0; drv_busy <= 1'b1; end
        else if (tx_done)  begin tx_active <= 1'b0; drv_busy <= 1'b1; end
        else               begin tx_active <= 1'b1; drv_busy <= 1'b0; end
    end

    // ---- 线上位流 NRZI 解码 ----
    integer   rec_n = 0;
    reg       rec_bits [0:511];
    reg       rec_started = 1'b0;
    reg       rec_prev = 1'b1;
    reg       done_seen = 1'b0;

    integer   cyc = 0;
    integer   ready_n = 0;          // 本包 tx_ready 脉冲数
    integer   se0_n = 0;            // 本包 tx_se0 高电平拍数

    always @(posedge clk_12m) begin
        cyc = cyc + 1;
        $write("  %4d | cur=%0d cnt=%0d one=%0d stf=%b shf=%02x | en=%b bit=%b se0=%b rdy=%b done=%b\n",
               cyc, u_tx.tx_stat_cur, u_tx.bit_cnt, u_tx.bit_ones_cnt, u_tx.bit_stuff,
               u_tx.data_shift, tx_en, tx_bit, tx_se0, tx_ready, tx_done);

        if (tx_en) begin
            if (tx_ready) ready_n = ready_n + 1;
            if (tx_se0)   se0_n   = se0_n + 1;
            if (!rec_started) begin
                if (!tx_se0 && !tx_bit) begin
                    rec_started = 1'b1; rec_prev = tx_bit;
                    rec_bits[rec_n] = 1'b0; rec_n = rec_n + 1;
                end
            end else if (!done_seen) begin
                if (tx_done) done_seen = 1'b1;
                else if (!tx_se0) begin
                    rec_bits[rec_n] = (tx_bit == rec_prev) ? 1'b1 : 1'b0;
                    rec_n = rec_n + 1; rec_prev = tx_bit;
                end
            end
        end
    end

    task send_pkt(input integer tag_id);
        integer k;
        begin
            @(posedge clk_12m);
            drv_req = 1'b1;
            wait (drv_busy == 1'b1);
            repeat (2) @(posedge clk_12m);
            drv_req = 1'b0;
            repeat (4) @(posedge clk_12m);
            $display("  ---- 包%0d: 发 %0d 字节, tx_ready 脉冲 %0d 个, tx_se0 拍数 %0d ----",
                     tag_id, n_byte, ready_n, se0_n);
            $write("       解码位流 rec[%0d] = ", rec_n);
            for (k = 0; k < rec_n; k = k + 1) $write("%b", rec_bits[k]);
            $write("\n");
            rec_n = 0; rec_started = 1'b0; rec_prev = 1'b1; done_seen = 1'b0;
            ready_n = 0; se0_n = 0;
        end
    endtask

    initial begin
        ref_rstn = 1'b0;
        repeat (4) @(posedge clk_12m);
        ref_rstn = 1'b1;
        repeat (4) @(posedge clk_12m);

        $display("");
        $display("==== A: 单字节 0xC3 ====");
        bytes[0] = 8'hC3; n_byte = 1;
        send_pkt(1);

        $display("");
        $display("==== B: 单字节 0x70 ====");
        bytes[0] = 8'h70; n_byte = 1;
        send_pkt(2);

        $display("");
        $display("==== C: 单字节 0xDD (探连 1 计数器是否在 0 位上复位) ====");
        bytes[0] = 8'hDD; n_byte = 1;
        send_pkt(3);

        $display("");
        $display("==== D: 单字节 0xFF (6 连 1 必须插 0 + hold) ====");
        bytes[0] = 8'hFF; n_byte = 1;
        send_pkt(4);

        $display("");
        $display("==== E: 单字节 0x00 ====");
        bytes[0] = 8'h00; n_byte = 1;
        send_pkt(5);

        $display("");
        $display("==== F: 双字节 0xC3 + 0x00 (多字节握手) ====");
        bytes[0] = 8'hC3; bytes[1] = 8'h00; n_byte = 2;
        send_pkt(6);

        $display("");
        $display("黄金值: 0xC3 LSb-first = 11000011 ; 0x70 = 00001110");
        $display("黄金值: 0xDD = 10111011 (最长 3 连 1 -> 不该插 0) ; 0xFF = 11111111");
        $display("黄金值: SYNC = 00000001 ; 单字节包 = 8 + 8 = 16 位");
        $finish;
    end

endmodule
