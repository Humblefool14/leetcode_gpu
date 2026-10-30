// FPV harness: ad_rx_f2fix.  Saturation bounds, sign, exact integers, monotonicity.
module ad_rx_f2fix_fv (input logic [31:0] f, input logic [31:0] g);
  logic [23:0] q, qg;
  ad_rx_f2fix u0 (.f(f), .q(q));
  ad_rx_f2fix u1 (.f(g), .q(qg));
  // monotone for two non-negative, non-NaN inputs
  wire fn = (f[30:23] == 8'hFF) && (f[22:0] != 0);
  wire gn = (g[30:23] == 8'hFF) && (g[22:0] != 0);
  always_comb begin
    if (!f[31] && !g[31] && !fn && !gn && f[30:0] <= g[30:0]) assert ($signed(q) <= $signed(qg));
    if (f == 32'h3F800000) assert (q == 24'd256);          // 1.0 -> 256 subpixels
    if (f == 32'hBF000000) assert (q == -24'sd128);        // -0.5 -> -128
  end
endmodule
