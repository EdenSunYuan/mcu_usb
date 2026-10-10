//============================================================================
// case_token.v — 标准 Token CRC5 测试
//
// 测试目的: 验证 usb_crc5 对多组 addr/endp 组合的正确性
//   用 crc5_ref.vh 参考模型实时计算期望值，无线硬编码黄金向量。
//
// 预期结果: 所有组合的余数和残差检查通过
//============================================================================

task case_token;
    begin
        $display("== case_token: standard CRC5 token vectors ==");

        // 覆盖典型值、边界值
        run_case(7'h00, 4'h0);    // 全零 addr + endp
        run_case(7'h05, 4'h1);    // CDR 常用测试地址
        run_case(7'h12, 4'h1);    // 中间值
        run_case(7'h7f, 4'hf);    // 全 1 addr + endp
        run_case(7'h01, 4'h0);    // addr=1
        run_case(7'h7f, 4'h0);    // addr 全 1, endp=0

        $display("  case_token done");
    end
endtask
