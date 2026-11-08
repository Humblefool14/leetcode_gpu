// ad_su_fmod -- the float modifiers of one operand, NPHYS lanes (combinational leaf of
// ad_su_opd; tools/gsi1model.py fmod): units FPU and XU: abs clears bit 31, then neg
// flips it; unit PK: the same on both halves (bits 15 and 31); other units unchanged.
module ad_su_fmod #(
    parameter NPHYS = 8,
    parameter LW    = 32
) (
    input  wire [3:0]          unit,
    input  wire                neg,
    input  wire                abs_,
    input  wire [NPHYS*LW-1:0] din,
    output wire [NPHYS*LW-1:0] dout
);
`include "ad_su_uop.vh"
    wire        fp  = unit == AD_UNIT_FPU || unit == AD_UNIT_XU;
    wire        pk  = unit == AD_UNIT_PK;
    wire [31:0] sb  = pk ? 32'h80008000 : fp ? 32'h80000000 : 32'h0;
    wire [LW-1:0] sbw = sb[LW-1:0];
    wire [LW-1:0] am = abs_ ? ~sbw : {LW{1'b1}};
    wire [LW-1:0] nx = neg ? sbw : {LW{1'b0}};
    genvar i;
    generate
        for (i = 0; i < NPHYS; i = i + 1) begin : l
            assign dout[LW*i +: LW] = (din[LW*i +: LW] & am) ^ nx;
        end
    endgenerate
endmodule
