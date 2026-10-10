//============================================================================
// case_out_normal.v — 正常 OUT token 回归
//
// 验证整链: SYNC 对齐(容 CDR 吃 SYNC 位) → 进 DATA → PID 为首字节 →
// 解填充 → 3 字节(addr+endp+crc5 共 16bit=2 字节) → EOP 干净关包 (err=0)。
//============================================================================

task case_out_normal;
    integer start_errs;
    begin
        start_errs = errors;
        $display("== deserial_out_normal: valid OUT token, expect clean close ==");

        out_packet_task(7'd5, 4'd0, 4, -1, 4);

        wait_close(1, 300);                 // 等帧关包
        dump_last_frame();

        if (close_cnt < 1) begin
            $display("    FAIL: no frame close observed");
            errors = errors + 1;
        end else begin
            if (last_err) begin
                $display("    FAIL: rx_error=1 at close on a GOOD packet");
                errors = errors + 1;
            end
            if (last_nbyte != 3) begin
                $display("    FAIL: expected 3 bytes, got %0d", last_nbyte);
                errors = errors + 1;
            end else begin
                if (last_bytes[0] !== 8'hE1) begin
                    $display("    FAIL: byte0 != PID(0xE1), got %02x", last_bytes[0]);
                    errors = errors + 1;
                end
            end
        end

        // 因果链打印 (2026-09-07: 仅证据, 不参与 pass/fail)
        if (close_cnt >= 1) begin
            causal_print("out_normal 正常关包", 0);
            causal_post("out_normal");
        end

        #(BIT_TIME * 10);
        if (errors == start_errs) $display("  PASS: case_out_normal");
        else                      $display("  FAIL: case_out_normal (%0d errors)", errors - start_errs);
    end
endtask
