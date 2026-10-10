//============================================================================
// phy_tasks.vh — tb_phy 的公共任务（在 tb_phy 模块内 include）
//
// 依赖 tb_phy 里的: errors, n_evt[], w_evt[], frame_cnt, last_err, last_nb,
//   last_bytes[], exp_bytes[], pay[], tx_* 队列, rxdp/rxdn, clk12m/ref_clk。
//
// ★ $display 的 tag 一律用 ASCII: 字符串经宽向量形参传递时按位截断，
//   中文 UTF-8 续字节会被砍掉变成乱码（实测）。解释写在 case 文件头的注释里。
//
// 口径: 期望字节按**线上字节**算。USB 数据字段 LSB first、CRC 字段 MSB first，
//   同一字节内位序不同；token 的 byte2 低 3 位还是 endp 不是 CRC。
//   算法统一放这里，用例只比对。
//============================================================================

// ---- 判据 + 计数 ----
task chk(input cond, input [1023:0] tag);
    begin
        if (cond) $display("  ok  : %0s", tag);
        else begin
            $display("  ERR : %0s", tag);
            errors = errors + 1;
        end
    end
endtask

// ---- 线驱动 ----
task drv_j(input real t);
    begin rxdp = 1'b1; rxdn = 1'b0; #(t); end
endtask

task drv_k(input real t);
    begin rxdp = 1'b0; rxdn = 1'b1; #(t); end
endtask

task drv_se0(input real t);
    begin rxdp = 1'b0; rxdn = 1'b0; #(t); end
endtask

// ---- 等到某类事件累计到 n 次（ref 拍超时保护） ----
task wait_evt(input integer idx, input integer n, input integer tmo);
    integer g;
    begin
        g = 0;
        while ((n_evt[idx] < n) && (g < tmo)) begin
            @(posedge ref_clk);
            g = g + 1;
        end
    end
endtask

// ---- 等到累计关包帧数到 n ----
task wait_frames(input integer n, input integer tmo);
    integer g;
    begin
        g = 0;
        while ((frame_cnt < n) && (g < tmo)) begin
            @(posedge ref_clk);
            g = g + 1;
        end
    end
endtask

// ---- 等 clk12m 若干个整拍（需要 clk12m 有沿；冷线 + rcv=1 时无沿，别用） ----
task wait_clk12m(input integer n);
    integer g;
    begin
        for (g = 0; g < n; g = g + 1) @(posedge clk12m);
    end
endtask

// ---- 软复位脉冲：宽 1 个 clk12m 周期（TB 扮 APB control 的同步分发） ----
task pulse_swrst;
    begin
        @(negedge clk12m); swrst = 1'b1;
        @(negedge clk12m); swrst = 1'b0;
    end
endtask

// ---- 把设备挂上总线：驱 J 等 connect_evt（那一次跳变同时给 CDR 起振） ----
task attach_dev;
    integer g;
    begin
        rxdp = 1'b1; rxdn = 1'b0;
        g = 0;
        while ((n_evt[0] < 1) && (g < 40000)) begin
            @(posedge ref_clk);
            g = g + 1;
        end
        repeat (60) @(posedge ref_clk);
    end
endtask

//============================================================================
// 期望字节
//============================================================================
integer   exp_n = 0;
reg [7:0] exp_bytes [0:FB_DEPTH-1];
reg [7:0] pay [0:FB_DEPTH-1];

task set_pay(input [7:0] p0, p1, p2, p3, p4, p5, p6, p7);
    begin
        pay[0]=p0; pay[1]=p1; pay[2]=p2; pay[3]=p3;
        pay[4]=p4; pay[5]=p5; pay[6]=p6; pay[7]=p7;
    end
endtask

// token 线上字节:
//   byte0 = PID 线上值 {~type,type}
//   byte1 = {endp[0], addr[6:0]}          -- addr LSB 先发，endp 低位紧跟
//   byte2 = {c5[0..4], endp[3],endp[2],endp[1]}
//           -- CRC5 线上 MSB first，先发的 c5[4] 落在 byte2 的 bit3
task exp_token(input [3:0] pid_type, input [6:0] addr, input [3:0] endp);
    reg [4:0] c5;
    begin
        c5 = crc5_tx(addr, endp);
        exp_n        = 3;
        exp_bytes[0] = {~pid_type, pid_type};
        exp_bytes[1] = {endp[0], addr[6:0]};
        exp_bytes[2] = {c5[0], c5[1], c5[2], c5[3], c5[4],
                        endp[3], endp[2], endp[1]};
    end
