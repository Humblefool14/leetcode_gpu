// fv_ad_su_fadd: fp32 add, RNE, flushed.
//  - commutativity a + b == b + a;
//  - a - a == +0 for every finite a (b = a ^ sign);
//  - x + (+-0) == x for normal x; (+-0) + (+-0) is -0 only for -0 + -0;
//  - inf + -inf and NaN operands give 0x7FC00000; every NaN result is
//    0x7FC00000; never a denormal result;
//  - equivalence with the fused datapath: fadd(a, b) == ad_su_ffma_p(a, 1.0,
//    b, RNE) (pm = a's significand * 1.0), i.e. gsi1fp fpu(FADD) - task
//    "equiv" (bmc only, see the spec).
module fv_ad_su_fadd;
    localparam [31:0] QNAN = 32'h7FC00000;
    (* anyconst *) reg [31:0] a, b;

    wire [31:0] y_ab, y_ba, y_aa, y_a0;
    ad_su_fadd u_ab (.a(a), .b(b), .y(y_ab));
    ad_su_fadd u_ba (.a(b), .b(a), .y(y_ba));
    ad_su_fadd u_aa (.a(a), .b(a ^ 32'h80000000), .y(y_aa));
    ad_su_fadd u_a0 (.a(a), .b({b[31], 8'd0, b[22:0]}), .y(y_a0));

    wire [7:0] ea = a[30:23], eb = b[30:23];
    wire nan_a = ea == 8'hFF && a[22:0] != 23'd0;
    wire nan_b = eb == 8'hFF && b[22:0] != 23'd0;
    wire inf_a = ea == 8'hFF && a[22:0] == 23'd0;
    wire inf_b = eb == 8'hFF && b[22:0] == 23'd0;

`ifdef FV_EQUIV
    wire [31:0] y_f;
    wire [47:0] pm1 = {ea != 8'd0, a[22:0], 24'd0} >> 1;
    ad_su_ffma_p u_f (.a(a), .b(32'h3F800000), .c(b), .rm(3'd0), .noc(1'b0), .pm(pm1), .y(y_f));
    always @(*) assert (y_ab == y_f);
`endif

    always @(*) begin
        assert (y_ab == y_ba);
        if (ea != 8'hFF)
            assert (y_aa == 32'd0);
        if (ea != 8'd0 && ea != 8'hFF)
            assert (y_a0 == a);
        if (ea == 8'd0 && eb == 8'd0)
            assert (y_ab == {a[31] & b[31], 31'd0});
        if (nan_a || nan_b || (inf_a && inf_b && a[31] != b[31]))
            assert (y_ab == QNAN);
        if (y_ab[30:23] == 8'hFF && y_ab[22:0] != 23'd0)
            assert (y_ab == QNAN);
        if (y_ab[30:23] == 8'd0)
            assert (y_ab[22:0] == 23'd0);
    end
endmodule
