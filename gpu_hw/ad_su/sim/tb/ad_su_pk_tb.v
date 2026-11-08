/*
 * Amaterrace GPU
 * SPDX-License-Identifier: Zlib
 */

/*
 * ad_su_pk_tb: ad_su_pk against tools/gsi1fp.pk (sim/vec/pk_lane.hex of
 * tools/gen_pk_vectors.py: 7000 groups of 8 lanes sharing op, rm, hsel, sub, sat;
 * every op, rm 0-7, hsel 0-3, sat).  One random stimulus (groups of the unit
 * between random groups of other units, random EXEC masks, rd, warp, group, WRD,
 * idle cycles) drives five units:
 *   u8  NPHYS 8 PACKED 1         every result vs the reference
 *   u0  NPHYS 8 PACKED 0         packh/unpackh/swaph vs the reference, others 0
 *   us  NPHYS 8 PACKED 1 PK_SHARED  its side: float ops not taken (no result,
 *                                x_ready 0 the next cycle), the rest vs the reference
 *   u4, us4  NPHYS 4 (GRP_W 3)   equal to the low 4 lanes of u8 / us every cycle
 * The short result is checked against a TB pipeline of exactly SHORT_LAT stages.
 *   .pack   packh/unpackh/swaph groups on u8, u0, us
 *   .arith  every other group on u8, u0 (0), us; x_ready always 1 (u8, u0)
 *   .shared skipped (needs ad_su_fpu: integration)
 *   .nphys4 u4 == u8[3:0], us4 == us[3:0] every cycle
 */
`timescale 1ns/1ps
module ad_su_pk_tb;
`include "ad_su_uop.vh"
	localparam NV = 56000;
	integer NG;
	localparam L = 6;
	localparam N = 8;

	reg clk = 0, rst_n = 0;
	always #5 clk = ~clk;

	reg [147:0] vl [0:NV-1];

	reg x_valid;
	reg [1:0] x_warp, x_grp;
	reg x_last;
	reg [2:0] x_sbe;
	reg [15:0] x_pc;
	reg [107:0] x_uop;
	reg [N*32-1:0] x_a, x_b, x_c;
	reg [2*N-1:0] x_mask;
	reg [31:0] x_info;

	/* Outputs: index 0 u8, 1 u0, 2 us. */
	wire rdy8, rdy0, rdys, rdy4, rdys4;
	wire sv8, sv0, svs, sv4, svs4;
	wire [1:0] sw8, sw0, sws, sw4, sws4;
	wire [1:0] sg8, sg0, sgs;
	wire [2:0] sg4, sgs4;
	wire [6:0] sr8, sr0, srs, sr4, srs4;
	wire [N*32-1:0] sd8, sd0, sds;
	wire [127:0] sd4, sds4;
	wire [N-1:0] sl8, sl0, sls;
	wire [3:0] sl4, sls4;

