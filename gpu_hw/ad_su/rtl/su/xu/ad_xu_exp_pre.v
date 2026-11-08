/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * ad_xu_exp_pre: exp2's operand as fixed point Q8.30 (|x| < 256, e < 135):
 * v = +-(m * 2^(e-150+30)) (truncated toward zero before the sign),
 * n = floor(v / 2^30) (the integer part), f = v mod 2^30 (combinational).
 */
module ad_xu_exp_pre (
	input wire s,
	input wire [7:0] e,
	input wire [23:0] m,
	output wire signed [9:0] n,
	output wire [29:0] f
);
	wire signed [9:0] sh = $signed({2'b00, e}) - 10'sd120;
	wire signed [9:0] nsh = -sh;
	wire [6:0] rsh = (sh < 0) ? ((nsh > 10'sd63) ? 7'd63 : nsh[6:0]) : 7'd0;
	wire [3:0] lsh = (sh > 10'sd14) ? 4'd14 : (sh < 0 ? 4'd0 : sh[3:0]);
	wire [37:0] v = (sh < 0) ? ({14'd0, m} >> rsh) : ({14'd0, m} << lsh);
	wire [39:0] vs = s ? (~{2'b00, v} + 1'b1) : {2'b00, v};

	assign n = vs[39:30];
	assign f = vs[29:0];
endmodule
