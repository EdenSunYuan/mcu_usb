//============================================================================
// case_long_loopback.v — 用例 12: 长包连续多包端到端回环 (收发填充规则一致性验收)
//
// 判据: 整段回环零错、无丢包/多包。这是"发送侧填充"与"接收侧解填充"两条
//       独立实现的一致性验收 —— 两边对"计数从 PID 起算"理解不同的话, 长包
//       必定在某个填充位处错位。
//============================================================================

task case_long_loopback;
    integer f0, k;
    begin
        $display("== tx_long_loopback: 64 字节 DATA 包连续多包 ==");

        // ---- 64 字节满包 (端点 FIFO 深度上限): DATA0 + 64B payload + CRC16 ----
        f0 = rx_frames;
        clr_pkt; put(`PID_DATA0);
        for (k = 0; k < 64; k = k + 1)
            put((k * 37 + 11) & 8'hFF);         // 伪随机载荷, 位型分散
        put(8'h3C); put(8'h5A);
        run_pkt("long_64B", 1, 1);
        eop_check("long_64B");
        if (rx_frames != f0 + 1) begin
            $display("    FAIL: 64B 包关包数 %0d", rx_frames - f0);
            errors = errors + 1;
        end

        // ---- 连续 8 个 64 字节满包 (长时段无残留) ----
        for (k = 0; k < 8; k = k + 1) begin
            clr_pkt; put(`PID_DATA1);
            begin : pl
                integer m;
                for (m = 0; m < 64; m = m + 1)
                    put((m * 53 + k * 7 + 3) & 8'hFF);
            end
            put(8'h3C); put(8'h5A);
            run_pkt("long_burst", 1, 1);
        end

        // ---- 高低 1 密度混合的长包序列 (填充边界与无填充段交替) ----
        for (k = 0; k < 4; k = k + 1) begin
            clr_pkt; put(`PID_DATA0);
            put(8'hFF); put(8'h00); put(8'hFF); put(8'h00);
            put(8'hFC); put(8'h03); put(8'hFD); put(8'h02);
            put(8'h7F); put(8'h80); put(8'hFE); put(8'h01);
            put(8'h55); put(8'hAA); put(8'hC3); put(8'h4B);
            put(8'h3C); put(8'h5A);
            run_pkt("long_mixed", 1, 1);
        end

        $display("    长包段: 累计关包 %0d 帧, 零错", rx_frames);
    end
endtask
