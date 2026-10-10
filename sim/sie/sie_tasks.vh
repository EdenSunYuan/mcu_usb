//============================================================================
// sie_tasks.vh — usb_sie 字节级激励任务 (clk12m 域, 单时钟)
//
// 与 sim/common/usb_pkt_tasks.vh 的区别: 那份是 **位级** (DP/DN + NRZI + 位填充),
// 供 PHY 用; 本模块的输入契约是 **字节级** (rx_data/rx_valid/rx_active/rx_error),
// 位级那些活归 usb_rx_deserial, 这里直接喂它吐出来的字节。
//
// 建模口径 (照 usb_rx_deserial 的输出行为, 见 rx_deserial_design.md §4.8):
//   · rx_active 一整包拉高: SYNC 检出即抬起, EOP 检出即落下
//   · 每字节 rx_data 稳定 + rx_valid 单拍脉冲; 字节间隔 8 拍 (bit_stretch 可调)
//   · rx_active↑ 到首个 rx_valid 之间隔 8 拍 —— 位级上就是 SYNC 那 8 bit
//     (deserial 检出 SYNC 才抬 rx_active, PID 字节再过 8 bit 才凑齐)
//   · rx_active↓ 落在末字节之后 pkt_tail_gap 拍 (位级 = EOP 那 2 bit + 4× 判决,
//     实测 gap 用 1 即"末字节后 ~3 拍落", 与 deserial 的 EOP 展宽口径相当)
//   · ★ rx_active 落之后必须连续 3 拍为 0, pkt_rx 才补得完 2 个 CRC 字节并出
//     pkt_done (tail_cnt 0→1→2); 少了这 3 拍这一包的结论就丢了。
//     pkt_idle_gap 控这个间隔, 最紧取 3 (下一个包紧跟着来)。
//
// CRC 字节的线序 (这是最容易搞错的一处, 见 usb_sie_design.md §2.3/§2.5.2):
//   数据字段 LSB first, **CRC 字段 MSB first**。字节化之后
//     CRC5 : byte2[3]=c[4] ... byte2[7]=c[0]   (低 3 位 = endp[1:3])
//     CRC16: 第 1 个 CRC 字节 bit k = c[15-k], 第 2 个 bit k = c[7-k]
//   这样喂进去, 走完数据 + CRC 的残差才是 0x0C / 0x800D。
//
// 依赖 (由 tb_sie.v 提供):
//   · clk12m / ref_rstn / errors
//   · rx_data / rx_valid / rx_active / rx_error / buf_rd_en (reg, 本文件驱动)
//   · DUT 的 buf_ready/buf_cnt/buf_rd_data, 应答队列 resp_q[]/resp_n
//   · 白盒: dut_t_state / dut_toggle / dut_pkt_wr_ok, 探针 pr_cnt
//============================================================================

`ifndef SIE_TASKS_VH
`define SIE_TASKS_VH

