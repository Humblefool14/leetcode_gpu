/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * ad_lane_srcl: the shfl source lane of warp lane l (combinational).
 * sub 0 idx s = rs2, 1 xor s = l ^ rs2, 2 up s = l - rs2, 3 down s = l + rs2
 * (integers without wraparound on the whole 32-bit unsigned rs2; ok when
 * 0 <= s < WARP), 4 rot s = (l + rs2) mod WARP (always ok); other sub
 * values: ok = 0 (the lane keeps its own rs1).
 */
module ad_lane_srcl #(
	parameter WARP = 32,
	parameter LW = 5
) (
	input wire [LW-1:0] l,
	input wire [31:0] rs2,
	input wire [4:0] sub,
	output reg [LW-1:0] s,
	output reg ok
);
	wire [31:0] lz = {{(32-LW){1'b0}}, l};
	wire [31:0] x = lz ^ rs2;
	wire [32:0] dn = {1'b0, lz} + {1'b0, rs2};
	wire [LW-1:0] r2 = rs2[LW-1:0];

	always @(*) begin
		case (sub)
		5'd0: begin s = r2; ok = (rs2 < WARP); end
		5'd1: begin s = x[LW-1:0]; ok = (x < WARP); end
		5'd2: begin s = l - r2; ok = (rs2 <= lz); end
		5'd3: begin s = dn[LW-1:0]; ok = (dn < WARP); end
		5'd4: begin s = l + r2; ok = 1'b1; end
		default: begin s = l; ok = 1'b0; end
		endcase
	end
endmodule
