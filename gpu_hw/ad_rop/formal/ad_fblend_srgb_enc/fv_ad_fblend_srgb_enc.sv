// ad_fblend_srgb_enc: encode(LUT[c]) == c for every code c (c is free); monotonic
// on all non-NaN fp32 (a <= b in fp32 order -> enc(a) <= enc(b)); NaN, negatives
// and -0 give 0; values >= 1.0 (and +inf) give 255.
module fv_ad_fblend_srgb_enc;
    (* anyconst *) reg [7:0]  c;
    (* anyconst *) reg [31:0] a;
    (* anyconst *) reg [31:0] b;
    wire [31:0] l; wire [7:0] cl, ea, eb;
    ad_fblend_srgb_lut u_lut (.c(c), .f(l));
    ad_fblend_srgb_enc u_el  (.f(l), .c(cl));
    ad_fblend_srgb_enc u_ea  (.f(a), .c(ea));
    ad_fblend_srgb_enc u_eb  (.f(b), .c(eb));
    wire a_nan = (a[30:23] == 8'hFF) && (a[22:0] != 0);
    wire b_nan = (b[30:23] == 8'hFF) && (b[22:0] != 0);
    // fp32 order a <= b for non-NaN (-0 = +0)
    wire [31:0] ka = (a[30:0] == 0) ? 32'h8000_0000 : (a[31] ? ~a : {1'b1, a[30:0]});
    wire [31:0] kb = (b[30:0] == 0) ? 32'h8000_0000 : (b[31] ? ~b : {1'b1, b[30:0]});
    always @(*) begin
        a_lut_rt: assert (cl == c);
        if (!a_nan && !b_nan && ka <= kb) a_mono: assert (ea <= eb);
        if (a_nan || a[31]) a_zero: assert (ea == 8'd0);
        if (!a[31] && a >= 32'h3F80_0000 && !a_nan) a_sat: assert (ea == 8'd255);
    end
endmodule
