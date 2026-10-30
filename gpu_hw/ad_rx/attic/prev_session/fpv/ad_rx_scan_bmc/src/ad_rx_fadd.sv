// ============================================================================
// ad_rx_fadd -- fp32 adder / subtractor, combinational.
//
//   r = a + (sub ? -b : b)
//
// RX arithmetic rules (shared by fadd/fmul/fdiv):
//   * round to nearest, ties to even
//   * denormal inputs read as zero, denormal results flushed to zero
//     (sign kept); "denormal result" = below 2^-126 after rounding with an
//     unbounded exponent
//   * NaN results are the canonical 0x7FC00000; infinities follow IEEE
//   * exact cancellation gives +0; (-0) + (-0) = -0
// ============================================================================
module ad_rx_fadd (
  input  logic [ad_rx_pkg::FP_W-1:0] a,
  input  logic [ad_rx_pkg::FP_W-1:0] b,
  input  logic                       sub,
  output logic [ad_rx_pkg::FP_W-1:0] r
);
  localparam int FW = ad_rx_pkg::FP_W;
  localparam int XW = 27;               // 1 + 23 + guard, round, sticky

  logic        sa, sb;
  logic [7:0]  ea, eb;
  logic [23:0] ma, mb;
  logic        za, zb, na, nb, ia, ib;

  always_comb begin
    sa = a[31];
    sb = b[31] ^ sub;
    ea = a[30:23];
    eb = b[30:23];
    za = ad_rx_pkg::fp_zer(a);
    zb = ad_rx_pkg::fp_zer(b);
    na = ad_rx_pkg::fp_nan(a);
    nb = ad_rx_pkg::fp_nan(b);
    ia = ad_rx_pkg::fp_inf(a);
    ib = ad_rx_pkg::fp_inf(b);
    ma = {1'b1, a[22:0]};
    mb = {1'b1, b[22:0]};
  end

  // ---- order by magnitude: x is the larger operand ------------------------
  logic        swap;
  logic        sx, sy;
  logic [7:0]  ex, ey;
  logic [23:0] mx, my;
  always_comb begin
    swap = {eb, mb} > {ea, ma};
    sx = swap ? sb : sa;   sy = swap ? sa : sb;
    ex = swap ? eb : ea;   ey = swap ? ea : eb;
    mx = swap ? mb : ma;   my = swap ? ma : mb;
  end

  // ---- align y to x with sticky -------------------------------------------
  logic [7:0]    d;
  logic [XW-1:0] xx, yy;
  logic [XW+23:0] ywide;
  always_comb begin
    d     = ex - ey;
    xx    = {mx, 3'b000};
    ywide = {my, 3'b000, 24'd0} >> d;      // 51 bits: shifted-out bits kept
    if (d >= 8'd27)
      yy = {{(XW-1){1'b0}}, 1'b1};         // whole y is sticky (y != 0 here)
    else
      yy = {ywide[XW+23:25], ywide[24] | (|ywide[23:0])};
  end

  // ---- add / subtract -------------------------------------------------------
  logic          eff_sub;
  logic [XW:0]   sum;        // 28 bits
  always_comb begin
    eff_sub = sx ^ sy;
    sum = eff_sub ? ({1'b0, xx} - {1'b0, yy}) : ({1'b0, xx} + {1'b0, yy});
  end

  // ---- normalise ------------------------------------------------------------
  logic [4:0]    lz;
  logic [XW-1:0] nrm;
  logic signed [10:0] en;     // unbounded exponent
  always_comb begin
    lz = 5'd0;
    for (int i = 0; i < XW; i++)
      if (sum[i]) lz = 5'(XW - 1 - i);
    if (sum[XW]) begin
      nrm = {sum[XW:2], sum[1] | sum[0]};
      en  = $signed({3'b000, ex}) + 11'sd1;
    end else begin
      nrm = sum[XW-1:0] << lz;
      en  = $signed({3'b000, ex}) - $signed({6'd0, lz});
    end
  end

  // ---- round to nearest even ----------------------------------------------
  logic        rup;
  logic [24:0] mr;
  logic signed [10:0] ef;
  logic [22:0] frac;
  always_comb begin
    rup  = nrm[2] & (nrm[1] | nrm[0] | nrm[3]);
    mr   = {1'b0, nrm[26:3]} + {24'd0, rup};
    if (mr[24]) begin
      frac = mr[23:1];
      ef   = en + 11'sd1;
    end else begin
      frac = mr[22:0];
      ef   = en;
    end
  end

  // ---- result selection -----------------------------------------------------
  always_comb begin
    if (na || nb || (ia && ib && (sa != sb)))
      r = ad_rx_pkg::FP_QNAN;
    else if (ia)
      r = {sa, 8'hFF, 23'd0};
    else if (ib)
      r = {sb, 8'hFF, 23'd0};
    else if (za && zb)
      r = {sa & sb, 31'd0};
    else if (zb)
      r = a;                                   // a is normal here
    else if (za)
      r = {sb, b[30:0]};
    else if (sum == '0)
      r = 32'd0;                               // exact cancellation: +0
    else if (ef >= 11'sd255)
      r = {sx, 8'hFF, 23'd0};
    else if (ef <= 11'sd0)
      r = {sx, 31'd0};                         // flush
    else
      r = {sx, ef[7:0], frac};
  end

`ifdef FORMAL
  // ---------------------------------------------------------------- FPV ----
  // Combinational unit: properties are immediate assertions.
  always_comb begin
    // canonical NaN is the only NaN produced
    if (ad_rx_pkg::fp_nan(r)) assert (r == ad_rx_pkg::FP_QNAN);
    // NaN in -> NaN out
    if (na || nb) assert (r == ad_rx_pkg::FP_QNAN);
    // never a denormal out
    assert (!(r[30:23] == 8'd0 && r[22:0] != 23'd0));
    // x + 0 = x for normal x
    if (!za && !na && !ia && zb) assert (r == a);
    // x - x = +0 for finite x
    if (!na && !ia && sub && (a == b)) assert (r == 32'd0);
    // inf + finite = inf, sign of the inf
    if (ia && !nb && !ib) assert (r == {sa, 8'hFF, 23'd0});
    // sign of a non-zero finite result is the sign of the larger magnitude
    if (!na && !nb && !ia && !ib && r[30:0] != 31'd0 && r[30:23] != 8'hFF)
      assert (r[31] == sx);
  end
`endif
endmodule
