/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * ad_su_dec_tab: the RISC-V half of ad_su_dec's opcode table (OP, OP-IMM,
 * LUI, LOAD, STORE, BRANCH, OP-FP, MADD/MSUB/NMSUB/NMADD), the rows of
 * tools/gsi1asm.py's table T.  Combinational.  Every output is 0 when
 * def = 0 (an undefined encoding or an opcode of the other half).
 * fmt: 0 none (R/R4), 1 I, 2 S, 3 B, 4 U.
 */

module ad_su_dec_tab (
	input  wire [6:0] opc,
	input  wire [2:0] f3,
	input  wire [6:0] f7,
	input  wire [4:0] rs2f,
	/* verilator lint_off UNUSEDSIGNAL */
	input  wire [4:0] sub,	/* only sub[4:1] (STORE) */
	/* verilator lint_on UNUSEDSIGNAL */
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

localparam [6:0] OPC_OP = 7'h33, OPC_OPIMM = 7'h13, OPC_LUI = 7'h37, OPC_LOAD = 7'h03,
	OPC_STORE = 7'h23, OPC_BRANCH = 7'h63, OPC_OPFP = 7'h53, OPC_MADD = 7'h43,
	OPC_MSUB = 7'h47, OPC_NMSUB = 7'h4B, OPC_NMADD = 7'h4F;
localparam [2:0] F_NONE = 3'd0, F_I = 3'd1, F_S = 3'd2, F_B = 3'd3, F_U = 3'd4;

/* rm 5 and 6 are faults (7 = dynamic = RNE). */
wire rmok = (f3 != 3'd5) && (f3 != 3'd6);

/* A defined row: unit, op, class, format, use1/2/3, wrd. */
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
	OPC_OP:
		case (f7)
		7'h00:
			case (f3)
			3'd0: row(AD_UNIT_ALU, {3'd0, AD_ALU_ADD}, AD_CLS_A, F_NONE, 1, 1, 0, 1);
			3'd1: row(AD_UNIT_ALU, {3'd0, AD_ALU_SLL}, AD_CLS_A, F_NONE, 1, 1, 0, 1);
			3'd2: row(AD_UNIT_ALU, {3'd0, AD_ALU_SLT}, AD_CLS_A, F_NONE, 1, 1, 0, 1);
			3'd3: row(AD_UNIT_ALU, {3'd0, AD_ALU_SLTU}, AD_CLS_A, F_NONE, 1, 1, 0, 1);
			3'd4: row(AD_UNIT_ALU, {3'd0, AD_ALU_XOR}, AD_CLS_A, F_NONE, 1, 1, 0, 1);
			3'd5: row(AD_UNIT_ALU, {3'd0, AD_ALU_SRL}, AD_CLS_A, F_NONE, 1, 1, 0, 1);
			3'd6: row(AD_UNIT_ALU, {3'd0, AD_ALU_OR}, AD_CLS_A, F_NONE, 1, 1, 0, 1);
			default: row(AD_UNIT_ALU, {3'd0, AD_ALU_AND}, AD_CLS_A, F_NONE, 1, 1, 0, 1);
			endcase
		7'h20:
			case (f3)
			3'd0: row(AD_UNIT_ALU, {3'd0, AD_ALU_SUB}, AD_CLS_A, F_NONE, 1, 1, 0, 1);
			3'd4: row(AD_UNIT_ALU, {3'd0, AD_ALU_XNOR}, AD_CLS_A, F_NONE, 1, 1, 0, 1);
			3'd5: row(AD_UNIT_ALU, {3'd0, AD_ALU_SRA}, AD_CLS_A, F_NONE, 1, 1, 0, 1);
			3'd6: row(AD_UNIT_ALU, {3'd0, AD_ALU_ORN}, AD_CLS_A, F_NONE, 1, 1, 0, 1);
			3'd7: row(AD_UNIT_ALU, {3'd0, AD_ALU_ANDN}, AD_CLS_A, F_NONE, 1, 1, 0, 1);
			default: ;
			endcase
		7'h05:	/* Zbb min/max */
			case (f3)
			3'd4: row(AD_UNIT_ALU, {3'd0, AD_ALU_MIN}, AD_CLS_A, F_NONE, 1, 1, 0, 1);
			3'd5: row(AD_UNIT_ALU, {3'd0, AD_ALU_MINU}, AD_CLS_A, F_NONE, 1, 1, 0, 1);
			3'd6: row(AD_UNIT_ALU, {3'd0, AD_ALU_MAX}, AD_CLS_A, F_NONE, 1, 1, 0, 1);
			3'd7: row(AD_UNIT_ALU, {3'd0, AD_ALU_MAXU}, AD_CLS_A, F_NONE, 1, 1, 0, 1);
			default: ;
			endcase
		7'h01:	/* M: mul* on the FPU, div/rem on the divider */
			if (!f3[2])
				row(AD_UNIT_FPU, AD_FPU_MUL + {6'd0, f3[1:0]}, AD_CLS_F, F_NONE, 1, 1, 0, 1);
			else
				row(AD_UNIT_DIV, AD_DIV_DIV + {6'd0, f3[1:0]}, AD_CLS_X, F_NONE, 1, 1, 0, 1);
		default: ;
		endcase
	OPC_OPIMM:
		case (f3)
		3'd0: row(AD_UNIT_ALU, {3'b100, AD_ALU_ADD}, AD_CLS_A, F_I, 1, 0, 0, 1);
		3'd2: row(AD_UNIT_ALU, {3'b100, AD_ALU_SLT}, AD_CLS_A, F_I, 1, 0, 0, 1);
		3'd3: row(AD_UNIT_ALU, {3'b100, AD_ALU_SLTU}, AD_CLS_A, F_I, 1, 0, 0, 1);
		3'd4: row(AD_UNIT_ALU, {3'b100, AD_ALU_XOR}, AD_CLS_A, F_I, 1, 0, 0, 1);
		3'd6: row(AD_UNIT_ALU, {3'b100, AD_ALU_OR}, AD_CLS_A, F_I, 1, 0, 0, 1);
		3'd7: row(AD_UNIT_ALU, {3'b100, AD_ALU_AND}, AD_CLS_A, F_I, 1, 0, 0, 1);
		3'd1:
			if (f7 == 7'h00)
				row(AD_UNIT_ALU, {3'b100, AD_ALU_SLL}, AD_CLS_A, F_I, 1, 0, 0, 1);
		default:	/* 5 */
			if (f7 == 7'h00)
				row(AD_UNIT_ALU, {3'b100, AD_ALU_SRL}, AD_CLS_A, F_I, 1, 0, 0, 1);
			else if (f7 == 7'h20)
				row(AD_UNIT_ALU, {3'b100, AD_ALU_SRA}, AD_CLS_A, F_I, 1, 0, 0, 1);
		endcase
	OPC_LUI:
		row(AD_UNIT_ALU, {3'd0, AD_ALU_MOVI}, AD_CLS_A, F_U, 0, 0, 0, 1);
	OPC_LOAD:
		if (f3 == 3'd2)
			row(AD_UNIT_LSU, AD_LSU_LW, AD_CLS_M, F_I, 1, 0, 0, 1);
		else if (f3 == 3'd6)
			row(AD_UNIT_CBANK, AD_CBANK_LWC, AD_CLS_M, F_I, 1, 0, 0, 1);
	OPC_STORE:
		/* sub 0 sw, 1 sw.x */
		if (f3 == 3'd2 && sub[4:1] == 4'd0) begin
			row(AD_UNIT_LSU, AD_LSU_SW, AD_CLS_M, F_S, 1, 1, 0, 0);
			side = 1'b1;
		end
	OPC_BRANCH:
		/* bany bnone ball (rs1's Boolean), j bexnz bexz */
		if (f3 <= 3'd5)
			row(AD_UNIT_EXEC, {5'd0, f3}, AD_CLS_A, F_B, f3 <= 3'd2, 0, 0, 0);
	OPC_OPFP:
		case (f7)
		7'h00: if (rmok) row(AD_UNIT_FPU, AD_FPU_FADD, AD_CLS_F, F_NONE, 1, 1, 0, 1);
		7'h04: if (rmok) row(AD_UNIT_FPU, AD_FPU_FSUB, AD_CLS_F, F_NONE, 1, 1, 0, 1);
		7'h08: if (rmok) row(AD_UNIT_FPU, AD_FPU_FMUL, AD_CLS_F, F_NONE, 1, 1, 0, 1);
		7'h10: if (f3 == 3'd0) row(AD_UNIT_FPU, AD_FPU_FSGNJ, AD_CLS_F, F_NONE, 1, 1, 0, 1);
		7'h14:
			if (f3 == 3'd0)
				row(AD_UNIT_FPU, AD_FPU_FMIN, AD_CLS_F, F_NONE, 1, 1, 0, 1);
			else if (f3 == 3'd1)
				row(AD_UNIT_FPU, AD_FPU_FMAX, AD_CLS_F, F_NONE, 1, 1, 0, 1);
		7'h2C:
			if (rmok && rs2f == 5'd0)
				row(AD_UNIT_XU, AD_XU_FSQRT, AD_CLS_X, F_NONE, 1, 0, 0, 1);
		7'h60:
			if (rmok && rs2f == 5'd0)
				row(AD_UNIT_FPU, AD_FPU_FCVTWS, AD_CLS_F, F_NONE, 1, 0, 0, 1);
			else if (rmok && rs2f == 5'd1)
				row(AD_UNIT_FPU, AD_FPU_FCVTWUS, AD_CLS_F, F_NONE, 1, 0, 0, 1);
		7'h68:
			if (rmok && rs2f == 5'd0)
				row(AD_UNIT_FPU, AD_FPU_FCVTSW, AD_CLS_F, F_NONE, 1, 0, 0, 1);
			else if (rmok && rs2f == 5'd1)
				row(AD_UNIT_FPU, AD_FPU_FCVTSWU, AD_CLS_F, F_NONE, 1, 0, 0, 1);
		7'h50:
			case (f3)
			3'd0: row(AD_UNIT_FPU, AD_FPU_FLE, AD_CLS_F, F_NONE, 1, 1, 0, 1);
			3'd1: row(AD_UNIT_FPU, AD_FPU_FLT, AD_CLS_F, F_NONE, 1, 1, 0, 1);
			3'd2: row(AD_UNIT_FPU, AD_FPU_FEQ, AD_CLS_F, F_NONE, 1, 1, 0, 1);
			3'd3: row(AD_UNIT_FPU, AD_FPU_FNE, AD_CLS_F, F_NONE, 1, 1, 0, 1);
			default: ;
			endcase
		7'h20:	/* fround: rm 0-3 only */
			if (rs2f == 5'd4 && !f3[2])
				row(AD_UNIT_FPU, AD_FPU_FROUND, AD_CLS_F, F_NONE, 1, 0, 0, 1);
		default: ;
		endcase
	OPC_MADD:
		if (rmok && fmt2 == 2'd0) row(AD_UNIT_FPU, AD_FPU_FMADD, AD_CLS_F, F_NONE, 1, 1, 1, 1);
	OPC_MSUB:
		if (rmok && fmt2 == 2'd0) row(AD_UNIT_FPU, AD_FPU_FMSUB, AD_CLS_F, F_NONE, 1, 1, 1, 1);
	OPC_NMSUB:
		if (rmok && fmt2 == 2'd0) row(AD_UNIT_FPU, AD_FPU_FNMSUB, AD_CLS_F, F_NONE, 1, 1, 1, 1);
	OPC_NMADD:
		if (rmok && fmt2 == 2'd0) row(AD_UNIT_FPU, AD_FPU_FNMADD, AD_CLS_F, F_NONE, 1, 1, 1, 1);
	default: ;
	endcase
end

endmodule
