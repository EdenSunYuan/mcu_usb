//============================================================================
// usb_pkt_tasks.vh — USB 1.1 数据包激励公共任务 (所有 tb 共享)
//
// 提供从 bit → byte → pid → 完整 packet 的分层发送任务，
// 内含 NRZI 编码 + 位填充 (bit-stuffing)，供任意 PHY/SIE testbench 复用。
//
// 覆盖 USB 1.1 全部包类型:
//   Token     : OUT / IN / SETUP / SOF
//   Data      : DATA0 / DATA1 (含 CRC16)
//   Handshake : ACK / NAK / STALL
//   Special   : PRE (仅 PID, 主机→hub 的低速前导, usb_const 已定义)
//
// 两类扩展 (供后续 SIE/deserial 测试复用):
//   - 每个 PID 的独立封装任务: data0/data1/ack/nak/stall/nyet/pre_packet_task
//   - 坏包/错误注入变体: PID 校验错 / CRC5/CRC16 错 / 截断无 EOP / 超长溢出
//
// 依赖 (由包含本文件的 tb 模块提供):
//   - rxdp, rxdn             : reg 差分线 (DP/DN), 由 drive_dpdn 驱动
//   - parameter real BIT_TIME      = 1 个 USB bit 时间 (12Mbps ≈ 83.333ns)
//   - parameter real EOP_SE0_TIME  = EOP SE0 段时长 (2 bit-time)
//   - parameter real EOP_J_TIME    = EOP J 段时长 (1 bit-time)
//
// 内部依赖 (本文件 include):
//   - "crc5_ref.vh"  : Token/SOF 的 CRC5 参考函数
//   - "crc16_ref.vh" : Data 的 CRC16 参考函数
//   - "usb_const.vh" : PID 类型常量 (来自 src/inc, 需 -I 路径)
//
// 全局状态 (由本文件声明):
//   - ones_cnt : 连续 1 计数 (位填充用)
//   - nrzi_lv  : 当前 NRZI 电平 (1=J, 0=K)
//
// 任务清单 (合法包):
//   drive_dpdn(lv, t)                    驱动 DP/DN 到指定电平并保持 t
//   bit_task(d, cyc)                      发 1 个数据位 (NRZI + 位填充)
//   byte_task(b, cyc, ofs, lcyc)          发 1 字节 (LSB first), 可指定 bit 拉长
//   pid_task(type, cyc, ofs, lcyc)        发 1 个 PID (type + ~type)
//   sync_task(cyc, lbit, lcyc, bit_cnt)   发 SYNC (00000001)
//   eop_task                              发 EOP (SE0×2 + J)
//   token_packet_task(...)                通用 Token (OUT/IN/SETUP)
//   out_packet_task / in_packet_task / setup_packet_task   Token 封装
//   sof_packet_task(...)                  SOF (帧号 + CRC5)
//   data_packet_task(...)                 DATA0/DATA1 (payload + CRC16)
//   handshake_packet_task(...)            ACK/NAK/STALL (仅 PID)
//
// 每个 PID 独立封装 (补全, 对齐 out/in/setup 风格):
//   data0_packet_task / data1_packet_task
//   ack_packet_task / nak_packet_task / stall_packet_task
//   nyet_packet_task (USB2.0, 保留/未知握手) / pre_packet_task (Special)
//
// 坏包/错误注入变体 (供 SIE/deserial 容错验证):
//   bad_pid_packet_task(...)              PID 校验错 (补码位翻转)
//   token_badcrc_packet_task(...)         Token CRC5 错
//   sof_badcrc_packet_task(...)           SOF   CRC5 错
//   data_badcrc_packet_task(...)          Data  CRC16 错
//   token_noeop_packet_task(...)          截断无 EOP (token)
//   data_noeop_packet_task(...)           截断无 EOP (data)
//   oversize_data_packet_task(...)        超长 payload 溢出端点上限 (无 CRC16)
//
// 说明: 所有 *packet_task 的 cyc 为标称 bit 周期数(4)，
//       long_bit_idx 为全局 bit 索引(-1 不指定)，long_cyc 为该 bit 的周期数，
//       用于构造长/短 bit 测试 CDR 的 F/B 绕行。
//============================================================================

