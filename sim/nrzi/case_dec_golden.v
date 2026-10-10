//============================================================================
// case_dec_golden.v — NRZI 解码器测试
//
// 测试目的: 验证 usb_nrzi_dec 对已知电平序列的解码正确性
//   参考模型实时计算期望数据，逐 bit 比对。
//
// 测试序列: 与 case_enc_golden 生成的 NRZI 电平相同
//   (编码器输出 → 解码器输入，验证解码恢复原始数据)
//
// 预期结果: 所有 16 bit 的解码输出与参考模型一致
//============================================================================

task case_dec_golden;
    begin
        $display("== case_dec_golden: decoder NRZI decoding ==");

        // 复位解码器到 idle J
        dec_rst = 1; @(posedge clk); #1; dec_rst = 0;
        dec_ref_prev = 1'b1;  // idle J (上一电平)

        // 期待电平序列: K,J,K,J,K,J,K,K (SYNC) + J,K,K,K,J,K,J,J (PID 0x2D)
        // 对应编码器输出: 0,1,0,1,0,1,0,0,1,0,0,0,1,0,1,1

        // SYNC 期望电平: KJKJKJKK → 0,1,0,1,0,1,0,0
        dec_check(1'b0);
        dec_check(1'b1);
        dec_check(1'b0);
        dec_check(1'b1);
        dec_check(1'b0);
        dec_check(1'b1);
        dec_check(1'b0);
        dec_check(1'b0);

        // PID 0x2D 编码后的期望电平: JKKKJKJJ → 1,0,0,0,1,0,1,1
        dec_check(1'b1);
        dec_check(1'b0);
        dec_check(1'b0);
        dec_check(1'b0);
        dec_check(1'b1);
        dec_check(1'b0);
        dec_check(1'b1);
        dec_check(1'b1);

        $display("  case_dec_golden done");
    end
endtask
