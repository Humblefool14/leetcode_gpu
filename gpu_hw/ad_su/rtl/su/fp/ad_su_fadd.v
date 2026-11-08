/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * ad_su_fadd: fp32 y = a + b, RNE, denormals flushed in and out (a result
 * whose exponent after rounding is below the normal range is a zero of
 * its sign), NaN results 0x7FC00000.  Exactly tools/gsi1fp.py
 * fpu(FADD, a, b, 0, RNE) (= fma(a, 1, b)); a - b is a + (b ^ 0x80000000)
 * (ad_su_lane's qd).  Combinational.  Spec: spec/gpu/su/ad_su_fadd.md.
 */

module ad_su_fadd (
	input  wire [31:0] a,
	input  wire [31:0] b,
	output reg  [31:0] y
);

	localparam [31:0] QNAN = 32'h7FC00000;

	wire [7:0] ea = a[30:23], eb = b[30:23];
	wire       za = ea == 8'd0, zb = eb == 8'd0;
	wire       ia = ea == 8'hFF && a[22:0] == 23'd0;
	wire       ib = eb == 8'hFF && b[22:0] == 23'd0;
	wire       na = ea == 8'hFF && a[22:0] != 23'd0;
	wire       nb = eb == 8'hFF && b[22:0] != 23'd0;

	/* Order by magnitude: x the larger (|x| >= |y|). */
	wire       swp = b[30:0] > a[30:0];
	wire [31:0] xo = swp ? b : a;
	wire [31:0] yo = swp ? a : b;
	wire [7:0]  dexp = xo[30:23] - yo[30:23];
	wire [5:0]  dd = dexp > 8'd51 ? 6'd51 : dexp[5:0];
	/* x at W[50:27]; y shifted right by dd, lost bits ORed into W[0]. */
	wire [101:0] yext = {yo[30:23] != 8'd0, yo[22:0], 27'd0, 51'd0} >> dd;
	wire [50:0]  yw = yext[101:51] | {50'd0, yext[50:0] != 51'd0};
	wire [50:0]  xw = {1'b1, xo[22:0], 27'd0};
	wire         esub = a[31] ^ b[31];
	wire [51:0]  mag = esub ? {1'b0, xw} - {1'b0, yw} : {1'b0, xw} + {1'b0, yw};
	wire         rs = xo[31];

	reg [5:0] lz;
	integer i;
	always @(*) begin
		lz = 6'd52;
		for (i = 0; i < 52; i = i + 1)
			if (mag[i])
				lz = 6'd51 - i[5:0];
	end
	wire [51:0] nm = mag << lz;
	wire [23:0] mt = nm[51:28];
	wire        g = nm[27];
	wire        st = nm[26:0] != 27'd0;
	wire        up = g & (st | mt[0]);
	wire [24:0] mr = {1'b0, mt} + {24'd0, up};
	/* Leading bit at W[50] has x's exponent: be = ex + 1 - lz (+ carry). */
	wire signed [9:0] be = $signed({2'd0, xo[30:23]}) + 10'sd1 - $signed({4'd0, lz}) +
		(mr[24] ? 10'sd1 : 10'sd0);
	wire [22:0] mf = mr[24] ? 23'd0 : mr[22:0];

	always @(*) begin
		if (na || nb || (ia && ib && a[31] != b[31]))
			y = QNAN;
		else if (ia)
			y = a;
		else if (ib)
			y = b;
		else if (za && zb)
			y = {a[31] & b[31], 31'd0};
		else if (za)
			y = b;
		else if (zb)
			y = a;
		else if (mag == 52'd0)
			y = 32'd0;
		else if (be >= 10'sd255)
			y = {rs, 8'hFF, 23'd0};
`ifdef MUT_FADD_ZERO
		else if (be <= 10'sd0)
			y = {rs, 8'd0, mf};
`else
		else if (be <= 10'sd0)
			y = {rs, 31'd0};
`endif
		else
			y = {rs, be[7:0], mf};
	end

endmodule
