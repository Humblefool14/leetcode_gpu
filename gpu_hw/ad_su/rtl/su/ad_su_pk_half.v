/*
 * Amaterrace GPU
 * SPDX-License-Identifier: Zlib
 */

/*
 * ad_su_pk_half: one 16-bit half of a lane of ad_su_pk
 * (spec/gpu/su/ad_su_pk_half.md).  packh's fp32 -> fp16 of xw (any ARITH) and,
 * with ARITH, the per-half packed operation o on ha, hb (after hsel's swap) and
 * hc under rounding mode r, sat clamping the float results.  FP 0 (ad_su_pk's
 * PK_SHARED) gives 0 for the float operations.  Bit-exact to tools/gsi1fp.py
 * (pk_half, f32_to_f16, sat).  Combinational.
 *
 * The fused fp16 multiply-add: product p = ma * mb (22 bits) placed at bits
 * [24:3] of a 39-bit frame; the addend's LSB at frame bit j = ec - ea - eb + 28
 * when 1 <= j <= 27; above (j > 27) the addend is at bits [37:27] and the product
 * (then at least 3 bits below the addend) becomes a sticky 1 at bit 0; below
 * (j < 1) the addend's bits under frame bit 1 are ORed into bit 0 (the product
 * then dominates by at least 12 bits).  The signed sum, its leading zeros lz,
 * the left shift by lz and one ad_su_hrnd, exponent ea + eb - lz (or ec + 1 - lz
 * when the addend dominates).
 */
module ad_su_pk_half #(
	parameter ARITH = 1,
	parameter FP = 1
) (
	input wire [3:0] o,
	input wire [15:0] ha,
	input wire [15:0] hb,
	input wire [15:0] hc,
	input wire [2:0] r,
	input wire sat,
	input wire [31:0] xw,
	output reg [15:0] y
);
`include "ad_su_uop.vh"

	/* ---- the fma's operands: a * fy + fz ---- */
	wire op_add = (o == AD_PK_FADD2[3:0]);
	wire op_sub = (o == AD_PK_FSUB2[3:0]);
	wire op_mul = (o == AD_PK_FMUL2[3:0]);
	wire op_fma = (o == AD_PK_FFMA2[3:0]);
	wire op_imul = (o == AD_PK_IMUL2[3:0]);
	wire op_packh = (o == AD_PK_PACKH[3:0]);
	wire noc = op_mul;

	wire [15:0] fa = ha;
	wire [15:0] fy = (op_add || op_sub) ? 16'h3C00 : hb;
	wire [15:0] fz = op_sub ? {~hb[15], hb[14:0]} : op_fma ? hc : hb;

	wire sa = fa[15], sb = fy[15], sc = fz[15];
	wire [4:0] ea = fa[14:10], eb = fy[14:10], ec = fz[14:10];
	wire za = (ea == 5'd0), zb = (eb == 5'd0), zc = (ec == 5'd0) || noc;
	wire na = (ea == 5'd31) && (fa[9:0] != 10'd0);
	wire nb = (eb == 5'd31) && (fy[9:0] != 10'd0);
	wire nc = !noc && (ec == 5'd31) && (fz[9:0] != 10'd0);
	wire ia = (ea == 5'd31) && (fa[9:0] == 10'd0);
	wire ib = (eb == 5'd31) && (fy[9:0] == 10'd0);
	wire ic = !noc && (ec == 5'd31) && (fz[9:0] == 10'd0);
	wire sp = sa ^ sb;
	wire rdn = (r == 3'd2);

	/* One 16 x 16 multiplier: the mantissas, or imul2's operands. */
	wire [15:0] mx = op_imul ? ha : {5'd0, ~za, fa[9:0]};
	wire [15:0] my = op_imul ? hb : {5'd0, ~zb, fy[9:0]};
	/* verilator lint_off UNUSEDSIGNAL */
	wire [31:0] prod = mx * my;
	/* verilator lint_on UNUSEDSIGNAL */
	wire [21:0] p = prod[21:0];
	wire [10:0] mc = {1'b1, fz[9:0]};

	/* Addend alignment. */
	wire signed [9:0] ja = $signed({5'd0, ec}) - $signed({5'd0, ea}) - $signed({5'd0, eb}) + 10'sd28;
	wire dom = !zc && (ja > 10'sd27);
	wire [9:0] rs = 10'd1 - ja;		/* right shift when ja < 1 */
	reg [38:0] fp_p, fp_c;
	reg signed [9:0] ebase;
	always @(*) begin
		fp_p = {14'd0, p, 3'd0};
		ebase = $signed({5'd0, ea}) + $signed({5'd0, eb});
		if (zc) begin
			fp_c = 39'd0;
		end else if (dom) begin
			fp_c = {1'b0, mc, 27'd0};
			fp_p = 39'd1;
			ebase = $signed({5'd0, ec}) + 10'sd1;
		end else if (ja >= 10'sd1) begin
			fp_c = {28'd0, mc} << ja[4:0];
		end else begin
			fp_c = {27'd0, (mc >> rs), 1'b0} |
			       {38'd0, |(mc & ~(11'h7FF << rs))};
		end
	end

	/* Signed sum. */
	wire esub = !zc && (sp ^ sc);
	wire [39:0] dif = {1'b0, fp_p} - {1'b0, fp_c};
	wire neg = esub && dif[39];
	wire [38:0] sum = !esub ? (fp_p + fp_c) : neg ? (fp_c - fp_p) : dif[38:0];
	wire ssum = neg ? sc : sp;

	/* Leading zeros and normalisation (binary search: 32, 16, 8, 4, 2, 1). */
	reg [5:0] lz;
	reg [38:0] nrm;
	always @(*) begin
		nrm = sum;
		lz = 6'd0;
		if (nrm[38:7] == 32'd0) begin nrm = nrm << 32; lz = lz + 6'd32; end
		if (nrm[38:23] == 16'd0) begin nrm = nrm << 16; lz = lz + 6'd16; end
		if (nrm[38:31] == 8'd0) begin nrm = nrm << 8; lz = lz + 6'd8; end
		if (nrm[38:35] == 4'd0) begin nrm = nrm << 4; lz = lz + 6'd4; end
		if (nrm[38:37] == 2'd0) begin nrm = nrm << 2; lz = lz + 6'd2; end
		if (nrm[38] == 1'b0) begin nrm = nrm << 1; lz = lz + 6'd1; end
	end
	wire signed [9:0] efma = ebase - $signed({4'd0, lz});
	wire [12:0] mfma = {nrm[38:28], nrm[27], |nrm[26:0]};

	/* packh's conversion. */
	wire [7:0] xe = xw[30:23];
	wire signed [9:0] epk = $signed({2'd0, xe}) - 10'sd112;
	wire [12:0] mpk = {1'b1, xw[22:13], xw[12], |xw[11:0]};

	/* The shared rounding. */
	wire [15:0] rnd;
	ad_su_hrnd u_rnd (
		.s(op_packh ? xw[31] : ssum),
		.e(op_packh ? epk : efma),
		.m(op_packh ? mpk : mfma),
		.r(op_packh ? 3'd0 : r),
		.y(rnd)
	);

	/* fma result with the special cases. */
	reg [15:0] yfma;
	always @(*) begin
		if (na || nb || nc)
			yfma = 16'h7E00;
		else if ((ia && zb) || (ib && za))
			yfma = 16'h7E00;
		else if (ia || ib)
			yfma = (ic && sc != sp) ? 16'h7E00 : {sp, 15'h7C00};
		else if (ic)
			yfma = {sc, 15'h7C00};
		else if (za || zb) begin
			if (zc)
`ifdef MUT_HALF_ZSIGN
				yfma = noc ? {sp, 15'd0} : {(sp | sc), 15'd0};
