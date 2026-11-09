// fv_ad_su_dec_tab: properties of the RISC-V half of the opcode table.
// def = 0 (and every output 0) outside OP/OP-IMM/LUI/LOAD/STORE/BRANCH/
// OP-FP/MADD..NMADD; a defined row names one unit of this half with a legal
// class and format; the half never asks for custom features.
module fv_ad_su_dec_tab (input wire clk);
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
    ad_su_dec_tab dut (.opc(opc), .f3(f3), .f7(f7), .rs2f(rs2f), .sub(sub), .fmt2(fmt2),
        .def(def), .fmt(fmt), .unit(unit), .op(op), .cls(cls), .use1(use1), .use2(use2),
        .use3(use3), .wrd(wrd), .pair(pair), .side(side), .need_pk(need_pk), .need_sg(need_sg),
        .need_sa(need_sa), .tex(tex));
    wire mine = opc == 7'h33 || opc == 7'h13 || opc == 7'h37 || opc == 7'h03 || opc == 7'h23 ||
        opc == 7'h63 || opc == 7'h53 || opc == 7'h43 || opc == 7'h47 || opc == 7'h4B ||
        opc == 7'h4F;
    wire [7:0] ophi = op >> 5;
    always @(*) begin
        if (!mine) assert(!def);
        if (!def)
            assert({fmt, unit, op, cls, use1, use2, use3, wrd, pair, side, need_pk, need_sg,
                    need_sa, tex} == 0);
        if (def) begin
            assert(unit == AD_UNIT_ALU || unit == AD_UNIT_FPU || unit == AD_UNIT_XU ||
                   unit == AD_UNIT_DIV || unit == AD_UNIT_LSU || unit == AD_UNIT_CBANK ||
                   unit == AD_UNIT_EXEC);
            assert(cls <= AD_CLS_X && fmt <= 3'd4);
            assert(!pair && !tex && !need_pk && !need_sg && !need_sa);
            // the class follows the unit
            assert((unit == AD_UNIT_LSU || unit == AD_UNIT_CBANK) == (cls == AD_CLS_M));
            assert((unit == AD_UNIT_XU || unit == AD_UNIT_DIV) == (cls == AD_CLS_X));
            assert((unit == AD_UNIT_FPU) == (cls == AD_CLS_F));
            // side effects: sw only; rm 5/6 never defined on OP-FP and R4
            assert(side == (opc == 7'h23));
            if (opc == 7'h53 || opc == 7'h43 || opc == 7'h47 || opc == 7'h4B || opc == 7'h4F)
                assert(f3 != 3'd5 && f3 != 3'd6);
            // ALU: I forms (OP-IMM) have OP bit 7 and read no rs2
            if (unit == AD_UNIT_ALU) assert(op[AD_ALU_IMMB] == (opc == 7'h13) && ophi[1:0] == 0);
            if (opc == 7'h13) assert(!use2 && fmt == 3'd1);
            if (unit == AD_UNIT_EXEC) assert(op == {5'd0, f3} && fmt == 3'd3 && !wrd);
            if (use3) assert(opc[6:4] == 3'b100);
            if (opc == 7'h37) assert(fmt == 3'd4 && !use1 && !use2 && wrd);
        end
        // a few rows transcribed from tools/gsi1asm.py T
        if (opc == 7'h33 && f7 == 7'h01 && f3 == 3'd6)	// rem
            assert(def && unit == AD_UNIT_DIV && op == AD_DIV_REM && use1 && use2 && wrd);
        if (opc == 7'h53 && f7 == 7'h20 && rs2f == 5'd4)	// fround: rm 0-3
            assert(def == (f3 <= 3'd3));
        if (opc == 7'h23 && f3 == 3'd2)	// sw / sw.x
            assert(def == (sub <= 5'd1));
        if (opc == 7'h63)
            assert(def == (f3 <= 3'd5) && (!def || use1 == (f3 <= 3'd2)));
    end
endmodule
