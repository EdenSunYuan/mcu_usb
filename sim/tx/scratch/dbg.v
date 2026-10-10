`timescale 1ns/1ps
module dbg;
  reg ref_clk=0, ref_rstn=0;
  always #(1000.0/48.0/2.0) ref_clk = ~ref_clk;
  reg [1:0] div; always @(posedge ref_clk or negedge ref_rstn) if(!ref_rstn) div<=0; else div<=div+1;
  wire clk = div[1];
  reg tx_active=0; reg [7:0] tx_data=8'hE1; reg tx_last=0;
  wire tx_ready, tx_done, tx_bit, tx_se0, tx_en;
  usb_tx_serial u (.clk12m(clk), .ref_rstn(ref_rstn), .tx_active(tx_active), .tx_data(tx_data),
                   .tx_last(tx_last), .tx_ready(tx_ready), .tx_done(tx_done), .tx_bit(tx_bit),
                   .tx_se0(tx_se0), .tx_en(tx_en));
  integer n=0; integer armed=0;
  always @(posedge clk) begin
    n = n + 1;
    if (tx_active && n > 4 && n < 40)
      $display("n=%0d st=%0d bit_cnt=%0d ones=%0d stf=%b sh=%b shreg=%02x bitout=%b en=%b bit=%b rdy=%b ld=%b bytend=%b",
        n, u.st_state, u.bit_cnt, u.ones_cnt, u.stuff_pend, u.shift_en, u.shift_reg, u.bit_out,
        tx_en, tx_bit, tx_ready, u.byte_load, u.data_end);
    if (tx_ready && armed==1) begin armed=2; tx_data=8'h07; end
    if (tx_ready && armed==0) armed=1;
  end
  initial begin
    #200; ref_rstn=1; #200;
    @(posedge clk); tx_active=1;
    #6000;
    $finish;
  end
endmodule
