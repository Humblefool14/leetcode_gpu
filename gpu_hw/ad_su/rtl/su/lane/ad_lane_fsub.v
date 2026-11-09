/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * ad_lane_fsub: y = a - b in fp32 (combinational), equal to
 * tools/gsi1fp.py fpu(FSUB, a, b, 0, RNE): denormals flushed on input and
 * output (a result whose exponent after rounding is below the normal range
 * is a zero of its sign), NaN results 0x7FC00000, inf - inf of the same
 * sign NaN, an exact zero +0 (or -0 for -0 - +0).
 * The smaller operand is aligned into 26 bits below the larger one's
 * mantissa with the shifted-out bits jammed into the LSB (the jammed value
 * is odd when inexact, so it never sits on a rounding boundary).
 */
module ad_lane_fsub (
	input wire [31:0] a,
	input wire [31:0] b,
	output reg [31:0] y
);
	wire sa = a[31];
	wire sb = ~b[31];		/* a + (-b) */
	wire [7:0] ea = a[30:23];
	wire [7:0] eb = b[30:23];
	wire [22:0] fa = a[22:0];
	wire [22:0] fb = b[22:0];
	wire za = (ea == 8'd0);
	wire zb = (eb == 8'd0);
	wire nan_a = (ea == 8'hFF) && (fa != 23'd0);
	wire nan_b = (eb == 8'hFF) && (fb != 23'd0);
	wire inf_a = (ea == 8'hFF) && (fa == 23'd0);
	wire inf_b = (eb == 8'hFF) && (fb == 23'd0);

	/* X: the larger magnitude */
	wire swp = {eb, fb} > {ea, fa};
	wire sx = swp ? sb : sa;
	wire sy = swp ? sa : sb;
	wire [7:0] ex = swp ? eb : ea;
	wire [7:0] ey = swp ? ea : eb;
	wire [23:0] mx = {1'b1, swp ? fb : fa};
	wire [23:0] my = {1'b1, swp ? fa : fb};
	wire [7:0] d = ex - ey;
	wire [5:0] dd = (d > 8'd51) ? 6'd51 : d[5:0];

	wire [50:0] xw = {1'b0, mx, 26'd0};
	wire [100:0] yfull = {1'b0, my, 26'd0, 50'd0} >> dd;
	wire ysticky = |yfull[49:0];
	wire [50:0] yw = yfull[100:50] | {50'd0, ysticky};
	wire [50:0] sum = (sx != sy) ? (xw - yw) : (xw + yw);

	reg [5:0] lz;
	integer i;
	always @(*) begin
		lz = 6'd51;
		for (i = 0; i <= 50; i = i + 1)
			if (sum[i])
				lz = 6'd50 - i[5:0];
	end

	wire [50:0] sn = sum << lz;
	wire [23:0] mt = sn[50:27];
	wire g = sn[26];
	wire st = |sn[25:0];
	wire up = g & (st | mt[0]);
	wire [24:0] mr = {1'b0, mt} + {24'd0, up};
	/* exponent of the result: X's MSB at bit 49 is ex, sn's MSB at bit 50 */
	wire signed [10:0] be = $signed({3'b000, ex}) + 11'sd1 - $signed({5'd0, lz}) +
		(mr[24] ? 11'sd1 : 11'sd0);
	wire [22:0] mo = mr[24] ? mr[23:1] : mr[22:0];

	always @(*) begin
		if (nan_a || nan_b)
			y = 32'h7FC00000;
		else if (inf_a && inf_b)
			y = (sa != sb) ? 32'h7FC00000 : {sa, 8'hFF, 23'd0};
		else if (inf_a)
			y = {sa, 8'hFF, 23'd0};
		else if (inf_b)
			y = {sb, 8'hFF, 23'd0};
		else if (za && zb)
			y = {sa & sb, 31'd0};
		else if (za)
			y = {sb, b[30:0]};
		else if (zb)
			y = a;
		else if (sum == 51'd0)
			y = 32'd0;
		else if (be >= 11'sd255)
			y = {sx, 8'hFF, 23'd0};
		else if (be <= 11'sd0)
			y = {sx, 31'd0};
		else
			y = {sx, be[7:0], mo};
	end
endmodule
