/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * ad_su_rint: the integer nearest to the fp32 x under rm, as sign and
 * magnitude (tools/gsi1fp.py rint(F32.value(x), rm)).  x is flushed
 * (a denormal is a zero); big: |x| >= 2^32 (also inf and NaN), mag is
 * then not meaningful.  Combinational.  Spec: spec/gpu/su/ad_su_rint.md.
 */

module ad_su_rint (
	input  wire [31:0] x,
	input  wire [2:0]  rm,	/* 0 RNE, 1 RTZ, 2 RDN, 3 RUP, 4 RMM, 5-7 RNE */
	output wire        neg,	/* sign of x */
	output wire [31:0] mag,	/* |rint(x)| when !big */
	output wire        big	/* |x| >= 2^32, inf or NaN */
);

	wire [7:0]  e = x[30:23];
	wire [23:0] m = {1'b1, x[22:0]};
	wire [2:0]  rmd = rm > 3'd4 ? 3'd0 : rm;

	assign neg = x[31];
	assign big = e >= 8'd159;

	/* e >= 150: integral, mag = m << (e - 150) (at most 8, no rounding). */
	wire [3:0]  lsh = e[3:0] - 4'd6;		/* e - 150 for 150..158 */
	wire [31:0] mint = {8'd0, m} << lsh;

	/* e < 150: m >> (150 - e), the bits below in a 26-bit fraction. */
	wire [7:0]  rsh0 = 8'd150 - e;
	wire [5:0]  rsh = rsh0 > 8'd50 ? 6'd50 : rsh0[5:0];
	wire [49:0] fx = {m, 26'd0} >> rsh;
	wire [23:0] ip = fx[49:26];
	wire        h = fx[25];
	wire        st = fx[24:0] != 25'd0 || rsh0 >= 8'd50;

	reg up;
	always @(*) begin
		case (rmd)
		3'd0: up = h & (st | ip[0]);
		3'd1: up = 1'b0;
		3'd2: up = neg & (h | st);
		3'd3: up = !neg & (h | st);
		default: up = h;
		endcase
	end

	assign mag = e == 8'd0 ? 32'd0 :
		e >= 8'd150 ? mint :
		{8'd0, ip} + {31'd0, up};

endmodule
