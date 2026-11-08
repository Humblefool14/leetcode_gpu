/*
 * Amaterrace GPU
 * SPDX-License-Identifier: Zlib
 */

/*
 * ad_su_hcmp: fp16 compare (spec/gpu/su/ad_su_hcmp.md, gsi1fp.fcmp(F16)).
 * op 0 eq, 1 lt, 2 le, 3 ne; y = 0xFFFF when true, else 0.  Denormals are
 * flushed (equal to zero), -0 == +0, a NaN operand makes every compare false
 * except ne.  Combinational.
 */
module ad_su_hcmp (
	input wire [15:0] a,
	input wire [15:0] b,
	input wire [1:0] op,
	output wire [15:0] y
);
	wire za = (a[14:10] == 5'd0);
	wire zb = (b[14:10] == 5'd0);
	wire na = (a[14:10] == 5'd31) && (a[9:0] != 10'd0);
	wire nb = (b[14:10] == 5'd31) && (b[9:0] != 10'd0);
	/* Magnitudes after the flush. */
	wire [14:0] ma = za ? 15'd0 : a[14:0];
	wire [14:0] mb = zb ? 15'd0 : b[14:0];
	wire eq = (za && zb) || (a == b);
	/* a < b, ordered and not equal. */
	reg lt;
	always @(*) begin
		if (eq)
			lt = 1'b0;
		else if (za)
			lt = ~b[15];			/* 0 < b iff b positive */
		else if (zb)
			lt = a[15];
		else if (a[15] != b[15])
			lt = a[15];
		else
			lt = a[15] ? (ma > mb) : (ma < mb);
	end
	reg t;
	always @(*) begin
		case (op)
		2'd0: t = eq;
		2'd1: t = lt;
		2'd2: t = lt | eq;
		default: t = ~eq;
		endcase
`ifdef MUT_HCMP_NAN
		if (na || nb)
			t = 1'b0;
`else
		if (na || nb)
			t = (op == 2'd3);
`endif
	end
	assign y = {16{t}};
endmodule
