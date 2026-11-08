/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * ad_xu_engine: one XU lane, sequential, following tools/gsi1fp.py xu()
 * step for step (results bit-identical):
 *  rcp   q, r = 2^50 / m (28 restoring steps), norm_round(s, q, 100 - e, r != 0)
 *  fsqrt r = isqrt(mm << 26) (30 steps), norm_round(0, r, (ee - 26) / 2, inexact)
 *  rsq   t = isqrt(mm << 34) (30 steps), q, r = 2^57 / t (29 steps),
 *        norm_round(0, q, -40 - ee / 2, r != 0 or t inexact)
 *        (mm = m, ee = e - 150, or m << 1, ee - 1 for an odd ee)
 *  exp2  y = 2^38 * prod of 2^(2^-(i+1)) over the fraction bits of x in
 *        Q8.30 (30 steps), norm_round(0, y, n - 38)
 *  log2  y = m in Q1.40, 30 squarings giving the fraction bits,
 *        v = ((e - 127) << 30) + frac, norm_round(sign, |v|, -30), v = 0: +0
 *  sin/cos  turns in Q0.40, quadrant, 26 CORDIC rotations from 1/K,
 *        norm_round(quad[1], cy, -34), cy <= 0: +0
 * The special operands (ad_xu_special) finish in one cycle.  start is taken
 * in IDLE (also in the cycle done is 1); done is 1 for one cycle with y.
 */