`else
				yfma = noc ? {sp, 15'd0} : {(rdn ? (sp | sc) : (sp & sc)), 15'd0};
`endif
			else
				yfma = fz;
		end else if (sum == 39'd0)
			yfma = {rdn, 15'd0};
		else
			yfma = rnd;
	end

	/* packh. */
	reg [15:0] ypk;
	always @(*) begin
		if (xe == 8'hFF)
			ypk = (xw[22:0] != 23'd0) ? 16'h7E00 : {xw[31], 15'h7C00};
		else if (xe == 8'd0)
			ypk = {xw[31], 15'd0};
		else
			ypk = rnd;
	end

	wire [15:0] ymm, ycmp, ysat;
	ad_su_hminmax u_mm (.a(ha), .b(hb), .mx(o == AD_PK_FMAX2[3:0]), .y(ymm));
	reg [1:0] cop;
	reg [15:0] ca, cb;
	always @(*) begin
		ca = ha;
		cb = hb;
		case (o)
		AD_PK_FCMPLT2[3:0]: cop = 2'd1;
		AD_PK_FCMPGE2[3:0]: begin cop = 2'd2; ca = hb; cb = ha; end
		AD_PK_FCMPEQ2[3:0]: cop = 2'd0;
		default: cop = 2'd3;
		endcase
	end
	ad_su_hcmp u_cmp (.a(ca), .b(cb), .op(cop), .y(ycmp));

	/* Float result before sat. */
	reg [15:0] yf;
	always @(*) begin
		case (o)
		AD_PK_FMIN2[3:0], AD_PK_FMAX2[3:0]: yf = ymm;
		default: yf = yfma;
		endcase
	end
	ad_su_hsat u_sat (.x(yf), .y(ysat));

	always @(*) begin
		y = 16'd0;
		case (o)
		AD_PK_PACKH[3:0]: y = ypk;
		AD_PK_FADD2[3:0], AD_PK_FSUB2[3:0], AD_PK_FMUL2[3:0], AD_PK_FFMA2[3:0],
		AD_PK_FMIN2[3:0], AD_PK_FMAX2[3:0]:
			if (ARITH != 0 && FP != 0)
				y = sat ? ysat : yf;
		AD_PK_FCMPLT2[3:0], AD_PK_FCMPGE2[3:0], AD_PK_FCMPEQ2[3:0], AD_PK_FCMPNE2[3:0]:
			if (ARITH != 0 && FP != 0)
				y = ycmp;
		AD_PK_IADD2[3:0]:
			if (ARITH != 0)
				y = ha + hb;
		AD_PK_ISUB2[3:0]:
			if (ARITH != 0)
				y = ha - hb;
		AD_PK_IMUL2[3:0]:
			if (ARITH != 0)
				y = prod[15:0];
		default: y = 16'd0;
		endcase
	end
endmodule
