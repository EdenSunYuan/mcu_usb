//============================================================================
// case_boundary.v — CRC16 边界条件测试
//
// 测试目的: 验证 usb_crc16 在极端输入下的行为
//   - 空 payload (仅种子, nbytes=0 不适用，最小 1 byte)
//   - 全 0 payload (5 byte)
//   - 全 0xFF payload (8 byte, 最大 bit 翻转)
//
// 预期结果: 边界条件通过
//============================================================================

task case_boundary;
    begin
        $display("== case_boundary: CRC16 boundary conditions ==");

        // 1-byte 全零: 最小数据量
        run_case(8'h00,8'h00,8'h00,8'h00,8'h00, 8'h00,8'h00,8'h00, 1);

        // 8-byte 全 0xFF: 每位都翻转，统计最大
        run_case(8'hFF,8'hFF,8'hFF,8'hFF,8'hFF, 8'hFF,8'hFF,8'hFF, 8);

        $display("  case_boundary done");
    end
endtask
