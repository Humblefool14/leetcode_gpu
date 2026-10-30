// FPV harness: ad_rx_fadd.  Commutativity (two instances), a - a = +0,
// a + 0 = a, inf - inf = NaN, plus the in-module assertions.
module ad_rx_fadd_fv (input logic [31:0] a, input logic [31:0] b);
  logic [31:0] r_ab, r_ba, r_aa, r_a0;
  ad_rx_fadd u0 (.i_a(a), .i_b(b), .i_sub(1'b0), .o_r(r_ab));
  ad_rx_fadd u1 (.i_a(b), .i_b(a), .i_sub(1'b0), .o_r(r_ba));
  ad_rx_fadd u2 (.i_a(a), .i_b(a), .i_sub(1'b1), .o_r(r_aa));
  ad_rx_fadd u3 (.i_a(a), .i_b(32'd0), .i_sub(1'b0), .o_r(r_a0));
  wire a_nan = (a[30:23] == 8'hFF) && (a[22:0] != 0);
  wire a_inf = (a[30:23] == 8'hFF) && (a[22:0] == 0);
  wire a_den = (a[30:23] == 8'h00);
  always_comb begin
    // a + b == b + a: the general case is the in-module ordering check (the
    // same operand bundle for (a, b) and (b, a)); here the equal and special cases
    if (a == b) assert (r_ab == r_ba);
    if (a[30:23] == 8'hFF || b[30:23] == 8'hFF || a[30:23] == 0 || b[30:23] == 0) assert (r_ab == r_ba);
    if (!a_nan && !a_inf) assert (r_aa == 32'd0);           // a - a == +0
    if (a_inf) assert (r_aa == 32'h7FC00000);               // inf - inf == NaN
    if (!a_nan && !a_den) assert (r_a0 == a);               // a + 0 == a
    if (a_den) assert (r_a0 == {a[31], 31'd0} || r_a0 == 32'd0);
  end
endmodule
