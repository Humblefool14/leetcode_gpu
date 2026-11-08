/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * ad_lane_qd: the quad operations of one lane group (combinational).
 * Lane l of a quad (v0..v3 its lanes): sub 0 qdx = v[l|1] - v[l&~1],
 * 1 qdy = v[l|2] - v[l&~2] (fp32 RNE flushed, two ad_lane_fsub per quad),
 * 2 qswap1 = v[l^1], 3 qswap2 = v[l^2], 4 qswap3 = v[l^3], 5 qbcast =
 * v[l&~3]; sub 6/7 (not decoded) give v[l].  Partners are read whatever
 * EXEC is.
 */
module ad_lane_qd #(
	parameter NPHYS = 8
) (
	input wire [4:0] sub,
	input wire [NPHYS*32-1:0] v,
	output reg [NPHYS*32-1:0] y
);
	localparam NQ = NPHYS / 4;

	genvar q;
	generate
	for (q = 0; q < NQ; q = q + 1) begin : g_quad
		wire [31:0] v0 = v[(4 * q + 0) * 32 +: 32];
		wire [31:0] v1 = v[(4 * q + 1) * 32 +: 32];
		wire [31:0] v2 = v[(4 * q + 2) * 32 +: 32];
		wire [31:0] v3 = v[(4 * q + 3) * 32 +: 32];
		wire dx = (sub == 5'd0);
		wire [31:0] fa, fb;
		/* qdx: A = v1 - v0 (lanes 0, 1), B = v3 - v2 (lanes 2, 3);
		 * qdy: A = v2 - v0 (lanes 0, 2), B = v3 - v1 (lanes 1, 3). */
		ad_lane_fsub u_a (.a(dx ? v1 : v2), .b(v0), .y(fa));
		ad_lane_fsub u_b (.a(v3), .b(dx ? v2 : v1), .y(fb));
		always @(*) begin
			case (sub)
			5'd0: y[q * 128 +: 128] = {fb, fb, fa, fa};
			5'd1: y[q * 128 +: 128] = {fb, fa, fb, fa};
			5'd2: y[q * 128 +: 128] = {v2, v3, v0, v1};
			5'd3: y[q * 128 +: 128] = {v1, v0, v3, v2};
			5'd4: y[q * 128 +: 128] = {v0, v1, v2, v3};
			5'd5: y[q * 128 +: 128] = {v0, v0, v0, v0};
			default: y[q * 128 +: 128] = {v3, v2, v1, v0};
			endcase
`ifdef MUT_LANE_QD
			if (sub == 5'd4)
				y[q * 128 +: 128] = {v1, v0, v3, v2};
`endif
		end
	end
	endgenerate
endmodule
