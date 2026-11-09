/*
 * Amaterrace GPU
 * SPDX-License-Identifier: Zlib
 */

/*
 * ad_su_h2f: fp16 to fp32 (spec/gpu/su/ad_su_h2f.md, gsi1fp.f16_to_f32).
 * Denormals flush to a zero of their sign, NaN gives 0x7FC00000, infinities
 * and normals are exact.  Combinational.
 */
module ad_su_h2f (
	input wire [15:0] h,
	output reg [31:0] f
);
	wire s = h[15];
	wire [4:0] e = h[14:10];
	wire [9:0] m = h[9:0];

	always @(*) begin
		if (e == 5'd31)
			f = (m != 10'd0) ? 32'h7FC00000 : {s, 8'hFF, 23'd0};
`ifdef MUT_H2F_BIAS
		else if (e == 5'd0)
			f = {s, 31'd0};
		else
			f = {s, {3'd0, e} + 8'd111, m, 13'd0};
`else
		else if (e == 5'd0)
			f = {s, 31'd0};
		else
			f = {s, {3'd0, e} + 8'd112, m, 13'd0};
`endif
	end
endmodule
