// ============================================================================
// ad_rx_cov -- MSAA sample offsets of the three edges.
//
// For edge e with coefficients A, B (signed 15.8, E per subpixel step) the
// standard 4x locations are (-32,-96), (96,-32), (-96,32), (32,96) subpixels
// from the pixel centre, so the edge changes by
//     sample 0: -P   sample 1: +Q   sample 2: -Q   sample 3: +P
//     P = 32A + 96B,  Q = 96A - 32B           (shifts and adds only)
// All four offsets of all three edges are registered at i_load and held for
// the whole triangle, so ad_rx_scan evaluates 16 samples per quad in one
// cycle (the earlier sequential i_start / i_step interface is gone).
//
// o_lowm[e] = the bits below the top set bit of |P| | |Q|, all ones: a
// power-of-two-minus-one bound with |offset| <= o_lowm, used by
// ad_rx_coarse / ad_rx_scan to skip and accept conservatively.
// With one sample (i_ms = 0) the offsets and lowm are 0.
// ============================================================================
module ad_rx_cov #(
  parameter int AW = ad_rx_pkg::FIX_W,     // A, B width
  parameter int EW = ad_rx_pkg::EDGE_W     // edge value width
) (
  input  logic                    clk,
  input  logic                    rst_n,
  input  logic                    i_load,
  input  logic                    i_ms,          // 4 samples
  input  logic [3*2*AW-1:0]       i_ab,          // edge e: {B, A} at 2*AW*e
  output logic [3*4*EW-1:0]       o_off,         // edge e, sample s at EW*(4e+s)
  output logic [3*EW-1:0]         o_lowm         // edge e at EW*e
);
  localparam int NE = ad_rx_pkg::NEDGE;

  logic signed [EW-1:0] p [NE];
  logic signed [EW-1:0] q [NE];
  logic        [EW-1:0] lm [NE];
  logic        [EW-1:0] ap, aq, orr;

  logic signed [EW-1:0] ea [NE];
  logic signed [EW-1:0] eb [NE];
  always_comb begin
    for (int e = 0; e < NE; e++) begin
      ea[e] = EW'($signed(i_ab[2*AW*e      +: AW]));
      eb[e] = EW'($signed(i_ab[2*AW*e + AW +: AW]));
      p[e] = (ea[e] <<< 5) + (eb[e] <<< 6) + (eb[e] <<< 5);   // 32A + 96B
      q[e] = (ea[e] <<< 6) + (ea[e] <<< 5) - (eb[e] <<< 5);   // 96A - 32B
    end
  end

  // lowm: smear the top set bit of |P| | |Q| downwards
  always_comb begin
    for (int e = 0; e < NE; e++) begin
      ap  = p[e][EW-1] ? EW'(-p[e]) : p[e];
      aq  = q[e][EW-1] ? EW'(-q[e]) : q[e];
      orr = ap | aq;
      for (int i = 1; i < EW; i = i * 2)
        orr = orr | (orr >> i);
      lm[e] = orr;                    // all ones from the top set bit down
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      o_off  <= '0;
      o_lowm <= '0;
    end else if (i_load) begin
      for (int e = 0; e < NE; e++) begin
        o_off[EW*(4*e+0) +: EW] <= i_ms ? EW'(-p[e]) : '0;
        o_off[EW*(4*e+1) +: EW] <= i_ms ? q[e]       : '0;
        o_off[EW*(4*e+2) +: EW] <= i_ms ? EW'(-q[e]) : '0;
        o_off[EW*(4*e+3) +: EW] <= i_ms ? p[e]       : '0;
        o_lowm[EW*e +: EW]      <= i_ms ? lm[e]      : '0;
      end
    end
  end

`ifdef FORMAL
  logic f_past = 1'b0;
  always_ff @(posedge clk) f_past <= 1'b1;
  initial assume (!rst_n);
  // A, B are snapped-coordinate differences: |A|, |B| < 2^23
  always_comb for (int e = 0; e < NE; e++) begin
    assume ($signed(i_ab[2*AW*e +: AW])      > -(1 <<< 23));
    assume ($signed(i_ab[2*AW*e + AW +: AW]) > -(1 <<< 23));
  end
  always_ff @(posedge clk) if (f_past && rst_n) begin
    for (int e = 0; e < NE; e++) begin
      // the four offsets pair up as opposites (P, Q symmetric locations)
      assert ($signed(o_off[EW*(4*e+0) +: EW]) == -$signed(o_off[EW*(4*e+3) +: EW]));
      assert ($signed(o_off[EW*(4*e+1) +: EW]) == -$signed(o_off[EW*(4*e+2) +: EW]));
      // lowm bounds every offset and is of the form 2^k - 1
      for (int s = 0; s < 4; s++) begin
        assert ($signed(o_off[EW*(4*e+s) +: EW]) <=  $signed(o_lowm[EW*e +: EW]));
        assert ($signed(o_off[EW*(4*e+s) +: EW]) >= -$signed(o_lowm[EW*e +: EW]));
      end
      assert ((o_lowm[EW*e +: EW] & (o_lowm[EW*e +: EW] + EW'(1))) == '0);
      assert (!o_lowm[EW*e + EW - 1]);
    end
  end
  always_ff @(posedge clk) if (f_past && rst_n && $past(rst_n) && !$past(i_load))
    assert (o_off == $past(o_off) && o_lowm == $past(o_lowm));
  always_ff @(posedge clk) if (rst_n) cover (o_lowm[EW-1:0] != '0);
`endif
endmodule
