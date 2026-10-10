`timescale 1ns/1ps
module t;
  reg tx_bit=1, tx_se0=0, tx_en=0;
  wire rxdp, rxdn;
  phy_model u (.tx_bit(tx_bit), .tx_se0(tx_se0), .tx_en(tx_en), .rxdp(rxdp), .rxdn(rxdn));
  initial begin
    #1 $display("z        dp=%b dn=%b (expect 1/0 J)", rxdp, rxdn);
    tx_en=1; tx_bit=1; tx_se0=0; #1 $display("drv J    dp=%b dn=%b (expect 1/0)", rxdp, rxdn);
    tx_bit=0; #1 $display("drv K    dp=%b dn=%b (expect 0/1)", rxdp, rxdn);
    tx_se0=1; tx_bit=1; #1 $display("drv SE0  dp=%b dn=%b (expect 0/0)", rxdp, rxdn);
    tx_en=0; tx_se0=0; #1 $display("back z   dp=%b dn=%b (expect 1/0)", rxdp, rxdn);
    $finish;
  end
endmodule
