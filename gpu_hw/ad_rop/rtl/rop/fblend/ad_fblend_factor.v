// ad_fblend_factor -- one blend factor (VkBlendFactor 0..14, 15 reads ZERO) in fp32.
// s, d, c: this channel's source, destination and constant; sa, da, ca: the alphas.
// For the alpha channel (is_alpha) s/d/c are the alphas themselves, and
// SRC_ALPHA_SATURATE is 1.0; for R, G, B it is min(sa, 1 - da) (ad_fblend_minmax).
// "One minus x" is ad_fp_add(1.0, x, sub = 1).  Combinational.
`include "ad_rop_state.vh"
module ad_fblend_factor (
    input  wire [3:0]  sel,
    input  wire        is_alpha,
    input  wire [31:0] s,
    input  wire [31:0] sa,
    input  wire [31:0] d,
    input  wire [31:0] da,
    input  wire [31:0] c,
    input  wire [31:0] ca,
    output reg  [31:0] f
);
    localparam [31:0] ONE = 32'h3F80_0000;
    reg  [31:0] base;
    always @(*) begin
        case ({1'b0, sel})
            `AD_BF_SC,  `AD_BF_OMSC: base = s;
            `AD_BF_DC,  `AD_BF_OMDC: base = d;
            `AD_BF_SA,  `AD_BF_OMSA: base = sa;
            `AD_BF_DA,  `AD_BF_OMDA, `AD_BF_SAS: base = da;
            `AD_BF_CC,  `AD_BF_OMCC: base = c;
            `AD_BF_CA,  `AD_BF_OMCA: base = ca;
            default: base = 32'd0;
        endcase
    end
    wire [31:0] om, sat;
    ad_fp_add        u_om  (.a(ONE), .b(base), .sub(1'b1), .y(om));
    ad_fblend_minmax u_sat (.a(sa), .b(om), .is_max(1'b0), .y(sat));
    always @(*) begin
        case ({1'b0, sel})
            `AD_BF_ONE: f = ONE;
            `AD_BF_SC, `AD_BF_DC, `AD_BF_SA, `AD_BF_DA, `AD_BF_CC, `AD_BF_CA: f = base;
            `AD_BF_OMSC, `AD_BF_OMDC, `AD_BF_OMSA, `AD_BF_OMDA, `AD_BF_OMCC, `AD_BF_OMCA: f = om;
            `AD_BF_SAS: f = is_alpha ? ONE : sat;
            default: f = 32'd0;                          // ZERO and 15
        endcase
    end
endmodule
