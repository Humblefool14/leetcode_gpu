// FPV harness: ad_rx_f2un.  floor <= ceil <= floor + 1; ends exact; monotone.
module ad_rx_f2un_fv (input logic [31:0] f, input logic [31:0] g);
  logic [15:0] dn, up, dg;
  ad_rx_f2un #(.RUP(0)) u0 (.f(f), .u(dn));
  ad_rx_f2un #(.RUP(1)) u1 (.f(f), .u(up));
  ad_rx_f2un #(.RUP(0)) u2 (.f(g), .u(dg));
  always_comb begin
    assert (dn <= up);
    assert (up - dn <= 16'd1);
    if (f == 32'h3F800000) assert (dn == 16'hFFFF);
    if (f == 32'h0) assert (up == 16'h0);
    if (!f[31] && !g[31] && f[30:23] != 8'hFF && g[30:23] != 8'hFF && f <= g) assert (dn <= dg);
  end
endmodule