`ifndef USB_PKT_TASKS_VH
`define USB_PKT_TASKS_VH

`include "usb_const.vh"
`include "crc5_ref.vh"
`include "crc16_ref.vh"

// ---- 全局状态 ----
integer        ones_cnt;      // 连续1计数 (对发送的数据位)
reg            nrzi_lv;       // 当前NRZI电平 (1=J, 0=K)

// ---- 发送记录 (端到端回环验证用) ----
// 由 tb 置 record_en=1 使能; bit_task 按发送顺序记录实际数据位(含 stuffed bit),
// 供 tb 用 CDR 恢复的 clk12m+d_out 还原出数据位后逐 bit 对比。
reg        record_en;
reg  [7:0] exp_tx_q [0:511];  // 期望发送数据位 (LSB-first 线上顺序, 含 stuffed)
integer    exp_tx_wptr;

// ---- 驱动 DP/DN 为指定电平, 保持 t 时间 ----
task drive_dpdn(input lv, input real t);
    begin
        if (lv) begin rxdp = 1'b1; rxdn = 1'b0; end
        else    begin rxdp = 1'b0; rxdn = 1'b1; end
        #(t);
    end
endtask

// ---- bit_task: 发送一个数据位 (含NRZI + 位填充) ----
// d = 数据位, cyc = 周期数(3=短,4=标称,5=长), 默认4
//
// 位填充按 USB 规范为**无条件**: 已发 6 个连续 1 后, 无论下一数据位是 0 还是 1,
// 都先插一个 stuffed 0 (规范 §7.1.9; 若下一数据是 0, 该 0 提供跳变但规则仍强制
// 先插 stuffed 0 —— 否则接收端"数满 6 个 1 就丢弃下一 0"会把真数据 0 误删)。
// 发送第 7 个连续位(不管数值)才会触发, 故"恰好 6 个 1 收尾"的字节流不插。
// (EOP 前若收尾 6 个 1 也须插 stuffed 0, 由各 *packet_task 在 eop_task 前处理。)
task bit_task(input d, input real cyc);
    real t;
    begin
        t = BIT_TIME * cyc / 4.0;

        // 位填充检查: 已发 6 个连续 1 -> 无条件插入 stuffed 0
        if (ones_cnt == 6) begin
            nrzi_lv = ~nrzi_lv;                    // stuffed 0 翻转 NRZI
            drive_dpdn(nrzi_lv, t);                // 驱动 stuffed 0
            ones_cnt = 0;
            if (record_en) begin
                exp_tx_q[exp_tx_wptr] = 1'b0;      // 记录 stuffed 0
                exp_tx_wptr = exp_tx_wptr + 1;
            end
        end

        // 发送实际数据位
        if (d == 1'b0) nrzi_lv = ~nrzi_lv;         // data=0 翻转 NRZI
        drive_dpdn(nrzi_lv, t);

        if (record_en) begin
            exp_tx_q[exp_tx_wptr] = d;             // 记录实际数据位
            exp_tx_wptr = exp_tx_wptr + 1;
        end
        if (d == 1'b1) ones_cnt = ones_cnt + 1;
        else           ones_cnt = 0;
    end
endtask

// ---- byte_task: 发送字节 (LSB first), 可指定周期数 ----
// long_ofs: 指定拉长/缩短的 bit 索引 (相对本字节), 越界则忽略
// long_cyc: 该 bit 的周期数
task byte_task(input [7:0] byte_val, input integer cyc,
               input integer long_ofs, input integer long_cyc);
    integer k;
    begin
        for (k=0; k<8; k=k+1)
            bit_task(byte_val[k], (long_ofs==k)? long_cyc : cyc);
    end
endtask

// ---- pid_task: 发送 PID 字节 (type + ~type, LSB first) ----
task pid_task(input [3:0] pid_type, input integer cyc,
              input integer long_ofs, input integer long_cyc);
    reg [7:0] pid_byte;
    begin
        pid_byte = {~pid_type, pid_type};
        byte_task(pid_byte, cyc, long_ofs, long_cyc);
    end
endtask

// ---- sync_task: 发送 SYNC (00000001, LSB first = 7个0 + 1个1) ----
task sync_task(input integer cyc, input integer long_bit_idx,
               input integer long_cyc, inout integer bit_cnt);
    integer i;
    begin
        for (i=0; i<7; i=i+1) begin
            bit_task(1'b0, (bit_cnt==long_bit_idx)? long_cyc : cyc);
            bit_cnt = bit_cnt + 1;
        end
        bit_task(1'b1, (bit_cnt==long_bit_idx)? long_cyc : cyc);
        bit_cnt = bit_cnt + 1;
    end
endtask

// ---- eop_task: 发送 EOP (SE0 2 bit-time + J 1 bit-time) ----
task eop_task;
    begin
        rxdp = 1'b0; rxdn = 1'b0;
        #(EOP_SE0_TIME);
        rxdp = 1'b1; rxdn = 1'b0;
        nrzi_lv = 1'b1;   // 重置NRZI到idle J
        #(EOP_J_TIME);
    end
endtask

// ---- token_packet_task: 发送通用 Token 包 (OUT/IN/SETUP) ----
// 结构: SYNC + PID + ADDR(7) + ENDP(4) + CRC5(5) + EOP
task token_packet_task(input [3:0] pid_type, input [6:0] addr, input [3:0] endp,
                       input integer cyc, input integer long_bit_idx,
                       input integer long_cyc);
    integer i, bit_cnt;
    reg [4:0] c5;
    begin
        $display("tb: TOKEN pid=%h addr=%d endp=%d cyc=%0d long_bit=%0d(%0dcyc)",
                 pid_type, addr, endp, cyc, long_bit_idx, long_cyc);
        bit_cnt = 0;

        sync_task(cyc, long_bit_idx, long_cyc, bit_cnt);

        pid_task(pid_type, cyc, long_bit_idx - bit_cnt, long_cyc);
        bit_cnt = bit_cnt + 8;

        // ADDR (7bit, LSB first)
        for (i=0; i<7; i=i+1) begin
            bit_task(addr[i], (bit_cnt==long_bit_idx)? long_cyc : cyc);
            bit_cnt = bit_cnt + 1;
        end
        // ENDP (4bit, LSB first)
        for (i=0; i<4; i=i+1) begin
            bit_task(endp[i], (bit_cnt==long_bit_idx)? long_cyc : cyc);
            bit_cnt = bit_cnt + 1;
        end
        // CRC5 (5bit, MSB first: 取反值 c5[4] 先发, 见 crc5_ref.vh)
        c5 = crc5_tx(addr, endp);
        for (i=0; i<5; i=i+1) begin
            bit_task(c5[4-i], (bit_cnt==long_bit_idx)? long_cyc : cyc);   // MSB first
            bit_cnt = bit_cnt + 1;
        end

        eop_task;
    end
endtask

// ---- out_packet_task / in_packet_task / setup_packet_task: Token 封装 ----
task out_packet_task(input [6:0] addr, input [3:0] endp,
                     input integer cyc, input integer long_bit_idx,
                     input integer long_cyc);
    begin
        token_packet_task(`PID_TYPE_OUT, addr, endp, cyc, long_bit_idx, long_cyc);
    end
