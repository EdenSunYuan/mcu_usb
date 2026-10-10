//============================================================================
// case_byte_exact.v — rx_data / rx_valid 对"理想恢复结果"的全量字节校验
//
// 动机: 现有用例只查 byte0( PID ) 与 err/nbyte, 从未把整帧恢复字节流和
//   发送端理想字节流逐字节比对。本用例补上: 对每帧断言
//     (a) err=0 (合规帧);
//     (b) nbyte == 理想字节数 (rx_valid 脉冲数 == 字节数 → 无漏/无多脉冲);
//     (c) 每个字节 == 参考模型算出的理想字节 (PID / payload / CRC 全覆盖);
//   payload 故意选高 1 密度 (0xFC/0xFE/0xFF...) 以同时压解填充跨字节正确性。
//
// 参考理想字节:
//   DATA0/1: byte0 = PID 原值; byte1..n = payload 原字节 (LSB first 传输,
//     解填充后原样恢复); byte(n+1),(n+2) = CRC16 (发送 MSB first, 恢复端按
//     LSB 对齐两字节: crc_b0[k]=tx_crc[15-k], crc_b1[k]=tx_crc[7-k])。
//   OUT token: byte1 = {addr[6:0] LSB 先 + endp[0]}, byte2 = {endp[1:3] + crc5 (MSB first)}。
//============================================================================

// ---- 模块级小工具 (逐字节比对 / 帧三要素比对), 各 case 文件共用 ----
task chk_byte(input integer idx, input [7:0] expv, input [7:0] gotv);
    begin
        if (gotv !== expv) begin
            $display("    FAIL: byte%0d = %02x, expected %02x", idx, gotv, expv);
            errors = errors + 1;
        end
    end
endtask

task chk_frame(input integer idx, input integer exp_nbyte, input integer exp_err,
               input [7:0] b0, b1, b2, b3, b4, b5);
    integer idx0;
    begin
        if (last_err !== exp_err) begin
            $display("    FAIL: frame%0d err=%0d, expected %0d", idx, last_err, exp_err);
            errors = errors + 1;
        end
        if (last_nbyte !== exp_nbyte) begin
            $display("    FAIL: frame%0d nbyte=%0d (rx_valid pulses), expected %0d",
                     idx, last_nbyte, exp_nbyte);
            errors = errors + 1;
        end else begin
            $write("    frame%0d got : ", idx);
            for (idx0 = 0; idx0 < last_nbyte; idx0 = idx0 + 1)
                $write("%02x ", last_bytes[idx0]);
            $write(" exp: ");
            case (exp_nbyte)
                3:  $write("%02x %02x %02x\n", b0, b1, b2);
                6:  $write("%02x %02x %02x %02x %02x %02x\n", b0, b1, b2, b3, b4, b5);
                default: $write("(len%0d)\n", exp_nbyte);
            endcase
            chk_byte(0, b0, last_bytes[0]);
            if (exp_nbyte > 1) chk_byte(1, b1, last_bytes[1]);
            if (exp_nbyte > 2) chk_byte(2, b2, last_bytes[2]);
            if (exp_nbyte > 3) chk_byte(3, b3, last_bytes[3]);
            if (exp_nbyte > 4) chk_byte(4, b4, last_bytes[4]);
            if (exp_nbyte > 5) chk_byte(5, b5, last_bytes[5]);
        end
    end
endtask

