/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * ad_lane_ctl: the shfl/vote/ballot sequencer.  IDLE: the groups of a
 * subgroup instruction are staged as they pass (x_ready 1); the last group
 * (bus_last) is staged in its first cycle with x_ready 0 and the state
 * moves to EMIT, where the results of groups e = 0..G-1 enter the result
 * pipeline, one per cycle, while the last group stays on the bus; x_ready
 * is 1 in the last of them (x_end).  x_ready is therefore 0 for exactly G
 * cycles on the last group.
 */
module ad_lane_ctl #(
	parameter G = 4,
	parameter GRP_W = 2
) (
	input wire clk,
	input wire rst_n,
	input wire bus_sub,		/* x_valid, unit lane, a subgroup op */
	input wire bus_last,		/* ... and x_last */
	output wire x_ready,
	output wire stage_we,
	output wire go_emit,
	output wire emit,
	output reg [GRP_W-1:0] e
);
	reg st;		/* 0 IDLE, 1 EMIT */

	wire e_end = ({{(32-GRP_W){1'b0}}, e} == G - 1);

	assign stage_we = !st && bus_sub;
	assign go_emit = !st && bus_sub && bus_last;
	assign emit = st;
`ifdef MUT_LANE_HOLD
	assign x_ready = st ? (e == G - 2) : !(bus_sub && bus_last);
`else
	assign x_ready = st ? e_end : !(bus_sub && bus_last);
`endif

	always @(posedge clk) begin
		if (!rst_n) begin
			st <= 1'b0;
			e <= {GRP_W{1'b0}};
		end else if (!st) begin
			if (go_emit) begin
				st <= 1'b1;
				e <= {GRP_W{1'b0}};
			end
		end else begin
			e <= e + 1'b1;
			if (e_end) begin
				st <= 1'b0;
				e <= {GRP_W{1'b0}};
			end
		end
	end
endmodule
