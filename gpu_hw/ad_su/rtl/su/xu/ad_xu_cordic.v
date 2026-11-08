/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * ad_xu_cordic: one CORDIC rotation (combinational), as tools/gsi1fp.py:
 * z >= 0: (cx - cy>>i, cy + cx>>i, z - atan_i), else (cx + cy>>i,
 * cy - cx>>i, z + atan_i); arithmetic shifts (floor).  cx, cy Q1.34,
 * z and atan_i in turns Q0.40.
 */
module ad_xu_cordic (
	input wire signed [39:0] cx,
	input wire signed [39:0] cy,
	input wire signed [41:0] z,
	input wire [4:0] i,
	input wire [39:0] atan,
	output wire signed [39:0] cx_n,
	output wire signed [39:0] cy_n,
	output wire signed [41:0] z_n
);
	wire signed [39:0] xs = cx >>> i;
	wire signed [39:0] ys = cy >>> i;
	wire signed [41:0] at = $signed({2'b00, atan});
	wire pos = !z[41];

	assign cx_n = pos ? (cx - ys) : (cx + ys);
	assign cy_n = pos ? (cy + xs) : (cy - xs);
	assign z_n = pos ? (z - at) : (z + at);
endmodule
