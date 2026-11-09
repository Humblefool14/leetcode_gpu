// fv_ad_dec_chk: the fault checker for any table output (free inputs):
// no fault implies every read operand and the written range legal
// (ad_su_dec.md §4/§10); each fault cause alone faults; rs3e/ndst/rq flags.
module fv_ad_dec_chk #(
    parameter NREGS = 32, parameter PACKED = 0, parameter SUBGROUP = 0,
    parameter HAS_SA = 0, parameter MS4 = 0
) (input wire clk);
`include "ad_su_uop.vh"
    (* anyconst *) reg def, need_pk, need_sg, need_sa, need_ms4, use1, use2, use3, wrd, pair,
                       tex, cmp, three;
    (* anyconst *) reg [2:0] cls;
    (* anyconst *) reg [6:0] rd, rs1, rs2, rs3;
    wire [6:0] rs3e;
    wire [2:0] ndst;
    wire rqs, rqd, ill;
    ad_su_dec_chk #(.NREGS(NREGS), .PACKED(PACKED), .SUBGROUP(SUBGROUP), .HAS_SA(HAS_SA),
        .MS4(MS4)) dut (.def(def), .need_pk(need_pk), .need_sg(need_sg), .need_sa(need_sa),
        .need_ms4(need_ms4), .cls(cls), .use1(use1), .use2(use2), .use3(use3), .wrd(wrd),
        .pair(pair), .tex(tex), .cmp(cmp), .three(three), .rd(rd), .rs1(rs1), .rs2(rs2),
        .rs3(rs3), .rs3e(rs3e), .ndst(ndst), .rqs(rqs), .rqd(rqd), .ill(ill));
    localparam integer LIM = NREGS < 63 ? NREGS : 63;
    function ok;
        input [6:0] r;
        ok = r >= 64 || (r == 63 ? HAS_SA != 0 : r < NREGS);
    endfunction
    // the last register of rs1's bank
    wire [7:0] bank_end = rs1 < 64 ? LIM - 1 : (rs1 < 96 ? 95 : 127);
    always @(*) begin
        assert(rs3e == ((cmp || three) ? rs1 + 7'd2 : rs3));
        assert(ndst == (!wrd ? 0 : tex ? 4 : 1));
        assert(rqd == (wrd && rd == 63));
        assert(rqs == ((use1 && rs1 == 63) || (use2 && rs2 == 63) || (use3 && rs3e == 63)));
        if (!def || (need_pk && !PACKED) || (need_sg && !SUBGROUP) || (need_sa && !HAS_SA) ||
            (need_ms4 && !MS4)) assert(ill);
        if (!ill) begin
            if (use1) assert(ok(rs1));
            if (use2) assert(ok(rs2));
            if (use3) assert(ok(rs3e));
            if (pair) assert(rs1 + 1 <= bank_end);
            if (cmp || three) assert(rs1 + ((cmp && three) ? 3 : 2) <= bank_end);
            if (wrd) assert(rd < 63 ? rd + ndst <= LIM : (rd == 63 && HAS_SA != 0 &&
                                                          cls == AD_CLS_A && !tex));
        end
        // a clean instruction does not fault
        if (def && !need_pk && !need_sg && !need_sa && !need_ms4 && !pair && !cmp && !three &&
            !use1 && !use2 && !use3 && (!wrd || (rd + 1 <= LIM && !tex)))
            assert(!ill);
        if (def && !need_pk && !need_sg && !need_sa && !need_ms4 && pair && !cmp && !three &&
            use1 && rs1 + 2 <= LIM && !use2 && !use3 && !wrd)
            assert(!ill);
    end
endmodule
