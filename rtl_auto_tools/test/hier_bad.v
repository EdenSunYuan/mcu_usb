module leaf (input clk, input rstn, input d_in, output reg d_out);
    always @(posedge clk) d_out <= d_in & rstn;
endmodule

module parent_bad (input clk, input rstn, input d_in, output d_out);
    leaf u_leaf (.clk(clk), .rstx(rstn), .d_out(d_out));
endmodule
