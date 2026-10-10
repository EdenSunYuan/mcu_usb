// 测试用例: 覆盖 lint 的各类边界情况
// 预期问题:
//   w_unused   : 有驱动但未被读取 → [未使用]
//   w_dead     : 无驱动且未使用   → [未驱动且未使用]
//   r_nodrv    : reg 无驱动       → [未驱动]
//   o_nc       : output 端口无驱动 → [未驱动]
//   i_never    : input 端口未被读取 → [未使用]
// 正常信号: w_ok, cnt, mem, w_cmp (不应误报)
module tb_edge (
    input  wire       clk,
    input  wire       rstn,
    input  wire [7:0] din,
    input  wire       i_never,          // 埋雷: 从不使用
    output wire [7:0] dout,
    output wire       o_nc              // 埋雷: 无驱动
);
    wire [7:0] w_ok    = din;         // 声明即赋值 + 被读取 → 正常
    wire [7:0] w_unused = ~din;       // 有驱动, 无人读 → 未使用
    wire [7:0] w_dead;                // 什么都没有 → 未驱动且未使用
    reg  [7:0] r_nodrv;               // reg 无任何赋值 → 未驱动
    reg  [3:0] cnt;
    reg  [7:0] mem [0:3];             // 存储器
    wire       w_cmp;

    // 比较运算 <= 出现在 if 条件里, 不应把 cnt 判成"再次驱动"造成误报
    always @(posedge clk or negedge rstn) begin
        if (!rstn)
            cnt <= 4'd0;
        else if (cnt <= 4'd9)         // 比较, 不是赋值
            cnt <= cnt + 4'd1;
        else
            cnt <= 4'd0;
    end

    // 拼接赋值 + 索引读取
    always @(posedge clk) begin
        mem[cnt[1:0]] <= {din[3:0], cnt};
    end

    // 字符串里含 "x = y" 字样, 不应把 x/y 计为驱动或读取
    always @(*) begin
        $display("debug: w_dead = %h cnt = %h", w_dead, cnt);
        w_cmp = (cnt <= 4'd5);        // 阻塞赋值, RHS 是比较
    end

    assign dout = w_ok ^ mem[0][7:4];
endmodule

// 非 ANSI 风格端口
module legacy_style (a, b, y);
    input  a;
    output b;
    input  [3:0] c_unused_in_hdr;     // 端口表里没有, 仅体内声明, 不算端口
    wire t = a;
    assign b = t;
endmodule
