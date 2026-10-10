//============================================================================
// case_pkt_all.v — 用例 2: 全 USB 1.1 包型字节序列
//
// 判据: 回环逐字节相等; tx_ready 每字节恰一拍。
// 覆盖: 报告 §2.2 (通路次序)、§2.7 (握手)、§4.4 (CRC 字节位序: 模块不重排,
//       喂已反序摆好的 CRC 字节, 模块应原样发出)。
//
// 注: 本模块不解释字节内容 —— CRC 字节由 TB 按 §4.4 摆好位序当普通数据喂入,
//     所以这里用的是"位序已摆好"的字节值, 不是 CRC 的数值本身。
//============================================================================

task case_pkt_all;
    begin
        $display("== tx_pkt_all: 全 USB1.1 包型 ==");

        // ---- Token: PID + ADDR(7) + ENDP(4) + CRC5(5) = 3 字节 ----
        // OUT token, 地址 7, 端点 0, CRC5 摆好位序
        clr_pkt; put(`PID_OUT);   put(8'h07); put(8'h10); run_pkt("OUT",   1, 1);
        clr_pkt; put(`PID_IN);    put(8'h07); put(8'h10); run_pkt("IN",    1, 1);
        clr_pkt; put(`PID_SETUP); put(8'h00); put(8'h10); run_pkt("SETUP", 1, 1);
        // SOF: PID + 帧号(11) + CRC5(5) = 3 字节
        clr_pkt; put(`PID_SOF);   put(8'hA5); put(8'h10); run_pkt("SOF",   1, 1);

        // ---- Data: PID + payload + CRC16(2 字节) ----
        clr_pkt; put(`PID_DATA0); put(8'h12); put(8'h34); put(8'h56); put(8'h78); put(8'h9A); put(8'hBC);
                 run_pkt("DATA0", 1, 1);
        clr_pkt; put(`PID_DATA1); put(8'hDE); put(8'hF0); put(8'h11); put(8'h22); put(8'h33); put(8'h44);
                 run_pkt("DATA1", 1, 1);

        // ---- Handshake / Special (仅 PID) ----
        clr_pkt; put(`PID_ACK);   run_pkt("ACK",   1, 1);
        clr_pkt; put(`PID_NAK);   run_pkt("NAK",   1, 1);
        clr_pkt; put(`PID_STALL); run_pkt("STALL", 1, 1);
        clr_pkt; put(`PID_NYET);  run_pkt("NYET",  1, 1);
        clr_pkt; put(`PID_PRE);   run_pkt("PRE",   1, 1);

        eop_check("pkt_all");
    end
endtask
