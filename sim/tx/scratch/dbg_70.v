//============================================================================
// dbg_70.v — 临时诊断: 逐拍打印 usb_tx_serial 内部, 专看数据字节 8'h70
//
// 用法: iverilog -g2012 -o dbg_70.vvp dbg_70.v ../../src/phy/usb_tx_serial.v && vvp dbg_70.vvp
// 目的: 把"线上位序"独立解回来 (NRZI 解码), 与 LSb-first 手算黄金值对照。
// ★ 用完即弃, 不属于回归用例。
//============================================================================

`timescale 1ns/1ps

module dbg_70;

    reg        clk12m = 1'b0;
    reg        ref_rstn = 1'b0;
    reg        tx_active;
    wire [7:0] tx_data;
    wire       tx_last;
    wire       tx_ready, tx_done, tx_bit, tx_se0, tx_en;

    // 12MHz 位时钟 = 83.333ns 周期
    always #41.6665 clk12m = ~clk12m;

    usb_tx_serial u_tx (
        .clk12m    (clk12m),
        .ref_rstn  (ref_rstn),
        .tx_active (tx_active),
        .tx_data   (tx_data),
        .tx_last   (tx_last),
        .tx_ready  (tx_ready),
        .tx_done   (tx_done),
        .tx_bit    (tx_bit),
        .tx_se0    (tx_se0),
        .tx_en     (tx_en)
    );

    // ---- 待发字节队列 (TB 扮演 SIE) ----
    integer   n_byte = 0;
    reg [7:0] bytes [0:7];
    integer   idx = 0;

    // 与真 TB 同构: tx_data/tx_last 组合译出, 避免边沿竞争
    assign tx_data = (idx < n_byte) ? bytes[idx] : 8'h00;
    assign tx_last = (idx == (n_byte - 1)) && (n_byte > 0);

    always @(posedge clk12m or negedge ref_rstn) begin
        if (!ref_rstn)               idx <= 0;
        else if (!tx_active)         idx <= 0;
        else if (tx_ready)           idx <= (idx < n_byte - 1) ? idx + 1 : idx;
        else                         idx <= idx;
    end

    // ---- tx_active: 请求 + tx_done 产生 (与真 TB 同构) ----
    reg drv_req = 1'b0;
    reg drv_busy = 1'b0;
    always @(posedge clk12m or negedge ref_rstn) begin
        if (!ref_rstn)        begin tx_active <= 1'b0; drv_busy <= 1'b0; end
        else if (!drv_req)    begin tx_active <= 1'b0; drv_busy <= 1'b0; end
        else if (drv_busy)    begin tx_active <= 1'b0; drv_busy <= 1'b1; end
        else if (tx_done)     begin tx_active <= 1'b0; drv_busy <= 1'b1; end
        else                  begin tx_active <= 1'b1; drv_busy <= 1'b0; end
    end

    // ---- 线上位流解码 (NRZI): 电平不变=1, 翻转=0; EOP/高阻跳过 ----
    integer   rec_n = 0;
    reg       rec_bits [0:511];
    reg       rec_started = 1'b0;
    reg       rec_prev = 1'b1;
    reg       done_seen = 1'b0;

    integer   cyc = 0;

    task show;
        begin
            $write("  %4d | st=%0d shreg=%02x bcnt=%0d sent=%b ones=%0d stuf=%b last=%b eopc=%0d | "
                   , cyc, u_tx.st_state, u_tx.shift_reg, u_tx.bit_cnt, u_tx.byte_sent,
                   u_tx.ones_cnt, u_tx.stuff_pend, u_tx.last_q, u_tx.eop_cnt);
            $write("en=%b bit=%b se0=%b rdy=%b done=%b\n",
                   tx_en, tx_bit, tx_se0, tx_ready, tx_done);
        end
    endtask

    always @(posedge clk12m) begin
        cyc = cyc + 1;
        if (cyc > 2) show;

        // 解码 (仅 tx_en 且非 EOP 的拍才是数据)
        if (tx_en) begin
            if (!rec_started) begin
                if (!tx_se0 && !tx_bit) begin
                    rec_started = 1'b1;
                    rec_prev    = tx_bit;
                    rec_bits[rec_n] = 1'b0; rec_n = rec_n + 1;
                end
            end else if (!done_seen) begin
                if (tx_done) done_seen = 1'b1;
                else if (!tx_se0) begin
                    rec_bits[rec_n] = (tx_bit == rec_prev) ? 1'b1 : 1'b0;
                    rec_n = rec_n + 1;
                    rec_prev = tx_bit;
                end
            end
        end
    end

    task send_pkt(input integer tag_id);
        integer k;
        begin
            @(posedge clk12m);
            drv_req = 1'b1;
            wait (drv_busy == 1'b1);
            repeat (2) @(posedge clk12m);
            drv_req = 1'b0;
            repeat (3) @(posedge clk12m);
            $display("  ---- 包%0d 解码位流 (含 SYNC) ----", tag_id);
            $write("       rec[%0d] = ", rec_n);
            for (k = 0; k < rec_n; k = k + 1) $write("%b", rec_bits[k]);
            $write("\n");
            rec_n = 0; rec_started = 1'b0; rec_prev = 1'b1; done_seen = 1'b0;
        end
    endtask

    initial begin
        $display("");
        $display("==== A: PID 8'hC3 (DATA0) + 载荷 8'h70 ====");
        bytes[0] = 8'hC3; bytes[1] = 8'h70; n_byte = 2;
        repeat (4) @(posedge clk12m);
        ref_rstn = 1'b1;
        repeat (4) @(posedge clk12m);
        send_pkt(1);

        $display("");
        $display("==== B: 单字节 8'h70 单独发 (tx_n=1) ====");
        bytes[0] = 8'h70; n_byte = 1;
        repeat (4) @(posedge clk12m);
        send_pkt(2);

        $display("");
        $display("==== C: tx_pkt_all 首包 OUT (PID 0xE1 + 0x07 + 0x10) ====");
        bytes[0] = 8'hE1; bytes[1] = 8'h07; bytes[2] = 8'h10; n_byte = 3;
        repeat (4) @(posedge clk12m);
        send_pkt(3);

        $display("");
        $display(" 黄金值 0x70 LSb-first = bit0..bit7 = 0 0 0 0 1 1 1 0");
        $display(" 黄金值 SYNC(0x80)    = 0 0 0 0 0 0 0 1");
        $finish;
    end

endmodule
