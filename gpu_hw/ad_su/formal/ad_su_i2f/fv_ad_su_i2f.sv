// fv_ad_su_i2f: int32/uint32 to fp32.
//  - f2i(i2f(i)) == i for |i| < 2^24 (signed) and i < 2^24 (unsigned), every
//    rm (through ad_su_rint and ad_su_f2i with the same rm);
//  - i2f is exact (no rounding) below 2^24: rounding modes agree;
//  - 0 gives +0; the sign is the integer's; never a denormal; exponent in
//    127..158 (+1 at the 2^32 round-up of a uint32);
//  - RTZ never increases the magnitude (through ad_su_rint:
//    rint(i2f(i, RTZ), RTZ) <= |i|);
//  - correct rounding for every rm (V = |i2f(i)| as an integer, ulp its
//    unit in the last place): RTZ V <= |i|; RDN/RUP toward -inf/+inf;
//    every rm |V - |i|| < ulp; RNE and RMM |V - |i|| <= ulp/2, a tie gives
//    an even significand (RNE) or the larger magnitude (RMM).
module fv_ad_su_i2f;
    (* anyconst *) reg [31:0] i;
    (* anyconst *) reg uns;
    (* anyconst *) reg [2:0] rm;

    wire [31:0] f, f_rne, f_rtz;
    ad_su_i2f u_i2f (.a(i), .uns(uns), .rm(rm), .y(f));
    ad_su_i2f u_rne (.a(i), .uns(uns), .rm(3'd0), .y(f_rne));
    ad_su_i2f u_rtz (.a(i), .uns(uns), .rm(3'd1), .y(f_rtz));

    wire        neg, big, neg_z, big_z;
    wire [31:0] mag, back, mag_z;
    ad_su_rint u_rint (.x(f), .rm(rm), .neg(neg), .mag(mag), .big(big));
    ad_su_f2i u_f2i (.neg(neg), .mag(mag), .big(big), .nan(1'b0), .uns(uns), .y(back));
    ad_su_rint u_rintz (.x(f_rtz), .rm(3'd1), .neg(neg_z), .mag(mag_z), .big(big_z));

    wire        si = !uns && i[31];
    wire [31:0] ai = si ? -i : i;
    wire        small = ai < 32'h01000000;

    wire [7:0]  fe = f[30:23];
    wire [63:0] fm = {40'd0, 1'b1, f[22:0]};
    wire [63:0] V = fe >= 8'd150 ? fm << (fe - 8'd150) : fm >> (8'd150 - fe);
    wire [63:0] ulp = fe >= 8'd150 ? 64'd1 << (fe - 8'd150) : 64'd1;
    wire [63:0] I = {32'd0, ai};
    wire [63:0] dif = V >= I ? V - I : I - V;
    wire [2:0]  rmd = rm > 3'd4 ? 3'd0 : rm;

    always @(*) begin
        if (i != 32'd0) begin
            assert (dif < ulp);
            if (rmd == 3'd1)
                assert (V <= I);
            if (rmd == 3'd2)
                assert (si ? V >= I : V <= I);
            if (rmd == 3'd3)
                assert (si ? V <= I : V >= I);
            if (rmd == 3'd0 || rmd == 3'd4)
                assert ({dif, 1'b0} <= {1'b0, ulp});
            if (rmd == 3'd0 && {dif, 1'b0} == {1'b0, ulp})
                assert (!f[0]);
            if (rmd == 3'd4 && {dif, 1'b0} == {1'b0, ulp})
                assert (V > I);
        end
        if (small) begin
            assert (back == i);
            assert (f == f_rne);
        end
        if (i == 32'd0)
            assert (f == 32'd0);
        else begin
            assert (f[31] == si);
            assert (f[30:23] >= 8'd127 && f[30:23] <= 8'd159);
            if (f[30:23] == 8'd159)
                assert (f[22:0] == 23'd0 && uns);
            assert (!big_z && mag_z <= ai);
        end
    end
endmodule
