// VkStencilOp properties: KEEP is the identity, INVERT an involution, the clamp ops
// saturate, the wrap ops are modulo 256 (and undo each other), ZERO/REPLACE.
module fv_ad_dtest_stencil_op;
    (* anyconst *) reg [7:0] s;
    (* anyconst *) reg [7:0] r;
    (* anyconst *) reg [2:0] op;
    wire [7:0] n_op, n_keep, n_zero, n_rep, n_ic, n_dc, n_inv, n_inv2, n_iw, n_dw, n_iwdw;
    ad_dtest_stencil_op u_op   (.op(op),   .s(s),     .sref(r), .n(n_op));
    ad_dtest_stencil_op u_keep (.op(3'd0), .s(s),     .sref(r), .n(n_keep));
    ad_dtest_stencil_op u_zero (.op(3'd1), .s(s),     .sref(r), .n(n_zero));
    ad_dtest_stencil_op u_rep  (.op(3'd2), .s(s),     .sref(r), .n(n_rep));
    ad_dtest_stencil_op u_ic   (.op(3'd3), .s(s),     .sref(r), .n(n_ic));
    ad_dtest_stencil_op u_dc   (.op(3'd4), .s(s),     .sref(r), .n(n_dc));
    ad_dtest_stencil_op u_inv  (.op(3'd5), .s(s),     .sref(r), .n(n_inv));
    ad_dtest_stencil_op u_inv2 (.op(3'd5), .s(n_inv), .sref(r), .n(n_inv2));
    ad_dtest_stencil_op u_iw   (.op(3'd6), .s(s),     .sref(r), .n(n_iw));
    ad_dtest_stencil_op u_dw   (.op(3'd7), .s(s),     .sref(r), .n(n_dw));
    ad_dtest_stencil_op u_iwdw (.op(3'd7), .s(n_iw),  .sref(r), .n(n_iwdw));
    always @(*) begin
        a_keep:   assert (n_keep == s);
        a_zero:   assert (n_zero == 8'd0);
        a_rep:    assert (n_rep == r);
        a_inv:    assert (n_inv2 == s && (n_inv ^ s) == 8'hFF);
        a_ic_sat: assert (s == 8'hFF ? n_ic == 8'hFF : n_ic == s + 8'd1);
        a_ic_mon: assert (n_ic >= s);
        a_dc_sat: assert (s == 8'h00 ? n_dc == 8'h00 : n_dc == s - 8'd1);
        a_dc_mon: assert (n_dc <= s);
        a_iw_mod: assert ({1'b0, n_iw} == ({1'b0, s} + 9'd1) % 9'd256);
        a_dw_mod: assert ({1'b0, n_dw} == ({1'b0, s} + 9'd255) % 9'd256);
        a_wrap:   assert (n_iwdw == s);
        a_sel:    assert (n_op == (op == 0 ? n_keep : op == 1 ? n_zero : op == 2 ? n_rep : op == 3 ? n_ic :
                                   op == 4 ? n_dc : op == 5 ? n_inv : op == 6 ? n_iw : n_dw));
    end
endmodule
