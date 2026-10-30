// ============================================================================
// ad_rx_f2fix -- fp32 -> signed 15.8 fixed point (FIX_WID = 24), combinational.
// NaN and |f| < 2^-33 (exponent < 94) -> 0; |f| >= 2^15 (exponent >= 142, inf
// included) or a rounded magnitude above FIX_SAT -> +-FIX_SAT; else
// RNE(|f| * 2^8) with f's sign.
// ============================================================================
module ad_rx_f2fix (
  input  logic [31:0]                     f,
  output logic [ad_rx_pkg::FIX_WID-1:0]   q
);
  localparam int QW  = ad_rx_pkg::FIX_WID;
  localparam logic [QW-1:0] SAT = QW'(ad_rx_pkg::FIX_SAT);

  logic [7:0]  e;
  logic [23:0] m;
  logic        nan;
  assign e   = f[30:23];
  assign m   = {1'b1, f[22:0]};
  assign nan = (e == 8'hFF) && (f[22:0] != 23'd0);

  // value * 256 = m * 2^(e - 142); for e < 142 shift right by 142 - e (1..48)
  logic [5:0]  sh;
  logic [47:0] wide, kept;
  logic [23:0] ip;
  logic        g, st, rup;
  logic [24:0] mag;
  assign sh   = (e >= 8'd94) ? 6'(8'd142 - e) : 6'd48;
  assign wide = {m, 24'd0};                        // m * 2^24
  assign kept = wide >> sh;                        // integer part in [47:24]
  assign ip   = kept[47:24];
  assign g    = kept[23];
  assign st   = (kept[22:0] != '0);
  assign rup  = g & (st | ip[0]);
  assign mag  = {1'b0, ip} + {24'd0, rup};

  always_comb begin
    if (nan || e < 8'd94)                q = '0;
    else if (e >= 8'd142 || mag > {1'b0, SAT})
                                         q = f[31] ? (~SAT + 1'b1) : SAT;
    else                                 q = f[31] ? (~mag[QW-1:0] + 1'b1) : mag[QW-1:0];
  end

`ifdef FORMAL
  always_comb begin
    assert ($signed(q) <= $signed(SAT) && $signed(q) >= -$signed(SAT));
    if (nan) assert (q == '0);
    if (!nan && q != '0) assert (q[QW-1] == f[31]);
  end
`endif
endmodule
