// ad_fp_cmp is a total order on non-NaN values with -0 = +0, and ad_cmp_op
// gives complementary results for complementary VkCompareOps.
module fv_ad_fp_cmp;
    (* anyconst *) reg [31:0] a;
    (* anyconst *) reg [31:0] b;
    (* anyconst *) reg [31:0] c;
    (* anyconst *) reg [2:0] op;
    wire lt_ab, eq_ab, un_ab, lt_ba, eq_ba, un_ba, lt_bc, eq_bc, un_bc, lt_ac, eq_ac, un_ac;
    ad_fp_cmp c_ab (.a(a), .b(b), .lt(lt_ab), .eq(eq_ab), .un(un_ab));
    ad_fp_cmp c_ba (.a(b), .b(a), .lt(lt_ba), .eq(eq_ba), .un(un_ba));
    ad_fp_cmp c_bc (.a(b), .b(c), .lt(lt_bc), .eq(eq_bc), .un(un_bc));
    ad_fp_cmp c_ac (.a(a), .b(c), .lt(lt_ac), .eq(eq_ac), .un(un_ac));
    wire p_op, p_not;
    ad_cmp_op o1 (.op(op),        .lt(lt_ab), .eq(eq_ab), .un(un_ab), .pass(p_op));
    ad_cmp_op o2 (.op(3'd7 - op), .lt(lt_ab), .eq(eq_ab), .un(un_ab), .pass(p_not));
    always @(*) begin
        a_un:    assert (un_ab == un_ba);
        if (!un_ab) a_tri:  assert ((lt_ab + eq_ab + lt_ba) == 1);           // exactly one of <, =, >
        a_eqsym: assert (eq_ab == eq_ba);
        if (lt_ab && lt_bc) a_trans: assert (lt_ac);                          // transitivity
        a_zero:  assert (!(a == 32'h0 && b == 32'h8000_0000) || eq_ab);       // +0 = -0
        if (!un_ab) a_compl: assert (p_op != p_not);                          // op and its complement (7-op)
    end
endmodule