endtask

// data 线上字节: byte0 = PID; byte1..n = 净荷原值; 末两字节 = CRC16
//   CRC 线上 MSB first: 先发的 c16[15] 落在第一个 CRC 字节的 bit0
task exp_data(input [3:0] pid_type, input integer nbytes);
    reg [15:0] c16;
    integer k;
    begin
        c16 = crc16_tx(pay[0], pay[1], pay[2], pay[3],
                       pay[4], pay[5], pay[6], pay[7], nbytes[6:0]);
        exp_n        = nbytes + 3;
        exp_bytes[0] = {~pid_type, pid_type};
        for (k = 0; k < nbytes; k = k + 1) exp_bytes[1+k] = pay[k];
        exp_bytes[nbytes+1] = {c16[8],  c16[9],  c16[10], c16[11],
                               c16[12], c16[13], c16[14], c16[15]};
        exp_bytes[nbytes+2] = {c16[0],  c16[1],  c16[2],  c16[3],
                               c16[4],  c16[5],  c16[6],  c16[7]};
    end
endtask

// handshake 线上字节: 只有 byte0 = PID，无 CRC、无数据
task exp_hshake(input [3:0] pid_type);
    begin
        exp_n        = 1;
        exp_bytes[0] = {~pid_type, pid_type};
    end
endtask

// 任意长度净荷的 CRC16 发送值（取反后的余数），种子 0xFFFF、字节 LSB first。
// crc16_ref.vh 的 crc16_tx 只吃 8 个字节形参，满长包要 64 字节，故这里逐字节喂
// 它公开的单步函数 crc16_feed_byte。8 字节以内两者等价，由 maxlen 用例交叉核对。
function [15:0] crc16_pay;
    input integer n;
    integer i;
    reg [15:0] c;
    begin
        c = 16'hFFFF;
        for (i = 0; i < n; i = i + 1)
            c = crc16_feed_byte(c, pay[i]);
        crc16_pay = ~c;
    end
endfunction

// data 线上字节（不限 8 字节）: 同 exp_data，净荷取 pay[0..n-1]
task exp_data_n(input [3:0] pid_type, input integer nbytes);
    reg [15:0] c16;
    integer k;
    begin
        c16 = crc16_pay(nbytes);
        exp_n        = nbytes + 3;
        exp_bytes[0] = {~pid_type, pid_type};
        for (k = 0; k < nbytes; k = k + 1) exp_bytes[1+k] = pay[k];
        exp_bytes[nbytes+1] = {c16[8],  c16[9],  c16[10], c16[11],
                               c16[12], c16[13], c16[14], c16[15]};
        exp_bytes[nbytes+2] = {c16[0],  c16[1],  c16[2],  c16[3],
                               c16[4],  c16[5],  c16[6],  c16[7]};
    end
endtask

// 主机发任意长度 DATA 包: SYNC + PID + pay[0..n-1] + CRC16 + EOP
// （usb_pkt_tasks.vh 的 data_packet_task 净荷形参只有 8 个，满长包走这条）
task send_data_pay(input [3:0] pid_type, input integer nbytes,
                   input integer cyc, input integer long_bit_idx,
                   input integer long_cyc);
    integer i, bit_cnt;
    reg [15:0] c16;
    begin
        c16 = crc16_pay(nbytes);
        bit_cnt = 0;
        sync_task(cyc, long_bit_idx, long_cyc, bit_cnt);

        pid_task(pid_type, cyc, long_bit_idx - bit_cnt, long_cyc);
        bit_cnt = bit_cnt + 8;

        for (i = 0; i < nbytes; i = i + 1) begin
            byte_task(pay[i], cyc, long_bit_idx - bit_cnt, long_cyc);
            bit_cnt = bit_cnt + 8;
        end

        for (i = 15; i >= 0; i = i - 1) begin
            bit_task(c16[i], (bit_cnt == long_bit_idx) ? long_cyc : cyc);
            bit_cnt = bit_cnt + 1;
        end

        eop_task;
    end
endtask

