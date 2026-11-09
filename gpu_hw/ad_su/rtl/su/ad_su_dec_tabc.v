/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * ad_su_dec_tabc: the custom half of ad_su_dec's opcode table (custom-0
 * 0001011, custom-1 0101011, custom-2 1011011, custom-3 1111011), the rows
 * of tools/gsi1asm.py's table T.  Combinational.  Every output is 0 when
 * def = 0 (an undefined encoding or an opcode of the other half).
 * fmt: 0 none (R/R4), 1 I, 2 S.  texsz.s (imm 3) is defined here; its
 * MS4 condition is checked by ad_su_dec (no port for it).
 */

module ad_su_dec_tabc (
	input  wire [6:0] opc,
	input  wire [2:0] f3,
	input  wire [6:0] f7,
	input  wire [4:0] rs2f,
	input  wire [4:0] sub,
	input  wire [1:0] fmt2,
	output reg        def,
	output reg  [2:0] fmt,
	output reg  [3:0] unit,
	output reg  [7:0] op,
	output reg  [2:0] cls,
	output reg        use1,
	output reg        use2,
	output reg        use3,
	output reg        wrd,
	output reg        pair,
	output reg        side,
	output reg        need_pk,
	output reg        need_sg,
	output reg        need_sa,
	output reg        tex
);