`define PK_PORTS(RDY, SV, SW, SG, SR, SD, SL) \
		.clk(clk), .rst_n(rst_n), .x_valid(x_valid), .x_warp(x_warp), .x_last(x_last), \
		.x_sbe(x_sbe), .x_pc(x_pc), .x_uop(x_uop), .x_info(x_info), .x_ready(RDY), \
		.s_valid(SV), .s_warp(SW), .s_grp(SG), .s_rd(SR), .s_data(SD), .s_lanes(SL)

	ad_su_pk #(.NPHYS(8), .GRP_W(2), .PACKED(1), .SHORT_LAT(L)) u8 (`PK_PORTS(rdy8, sv8, sw8, sg8, sr8, sd8, sl8),
		.x_grp(x_grp), .x_a(x_a), .x_b(x_b), .x_c(x_c), .x_mask(x_mask));
	ad_su_pk #(.NPHYS(8), .GRP_W(2), .PACKED(0), .SHORT_LAT(L)) u0 (`PK_PORTS(rdy0, sv0, sw0, sg0, sr0, sd0, sl0),
		.x_grp(x_grp), .x_a(x_a), .x_b(x_b), .x_c(x_c), .x_mask(x_mask));
	ad_su_pk #(.NPHYS(8), .GRP_W(2), .PACKED(1), .PK_SHARED(1), .SHORT_LAT(L)) us (`PK_PORTS(rdys, svs, sws, sgs, srs, sds, sls),
		.x_grp(x_grp), .x_a(x_a), .x_b(x_b), .x_c(x_c), .x_mask(x_mask));
	ad_su_pk #(.NPHYS(4), .GRP_W(3), .PACKED(1), .SHORT_LAT(L)) u4 (`PK_PORTS(rdy4, sv4, sw4, sg4, sr4, sd4, sl4),
		.x_grp({1'b0, x_grp}), .x_a(x_a[127:0]), .x_b(x_b[127:0]), .x_c(x_c[127:0]),
		.x_mask({x_mask[11:8], x_mask[3:0]}));
	ad_su_pk #(.NPHYS(4), .GRP_W(3), .PACKED(1), .PK_SHARED(1), .SHORT_LAT(L)) us4 (`PK_PORTS(rdys4, svs4, sws4, sgs4, srs4, sds4, sls4),
		.x_grp({1'b0, x_grp}), .x_a(x_a[127:0]), .x_b(x_b[127:0]), .x_c(x_c[127:0]),
		.x_mask({x_mask[11:8], x_mask[3:0]}));

	/* The TB's pipeline: per unit (0 u8, 1 u0, 2 us) valid, tag, data, kind. */
	reg ev [0:2][0:L-1];
	reg [18:0] et [0:2][0:L-1];		/* {warp, grp, rd, lanes} */
	reg [N*32-1:0] ed [0:2][0:L-1];
	reg ek [0:2][0:L-1];			/* 1: a pack group */
	reg nv [0:2];
	reg [N*32-1:0] nd [0:2];
	reg nk;
	reg exp_blk;				/* us's expected x_ready = !exp_blk */

	integer gi, i, j, u, cyc, seed;
	integer err_pack, err_arith, err_n4, err_rdy, npack, narith, nres;
	reg pkgrp;
	reg [3:0] op;
	reg fop;
	reg [18:0] stag;
	reg [N*32-1:0] y;

	/* Builds the next cycle's inputs in t_* and assigns each x_* once. */
	reg t_valid;
	reg [107:0] t_uop;
	reg [N*32-1:0] t_a, t_b, t_c;
	task drive;
		begin
			t_valid = 0;
			t_uop = {$random(seed), $random(seed), $random(seed), $random(seed)};
			t_a = {8{$random(seed)}};
			t_b = {8{$random(seed)}};
			t_c = {8{$random(seed)}};
			pkgrp = 0;
			if (($random(seed) & 3) != 0) begin
				t_valid = 1;
				if (gi < NG && ($random(seed) & 7) != 0) begin
					pkgrp = 1;
					t_uop[AD_UOP_UNIT +: 4] = AD_UNIT_PK;
					t_uop[AD_UOP_OP +: 8] = vl[gi*8][147:144];
					t_uop[AD_UOP_RM +: 3] = vl[gi*8][142:140];
					t_uop[AD_UOP_HSEL +: 2] = vl[gi*8][137:136];
					t_uop[AD_UOP_SUB +: 5] = vl[gi*8][132];
					t_uop[AD_UOP_MOD + 6] = vl[gi*8][128];
					t_uop[AD_UOP_WRD] = (($random(seed) & 15) != 0);
					for (i = 0; i < N; i = i + 1) begin
						t_a[i*32 +: 32] = vl[gi*8+i][127:96];
						t_b[i*32 +: 32] = vl[gi*8+i][95:64];
						t_c[i*32 +: 32] = vl[gi*8+i][63:32];
						y[i*32 +: 32] = vl[gi*8+i][31:0];
					end
					gi = gi + 1;
				end else if (t_uop[AD_UOP_UNIT +: 4] == AD_UNIT_PK)
					t_uop[AD_UOP_UNIT +: 4] = AD_UNIT_FPU;
			end
			x_valid = t_valid;
			x_warp = $random(seed);
			x_grp = $random(seed);
			x_last = $random(seed);
			x_sbe = $random(seed);
			x_pc = $random(seed);
			x_info = $random(seed);
			x_mask = {$random(seed)} ^ ({$random(seed)} << 1);
			x_uop = t_uop;
			x_a = t_a;
			x_b = t_b;
			x_c = t_c;
		end
	endtask

	/* Expected results of this cycle's group (before the posedge). */
	task expect_now;
		begin
			op = x_uop[AD_UOP_OP +: 4];
			fop = (op <= 5) || (op >= 9 && op <= 12);
			nk = (op >= 13);
			nv[0] = pkgrp && x_uop[AD_UOP_WRD];
			nd[0] = y;
			nv[1] = nv[0];
			nd[1] = nk ? y : {N*32{1'b0}};
			nv[2] = nv[0] && !exp_blk && !fop;
			nd[2] = y;
		end
	endtask

	task check_unit(input integer uu, input sv, input [1:0] sw, input [1:0] sg, input [6:0] sr,
			input [N*32-1:0] sd, input [N-1:0] sl);
		reg bad;
		begin
			bad = (sv !== ev[uu][L-1]);
			if (ev[uu][L-1] && (sd !== ed[uu][L-1] || {sw, sg, sr, sl} !== et[uu][L-1]))
				bad = 1;
			if (ev[uu][L-1])
				nres = nres + 1;
			if (bad) begin
				if (ek[uu][L-1])
					err_pack = err_pack + 1;
				else
					err_arith = err_arith + 1;
				if (err_pack + err_arith < 10)
					$display("FAIL ad_su_pk unit %0d cycle %0d: s_valid %b exp %b data %h exp %h tag %h exp %h",
						uu, cyc, sv, ev[uu][L-1], sd, ed[uu][L-1], {sw, sg, sr, sl}, et[uu][L-1]);
			end
		end
	endtask

	always @(posedge clk) begin
		for (u = 0; u < 3; u = u + 1) begin
			for (j = L - 1; j > 0; j = j - 1) begin
				ev[u][j] <= ev[u][j-1];
				et[u][j] <= et[u][j-1];
				ed[u][j] <= ed[u][j-1];
				ek[u][j] <= ek[u][j-1];
			end
			ev[u][0] <= rst_n && nv[u];
			et[u][0] <= stag;
			ed[u][0] <= nd[u];
			ek[u][0] <= nk;
		end
		exp_blk <= rst_n && pkgrp && !exp_blk && fop;
	end

	initial begin
		$readmemh("sim/vec/pk_lane.hex", vl);
		seed = 7;
		NG = NV / 8;
		if ($value$plusargs("ng=%d", NG)) $display("ad_su_pk_tb: %0d groups", NG);
		gi = 0;
		err_pack = 0; err_arith = 0; err_n4 = 0; err_rdy = 0; nres = 0;
		npack = 0; narith = 0;
		exp_blk = 0;
		for (u = 0; u < 3; u = u + 1)
			for (j = 0; j < L; j = j + 1)
				ev[u][j] = 0;
		drive;
		x_valid = 0;
		pkgrp = 0;
		expect_now;
		stag = 0;
		repeat (3) @(negedge clk);
		rst_n = 1;
		cyc = 0;
		while (gi < NG || cyc < 20) begin
			@(negedge clk);
			cyc = cyc + 1;
			/* Check the outputs of this cycle. */
			check_unit(0, sv8, sw8, sg8, sr8, sd8, sl8);
			check_unit(1, sv0, sw0, sg0, sr0, sd0, sl0);
			check_unit(2, svs, sws, sgs, srs, sds, sls);
			if (rdy8 !== 1'b1 || rdy0 !== 1'b1 || rdys !== !exp_blk) begin
				err_rdy = err_rdy + 1;
				if (err_rdy < 5)
					$display("FAIL ad_su_pk x_ready cycle %0d: %b %b %b (us exp %b)", cyc, rdy8, rdy0, rdys, !exp_blk);
			end
			if (cyc > L + 1 && ({rdy4, sv4, sw4, sg4, sr4, sd4, sl4} !== {rdy8, sv8, sw8, 1'b0, sg8, sr8, sd8[127:0], sl8[3:0]} ||
			    {rdys4, svs4, sws4, sgs4, srs4, sds4, sls4} !== {rdys, svs, sws, 1'b0, sgs, srs, sds[127:0], sls[3:0]})) begin
				err_n4 = err_n4 + 1;
				if (err_n4 < 5)
					$display("FAIL ad_su_pk.nphys4 cycle %0d", cyc);
			end
			/* Next group. */
			drive;
			expect_now;
			stag = {x_warp, x_grp, x_uop[AD_UOP_RD +: 7], x_mask[N-1:0]};
			if (pkgrp && nk)
				npack = npack + 1;
			else if (pkgrp)
				narith = narith + 1;
		end
		if (err_pack == 0 && npack > 100)
			$display("PASS ad_su_pk.pack");
		else
			$display("FAIL ad_su_pk.pack (%0d errors, %0d groups)", err_pack, npack);
		if (err_arith == 0 && err_rdy == 0 && narith > 1000)
			$display("PASS ad_su_pk.arith");
		else
			$display("FAIL ad_su_pk.arith (%0d errors, %0d x_ready errors, %0d groups)", err_arith, err_rdy, narith);
		$display("SKIP ad_su_pk.shared: needs ad_su_fpu (PK_SHARED pair), left to integration; this unit's side is checked in .arith");
		if (err_n4 == 0)
			$display("PASS ad_su_pk.nphys4");
		else
			$display("FAIL ad_su_pk.nphys4 (%0d cycles differ)", err_n4);
		$display("ad_su_pk_tb: %0d cycles, %0d pack + %0d arith groups (%0d lane vectors), %0d results checked",
			cyc, npack, narith, gi * 8, nres);
		if (err_pack + err_arith + err_rdy + err_n4 == 0)
			$display("PASS ad_su_pk");
		$finish;
	end
endmodule