endtask

task in_packet_task(input [6:0] addr, input [3:0] endp,
                    input integer cyc, input integer long_bit_idx,
                    input integer long_cyc);
    begin
        token_packet_task(`PID_TYPE_IN, addr, endp, cyc, long_bit_idx, long_cyc);
    end
endtask

task setup_packet_task(input [6:0] addr, input [3:0] endp,
                       input integer cyc, input integer long_bit_idx,
                       input integer long_cyc);
    begin
        token_packet_task(`PID_TYPE_SETUP, addr, endp, cyc, long_bit_idx, long_cyc);
    end
endtask

// ---- sof_packet_task: 发送 SOF 包 ----
// 结构: SYNC + PID(SOF) + FrameNumber(11) + CRC5(5) + EOP
task sof_packet_task(input [10:0] frame_num,
                     input integer cyc, input integer long_bit_idx,
                     input integer long_cyc);
    integer i, bit_cnt;
    reg [4:0] c5;
    begin
        $display("tb: SOF frame=%d cyc=%0d long_bit=%0d(%0dcyc)",
                 frame_num, cyc, long_bit_idx, long_cyc);
        bit_cnt = 0;

        sync_task(cyc, long_bit_idx, long_cyc, bit_cnt);

        pid_task(`PID_TYPE_SOF, cyc, long_bit_idx - bit_cnt, long_cyc);
        bit_cnt = bit_cnt + 8;

        // Frame number (11bit, LSB first)
        for (i=0; i<11; i=i+1) begin
            bit_task(frame_num[i], (bit_cnt==long_bit_idx)? long_cyc : cyc);
            bit_cnt = bit_cnt + 1;
        end
        // CRC5 (5bit, MSB first: 取反值 c5[4] 先发)
        c5 = crc5_tx_11(frame_num);
        for (i=0; i<5; i=i+1) begin
            bit_task(c5[4-i], (bit_cnt==long_bit_idx)? long_cyc : cyc);   // MSB first
            bit_cnt = bit_cnt + 1;
        end

        eop_task;
    end
endtask

// ---- data_packet_task: 发送 Data 包 (DATA0/DATA1) ----
// 结构: SYNC + PID + payload(N byte, LSB first) + CRC16(16, MSB first) + EOP
// payload 最多 8 字节 (与 crc16_ref.vh 的 crc16_tx 签名一致)
task data_packet_task(input [3:0] pid_type,
                      input [7:0] b0, b1, b2, b3, b4, b5, b6, b7,
                      input [6:0] nbytes,
                      input integer cyc, input integer long_bit_idx,
                      input integer long_cyc);
    integer i, bit_cnt;
    reg [7:0] bytes [0:7];
    reg [15:0] tx_crc;
    begin
        $display("tb: DATA pid=%h nbytes=%0d cyc=%0d long_bit=%0d(%0dcyc)",
                 pid_type, nbytes, cyc, long_bit_idx, long_cyc);
        bytes[0]=b0; bytes[1]=b1; bytes[2]=b2; bytes[3]=b3;
        bytes[4]=b4; bytes[5]=b5; bytes[6]=b6; bytes[7]=b7;

        // 预计算 CRC16 发送值 (取反)
        tx_crc = crc16_tx(b0, b1, b2, b3, b4, b5, b6, b7, nbytes);

        bit_cnt = 0;
        sync_task(cyc, long_bit_idx, long_cyc, bit_cnt);

        pid_task(pid_type, cyc, long_bit_idx - bit_cnt, long_cyc);
        bit_cnt = bit_cnt + 8;

        // Payload (每字节 LSB first)
        for (i=0; i<nbytes; i=i+1) begin
            byte_task(bytes[i], cyc, long_bit_idx - bit_cnt, long_cyc);
            bit_cnt = bit_cnt + 8;
        end

        // CRC16 (16bit, MSB first)
        for (i=15; i>=0; i=i-1) begin
            bit_task(tx_crc[i], (bit_cnt==long_bit_idx)? long_cyc : cyc);
            bit_cnt = bit_cnt + 1;
        end

        eop_task;
    end
endtask

// ---- handshake_packet_task: 发送 Handshake 包 (ACK/NAK/STALL) ----
// 结构: SYNC + PID (无 CRC, 无数据) + EOP
task handshake_packet_task(input [3:0] pid_type,
                           input integer cyc, input integer long_bit_idx,
                           input integer long_cyc);
    integer bit_cnt;
    begin
        $display("tb: HSHAKE pid=%h cyc=%0d long_bit=%0d(%0dcyc)",
                 pid_type, cyc, long_bit_idx, long_cyc);
        bit_cnt = 0;

        sync_task(cyc, long_bit_idx, long_cyc, bit_cnt);
        pid_task(pid_type, cyc, long_bit_idx - bit_cnt, long_cyc);
        bit_cnt = bit_cnt + 8;

        eop_task;
    end
endtask

//============================================================================
// 每个 PID 独立封装任务 (补全, 对齐 out/in/setup 封装风格)
// 仅转发到通用 task + 对应 PID_TYPE_* 宏, 便于 tb 按包类型名字直接调用。
//============================================================================

// ---- data0_packet_task: DATA0 (PID type=3), 结构同 data_packet_task ----
task data0_packet_task(input [7:0] b0, b1, b2, b3, b4, b5, b6, b7,
                       input [6:0] nbytes,
                       input integer cyc, input integer long_bit_idx,
                       input integer long_cyc);
    begin
        data_packet_task(`PID_TYPE_DATA0, b0, b1, b2, b3, b4, b5, b6, b7,
                         nbytes, cyc, long_bit_idx, long_cyc);
    end
