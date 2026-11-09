/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * ad_xu_sincos_pre: sin/cos range reduction (combinational): the turns
 * t = x / (2 pi) mod 1 in Q0.40 (p = m * 1/(2 pi) in Q0.61, shifted by
 * e - 171), negated for x < 0, + 1/4 turn for cos; the quadrant t[39:38]
 * and the residual a in [0, 1/4] turn (Q0.40, mirrored in odd quadrants).
 */
module ad_xu_sincos_pre (
	input wire cos,
	input wire s,
	input wire [7:0] e,
	input wire [23:0] m,
	output wire [1:0] quad,
	output wire [38:0] a
);
`include "ad_su_xu_tab.vh"

	wire [82:0] p = m * XU_INV2PI;
	wire signed [9:0] sh = $signed({2'b00, e}) - 10'sd171;
	wire [6:0] lsh = (sh >= 0) ? sh[6:0] : 7'd0;
	wire signed [9:0] nsh = -sh;
	wire [6:0] rsh = (sh < 0) ? nsh[6:0] : 7'd0;
	wire [39:0] tl = (lsh >= 7'd40) ? 40'd0 : (p[39:0] << lsh);
	wire [82:0] tr = p >> rsh;
	wire [39:0] t0 = (sh >= 0) ? tl : tr[39:0];
	wire [39:0] t1 = s ? (~t0 + 1'b1) : t0;
	wire [39:0] t = cos ? (t1 + 40'h4000000000) : t1;

	assign quad = t[39:38];
	assign a = quad[0] ? ({1'b1, 38'd0} - {1'b0, t[37:0]}) : {1'b0, t[37:0]};
endmodule
