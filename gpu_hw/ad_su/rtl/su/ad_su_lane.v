/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * ad_su_lane: cross-lane operations (spec/gpu/su/ad_su_lane.md), short
 * results exactly SHORT_LAT cycles after their slot on the bus.
 *  - qd (always): one group per cycle, ad_lane_qd on the group's lanes.
 *  - shfl/vote/ballot (SUBGROUP = 1): the groups are staged as they pass
 *    (ad_lane_srcl computes each lane's shfl source, ad_lane_stage keeps
 *    rs1, EXEC, source, ok per warp lane); the last group is staged in its
 *    first cycle and held on the bus for G more cycles (ad_lane_ctl) in
 *    which ad_lane_sub's result of groups 0..G-1 enters the pipeline.
 * s_valid only for uops that write rd; s_lanes = the EXEC lanes of the
 * group (vote/ballot: every lane).
 * WARP (added parameter, default 32): the warp size, reduced only in the
 * formal harness.
 */
module ad_su_lane #(
	parameter NPHYS = 8,
	parameter NWARPS = 4,
	parameter WARP_W = 2,
	parameter GRP_W = 2,
	parameter SBE_W = 2,
	parameter UOP_W = 108,
	parameter SUBGROUP = 0,
	parameter SHORT_LAT = 6,
	parameter WARP = 32
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
	output wire s_valid,
	output wire [WARP_W-1:0] s_warp,
	output wire [GRP_W-1:0] s_grp,
	output wire [6:0] s_rd,
	output wire [NPHYS*32-1:0] s_data,
	output wire [NPHYS-1:0] s_lanes
);
`include "ad_su_uop.vh"

	localparam G = WARP / NPHYS;
	localparam LW = $clog2(WARP);

	wire [7:0] op = x_uop[AD_UOP_OP +: 8];
	wire [4:0] sub = x_uop[AD_UOP_SUB +: 5];
	wire mine = x_valid && (x_uop[AD_UOP_UNIT +: 4] == AD_UNIT_LANE);
	wire is_qd = (op == AD_LANE_QD);
	wire take = mine && x_ready;

	/* qd */
	wire [NPHYS*32-1:0] qd_y;
	ad_lane_qd #(.NPHYS(NPHYS)) u_qd (.sub(sub), .v(x_a), .y(qd_y));

	/* entry of the result pipeline */
	reg in_v;
	reg [WARP_W-1:0] in_warp;
	reg [GRP_W-1:0] in_grp;
	reg [6:0] in_rd;
	reg [NPHYS*32-1:0] in_data;
	reg [NPHYS-1:0] in_lanes;

	wire emit;
	wire [GRP_W-1:0] e;
	wire [NPHYS*32-1:0] sub_y;
	wire [NPHYS-1:0] sub_lanes;
	wire [WARP_W-1:0] m_warp;
	wire [6:0] m_rd;
	wire m_wrd;

	generate
	if (SUBGROUP != 0) begin : g_sub
		wire bus_sub = mine && !is_qd;
		wire stage_we, go_emit;
		wire [NPHYS*LW-1:0] src;
		wire [NPHYS-1:0] ok;
		wire [WARP*32-1:0] q_rs1;
		wire [WARP-1:0] q_exec, q_ok;
		wire [WARP*LW-1:0] q_src;
		reg [1:0] m_op;
		reg [4:0] m_sub;
		reg [WARP_W-1:0] r_warp;
		reg [6:0] r_rd;
		reg r_wrd;

		assign m_warp = r_warp;
		assign m_rd = r_rd;
		assign m_wrd = r_wrd;

		ad_lane_ctl #(.G(G), .GRP_W(GRP_W)) u_ctl (
			.clk(clk), .rst_n(rst_n), .bus_sub(bus_sub), .bus_last(x_last),
			.x_ready(x_ready), .stage_we(stage_we), .go_emit(go_emit),
			.emit(emit), .e(e)
		);

		genvar j;
		for (j = 0; j < NPHYS; j = j + 1) begin : g_src
			wire [31:0] lw = x_grp * NPHYS + j;
			wire [LW-1:0] l = lw[LW-1:0];
			ad_lane_srcl #(.WARP(WARP), .LW(LW)) u_srcl (
				.l(l), .rs2(x_b[j * 32 +: 32]), .sub(sub),
				.s(src[j * LW +: LW]), .ok(ok[j])
			);
		end

		ad_lane_stage #(.NPHYS(NPHYS), .WARP(WARP), .LW(LW), .GRP_W(GRP_W)) u_stage (
			.clk(clk), .rst_n(rst_n), .we(stage_we), .grp(x_grp),
			.rs1(x_a), .exec(x_mask[NPHYS-1:0]), .src(src), .ok(ok),
			.q_rs1(q_rs1), .q_exec(q_exec), .q_src(q_src), .q_ok(q_ok)
		);

		always @(posedge clk) begin
			if (!rst_n) begin
				r_warp <= {WARP_W{1'b0}};
				r_rd <= 7'd0;
				r_wrd <= 1'b0;
				m_op <= 2'd0;
				m_sub <= 5'd0;
			end else if (go_emit) begin
				r_warp <= x_warp;
				r_rd <= x_uop[AD_UOP_RD +: 7];
				r_wrd <= x_uop[AD_UOP_WRD];
				m_op <= op[1:0];
				m_sub <= sub;
			end
		end

		ad_lane_sub #(.NPHYS(NPHYS), .WARP(WARP), .LW(LW), .GRP_W(GRP_W)) u_sub (
			.op(m_op), .sub(m_sub), .e(e), .q_rs1(q_rs1), .q_exec(q_exec),
			.q_src(q_src), .q_ok(q_ok), .y(sub_y), .lanes(sub_lanes)
		);
	end else begin : g_nosub
		assign x_ready = 1'b1;
		assign emit = 1'b0;
		assign e = {GRP_W{1'b0}};
		assign sub_y = {NPHYS*32{1'b0}};
		assign sub_lanes = {NPHYS{1'b0}};
		assign m_warp = {WARP_W{1'b0}};
		assign m_rd = 7'd0;
		assign m_wrd = 1'b0;
	end
	endgenerate

	always @(*) begin
		if (emit) begin
			in_v = m_wrd;
			in_warp = m_warp;
			in_grp = e;
			in_rd = m_rd;
			in_data = sub_y;
			in_lanes = sub_lanes;
		end else begin
			in_v = take && is_qd && x_uop[AD_UOP_WRD];
			in_warp = x_warp;
			in_grp = x_grp;
			in_rd = x_uop[AD_UOP_RD +: 7];
			in_data = qd_y;
			in_lanes = x_mask[NPHYS-1:0];
		end
	end

	/* SHORT_LAT pipeline stages */
	reg [SHORT_LAT-1:0] p_v;
	reg [WARP_W-1:0] p_warp [0:SHORT_LAT-1];
	reg [GRP_W-1:0] p_grp [0:SHORT_LAT-1];
	reg [6:0] p_rd [0:SHORT_LAT-1];
	reg [NPHYS*32-1:0] p_data [0:SHORT_LAT-1];
	reg [NPHYS-1:0] p_lanes [0:SHORT_LAT-1];

	integer k;
	always @(posedge clk) begin
		if (!rst_n) begin
			p_v <= {SHORT_LAT{1'b0}};
			for (k = 0; k < SHORT_LAT; k = k + 1) begin
				p_warp[k] <= {WARP_W{1'b0}};
				p_grp[k] <= {GRP_W{1'b0}};
				p_rd[k] <= 7'd0;
				p_data[k] <= {NPHYS*32{1'b0}};
				p_lanes[k] <= {NPHYS{1'b0}};
			end
		end else begin
			p_v[0] <= in_v;
			p_warp[0] <= in_warp;
			p_grp[0] <= in_grp;
			p_rd[0] <= in_rd;
			p_data[0] <= in_data;
			p_lanes[0] <= in_lanes;
			for (k = 1; k < SHORT_LAT; k = k + 1) begin
				p_v[k] <= p_v[k-1];
				p_warp[k] <= p_warp[k-1];
				p_grp[k] <= p_grp[k-1];
				p_rd[k] <= p_rd[k-1];
				p_data[k] <= p_data[k-1];
				p_lanes[k] <= p_lanes[k-1];
			end
		end
	end

	assign s_valid = p_v[SHORT_LAT-1];
	assign s_warp = p_warp[SHORT_LAT-1];
	assign s_grp = p_grp[SHORT_LAT-1];
	assign s_rd = p_rd[SHORT_LAT-1];
	assign s_data = p_data[SHORT_LAT-1];
	assign s_lanes = p_lanes[SHORT_LAT-1];
endmodule
