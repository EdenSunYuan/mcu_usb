//============================================================================
// case_tail7.v — 末数据阶段贴着 EOP SE0 的长 run 边界形态
//
// USB 发送 LSB first: 字节值 vs 线上位序
//   0xFE (1111_1110) → 线上 0,1,1,1,1,1,1,1 = "1个0 + 7个1"(7连1收尾)
//   0x7F (0111_1111) → 线上 1,1,1,1,1,1,1,0 = "7个1 + 1个0"
//   0xFC (1111_1100) → 线上 0,0,1,1,1,1,1,1 = "2个0 + 6个1"(6连1收尾贴SE0)
//
// 4 个子例 (默认全跑; 可用 +sub=A|B|C|D 只跑单个, 用于分窗看波形):
//   A: 0xFE 正常填充 → 末字节原样 0xFE, err=0   ("1个0+7个1", 填充把 run 拆开)
//   B: 0xFE 不插填充  → 真 7 连 1 贴 EOP → err=1 (7 连 1 = 违规)
//   C: 0xFC 不插填充  → SE0 前恰 6 个连续 1, err=0 (直尾仅 6 连 1, 无第 7 个 1;
//                       门控须保证 SE0 不被误判为第 7 个 1 → 干净关闭, 恢复 0xFC)
//   D: 0x7F 不插填充  → 违规 → err=1
//
// 说明: ones 计数跨字节边界连续 (规范)。B/D 的 7 连 1 会叠上 PID 尾部的 1。
// C 里 0xFC 开头 b0=0 把 PID 尾的 1 清掉, 故是"恰好" 6 连 1 顶 SE0 (无第 7 个)。
// 合规发射本应在 6 连 1 之后、EOP 之前插 stuffed 0; C 故意不插, 检验门控鲁棒性。
//============================================================================

// ---- 无填充发一字节 (LSB first, 每 bit 标称 4 周期): 用于构造真 7 连 1 ----
task raw_byte_nostuff(input [7:0] bval);
    integer k;
    begin
        for (k = 0; k < 8; k = k + 1) begin
            if (bval[k] == 1'b0) nrzi_lv = ~nrzi_lv;   // 数据 0 → 跳变
            drive_dpdn(nrzi_lv, BIT_TIME);             // 保持 1 bit (1=无跳变)
        end
    end
endtask

// ---- 驱动一帧并校验: SYNC+PID(E1)+末字节 bval +EOP ----
// stuffed=1 走 byte_task(带填充), stuffed=0 走 raw_byte_nostuff(不插填充)。
// exp_err=0 → 期望干净: err=0, nbyte=2, 恢复 [E1, bval];
// exp_err=1 → 期望报错: err=1 (真 7 连 1 违规)。
// (C: 不插填充但只到 6 连 1 → 非"7连1违规", 门控应使其干净关闭 → exp_err=0。)
task run_tail7_byte(input [7:0] bval, input stuffed, input integer exp_err,
                    input [8*2:0] tag);
    integer start_errs, frame_before, _bc;
    begin
        start_errs = errors;
        frame_before = close_cnt;
        _bc = 0;
        sync_task(4, -1, 4, _bc);            // SYNC → 进 DATA
        pid_task(`PID_TYPE_OUT, 4, -1, 4);   // byte0 = E1 (发完在字节边界)
        if (stuffed)
            byte_task(bval, 4, -1, 4);       // 正常填充 (第 6 个连续 1 后插 stuffed 0)
        else
            raw_byte_nostuff(bval);          // 不插填充 (构造贴 EOP 的连 1/连 0 直尾)
        eop_task;                            // 真 EOP
        wait_close(frame_before + 1, 300);

        $write("    %0s(0x%02x %0s): close@%0t nbyte=%0d err=%0d bytes=",
               tag, bval, stuffed ? "stuffed" : "nostuff",
               last_close_t, last_nbyte, last_err);
        for (_bc = 0; _bc < last_nbyte; _bc = _bc + 1) $write("%02x ", last_bytes[_bc]);
        $write("\n");

        if (exp_err == 0) begin
            if (last_err !== 1'b0) begin
                $display("    FAIL: %0s err=%0d, expected 0 (tail must close clean)", tag, last_err);
                errors = errors + 1;
            end
            if (last_nbyte != 2) begin
                $display("    FAIL: %0s nbyte=%0d, expected 2", tag, last_nbyte);
                errors = errors + 1;
            end else if (last_bytes[0] !== 8'hE1 || last_bytes[1] !== bval) begin
                $display("    FAIL: %0s bytes = %02x %02x, expected E1 %02x",
                         tag, last_bytes[0], last_bytes[1], bval);
                errors = errors + 1;
            end
        end else begin
            if (last_err !== 1'b1) begin
                $display("    FAIL: %0s err=%0d, expected 1 (real 7-ones at tail must flag)", tag, last_err);
                errors = errors + 1;
            end
        end
        #(BIT_TIME * 6);
    end
endtask

task case_tail7;
    integer start_errs;
    reg [8*8:0] wsub;
    reg run_a, run_b, run_c, run_d;
    begin
        start_errs = errors;
        wsub = "";
        if (!$value$plusargs("sub=%s", wsub)) ;     // "A"~"D", 缺省 = 4 个都跑
        run_a = 1'b1; run_b = 1'b1; run_c = 1'b1; run_d = 1'b1;
        if      (wsub == "A") begin run_b = 1'b0; run_c = 1'b0; run_d = 1'b0; end
        else if (wsub == "B") begin run_a = 1'b0; run_c = 1'b0; run_d = 1'b0; end
        else if (wsub == "C") begin run_a = 1'b0; run_b = 1'b0; run_d = 1'b0; end
        else if (wsub == "D") begin run_a = 1'b0; run_b = 1'b0; run_c = 1'b0; end
        $display("== deserial_tail7: last data vs EOP SE0 — A:0xFE填充 B:0xFE七1违规 C:0xFC六1直尾 D:0x7F七1违规, sub=%0s ==",
                 wsub);

        if (run_a) run_tail7_byte(8'hFE, 1, 0, "A");
        if (run_b) run_tail7_byte(8'hFE, 0, 1, "B");
        if (run_c) run_tail7_byte(8'hFC, 0, 0, "C");
        if (run_d) run_tail7_byte(8'h7F, 0, 1, "D");

        if (errors == start_errs)
            $display("  PASS: case_tail7 (A clean / C 6-ones-tail clean / B,D 7-ones flagged)");
        else
            $display("  FAIL: case_tail7 (%0d errors)", errors - start_errs);
    end
endtask
