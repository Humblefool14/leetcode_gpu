// ad_blend_factor8 -- 8-bit blend factor of one channel (spec ad_rop_blend.md §4).
// sel = VkBlendFactor 0..18 (already {MSB, 4 bits} with ROP_CTRL[7], {0, 4 bits} without).
// 15..18 (SRC1_*) only with dual = ROP_CTRL[7]; any other value reads ZERO.
// For the alpha channel pass the alpha values in the *_c inputs too and is_alpha = 1
// (then SRC_ALPHA_SATURATE reads 255).  255 - x == ~x for 8 bits.
`include "ad_rop_state.vh"
module ad_blend_factor8 (
    input  wire [4:0] sel,
    input  wire       dual,
    input  wire       is_alpha,
    input  wire [7:0] s_c,
    input  wire [7:0] s_a,
    input  wire [7:0] d_c,
    input  wire [7:0] d_a,
    input  wire [7:0] k_c,
    input  wire [7:0] k_a,
    input  wire [7:0] s1_c,
    input  wire [7:0] s1_a,
    output reg  [7:0] f
);
    wire [7:0] omda = ~d_a;
    wire [7:0] sat  = is_alpha ? 8'hFF : ((s_a < omda) ? s_a : omda);
    always @(*) begin
        case (sel)
            `AD_BF_ZERO:  f = 8'd0;
            `AD_BF_ONE:   f = 8'hFF;
`ifdef MUT_FACTOR_SWAP
            `AD_BF_SC:    f = d_c;
            `AD_BF_DC:    f = s_c;
`else
            `AD_BF_SC:    f = s_c;
            `AD_BF_DC:    f = d_c;
`endif
            `AD_BF_OMSC:  f = ~s_c;
            `AD_BF_OMDC:  f = ~d_c;
            `AD_BF_SA:    f = s_a;
            `AD_BF_OMSA:  f = ~s_a;
            `AD_BF_DA:    f = d_a;
            `AD_BF_OMDA:  f = omda;
            `AD_BF_CC:    f = k_c;
            `AD_BF_OMCC:  f = ~k_c;
            `AD_BF_CA:    f = k_a;
            `AD_BF_OMCA:  f = ~k_a;
            `AD_BF_SAS:   f = sat;
            `AD_BF_S1C:   f = dual ? s1_c  : 8'd0;
            `AD_BF_OMS1C: f = dual ? ~s1_c : 8'd0;
            `AD_BF_S1A:   f = dual ? s1_a  : 8'd0;
            `AD_BF_OMS1A: f = dual ? ~s1_a : 8'd0;
            default:      f = 8'd0;
        endcase
    end
endmodule
