//============================================================================
// case_pkt_all.v — 全部 USB 1.1 包类型的整帧字节校验 (deserial 层)
//
// deserial 的职责边界: 只做"字节恢复 + 包定界 + 物理检错(7连1/EOP错)",
// 不判 PID 语义 / 不校验 CRC (那是 SIE 事务层)。所以对每类包断言:
//   (a) err=0 — 合法字节流 + 正常 EOP 不会误报(位填充/SE0 门控都正确);
//   (b) 恢复字节 == 理想字节 — PID + 字段按 LSB-first 连续逻辑位流每 8 位重分组;
//   (c) 对 PID 校验错 / CRC5 / CRC16 错的"坏包", deserial 保持透明: 同样 err=0、
//       字节原样恢复 (坏包留给 SIE 层按 PID/CRC 判), 证明反序列化不做越层检查。
//
// 帧清单 (已由 byte_exact/out_normal 覆盖的 OUT/DATA0/DATA1 不重复):
//   Token IN    : 3B = 69 | {addr,endp0} | {endp[1:3],crc5}
//   Token SETUP : 3B = 2D | ...
//   SOF         : 3B = A5 | frame[7:0] | {frame[10:8], crc5}
//   握手 ACK/NAK/STALL: 1B = D2 / 5A / 1E
//   Special PRE: 1B = 3C (FS 设备按数据透明恢复)
//   USB2 NYET  : 1B = 96 (未知 PID, deserial 透明, 语义留给上层)
//   坏 PID     : 1B = 61 (OUT 补码最高位翻转) err=0
//   Token CRC5 错 / DATA CRC16 错: 字节原样, err=0
//============================================================================

