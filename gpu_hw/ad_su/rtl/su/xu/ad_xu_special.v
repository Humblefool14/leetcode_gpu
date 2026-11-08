/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * ad_xu_special: the operand fields of an XU lane and the results that need
 * no iteration (combinational), as tools/gsi1fp.py xu(): the input is
 * flushed (a denormal is a zero of its sign); NaN in -> 0x7FC00000;
 *  rcp:   0 -> inf(s), inf -> 0(s)
 *  rsq:   x < 0 -> NaN, 0 -> inf(s), +inf -> +0
 *  fsqrt: x < 0 -> NaN, 0 -> x, +inf -> +inf
 *  exp2:  +-inf -> +inf / +0, 0 -> 1.0, |x| >= 256 -> +inf (x > 0) / +0
 *  log2:  x < 0 -> NaN, 0 -> -inf, +inf -> +inf
 *  sin/cos: inf -> NaN, |x| < 2^-12 -> x / 1.0
 *  op 7 (not decoded): +0.
 */
module ad_xu_special (
	input wire [2:0] op,
	input wire [31:0] x,
	output wire s,
	output wire [7:0] e,
	output wire [23:0] m,
	output reg spec,
	output reg [31:0] sv
);
	localparam [31:0] QNAN = 32'h7FC00000;
	localparam [31:0] ONE = 32'h3F800000;

	assign s = x[31];
	assign e = x[30:23];
	assign m = {1'b1, x[22:0]};

	wire zero = (e == 8'd0);
	wire [31:0] xf = zero ? {s, 31'd0} : x;
	wire nan = (e == 8'hFF) && (x[22:0] != 23'd0);
	wire inf = (e == 8'hFF) && (x[22:0] == 23'd0);
	wire [31:0] inf_s = {s, 8'hFF, 23'd0};

	always @(*) begin
		spec = 1'b1;
		sv = 32'd0;
		case (op)
		3'd0: begin	/* rcp */
			if (nan) sv = QNAN;
			else if (zero) sv = inf_s;
			else if (inf) sv = {s, 31'd0};
			else spec = 1'b0;
		end
		3'd1, 3'd6: begin	/* rsq, fsqrt */
			if (nan || (s && !zero)) sv = QNAN;
			else if (zero) sv = (op == 3'd1) ? inf_s : xf;
			else if (inf) sv = (op == 3'd1) ? 32'd0 : xf;
			else spec = 1'b0;
		end
		3'd2: begin	/* exp2 */
			if (nan) sv = QNAN;
			else if (inf) sv = s ? 32'd0 : xf;
			else if (zero) sv = ONE;
			else if (e >= 8'd135) sv = s ? 32'd0 : 32'h7F800000;
			else spec = 1'b0;
		end
		3'd3: begin	/* log2 */
			if (nan || (s && !zero)) sv = QNAN;
			else if (zero) sv = 32'hFF800000;
			else if (inf) sv = xf;
			else spec = 1'b0;
		end
		3'd4, 3'd5: begin	/* sin, cos */
			if (nan || inf) sv = QNAN;
			else if (e < 8'd115) sv = (op == 3'd4) ? xf : ONE;
			else spec = 1'b0;
		end
		default: sv = 32'd0;
		endcase
	end
endmodule
