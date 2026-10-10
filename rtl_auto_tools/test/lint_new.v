// lint_new.v — 验证 [多驱动]/[未声明]/[锁存器?]/[风格] 新检查项
// 预期问题:
//   latch_a   : 两个 always 块驱动        → [多驱动]
//   w_multi1  : 两条 assign 驱动          → [多驱动]
//   latch_en  : 组合块 if 无 else         → [锁存器?]
//   rsrn      : rstn 拼写错误             → [未声明]
//   doutx     : assign LHS 未声明         → [未声明]
// 不应误报: cnt(单块多分支), i(genvar), bump(函数), dut.cnt(层次引用)
module style_demo (                    // 模块名≠文件名 → [风格]
    input  wire clk,
    input  wire rstn,
    output wire [3:0] dout
);
    reg  [3:0] cnt;
    reg        latch_a;
    reg        latch_en;
    wire       w_multi1;

    // 正常: 单 always 内 if/else 多分支 → 不应报多驱动
    always @(posedge clk or negedge rstn) begin
        if (!rstn)         cnt <= 4'd0;
        else if (cnt <= 9) cnt <= cnt + 4'd1;
        else               cnt <= 4'd0;
    end

    // [多驱动] 两个 always 块驱动同一 reg
    always @(posedge clk)  latch_a <= clk;
    always @(posedge rstn) latch_a <= ~clk;

    // [锁存器?] 组合块 if 无 else
    always @* begin
        if (cnt[0])
            latch_en = 1'b1;
    end

    // [多驱动] 两条 assign 驱动同一 wire
    assign w_multi1 = cnt[0];
    assign w_multi1 = cnt[1];

    // [未声明] 拼写错误 rsrn (rstn) / LHS doutx 未声明
    assign dout  = cnt + rsrn;
    assign doutx = cnt;

    // 以下均不应误报:
    genvar i;
    generate
        for (i = 0; i < 2; i = i + 1) begin : g_loop
            wire t = cnt[i];
        end
    endgenerate

    function [3:0] bump;
        input [3:0] x;
        begin
            bump = x + 4'd1;
        end
    endfunction

    wire [3:0] w_fn = bump(cnt);
    wire [3:0] w_hier = dut.cnt;      // 层次引用: dut./.cnt 都跳过
endmodule
