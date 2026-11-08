/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * ad_su_lane_tb: ad_su_lane against tools/gsi1model.py lane() (vectors of
 * tools/gen_lane_vectors.py).
 *  - qd: sim/vec/lane_qd.hex on NPHYS 8 (SUBGROUP 0), and a twin unit of
 *    NPHYS 4 fed the low 4 lanes of every group, whose outputs must equal
 *    the low 4 lanes of the NPHYS 8 unit every cycle.
 *  - sub: sim/vec/lane_sub.hex (1500 instructions: shfl idx/xor/up/down/rot
 *    in and out of range and from lanes outside EXEC, vote any/all, ballot,
 *    qd between them; EXEC full/empty/one/all-but-one/random; X on rs1/rs2
 *    of the lanes outside EXEC) on SUBGROUP 1 and NPHYS 4, 8, 16, 32.
 * Every result is checked in its cycle (SHORT_LAT after its slot; group g of
 * a subgroup op SHORT_LAT after x_end - (G-1) + g), with s_valid only for
 * rd-writing uops, s_lanes, s_rd, s_warp, s_grp and the written lanes' data;
 * x_ready must be 1 on every group but the last of a subgroup op, which
 * sees it 0 for exactly G cycles.  Idle cycles and other units' groups are
 * put between groups.
 *
 *   PASS ad_su_lane.qd
 *   PASS ad_su_lane.sub
 *   PASS ad_su_lane
 */
