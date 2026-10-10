//============================================================================
// case_rx_token.v — 主机发 OUT token，整条 PHY 链路的字节级复现
//
// 因: 插入后主机发 SYNC + PID(OUT) + ADDR + ENDP + CRC5 + EOP。
//     位级链路的走向是 CDR → deserial（内部自己采 line_s）→ rx_data/rx_valid；
//     rx_active 由 deserial 的帧机在 SYNC 后拉起、EOP/SE0 定界时落下。
// 变: 每 8 个位时钟出 1 个 rx_valid 脉冲 + 1 个字节；整包含 3 个字节。
// 果: ① rx_active 上升沿恰 1 次（整包一段，不是每字节一段）；
//     ② 关包时 rx_error = 0；
//     ③ 3 个字节逐字节等于参考模型：
//          byte0 = 0xE1 (OUT=PID_TYPE_OUT=1，线上 {~1,1} = 1110_0001)
//          byte1 = {endp[0], addr[6:0]}
//          byte2 = {c5[0..4], endp[3],endp[2],endp[1]}，c5 = crc5_tx(addr,endp)
//        后两个字节是地址/端点的位序与 CRC5 的 MSB-first 落点，最容易接错，
//        故本用例故意选 7 位地址 + 4 位端点全 1 的边界值（addr=0x7F, endp=0xF）。
// 前后文窗口: 关包的下降沿后记帧，随后 20µs 无新帧。
//
// 另: 这 3 个字节还必须"落在同一帧里"。EOP 的 SE0 只有 2 个位时钟，deserial 的
//   定界跑 ref_clk 4×（8 拍），两者宽度正好卡住 —— 若定界域接错，帧会被切碎成 1~3 帧。
//============================================================================
task case_rx_token;
    begin
        attach_dev;
        chk_evt(0, 1, "connect_evt before rx");

        $display("  [host sends OUT token addr=0x7F endp=0xF]");
        nrzi_lv = 1'b1;                       // 包间回到 idle J
        ones_cnt = 0;
        out_packet_task(7'h7F, 4'hF, 4, -1, 0);
        drv_j(2000.0);                        // 包间 gap
        wait_frames(1, 20000);

        exp_token(`PID_TYPE_OUT, 7'h7F, 4'hF);
        chk_frame(1, 1'b0, "OUT token payload");

        chk(n_rx_active_rise == 1, "rx_active rose exactly once for the packet");
        $display("        rx_active rises = %0d, frames = %0d",
                 n_rx_active_rise, frame_cnt);

        chk_evt(0, 1, "no extra connect_evt");
        chk_evt(1, 0, "token body must not look like a bus reset");
        chk_evt(2, 0, "no suspend_evt");

        if (errors == start_errs) $display("  PASS: phy_rx_token");
        else $display("  FAIL: phy_rx_token (%0d errors)", errors - start_errs);
    end
endtask
