//============================================================================
// tb_crc5.v — CRC-5 单元测试顶层
//
// 验证点:
//   1. 喂完 ADDR+ENDP 11 位后, crc_out == crc5_rem(addr, endp) (未取反余数)
//   2. 再喂 5 位发送 CRC (MSB first), 残差 == 0x0C (规范 §8.3.5.1)
//
// 参考模型: crc5_ref.vh — 在 testbench 内计算期望值，无线硬编码黄金向量
//
// Case 文件:
//   case_token.v    — 标准 Token CRC 向量
//   case_boundary.v — 边界条件
//============================================================================

`timescale 1ns/1ps

module tb_crc5;

    reg        clk    = 0;
    reg        rstn   = 0;
    reg        crc_en = 0;
    reg        crc_clr= 0;
    reg        d_in   = 0;
    wire [4:0] crc_out;

    integer errors = 0;

    usb_crc5 dut (
        .clk     (clk),
        .rstn    (rstn),
        .crc_en  (crc_en),
        .crc_clr (crc_clr),
        .d_in    (d_in),
        .crc_out (crc_out)
    );

    always #5 clk = ~clk;        // 100MHz 测试时钟 / test clock

    // ---- 参考模型 ----
    `include "crc5_ref.vh"

    // ---- 共享 task ----

    // 复位种子到全1 / load seed (all ones)
    task load_seed;
        begin
            crc_clr = 1;
            @(posedge clk); #1;
            crc_clr = 0;
        end
    endtask

    // 喂 1 个数据位 / feed one data bit
    task feed_bit(input val);
        begin
            d_in = val;
            crc_en = 1;
            @(posedge clk);
            #1;
            crc_en = 0;
        end
    endtask

    // 喂 ADDR+ENDP (11 bit, LSb first) / feed token fields
    task feed_token(input [6:0] addr, input [3:0] endp);
        integer i;
        begin
            load_seed;
            for (i = 0; i < 7; i = i + 1) feed_bit(addr[i]);
            for (i = 0; i < 4; i = i + 1) feed_bit(endp[i]);
        end
    endtask

    // 喂发送 CRC (MSB first) / feed transmitted CRC, MSB first
    task feed_crc(input [4:0] val);
        integer i;
        begin
            for (i = 4; i >= 0; i = i - 1) feed_bit(val[i]);
        end
    endtask

    // 单个用例: 用参考模型计算期望值，校验余数 + 残差
    task run_case(input [6:0] addr, input [3:0] endp);
        reg [4:0] exp_rem, exp_tx;
        begin
            exp_rem = crc5_rem(addr, endp);
            exp_tx  = crc5_tx(addr, endp);

            feed_token(addr, endp);
            if (crc_out !== exp_rem) begin
                $display("FAIL: addr=%02x endp=%x rem=0x%02x exp_rem=0x%02x",
                         addr, endp, crc_out, exp_rem);
                errors = errors + 1;
            end
            feed_crc(exp_tx);
            if (crc_out !== 5'b01100) begin   // 残差 = 0x0C
                $display("FAIL: residual=0x%02x exp=0x0c (addr=%02x endp=%x)",
                         crc_out, addr, endp);
                errors = errors + 1;
            end
        end
    endtask

    // ---- include case 文件 ----
    `include "case_token.v"
    `include "case_boundary.v"

    // ---- 测试主流程 ----
    initial begin
        // 复位 / reset
        rstn = 0;
        repeat (3) @(posedge clk);
        rstn = 1;
        @(posedge clk); #1;

        // 运行所有 case
        case_token;
        case_boundary;

        // 汇总结果
        if (errors == 0) begin
            $display("TEST PASSED: usb_crc5");
            $finish(0);
        end else begin
            $display("TEST FAILED: usb_crc5 (%0d errors)", errors);
            $fatal(1, "testbench abort");
        end
    end

endmodule