endtask

// ---- data1_packet_task: DATA1 (PID type=B), 结构同 data_packet_task ----
task data1_packet_task(input [7:0] b0, b1, b2, b3, b4, b5, b6, b7,
                       input [6:0] nbytes,
                       input integer cyc, input integer long_bit_idx,
                       input integer long_cyc);
    begin
        data_packet_task(`PID_TYPE_DATA1, b0, b1, b2, b3, b4, b5, b6, b7,
                         nbytes, cyc, long_bit_idx, long_cyc);
    end
endtask

// ---- ack_packet_task: ACK (仅 PID) ----
task ack_packet_task(input integer cyc, input integer long_bit_idx,
                     input integer long_cyc);
    begin
        handshake_packet_task(`PID_TYPE_ACK, cyc, long_bit_idx, long_cyc);
    end
endtask

// ---- nak_packet_task: NAK (仅 PID) ----
task nak_packet_task(input integer cyc, input integer long_bit_idx,
                     input integer long_cyc);
    begin
        handshake_packet_task(`PID_TYPE_NAK, cyc, long_bit_idx, long_cyc);
    end
endtask

// ---- stall_packet_task: STALL (仅 PID) ----
task stall_packet_task(input integer cyc, input integer long_bit_idx,
                       input integer long_cyc);
    begin
        handshake_packet_task(`PID_TYPE_STALL, cyc, long_bit_idx, long_cyc);
    end
