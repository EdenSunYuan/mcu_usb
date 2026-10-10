//============================================================================
// case_stuff_dense.v — 用例 4: 高 1 密度载荷 (0xFF/0xFE/0x7F/0xFD/0xEF)
//
// 判据: 回环相等; 逐位 oracle 相等 —— 即每 6 连 1 后**恰有**一个 0,
//       且插 0 那拍 hold (数据通路不移位), 位流严格连续。
// 覆盖: 报告 §2.4 (插 0 + hold 一拍)、§4.2 (填充从 PID 起算)。
//============================================================================

task case_stuff_dense;
    begin
        $display("== tx_stuff_dense: 高 1 密度载荷 ==");

        // 全 1: 每 8 位插 1 个 0 (最密的填充)
        clr_pkt; put(`PID_DATA1); put(8'hFF); put(8'hFF); put(8'hFF); put(8'hFF);
                 put(8'hE1); put(8'h42); run_pkt("dense_FF", 1, 1);
        eop_check("dense_FF");

        // 0xFE = 1111_1110: b0=0 起头, b1~b7 七个 1 → 第 6 个 1 处插 0
        clr_pkt; put(`PID_DATA0); put(8'hFE); put(8'hFE); put(8'h3C); put(8'h5A);
                 run_pkt("dense_FE", 1, 1);

        // 0x7F = 0111_1111: b7 收尾 1 串, 跨字节延续
        clr_pkt; put(`PID_DATA1); put(8'h7F); put(8'h7F); put(8'hBC); put(8'hA5);
                 run_pkt("dense_7F", 1, 1);

        // 0xFD = 1011_1111: b0=1 起头连 1, 与前一字节尾巴叠加
        clr_pkt; put(`PID_DATA0); put(8'hFD); put(8'hEF); put(8'h18); put(8'h5A);
                 run_pkt("dense_FD", 1, 1);

        // 0xEF = 1110_1111: 中间断开的 1 串
        clr_pkt; put(`PID_DATA1); put(8'hEF); put(8'hEF); put(8'h24); put(8'h5A);
                 run_pkt("dense_EF", 1, 1);

        // 全 1 载荷长包: 填充密度最高, 累计插 0 数最大
        clr_pkt; put(`PID_DATA0);
        put(8'hFF); put(8'hFF); put(8'hFF); put(8'hFF); put(8'hFF); put(8'hFF);
        put(8'hFF); put(8'hFF); put(8'hFF); put(8'hFF); put(8'hFF); put(8'hFF);
        put(8'h3C); put(8'h5A);
        run_pkt("dense_FF_long", 1, 1);

        $display("    最后一条 (12×0xFF) 位流 %0d 位 (纯数据 8×%0d=96 位, 插 0 多于 0)",
                 rec_n, tx_n);
    end
endtask
