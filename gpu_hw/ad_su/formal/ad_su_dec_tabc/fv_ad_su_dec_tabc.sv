// fv_ad_su_dec_tabc: properties of the custom half of the opcode table.
// def = 0 (and every output 0) outside custom-0..3; a defined row names one
// unit with its class; feature needs, PAIR/tex and the sub rules of
// ad_su_dec.md §10 (atom sub[3:0] <= 10, texture sub[4] = 0, qd <= 5,
// shfl <= 4, exec.* <= 3, vote <= 1, unpackh <= 1, nop sub 0).
module fv_ad_su_dec_tabc (input wire clk);
`include "ad_su_uop.vh"
    (* anyconst *) reg [6:0] opc;
    (* anyconst *) reg [2:0] f3;
    (* anyconst *) reg [6:0] f7;
    (* anyconst *) reg [4:0] rs2f;
    (* anyconst *) reg [4:0] sub;
    (* anyconst *) reg [1:0] fmt2;
    wire def, use1, use2, use3, wrd, pair, side, need_pk, need_sg, need_sa, tex;
    wire [2:0] fmt, cls;
    wire [3:0] unit;
    wire [7:0] op;
    ad_su_dec_tabc dut (.opc(opc), .f3(f3), .f7(f7), .rs2f(rs2f), .sub(sub), .fmt2(fmt2),
        .def(def), .fmt(fmt), .unit(unit), .op(op), .cls(cls), .use1(use1), .use2(use2),
        .use3(use3), .wrd(wrd), .pair(pair), .side(side), .need_pk(need_pk), .need_sg(need_sg),
        .need_sa(need_sa), .tex(tex));
    wire mine = opc == 7'h0B || opc == 7'h2B || opc == 7'h5B || opc == 7'h7B;
    always @(*) begin
        if (!mine) assert(!def);
        if (!def)
            assert({fmt, unit, op, cls, use1, use2, use3, wrd, pair, side, need_pk, need_sg,
                    need_sa, tex} == 0);
        if (def) begin
            assert(unit != AD_UNIT_FPU || (opc == 7'h7B && f3 == 3'd3));
            assert(cls <= AD_CLS_X && fmt <= 3'd2);
            assert((unit == AD_UNIT_TEX) == (cls == AD_CLS_T));
            assert((unit == AD_UNIT_XU) == (cls == AD_CLS_X));
            assert((unit == AD_UNIT_PK || unit == AD_UNIT_FPU) == (cls == AD_CLS_F));
            if (need_pk) assert(unit == AD_UNIT_PK);
            if (need_sg) assert(unit == AD_UNIT_LANE && op != AD_LANE_QD);
            assert(need_sa == (unit == AD_UNIT_RQ));
            assert(pair == tex);
            if (tex) assert(unit == AD_UNIT_TEX && wrd && use1 && side && !sub[4] && op[1:0] != 2'd3);
            if (unit == AD_UNIT_TEX) assert(!sub[4] && side && wrd);
            if (opc == 7'h0B && f3 == 3'd2) assert(sub[3:0] <= 4'd10 && use3 == (sub[3:0] == 4'd10)
                && unit == (sub[4] ? AD_UNIT_LDS : AD_UNIT_LSU));
            if (unit == AD_UNIT_LANE && op == AD_LANE_QD) assert(sub <= 5'd5);
            if (unit == AD_UNIT_LANE && op == AD_LANE_SHFL) assert(sub <= 5'd4);
            if (unit == AD_UNIT_LANE && op == AD_LANE_VOTE) assert(sub <= 5'd1);
            if (unit == AD_UNIT_EXEC && opc == 7'h7B && f3 == 3'd1) assert(sub <= 5'd3);
            if (unit == AD_UNIT_PK && op == AD_PK_UNPACKH) assert(sub <= 5'd1 && !need_pk);
            if (unit == AD_UNIT_NONE) assert(opc == 7'h7B && f3 == 3'd7 && sub == 0 && f7 == 0);
            if (use3 && unit != AD_UNIT_TEX && unit != AD_UNIT_LSU && unit != AD_UNIT_LDS)
                assert(fmt2 == 2'd0);
        end
        // texsz: imm 0..3 (3 = texsz.s; MS4 in ad_su_dec)
        if (opc == 7'h2B && f3 == 3'd3 && !sub[4])
            assert(def == ({f7, rs2f} <= 12'd3));
        if (opc == 7'h2B && f3 == 3'd3 && {f7, rs2f} == 12'd3)
            assert(!def || (op == 8'h4B && !use1));
        // custom-2 funct7 of fmin2/fmax2, iadd2/isub2/imul2, fcmp2
        if (opc == 7'h5B && f3 == 3'd4) assert(def == (f7 <= 7'd1));
        if (opc == 7'h5B && f3 == 3'd5) assert(def == (f7 <= 7'd2));
        if (opc == 7'h5B && f3 == 3'd6) assert(def == (f7 <= 7'd3) && (!def || op == 8'd9 + f7));
    end
endmodule