endtask

// ---- nyet_packet_task: NYET (USB2.0 握手, 仅 PID) ----
// USB1.1 FS 设备不认 NYET, 用于验证接收端把"未知/保留 PID"当忽略处理。
task nyet_packet_task(input integer cyc, input integer long_bit_idx,
                      input integer long_cyc);
    begin
        handshake_packet_task(`PID_TYPE_NYET, cyc, long_bit_idx, long_cyc);
    end
endtask

// ---- pre_packet_task: PRE (Special 类, 仅 PID, 结构同单 PID 包) ----
// USB1.1 §7.1.7 低速前导: 主机以全速发 PRE, hub 随后把低速设备接到总线上;
// FS 设备不应响应。此处按 SYNC+PID+EOP 的单 PID 包建模(补码有效),
// 供验证接收端忽略 PRE / 或按保留 PID 处理。
task pre_packet_task(input integer cyc, input integer long_bit_idx,
                     input integer long_cyc);
    begin
        handshake_packet_task(`PID_TYPE_PRE, cyc, long_bit_idx, long_cyc);
    end
endtask

//============================================================================
// 坏包/错误注入变体 (供 SIE/deserial 容错验证)
// 参考 USB 1.1 §8.3 接收端健壮性: PID 校验 / CRC / 截断无 EOP / 超长溢出。
// 结构沿用对应合法包, 只对单一字段注入错误, 便于定向验证某条错误路径。
//============================================================================

