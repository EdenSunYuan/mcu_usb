//============================================================================
// case_enc_golden.v — NRZI 编码器测试
//
// 测试目的: 验证 usb_nrzi_enc 对已知数据序列的编码正确性
//   参考模型实时计算期望电平，逐 bit 比对。
//
// 测试序列:
//   1. SYNC (00000001) — 7 个 0 翻转 + 1 个 1 保持
//   2. PID 0x2D (LSB first: 10110100) — 混合翻转/保持
//
// 预期结果: 所有 16 bit 的编码输出与参考模型一致
//============================================================================

task case_enc_golden;
    begin
        $display("== case_enc_golden: encoder NRZI encoding ==");

        // 复位编码器到 idle J
        enc_rst = 1; @(posedge clk); #1; enc_rst = 0;
        ref_level = 1'b1;  // idle J
        if (nrzi_out !== 1'b1) begin
            $display("FAIL(enc): idle level=%b exp=1", nrzi_out);
            errors = errors + 1;
        end

        // SYNC: 00000001 (LSB first, 即 1,0,0,0,0,0,0,0 → 但 USB 规范 SYNC 是 KJKJKJKK)
        // 数据位: 0,0,0,0,0,0,0,1
        enc_check(1'b0);   // 0→翻转 K
        enc_check(1'b0);   // 0→翻转 J
        enc_check(1'b0);   // 0→翻转 K
        enc_check(1'b0);   // 0→翻转 J
        enc_check(1'b0);   // 0→翻转 K
        enc_check(1'b0);   // 0→翻转 J
        enc_check(1'b0);   // 0→翻转 K
        enc_check(1'b1);   // 1→保持 K (NRZI 结束在 K, 最后一个 data=1)

        // PID OUT=0xE1, type=0x1, LSB first: 1,0,0,0,0,1,1,1
        // 但是测试用 0x2D (LSB first: 1,0,1,1,0,1,0,0)
        enc_check(1'b1);
        enc_check(1'b0);
        enc_check(1'b1);
        enc_check(1'b1);
        enc_check(1'b0);
        enc_check(1'b1);
        enc_check(1'b0);
        enc_check(1'b0);

        $display("  case_enc_golden done");
    end
endtask
