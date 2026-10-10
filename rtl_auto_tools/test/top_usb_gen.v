//============================================
// 由 rtl_autogen.py gen 生成 — 顶层: test/top_usb.v
// 2 个实例, 3 条自动连线
//============================================

//---- 实例 u_stuff  (INST 注释在第 16 行) ----
    wire d_out;   // u_stuff.d_out 输出
    wire d_out_valid;   // u_stuff.d_out_valid 输出

usb_bit_stuff u_stuff (
        .clk          (clk),   // 时钟 / clock
        .rstn         (rstn),   // 异步复位 低有效 / async reset active-low
        .d_in         (d_in),   // 输入数据位 / input data bit
        .d_valid      (d_valid),   // 输入位有效 / input bit valid
        .d_out        (d_out),   // 输出数据位(含stuffed bit)
        .d_out_valid  (d_out_valid)
    );

//---- 实例 u_crc16  (INST 注释在第 17 行) ----
    wire [15:0] crc_out;   // u_crc16.crc_out 输出

usb_crc16 u_crc16 (
        .clk      (clk),   // 时钟/clock
        .rstn     (rstn),   // 异步复位,低有效/async reset, active-low
        .crc_en   (crc_en),   // 数据位有效(处理一位)/process one data bit
        .crc_clr  (crc_clr),   // 复位到种子全1/load seed (all-ones)
        .d_in     (d_in),   // 输入数据位(线上序)/data bit (wire order)
        .crc_out  (crc_out)
    );
