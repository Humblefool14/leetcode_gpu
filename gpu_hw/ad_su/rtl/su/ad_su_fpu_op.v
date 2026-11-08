/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * ad_su_fpu_op: one lane's operation of ad_su_fpu given the lane's
 * multiplier product pr (operands from ad_su_fpu_mulops); exactly
 * tools/gsi1fp.py fpu(o, ia, ib, ic, irm, ist).  One ad_su_ffma_p (fadd =
 * a * 1 + b, fsub = a * 1 - b, fmul = a * b without an addend, the fmadd
 * family, fract = a * 1 - fround(a, RDN) with RNE), one ad_su_rint
 * (fround, fract, fcvt.w*), one ad_su_i2f (fcvt.s.w*, and fround's
 * integral value) and one ad_su_f2i.  Combinational.
 * Spec: spec/gpu/su/ad_su_fpu_op.md.
 */

module ad_su_fpu_op (
	input  wire [4:0]  o,	/* AD_FPU_* */
	input  wire [31:0] ia,
	input  wire [31:0] ib,
	input  wire [31:0] ic,
	input  wire [2:0]  irm,	/* the uop's rm */
	input  wire        ist,	/* sat (MOD bit 6) */
	input  wire [63:0] pr,	/* low 64 bits of $signed(ma) * $signed(mb) */
	output reg  [31:0] res
);

`include "ad_su_uop.vh"

	localparam [31:0] QNAN = 32'h7FC00000;
	localparam [31:0] ONE = 32'h3F800000;
	localparam [31:0] SGN = 32'h80000000;

	wire [7:0] op = {3'd0, o};

	/* Flushed operands and classes. */
	wire [31:0] fa = ia[30:23] == 8'd0 ? {ia[31], 31'd0} : ia;
	wire [31:0] fb = ib[30:23] == 8'd0 ? {ib[31], 31'd0} : ib;
	wire        nan_a = fa[30:23] == 8'hFF && fa[22:0] != 23'd0;
	wire        nan_b = fb[30:23] == 8'hFF && fb[22:0] != 23'd0;
	wire        zer_a = fa[30:0] == 31'd0;
	wire        zer_b = fb[30:0] == 31'd0;

	/* rint / i2f / f2i (fround, fract, fcvt). */
	wire        r_neg, r_big;
	wire [31:0] r_mag;
	ad_su_rint u_rint (
		.x(ia), .rm(op == AD_FPU_FRACT ? 3'd2 : irm),
		.neg(r_neg), .mag(r_mag), .big(r_big)
	);

	wire cvt_s = op == AD_FPU_FCVTSW || op == AD_FPU_FCVTSWU;
	wire [31:0] i2f_y;
	ad_su_i2f u_i2f (
		.a(cvt_s ? ia : r_mag), .uns(op != AD_FPU_FCVTSW), .rm(cvt_s ? irm : 3'd0),
		.y(i2f_y)
	);

	wire [31:0] f2i_y;
	ad_su_f2i u_f2i (
		.neg(r_neg), .mag(r_mag), .big(r_big), .nan(nan_a),
		.uns(op == AD_FPU_FCVTWUS), .y(f2i_y)
	);

	/* fround: NaN -> QNAN; inf, zero and |x| >= 2^23 unchanged. */
	wire [31:0] frnd = nan_a ? QNAN :
		(zer_a || fa[30:23] >= 8'd150) ? fa : {r_neg, 31'd0} | i2f_y;

	/* The fused datapath. */
	reg [31:0] m_a, m_b, m_c;
	always @(*) begin
		m_a = (op == AD_FPU_FNMSUB || op == AD_FPU_FNMADD) ? ia ^ SGN : ia;
		m_b = (op == AD_FPU_FADD || op == AD_FPU_FSUB || op == AD_FPU_FRACT) ? ONE : ib;
		case (op)
		AD_FPU_FADD: m_c = ib;
		AD_FPU_FSUB: m_c = ib ^ SGN;
		AD_FPU_FMSUB, AD_FPU_FNMADD: m_c = ic ^ SGN;
		AD_FPU_FRACT: m_c = frnd ^ SGN;
		default: m_c = ic;
		endcase
	end
	wire [31:0] fma_y;
	ad_su_ffma_p u_ffma (
		.a(m_a), .b(m_b), .c(m_c), .rm(op == AD_FPU_FRACT ? 3'd0 : irm),
		.noc(op == AD_FPU_FMUL), .pm(pr[47:0]), .y(fma_y)
	);

	/* min/max/compares on the flushed operands; -0 < +0 for min/max. */
	wire [31:0] ka = fa[31] ? ~fa : fa | SGN;
	wire [31:0] kb = fb[31] ? ~fb : fb | SGN;
	wire        anan = nan_a | nan_b;
	wire        feq = !anan && ((zer_a && zer_b) || fa == fb);
	wire        flt = !anan && !feq && ka < kb;
	wire [31:0] fmin = (nan_a && nan_b) ? QNAN : nan_a ? fb : nan_b ? fa : (ka <= kb ? fa : fb);
	wire [31:0] fmax = (nan_a && nan_b) ? QNAN : nan_a ? fb : nan_b ? fa : (ka >= kb ? fa : fb);

	reg [31:0] r;
	reg        isf;
	always @(*) begin
		isf = 1'b1;
		case (op)
		AD_FPU_FADD, AD_FPU_FSUB, AD_FPU_FMUL, AD_FPU_FMADD, AD_FPU_FMSUB,
		AD_FPU_FNMSUB, AD_FPU_FNMADD, AD_FPU_FRACT:
			r = fma_y;
		AD_FPU_FSGNJ: r = {ib[31], ia[30:0]};
		AD_FPU_FMIN: r = fmin;
		AD_FPU_FMAX: r = fmax;
		AD_FPU_FCVTSW, AD_FPU_FCVTSWU: r = i2f_y;
		AD_FPU_FROUND: r = frnd;
		default: begin
			isf = 1'b0;
			case (op)
			AD_FPU_FCVTWS, AD_FPU_FCVTWUS: r = f2i_y;
			AD_FPU_FEQ: r = {32{feq}};
			AD_FPU_FLT: r = {32{flt}};
			AD_FPU_FLE: r = {32{feq | flt}};
			AD_FPU_FNE: r = {32{!feq}};
			AD_FPU_MUL: r = pr[31:0];
			AD_FPU_MULH, AD_FPU_MULHSU, AD_FPU_MULHU: r = pr[63:32];
			default: r = 32'd0;
			endcase
		end
		endcase
		/* sat: NaN, negatives and -0 give +0, above 1.0 gives 1.0. */
		res = r;
		if (ist && isf) begin
			if (r[31] || (r[30:23] == 8'hFF && r[22:0] != 23'd0))
				res = 32'd0;
			else if (r > ONE)
				res = ONE;
		end
	end

endmodule
