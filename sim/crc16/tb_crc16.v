//============================================================================
// tb_crc16.v — CRC-16 单元测试顶层
//
// 验证点:
//   1. 喂完 DATA 字节流后, crc_out == crc16_rem(...) (未取反余数)
//   2. 再喂 16 位发送 CRC (MSB first), 残差 == 0x800D (规范 §8.3.5.2)
//
// 参考模型: crc16_ref.vh — 在 testbench 内计算期望值
//
// Case 文件:
//   case_data.v    — 标准 Data CRC 向量
//   case_boundary.v — 边界条件
//============================================================================

`timescale 1ns/1ps

module tb_crc16;

    reg         clk    = 0;
    reg         rstn   = 0;
    reg         crc_en = 0;
    reg         crc_clr= 0;
    reg         d_in   = 0;
    wire [15:0] crc_out;

    integer errors = 0;

    usb_crc16 dut (
        .clk     (clk),
        .rstn    (rstn),
        .crc_en  (crc_en),
        .crc_clr (crc_clr),
        .d_in    (d_in),
        .crc_out (crc_out)
    );

    always #5 clk = ~clk;        // 100MHz 测试时钟 / test clock

    // ---- 参考模型 ----
    `include "crc16_ref.vh"

    // ---- 共享 task ----

    task load_seed;
        begin
            crc_clr = 1;
            @(posedge clk); #1;
            crc_clr = 0;
        end
    endtask

    task feed_bit(input val);
        begin
            d_in = val;
            crc_en = 1;
            @(posedge clk);
            #1;
            crc_en = 0;
        end
    endtask

    // 喂一个字节 (LSb first) / feed one byte, LSB first
    task feed_byte(input [7:0] bval);
        integer i;
        begin
            for (i = 0; i < 8; i = i + 1) feed_bit(bval[i]);
        end
    endtask

    // 喂发送 CRC (MSB first) / feed transmitted CRC, MSB first
    task feed_crc(input [15:0] val);
        integer i;
        begin
            for (i = 15; i >= 0; i = i - 1) feed_bit(val[i]);
        end
    endtask

    // 单个用例: 用参考模型计算期望值并校验
    task run_case(input [7:0] b0, input [7:0] b1, input [7:0] b2,
                  input [7:0] b3, input [7:0] b4, input [7:0] b5,
                  input [7:0] b6, input [7:0] b7, input [6:0] nbytes);
        integer i;
        reg [7:0] bytes [0:7];
        reg [15:0] exp_rem, exp_tx;
        begin
            bytes[0]=b0; bytes[1]=b1; bytes[2]=b2; bytes[3]=b3;
            bytes[4]=b4; bytes[5]=b5; bytes[6]=b6; bytes[7]=b7;

            exp_rem = crc16_rem(b0, b1, b2, b3, b4, b5, b6, b7, nbytes);
            exp_tx  = crc16_tx(b0, b1, b2, b3, b4, b5, b6, b7, nbytes);

            load_seed;
            for (i = 0; i < nbytes; i = i + 1) feed_byte(bytes[i]);

            if (crc_out !== exp_rem) begin
                $display("FAIL: rem=0x%04x exp_rem=0x%04x (nbytes=%0d)", crc_out, exp_rem, nbytes);
                errors = errors + 1;
            end

            feed_crc(exp_tx);
            if (crc_out !== 16'h800d) begin   // 残差 = 0x800D
                $display("FAIL: residual=0x%04x exp=0x800d (nbytes=%0d)", crc_out, nbytes);
                errors = errors + 1;
            end
        end
    endtask

    // ---- include case 文件 ----
    `include "case_data.v"
    `include "case_boundary.v"

    // ---- 测试主流程 ----
    initial begin
        rstn = 0;
        repeat (3) @(posedge clk);
        rstn = 1;
        @(posedge clk); #1;

        case_data;
        case_boundary;

        if (errors == 0) begin
            $display("TEST PASSED: usb_crc16");
            $finish(0);
        end else begin
            $display("TEST FAILED: usb_crc16 (%0d errors)", errors);
            $fatal(1, "testbench abort");
        end
    end

endmodule
