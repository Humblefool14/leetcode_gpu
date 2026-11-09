/*
 * Amaterrace GPU
 * SPDX-License-Identifier: Zlib
 */

/*
 * ad_su_hminmax: fp16 min/max (spec/gpu/su/ad_su_hminmax.md, gsi1fp.fminmax(F16)).
 * Operands are flushed (a denormal becomes a zero of its sign); a NaN operand
 * gives the other (flushed) operand, two NaNs give 0x7E00; -0 < +0.
 * mx 0 min, 1 max.  Combinational.
 */
module ad_su_hminmax (
	input wire [15:0] a,
	input wire [15:0] b,
	input wire mx,
	output reg [15:0] y
);
	wire [15:0] fa = (a[14:10] == 5'd0) ? {a[15], 15'd0} : a;
	wire [15:0] fb = (b[14:10] == 5'd0) ? {b[15], 15'd0} : b;
	wire na = (a[14:10] == 5'd31) && (a[9:0] != 10'd0);
	wire nb = (b[14:10] == 5'd31) && (b[9:0] != 10'd0);
	/* Total order of the flushed non-NaN values with -0 < +0: a <= b. */
	reg ale;
	always @(*) begin
		if (fa[15] != fb[15])
			ale = fa[15];
		else if (fa[15])
			ale = fa[14:0] >= fb[14:0];
		else
			ale = fa[14:0] <= fb[14:0];
		if (na && nb)
			y = 16'h7E00;
		else if (na)
			y = fb;
		else if (nb)
			y = fa;
`ifdef MUT_HMINMAX_ORDER
		else
			y = (mx ^ ale) ? fb : fa;
`else
		else if (mx)
			y = ale ? fb : fa;
		else
			y = ale ? fa : fb;
`endif
	end
endmodule
