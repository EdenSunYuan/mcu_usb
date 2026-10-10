//============================================================================
// case_roundtrip.v — 位填充 → 解填充回环测试
//
// 测试目的: 验证 stuff→unstuff 串联能正确恢复原始数据
//   输入序列 → stuffer → unstuffer → 输出应与输入一致。
//
// 测试模式: 与 case_stuff_golden 相同的 5 组输入
//
// 预期结果: 所有回环的恢复数据与输入一致
//============================================================================

task case_roundtrip;
    begin
        $display("== case_roundtrip: stuff->unstuff round-trip ==");

        check_rt( 7'b1111110,       7);
        check_rt( 7'b1111111,       7);
        check_rt(12'b001111111100,  12);
        check_rt(13'b1011011111101, 13);
        check_rt(14'b11111101111110, 14);

        $display("  case_roundtrip done");
    end
endtask
