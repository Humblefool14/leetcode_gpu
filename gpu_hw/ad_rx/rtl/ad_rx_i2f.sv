// ============================================================================
// ad_rx_i2f -- signed W-bit integer over 2^F -> fp32, round to nearest even.
// Exact whenever |v| < 2^24.  0 -> +0.
// Fixes vs atg: v = -2^(W-1) is handled; W may exceed 24 (the setup's DF, a
// 48-bit area, is rounded; atg could only convert W <= 23 exactly).
// ============================================================================
module ad_rx_i2f #(
  parameter int W = 17,           // input bits, sign included (2..64)
  parameter int F = 0             // fraction bits of the input
) (
  input  logic [W-1:0] v,
  output logic [31:0]  f
);
  localparam int NW = (W < 26) ? 26 : W;           // working width >= 24 + guard + sticky

  logic          s;
  logic [W-1:0]  a;                                // |v| (W bits hold 2^(W-1))
  assign s = v[W-1];
  assign a = s ? (~v + 1'b1) : v;

  logic [6:0] msb;
  always_comb begin
    msb = '0;
    for (int k = 0; k < W; k++) if (a[k]) msb = 7'(k);
  end

  logic [NW-1:0] n;                                // leading one at bit NW-1
  assign n = {{(NW-W){1'b0}}, a} << (7'(NW - 1) - msb);

  logic [23:0] sig;
  logic        g, st, rup;
  logic [24:0] rnd;
  assign sig = n[NW-1 -: 24];
  assign g   = n[NW-25];
  assign st  = (NW > 25) ? (n[NW-26:0] != '0) : 1'b0;
  assign rup = g & (st | sig[0]);
  assign rnd = {1'b0, sig} + {24'd0, rup};

  logic [8:0] ex;
  assign ex = 9'd127 + {2'd0, msb} - 9'(F) + {8'd0, rnd[24]};
  assign f = (a == '0) ? 32'd0 : {s, ex[7:0], rnd[24] ? rnd[23:1] : rnd[22:0]};

`ifdef FORMAL
  always_comb if (v != '0) assert (f[31] == v[W-1] && f[30:23] != 8'd0);
`endif
endmodule