task case_byte_exact;
    integer start_errs, frame_before;
    integer k, exp_nbyte;
    reg [7:0] p0, p1, p2, p3, p4, p5, p6, p7;
    reg [15:0] tx_crc;
    reg [7:0] exp_b1, exp_b2, exp_b4, exp_b5;
    reg [4:0] c5;
    reg [6:0] addr;
    reg [3:0] endp;

    begin
        start_errs = errors;
        $display("== deserial_byte_exact: full recovered stream vs ideal (per-byte) ==");

        //--------------------------------------------------------------------
        // 帧 0: OUT token (addr=5, endp=0) → 理想 3 字节 E1 / {addr,endp[0]} / {endp[1:3],crc5}
        //--------------------------------------------------------------------
        addr = 7'd5; endp = 4'd0; c5 = crc5_tx(addr, endp);
        for (k = 0; k < 7; k = k + 1) exp_b1[k] = addr[k];   // b0..b6 = addr LSB 先
        exp_b1[7] = endp[0];
        for (k = 0; k < 3; k = k + 1) exp_b2[k] = endp[k+1]; // b0..b2 = endp[1:3]
        for (k = 0; k < 5; k = k + 1) exp_b2[k+3] = c5[4-k]; // b3..b7 = crc5 (MSB first)
        frame_before = close_cnt;
        out_packet_task(addr, endp, 4, -1, 4);
        wait_close(frame_before + 1, 300);
        chk_frame(0, 3, 1'b0, 8'hE1, exp_b1, exp_b2, 8'h00, 8'h00, 8'h00);
        #(BIT_TIME * 6);

        //--------------------------------------------------------------------
        // 帧 1: DATA0 payload {00 01 02} (基线, 无填充) → 6 字节
        //--------------------------------------------------------------------
        p0 = 8'h00; p1 = 8'h01; p2 = 8'h02;
        tx_crc = crc16_tx(p0, p1, p2, 0, 0, 0, 0, 0, 3);
        for (k = 0; k < 8; k = k + 1) begin exp_b4[k] = tx_crc[15-k]; exp_b5[k] = tx_crc[7-k]; end
        frame_before = close_cnt;
        data0_packet_task(p0, p1, p2, 0, 0, 0, 0, 0, 3, 4, -1, 4);
        wait_close(frame_before + 1, 300);
        chk_frame(1, 6, 1'b0, 8'hC3, p0, p1, p2, exp_b4, exp_b5);
        #(BIT_TIME * 6);

        //--------------------------------------------------------------------
        // 帧 2: DATA0 payload {FC FE FF} (全高 1, 多次跨字节位填充) → 6 字节
        //--------------------------------------------------------------------
        p0 = 8'hFC; p1 = 8'hFE; p2 = 8'hFF;
        tx_crc = crc16_tx(p0, p1, p2, 0, 0, 0, 0, 0, 3);
        for (k = 0; k < 8; k = k + 1) begin exp_b4[k] = tx_crc[15-k]; exp_b5[k] = tx_crc[7-k]; end
        frame_before = close_cnt;
        data0_packet_task(p0, p1, p2, 0, 0, 0, 0, 0, 3, 4, -1, 4);
        wait_close(frame_before + 1, 300);
        chk_frame(2, 6, 1'b0, 8'hC3, p0, p1, p2, exp_b4, exp_b5);
        #(BIT_TIME * 6);

        //--------------------------------------------------------------------
        // 帧 3: DATA1 payload {FF 55 AA} (伪随机) → 6 字节
        //--------------------------------------------------------------------
        p0 = 8'hFF; p1 = 8'h55; p2 = 8'hAA;
        tx_crc = crc16_tx(p0, p1, p2, 0, 0, 0, 0, 0, 3);
        for (k = 0; k < 8; k = k + 1) begin exp_b4[k] = tx_crc[15-k]; exp_b5[k] = tx_crc[7-k]; end
        frame_before = close_cnt;
        data1_packet_task(p0, p1, p2, 0, 0, 0, 0, 0, 3, 4, -1, 4);
        wait_close(frame_before + 1, 300);
        chk_frame(3, 6, 1'b0, 8'h4B, p0, p1, p2, exp_b4, exp_b5);
        #(BIT_TIME * 6);

        //--------------------------------------------------------------------
        // 帧 4: DATA0 8B payload (1 密值 + CRC16 全跨) → 11 字节
        //--------------------------------------------------------------------
        p0 = 8'hAA; p1 = 8'hFC; p2 = 8'h55; p3 = 8'hFE; p4 = 8'h00; p5 = 8'hFF; p6 = 8'h80; p7 = 8'h3C;
        tx_crc = crc16_tx(p0, p1, p2, p3, p4, p5, p6, p7, 8);
        for (k = 0; k < 8; k = k + 1) begin exp_b4[k] = tx_crc[15-k]; exp_b5[k] = tx_crc[7-k]; end
        frame_before = close_cnt;
        data0_packet_task(p0, p1, p2, p3, p4, p5, p6, p7, 8, 4, -1, 4);
        wait_close(frame_before + 1, 300);
        exp_nbyte = 11;   // PID + 8 payload + 2 CRC
        if (last_err !== 1'b0 || last_nbyte !== exp_nbyte) begin
            $display("    FAIL: frame4 err=%0d nbyte=%0d, expected err=0 nbyte=%0d",
                     last_err, last_nbyte, exp_nbyte);
            errors = errors + 1;
        end else begin
            chk_byte(0, 8'hC3, last_bytes[0]);
            chk_byte(1, p0, last_bytes[1]); chk_byte(2, p1, last_bytes[2]);
            chk_byte(3, p2, last_bytes[3]); chk_byte(4, p3, last_bytes[4]);
            chk_byte(5, p4, last_bytes[5]); chk_byte(6, p5, last_bytes[6]);
            chk_byte(7, p6, last_bytes[7]); chk_byte(8, p7, last_bytes[8]);
            chk_byte(9, exp_b4, last_bytes[9]); chk_byte(10, exp_b5, last_bytes[10]);
        end
        #(BIT_TIME * 6);

        if (errors == start_errs) $display("  PASS: case_byte_exact (all bytes + rx_valid count match ideal)");
        else                      $display("  FAIL: case_byte_exact (%0d errors)", errors - start_errs);
    end
endtask
