/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * ad_su_dec_chk: the ISA-fault checker of ad_su_dec (spec/gpu/su/ad_su_dec.md
 * §4, §10).  Faults: an undefined encoding (def = 0), a feature the
 * parameters leave out (PACKED, SUBGROUP, HAS_SA, MS4), a source GPR
 * >= NREGS (63 is rq: only with HAS_SA; 64-127 constants and specials are
 * fine), a destination >= 64, rq as a destination without HAS_SA or for a
 * class other than a or several destinations, a destination range past
 * NREGS or 63, a PAIR rs1+1 or a texture .c/.3 rs1+2 (and rs1+3 for .3.c)
 * outside the GPRs (below min(NREGS, 63)) or outside the 32 constants /
 * 32 specials.  Also the effective rs3 (rs1+2 for .c/.3), the destination
 * count and the rq flags.  Combinational.
 */

module ad_su_dec_chk #(
	parameter NREGS = 32,
	parameter PACKED = 0,
	parameter SUBGROUP = 0,
	parameter HAS_SA = 0,
	parameter MS4 = 0
) (
	input  wire       def,
	input  wire       need_pk,
	input  wire       need_sg,
	input  wire       need_sa,
	input  wire       need_ms4,
	input  wire [2:0] cls,
	input  wire       use1,
	input  wire       use2,
	input  wire       use3,
	input  wire       wrd,
	input  wire       pair,
	input  wire       tex,
	input  wire       cmp,		/* texture .c: Dref in rs1+2 (rs1+3 with .3) */
	input  wire       three,	/* texture .3: third coordinate in rs1+2 */
	input  wire [6:0] rd,
	input  wire [6:0] rs1,
	input  wire [6:0] rs2,
	input  wire [6:0] rs3,
	output wire [6:0] rs3e,
	output wire [2:0] ndst,
	output wire       rqs,
	output wire       rqd,
	output wire       ill
);

`include "ad_su_uop.vh"

localparam integer LIM = (NREGS < 63) ? NREGS : 63;

/* rs1 + k must stay in rs1's bank: the GPRs below LIM, c0-c31, 96-127. */
function ext_bad;
	input [6:0] r;
	input [1:0] k;
	begin
		if (!r[6])
			ext_bad = ({25'd0, r} + {30'd0, k}) >= LIM;
		else
			ext_bad = ({1'b0, r[4:0]} + {4'd0, k}) > 6'd31;
	end
endfunction

function src_bad;
	input [6:0] r;
	begin
		if (r == 7'd63)
			src_bad = (HAS_SA == 0);
		else
			src_bad = !r[6] && ({25'd0, r} >= NREGS);
	end
endfunction

wire ext = cmp | three;
`ifdef MUT_DEC_RS3
assign rs3e = rs3;	/* mutation: .c/.3 forms keep the encoded rs3 */
`else
assign rs3e = ext ? rs1 + 7'd2 : rs3;
`endif
assign ndst = wrd ? (tex ? 3'd4 : 3'd1) : 3'd0;
assign rqs = (use1 && rs1 == 7'd63) || (use2 && rs2 == 7'd63) || (use3 && rs3e == 7'd63);
assign rqd = wrd && rd == 7'd63;

wire f_need = (need_pk && PACKED == 0) || (need_sg && SUBGROUP == 0) ||
	(need_sa && HAS_SA == 0) || (need_ms4 && MS4 == 0);
wire f_pair = pair && ext_bad(rs1, 2'd1);
wire f_ext = ext && ext_bad(rs1, (cmp && three) ? 2'd3 : 2'd2);
wire f_src = (use1 && src_bad(rs1)) || (use2 && src_bad(rs2)) || (use3 && src_bad(rs3e));
wire [7:0] rd_end = {1'b0, rd} + {5'd0, ndst};
wire f_rd = wrd && (rd[6] ||
	(rd == 7'd63 ? (HAS_SA == 0 || cls != AD_CLS_A || tex) :
	 ({24'd0, rd_end} > NREGS || rd_end > 8'd63)));

assign ill = !def || f_need || f_pair || f_ext || f_src || f_rd;

endmodule
