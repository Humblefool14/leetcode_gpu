// fv_ad_ctl_sb_ovl -- the overlap checker equals a reference interval check
// (operand n is a GPR when n < 63; entry e covers [base, base + 1 or 4)).
module fv_ad_ctl_sb_ovl (input wire clk);
    (* anyconst *) reg [4:0]  src_use;
    (* anyconst *) reg [39:0] src;
    (* anyconst *) reg        dst_use, dst_w4;
    (* anyconst *) reg [5:0]  dst;
    (* anyconst *) reg [3:0]  e_valid, e_w4;
    (* anyconst *) reg [23:0] e_base;
    wire src_hit, dst_hit;
    ad_ctl_sb_ovl #(.NE(4)) dut (.src_use(src_use), .src(src), .dst_use(dst_use), .dst(dst), .dst_w4(dst_w4),
        .e_valid(e_valid), .e_base(e_base), .e_w4(e_w4), .src_hit(src_hit), .dst_hit(dst_hit));
    // reference: enumerate every register 0..62 and ask whether it is in both sets
    reg rs, rd_;
    integer r, e, s;
    reg in_e, in_s, in_d;
    always @(*) begin
        rs = 1'b0; rd_ = 1'b0;
        for (r = 0; r < 63; r = r + 1) begin
            in_e = 1'b0;
            for (e = 0; e < 4; e = e + 1)
                if (e_valid[e] && (r == e_base[6*e +: 6] || (e_w4[e] && r > e_base[6*e +: 6] && r <= e_base[6*e +: 6] + 3)))
                    in_e = 1'b1;
            in_s = 1'b0;
            for (s = 0; s < 5; s = s + 1) if (src_use[s] && src[8*s +: 8] == r) in_s = 1'b1;
            in_d = dst_use && (r == dst || (dst_w4 && r > dst && r <= dst + 3));
            if (in_e && in_s) rs = 1'b1;
            if (in_e && in_d) rd_ = 1'b1;
        end
    end
    // dst overlap of registers above 62 (a long entry reaching 63+ never exists:
    // ad_su_dec keeps rd + width within the GPRs) is excluded by the assumption
    integer q;
    always @(*) begin
        for (q = 0; q < 4; q = q + 1) assume (!(e_valid[q] && e_base[6*q +: 6] + (e_w4[q] ? 3 : 0) > 62));
        assume (!(dst_use && dst + (dst_w4 ? 3 : 0) > 62));
        a_src: assert (src_hit == rs);
        a_dst: assert (dst_hit == rd_);
    end
endmodule
