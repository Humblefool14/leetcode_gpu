// ad_ms_zclamp -- clamps of one fp32 sample depth (spec/gpu/rop/ad_rop_ms.md §4).
// Stage 1 (en01): clamp01 -- NaN and negatives (sign bit set, -0 included) give
//   +0, above 1.0 (+inf included) gives 1.0, else x unchanged.
// Stage 2 (enmm): clamp to [lo, hi] -- a NaN gives lo, x < lo gives lo,
//   hi < x gives hi, else unchanged (fp32 order of ad_fp_cmp, -0 = +0).
// The parent passes lo = min(n, f), hi = max(n, f).  Combinational.
module ad_ms_zclamp (
    input  wire [31:0] x,
    input  wire        en01,
    input  wire        enmm,
    input  wire [31:0] lo,
    input  wire [31:0] hi,
    output wire [31:0] y
);
    localparam [31:0] ONE = 32'h3F80_0000;

    // ---- clamp01 ----
    wire xnan = (x[30:23] == 8'hFF) && (x[22:0] != 23'd0);
    wire g1_lt, g1_eq, g1_un;
    ad_fp_cmp u_c1 (.a(ONE), .b(x), .lt(g1_lt), .eq(g1_eq), .un(g1_un));   // 1 < x
    wire [31:0] c01 = (xnan || x[31]) ? 32'd0 :
                      g1_lt           ? ONE   : x;
    wire [31:0] s1  = en01 ? c01 : x;

    // ---- clamp to [lo, hi] ----
    wire l_lt, l_eq, l_un, h_lt, h_eq, h_un;
    ad_fp_cmp u_cl (.a(s1), .b(lo), .lt(l_lt), .eq(l_eq), .un(l_un));      // s1 < lo
    ad_fp_cmp u_ch (.a(hi), .b(s1), .lt(h_lt), .eq(h_eq), .un(h_un));      // hi < s1
    wire s1nan = (s1[30:23] == 8'hFF) && (s1[22:0] != 23'd0);
    wire [31:0] cmm = (s1nan || l_lt) ? lo :
                      h_lt            ? hi : s1;
    assign y = enmm ? cmm : s1;
endmodule
