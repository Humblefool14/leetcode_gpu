/*
 * Amaterrace GPU
 * SPDX-License-Identifier: Zlib
 */

/*
 * ad_su_hrnd: fp16 rounding of a normalised mantissa (spec/gpu/su/ad_su_hrnd.md).
 * value = (-1)^s * m[12:2].m[1]m[0]... * 2^(e-15) with m[12] = 1, m[1] the round
 * bit and m[0] the sticky bit.  One rounding to 11 bits under r (0 RNE, 1 RTZ,
 * 2 RDN, 3 RUP, 4 RMM, 5-7 RNE), then: biased exponent >= 31 overflows (RTZ and
 * the rounding towards the other infinity give the largest finite), <= 0 gives a
 * zero of the sign (gsi1fp.Fmt.round for F16).  Combinational.
 */
module ad_su_hrnd (
	input wire s,
	input wire signed [9:0] e,
	input wire [12:0] m,
	input wire [2:0] r,
	output reg [15:0] y
);
	wire lsb = m[2];
	wire rb = m[1];
	wire st = m[0];
	reg inc;
	/* verilator lint_off UNUSEDSIGNAL */
	reg [11:0] mr;
	/* verilator lint_on UNUSEDSIGNAL */
	reg signed [10:0] er;
	reg ovf_max;

	always @(*) begin
		case (r)
		3'd1: inc = 1'b0;			/* RTZ */
		3'd2: inc = s & (rb | st);		/* RDN */
		3'd3: inc = ~s & (rb | st);		/* RUP */
		3'd4: inc = rb;				/* RMM */
		default: inc = rb & (st | lsb);		/* RNE */
		endcase
		mr = {1'b0, m[12:2]} + {11'd0, inc};
		er = {e[9], e} + {10'd0, mr[11]};
		ovf_max = (r == 3'd1) || (r == 3'd2 && !s) || (r == 3'd3 && s);
		if (er >= 11'sd31)
			y = ovf_max ? {s, 15'h7BFF} : {s, 15'h7C00};
`ifdef MUT_HRND_DENORM
		else if (er <= 11'sd0)
			y = {s, 5'd0, mr[9:0]};
`else
		else if (er <= 11'sd0)
			y = {s, 15'd0};
`endif
		else
			y = {s, er[4:0], (mr[11] ? 10'd0 : mr[9:0])};
	end
endmodule
