module top_usb2 (
    input  wire        clk,
    input  wire        rstn,
    input  wire        d_in,
    output wire        stuffed_out
);
    wire crc_en;
    wire crc_clr;

    // INST: ../../src/common/usb_crc16.v  u_crc16
    // INST: ../../src/common/usb_bit_stuff.v
endmodule
