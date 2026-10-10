module top_usb3 (
    input  wire        clk,
    input  wire        rstn,
    input  wire        d_in,
    input  wire        d_valid,
    output wire [15:0] crc16_out
);
    // INST: ../../src/common/usb_bit_stuff.v  u_stuff
    // INST: ../../src/common/usb_crc16.v  u_crc16  .d_in=d_out .crc_en=d_out_valid .crc_clr=1'b0
endmodule
