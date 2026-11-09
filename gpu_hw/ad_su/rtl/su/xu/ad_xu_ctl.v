/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * ad_xu_ctl: the group sequencer of a lane-by-lane long unit.
 * IDLE (x_ready 1) -take-> RUN: the EXEC lanes go one at a time to the
 * lane engine, lowest first (the next one starts in the cycle the previous
 * one is done) -> RET: one beat (l_valid) held until l_ready -> IDLE.
 * A group without EXEC lanes goes straight to RET.
 */
module ad_xu_ctl #(
	parameter NPHYS = 8,
	parameter LW = (NPHYS > 1) ? $clog2(NPHYS) : 1
) (
	input wire clk,
	input wire rst_n,
	input wire take,
	input wire [NPHYS-1:0] exec,
	output wire x_ready,
	output reg eng_start,
	output reg [LW-1:0] eng_lane,
	input wire eng_done,
	output wire res_we,
	output wire [LW-1:0] res_lane,
	output wire l_valid,
	input wire l_ready
);
	localparam [1:0] S_IDLE = 2'd0, S_RUN = 2'd1, S_RET = 2'd2;

	reg [1:0] st;
	reg [NPHYS-1:0] pend;
	reg eng_on;
	reg [LW-1:0] cur;

	wire fin = eng_on & eng_done;
	wire [NPHYS-1:0] npend = fin ? (pend & ~({{(NPHYS-1){1'b0}}, 1'b1} << cur)) : pend;
	wire free = ~eng_on | eng_done;

	integer i;
	always @(*) begin
		eng_lane = {LW{1'b0}};
		for (i = NPHYS - 1; i >= 0; i = i - 1)
			if (npend[i])
				eng_lane = i[LW-1:0];
		eng_start = (st == S_RUN) && free && (npend != {NPHYS{1'b0}});
	end

	assign x_ready = (st == S_IDLE);
	assign l_valid = (st == S_RET);
	assign res_we = (st == S_RUN) && fin;
	assign res_lane = cur;

	always @(posedge clk) begin
		if (!rst_n) begin
			st <= S_IDLE;
			pend <= {NPHYS{1'b0}};
			eng_on <= 1'b0;
			cur <= {LW{1'b0}};
		end else begin
			case (st)
			S_IDLE: if (take) begin
				pend <= exec;
				st <= S_RUN;
			end
			S_RUN: begin
				pend <= npend;
				if (eng_start) begin
					eng_on <= 1'b1;
					cur <= eng_lane;
				end else if (free) begin
					eng_on <= 1'b0;
					st <= S_RET;
				end
			end
			default: if (l_ready)
				st <= S_IDLE;
			endcase
		end
	end
endmodule