`include "usb_const.vh"
`include "crc5_ref.vh"
`include "crc16_ref.vh"

// ---- 激励控制量 (tb 初始化) ----
integer byte_period   = 8;    // 每字节占的拍数 (9 = 位填充拉长的那种)
integer pkt_tail_gap  = 1;    // 末字节之后到 rx_active↓ 的拍数
integer pkt_idle_gap  = 4;    // rx_active↓ 之后保持空闲的拍数 (最小 3, 见文件头)
reg [7:0] pl_buf [0:63];      // 待发净荷
integer pl_n          = 0;    // 待发净荷字节数

// ---- 期望净荷 (核对排出字节用; 需要跨包保留时先 pl_keep) ----
reg [7:0] pl_exp [0:63];
integer pl_exp_n = 0;

//============================================================================
// 组合辅助函数
//============================================================================

// PID 字节: 高 4 位是低 4 位的反码
function [7:0] pid_byte;
    input [3:0] ptype;
    begin
        pid_byte = {~ptype[3:0], ptype[3:0]};
    end
endfunction

// token byte1 = {endp[0], addr[6:0]}
function [7:0] tok_b1;
    input [6:0] addr;
    input [3:0] endp;
    begin
        tok_b1 = {endp[0], addr[6:0]};
    end
endfunction

// token byte2 = {crc5 MSB first, endp[3:1]}
function [7:0] tok_b2;
    input [3:0] endp;
    input [4:0] c5;                 // 取反后的发送值
    begin
        tok_b2 = {c5[0], c5[1], c5[2], c5[3], c5[4], endp[3], endp[2], endp[1]};
    end
endfunction

// SOF byte2 = {crc5 MSB first, frame[10:8]}
function [7:0] sof_b2;
    input [10:0] fn;
    input [4:0]  c5;
    begin
        sof_b2 = {c5[0], c5[1], c5[2], c5[3], c5[4], fn[10], fn[9], fn[8]};
    end
endfunction

// CRC16 两字节 (线序: MSB first, 字节内 LSB 对齐)
function [7:0] crc16_b0;
    input [15:0] c;
    begin
        crc16_b0 = {c[8], c[9], c[10], c[11], c[12], c[13], c[14], c[15]};
    end
endfunction

function [7:0] crc16_b1;
    input [15:0] c;
    begin
        crc16_b1 = {c[0], c[1], c[2], c[3], c[4], c[5], c[6], c[7]};
    end
endfunction

// 净荷 (pl_buf[0..n-1]) 的 CRC16 **发送值** = 取反后的余数
//   ★ 上线的是取反值 (与 crc5_tx 同理), 别忘了这个 ~, 否则残差不是 0x800D
function [15:0] crc16_tx_pl;
    input integer n;
    integer i;
    reg [15:0] c;
    begin
        c = 16'hFFFF;
        for (i = 0; i < n; i = i + 1)
            c = crc16_feed_byte(c, pl_buf[i]);
        crc16_tx_pl = ~c;
    end
endfunction

//============================================================================
// 字节级发送原语 (全部在 negedge 驱动, 避开 DUT 的 posedge 采样)
//============================================================================

// 发一个字节: 先补齐与上一字节的间隔, 再给 rx_valid 单拍脉冲
task byte_send(input [7:0] b);
    begin
        repeat (byte_period - 1) @(negedge clk12m);
        rx_data  = b;
        rx_valid = 1'b1;
        @(negedge clk12m);
        rx_valid = 1'b0;
    end
endtask

// 包首: rx_active 抬起 (比 PID 字节早 8 拍, 就是 SYNC 那 8 bit)
task pkt_open;
    begin
        @(negedge clk12m);
        rx_active = 1'b1;
    end
endtask

// 包尾: pkt_tail_gap 拍后落 rx_active, 再留 pkt_idle_gap 拍空闲
task pkt_close;
    begin
        repeat (pkt_tail_gap) @(negedge clk12m);
        rx_active = 1'b0;
        repeat (pkt_idle_gap) @(negedge clk12m);
    end
endtask

//============================================================================
// 各类包 (自带 open/close)
//============================================================================

// OUT / IN / SETUP token; badcrc=1 → CRC5 全位翻转
task pkt_token(input [3:0] ptype, input [6:0] addr, input [3:0] endp, input badcrc);
    reg [4:0] c5;
    begin
        $display("tb: TOKEN type=%h addr=%0d endp=%0d badcrc=%0d", ptype, addr, endp, badcrc);
        c5 = crc5_tx(addr, endp);
        if (badcrc) c5 = c5 ^ 5'h1F;
        pkt_open;
        byte_send(pid_byte(ptype));
        byte_send(tok_b1(addr, endp));
        byte_send(tok_b2(endp, c5));
        pkt_close;
    end
endtask

// SOF (帧号 11 bit)
task pkt_sof(input [10:0] fn, input badcrc);
    reg [4:0] c5;
    begin
        $display("tb: SOF frame=%0d badcrc=%0d", fn, badcrc);
        c5 = crc5_tx_11(fn);
        if (badcrc) c5 = c5 ^ 5'h1F;
        pkt_open;
        byte_send(pid_byte(`PID_TYPE_SOF));
        byte_send(fn[7:0]);
        byte_send(sof_b2(fn, c5));
        pkt_close;
    end
endtask

// DATA0 / DATA1 (净荷取 pl_buf[0..n-1]); badcrc=1 → CRC16 最低位翻转
task pkt_data(input is_data1, input integer n, input badcrc);
    reg [15:0] c16;
    integer i;
    begin
        $display("tb: DATA%0d n=%0d badcrc=%0d", is_data1, n, badcrc);
        c16 = crc16_tx_pl(n);
        if (badcrc) c16 = c16 ^ 16'h0001;      // 末位单 bit 错
        pkt_open;
        byte_send(pid_byte(is_data1 ? `PID_TYPE_DATA1 : `PID_TYPE_DATA0));
        for (i = 0; i < n; i = i + 1)
            byte_send(pl_buf[i]);
        byte_send(crc16_b0(c16));
        byte_send(crc16_b1(c16));
        pkt_close;
    end