// ---- 逐字节核第 n 帧（1 起）；err_exp = 该帧预期 rx_error；tag 走 ASCII ----
task chk_frame(input integer n, input err_exp, input [1023:0] tag);
    integer k, bad, i;
    begin
        bad = 0;
        if (frame_cnt < n) begin
            $display("  ERR : %0s -- frame %0d never closed (frame_cnt=%0d)",
                     tag, n, frame_cnt);
            errors = errors + 1;
        end else begin
            i = (n - 1) & 3;
            if (hist_n[i] !== exp_n) begin
                $display("  ERR : %0s -- frame %0d has %0d bytes, exp %0d",
                         tag, n, hist_n[i], exp_n);
                bad = 1;
            end
            for (k = 0; k < hist_n[i] && k < exp_n; k = k + 1)
                if (hist_b[i][k] !== exp_bytes[k]) begin
                    $display("  ERR : %0s -- frame %0d byte%0d = %02x, exp %02x",
                             tag, n, k, hist_b[i][k], exp_bytes[k]);
                    bad = 1;
                end
            if (hist_err[i] !== err_exp) begin
                $display("  ERR : %0s -- frame %0d rx_error = %0b, exp %0b",
                         tag, n, hist_err[i], err_exp);
                bad = 1;
            end
            if (bad == 0)
                $display("  ok  : %0s -- frame %0d, %0d bytes, rx_error=%0b",
                         tag, n, hist_n[i], hist_err[i]);
            else
                errors = errors + 1;
        end
    end
endtask

// ---- 事件计数/脉宽判据（tag 走 ASCII） ----
//   ★ 脉宽必须等一拍再查: 脉冲是子模块在 clk12m 沿上用非阻塞赋值拉起的，量宽的那个
//     always 块在同一沿读到的是**旧值**，要下一个 clk12m 沿才数到。宽度是全程最大值,
//     等过之后不会再变。这里用固定 #200（> 1 个 clk12m 周期）而不是等 clk12m 沿,
//     免得在时钟停摆的场合把 TB 挂死。
task chk_evt(input integer idx, input integer n_exp, input [1023:0] tag);
    begin
        if (n_evt[idx] == n_exp)
            $display("  ok  : %0s count = %0d", tag, n_evt[idx]);
        else begin
            $display("  ERR : %0s count = %0d, exp %0d", tag, n_evt[idx], n_exp);
            errors = errors + 1;
        end
        if (n_evt[idx] > 0) begin
            #200;
            if (w_evt[idx] != 1) begin
                $display("  ERR : %0s pulse width %0d clk12m cycles, exp 1",
                         tag, w_evt[idx]);
                errors = errors + 1;
            end else
                $display("  ok  : %0s pulse width = 1 clk12m cycle", tag);
        end
    end
endtask

// ---- 打印逐段 rx_active 记录（一段 = 一次 rx_active 高电平） ----
task dump_periods(input integer n);
    integer i;
    begin
        $display("---- rx_active periods: %0d recorded (%0d closed)", n, frame_cnt);
        for (i = 0; i < n && i < 4; i = i + 1)
            $display("     period %0d: %0d bytes, rx_error=%0b",
                     i + 1, hist_n[i], hist_err[i]);
    end
endtask

task print_evt_summary;
    begin
        $display("---- events: connect=%0d rst=%0d suspend=%0d resume=%0d",
                 n_evt[0], n_evt[1], n_evt[2], n_evt[3]);
        $display("     max width (clk12m cyc): %0d %0d %0d %0d",
                 w_evt[0], w_evt[1], w_evt[2], w_evt[3]);
        $display("     frame_cnt=%0d  n_rx_active_rise=%0d  ns_bad=%0d",
                 frame_cnt, n_rx_active_rise, ns_bad);
        $display("     clk12m min phase (ref cyc): hi=%0d lo=%0d  se0_run_max=%0d",
                 clk_hi_min, clk_lo_min, se0_run_max);
        $display("     clk12m rise=%0d fall=%0d  dclk rise=%0d  ref rise=%0d",
                 n_clk12m_rise, n_clk12m_fall, n_dclk_rise, n_ref_rise);
    end
endtask

//============================================================================
// 发送 (TB 扮 SIE, 握手口径同 tx_last 契约)
//============================================================================
task tx_put(input [7:0] b);
    begin tx_bytes[tx_n] = b; tx_n = tx_n + 1; end
endtask

task tx_start;
    begin tx_req = 1'b1; end
endtask

task tx_finish;
    begin tx_req = 1'b0; end
endtask
