/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * ad_lane_sub: the result of lane group e of a staged shfl/vote/ballot
 * (combinational).  op 1 shfl: EXEC lane l gets rs1 of its source lane s
 * when s exists and is in EXEC, else its own rs1 (lanes outside EXEC: 0,
 * not written); op 2 vote (sub 0 any: B != 0, else all: B == EXEC) as a
 * Boolean, op 3 ballot B, with B = the EXEC lanes whose rs1 != 0; vote and
 * ballot write every lane.  Lanes outside EXEC are never read.
 */
module ad_lane_sub #(
	parameter NPHYS = 8,
	parameter WARP = 32,
	parameter LW = 5,
	parameter GRP_W = 2
) (
	input wire [1:0] op,
	input wire [4:0] sub,
	input wire [GRP_W-1:0] e,
	input wire [WARP*32-1:0] q_rs1,
	input wire [WARP-1:0] q_exec,
	input wire [WARP*LW-1:0] q_src,
	input wire [WARP-1:0] q_ok,
	output reg [NPHYS*32-1:0] y,
	output reg [NPHYS-1:0] lanes
);
	localparam G = WARP / NPHYS;

	reg [WARP-1:0] bal;
	reg [31:0] vb;
	integer l, j;
	reg [LW-1:0] sl;
	reg [31:0] own, oth;
	always @(*) begin
		for (l = 0; l < WARP; l = l + 1)
			bal[l] = q_exec[l] & (|q_rs1[l * 32 +: 32]);
		if (op == 2'd3)
			vb = {{(32-WARP){1'b0}}, bal};
		else if (sub == 5'd0)
			vb = (bal != {WARP{1'b0}}) ? 32'hFFFFFFFF : 32'd0;
		else
			vb = (bal == q_exec) ? 32'hFFFFFFFF : 32'd0;
`ifdef MUT_LANE_VOTE
		if (op == 2'd2 && sub != 5'd0)
			vb = (bal != {WARP{1'b0}}) ? 32'hFFFFFFFF : 32'd0;
`endif
		y = {NPHYS*32{1'b0}};
		lanes = {NPHYS{1'b1}};
		sl = {LW{1'b0}};
		own = 32'd0;
		oth = 32'd0;
		if (op == 2'd1) begin
			for (j = 0; j < NPHYS; j = j + 1) begin
				l = e * NPHYS + j;
				sl = q_src[l * LW +: LW];
				own = q_rs1[l * 32 +: 32];
				oth = q_rs1[sl * 32 +: 32];
				lanes[j] = q_exec[l];
				if (!q_exec[l])
					y[j * 32 +: 32] = 32'd0;
				else if (q_ok[l] && q_exec[sl])
					y[j * 32 +: 32] = oth;
				else
					y[j * 32 +: 32] = own;
			end
		end else begin
			for (j = 0; j < NPHYS; j = j + 1)
				y[j * 32 +: 32] = vb;
		end
	end
endmodule
