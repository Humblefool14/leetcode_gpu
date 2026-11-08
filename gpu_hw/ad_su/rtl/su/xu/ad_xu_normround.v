/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * ad_xu_normround: the fp32 of (-1)^s * n * 2^e (n > 0, up to 48 bits;
 * sticky: nonzero bits below n's LSB), RNE, flushed: overflow -> inf(s),
 * a biased exponent <= 0 after rounding -> zero(s).  As tools/gsi1fp.py
 * norm_round() (combinational).
 */
module ad_xu_normround (
	input wire s,
	input wire [47:0] n,
	input wire signed [11:0] e,
	input wire sticky,
	output reg [31:0] y
);
	reg [5:0] lz;
	integer i;
	always @(*) begin
		lz = 6'd48;
		for (i = 0; i < 48; i = i + 1)
			if (n[i])
				lz = 6'd47 - i[5:0];
	end

	wire [47:0] nn = n << lz;
	wire [23:0] mt = nn[47:24];
	wire g = nn[23];
	wire st = sticky | (|nn[22:0]);
	wire up = g & (st | mt[0]);
	wire [24:0] mr = {1'b0, mt} + {24'd0, up};
	/* bit length k = 48 - lz; biased exponent e + k + 126 */
	wire signed [13:0] be = $signed({{2{e[11]}}, e}) + 14'sd174 - $signed({8'd0, lz}) +
		(mr[24] ? 14'sd1 : 14'sd0);
	wire [22:0] mo = mr[24] ? mr[23:1] : mr[22:0];

	always @(*) begin
		if (be >= 14'sd255)
			y = {s, 8'hFF, 23'd0};
		else if (be <= 14'sd0)
			y = {s, 31'd0};
		else
			y = {s, be[7:0], mo};
`ifdef MUT_XU_ROUND
		if (be > 14'sd0 && be < 14'sd255)
			y = {s, be[7:0], mt[22:0]};
`endif
	end
endmodule
