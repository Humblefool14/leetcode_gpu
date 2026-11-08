// fv_ad_su_f2i: fp32 to int32/uint32 through ad_su_rint, saturating.
//  - NaN gives the largest (0x7FFFFFFF / 0xFFFFFFFF);
//  - |x| >= 2^32 or inf: the bound of x's sign (unsigned: 0 for negatives);
//  - signed: rint(x) above 2^31-1 gives 0x7FFFFFFF, below -2^31 gives
//    0x80000000, otherwise the result is rint(x);
//  - unsigned: a negative x gives 0, otherwise rint(x);
module fv_ad_su_f2i;
    (* anyconst *) reg [31:0] x;
    (* anyconst *) reg uns;
    (* anyconst *) reg [2:0] rm;

    wire        neg, big;
    wire [31:0] mag, y;
    wire        nan = x[30:23] == 8'hFF && x[22:0] != 23'd0;
    ad_su_rint u_rint (.x(x), .rm(rm), .neg(neg), .mag(mag), .big(big));
    ad_su_f2i u_f2i (.neg(neg), .mag(mag), .big(big), .nan(nan), .uns(uns), .y(y));

    wire signed [33:0] r = neg ? -$signed({2'b0, mag}) : $signed({2'b0, mag});

    always @(*) begin
        if (nan)
            assert (y == (uns ? 32'hFFFFFFFF : 32'h7FFFFFFF));
        else if (big)
            assert (y == (uns ? (neg ? 32'd0 : 32'hFFFFFFFF) : (neg ? 32'h80000000 : 32'h7FFFFFFF)));
        else if (uns) begin
            if (neg)
                assert (y == 32'd0);
            else
                assert (y == mag);
        end else begin
            if (r > 34'sh7FFFFFFF)
                assert (y == 32'h7FFFFFFF);
            else if (r < -34'sh80000000)
                assert (y == 32'h80000000);
            else
                assert ($signed({{2{y[31]}}, y}) == r);
        end
    end
endmodule
