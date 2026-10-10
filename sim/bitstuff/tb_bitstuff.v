//============================================================================
// tb_bitstuff.v — 位填充/解填充单元测试顶层
//
// 验证点:
//   1. 填充器: 收集 DUT 输出 → 与参考模型预期序列比对
//   2. 回环: stuff → unstuff 恢复原数据
//
// 参考模型: bitstuff_ref.vh
//
// Case 文件:
//   case_stuff_golden.v  — 填充器黄金向量
//   case_roundtrip.v     — stuff→unstuff 回环
//============================================================================

`timescale 1ns/1ps

module tb_bitstuff;

    reg clk = 0;
    reg rstn = 0;

    // ---- 填充器 DUT ----
    reg  s_d_in, s_d_valid;
    wire s_d_out, s_d_out_valid;
    // ---- 解填充器 DUT ----
    wire u_d_in = s_d_out;
    wire u_d_valid = s_d_out_valid;
    wire u_d_out, u_d_out_valid;

    integer errors = 0;

    usb_bit_stuff u_stuff (
        .clk       (clk),
        .rstn      (rstn),
        .d_in      (s_d_in),
        .d_valid   (s_d_valid),
        .d_out     (s_d_out),
        .d_out_valid(s_d_out_valid)
    );

    usb_bit_unstuff u_unstuff (
        .clk       (clk),
        .rstn      (rstn),
        .d_in      (u_d_in),
        .d_valid   (u_d_valid),
        .d_out     (u_d_out),
        .d_out_valid(u_d_out_valid)
    );

    // ---- 采集寄存器 ----
    reg  [127:0] s_col;        // 填充器输出位
    reg  [127:0] u_col;        // 解填充器输出位
    integer s_n, u_n;

    always #5 clk = ~clk;        // 100MHz 测试时钟

    // ---- 参考模型 ----
    `include "bitstuff_ref.vh"

    // 复位
    task do_reset;
        begin
            rstn = 0;
            s_d_valid = 0;
            repeat (3) @(posedge clk);
            rstn = 1;
            @(posedge clk); #1;
        end
    endtask

    // ---- 喂 1 位给填充器 (采集输出，不做内联检查) ----
    task s_feed(input b);
        begin
            s_d_in = b;
            s_d_valid = 1;
            @(posedge clk);
            #1;
            if (s_d_out_valid) begin
                s_col[s_n] = s_d_out;
                s_n = s_n + 1;
            end
            if (u_d_out_valid) begin
                u_col[u_n] = u_d_out;
                u_n = u_n + 1;
            end
            s_d_valid = 0;
        end
    endtask

    // ---- 排空填充器 ----
    task s_flush;
        begin
            while (u_stuff.cnt != 0 || u_stuff.stuff_nxt) begin
                @(posedge clk);
                #1;
                if (s_d_out_valid) begin s_col[s_n] = s_d_out; s_n = s_n + 1; end
                if (u_d_out_valid) begin u_col[u_n] = u_d_out; u_n = u_n + 1; end
            end
        end
    endtask

    // ---- 回环时钟 ----
    task rt_clock(input integer n);
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) begin
                @(posedge clk);
                #1;
                if (u_d_out_valid) begin u_col[u_n] = u_d_out; u_n = u_n + 1; end
            end
        end
    endtask

    // ---- 校验填充器输出: 收集 DUT 输出并与黄金期望比对 ----
    task check_stuff(input [63:0] in_vec, input [6:0] nin,
                     input [63:0] exp_vec, input [6:0] nexp);
        integer i;
        begin
            do_reset;
            s_n = 0;
            for (i = 0; i < nin; i = i + 1)
                s_feed(in_vec[nin - 1 - i]);   // MSB=第一个发送位
            s_flush;
            if (s_n !== nexp) begin
                $display("FAIL(stuff): out=%0d bits exp=%0d", s_n, nexp);
                errors = errors + 1;
            end
            for (i = 0; i < nexp; i = i + 1) begin
                if (s_col[i] !== exp_vec[nexp - 1 - i]) begin
                    $display("FAIL(stuff): bit[%0d]=%b exp=%b", i,
                             s_col[i], exp_vec[nexp - 1 - i]);
                    errors = errors + 1;
                end
            end
        end
    endtask

    // ---- 校验回环 ----
    task check_rt(input [63:0] in_vec, input [6:0] nin);
        integer i;
        begin
            do_reset;
            s_n = 0; u_n = 0;
            for (i = 0; i < nin; i = i + 1)
                s_feed(in_vec[nin - 1 - i]);
            s_flush;
            rt_clock(4);
            if (u_n !== nin) begin
                $display("FAIL(rt): out=%0d bits exp=%0d", u_n, nin);
                errors = errors + 1;
            end
            for (i = 0; i < nin; i = i + 1) begin
                if (u_col[i] !== in_vec[nin - 1 - i]) begin
                    $display("FAIL(rt): bit[%0d]=%b exp=%b", i,
                             u_col[i], in_vec[nin - 1 - i]);
                    errors = errors + 1;
                end
            end
        end
    endtask

    // ---- include case 文件 ----
    `include "case_stuff_golden.v"
    `include "case_roundtrip.v"

    initial begin
        do_reset;

        case_stuff_golden;
        case_roundtrip;

        if (errors == 0) begin
            $display("TEST PASSED: usb_bit_stuff/usb_bit_unstuff");
            $finish(0);
        end else begin
            $display("TEST FAILED: usb_bit_stuff (%0d errors)", errors);
            $fatal(1, "testbench abort");
        end
    end

endmodule
