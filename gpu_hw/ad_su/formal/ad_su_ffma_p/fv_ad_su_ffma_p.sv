// fv_ad_su_ffma_p: algebraic properties of the fused multiply-add.
//  - commutativity: ffma(a, b, c) == ffma(b, a, c) for every rm and noc, on
//    the same significand product pm (free, with the leading-bit range of a
//    real product: pm[47:46] != 0); the multiplier itself is the parent's;
//  - x * 1 + (+-0) == x and x * 1 (noc) == x for every normal x and rm
//    (pm = the exact product of x's significand and 1.0);
//  - 0 * x + c == c for normal c (pm = 0);
//  - sign rules: noc gives the sign of a*b (unless NaN); p != 0 with c zero
//    gives the sign of a*b; 0 * x + 0 gives (sa^sb) & sc, or | under RDN;
//  - every NaN result is 0x7FC00000; never a denormal result.
module fv_ad_su_ffma_p;
    localparam [31:0] ONE = 32'h3F800000;
    localparam [31:0] QNAN = 32'h7FC00000;

    (* anyconst *) reg [31:0] a, b, c;
    (* anyconst *) reg [2:0] rm;
    (* anyconst *) reg noc;
    (* anyconst *) reg [47:0] pm;

    wire [7:0] ea = a[30:23], eb = b[30:23], ec = c[30:23];
    wire nrm_a = ea != 8'd0 && ea != 8'hFF;
    wire nrm_b = eb != 8'd0 && eb != 8'hFF;
    wire nrm_c = ec != 8'd0 && ec != 8'hFF;
    wire [2:0] rmd = rm > 3'd4 ? 3'd0 : rm;

    always @(*) assume (pm[47:46] != 2'b00);

    // Commutativity.
    wire [31:0] y_ab, y_ba;
    ad_su_ffma_p u_ab (.a(a), .b(b), .c(c), .rm(rm), .noc(noc), .pm(pm), .y(y_ab));
    ad_su_ffma_p u_ba (.a(b), .b(a), .c(c), .rm(rm), .noc(noc), .pm(pm), .y(y_ba));

    // x * 1 + (+-0) and x * 1.
    wire [47:0] pm1 = {nrm_a | ea == 8'hFF, a[22:0], 24'd0} >> 1;   // {1, m} * 2^23
    wire [31:0] y_id;
    ad_su_ffma_p u_id (.a(a), .b(ONE), .c({c[31], 31'd0}), .rm(rm), .noc(noc), .pm(pm1), .y(y_id));

    // 0 * x + c.
    wire [31:0] y_z;
    ad_su_ffma_p u_z (.a({a[31], 8'd0, a[22:0]}), .b(b), .c(c), .rm(rm), .noc(1'b0), .pm(48'd0), .y(y_z));

    always @(*) begin
        assert (y_ab == y_ba);
        if (nrm_a)
            assert (y_id == a);
        if (nrm_c && eb != 8'hFF)
            assert (y_z == c);
        if (eb == 8'd0 && ec == 8'd0)
            assert (y_z == {rmd == 3'd2 ? (a[31] ^ b[31]) | c[31] : (a[31] ^ b[31]) & c[31], 31'd0});
        // Sign rules.
        if (y_ab != QNAN && noc)
            assert (y_ab[31] == (a[31] ^ b[31]));
        if (y_ab != QNAN && ec == 8'd0 && ea != 8'd0 && eb != 8'd0)
            assert (y_ab[31] == (a[31] ^ b[31]));
        // NaN canonical, no denormal.
        if (y_ab[30:23] == 8'hFF && y_ab[22:0] != 23'd0)
            assert (y_ab == QNAN);
        if (y_ab[30:23] == 8'd0)
            assert (y_ab[22:0] == 23'd0);
    end
endmodule