`timescale 1ns/1ps

module ad_su_lane_tbh #(
	parameter NPHYS = 8,
	parameter GRP_W = 2,
	parameter SUBGROUP = 1,
	parameter NI = 1500,
	parameter QDFILE = 0,
	parameter SEED = 1,
	parameter SHORT_LAT = 6
) (
	input wire clk,
	input wire rst_n,
	output reg done,
	output reg [31:0] nerr,
	output reg [31:0] nchk
);
`include "ad_su_uop.vh"
	localparam G = 32 / NPHYS;

	reg [127:0] vec [0:NI*33-1];

	reg x_valid;
	reg [1:0] x_warp;
	reg [GRP_W-1:0] x_grp;
	reg x_last;
	reg [107:0] x_uop;
	reg [NPHYS*32-1:0] x_a, x_b;
	reg [2*NPHYS-1:0] x_mask;
	wire x_ready;
	wire s_valid;
	wire [1:0] s_warp;
	wire [GRP_W-1:0] s_grp;
	wire [6:0] s_rd;
	wire [NPHYS*32-1:0] s_data;
	wire [NPHYS-1:0] s_lanes;

	ad_su_lane #(.NPHYS(NPHYS), .GRP_W(GRP_W), .SUBGROUP(SUBGROUP), .SHORT_LAT(SHORT_LAT)) dut (
		.clk(clk), .rst_n(rst_n), .x_valid(x_valid), .x_warp(x_warp), .x_grp(x_grp),
		.x_last(x_last), .x_sbe(3'd7), .x_pc(16'd0), .x_uop(x_uop), .x_a(x_a), .x_b(x_b),
		.x_c({NPHYS*32{1'b0}}), .x_mask(x_mask), .x_info(32'd0), .x_ready(x_ready),
		.s_valid(s_valid), .s_warp(s_warp), .s_grp(s_grp), .s_rd(s_rd), .s_data(s_data),
		.s_lanes(s_lanes)
	);

	/* twin of half the lanes (qd only): its outputs = the low lanes */
	generate
	if (QDFILE != 0) begin : g_twin
		localparam NH = NPHYS / 2;
		wire t_ready, t_valid;
		wire [1:0] t_warp;
		wire [GRP_W:0] t_grp;
		wire [6:0] t_rd;
		wire [NH*32-1:0] t_data;
		wire [NH-1:0] t_lanes;
		ad_su_lane #(.NPHYS(NH), .GRP_W(GRP_W + 1), .SUBGROUP(0), .SHORT_LAT(SHORT_LAT)) twin (
			.clk(clk), .rst_n(rst_n), .x_valid(x_valid), .x_warp(x_warp),
			.x_grp({x_grp, 1'b0}), .x_last(x_last), .x_sbe(3'd7), .x_pc(16'd0),
			.x_uop(x_uop), .x_a(x_a[NH*32-1:0]), .x_b(x_b[NH*32-1:0]),
			.x_c({NH*32{1'b0}}), .x_mask({x_mask[NPHYS +: NH], x_mask[NH-1:0]}),
			.x_info(32'd0), .x_ready(t_ready), .s_valid(t_valid), .s_warp(t_warp),
			.s_grp(t_grp), .s_rd(t_rd), .s_data(t_data), .s_lanes(t_lanes)
		);
		always @(posedge clk)
			if (rst_n && (t_ready !== x_ready || t_valid !== s_valid ||
			    (s_valid && (t_warp !== s_warp || t_grp !== {s_grp, 1'b0} || t_rd !== s_rd ||
			    t_lanes !== s_lanes[NH-1:0] || t_data !== s_data[NH*32-1:0])))) begin
				if (nerr < 20)
					$display("FAIL ad_su_lane.qd NPHYS %0d twin differs at %0t", NH, $time);
				nerr = nerr + 1;
			end
	end
	endgenerate

	/* expected results by cycle */
	reg sv [0:255];
	reg [1:0] sw [0:255];
	reg [GRP_W-1:0] sg [0:255];
	reg [6:0] sr [0:255];
	reg [NPHYS*32-1:0] sd [0:255];
	reg [NPHYS-1:0] sl [0:255];
	integer cyc;
	integer rs;

	task bad(input [8*40-1:0] what, input integer n);
		begin
			if (nerr < 20)
				$display("FAIL ad_su_lane.%0s NPHYS %0d inst %0d cycle %0d: %0s",
				    QDFILE ? "qd" : "sub", NPHYS, n, cyc, what);
			nerr = nerr + 1;
		end
	endtask

	integer it, g, ln, i, idle, zeros, c0, slot, base;
	reg [127:0] h, v;
	reg [7:0] op;
	reg [4:0] sub;
	reg [6:0] rd;
	reg wrd;
	reg [31:0] ex;
	reg [1:0] warp;
	reg is_sub;

	task sched(input integer at, input integer gg);
		integer k;
		begin
			slot = at % 256;
			if (sv[slot])
				bad("two results in one cycle", it);
			sv[slot] = 1;
			sw[slot] = warp;
			sg[slot] = gg;
			sr[slot] = rd;
			for (k = 0; k < NPHYS; k = k + 1) begin
				v = vec[base + 1 + gg * NPHYS + k];
				sl[slot][k] = v[0];
				sd[slot][k * 32 +: 32] = v[35:4];
			end
		end
	endtask

	initial begin
		if (QDFILE)
			$readmemh("sim/vec/lane_qd.hex", vec);
		else
			$readmemh("sim/vec/lane_sub.hex", vec);
		rs = SEED;
		done = 0; nerr = 0; nchk = 0;
		for (i = 0; i < 256; i = i + 1)
			sv[i] = 0;
		x_valid = 0; x_warp = 0; x_grp = 0; x_last = 0; x_uop = 0;
		x_a = 0; x_b = 0; x_mask = 0;
		@(posedge rst_n);
		for (it = 0; it < NI; it = it + 1) begin
			base = it * 33;
			h = vec[base];
			ex = h[31:0];
			/* header: op(8) sub(8) rd(8) wrd(4) exec(32) */
			op = h[59:52];
			sub = h[51:44];
			rd = h[43:36];
			wrd = h[32];
			warp = $urandom(rs);
			is_sub = (op != AD_LANE_QD);
			for (g = 0; g < G; g = g + 1) begin
				@(negedge clk);
				idle = ($urandom(rs) % 4 == 0) ? $urandom(rs) % 3 : 0;
				while (idle > 0) begin
					x_valid = $urandom(rs) % 2;
					x_uop = {$urandom(rs), $urandom(rs), $urandom(rs), $urandom(rs)};
					if (x_uop[3:0] == AD_UNIT_LANE)
						x_uop[3:0] = AD_UNIT_FPU;
					x_last = $urandom(rs);
					x_a = {NPHYS{$urandom(rs)}};
					x_b = {NPHYS{$urandom(rs)}};
					#1;
					if (!x_ready)
						bad("x_ready 0 on another unit's group", it);
					@(negedge clk);
					idle = idle - 1;
				end
				x_uop = 108'd0;
				x_uop[AD_UOP_UNIT +: 4] = AD_UNIT_LANE;
				x_uop[AD_UOP_OP +: 8] = op;
				x_uop[AD_UOP_SUB +: 5] = sub;
				x_uop[AD_UOP_RD +: 7] = rd;
				x_uop[AD_UOP_WRD] = wrd;
				x_uop[AD_UOP_CLS +: 3] = AD_CLS_A;
				x_warp = warp;
				x_grp = g;
				x_last = (g == G - 1);
				for (ln = 0; ln < NPHYS; ln = ln + 1) begin
					v = vec[base + 1 + g * NPHYS + ln];
					x_a[ln * 32 +: 32] = v[99:68];
					x_b[ln * 32 +: 32] = v[67:36];
					x_mask[ln] = ex[g * NPHYS + ln];
					x_mask[NPHYS + ln] = ex[g * NPHYS + ln] & $urandom(rs);
				end
				x_valid = 1;
				#1;
				if (is_sub && SUBGROUP && g == G - 1) begin
					c0 = cyc;
					zeros = 0;
					if (wrd)
						for (i = 0; i < G; i = i + 1)
							sched(c0 + 1 + i + SHORT_LAT, i);
					while (!x_ready && zeros < G + 4) begin
						zeros = zeros + 1;
						@(negedge clk);
						#1;
					end
					if (zeros != G)
						bad("x_ready not 0 for exactly G cycles", it);
				end else begin
					if (!x_ready)
						bad("x_ready 0", it);
					if (!is_sub && wrd)
						sched(cyc + SHORT_LAT, g);
				end
			end
			@(negedge clk);
			x_valid = 0;
			x_a = {NPHYS{32'hxxxxxxxx}};
			x_b = {NPHYS{32'hxxxxxxxx}};
		end
		repeat (SHORT_LAT + 4) @(negedge clk);
		done = 1;
	end

	integer k2;
	always @(posedge clk) begin
		if (!rst_n) begin
			cyc <= 0;
		end else begin
			cyc <= cyc + 1;
			slot = cyc % 256;
			if (sv[slot]) begin
				nchk = nchk + 1;
				if (!s_valid) begin
					bad("result missing", it);
				end else begin
					if (s_warp !== sw[slot]) bad("s_warp", it);
					if (s_grp !== sg[slot]) bad("s_grp", it);
					if (s_rd !== sr[slot]) bad("s_rd", it);
					if (s_lanes !== sl[slot]) bad("s_lanes", it);
					for (k2 = 0; k2 < NPHYS; k2 = k2 + 1)
						if (sl[slot][k2] && s_data[k2 * 32 +: 32] !== sd[slot][k2 * 32 +: 32]) begin
							if (nerr < 20)
								$display("FAIL ad_su_lane NPHYS %0d cycle %0d lane %0d: got %08x want %08x",
								    NPHYS, cyc, k2, s_data[k2 * 32 +: 32], sd[slot][k2 * 32 +: 32]);
							nerr = nerr + 1;
						end
				end
				sv[slot] = 0;
			end else if (s_valid !== 1'b0) begin
				bad("unexpected s_valid", it);
			end
		end
	end
endmodule

module ad_su_lane_tb;
	reg clk = 0;
	reg rst_n = 0;
	always #5 clk = ~clk;
	wire dq, d4, d8, d16, d32;
	wire [31:0] eq, e4, e8, e16, e32, cq, c4, c8, c16, c32;

	ad_su_lane_tbh #(.NPHYS(8), .GRP_W(2), .SUBGROUP(0), .NI(1200), .QDFILE(1), .SEED(3)) hq (
		.clk(clk), .rst_n(rst_n), .done(dq), .nerr(eq), .nchk(cq));
	ad_su_lane_tbh #(.NPHYS(4), .GRP_W(3), .SUBGROUP(1), .SEED(5)) h4 (
		.clk(clk), .rst_n(rst_n), .done(d4), .nerr(e4), .nchk(c4));
	ad_su_lane_tbh #(.NPHYS(8), .GRP_W(2), .SUBGROUP(1), .SEED(7)) h8 (
		.clk(clk), .rst_n(rst_n), .done(d8), .nerr(e8), .nchk(c8));
	ad_su_lane_tbh #(.NPHYS(16), .GRP_W(1), .SUBGROUP(1), .SEED(9)) h16 (
		.clk(clk), .rst_n(rst_n), .done(d16), .nerr(e16), .nchk(c16));
	ad_su_lane_tbh #(.NPHYS(32), .GRP_W(1), .SUBGROUP(1), .SEED(13)) h32 (
		.clk(clk), .rst_n(rst_n), .done(d32), .nerr(e32), .nchk(c32));

	initial begin
		repeat (4) @(posedge clk);
		rst_n = 1;
		wait (dq && d4 && d8 && d16 && d32);
		$display("ad_su_lane_tb: qd %0d results (%0d errors); sub NPHYS 4/8/16/32 %0d/%0d/%0d/%0d results (%0d/%0d/%0d/%0d errors)",
		    cq, eq, c4, c8, c16, c32, e4, e8, e16, e32);
		if (eq == 0 && cq > 0)
			$display("PASS ad_su_lane.qd");
		else
			$display("FAIL ad_su_lane.qd");
		if (e4 + e8 + e16 + e32 == 0 && c4 > 0 && c8 > 0 && c16 > 0 && c32 > 0)
			$display("PASS ad_su_lane.sub");
		else
			$display("FAIL ad_su_lane.sub");
		if (eq + e4 + e8 + e16 + e32 == 0)
			$display("PASS ad_su_lane");
		$finish;
	end

	initial begin
		#100000000;
		$display("FAIL ad_su_lane timeout");
		$finish;
	end
endmodule
