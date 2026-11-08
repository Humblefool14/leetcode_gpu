/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * ad_lane_stage: the staging registers of shfl/vote/ballot, per warp lane:
 * rs1, the EXEC bit, the shfl source lane and whether it exists.  we writes
 * the NPHYS lanes of group grp.
 */
module ad_lane_stage #(
	parameter NPHYS = 8,
	parameter WARP = 32,
	parameter LW = 5,
	parameter GRP_W = 2
) (
	input wire clk,
	input wire rst_n,
	input wire we,
	input wire [GRP_W-1:0] grp,
	input wire [NPHYS*32-1:0] rs1,
	input wire [NPHYS-1:0] exec,
	input wire [NPHYS*LW-1:0] src,
	input wire [NPHYS-1:0] ok,
	output reg [WARP*32-1:0] q_rs1,
	output reg [WARP-1:0] q_exec,
	output reg [WARP*LW-1:0] q_src,
	output reg [WARP-1:0] q_ok
);
	localparam G = WARP / NPHYS;

	integer g;
	always @(posedge clk) begin
		if (!rst_n) begin
			q_rs1 <= {WARP*32{1'b0}};
			q_exec <= {WARP{1'b0}};
			q_src <= {WARP*LW{1'b0}};
			q_ok <= {WARP{1'b0}};
		end else if (we) begin
			for (g = 0; g < G; g = g + 1)
				if ({{(32-GRP_W){1'b0}}, grp} == g) begin
					q_rs1[g * NPHYS * 32 +: NPHYS * 32] <= rs1;
					q_exec[g * NPHYS +: NPHYS] <= exec;
					q_src[g * NPHYS * LW +: NPHYS * LW] <= src;
					q_ok[g * NPHYS +: NPHYS] <= ok;
				end
		end
	end
endmodule