`include "ad_su_uop.vh"

localparam [6:0] OPC_C0 = 7'h0B, OPC_C1 = 7'h2B, OPC_C2 = 7'h5B, OPC_C3 = 7'h7B;
localparam [2:0] F_NONE = 3'd0, F_I = 3'd1, F_S = 3'd2;

wire [11:0] imm12 = {f7, rs2f};

/* Texture R forms: funct7 [5] the .3 form; texl [4:0] in 0 (plain), 1 (.c),
 * 2/6/10/14 (texg r/g/b/a: gather, component [3:2]), 3 (texg.c); texb 0,
 * 1 (.c), 0x10 (texqlod); texf 0.  op = {qlod, comp, gather, .c, base}. */
wire texl_ok = (f7[4:0] == 5'd0) || (f7[4:0] == 5'd1) || (f7[4:0] == 5'd3) ||
	(f7[4:0] == 5'd2) || (f7[4:0] == 5'd6) || (f7[4:0] == 5'd10) || (f7[4:0] == 5'd14);
wire texb_ok = (f7[4:0] == 5'd0) || (f7[4:0] == 5'd1) || (f7[4:0] == 5'h10);
wire texf_ok = (f7[4:0] == 5'd0);
wire tex_nors2 = f7[1] | f7[4];	/* texg, texqlod: no rs2 */

task row;
	input [3:0] u;
	input [7:0] o;
	input [2:0] c;
	input [2:0] f;
	input       a1, a2, a3, w;
	begin
		def = 1'b1; unit = u; op = o; cls = c; fmt = f;
		use1 = a1; use2 = a2; use3 = a3; wrd = w;
	end
endtask

always @(*) begin
	def = 1'b0; fmt = F_NONE; unit = AD_UNIT_NONE; op = 8'd0; cls = AD_CLS_A;
	use1 = 1'b0; use2 = 1'b0; use3 = 1'b0; wrd = 1'b0; pair = 1'b0; side = 1'b0;
	need_pk = 1'b0; need_sg = 1'b0; need_sa = 1'b0; tex = 1'b0;
	case (opc)
	OPC_C0:
		case (f3)
		3'd0: row(AD_UNIT_LDS, AD_LDS_LDS, AD_CLS_M, F_I, 1, 0, 0, 1);
		3'd1: begin
			row(AD_UNIT_LDS, AD_LDS_STS, AD_CLS_M, F_S, 1, 1, 0, 0);
			side = 1'b1;
		end
		3'd2:	/* atom: sub[3:0] the operation (10 cmpxchg reads rs3), sub[4] shared */
			if (sub[3:0] <= 4'd10) begin
				row(sub[4] ? AD_UNIT_LDS : AD_UNIT_LSU, sub[4] ? AD_LDS_ATOM : AD_LSU_ATOM,
				    AD_CLS_M, F_NONE, 1, 1, sub[3:0] == 4'd10, 1);
				side = 1'b1;
			end
		3'd4: row(AD_UNIT_LSU, AD_LSU_FENCE, AD_CLS_A, F_I, 0, 0, 0, 0);
		3'd5: if (f7 == 7'd0) row(AD_UNIT_EXEC, AD_EXEC_BAR, AD_CLS_A, F_NONE, 0, 0, 0, 0);
		3'd6: row(AD_UNIT_CTL, AD_CTL_WAIT, AD_CLS_A, F_I, 0, 0, 0, 0);
		3'd7: if (f7 == 7'd0) row(AD_UNIT_EXEC, AD_EXEC_END, AD_CLS_A, F_NONE, 0, 0, 0, 0);
		default: ;
		endcase
	OPC_C1:
		case (f3)
		3'd0, 3'd1, 3'd2:
			if (!sub[4] && !f7[6] && ((f3 == 3'd0 && texl_ok) || (f3 == 3'd1 && texb_ok) ||
			    (f3 == 3'd2 && texf_ok))) begin
				row(AD_UNIT_TEX, {1'b0, f7[4], f7[3:2], f7[1], f7[0], f3[1:0]}, AD_CLS_T,
				    F_NONE, 1, !tex_nors2, f7[0] | f7[5], 1);
				side = 1'b1; pair = 1'b1; tex = 1'b1;
			end
		3'd3:	/* texsz: imm 0 (lod in rs1), 1 .l, 2 .d (rs1), 3 .s */
			if (!sub[4] && imm12 <= 12'd3) begin
				row(AD_UNIT_TEX, {1'b0, imm12[0], 2'b00, imm12[1], 3'b011}, AD_CLS_T, F_I, !imm12[0], 0, 0, 1);
				side = 1'b1;
			end
		3'd4: begin
			row(AD_UNIT_EXP, AD_EXP_EXP, AD_CLS_A, F_S, 0, 1, 0, 0);
			side = 1'b1;
		end
		3'd5: row(AD_UNIT_LDA, AD_LDA_LDA, AD_CLS_A, F_I, 0, 0, 0, 1);
		3'd6: if (f7 == 7'd0 && sub <= 5'd5)
			row(AD_UNIT_LANE, AD_LANE_QD, AD_CLS_A, F_NONE, 1, 0, 0, 1);
		default:	/* 7 */
			if (f7 == 7'd0 && sub <= 5'd4) begin
				row(AD_UNIT_LANE, AD_LANE_SHFL, AD_CLS_A, F_NONE, 1, 1, 0, 1);
				need_sg = 1'b1;
			end
		endcase
	OPC_C2:
		case (f3)
		3'd0, 3'd1, 3'd2:	/* fadd2 fsub2 fmul2 */
			if (f7 == 7'd0) begin
				row(AD_UNIT_PK, {5'd0, f3}, AD_CLS_F, F_NONE, 1, 1, 0, 1);
				need_pk = 1'b1;
			end
		3'd3:	/* ffma2 (R4) */
			if (fmt2 == 2'd0) begin
				row(AD_UNIT_PK, AD_PK_FFMA2, AD_CLS_F, F_NONE, 1, 1, 1, 1);
				need_pk = 1'b1;
			end
		3'd4:	/* fmin2 0, fmax2 1 */
			if (f7 <= 7'd1) begin
				row(AD_UNIT_PK, AD_PK_FMIN2 + {7'd0, f7[0]}, AD_CLS_F, F_NONE, 1, 1, 0, 1);
				need_pk = 1'b1;
			end
		3'd5:	/* iadd2 0, isub2 1, imul2 2 */
			if (f7 <= 7'd2) begin
				row(AD_UNIT_PK, AD_PK_IADD2 + {6'd0, f7[1:0]}, AD_CLS_F, F_NONE, 1, 1, 0, 1);
				need_pk = 1'b1;
			end
		3'd6:	/* fcmp2 lt 0, ge 1, eq 2, ne 3 */
			if (f7 <= 7'd3) begin
				row(AD_UNIT_PK, AD_PK_FCMPLT2 + {6'd0, f7[1:0]}, AD_CLS_F, F_NONE, 1, 1, 0, 1);
				need_pk = 1'b1;
			end
		default:	/* 7: packh 0, unpackh 1 (sub 0/1), swaph 2 (packed) */
			if (f7 == 7'd0)
				row(AD_UNIT_PK, AD_PK_PACKH, AD_CLS_F, F_NONE, 1, 1, 0, 1);
			else if (f7 == 7'd1 && sub <= 5'd1)
				row(AD_UNIT_PK, AD_PK_UNPACKH, AD_CLS_F, F_NONE, 1, 0, 0, 1);
			else if (f7 == 7'd2) begin
				row(AD_UNIT_PK, AD_PK_SWAPH, AD_CLS_F, F_NONE, 1, 0, 0, 1);
				need_pk = 1'b1;
			end
		endcase
	OPC_C3:
		if (f3 == 3'd0) begin
			if (fmt2 == 2'd0)	/* sel (R4) */
				row(AD_UNIT_ALU, {3'd0, AD_ALU_SEL}, AD_CLS_A, F_NONE, 1, 1, 1, 1);
		end else if (f7 == 7'd0) begin
			case (f3)
			3'd1:	/* exec.set/and/or (rs1), exec.save (rd) */
				if (sub <= 5'd3)
					row(AD_UNIT_EXEC, AD_EXEC_SET + {6'd0, sub[1:0]}, AD_CLS_A, F_NONE,
					    sub != 5'd3, 0, 0, sub == 5'd3);
			3'd2: row(AD_UNIT_EXEC, AD_EXEC_KILL, AD_CLS_A, F_NONE, 1, 0, 0, 0);
			3'd3:	/* rcp rsq exp2 log2 sin cos; 6 fract */
				if (sub <= 5'd5)
					row(AD_UNIT_XU, {3'd0, sub}, AD_CLS_X, F_NONE, 1, 0, 0, 1);
				else if (sub == 5'd6)
					row(AD_UNIT_FPU, AD_FPU_FRACT, AD_CLS_F, F_NONE, 1, 0, 0, 1);
			3'd4:
				if (sub <= 5'd1) begin
					row(AD_UNIT_LANE, AD_LANE_VOTE, AD_CLS_A, F_NONE, 1, 0, 0, 1);
					need_sg = 1'b1;
				end
			3'd5: begin
				row(AD_UNIT_LANE, AD_LANE_BALLOT, AD_CLS_A, F_NONE, 1, 0, 0, 1);
				need_sg = 1'b1;
			end
			3'd6: begin
				row(AD_UNIT_RQ, AD_RQ_SACTL, AD_CLS_A, F_NONE, 1, 0, 0, 0);
				need_sa = 1'b1;
			end
			default:	/* 7: nop */
				if (sub == 5'd0)
					row(AD_UNIT_NONE, 8'd0, AD_CLS_A, F_NONE, 0, 0, 0, 0);
			endcase
		end
	default: ;
	endcase
end

endmodule
