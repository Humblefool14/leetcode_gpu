// ad_fblend_minmax -- fp32 min / max for the blend MIN/MAX ops and SRC_ALPHA_SATURATE.
// One NaN operand -> the other operand; both NaN -> 0x7FC00000.
// min = (a < b) ? a : b, max = (a < b) ? b : a (ad_fp_cmp order, -0 = +0); for
// equal operands min returns b and max returns a.  Operand bits pass unchanged
// (no flush).  Combinational.
module ad_fblend_minmax (
    input  wire [31:0] a,
    input  wire [31:0] b,
    input  wire        is_max,
    output wire [31:0] y
);
    wire lt, eq, un;
    ad_fp_cmp u_cmp (.a(a), .b(b), .lt(lt), .eq(eq), .un(un));
    wire na = (a[30:23] == 8'hFF) && (a[22:0] != 23'd0);
    wire nb = (b[30:23] == 8'hFF) && (b[22:0] != 23'd0);
    assign y = (na && nb) ? 32'h7FC0_0000 :
               na         ? b :
               nb         ? a :
               is_max     ? (lt ? b : a) :
                            (lt ? a : b);
endmodule
