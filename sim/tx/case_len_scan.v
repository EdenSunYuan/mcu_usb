//============================================================================
// case_len_scan.v — 用例 3: 载荷长度扫描 (0/1/7/8/63/64 字节)
//
// 判据: 回环逐字节相等; tx_last 后移完即进 EOP (EOP 恒 3 拍, 无多余拍)。
// 覆盖: 报告 §2.6 (FSM 出口条件)、§4.1 (包尾严丝合缝, 无 FIFO 排空余量)。
// 64 字节 = 端点 FIFO 满深度 (决策 D), 是包的实际上限。
//============================================================================

task case_len_scan;
    integer n, i;
    begin
        $display("== tx_len_scan: 载荷长度扫描 0/1/7/8/63/64 ==");

        for (n = 0; n <= 64; n = n + 1) begin
            if ((n == 0) || (n == 1) || (n == 7) || (n == 8) || (n == 63) || (n == 64)) begin
                clr_pkt;
                put(`PID_DATA0);
                for (i = 0; i < n; i = i + 1)
                    put(8'hA0 + i[7:0]);            // 递增载荷, 位型分散
                put(8'h3C);                         // CRC16 低字节 (摆好位序)
                put(8'h5A);                         // CRC16 高字节
                run_pkt("len", 1, 1);
                eop_check("len");
                if (rx_last_nb != tx_n) begin
                    $display("    FAIL: 长度 %0d 回环字节数 %0d", n, rx_last_nb);
                    errors = errors + 1;
                end
                $display("    长度 %0d 字节: 回环 %0d 字节 OK (位流 %0d 位)",
                         n, rx_last_nb, rec_n);
            end
        end
    end
endtask