endtask

// 握手包 (只有 PID)
task pkt_hs(input [3:0] ptype);
    begin
        $display("tb: HS pid=%h", ptype);
        pkt_open;
        byte_send(pid_byte(ptype));
        pkt_close;
    end
endtask

// 裸包: 指定 PID 字节 + n 个填充字节, 不带 CRC (造超长 / 截断 / 垃圾包)
task pkt_raw(input [7:0] pidb, input integer n, input [7:0] fill);
    integer i;
    begin
        $display("tb: RAW pid=%02x n=%0d", pidb, n);
        pkt_open;
        byte_send(pidb);
        for (i = 0; i < n; i = i + 1)
            byte_send(fill);
        pkt_close;
    end
endtask

//============================================================================
// 配置 / 事件 / 复位 / 错误注入
//============================================================================

// 准静态配置 (pclk 域口径): 改完等 4 拍, 让 2-FF 同步链吃进去
task set_cfg(input [6:0] addr, input [2:0] stall, input [2:0] nak, input [1:0] dir);
    begin
        @(negedge clk12m);
        dev_addr = addr; ep_stall = stall; ep_nak = nak; ep_dir = dir;
        repeat (4) @(negedge clk12m);
    end
endtask

// CPU 写 toggle 初值 (toggle_set 单拍脉冲)
task set_toggle(input [2:0] val);
    begin
        @(negedge clk12m);
        toggle_val = val;
        toggle_set = 3'b111;
        @(negedge clk12m);
        toggle_set = 3'b000;
        repeat (4) @(negedge clk12m);
    end
endtask

// 附着事件 (usb_bus_state 的单拍脉冲口径)
task pulse_connect_evt;
    begin
        @(negedge clk12m);
        connect_evt = 1'b1;
        @(negedge clk12m);
        connect_evt = 1'b0;
        repeat (2) @(negedge clk12m);
    end
endtask

// core 复位脉冲 (宽 1 个 clk12m 周期)
task pulse_usb_rst;
    begin
        @(negedge clk12m);
        usb_rst = 1'b1;
        @(negedge clk12m);
        usb_rst = 1'b0;
        repeat (2) @(negedge clk12m);
    end
endtask

// 物理错电平注入 (rx_error 是电平, 包内拉高即锁存进 pkt_bad)
task rxerr_pulse(input integer n);
    begin
        @(negedge clk12m);
        rx_error = 1'b1;
        repeat (n) @(negedge clk12m);
        rx_error = 1'b0;
    end
endtask

// 空等 n 拍 (让应答/事件脉冲都出完)
task idle_cycles(input integer n);
    begin
        repeat (n) @(negedge clk12m);
    end
endtask

// 等 pkt_done (探针 pr_cnt 计数变化), 带超时
task wait_pktdone(input integer timeout);
    integer g, c0;
    begin
        g = 0; c0 = pr_cnt;
        while ((pr_cnt == c0) && (g < timeout)) begin
            @(negedge clk12m);
            g = g + 1;
        end
        if (pr_cnt == c0) begin
            $display("    FAIL: 等 pkt_done 超时 (%0d 拍)", timeout);
            errors = errors + 1;
        end
    end
endtask

//============================================================================
// 净荷造数 / 期望值核对
//============================================================================

// 造 n 字节净荷: 第 i 字节 = seed + 7*i + 1 (非重复, 便于定位错位)
task pl_fill(input integer n, input [7:0] seed);
    integer i;
    begin
        if (n > 64) begin
            $display("    FAIL: pl_fill n=%0d 超出 pl_buf 容量 (64)", n);
            errors = errors + 1;
            n = 64;
        end
        for (i = 0; i < n; i = i + 1)
            pl_buf[i] = seed + 8'd7 * i + 8'd1;
        pl_n = n;
    end
endtask

// 冻结当前净荷为期望值 (跨包保留, 供后面的排出核对)
task pl_keep;
    integer i;
    begin
        for (i = 0; i < pl_n; i = i + 1)
            pl_exp[i] = pl_buf[i];
        pl_exp_n = pl_n;
    end
endtask