// ---- bad_pid_packet_task: PID 校验错误 (补码高位翻转) ----
// 发 SYNC + 补码错误的 PID + EOP。低 4 位 type 保持原值, 高 4 位补码
// 翻转最高位 → 接收端 (PID[3:0] == ~PID[7:4]?) 校验失败, 应忽略整个包。
task bad_pid_packet_task(input [3:0] pid_type,
                         input integer cyc, input integer long_bit_idx,
                         input integer long_cyc);
    integer bit_cnt;
    reg [7:0] pid_byte;
    begin
        $display("tb: BADPID type=%h cyc=%0d long_bit=%0d(%0dcyc)",
                 pid_type, cyc, long_bit_idx, long_cyc);
        bit_cnt = 0;

        sync_task(cyc, long_bit_idx, long_cyc, bit_cnt);

        pid_byte = {~pid_type, pid_type};
        pid_byte[7] = ~pid_byte[7];              // 翻转补码最高位 -> 校验必失败
        byte_task(pid_byte, cyc, long_bit_idx - bit_cnt, long_cyc);
        bit_cnt = bit_cnt + 8;

        eop_task;
    end
endtask

// ---- token_badcrc_packet_task: Token 的 CRC5 错误 ----
// 与 token_packet_task 相同结构, 只是 CRC5 取反发送时全 5 位翻转, 保证错。
task token_badcrc_packet_task(input [3:0] pid_type, input [6:0] addr,
                              input [3:0] endp,
                              input integer cyc, input integer long_bit_idx,
                              input integer long_cyc);
    integer i, bit_cnt;
    reg [4:0] c5;
    begin
        $display("tb: TOKEN(badcrc) pid=%h addr=%d endp=%d cyc=%0d long_bit=%0d(%0dcyc)",
                 pid_type, addr, endp, cyc, long_bit_idx, long_cyc);
        bit_cnt = 0;

        sync_task(cyc, long_bit_idx, long_cyc, bit_cnt);

        pid_task(pid_type, cyc, long_bit_idx - bit_cnt, long_cyc);
        bit_cnt = bit_cnt + 8;

        for (i=0; i<7; i=i+1) begin
            bit_task(addr[i], (bit_cnt==long_bit_idx)? long_cyc : cyc);
            bit_cnt = bit_cnt + 1;
        end
        for (i=0; i<4; i=i+1) begin
            bit_task(endp[i], (bit_cnt==long_bit_idx)? long_cyc : cyc);
            bit_cnt = bit_cnt + 1;
        end
        c5 = crc5_tx(addr, endp) ^ 5'h1F;        // 全位翻转 -> CRC5 错
        for (i=0; i<5; i=i+1) begin
            bit_task(c5[4-i], (bit_cnt==long_bit_idx)? long_cyc : cyc);   // MSB first
            bit_cnt = bit_cnt + 1;
        end

        eop_task;
    end
endtask

