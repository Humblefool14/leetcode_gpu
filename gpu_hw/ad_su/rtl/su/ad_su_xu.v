/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * ad_su_xu: the SU's transcendental unit (spec/gpu/su/ad_su_xu.md).
 * rcp rsq exp2 log2 sin cos fsqrt, bit-identical to tools/gsi1fp.py xu(),
 * one lane group at a time: the group is taken into a buffer (x_ready 0
 * from then on), each EXEC lane goes through the sequential engine
 * ad_xu_engine (about 30-60 cycles; specials 1), then one long beat (class
 * of the uop) goes out held until l_ready; l_last is the group's x_last.
 * Lanes outside EXEC are skipped and not written.
 */
module ad_su_xu #(
	parameter NPHYS = 8,
	parameter NWARPS = 4,
	parameter WARP_W = 2,
	parameter GRP_W = 2,
	parameter SBE_W = 2,
	parameter UOP_W = 108
) (
	input wire clk,
	input wire rst_n,
	input wire x_valid,
	input wire [WARP_W-1:0] x_warp,
	input wire [GRP_W-1:0] x_grp,
	input wire x_last,
	input wire [SBE_W:0] x_sbe,
	input wire [15:0] x_pc,
	input wire [UOP_W-1:0] x_uop,
	input wire [NPHYS*32-1:0] x_a,
	input wire [NPHYS*32-1:0] x_b,
	input wire [NPHYS*32-1:0] x_c,
	input wire [2*NPHYS-1:0] x_mask,
	input wire [31:0] x_info,
	output wire x_ready,
	output wire l_valid,
	input wire l_ready,
	output reg [WARP_W-1:0] l_warp,
	output reg [GRP_W-1:0] l_grp,
	output reg [6:0] l_rd,
	output reg [NPHYS*32-1:0] l_data,
	output reg [NPHYS-1:0] l_lanes,
	output reg l_wr,
	output reg l_last,
	output reg [SBE_W:0] l_sbe,
	output reg [2:0] l_cls
);
`include "ad_su_uop.vh"

	localparam LW = (NPHYS > 1) ? $clog2(NPHYS) : 1;

	wire take = x_valid && (x_uop[AD_UOP_UNIT +: 4] == AD_UNIT_XU) && x_ready;

	reg [NPHYS*32-1:0] a_buf;
	reg [2:0] op_r;

	wire eng_start, eng_done, eng_busy, res_we;
	wire [LW-1:0] eng_lane, res_lane;
	wire [31:0] eng_res;

	ad_xu_ctl #(.NPHYS(NPHYS), .LW(LW)) u_ctl (
		.clk(clk), .rst_n(rst_n), .take(take), .exec(x_mask[NPHYS-1:0]),
		.x_ready(x_ready), .eng_start(eng_start), .eng_lane(eng_lane),
		.eng_done(eng_done), .res_we(res_we), .res_lane(res_lane),
		.l_valid(l_valid), .l_ready(l_ready)
	);

	ad_xu_engine u_eng (
		.clk(clk), .rst_n(rst_n), .start(eng_start), .op(op_r),
		.x(a_buf[eng_lane*32 +: 32]), .busy(eng_busy), .done(eng_done), .y(eng_res)
	);

	always @(posedge clk) begin
		if (!rst_n) begin
			a_buf <= {NPHYS*32{1'b0}};
			op_r <= 3'd0;
			l_warp <= {WARP_W{1'b0}};
			l_grp <= {GRP_W{1'b0}};
			l_rd <= 7'd0;
			l_data <= {NPHYS*32{1'b0}};
			l_lanes <= {NPHYS{1'b0}};
			l_wr <= 1'b0;
			l_last <= 1'b0;
			l_sbe <= {(SBE_W+1){1'b0}};
			l_cls <= 3'd0;
		end else if (take) begin
			a_buf <= x_a;
			op_r <= x_uop[AD_UOP_OP +: 3];
			l_warp <= x_warp;
			l_grp <= x_grp;
			l_rd <= x_uop[AD_UOP_RD +: 7];
			l_data <= {NPHYS*32{1'b0}};
			l_lanes <= x_mask[NPHYS-1:0];
			l_wr <= x_uop[AD_UOP_WRD];
			l_last <= x_last;
			l_sbe <= x_sbe;
			l_cls <= x_uop[AD_UOP_CLS +: 3];
		end else if (res_we) begin
			l_data[res_lane*32 +: 32] <= eng_res;
		end
	end
endmodule
