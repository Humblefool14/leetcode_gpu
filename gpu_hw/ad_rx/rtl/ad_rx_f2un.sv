// ============================================================================
// ad_rx_f2un -- fp32 depth in [0, 1] -> unorm (HZ_DEPW bits), conservative.
// NEW (not in atg): the Hi-Z compares unorm16 values; the triangle's nearest
// depth is rounded DOWN (RUP = 0), a tile's farthest depth UP (RUP = 1), so a
// reject is never wrong.  NaN and negatives -> 0; >= 1.0 and +inf -> all ones.
// ============================================================================
module ad_rx_f2un #(
  parameter int RUP = 0           // 0 floor, 1 ceiling
) (
  input  logic [31:0]                    f,
  output logic [ad_rx_pkg::HZ_DEPW-1:0]  u
);
  localparam int DW = ad_rx_pkg::HZ_DEPW;
  localparam logic [DW-1:0] MX = {DW{1'b1}};

  logic [7:0]  e;
  logic        nan, neg;
  assign e   = f[30:23];
  assign nan = (e == 8'hFF) && (f[22:0] != 23'd0);
  assign neg = f[31] && (e != 8'd0);

  // v * (2^DW - 1) = m * (2^DW - 1) * 2^(e - 150); e <= 126 -> shift >= 24
  logic [23:0]      m;
  logic [24+DW-1:0] p, fl;
  logic [7:0]       sh;
  logic             rem;
  assign m   = {1'b1, f[22:0]};
  assign p   = ({{DW{1'b0}}, m} << DW) - {{DW{1'b0}}, m};   // m * (2^DW - 1), no multiplier
  assign sh  = 8'd150 - e;
  assign fl  = (sh >= 8'(24 + DW)) ? '0 : (p >> sh);
  assign rem = (sh >= 8'(24 + DW)) ? 1'b1 : ((fl << sh) != p);

  always_comb begin
    if (nan || neg || e == 8'd0)        u = '0;
    else if (e >= 8'd127)               u = MX;           // >= 1.0, inf
    else if (RUP != 0 && rem)           u = fl[DW-1:0] + 1'b1;
    else                                u = fl[DW-1:0];
  end
endmodule
