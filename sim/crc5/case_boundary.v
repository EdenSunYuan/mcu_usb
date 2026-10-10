//============================================================================
// case_boundary.v — CRC5 边界条件测试
//
// 测试目的: 验证 usb_crc5 在极端输入下的行为
//   - 全零 addr+endp: 非零种子 0x1F, 应产生非零余数
//   - 全一 addr+endp: 最大 bit 翻转, 统计量最大
//
// 预期结果: 边界条件通过
//============================================================================

task case_boundary;
    begin
        $display("== case_boundary: CRC5 boundary conditions ==");

        run_case(7'h00, 4'h0);    // 全零输入, 种子 0x1F → 余数非零
        run_case(7'h7f, 4'hf);    // 全一输入, 最大翻转

        $display("  case_boundary done");
    end
endtask