module ad_xu_engine (
	input wire clk,
	input wire rst_n,
	input wire start,
	input wire [2:0] op,
	input wire [31:0] x,
	output wire busy,
	output reg done,
	output reg [31:0] y
);
`include "ad_su_xu_tab.vh"

	localparam [2:0] OP_RCP = 3'd0, OP_RSQ = 3'd1, OP_EXP2 = 3'd2, OP_LOG2 = 3'd3,
		OP_SIN = 3'd4, OP_COS = 3'd5, OP_FSQRT = 3'd6;
	localparam [2:0] S_IDLE = 3'd0, S_DIV = 3'd1, S_SQRT = 3'd2, S_EXP = 3'd3,
		S_LOG = 3'd4, S_COR = 3'd5, S_FIN = 3'd6;

	reg [2:0] st;
	reg [2:0] op_r;
	reg [7:0] e_r;
	reg [4:0] it;
	reg [39:0] ye;			/* exp2: Q2.38 */
	reg [40:0] yl;			/* log2: Q1.40 */
	reg [29:0] fb;			/* exp2: the fraction bits / log2: the result bits */
	reg signed [9:0] n_r;		/* exp2: the integer part */
	reg signed [39:0] cx, cy;
	reg signed [41:0] z;
	reg [1:0] quad;
	reg inex;			/* rsq: isqrt inexact */
	reg nr_s, nr_st, nr_zero;
	reg [47:0] nr_n;
	reg signed [11:0] nr_e;

	/* operand fields and special results of the input */
	wire xs, spec;
	wire [7:0] xe;
	wire [23:0] xm;
	wire [31:0] sv;
	ad_xu_special u_spec (.op(op), .x(x), .s(xs), .e(xe), .m(xm), .spec(spec), .sv(sv));

	/* exp2 and sin/cos operand preparation (from the input) */
	wire signed [9:0] ex_n;
	wire [29:0] ex_f;
	ad_xu_exp_pre u_epre (.s(xs), .e(xe), .m(xm), .n(ex_n), .f(ex_f));
	wire [1:0] sc_q;
	wire [38:0] sc_a;
	ad_xu_sincos_pre u_scpre (.cos(op == OP_COS), .s(xs), .e(xe), .m(xm), .quad(sc_q), .a(sc_a));

	/* sqrt operand: mm << 26 (fsqrt) or mm << 34 (rsq) */
	wire [24:0] mm = xe[0] ? {xm, 1'b0} : {1'b0, xm};
	wire [59:0] sq_n = (op == OP_RSQ) ? {1'b0, mm, 34'd0} : {9'd0, mm, 26'd0};

	/* the iteration leaves */
	reg div_go, sq_go;
	reg [29:0] div_r0, div_d;
	reg [5:0] div_steps;
	wire div_busy, div_done, sq_busy, sq_done;
	wire [31:0] div_q;
	wire [29:0] div_r;
	wire [29:0] sq_root;
	wire [31:0] sq_rem;
	ad_xu_divider #(.DW(30), .QW(32), .CW(6)) u_div (
		.clk(clk), .rst_n(rst_n), .start(div_go), .r0(div_r0), .d(div_d),
		.steps(div_steps), .busy(div_busy), .done(div_done), .q(div_q), .r(div_r)
	);
	ad_xu_isqrt #(.RW(30)) u_sqrt (
		.clk(clk), .rst_n(rst_n), .start(sq_go), .n(sq_n), .busy(sq_busy),
		.done(sq_done), .root(sq_root), .rem(sq_rem)
	);

	wire [39:0] ye_n;
	wire [40:0] yl_n;
	wire lbit;
	ad_xu_mulstep u_mul (.y(ye), .k(xu_expk(it)), .en(fb[29]), .ye(ye_n),
		.yl_in(yl), .yl(yl_n), .lb(lbit));

	wire signed [39:0] cx_n, cy_n;
	wire signed [41:0] z_n;
	ad_xu_cordic u_cor (.cx(cx), .cy(cy), .z(z), .i(it), .atan(xu_atan(it)),
		.cx_n(cx_n), .cy_n(cy_n), .z_n(z_n));

	wire [31:0] nr_y;
	ad_xu_normround u_nr (.s(nr_s), .n(nr_n), .e(nr_e), .sticky(nr_st), .y(nr_y));

	/* ee = e - 150 made even; exponents of the sqrt results */
	wire signed [11:0] ee = $signed({4'd0, e_r}) - 12'sd150 - (e_r[0] ? 12'sd1 : 12'sd0);
	wire signed [11:0] ee_h = ee >>> 1;
	/* log2: v = ((e - 127) << 30) + frac */
	wire signed [39:0] lv = ($signed({32'd0, e_r}) - 40'sd127) * 40'sd1073741824 +
		$signed({10'd0, fb[28:0], lbit});
	wire [39:0] lva = lv[39] ? (~lv + 1'b1) : lv;

	assign busy = (st != S_IDLE);

	always @(*) begin
		div_go = 1'b0;
		div_r0 = 30'd0;
		div_d = 30'd0;
		div_steps = 6'd0;
		sq_go = 1'b0;
		if (st == S_IDLE && start && !spec) begin
			if (op == OP_RCP) begin
				div_go = 1'b1;
				div_r0 = 30'd1 << 22;
				div_d = {6'd0, xm};
				div_steps = 6'd28;
			end
			if (op == OP_RSQ || op == OP_FSQRT)
				sq_go = 1'b1;
		end
		if (st == S_SQRT && sq_done && op_r == OP_RSQ) begin
			div_go = 1'b1;
			div_r0 = 30'd1 << 28;
			div_d = sq_root;
			div_steps = 6'd29;
		end
	end

	always @(posedge clk) begin
		if (!rst_n) begin
			st <= S_IDLE;
			op_r <= 3'd0;
			e_r <= 8'd0;
			it <= 5'd0;
			ye <= 40'd0;
			yl <= 41'd0;
			fb <= 30'd0;
			n_r <= 10'sd0;
			cx <= 40'sd0;
			cy <= 40'sd0;
			z <= 42'sd0;
			quad <= 2'd0;
			inex <= 1'b0;
			nr_s <= 1'b0;
			nr_n <= 48'd0;
			nr_e <= 12'sd0;
			nr_st <= 1'b0;
			nr_zero <= 1'b0;
			done <= 1'b0;
			y <= 32'd0;
		end else begin
			done <= 1'b0;
			case (st)
			S_IDLE: if (start) begin
				op_r <= op;
				e_r <= xe;
				nr_s <= 1'b0;
				nr_st <= 1'b0;
				nr_zero <= 1'b0;
				it <= 5'd0;
				if (spec) begin
					y <= sv;
					done <= 1'b1;
				end else begin
					case (op)
					OP_RCP: begin
						nr_s <= xs;
						st <= S_DIV;
					end
					OP_RSQ, OP_FSQRT: st <= S_SQRT;
					OP_EXP2: begin
						ye <= 40'd1 << 38;
						fb <= ex_f;
						n_r <= ex_n;
						st <= S_EXP;
					end
					OP_LOG2: begin
						yl <= {xm, 17'd0};
						fb <= 30'd0;
						st <= S_LOG;
					end
					default: begin	/* sin, cos */
						cx <= $signed({4'd0, XU_CG});
						cy <= 40'sd0;
						z <= $signed({3'd0, sc_a});
						quad <= sc_q;
						st <= S_COR;
					end
					endcase
				end
			end
			S_SQRT: if (sq_done) begin
				if (op_r == OP_FSQRT) begin
					nr_n <= {18'd0, sq_root};
					nr_e <= (ee - 12'sd26) >>> 1;
					nr_st <= (sq_rem != 32'd0);
					st <= S_FIN;
				end else begin
					inex <= (sq_rem != 32'd0);
					st <= S_DIV;
				end
			end
			S_DIV: if (div_done) begin
				nr_n <= {16'd0, div_q};
				if (op_r == OP_RCP) begin
					nr_e <= 12'sd100 - $signed({4'd0, e_r});
					nr_st <= (div_r != 30'd0);
				end else begin
					nr_e <= -12'sd40 - ee_h;
					nr_st <= (div_r != 30'd0) | inex;
				end
				st <= S_FIN;
			end
			S_EXP: begin
				ye <= ye_n;
				fb <= {fb[28:0], 1'b0};
				it <= it + 1'b1;
				if (it == 5'd29) begin
					nr_n <= {8'd0, ye_n};
					nr_e <= $signed({{2{n_r[9]}}, n_r}) - 12'sd38;
					st <= S_FIN;
				end
			end
			S_LOG: begin
				yl <= yl_n;
				fb <= {fb[28:0], lbit};
				it <= it + 1'b1;
				if (it == 5'd29) begin
					nr_zero <= (lv == 40'sd0);
					nr_s <= lv[39];
					nr_n <= {8'd0, lva};
					nr_e <= -12'sd30;
					st <= S_FIN;
				end
			end
			S_COR: begin
				cx <= cx_n;
				cy <= cy_n;
				z <= z_n;
				it <= it + 1'b1;
				if (it == 5'd25) begin
					nr_zero <= (cy_n <= 40'sd0);
					nr_s <= quad[1];
					nr_n <= {8'd0, cy_n};
					nr_e <= -12'sd34;
					st <= S_FIN;
				end
			end
			S_FIN: begin
				y <= nr_zero ? 32'd0 : nr_y;
				done <= 1'b1;
				st <= S_IDLE;
			end
			default: st <= S_IDLE;
			endcase
		end
	end
endmodule
