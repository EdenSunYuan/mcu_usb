//============================================================================
// dbg_tail.v — 追"末字节收尾填充 0 丢失"用的临时 TB (用完即弃)
//
// 现象(项目 TB): FAIL: 末字节 0xFC 位流 24 位, 应 25 (8+8+8+收尾填充0)
// 做法: 发 PID + 0xFC, 逐拍打印 FSM/移位/连 1 计数, 并独立 NRZI 解码线上位流,
//       看那个收尾填充 0 到底有没有上线。
//============================================================================

`timescale 1ns/1ps

module dbg_e1;

    reg        clk12s = 1'b0;
    reg        ref_rstn = 1'b0;
    reg        tx_active;
    wire [7:0] tx_data;
    wire       tx_last;
    wire       tx_en, tx_bit, tx_se0, tx_ready, tx_done;

    always #5 clk12s = ~clk12s;

    usb_tx_serial u_tx (
        .clk_12m (clk12s), .ref_rstn(ref_rstn), .tx_active(tx_active),
        .tx_data (tx_data), .tx_last(tx_last),
        .tx_en (tx_en), .tx_bit(tx_bit), .tx_se0(tx_se0),
        .tx_ready(tx_ready), .tx_done(tx_done)
    );

    reg       drv_req = 1'b0;
    reg       drv_busy = 1'b0;
    integer   drv_idx = 0;
    integer   n_byte = 2;
    reg [7:0] bytes [0:7];

    assign tx_data = (drv_idx < n_byte) ? bytes[drv_idx] : 8'h00;
    assign tx_last = (drv_idx == (n_byte - 1)) && (n_byte > 0);

    always @(posedge clk12s or negedge ref_rstn) begin
        if (!ref_rstn)     begin tx_active <= 1'b0; drv_busy <= 1'b0; end
        else if (!drv_req) begin tx_active <= 1'b0; drv_busy <= 1'b0; end
        else if (drv_busy) begin tx_active <= 1'b0; drv_busy <= 1'b1; end
        else if (tx_done)  begin tx_active <= 1'b0; drv_busy <= 1'b1; end
        else               begin tx_active <= 1'b1; drv_busy <= 1'b0; end
    end

    always @(posedge clk12s or negedge ref_rstn) begin
        if (!ref_rstn)       drv_idx <= 0;
        else if (!tx_active) drv_idx <= 0;
        else if (tx_ready)   drv_idx <= (drv_idx < n_byte - 1) ? drv_idx + 1 : drv_idx;
        else                 drv_idx <= drv_idx;
    end

    integer cyc = 0;
    integer wn = 0;
    reg     wb [0:255];
    reg     prev = 1'b1;
    reg     in_pkt = 1'b0;

    always @(posedge clk12s) begin
        cyc = cyc + 1;
        $write("  %3d | cur=%0d cnt=%0d one=%0d stf=%b shf=%02x rdy=%b done=%b en=%b bit=%b se0=%b\n",
               cyc, u_tx.tx_stat_cur, u_tx.bit_cnt, u_tx.bit_ones_cnt, u_tx.bit_stuff,
               u_tx.data_shift, tx_ready, tx_done, tx_en, tx_bit, tx_se0);
        if ((tx_en === 1'b1) && (tx_se0 === 1'b0)) begin
            if (!in_pkt) begin in_pkt = 1'b1; prev = 1'b1; end
            if (wn < 256) begin
                wb[wn] = (tx_bit === prev) ? 1'b1 : 1'b0;
                wn = wn + 1;
            end
            prev = tx_bit;
        end else begin
            in_pkt = 1'b0;
            prev = 1'b1;
        end
    end

    integer k;
    initial begin
        ref_rstn = 1'b0;
        repeat (4) @(posedge clk12s);
        ref_rstn = 1'b1;
        repeat (4) @(posedge clk12s);

        // PID_DATA0 = 0xC3, 末字节 0xFC (b7 正好凑满第 6 个连 1)
        bytes[0] = 8'hE1; bytes[1] = 8'h07; bytes[2] = 8'h10; n_byte = 3;
        @(posedge clk12s);
        drv_req = 1'b1;
        wait (drv_busy == 1'b1);
        repeat (4) @(posedge clk12s);
        drv_req = 1'b0;
        repeat (4) @(posedge clk12s);

        $display("");
        $write("  线上位流 (%0d 位) = ", wn);
        for (k = 0; k < wn; k = k + 1) begin
            if ((k > 0) && ((k % 8) == 0)) $write(" ");
            $write("%b", wb[k]);
        end
        $write("\n  期望 = 00000001 11000011 00111111 0   (8+8+8+收尾填充0 = 25 位)\n");
        $finish;
    end

endmodule
