// fv_ad_core_opd_plan -- ad_su_opd_plan: the operand numbers of each pass (pass 0: rs1,
// rs2, PAIR ? rs1+1 : rs3; pass 1: rs3, rs2, rs3+1) and their use; a GPR is a used
// operand below 63; two read slots exactly with three GPR operands (slot 0 = a and b,
// slot 1 = c); with one slot every GPR operand has a port of its own reading it.
module fv_ad_core_opd_plan (input wire clk);
    (* anyconst *) reg [6:0] rs1, rs2, rs3; (* anyconst *) reg u1, u2, u3, pair, pass;
    wire [6:0] na, nb, nc; wire ua, ub, uc, ga, gb, gc, two, bp2, cp2; wire [5:0] s0r1, s0r2, s1r1;
    ad_su_opd_plan dut (.rs1(rs1), .rs2(rs2), .rs3(rs3), .use1(u1), .use2(u2), .use3(u3), .pair(pair), .pass(pass),
        .na(na), .nb(nb), .nc(nc), .ua(ua), .ub(ub), .uc(uc), .ga(ga), .gb(gb), .gc(gc), .two(two),
        .s0_r1(s0r1), .s0_r2(s0r2), .s1_r1(s1r1), .b_p2(bp2), .c_p2(cp2));
    always @(*) begin
        assert (na == (pass ? rs3 : rs1) && nb == rs2 && nc == (pass ? rs3 + 7'd1 : pair ? rs1 + 7'd1 : rs3));
        assert (ua == (pass || u1) && ub == u2 && uc == (pass || pair || u3));
        assert (ga == (ua && na < 63) && gb == (ub && nb < 63) && gc == (uc && nc < 63));
        assert (two == (ga && gb && gc));
        if (two) assert (s0r1 == na[5:0] && s0r2 == nb[5:0] && s1r1 == nc[5:0]);
        else begin
            if (ga) assert (s0r1 == na[5:0]);
            if (gb) assert ((bp2 ? s0r2 : s0r1) == nb[5:0]);
            if (gc) assert ((cp2 ? s0r2 : s0r1) == nc[5:0]);
            if (ga && gb) assert (bp2);                  // distinct ports
            if (gc && (ga || gb)) assert (cp2);
        end
    end
endmodule
