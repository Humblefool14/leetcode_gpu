// ============================================================================
// ad_rx_fmul -- fp32 a * b, combinational.  Rules as ad_rx_fadd.
// 0 * inf = NaN; a denormal operand counts as zero.
// ============================================================================
module ad_rx_fmul (
  input  logic [31:0] i_a,
  input  logic [31:0] i_b,
  output logic [31:0] o_r
);
  logic [31:0] r_c;               // the exact result
`ifdef AD_FPABS
  (* anyseq *) logic [31:0] f_any;  // FPV cut-point: any value (control-path proofs)
  assign o_r = f_any;
`else
  assign o_r = r_c;
`endif
  logic        s;
  logic [7:0]  ea, eb;
  logic        za, zb, ia, ib, na, nb;
  assign s  = i_a[31] ^ i_b[31];
  assign ea = i_a[30:23];
  assign eb = i_b[30:23];
  assign za = (ea == 8'd0);
  assign zb = (eb == 8'd0);
  assign ia = (ea == 8'hFF) && (i_a[22:0] == 23'd0);
  assign ib = (eb == 8'hFF) && (i_b[22:0] == 23'd0);
  assign na = (ea == 8'hFF) && (i_a[22:0] != 23'd0);
  assign nb = (eb == 8'hFF) && (i_b[22:0] != 23'd0);

  logic [47:0] p;
  assign p = {1'b1, i_a[22:0]} * {1'b1, i_b[22:0]};   // in [2^46, 2^48)

  logic        hi;
  logic [23:0] sig;
  logic        g, st, rup;
  logic [24:0] rnd;
  logic [9:0]  en, er;
  assign hi  = p[47];
  assign sig = hi ? p[47:24] : p[46:23];
  assign g   = hi ? p[23] : p[22];
  assign st  = hi ? (p[22:0] != '0) : (p[21:0] != '0);
  assign rup = g & (st | sig[0]);
  assign rnd = {1'b0, sig} + {24'd0, rup};
  assign en  = {2'b00, ea} + {2'b00, eb} - 10'd127 + {9'd0, hi};
  assign er  = rnd[24] ? en + 10'd1 : en;

  always_comb begin
    if (na || nb || (ia && zb) || (ib && za))
      r_c = ad_rx_pkg::FP_QNAN;
    else if (ia || ib)
      r_c = {s, 8'hFF, 23'd0};
    else if (za || zb)
      r_c = {s, 31'd0};
    else if (er[9] || er == 10'd0)
      r_c = {s, 31'd0};
    else if (er >= 10'd255)
      r_c = {s, 8'hFF, 23'd0};
    else
      r_c = {s, er[7:0], rnd[24] ? rnd[23:1] : rnd[22:0]};
  end

`ifdef FORMAL
  always_comb begin
    if (na || nb) assert (r_c == ad_rx_pkg::FP_QNAN);
    if (r_c != ad_rx_pkg::FP_QNAN) assert (r_c[31] == s);
    assert (r_c[30:23] != 8'd0 || r_c[22:0] == 23'd0);
    if (i_b == ad_rx_pkg::FP_ONEV && !na) assert (r_c == (za ? {i_a[31], 31'd0} : i_a));
  end
`endif
endmodule
