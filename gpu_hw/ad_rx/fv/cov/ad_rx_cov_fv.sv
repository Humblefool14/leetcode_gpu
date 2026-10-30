// FPV harness: ad_rx_cov.  Bound assertions are in the module; here: opposite
// samples are negatives (s0 = -s3, s1 = -s2) and the deltas equal the exact
// offsets (-32A-96B, 96A-32B, ...).
module ad_rx_cov_fv (input logic clk, input logic rst_n, input logic load,
                     input logic [143:0] ab);
  logic [575:0] dlt; logic [143:0] lowm;
  ad_rx_cov u (.clk, .rst_n, .i_load(load), .i_ab(ab), .o_dlt(dlt), .o_lowm(lowm));
  logic f_init = 1'b1; logic [143:0] hab; logic hv;
  always @(posedge clk) begin
    f_init <= 1'b0;
    if (!rst_n) hv <= 0; else if (load) begin hab <= ab; hv <= 1; end
  end
  always @(*) if (f_init) assume (!rst_n);
  for (genvar e = 0; e < 3; e++) begin : g
    wire signed [47:0] A = 48'($signed(hab[48*e +: 24]));
    wire signed [47:0] B = 48'($signed(hab[48*e + 24 +: 24]));
    always @(posedge clk) if (!f_init && hv && rst_n) begin
      assert ($signed(dlt[48*(0+e) +: 48]) == -32*A - 96*B);
      assert ($signed(dlt[48*(3+e) +: 48]) ==  96*A - 32*B);
      assert ($signed(dlt[48*(6+e) +: 48]) == -96*A + 32*B);
      assert ($signed(dlt[48*(9+e) +: 48]) ==  32*A + 96*B);
    end
  end
endmodule