task case_pkt_all;
    integer start_errs, frame_before;
    integer k;
    reg [6:0] addr;
    reg [3:0] endp;
    reg [4:0] c5;
    reg [10:0] fn;
    reg [7:0] exp_b1, exp_b2, exp_b4, exp_b5;
    reg [15:0] tx_crc;
    reg [7:0] p0, p1, p2;

    begin
        start_errs = errors;
        $display("== deserial_pkt_all: all USB1.1 packet types, byte-exact, err=0 ==");

        //--------------------------------------------------------------------
        // 0: Token IN  (addr=5, endp=0) — PID 69
        //--------------------------------------------------------------------
        addr = 7'd5; endp = 4'd0; c5 = crc5_tx(addr, endp);
        for (k = 0; k < 7; k = k + 1) exp_b1[k] = addr[k];
        exp_b1[7] = endp[0];
        for (k = 0; k < 3; k = k + 1) exp_b2[k] = endp[k+1];
        for (k = 0; k < 5; k = k + 1) exp_b2[k+3] = c5[4-k];
        frame_before = close_cnt;
        in_packet_task(addr, endp, 4, -1, 4);
        wait_close(frame_before + 1, 300);
        chk_frame(0, 3, 1'b0, 8'h69, exp_b1, exp_b2, 8'h00, 8'h00, 8'h00);
        #(BIT_TIME * 6);

        //--------------------------------------------------------------------
        // 1: Token SETUP (addr=5, endp=0) — PID 2D
        //--------------------------------------------------------------------
        frame_before = close_cnt;
        setup_packet_task(addr, endp, 4, -1, 4);
        wait_close(frame_before + 1, 300);
        chk_frame(1, 3, 1'b0, 8'h2D, exp_b1, exp_b2, 8'h00, 8'h00, 8'h00);
        #(BIT_TIME * 6);

        //--------------------------------------------------------------------
        // 2: SOF frame=0x3FF (低 10 位全 1, 强制 PID→帧号跨边界位填充) — PID A5
        //    b1 = frame[7:0]; b2 bit0..2=frame[8..10], bit3..7=crc5_tx_11
        //--------------------------------------------------------------------
        fn = 11'h3FF; c5 = crc5_tx_11(fn);
        for (k = 0; k < 8; k = k + 1) exp_b1[k] = fn[k];
        for (k = 0; k < 3; k = k + 1) exp_b2[k] = fn[k+8];
        for (k = 0; k < 5; k = k + 1) exp_b2[k+3] = c5[4-k];
        frame_before = close_cnt;
        sof_packet_task(fn, 4, -1, 4);
        wait_close(frame_before + 1, 300);
        chk_frame(2, 3, 1'b0, 8'hA5, exp_b1, exp_b2, 8'h00, 8'h00, 8'h00);
        #(BIT_TIME * 6);

        //--------------------------------------------------------------------
        // 3-5: 握手 ACK / NAK / STALL (仅 PID, 1 字节)
        //--------------------------------------------------------------------
        frame_before = close_cnt;
        ack_packet_task(4, -1, 4);
        wait_close(frame_before + 1, 300);
        chk_frame(3, 1, 1'b0, 8'hD2, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00);
        #(BIT_TIME * 6);

        frame_before = close_cnt;
        nak_packet_task(4, -1, 4);
        wait_close(frame_before + 1, 300);
        chk_frame(4, 1, 1'b0, 8'h5A, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00);
        #(BIT_TIME * 6);

        frame_before = close_cnt;
        stall_packet_task(4, -1, 4);
        wait_close(frame_before + 1, 300);
        chk_frame(5, 1, 1'b0, 8'h1E, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00);
        #(BIT_TIME * 6);

        //--------------------------------------------------------------------
        // 6: Special PRE (低速前导, 单 PID) — 3C
        //--------------------------------------------------------------------
        frame_before = close_cnt;
        pre_packet_task(4, -1, 4);
        wait_close(frame_before + 1, 300);
        chk_frame(6, 1, 1'b0, 8'h3C, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00);
        #(BIT_TIME * 6);

        //--------------------------------------------------------------------
        // 7: USB2 NYET (FS 设备未知 PID) — 96, deserial 透明
        //--------------------------------------------------------------------
        frame_before = close_cnt;
        nyet_packet_task(4, -1, 4);
        wait_close(frame_before + 1, 300);
        chk_frame(7, 1, 1'b0, 8'h96, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00);
        #(BIT_TIME * 6);

        //--------------------------------------------------------------------
        // 8: 坏 PID (OUT 补码最高位翻转) — deserial 不判 PID, 原样恢复 61, err=0
        //--------------------------------------------------------------------
        frame_before = close_cnt;
        bad_pid_packet_task(`PID_TYPE_OUT, 4, -1, 4);
        wait_close(frame_before + 1, 300);
        chk_frame(8, 1, 1'b0, 8'h61, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00);
        #(BIT_TIME * 6);

        //--------------------------------------------------------------------
        // 9: Token CRC5 错 (OUT, addr=5,endp=0) — 3B 原样, err=0
        //    b2 用翻转后的坏 crc: c5^5'h1F
        //--------------------------------------------------------------------
        c5 = crc5_tx(addr, endp) ^ 5'h1F;
        for (k = 0; k < 7; k = k + 1) exp_b1[k] = addr[k];   // b1 重算 (被 SOF 覆盖过)
        exp_b1[7] = endp[0];
        for (k = 0; k < 3; k = k + 1) exp_b2[k] = endp[k+1];
        for (k = 0; k < 5; k = k + 1) exp_b2[k+3] = c5[4-k];
        frame_before = close_cnt;
        token_badcrc_packet_task(`PID_TYPE_OUT, addr, endp, 4, -1, 4);
        wait_close(frame_before + 1, 300);
        chk_frame(9, 3, 1'b0, 8'hE1, exp_b1, exp_b2, 8'h00, 8'h00, 8'h00);
        #(BIT_TIME * 6);

        //--------------------------------------------------------------------
        // 10: DATA CRC16 错 (DATA0, {01 02 03}) — 6B 原样, err=0
        //--------------------------------------------------------------------
        p0 = 8'h01; p1 = 8'h02; p2 = 8'h03;
        tx_crc = crc16_tx(p0, p1, p2, 0, 0, 0, 0, 0, 3) ^ 16'hFFFF;
        for (k = 0; k < 8; k = k + 1) begin exp_b4[k] = tx_crc[15-k]; exp_b5[k] = tx_crc[7-k]; end
        frame_before = close_cnt;
        data_badcrc_packet_task(`PID_TYPE_DATA0, p0, p1, p2, 0, 0, 0, 0, 0, 3, 4, -1, 4);
        wait_close(frame_before + 1, 300);
        chk_frame(10, 6, 1'b0, 8'hC3, p0, p1, p2, exp_b4, exp_b5);
        #(BIT_TIME * 6);

        if (errors == start_errs) $display("  PASS: case_pkt_all (all packet types byte-exact, bad PID/CRC transparent)");
        else                      $display("  FAIL: case_pkt_all (%0d errors)", errors - start_errs);
    end
endtask
