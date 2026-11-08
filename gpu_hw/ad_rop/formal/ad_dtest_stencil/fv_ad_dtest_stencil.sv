// Stencil write-mask merge: bits outside the write mask never change; byte 3's
// enable (sdiff) is exactly "the written stencil differs"; a failed test uses the
// fail op, a passed one the pass / depth-fail op by dres; compare masks.
module fv_ad_dtest_stencil;
    (* anyconst *) reg [7:0] s_a, sref, cmask, wmask;
    (* anyconst *) reg [2:0] cop, fop, pop, zop;
    (* anyconst *) reg       dres;
    wire spass, sdiff; wire [7:0] swr;
    ad_dtest_stencil dut (.s_a(s_a), .sref(sref), .cmask(cmask), .wmask(wmask), .cop(cop),
                          .fail_op(fop), .pass_op(pop), .zfail_op(zop), .dres(dres),
                          .spass(spass), .swr(swr), .sdiff(sdiff));
    wire [7:0] n_f, n_p, n_z;
    ad_dtest_stencil_op o_f (.op(fop), .s(s_a), .sref(sref), .n(n_f));
    ad_dtest_stencil_op o_p (.op(pop), .s(s_a), .sref(sref), .n(n_p));
    ad_dtest_stencil_op o_z (.op(zop), .s(s_a), .sref(sref), .n(n_z));
    wire [7:0] nsel = !spass ? n_f : dres ? n_p : n_z;
    always @(*) begin
        a_keep_bits: assert ((swr & ~wmask) == (s_a & ~wmask));
        a_new_bits:  assert ((swr & wmask) == (nsel & wmask));
        a_diff:      assert (sdiff == (swr != s_a));
        if (wmask == 8'd0) a_nowrite: assert (!sdiff);
        if (cop == 3'd7) a_always: assert (spass);
        if (cop == 3'd0) a_never:  assert (!spass);
        if (cmask == 8'd0) a_cm0:  assert (spass == (cop == 3'd2 || cop == 3'd3 || cop == 3'd6 || cop == 3'd7));
    end
endmodule
