/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * ad_div_sign: sign handling of the RISC-V divide (combinational).
 * Before: the magnitudes ua, ub of the operands (signed ops div/rem) or the
 * operands (divu/remu).  After: from the unsigned quotient uq and remainder
 * ur, the result: quotient negated when the signs differ, remainder with
 * the dividend's sign; division by zero gives all ones (div/divu) or the
 * dividend (rem/remu); INT_MIN / -1 gives INT_MIN (div) or 0 (rem).
 * op: 0 div, 1 divu, 2 rem, 3 remu (AD_DIV_*).
 */
module ad_div_sign #(
	parameter W = 32
) (
	input wire [1:0] op,
	input wire [W-1:0] a,
	input wire [W-1:0] b,
	output wire [W-1:0] ua,
	output wire [W-1:0] ub,
	input wire [W-1:0] uq,
	input wire [W-1:0] ur,
	output reg [W-1:0] res
);
	wire sgn = ~op[0];		/* div, rem */
	wire na = sgn & a[W-1];
	wire nb = sgn & b[W-1];
	wire bz = (b == {W{1'b0}});
	wire ovf = sgn & (a == {1'b1, {(W-1){1'b0}}}) & (b == {W{1'b1}});
	wire [W-1:0] q_s = (na ^ nb) ? (~uq + 1'b1) : uq;
	wire [W-1:0] r_s = na ? (~ur + 1'b1) : ur;

	assign ua = na ? (~a + 1'b1) : a;
	assign ub = nb ? (~b + 1'b1) : b;

	always @(*) begin
		if (bz)
			res = op[1] ? a : {W{1'b1}};
		else if (ovf)
			res = op[1] ? {W{1'b0}} : a;
		else
			res = op[1] ? r_s : q_s;
`ifdef MUT_DIV_SIGN
		if (ovf)
			res = {W{1'b0}};
`endif
	end
endmodule
