//============================================================================
// top_usb.v — 顶层骨架示例 (供 rtl_autogen.py gen 使用)
//
// 写法约定: 在需要实例化的位置写  // INST: <子模块文件路径> [实例名]
//   路径相对本文件所在目录; 实例名缺省为 u_<模块名>。
//   gen 会解析子模块端口, 自动生成连线 wire 声明 + 命名端口实例化。
//============================================================================
module top_usb (
    input  wire        clk,
    input  wire        rstn,
    input  wire        d_in,        // 串行数据位 (来自 NRZI 解码)
    input  wire        d_valid,     // 位有效
    output wire [15:0] crc16_out    // CRC16 校验值
);

    // INST: ../../src/common/usb_bit_stuff.v  u_stuff
    // INST: ../../src/common/usb_crc16.v      u_crc16

endmodule
