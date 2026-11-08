// ad_fblend_srgb_lut: LUT[0] = +0, LUT[255] = 1.0, strictly increasing in c, every
// entry a non-negative normal fp32 <= 1.0 (or +0).
module fv_ad_fblend_srgb_lut;
    (* anyconst *) reg [7:0] c1;
    (* anyconst *) reg [7:0] c2;
    wire [31:0] f1, f2;
    ad_fblend_srgb_lut u1 (.c(c1), .f(f1));
    ad_fblend_srgb_lut u2 (.c(c2), .f(f2));
    always @(*) begin
        if (c1 == 8'd0)   a_zero: assert (f1 == 32'd0);
        if (c1 == 8'd255) a_one:  assert (f1 == 32'h3F80_0000);
        if (c1 < c2)      a_mono: assert (f1 < f2);
        a_range: assert (!f1[31] && f1 <= 32'h3F80_0000 && (f1 == 0 || f1[30:23] != 0));
    end
endmodule