// ---- sof_badcrc_packet_task: SOF 的 CRC5 错误 ----
task sof_badcrc_packet_task(input [10:0] frame_num,
                            input integer cyc, input integer long_bit_idx,
                            input integer long_cyc);
    integer i, bit_cnt;
    reg [4:0] c5;
    begin
        $display("tb: SOF(badcrc) frame=%d cyc=%0d long_bit=%0d(%0dcyc)",
                 frame_num, cyc, long_bit_idx, long_cyc);
        bit_cnt = 0;

        sync_task(cyc, long_bit_idx, long_cyc, bit_cnt);

        pid_task(`PID_TYPE_SOF, cyc, long_bit_idx - bit_cnt, long_cyc);
        bit_cnt = bit_cnt + 8;

        for (i=0; i<11; i=i+1) begin
            bit_task(frame_num[i], (bit_cnt==long_bit_idx)? long_cyc : cyc);
            bit_cnt = bit_cnt + 1;
        end
        c5 = crc5_tx_11(frame_num) ^ 5'h1F;      // 全位翻转 -> CRC5 错
        for (i=0; i<5; i=i+1) begin
            bit_task(c5[4-i], (bit_cnt==long_bit_idx)? long_cyc : cyc);   // MSB first
            bit_cnt = bit_cnt + 1;
        end

        eop_task;
    end
endtask

// ---- data_badcrc_packet_task: Data 的 CRC16 错误 ----
// 与 data_packet_task 相同结构, 只是 CRC16 取反发送时全 16 位翻转, 保证错。
task data_badcrc_packet_task(input [3:0] pid_type,
                             input [7:0] b0, b1, b2, b3, b4, b5, b6, b7,
                             input [6:0] nbytes,
                             input integer cyc, input integer long_bit_idx,
                             input integer long_cyc);
    integer i, bit_cnt;
    reg [7:0] bytes [0:7];
    reg [15:0] tx_crc;
    begin
        $display("tb: DATA(badcrc) pid=%h nbytes=%0d cyc=%0d long_bit=%0d(%0dcyc)",
                 pid_type, nbytes, cyc, long_bit_idx, long_cyc);
        bytes[0]=b0; bytes[1]=b1; bytes[2]=b2; bytes[3]=b3;
        bytes[4]=b4; bytes[5]=b5; bytes[6]=b6; bytes[7]=b7;

        tx_crc = crc16_tx(b0, b1, b2, b3, b4, b5, b6, b7, nbytes)
                 ^ 16'hFFFF;                     // 全位翻转 -> CRC16 错

        bit_cnt = 0;
        sync_task(cyc, long_bit_idx, long_cyc, bit_cnt);

        pid_task(pid_type, cyc, long_bit_idx - bit_cnt, long_cyc);
        bit_cnt = bit_cnt + 8;

        for (i=0; i<nbytes; i=i+1) begin
            byte_task(bytes[i], cyc, long_bit_idx - bit_cnt, long_cyc);
            bit_cnt = bit_cnt + 8;
        end
        for (i=15; i>=0; i=i-1) begin
            bit_task(tx_crc[i], (bit_cnt==long_bit_idx)? long_cyc : cyc);
            bit_cnt = bit_cnt + 1;
        end

        eop_task;
    end
endtask

// ---- token_noeop_packet_task: Token 截断 (发完 body, 不发 EOP) ----
// body (SYNC+PID+ADDR+ENDP+CRC5) 正常发出后直接回到总线 idle J,
// 不送 EOP 的 SE0 定界。接收端将按"无 EOP"处理 (依赖 SIE 字节计数中止/超时)。
task token_noeop_packet_task(input [3:0] pid_type, input [6:0] addr,
                             input [3:0] endp,
                             input integer cyc, input integer long_bit_idx,
                             input integer long_cyc);
    integer i, bit_cnt;
    reg [4:0] c5;
    begin
        $display("tb: TOKEN(noeop) pid=%h addr=%d endp=%d cyc=%0d long_bit=%0d(%0dcyc)",
                 pid_type, addr, endp, cyc, long_bit_idx, long_cyc);
        bit_cnt = 0;

        sync_task(cyc, long_bit_idx, long_cyc, bit_cnt);

        pid_task(pid_type, cyc, long_bit_idx - bit_cnt, long_cyc);
        bit_cnt = bit_cnt + 8;

        for (i=0; i<7; i=i+1) begin
            bit_task(addr[i], (bit_cnt==long_bit_idx)? long_cyc : cyc);
            bit_cnt = bit_cnt + 1;
        end
        for (i=0; i<4; i=i+1) begin
            bit_task(endp[i], (bit_cnt==long_bit_idx)? long_cyc : cyc);
            bit_cnt = bit_cnt + 1;
        end
        c5 = crc5_tx(addr, endp);
        for (i=0; i<5; i=i+1) begin
            bit_task(c5[4-i], (bit_cnt==long_bit_idx)? long_cyc : cyc);   // MSB first
            bit_cnt = bit_cnt + 1;
        end

        // 无 EOP: 不发 SE0, 让总线回到 idle J (截断包场景)
        rxdp = 1'b1; rxdn = 1'b0;
        nrzi_lv = 1'b1;
        #(EOP_J_TIME);
    end
endtask

// ---- data_noeop_packet_task: Data 截断 (发完 body, 不发 EOP) ----
task data_noeop_packet_task(input [3:0] pid_type,
                            input [7:0] b0, b1, b2, b3, b4, b5, b6, b7,
                            input [6:0] nbytes,
                            input integer cyc, input integer long_bit_idx,
                            input integer long_cyc);
    integer i, bit_cnt;
    reg [7:0] bytes [0:7];
    reg [15:0] tx_crc;
    begin
        $display("tb: DATA(noeop) pid=%h nbytes=%0d cyc=%0d long_bit=%0d(%0dcyc)",
                 pid_type, nbytes, cyc, long_bit_idx, long_cyc);
        bytes[0]=b0; bytes[1]=b1; bytes[2]=b2; bytes[3]=b3;
        bytes[4]=b4; bytes[5]=b5; bytes[6]=b6; bytes[7]=b7;

        tx_crc = crc16_tx(b0, b1, b2, b3, b4, b5, b6, b7, nbytes);

        bit_cnt = 0;
        sync_task(cyc, long_bit_idx, long_cyc, bit_cnt);

        pid_task(pid_type, cyc, long_bit_idx - bit_cnt, long_cyc);
        bit_cnt = bit_cnt + 8;

        for (i=0; i<nbytes; i=i+1) begin
            byte_task(bytes[i], cyc, long_bit_idx - bit_cnt, long_cyc);
            bit_cnt = bit_cnt + 8;
        end
        for (i=15; i>=0; i=i-1) begin
            bit_task(tx_crc[i], (bit_cnt==long_bit_idx)? long_cyc : cyc);
            bit_cnt = bit_cnt + 1;
        end

        // 无 EOP: 不发 SE0, 让总线回到 idle J (截断包场景)
        rxdp = 1'b1; rxdn = 1'b0;
        nrzi_lv = 1'b1;
        #(EOP_J_TIME);
    end
endtask

// ---- oversize_data_packet_task: 超长 Data (payload > 端点最大负载) ----
// SYNC + PID + nbytes 个填充字节(无 CRC16, 溢出中止发生在 CRC 校验前,
// 即 deserial 的 SIE 字节计数 > 该包类型/端点上限时) + EOP。
// nbytes 用 integer 不设 8B 上限, 可注入到 >64B 以测 EP 溢出/丢包。
task oversize_data_packet_task(input [3:0] pid_type, input [7:0] fill,
                               input integer nbytes,
                               input integer cyc, input integer long_bit_idx,
                               input integer long_cyc);
    integer i, bit_cnt;
    begin
        $display("tb: DATA(oversize) pid=%h nbytes=%0d cyc=%0d long_bit=%0d(%0dcyc)",
                 pid_type, nbytes, cyc, long_bit_idx, long_cyc);
        bit_cnt = 0;

        sync_task(cyc, long_bit_idx, long_cyc, bit_cnt);

        pid_task(pid_type, cyc, long_bit_idx - bit_cnt, long_cyc);
        bit_cnt = bit_cnt + 8;

        for (i=0; i<nbytes; i=i+1) begin
            byte_task(fill, cyc, long_bit_idx - bit_cnt, long_cyc);
            bit_cnt = bit_cnt + 8;
        end

        // 无 CRC16: 端点字节计数先溢出, CRC 校验不再到达
        eop_task;
    end
endtask

`endif
