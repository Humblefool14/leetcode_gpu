// ad_fblend_minmax: result is one of the operands unless both are NaN (then
// 0x7FC00000); one NaN -> the other; otherwise min <= a, b and max >= a, b in
// ad_fp_cmp order; min and max are symmetric in value (min(a,b) == min(b,a) by cmp).
module fv_ad_fblend_minmax;
    (* anyconst *) reg [31:0] a;
    (* anyconst *) reg [31:0] b;
    wire [31:0] mn, mx, mn2, mx2;
    ad_fblend_minmax u_mn  (.a(a), .b(b), .is_max(1'b0), .y(mn));
    ad_fblend_minmax u_mx  (.a(a), .b(b), .is_max(1'b1), .y(mx));
    ad_fblend_minmax u_mn2 (.a(b), .b(a), .is_max(1'b0), .y(mn2));
    ad_fblend_minmax u_mx2 (.a(b), .b(a), .is_max(1'b1), .y(mx2));
    wire lt_mn_a, eq_mn_a, un1, lt_mn_b, eq_mn_b, un2, lt_a_mx, eq_a_mx, un3, lt_b_mx, eq_b_mx, un4;
    wire lt_x, eq_mn12, un5, eq_mx12, un6, lt_y;
    ad_fp_cmp c1 (.a(mn), .b(a),  .lt(lt_mn_a), .eq(eq_mn_a), .un(un1));
    ad_fp_cmp c2 (.a(mn), .b(b),  .lt(lt_mn_b), .eq(eq_mn_b), .un(un2));
    ad_fp_cmp c3 (.a(a),  .b(mx), .lt(lt_a_mx), .eq(eq_a_mx), .un(un3));
    ad_fp_cmp c4 (.a(b),  .b(mx), .lt(lt_b_mx), .eq(eq_b_mx), .un(un4));
    ad_fp_cmp c5 (.a(mn), .b(mn2), .lt(lt_x), .eq(eq_mn12), .un(un5));
    ad_fp_cmp c6 (.a(mx), .b(mx2), .lt(lt_y), .eq(eq_mx12), .un(un6));
    wire na = (a[30:23] == 8'hFF) && (a[22:0] != 0);
    wire nb = (b[30:23] == 8'hFF) && (b[22:0] != 0);
    always @(*) begin
        if (na && nb)  a_nan2: assert (mn == 32'h7FC0_0000 && mx == 32'h7FC0_0000);
        if (na && !nb) a_nana: assert (mn == b && mx == b);
        if (!na && nb) a_nanb: assert (mn == a && mx == a);
        if (!na && !nb) begin
            a_one_of: assert ((mn == a || mn == b) && (mx == a || mx == b));
            a_min:    assert ((lt_mn_a || eq_mn_a) && (lt_mn_b || eq_mn_b));
            a_max:    assert ((lt_a_mx || eq_a_mx) && (lt_b_mx || eq_b_mx));
            a_symm:   assert (eq_mn12 && eq_mx12);
        end
    end
endmodule
