// ============================================================================
// ad_rx_fadd -- fp32 a + b (or a - b with i_sub), combinational.
// Rules (shared by every RX fp unit): IEEE single, round to nearest even,
// denormal inputs read as zero (sign kept), denormal results flushed to zero
// (sign kept; tininess after rounding, unbounded exponent), NaN results are
// the canonical FP_QNAN, infinities follow IEEE, x + (-x) = +0.
// ============================================================================
module ad_rx_fadd (
  input  logic [31:0] i_a,
  input  logic [31:0] i_b,
  input  logic        i_sub,      // 1: a - b
  output logic [31:0] o_r
);
  logic [31:0] r_c;               // the exact result
`ifdef AD_FPABS
  (* anyseq *) logic [31:0] f_any;  // FPV cut-point: any value (control-path proofs)
  assign o_r = f_any;
`else
  assign o_r = r_c;
`endif
  localparam int GW = 26;         // guard bits below the significand

  logic        sa, sb;
  logic [7:0]  ea, eb;
  logic [22:0] fa, fb;
  logic        za, zb, ia, ib, na, nb;

  assign sa = i_a[31];
  assign sb = i_b[31] ^ i_sub;
  assign ea = i_a[30:23];
  assign eb = i_b[30:23];
  assign fa = i_a[22:0];
  assign fb = i_b[22:0];
  assign za = (ea == 8'd0);                       // zero or denormal (flushed)
  assign zb = (eb == 8'd0);
  assign ia = (ea == 8'hFF) && (fa == 23'd0);
  assign ib = (eb == 8'hFF) && (fb == 23'd0);
  assign na = (ea == 8'hFF) && (fa != 23'd0);
  assign nb = (eb == 8'hFF) && (fb != 23'd0);

  // operand ordering by magnitude
  logic        swap;
  logic        sx, sy;
  logic [7:0]  ex, ey;
  logic [23:0] mx, my;
  assign swap = {ea, fa} < {eb, fb};
  assign sx = swap ? sb : sa;
  assign sy = swap ? sa : sb;
  assign ex = swap ? eb : ea;
  assign ey = swap ? ea : eb;
  assign mx = {1'b1, swap ? fb : fa};
  assign my = {1'b1, swap ? fa : fb};

  logic [7:0]          d;
  logic [5:0]          dsh;
  logic [24+GW-1:0]    wx, wy, wys;
  logic                stk;
  logic [24+GW:0]      sum;                       // one carry bit
  logic                eff_sub;

  assign d   = ex - ey;
  assign dsh = (d > 8'd50) ? 6'd50 : d[5:0];
  assign wx  = {mx, {GW{1'b0}}};
  assign wy  = {my, {GW{1'b0}}};
  assign wys = wy >> dsh;
  assign stk = ((wys << dsh) != wy);              // bits shifted out
  assign eff_sub = sx ^ sy;
  assign sum = eff_sub ? ({1'b0, wx} - {1'b0, wys} - {{(24+GW){1'b0}}, stk})
                       : ({1'b0, wx} + {1'b0, wys});

  // normalise: leading one of sum to bit 24+GW
  logic [5:0] lz;
  always_comb begin
    lz = 6'd51;
    for (int k = 0; k <= 24+GW; k++)
      if (sum[k]) lz = 6'(24 + GW - k);
  end

  logic [24+GW:0] nrm;
  logic [9:0]     en;                             // signed exponent, unbounded
  assign nrm = sum << lz;
  assign en  = {2'b00, ex} + 10'd1 - {4'd0, lz};

  // round: significand nrm[50:27], guard nrm[26], sticky rest | stk (sub keeps stk in the LSB)
  logic [23:0] sig;
  logic        g, st, rup;
  logic [24:0] rnd;
  logic [9:0]  er;
  assign sig = nrm[24+GW -: 24];
  assign g   = nrm[GW];
  assign st  = (nrm[GW-1:0] != '0) | stk;
  assign rup = g & (st | sig[0]);
  assign rnd = {1'b0, sig} + {24'd0, rup};
  assign er  = rnd[24] ? en + 10'd1 : en;

  logic [22:0] fr;
  assign fr = rnd[24] ? rnd[23:1] : rnd[22:0];

  always_comb begin
    if (na || nb || (ia && ib && (sa != sb)))
      r_c = ad_rx_pkg::FP_QNAN;
    else if (ia)
      r_c = {sa, 8'hFF, 23'd0};
    else if (ib)
      r_c = {sb, 8'hFF, 23'd0};
    else if (za && zb)
      r_c = {sa & sb, 31'd0};
    else if (za)
      r_c = {sb, eb, fb};
    else if (zb)
      r_c = {sa, ea, fa};
    else if (sum == '0)
      r_c = 32'd0;                                // exact cancellation: +0
    else if (er[9] || er == 10'd0)
      r_c = {sx, 31'd0};                          // tiny: flushed, sign kept
    else if (er >= 10'd255)
      r_c = {sx, 8'hFF, 23'd0};                   // overflow
    else
      r_c = {sx, er[7:0], fr};
  end

`ifdef FORMAL
  // Commutativity, structurally: the bundle after ordering by magnitude is the
  // same when the operands are exchanged (the rest of the datapath reads only
  // that bundle and the symmetric flags), for i_sub = 0 and |a| != |b|.
  logic        c_swap, c_sx, c_sy;
  logic [7:0]  c_ex, c_ey;
  logic [23:0] c_mx, c_my;
  assign c_swap = {eb, fb} < {ea, fa};             // ordering of (b, a)
  assign c_sx = c_swap ? sa : sb;
  assign c_sy = c_swap ? sb : sa;
  assign c_ex = c_swap ? ea : eb;
  assign c_ey = c_swap ? eb : ea;
  assign c_mx = {1'b1, c_swap ? fa : fb};
  assign c_my = {1'b1, c_swap ? fb : fa};
  always_comb if (!i_sub && {ea, fa} != {eb, fb})
    assert (c_sx == sx && c_sy == sy && c_ex == ex && c_ey == ey && c_mx == mx && c_my == my);
  // NaN in -> canonical NaN out
  always_comb begin
    if (na || nb) assert (r_c == ad_rx_pkg::FP_QNAN);
    if (!na && !nb && !ia && !ib && r_c[30:23] == 8'hFF) assert (r_c[22:0] == 23'd0);
    assert (r_c[30:23] != 8'd0 || r_c[22:0] == 23'd0);      // never a denormal
  end
`endif
endmodule
