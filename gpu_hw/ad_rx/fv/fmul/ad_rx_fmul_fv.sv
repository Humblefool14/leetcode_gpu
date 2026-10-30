// FPV harness: ad_rx_fmul.  Sign rule, x * 1 = x, x * 0 = +-0 (finite x),
// 0 * inf = NaN, |x * 2| exponent +1 (normal, no overflow), plus in-module asserts.
module ad_rx_fmul_fv (input logic [31:0] a, input logic [31:0] b);
  logic [31:0] r, r0, r2;
  ad_rx_fmul u0 (.i_a(a), .i_b(b), .o_r(r));
  ad_rx_fmul u1 (.i_a(a), .i_b(32'd0), .o_r(r0));
  ad_rx_fmul u2 (.i_a(a), .i_b(32'h40000000), .o_r(r2));
  wire a_nan = (a[30:23] == 8'hFF) && (a[22:0] != 0);
  wire a_inf = (a[30:23] == 8'hFF) && (a[22:0] == 0);
  always_comb begin
    if (!a_nan && !a_inf) assert (r0 == {a[31], 31'd0});
    if (a_inf) assert (r0 == 32'h7FC00000);
    if (a[30:23] != 0 && a[30:23] < 8'hFE) assert (r2 == {a[31], a[30:23] + 8'd1, a[22:0]});
  end
endmodule
