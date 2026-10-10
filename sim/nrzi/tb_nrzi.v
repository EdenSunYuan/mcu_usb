//============================================================================
// tb_nrzi.v — NRZI 编码/解码单元测试顶层
//
// 验证点:
//   1. 编码器: 参考模型计算期望电平 → 与 nrzi_out 比对
//   2. 解码器: 参考模型计算期望数据 → 与 d_out 比对
//   3. 回环: enc → dec 恢复原数据
//
// 参考模型: nrzi_ref.vh — 在 testbench 内计算期望值
//
// Case 文件:
//   case_enc_golden.v  — 编码器 (SYNC + PID)
//   case_dec_golden.v  — 解码器
//   case_roundtrip.v   — enc→dec 回环
//============================================================================

`timescale 1ns/1ps

module tb_nrzi;

    reg clk   = 0;
    reg rstn  = 0;

    // 编码器 DUT / encoder DUT
    reg  enc_rst, enc_en, d_in_enc;
    wire nrzi_out;
    // 解码器 DUT / decoder DUT
    reg  dec_rst, dec_en, nrzi_in;
    wire d_out;
    wire dec_last_level;

    integer errors = 0;

    usb_nrzi_enc u_enc (
        .clk      (clk),
        .rstn     (rstn),
        .nrzi_rst (enc_rst),
        .nrzi_en  (enc_en),
        .d_in     (d_in_enc),
        .nrzi_out (nrzi_out)
    );

    usb_nrzi_dec u_dec (
        .clk       (clk),
        .rstn      (rstn),
        .dec_en    (dec_en),
        .dec_rst   (dec_rst),
        .nrzi_in   (nrzi_in),
        .d_out     (d_out),
        .last_level(dec_last_level)
    );

    always #5 clk = ~clk;        // 100MHz 测试时钟 / test clock

    // ---- 参考模型 ----
    `include "nrzi_ref.vh"

    // 跟踪参考模型的当前电平 (用于比对)
    reg ref_level;   // 编码器参考电平

    // ---- 编码器 task: 喂 1 位并检查期望电平 ----
    task enc_check(input val);
        reg exp;
        begin
            exp = enc_ref(ref_level, val);
            d_in_enc = val;
            enc_en   = 1;
            @(posedge clk);
            #1;
            enc_en   = 0;
            ref_level = exp;   // 更新参考电平
            if (nrzi_out !== exp) begin
                $display("FAIL(enc): d=%b level=%b exp=%b", val, nrzi_out, exp);
                errors = errors + 1;
            end
        end
    endtask

    // ---- 解码器 task: 喂 1 电平并检查期望数据 ----
    reg dec_ref_prev;  // 解码器参考上一电平
    task dec_check(input lvl);
        reg exp_data;
        begin
            exp_data = dec_ref(dec_ref_prev, lvl);
            nrzi_in = lvl;
            dec_en  = 1;
            @(posedge clk);
            #1;
            dec_en  = 0;
            dec_ref_prev = lvl;
            if (d_out !== exp_data) begin
                $display("FAIL(dec): lvl=%b data=%b exp=%b", lvl, d_out, exp_data);
                errors = errors + 1;
            end
        end
    endtask

    // ---- include case 文件 ----
    `include "case_enc_golden.v"
    `include "case_dec_golden.v"
    `include "case_roundtrip.v"

    // ---- 测试主流程 ----
    initial begin
        // 复位 / reset
        enc_rst = 0; dec_rst = 0;
        rstn = 0;
        repeat (3) @(posedge clk);
        rstn = 1;
        @(posedge clk);

        case_enc_golden;
        case_dec_golden;
        case_roundtrip;

        if (errors == 0) begin
            $display("TEST PASSED: usb_nrzi");
            $finish(0);
        end else begin
            $display("TEST FAILED: usb_nrzi (%0d errors)", errors);
            $fatal(1, "testbench abort");
        end
    end

endmodule
