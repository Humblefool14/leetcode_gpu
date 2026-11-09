/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * ad_su_fpu_tb: ad_su_fpu of NPHYS 8 against the lane groups of
 * sim/vec/fpu_grp.hex (tools/gen_fpu_vectors.py: directed corners for every
 * op x rm 0-7 x sat, then random groups gsi1fp.fpu_vec style, every
 * expected value from tools/gsi1fp.py fpu()), interleaved with idle cycles,
 * groups of other units and uops without WRD.  Checks s_* exactly
 * SHORT_LAT cycles after the take (valid, warp, grp, rd, data of every
 * lane, EXEC lanes), fw4_* / fw5_* (= s_* 2 / 1 cycles later, valid only
 * for rd < 63), x_ready, and a unit of NPHYS 4 fed the low 4 lanes equal
 * to the NPHYS 8 unit's low 4 lanes every cycle.
 */

`timescale 1ns/1ps

module ad_su_fpu_tb;

`include "ad_su_uop.vh"

	localparam NV = 80000;
	localparam SL = 6;
	localparam UW = 108;

	reg clk = 0, rst_n = 0;
	always #5 clk = ~clk;

	reg [143:0] vg [0:NV-1];

	/* Bus. */
	reg          x_valid;
	reg [1:0]    x_warp;
	reg [2:0]    x_grp;
	reg [UW-1:0] x_uop;
	reg [255:0]  x_a, x_b, x_c;
	reg [15:0]   x_mask;

	wire         r8, s8v, f48v, f58v;
	wire [1:0]   s8w, f48w, f58w;
	wire [1:0]   s8g, f48g, f58g;
	wire [6:0]   s8r, f48r, f58r;
	wire [255:0] s8d, f48d, f58d;
	wire [7:0]   s8l, f48l, f58l;
	ad_su_fpu #(.NPHYS(8), .GRP_W(2), .UOP_W(UW), .SHORT_LAT(SL)) u8 (
		.clk(clk), .rst_n(rst_n), .x_valid(x_valid), .x_warp(x_warp), .x_grp(x_grp[1:0]),
		.x_last(1'b1), .x_sbe(3'd7), .x_pc(16'd0), .x_uop(x_uop), .x_a(x_a), .x_b(x_b),
		.x_c(x_c), .x_mask(x_mask), .x_info(32'd0), .x_ready(r8),
		.s_valid(s8v), .s_warp(s8w), .s_grp(s8g), .s_rd(s8r), .s_data(s8d), .s_lanes(s8l),
		.fw4_valid(f48v), .fw4_warp(f48w), .fw4_grp(f48g), .fw4_rd(f48r), .fw4_data(f48d),
		.fw4_lanes(f48l), .fw5_valid(f58v), .fw5_warp(f58w), .fw5_grp(f58g), .fw5_rd(f58r),
		.fw5_data(f58d), .fw5_lanes(f58l));

	wire         r4, s4v, f44v, f54v;
	wire [1:0]   s4w, f44w, f54w;
	wire [2:0]   s4g, f44g, f54g;
	wire [6:0]   s4r, f44r, f54r;
	wire [127:0] s4d, f44d, f54d;
	wire [3:0]   s4l, f44l, f54l;
	ad_su_fpu #(.NPHYS(4), .GRP_W(3), .UOP_W(UW), .SHORT_LAT(SL)) u4 (
		.clk(clk), .rst_n(rst_n), .x_valid(x_valid), .x_warp(x_warp), .x_grp(x_grp),
		.x_last(1'b0), .x_sbe(3'd1), .x_pc(16'hFFFF), .x_uop(x_uop), .x_a(x_a[127:0]),
		.x_b(x_b[127:0]), .x_c(x_c[127:0]), .x_mask({x_mask[11:8], x_mask[3:0]}),
		.x_info(32'hFFFFFFFF), .x_ready(r4),
		.s_valid(s4v), .s_warp(s4w), .s_grp(s4g), .s_rd(s4r), .s_data(s4d), .s_lanes(s4l),
		.fw4_valid(f44v), .fw4_warp(f44w), .fw4_grp(f44g), .fw4_rd(f44r), .fw4_data(f44d),
		.fw4_lanes(f44l), .fw5_valid(f54v), .fw5_warp(f54w), .fw5_grp(f54g), .fw5_rd(f54r),
		.fw5_data(f54d), .fw5_lanes(f54l));

	/* Expected results by the cycle of the take (mod 16). */
	reg         e_v [0:15];
	reg [1:0]   e_w [0:15];
	reg [2:0]   e_g [0:15];
	reg [6:0]   e_r [0:15];
	reg [255:0] e_d [0:15];
	reg [7:0]   e_l [0:15];
	reg [1:0]   e_cat [0:15];
	reg [143:0] e_vec [0:15];	/* lane 0 vector, for messages */

	integer cyc, ng, gi, i, k, nvec, ntake, nsv;
	integer err_cat [0:3];
	integer n_cat [0:3];
	integer err_t, err_4;

	function [1:0] cat(input [7:0] op);
		cat = (op >= AD_FPU_MUL) ? 2'd3 :
			(op >= AD_FPU_FEQ && op <= AD_FPU_FNE) ? 2'd2 :
			((op >= AD_FPU_FCVTWS && op <= AD_FPU_FCVTSWU) || op == AD_FPU_FROUND ||
			 op == AD_FPU_FRACT) ? 2'd1 : 2'd0;
	endfunction

	/* Check one cycle's outputs (before the inputs of the cycle change). */
	task check;
		integer p4, p5, p6;
		reg [255:0] dd;
		begin
			p6 = (cyc - SL) & 15;
			p5 = (cyc - SL + 1) & 15;
			p4 = (cyc - SL + 2) & 15;
			if (r8 !== 1'b1 || r4 !== 1'b1) begin
				err_t = err_t + 1;
				$display("FAIL cycle %0d: x_ready %b %b", cyc, r8, r4);
			end
			if (cyc >= SL) begin
				if (s8v !== e_v[p6]) begin
					err_t = err_t + 1;
					if (err_t < 10) $display("cycle %0d: s_valid %b expected %b", cyc, s8v, e_v[p6]);
				end else if (s8v) begin
					nsv = nsv + 1;
					if (s8w !== e_w[p6] || s8g !== e_g[p6][1:0] || s8r !== e_r[p6] ||
					    s8l !== e_l[p6]) begin
						err_t = err_t + 1;
						if (err_t < 10) $display("cycle %0d: s_warp/grp/rd/lanes %h %h %h %h expected %h %h %h %h",
							cyc, s8w, s8g, s8r, s8l, e_w[p6], e_g[p6], e_r[p6], e_l[p6]);
					end
					dd = e_d[p6];
					n_cat[e_cat[p6]] = n_cat[e_cat[p6]] + 1;
					if (s8d !== dd) begin
						err_cat[e_cat[p6]] = err_cat[e_cat[p6]] + 1;
						if (err_cat[e_cat[p6]] < 6)
							for (k = 0; k < 8; k = k + 1)
								if (s8d[k*32 +: 32] !== dd[k*32 +: 32])
									$display("cycle %0d lane %0d: op %0d rm %0d sat %0d a %h b %h c %h: got %h expected %h",
										cyc, k, e_vec[p6][143:136], e_vec[p6][135:132], e_vec[p6][128],
										x_a_hist[p6][k*32 +: 32], x_b_hist[p6][k*32 +: 32],
										x_c_hist[p6][k*32 +: 32], s8d[k*32 +: 32], dd[k*32 +: 32]);
					end
				end
				/* fw4: the take of 4 cycles ago; fw5: 5 cycles ago. */
				if (f48v !== (e_v[p4] && e_r[p4] < 7'd63) ||
				    (f48v && (f48w !== e_w[p4] || f48g !== e_g[p4][1:0] || f48r !== e_r[p4] ||
				              f48d !== e_d[p4] || f48l !== e_l[p4])) ||
				    f58v !== (e_v[p5] && e_r[p5] < 7'd63) ||
				    (f58v && (f58w !== e_w[p5] || f58g !== e_g[p5][1:0] || f58r !== e_r[p5] ||
				              f58d !== e_d[p5] || f58l !== e_l[p5]))) begin
					err_t = err_t + 1;
					if (err_t < 10) $display("cycle %0d: fw4/fw5 mismatch", cyc);
				end
			end
			/* NPHYS 4 = low 4 lanes of NPHYS 8, every cycle. */
			if (s4v !== s8v || (s8v && (s4w !== s8w || s4r !== s8r || s4d !== s8d[127:0] ||
			    s4l !== s8l[3:0] || s4g !== e_g[p6])) ||
			    f44v !== f48v || (f48v && (f44d !== f48d[127:0] || f44l !== f48l[3:0] ||
			    f44r !== f48r || f44w !== f48w || f44g !== e_g[p4])) ||
			    f54v !== f58v || (f58v && (f54d !== f58d[127:0] || f54l !== f58l[3:0] ||
			    f54r !== f58r || f54w !== f58w || f54g !== e_g[p5]))) begin
				err_4 = err_4 + 1;
				if (err_4 < 10) $display("cycle %0d: NPHYS 4 differs from NPHYS 8", cyc);
			end
		end
	endtask

	reg [255:0] x_a_hist [0:15];
	reg [255:0] x_b_hist [0:15];
	reg [255:0] x_c_hist [0:15];

	task pass_line(input [8*5-1:0] name, input integer e, input integer cnt);
		begin
			if (e == 0 && err_t == 0 && err_4 == 0 && cnt > 0)
				$display("PASS ad_su_fpu.%0s (%0d groups)", name, cnt);
			else
				$display("FAIL ad_su_fpu.%0s (%0d of %0d groups wrong)", name, e, cnt);
		end
	endtask

	reg [31:0] rnd;
	reg [7:0]  op;
	reg        wrd;
	reg [6:0]  rd;

	initial begin
		for (i = 0; i < NV; i = i + 1)
			vg[i] = {144{1'bx}};
		$readmemh("sim/vec/fpu_grp.hex", vg);
		nvec = 0;
		while (nvec < NV && !$isunknown(vg[nvec]))
			nvec = nvec + 1;
		ng = nvec / 8;
		for (i = 0; i < 4; i = i + 1) begin
			err_cat[i] = 0;
			n_cat[i] = 0;
		end
		for (i = 0; i < 16; i = i + 1)
			e_v[i] = 1'b0;
		err_t = 0; err_4 = 0; ntake = 0; nsv = 0;
		x_valid = 0; x_uop = 0; x_warp = 0; x_grp = 0; x_a = 0; x_b = 0; x_c = 0; x_mask = 0;
		cyc = 0;
		repeat (3) @(posedge clk);
		#1 rst_n = 1;
		gi = 0;
		done = 0;
		while (!done) begin
			@(negedge clk);
			check;
			e_v[cyc & 15] = 1'b0;
			if (gi >= ng) begin
				x_valid = 0;		/* drain */
				if (cyc >= drain_end)
					done = 1;
			end else begin
				rnd = $random;
				x_uop = {$random, $random, $random, $random};
				x_warp = $random;
				x_grp = $random;
				x_mask = (rnd[11:9] == 0) ? 16'h0000 : (rnd[11:9] == 1) ? 16'hFFFF : $random;
				x_a = {8{$random}}; x_b = {8{$random}}; x_c = {8{$random}};
				wrd = rnd[7:4] != 0;
				rd = rnd[15:12] == 0 ? 7'd63 : {1'b0, $random} % 63;
				x_uop[AD_UOP_RD +: 7] = rd;
				x_uop[AD_UOP_WRD] = wrd;
				if (rnd[3:0] < 2) begin
					x_valid = 0;		/* idle (random junk on the bus) */
				end else if (rnd[3:0] < 4) begin
					x_valid = 1;		/* another unit's group */
					if (x_uop[AD_UOP_UNIT +: 4] == AD_UNIT_FPU)
						x_uop[AD_UOP_UNIT +: 4] = AD_UNIT_ALU;
				end else begin
					x_valid = 1;
					op = vg[gi*8][143:136];
					x_uop[AD_UOP_UNIT +: 4] = AD_UNIT_FPU;
					x_uop[AD_UOP_OP +: 8] = op;
					x_uop[AD_UOP_RM +: 3] = vg[gi*8][134:132];
					x_uop[AD_UOP_MOD + 6] = vg[gi*8][128];
					for (k = 0; k < 8; k = k + 1) begin
						x_a[k*32 +: 32] = vg[gi*8+k][127:96];
						x_b[k*32 +: 32] = vg[gi*8+k][95:64];
						x_c[k*32 +: 32] = vg[gi*8+k][63:32];
						e_d[cyc & 15][k*32 +: 32] = vg[gi*8+k][31:0];
					end
					e_v[cyc & 15] = wrd;
					e_w[cyc & 15] = x_warp;
					e_g[cyc & 15] = x_grp;
					e_r[cyc & 15] = rd;
					e_l[cyc & 15] = x_mask[7:0];
					e_cat[cyc & 15] = cat(op);
					e_vec[cyc & 15] = vg[gi*8];
					x_a_hist[cyc & 15] = x_a; x_b_hist[cyc & 15] = x_b; x_c_hist[cyc & 15] = x_c;
					ntake = ntake + 1;
					/* A group without WRD is not checked: send it again. */
					if (wrd)
						gi = gi + 1;
					if (gi >= ng)
						drain_end = cyc + SL + 2;
				end
			end
			@(posedge clk);
			#1 cyc = cyc + 1;
		end
		$display("ad_su_fpu_tb: %0d lane vectors, %0d groups taken, %0d results checked", nvec, ntake, nsv);
		pass_line("arith", err_cat[0], n_cat[0]);
		pass_line("cvt", err_cat[1], n_cat[1]);
		pass_line("cmp", err_cat[2], n_cat[2]);
		pass_line("mul", err_cat[3], n_cat[3]);
		if (err_t != 0)
			$display("FAIL ad_su_fpu.timing (%0d errors)", err_t);
		if (err_4 != 0)
			$display("FAIL ad_su_fpu.nphys4 (%0d errors)", err_4);
		if (err_t == 0 && err_4 == 0 && err_cat[0] == 0 && err_cat[1] == 0 &&
		    err_cat[2] == 0 && err_cat[3] == 0 && nsv > 0)
			$display("PASS ad_su_fpu");
		else
			$display("FAIL ad_su_fpu");
		$finish;
	end

	integer drain_end = 0;
	reg done;

endmodule
