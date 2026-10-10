//============================================================================
// case_roundtrip.v — NRZI enc→dec 回环测试
//
// 测试目的: 验证 encoder + decoder 串联能正确恢复原始数据
//   发送随机 16-bit 序列进编码器，编码器输出直连解码器输入，
//   检查解码器输出是否与原始序列一致。
//
// 预期结果: dec_out == 原始序列
//============================================================================

task case_roundtrip;
    integer i;
    reg [15:0] seq;
    reg [15:0] dec_out;
    begin
        $display("== case_roundtrip: enc->dec round-trip ==");

        seq = 16'b1010_1100_1110_0101;  // 随机位序列

        enc_rst = 1; @(posedge clk); #1; enc_rst = 0;
        dec_rst = 1; @(posedge clk); #1; dec_rst = 0;

        for (i = 0; i < 16; i = i + 1) begin
            d_in_enc = seq[i];
            enc_en   = 1;
            @(posedge clk);
            #1;
            enc_en   = 0;

            // 编码器输出直连解码器输入
            nrzi_in = nrzi_out;
            dec_en  = 1;
            @(posedge clk);
            #1;
            dec_en  = 0;
            dec_out[i] = d_out;
        end

        if (dec_out !== seq) begin
            $display("FAIL(rt): dec_out=%016b exp=%016b", dec_out, seq);
            errors = errors + 1;
        end

        $display("  case_roundtrip done");
    end
endtask
