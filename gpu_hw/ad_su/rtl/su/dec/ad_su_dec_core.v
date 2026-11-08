/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * ad_su_dec_core: the combinational decode of one 64-bit GSI1 instruction
 * into the uop of include/ad_su_uop.vh, bit for bit tools/gsi1asm.py's
 * decode(word, cfg).  ad_su_dec registers it.  Children: ad_su_dec_fld
 * (fields, operand numbers), ad_su_dec_tab (RISC-V opcodes),
 * ad_su_dec_tabc (custom-0..3), ad_su_dec_imm (immediate), ad_su_dec_chk
 * (faults).  An ILL uop has only the ILL bit set.  U forms (lui) carry RS1-3,
 * MOD, HSEL, SUB and RM 0; the other forms carry every operand field as
 * encoded and RM = funct3.
 */

module ad_su_dec_core #(
	parameter UOP_W = 108,
	parameter NREGS = 32,
	parameter PACKED = 0,
	parameter SUBGROUP = 0,
	parameter HAS_SA = 0,
	parameter MS4 = 0
) (
	input  wire [63:0]      instr,
	output wire [UOP_W-1:0] uop
);

`include "ad_su_uop.vh"

wire [6:0] opc, f7, rd, rs1, rs2, rs3, mods;
wire [2:0] f3;
wire [4:0] rs2f, sub;
wire [1:0] fmt2, hsel;
wire [11:0] imm12;

ad_su_dec_fld u_fld (
	.instr(instr), .opc(opc), .f3(f3), .f7(f7), .rs2f(rs2f), .fmt2(fmt2), .imm12(imm12),
	.rd(rd), .rs1(rs1), .rs2(rs2), .rs3(rs3), .mods(mods), .hsel(hsel), .sub(sub)
);

wire a_def, a_use1, a_use2, a_use3, a_wrd, a_pair, a_side, a_pk, a_sg, a_sa, a_tex;
wire b_def, b_use1, b_use2, b_use3, b_wrd, b_pair, b_side, b_pk, b_sg, b_sa, b_tex;
wire [2:0] a_fmt, b_fmt, a_cls, b_cls;
wire [3:0] a_unit, b_unit;
wire [7:0] a_op, b_op;

ad_su_dec_tab u_tab (
	.opc(opc), .f3(f3), .f7(f7), .rs2f(rs2f), .sub(sub), .fmt2(fmt2),
	.def(a_def), .fmt(a_fmt), .unit(a_unit), .op(a_op), .cls(a_cls),
	.use1(a_use1), .use2(a_use2), .use3(a_use3), .wrd(a_wrd), .pair(a_pair), .side(a_side),
	.need_pk(a_pk), .need_sg(a_sg), .need_sa(a_sa), .tex(a_tex)
);

ad_su_dec_tabc u_tabc (
	.opc(opc), .f3(f3), .f7(f7), .rs2f(rs2f), .sub(sub), .fmt2(fmt2),
	.def(b_def), .fmt(b_fmt), .unit(b_unit), .op(b_op), .cls(b_cls),
	.use1(b_use1), .use2(b_use2), .use3(b_use3), .wrd(b_wrd), .pair(b_pair), .side(b_side),
	.need_pk(b_pk), .need_sg(b_sg), .need_sa(b_sa), .tex(b_tex)
);

/* The halves are 0 outside their opcodes: OR them. */
wire       def = a_def | b_def;
wire [2:0] fmt = a_fmt | b_fmt;
wire [3:0] unit = a_unit | b_unit;
wire [7:0] op = a_op | b_op;
wire [2:0] cls = a_cls | b_cls;
wire       use1 = a_use1 | b_use1;
wire       use2 = a_use2 | b_use2;
wire       use3 = a_use3 | b_use3;
wire       wrd = a_wrd | b_wrd;
wire       pair = a_pair | b_pair;
wire       side = a_side | b_side;
wire       tex = a_tex | b_tex;

wire istex = (unit == AD_UNIT_TEX);
wire cmp = tex & op[AD_TEX_CFORM];
wire three = tex & f7[5];
wire need_ms4 = (opc == 7'h2B) && (f3 == 3'd3) && (imm12 == 12'd3);	/* texsz.s */

wire [31:0] imm;
ad_su_dec_imm u_imm (.instr(instr), .fmt(fmt), .tex(istex), .imm(imm));

wire [6:0] rs3e;
wire [2:0] ndst;
wire rqs, rqd, ill;

ad_su_dec_chk #(
	.NREGS(NREGS), .PACKED(PACKED), .SUBGROUP(SUBGROUP), .HAS_SA(HAS_SA), .MS4(MS4)
) u_chk (
	.def(def), .need_pk(a_pk | b_pk), .need_sg(a_sg | b_sg), .need_sa(a_sa | b_sa),
	.need_ms4(need_ms4), .cls(cls), .use1(use1), .use2(use2), .use3(use3), .wrd(wrd),
	.pair(pair), .tex(tex), .cmp(cmp), .three(three), .rd(rd), .rs1(rs1), .rs2(rs2),
	.rs3(rs3), .rs3e(rs3e), .ndst(ndst), .rqs(rqs), .rqd(rqd), .ill(ill)
);

wire ufmt = (fmt == 3'd4);

reg [UOP_W-1:0] u;
always @(*) begin
	u = {UOP_W{1'b0}};
	if (ill) begin
		u[AD_UOP_ILL] = 1'b1;
	end else begin
		u[AD_UOP_UNIT +: 4] = unit;
		u[AD_UOP_OP +: 8] = op;
		u[AD_UOP_RD +: 7] = rd;
		u[AD_UOP_RS1 +: 7] = ufmt ? 7'd0 : rs1;
		u[AD_UOP_RS2 +: 7] = ufmt ? 7'd0 : rs2;
		u[AD_UOP_RS3 +: 7] = ufmt ? 7'd0 : rs3e;
		u[AD_UOP_IMM +: 32] = imm;
		u[AD_UOP_MOD +: 7] = ufmt ? 7'd0 : mods;
		u[AD_UOP_HSEL +: 2] = ufmt ? 2'd0 : hsel;
		u[AD_UOP_SUB +: 5] = ufmt ? 5'd0 : {sub[4] | three, sub[3:0]};
		u[AD_UOP_RM +: 3] = ufmt ? 3'd0 : f3;
		u[AD_UOP_CLS +: 3] = cls;
		u[AD_UOP_NDST +: 3] = ndst;
		u[AD_UOP_USE1] = use1;
		u[AD_UOP_USE2] = use2;
		u[AD_UOP_USE3] = use3;
		u[AD_UOP_WRD] = wrd;
		u[AD_UOP_PAIR] = pair;
		u[AD_UOP_RQS] = rqs;
		u[AD_UOP_RQD] = rqd;
		u[AD_UOP_SIDE] = side;
		u[AD_UOP_SAMP_SLOT +: 4] = istex ? instr[41:38] : 4'd0;
	end
end
assign uop = u;

endmodule
