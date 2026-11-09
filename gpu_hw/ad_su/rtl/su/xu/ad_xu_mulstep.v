/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * ad_xu_mulstep: the multiply steps of exp2 and log2 (combinational).
 *  exp2: ye = en ? (y * k) >> 38 : y   (y, k in Q2.38: 2^(2^-(i+1)))
 *  log2: ys = (y * y) >> 40, then lb = ys >= 2 (bit 41) and yl = ys / 2 when
 *        lb (y in Q1.40, [1, 2))
 */
module ad_xu_mulstep (
	input wire [39:0] y,
	input wire [39:0] k,
	input wire en,
	output wire [39:0] ye,
	input wire [40:0] yl_in,
	output wire [40:0] yl,
	output wire lb
);
	wire [79:0] pe = y * k;
	assign ye = en ? pe[77:38] : y;

	wire [81:0] pl = yl_in * yl_in;
	wire [41:0] sq = pl[81:40];
	assign lb = sq[41];
	assign yl = lb ? sq[41:1] : sq[40:0];
endmodule
