//============================================================================
// case_back2back.v — 用例 9: 背靠背连续两包
//
// 判据: 两包各自回环相等; 包间必须回 S_IDLE (tx_en↓、线回 J)、NRZI 复位 J、
//       下一包 SOP 仍是"空闲 J → K"沿。验证两包之间没有状态残留。
// 覆盖: 报告 §2.6 (S_EOP→S_IDLE)、§4.6 (驱动使能与 SOP)。
//============================================================================

task case_back2back;
    integer f0;
    begin
        $display("== tx_back2back: 背靠背两包, 包间回空闲 ==");

        // 第 1 包
        clr_pkt; put(`PID_OUT); put(8'h07); put(8'h10);
        run_pkt("b2b_p1", 1, 1);

        // 包间: 线必须回 J
        if (rxdp !== 1'b1 || rxdn !== 1'b0) begin
            $display("    FAIL: 包间线未回 J");
            errors = errors + 1;
        end

        // 第 2 包 (不同包型)
        f0 = rx_frames;
        clr_pkt; put(`PID_DATA1); put(8'hFF); put(8'h00); put(8'h3C); put(8'h5A);
        run_pkt("b2b_p2", 1, 1);
        if (rx_frames != f0 + 1) begin
            $display("    FAIL: 第 2 包关包数不对 (%0d)", rx_frames - f0);
            errors = errors + 1;
        end

        // 连续 3 个单字节握手包背靠背
        clr_pkt; put(`PID_ACK);  run_pkt("b2b_ack",  1, 1);
        clr_pkt; put(`PID_NAK);  run_pkt("b2b_nak",  1, 1);
        clr_pkt; put(`PID_STALL);run_pkt("b2b_stall",1, 1);

        // 一个长包后面紧跟一个短包 (状态残留最容易出问题)
        clr_pkt; put(`PID_DATA0);
        put(8'hFF); put(8'hFF); put(8'hFF); put(8'hFF); put(8'hFC);
        put(8'h3C); put(8'h5A);
        run_pkt("b2b_long", 1, 1);
        clr_pkt; put(`PID_ACK);
        run_pkt("b2b_after_long", 1, 1);
        eop_check("b2b_after_long");
    end
endtask