// 核对最近排出的字节 (从 rec_start 起) == pl_exp[0..pl_exp_n-1]
task chk_drain_exp(input integer rec_start, input [8*47:0] tag);
    integer i;
    reg bad;
    begin
        bad = 1'b0;
        if ((drain_n - rec_start) != pl_exp_n) begin
            $display("    FAIL: %0s 排出字节数 %0d, 期望 %0d",
                     tag, drain_n - rec_start, pl_exp_n);
            errors = errors + 1;
            bad = 1'b1;
        end else begin
            for (i = 0; i < pl_exp_n; i = i + 1) begin
                if (drain_rec[rec_start + i] !== pl_exp[i]) begin
                    $display("    FAIL: %0s 第 %0d 字节 %02x, 期望 %02x",
                             tag, i, drain_rec[rec_start + i], pl_exp[i]);
                    errors = errors + 1;
                    bad = 1'b1;
                end
            end
        end
        if (!bad)
            $display("    OK  : %0s 排出 %0d 字节内容全对", tag, pl_exp_n);
    end
endtask

// 冻结当前净荷并核对 (一步到位)
task chk_drain_pl(input integer rec_start, input [8*47:0] tag);
    begin
        pl_keep;
        chk_drain_exp(rec_start, tag);
    end
endtask

// 核对 buf_cnt (buf_ready=1 期间有效)
task chk_buf_cnt(input integer exp, input [8*47:0] tag);
    begin
        if (buf_ready !== 1'b1) begin
            $display("    FAIL: %0s 期望 buf_ready=1, 实际 0", tag);
            errors = errors + 1;
        end else if (buf_cnt !== exp[6:0]) begin
            $display("    FAIL: %0s buf_cnt=%0d, 期望 %0d", tag, buf_cnt, exp);
            errors = errors + 1;
        end else
            $display("    OK  : %0s buf_cnt=%0d", tag, buf_cnt);
    end
endtask

// 核对 buf_ready 电平
task chk_buf_ready(input exp, input [8*47:0] tag);
    begin
        if (buf_ready !== exp) begin
            $display("    FAIL: %0s buf_ready=%b, 期望 %b", tag, buf_ready, exp);
            errors = errors + 1;
        end else
            $display("    OK  : %0s buf_ready=%b", tag, buf_ready);
    end
endtask

// 核对事务状态机现态 (白盒)
task chk_tstate(input [2:0] exp, input [8*47:0] tag);
    begin
        if (dut_t_state !== exp) begin
            $display("    FAIL: %0s 事务态=%0d, 期望 %0d", tag, dut_t_state, exp);
            errors = errors + 1;
        end else
            $display("    OK  : %0s 事务态=%0d", tag, dut_t_state);
    end
endtask

//============================================================================
// 包缓冲排出 (CDC 侧口径: buf_rd_en 逐字节脉冲)
//============================================================================

// 排 n 个字节 (n < buf_cnt 时缓冲保持 ready, 用于造"忙")
task drain_bytes(input integer n);
    integer i;
    begin
        for (i = 0; i < n; i = i + 1) begin
            if (!buf_ready) begin
                $display("    FAIL: drain_bytes 期望 buf_ready=1, 实际 0 (第 %0d 字节)", i);
                errors = errors + 1;
                i = n;
            end else begin
                @(negedge clk12m);
                drain_rec[drain_n] = buf_rd_data;      // 读口组合, 先于 posedge 采样
                drain_n = drain_n + 1;
                buf_rd_en = 1'b1;
                @(negedge clk12m);
                buf_rd_en = 1'b0;
            end
        end
    end
endtask

// 排空当前包: 0 长度包补一次读脉冲 (协议上零长包也要走完握手)
task drain_all;
    integer nb;
    begin
        nb = buf_cnt;
        drain_bytes(nb);
        if (nb == 0) begin
            @(negedge clk12m);
            buf_rd_en = 1'b1;
            @(negedge clk12m);
            buf_rd_en = 1'b0;
        end
        @(negedge clk12m);
        if (buf_ready) begin
            $display("    FAIL: drain_all 后 buf_ready 仍为 1 (cnt=%0d)", buf_cnt);
            errors = errors + 1;
        end
    end
endtask

// 等 buf_ready 起来 (带超时)
task wait_buf_ready(input integer timeout);
    integer g;
    begin
        g = 0;
        while (!buf_ready && g < timeout) begin
            @(negedge clk12m);
            g = g + 1;
        end
        if (!buf_ready) begin
            $display("    FAIL: 等 buf_ready 超时 (%0d 拍)", timeout);
            errors = errors + 1;
        end
    end
endtask

`endif
