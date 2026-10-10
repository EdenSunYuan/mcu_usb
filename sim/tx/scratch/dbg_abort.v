//============================================================================
// dbg_abort.v — 追 tx_abort 唯一残留错误用的临时 TB (用完即弃)
//
// 现象: 项目 TB 报 FAIL[after_abort2]: 回环收到 2 字节, 应 1
//       —— 复现 case_abort 的 "[SYNC 段中止] → 紧接一个单字节包" 序列,
//          把线上位流逐位记下来, 看中止残留到底在 DP/DN 上留下了什么。
//
// 做法: 与 tb_tx_serial.v 完全一样的 SIE 驱动 (tx_active 见 tx_done 才撤,
//       idx 见 tx_ready 才前进), 只加一个独立 NRZI 解码记录器。
//============================================================================

`timescale 1ns/1ps

module dbg_abort;

    reg        clk12s = 1'b0;
    reg        ref_rstn = 1'b0;
    reg        tx_active;
    wire [7:0] tx_data;
    wire       tx_last;
    wire       tx_en, tx_bit, tx_se0, tx_ready, tx_done;
    wire       rxdp, rxdn;

    always #5 clk12s = ~clk12s;             // 12MHz

    usb_tx_serial u_tx (
        .clk_12m (clk12s), .ref_rstn(ref_rstn), .tx_active(tx_active),
        .tx_data (tx_data), .tx_last(tx_last),
        .tx_en (tx_en), .tx_bit(tx_bit), .tx_se0(tx_se0),
        .tx_ready(tx_ready), .tx_done(tx_done)
    );

    phy_model u_phy (
        .tx_bit(tx_bit), .tx_se0(tx_se0), .tx_en(tx_en),
        .rxdp(rxdp), .rxdn(rxdn)
    );

    // ---- SIE 侧驱动 (与 tb_tx_serial.v 逐行同构) ----
    reg       drv_req = 1'b0;
    reg       drv_busy = 1'b0;
    integer   drv_idx = 0;
    integer   n_byte = 0;
    reg [7:0] bytes [0:7];

    assign tx_data = (drv_idx < n_byte) ? bytes[drv_idx] : 8'h00;
    assign tx_last = (drv_idx == (n_byte - 1)) && (n_byte > 0);

    always @(posedge clk12s or negedge ref_rstn) begin
        if (!ref_rstn)        begin tx_active <= 1'b0; drv_busy <= 1'b0; end
        else if (!drv_req)    begin tx_active <= 1'b0; drv_busy <= 1'b0; end
        else if (drv_busy)    begin tx_active <= 1'b0; drv_busy <= 1'b1; end
        else if (tx_done)     begin tx_active <= 1'b0; drv_busy <= 1'b1; end
        else                  begin tx_active <= 1'b1; drv_busy <= 1'b0; end
    end

    always @(posedge clk12s or negedge ref_rstn) begin
        if (!ref_rstn)       drv_idx <= 0;
        else if (!tx_active) drv_idx <= 0;
        else if (tx_ready)   drv_idx <= (drv_idx < n_byte - 1) ? drv_idx + 1 : drv_idx;
        else                 drv_idx <= drv_idx;
    end

    // ---- 线上位流记录 (独立 NRZI 解码, 不看 DUT 内部) ----
    integer   cyc = 0;
    integer   wn  = 0;
    reg       wbits [0:8191];       // 解码出的数据位
    integer   wt   [0:8191];        // 每位对应的拍号
    integer   weop [0:8191];        // 该位之后是否紧跟 EOP 边界
    reg       prev = 1'b1;
    reg       in_pkt = 1'b0;
    integer   eop_cnt = 0;

    // 只在 tx_en=1 且非 SE0 时算"线上有数据位"; tx_en=0 是上拉空闲 J (不算位)
    always @(posedge clk12s) begin
        cyc = cyc + 1;
        if ((tx_en === 1'b1) && (tx_se0 === 1'b0)) begin
            if (!in_pkt) begin
                in_pkt = 1'b1;
                prev   = 1'b1;              // 空闲 J 当基准
            end
            if (wn < 8192) begin
                wbits[wn] = (rxdp === prev) ? 1'b1 : 1'b0;
                wt[wn]    = cyc;
                wn        = wn + 1;
            end
            prev = rxdp;
        end else begin
            in_pkt = 1'b0;
            prev   = 1'b1;                  // 交高阻 → 空闲 J 重新当基准
        end
    end

    // 打印从第 from 位起的位流
    task dump_from(input integer from, input [255:0] tag);
        integer k;
        begin
            $display("  [%0s] 从位 %0d 起的线位流 (共记录 %0d 位):", tag, from, wn);
            $write("    ");
            for (k = from; k < wn; k = k + 1) begin
                if ((k > from) && (((k - from) % 8) == 0)) $write(" ");
                $write("%b", wbits[k]);
            end
            $write("\n    拍号: ");
            for (k = from; k < wn; k = k + 1) begin
                if ((k > from) && (((k - from) % 8) == 0)) $write(" ");
                $write("%0d ", wt[k] % 1000);
            end
            $write("\n");
        end
    endtask

    integer mark_abort;

    initial begin
        ref_rstn = 1'b0;
        repeat (4) @(posedge clk12s);
        ref_rstn = 1'b1;
        repeat (4) @(posedge clk12s);

        // ---- 段1: SYNC 段中止 (与 case_abort 第 3 段一致) ----
        n_byte = 1; bytes[0] = 8'h4B;      // PID_NAK
        @(posedge clk12s);
        drv_req = 1'b1;
        repeat (3) @(posedge clk12s);
        drv_req = 1'b0;
        mark_abort = cyc;
        $display("== 中止时刻 cyc=%0d (撤 drv_req)", mark_abort);
        repeat (10) @(posedge clk12s);
        $display("  中止后 10 拍: tx_en=%b tx_bit=%b tx_se0=%b dp=%b dn=%b (tx_active=%b)",
                 tx_en, tx_bit, tx_se0, rxdp, rxdn, tx_active);

        // 打印中止前后各若干位的线
        dump_from(0, "中止段");

        // ---- 段2: 紧接一个干净的单字节包 (after_abort2) ----
        wn = 0;
        n_byte = 1; bytes[0] = 8'h4B;      // PID_NAK
        @(posedge clk12s);
        drv_req = 1'b1;
        wait (drv_busy == 1'b1);
        repeat (2) @(posedge clk12s);
        drv_req = 1'b0;
        repeat (6) @(posedge clk12s);
        dump_from(0, "after_abort2 单字节包");
        $display("  期望: 00000001 11010010 (SYNC + 0x4B LSb 先) = 16 位");
        $finish;
    end

endmodule
