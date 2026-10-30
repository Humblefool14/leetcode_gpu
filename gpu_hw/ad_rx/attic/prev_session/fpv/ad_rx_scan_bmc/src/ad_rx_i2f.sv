// ============================================================================
// ad_rx_i2f -- signed fixed point (W bits, F fraction bits) to fp32,
// combinational.
//
//   f = v / 2^F, rounded to nearest even when |v| needs more than 24
//   significant bits (W > 25); exact otherwise.  0 gives +0.
//
// Users: ad_rx_bary (W 21, F 3: lane i, j in eighths), ad_rx_scan (W 17, F 0),
// ad_rx_frag (W 17, F 0), ad_rx_edge (W 50, F 0: deltas and the area D,
// which can exceed 24 bits -- the rounding path exists for it).
// Range: v = -2^(W-1) is allowed (|v| computed in W+1 bits).
// ============================================================================
module ad_rx_i2f #(
  parameter int W = 17,
  parameter int F = 0
) (
  input  logic [W-1:0]               v,
  output logic [ad_rx_pkg::FP_W-1:0] f
);
  localparam int AW = W + 1;              // |v| width incl. -2^(W-1)
  localparam int NW = (AW > 27) ? AW : 27;  // normalised width (>= 24+G+R+S)

  logic          s;
  logic [AW-1:0] mag;
  logic [$clog2(NW+1)-1:0] lz;
  logic [NW-1:0] nrm;
  logic          rup;
  logic [24:0]   mr;
  logic signed [12:0] e;

  always_comb begin
    s   = v[W-1];
    mag = s ? (AW'(0) - {v[W-1], v}) : {1'b0, v};
    // leading zeros of mag, counted in NW bits
    lz = '0;
    for (int i = 0; i < AW; i++)
      if (mag[i]) lz = ($clog2(NW+1))'(NW - 1 - i);
    nrm = {{(NW-AW){1'b0}}, mag} << lz;           // leading one at NW-1
    // 24 significant bits nrm[NW-1 -: 24], guard nrm[NW-25], sticky below
    if (NW > 26) begin
      rup = nrm[NW-25] & ((|(nrm & ((NW'(1) << (NW-25)) - NW'(1)))) | nrm[NW-24]);
    end else begin
      rup = 1'b0;
    end
    mr = {1'b0, nrm[NW-1 -: 24]} + {24'd0, rup};
    // value = 1.xxx * 2^(NW-1-lz-F)
    e  = 13'sd127 + 13'(NW - 1 - F) - $signed({1'b0, 12'(lz)});
    if (mr[24]) e = e + 13'sd1;
    if (mag == '0)
      f = 32'd0;
    else if (e <= 13'sd0)
      f = {s, 31'd0};                              // only for huge F
    else if (e >= 13'sd255)
      f = {s, 8'hFF, 23'd0};                       // only for W > 128
    else
      f = {s, e[7:0], mr[24] ? mr[23:1] : mr[22:0]};
  end

`ifdef FORMAL
  // exactness for narrow inputs: converting back gives v (checked by the
  // reference-model simulation for all W used); here: sign and zero rules
  always_comb begin
    if (v == '0) assert (f == 32'd0);
    if (v != '0) assert (f[31] == v[W-1]);
    if (v != '0) assert (f[30:23] != 8'd0);
    // a power of two converts to a zero fraction
    if (v == W'(1)) assert (f == {1'b0, 8'(127 - F), 23'd0});
  end
`endif
endmodule
