// fv_ad_su_rint: round to integer, for every rm.
//  - |rint(x) - x| < 1 for every finite x below 2^32 (exact fixed point:
//    X = |x| * 2^149, M = mag * 2^149);
//  - RTZ goes toward zero (M <= X); RDN / RUP of a positive x go down / up;
//  - an integral x is unchanged; a zero or denormal gives 0;
//  - monotonic: value(x1) <= value(x2) gives rint(x1) <= rint(x2) (same rm);
//  - the result is integral: fround's value (the rounded integer through
//    ad_su_i2f with the sign of x) has no fraction bits.
module fv_ad_su_rint;
    (* anyconst *) reg [31:0] x, x2;
    (* anyconst *) reg [2:0] rm;

    wire        neg, big, neg2, big2;
    wire [31:0] mag, mag2;
    ad_su_rint u1 (.x(x), .rm(rm), .neg(neg), .mag(mag), .big(big));
    ad_su_rint u2 (.x(x2), .rm(rm), .neg(neg2), .mag(mag2), .big(big2));
    wire [2:0] rmd = rm > 3'd4 ? 3'd0 : rm;

    wire [7:0]   e = x[30:23];
    wire [180:0] X = {157'd0, 1'b1, x[22:0]} << (e - 8'd1);
    wire [180:0] M = {149'd0, mag} << 149;
    wire [180:0] ONEF = 181'd1 << 149;
    wire         fin = e != 8'd0 && !big;
    wire         exact = (X & (ONEF - 181'd1)) == 181'd0;

    // Value order of non-NaN floats (+0 == -0, denormals are zeros).
    function [32:0] key(input [31:0] f);
        key = (f[30:23] == 8'd0) ? 33'h100000000 : f[31] ? {1'b0, ~f} : {1'b1, f};
    endfunction
    wire signed [33:0] r1 = neg ? -$signed({2'b0, mag}) : $signed({2'b0, mag});
    wire signed [33:0] r2 = neg2 ? -$signed({2'b0, mag2}) : $signed({2'b0, mag2});

    // fround's value: ad_su_i2f of the magnitude (exact below 2^24), sign of x.
    wire [31:0] fy;
    ad_su_i2f u_f (.a(mag), .uns(1'b1), .rm(3'd0), .y(fy));
    wire [7:0]  fe = fy[30:23];
    wire [23:0] fm = {1'b1, fy[22:0]};
    wire [23:0] fmask = (fe >= 8'd150) ? 24'd0 : (fe < 8'd127) ? 24'hFFFFFF :
                        (24'hFFFFFF >> (fe - 8'd127 + 8'd1));

    always @(*) begin
        assert (neg == x[31]);
        assert (big == (e >= 8'd159));
        if (e == 8'd0)
            assert (mag == 32'd0);
        if (fin) begin
            assert (M < X + ONEF);
            assert (X < M + ONEF);
            if (rmd == 3'd1)
                assert (M <= X);
            if (!neg && rmd == 3'd2)
                assert (M <= X);
            if (!neg && rmd == 3'd3)
                assert (M >= X);
            if (exact)
                assert (M == X);
        end
        if (!big && !big2 && key(x) <= key(x2))
            assert (r1 <= r2);
        // integral: e < 150 here (|x| < 2^23, mag <= 2^23)
        if (fin && e < 8'd150) begin
            if (mag == 32'd0)
                assert (fy == 32'd0);
            else
                assert ((fm & fmask) == 24'd0 && fe >= 8'd127);
        end
    end
endmodule
