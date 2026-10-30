// ============================================================================
// ad_rx_fmul -- fp32 multiplier, combinational (RX arithmetic rules, see
// ad_rx_fadd).  One 24 x 24 unsigned mantissa product.
// ============================================================================
module ad_rx_fmul (
  input  logic [ad_rx_pkg::FP_W-1:0] a,
  input  logic [ad_rx_pkg::FP_W-1:0] b,
  output logic [ad_rx_pkg::FP_W-1:0] r
);
  logic        s;
  logic        za, zb, na, nb, ia, ib;
  logic [47:0] p;
  logic signed [10:0] e0;

  always_comb begin
    s  = a[31] ^ b[31];
    za = ad_rx_pkg::fp_zer(a);
    zb = ad_rx_pkg::fp_zer(b);
    na = ad_rx_pkg::fp_nan(a);
    nb = ad_rx_pkg::fp_nan(b);
    ia = ad_rx_pkg::fp_inf(a);
    ib = ad_rx_pkg::fp_inf(b);
    p  = {24'd0, 1'b1, a[22:0]} * {24'd0, 1'b1, b[22:0]};
    e0 = $signed({3'b000, a[30:23]}) + $signed({3'b000, b[30:23]}) - 11'sd127;
  end

  // normalise: p in [2^46, 2^48)
  logic [23:0] m;
  logic        g, st;
  logic signed [10:0] en;
  always_comb begin
    if (p[47]) begin
      m  = p[47:24];  g = p[23];  st = |p[22:0];  en = e0 + 11'sd1;
    end else begin
      m  = p[46:23];  g = p[22];  st = |p[21:0];  en = e0;
    end
  end

  // round to nearest even
  logic        rup;
  logic [24:0] mr;
  logic [22:0] frac;
  logic signed [10:0] ef;
  always_comb begin
    rup = g & (st | m[0]);
    mr  = {1'b0, m} + {24'd0, rup};
    if (mr[24]) begin frac = mr[23:1]; ef = en + 11'sd1; end
    else        begin frac = mr[22:0]; ef = en;          end
  end

  always_comb begin
    if (na || nb || (ia && zb) || (ib && za))
      r = ad_rx_pkg::FP_QNAN;
    else if (ia || ib)
      r = {s, 8'hFF, 23'd0};
    else if (za || zb)
      r = {s, 31'd0};
    else if (ef >= 11'sd255)
      r = {s, 8'hFF, 23'd0};
    else if (ef <= 11'sd0)
      r = {s, 31'd0};
    else
      r = {s, ef[7:0], frac};
  end

`ifdef FORMAL
  always_comb begin
    if (ad_rx_pkg::fp_nan(r)) assert (r == ad_rx_pkg::FP_QNAN);
    if (na || nb) assert (r == ad_rx_pkg::FP_QNAN);
    assert (!(r[30:23] == 8'd0 && r[22:0] != 23'd0));
    // sign is always the xor of the input signs unless NaN
    if (r != ad_rx_pkg::FP_QNAN) assert (r[31] == s);
    // x * 1.0 = x for normal x
    if (b == ad_rx_pkg::FP_ONE && !za && !na && !ia) assert (r == a);
    // x * 2.0 = x with exponent + 1 (normal, no overflow)
    if (b == 32'h4000_0000 && !za && !na && !ia && a[30:23] < 8'hFE)
      assert (r == {a[31], a[30:23] + 8'd1, a[22:0]});
    // 0 * inf = NaN
    if ((za && ib) || (zb && ia)) assert (r == ad_rx_pkg::FP_QNAN);
  end
`endif
endmodule
