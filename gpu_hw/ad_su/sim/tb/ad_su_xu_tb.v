/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * ad_su_xu_tb: ad_su_xu against tools/gsi1fp.py xu() (vectors of
 * tools/gen_xu_vectors.py in sim/vec/xu_funcs.hex: gsi1fp.py's xu_vec plus
 * targeted blocks, one op per 8 lines).
 *  - funcs: NPHYS 8, EXEC full: every vector bit for bit, and the results
 *    against $sqrt/$pow/$ln/$sin/$cos: rcp, fsqrt <= 0.5 ulp, rsq, exp2
 *    <= 1 ulp, log2 <= 2^-22 + 1 ulp, sin/cos <= 2^-22 absolute for
 *    |x| <= 16 (normal operands and results only).
 *  - beats: NPHYS 8 and NPHYS 4 with EXEC full/empty/one/all-but-one/random
 *    (X on the operands outside EXEC), idle cycles and other units' groups,
 *    random l_ready: one beat per group in order, l_lanes = EXEC, l_last =
 *    x_last, l_warp/grp/rd/wr/sbe/cls, the payload held while l_ready is 0,
 *    no group taken while a beat is pending, the EXEC lanes' data.
 *
 *   PASS ad_su_xu.funcs
 *   PASS ad_su_xu.beats
 *   PASS ad_su_xu
 */
`timescale 1ns/1ps

module ad_su_xu_tbh #(
	parameter NPHYS = 8,
	parameter GRP_W = 2,
	parameter SEED = 1,
	parameter FUNCS = 0
) (
	input wire clk,
	input wire rst_n,
	output reg done,
	output reg [31:0] nerr,
	output reg [31:0] nchk
);
`include "ad_su_uop.vh"
	localparam G = 32 / NPHYS;
	localparam NV = 4448;
	localparam NI = NV / 32;
	localparam MAXB = NI * G;

	reg [67:0] vec [0:NV-1];

	reg x_valid;
	reg [1:0] x_warp;
	reg [GRP_W-1:0] x_grp;
	reg x_last;
	reg [2:0] x_sbe;
	reg [107:0] x_uop;
	reg [NPHYS*32-1:0] x_a, x_b;
	reg [2*NPHYS-1:0] x_mask;
	wire x_ready;
	reg l_ready;
	wire l_valid;
	wire [1:0] l_warp;
	wire [GRP_W-1:0] l_grp;
	wire [6:0] l_rd;
	wire [NPHYS*32-1:0] l_data;
	wire [NPHYS-1:0] l_lanes;
	wire l_wr, l_last;
	wire [2:0] l_sbe, l_cls;

	ad_su_xu #(.NPHYS(NPHYS), .GRP_W(GRP_W)) dut (
		.clk(clk), .rst_n(rst_n), .x_valid(x_valid), .x_warp(x_warp), .x_grp(x_grp),
		.x_last(x_last), .x_sbe(x_sbe), .x_pc(16'd0), .x_uop(x_uop), .x_a(x_a), .x_b(x_b),
		.x_c({NPHYS*32{1'b0}}), .x_mask(x_mask), .x_info(32'd0), .x_ready(x_ready),
		.l_valid(l_valid), .l_ready(l_ready), .l_warp(l_warp), .l_grp(l_grp), .l_rd(l_rd),
		.l_data(l_data), .l_lanes(l_lanes), .l_wr(l_wr), .l_last(l_last), .l_sbe(l_sbe),
		.l_cls(l_cls)
	);

	/* expected beats */
	reg [NPHYS*32-1:0] e_data [0:MAXB-1];
	reg [NPHYS-1:0] e_lanes [0:MAXB-1];
	reg [1:0] e_warp [0:MAXB-1];
	reg [GRP_W-1:0] e_grp [0:MAXB-1];
	reg [6:0] e_rd [0:MAXB-1];
	reg e_wr [0:MAXB-1];
	reg e_last [0:MAXB-1];
	reg [2:0] e_sbe [0:MAXB-1];
	reg [31:0] e_cyc [0:MAXB-1];	/* EXEC lanes */
	reg [NPHYS*32-1:0] e_x [0:MAXB-1];
	reg [3:0] e_op [0:MAXB-1];
	integer nexp, nrcv, ntake;
	integer rs;
	integer cyc;
	integer take_cyc [0:MAXB-1];

	task fail_msg(input [8*48-1:0] what, input integer b);
		begin
			if (nerr < 20)
				$display("FAIL ad_su_xu.%0s NPHYS %0d beat %0d: %0s", FUNCS ? "funcs" : "beats", NPHYS, b, what);
			nerr = nerr + 1;
		end
	endtask

	/* error bounds against the real functions */
	integer nbound;
	real bw [0:6];
	function real f2r(input [31:0] b);
		begin
			if (b[30:23] == 8'd0)
				f2r = 0.0;
			else
				f2r = (b[31] ? -1.0 : 1.0) * (1.0 + b[22:0] / 8388608.0) *
				    (2.0 ** ($itor(b[30:23]) - 127.0));
		end
	endfunction
	task bound(input [3:0] o, input [31:0] x, input [31:0] y);
		real xv, yv, ulp, rf, er, lim;
		begin
			xv = f2r(x);
			yv = f2r(y);
			ulp = 2.0 ** ($itor(y[30:23]) - 150.0);
			lim = -1.0;
			if (x[30:23] != 8'd0 && x[30:23] != 8'hFF && y[30:23] != 8'd0 && y[30:23] != 8'hFF) begin
				case (o)
				0: begin rf = 1.0 / xv; lim = 0.5 * ulp; end
				1: begin rf = 1.0 / $sqrt(xv); lim = 1.0 * ulp; end
				2: begin rf = $pow(2.0, xv); lim = (rf >= 2.0 ** -125) ? 1.0 * ulp : -1.0; end
				3: begin rf = $ln(xv) / $ln(2.0); lim = 2.0 ** -22 + ulp; end
				4: begin rf = $sin(xv); lim = (xv <= 16.0 && xv >= -16.0) ? 2.0 ** -22 : -1.0; end
				5: begin rf = $cos(xv); lim = (xv <= 16.0 && xv >= -16.0) ? 2.0 ** -22 : -1.0; end
				6: begin rf = $sqrt(xv); lim = 0.5 * ulp; end
				default: lim = -1.0;
				endcase
				if (lim > 0.0) begin
					er = (yv > rf) ? yv - rf : rf - yv;
					nbound = nbound + 1;
					if (er / lim > bw[o])
						bw[o] = er / lim;
					if (er > lim * 1.000001) begin
						if (nerr < 20)
							$display("FAIL ad_su_xu.funcs op %0d x %08x y %08x: error %g > bound %g",
							    o, x, y, er, lim);
						nerr = nerr + 1;
					end
				end
			end
		end
	endtask

	integer it, g, ln, k, n1, idle;
	reg [31:0] ex;
	reg [3:0] op;
	reg [67:0] v;
	reg [6:0] rd;
	reg wrd;
	reg [1:0] warp;
	reg [2:0] sbe;

	initial begin
		$readmemh("sim/vec/xu_funcs.hex", vec);
		rs = SEED;
		done = 0; nerr = 0; nchk = 0; nbound = 0;
		for (k = 0; k < 7; k = k + 1)
			bw[k] = 0.0;
		nexp = 0; nrcv = 0; ntake = 0;
		x_valid = 0; x_warp = 0; x_grp = 0; x_last = 0; x_sbe = 0; x_uop = 0;
		x_a = 0; x_b = 0; x_mask = 0;
		@(posedge rst_n);
		for (it = 0; it < NI; it = it + 1) begin
			/* EXEC of the instruction */
			k = FUNCS ? 7 : $urandom(rs) % 8;
			case (k)
			0: ex = 32'h0;
			1: ex = 32'h1 << ($urandom(rs) % 32);
			2: ex = ~(32'h1 << ($urandom(rs) % 32));
			3, 4: ex = $urandom(rs);
			default: ex = 32'hFFFFFFFF;
			endcase
			rd = $urandom(rs) % 64;
			wrd = ($urandom(rs) % 8) != 0;
			warp = $urandom(rs);
			sbe = $urandom(rs) % 8;
			for (g = 0; g < G; g = g + 1) begin
				@(negedge clk);
				/* idle cycles or other units' groups first */
				idle = FUNCS ? 0 : $urandom(rs) % 4;
				v = vec[it * 32 + g * NPHYS];
				op = v[67:64];
				while (idle > 0) begin
					x_valid = $urandom(rs) % 2;
					x_uop = {$urandom(rs), $urandom(rs), $urandom(rs), $urandom(rs)};
					if (x_uop[3:0] == AD_UNIT_XU)
						x_uop[3:0] = AD_UNIT_ALU;
					x_mask = {2 * NPHYS{1'b1}};
					@(negedge clk);
					idle = idle - 1;
				end
				x_uop = 108'd0;
				x_uop[AD_UOP_UNIT +: 4] = AD_UNIT_XU;
				x_uop[AD_UOP_OP +: 8] = {4'd0, op};
				x_uop[AD_UOP_RD +: 7] = rd;
				x_uop[AD_UOP_WRD] = wrd;
				x_uop[AD_UOP_CLS +: 3] = AD_CLS_X;
				x_warp = warp;
				x_grp = g;
				x_last = (g == G - 1);
				x_sbe = sbe;
				n1 = 0;
				for (ln = 0; ln < NPHYS; ln = ln + 1) begin
					v = vec[it * 32 + g * NPHYS + ln];
					x_mask[ln] = ex[g * NPHYS + ln];
					x_mask[NPHYS + ln] = ex[g * NPHYS + ln] & $urandom(rs);
					if (x_mask[ln]) begin
						x_a[ln * 32 +: 32] = v[63:32];
						x_b[ln * 32 +: 32] = $urandom(rs);
						e_data[nexp][ln * 32 +: 32] = v[31:0];
						e_x[nexp][ln * 32 +: 32] = v[63:32];
						e_op[nexp] = op;
						n1 = n1 + 1;
					end else begin
						x_a[ln * 32 +: 32] = 32'hxxxxxxxx;
						x_b[ln * 32 +: 32] = 32'hxxxxxxxx;
						e_data[nexp][ln * 32 +: 32] = 32'h0;
					end
				end
				e_lanes[nexp] = x_mask[NPHYS-1:0];
				e_warp[nexp] = warp;
				e_grp[nexp] = g;
				e_rd[nexp] = rd;
				e_wr[nexp] = wrd;
				e_last[nexp] = (g == G - 1);
				e_sbe[nexp] = sbe;
				e_cyc[nexp] = n1;
				nexp = nexp + 1;
				x_valid = 1;
				@(posedge clk);
				while (!x_ready) @(posedge clk);
				/* taken at this edge */
				@(negedge clk);
				x_valid = 0;
				x_a = {NPHYS{32'hxxxxxxxx}};
				x_b = {NPHYS{32'hxxxxxxxx}};
			end
		end
		@(negedge clk);
		x_valid = 0;
		k = 0;
		while (nrcv < nexp && k < 100000) begin
			@(posedge clk);
			k = k + 1;
		end
		if (nrcv != nexp)
			fail_msg("beats missing", nrcv);
		if (FUNCS)
			$display("ad_su_xu_tb: %0d results within the bounds; worst error / bound: rcp %0.3f rsq %0.3f exp2 %0.3f log2 %0.3f sin %0.3f cos %0.3f fsqrt %0.3f",
			    nbound, bw[0], bw[1], bw[2], bw[3], bw[4], bw[5], bw[6]);
		done = 1;
	end

	/* monitor */
	reg p_valid, p_ready;
	reg [NPHYS*32-1:0] p_data;
	reg [NPHYS-1:0] p_lanes;
	reg [6:0] p_rd;
	reg p_last;
	integer ln2;
	always @(posedge clk) begin
		if (!rst_n) begin
			cyc <= 0;
			p_valid <= 0;
			p_ready <= 0;
			l_ready <= 1;
		end else begin
			cyc <= cyc + 1;
			l_ready <= FUNCS ? 1'b1 : (($urandom(rs) % 4) != 0);
			p_valid <= l_valid;
			p_ready <= l_ready;
			p_data <= l_data;
			p_lanes <= l_lanes;
			p_rd <= l_rd;
			p_last <= l_last;
			if (p_valid && !p_ready && (!l_valid || l_data !== p_data ||
			    l_lanes !== p_lanes || l_rd !== p_rd || l_last !== p_last))
				fail_msg("beat changed while l_ready 0", nrcv);
			if (x_valid && x_ready && x_uop[3:0] == AD_UNIT_XU) begin
				take_cyc[ntake] = cyc;
				ntake = ntake + 1;
				if (ntake - nrcv > 1)
					fail_msg("took a group with a beat pending", nrcv);
			end
			if (l_valid && l_ready) begin
				if (nrcv >= nexp) begin
					fail_msg("unexpected beat", nrcv);
				end else begin
					nchk = nchk + 1;
					if (l_lanes !== e_lanes[nrcv]) fail_msg("l_lanes", nrcv);
					if (l_warp !== e_warp[nrcv]) fail_msg("l_warp", nrcv);
					if (l_grp !== e_grp[nrcv]) fail_msg("l_grp", nrcv);
					if (l_rd !== e_rd[nrcv]) fail_msg("l_rd", nrcv);
					if (l_wr !== e_wr[nrcv]) fail_msg("l_wr", nrcv);
					if (l_last !== e_last[nrcv]) fail_msg("l_last", nrcv);
					if (l_sbe !== e_sbe[nrcv]) fail_msg("l_sbe", nrcv);
					if (l_cls !== AD_CLS_X) fail_msg("l_cls", nrcv);
					if (cyc - take_cyc[nrcv] < e_cyc[nrcv] + 1 ||
					    cyc - take_cyc[nrcv] > 70 * e_cyc[nrcv] + 40)
						fail_msg("group time out of 1..70 cycles per EXEC lane", nrcv);
					for (ln2 = 0; ln2 < NPHYS; ln2 = ln2 + 1)
						if (e_lanes[nrcv][ln2] &&
						    l_data[ln2 * 32 +: 32] !== e_data[nrcv][ln2 * 32 +: 32]) begin
							if (nerr < 20)
								$display("FAIL ad_su_xu NPHYS %0d beat %0d lane %0d op %0d x %08x: got %08x want %08x",
								    NPHYS, nrcv, ln2, e_op[nrcv], e_x[nrcv][ln2 * 32 +: 32],
								    l_data[ln2 * 32 +: 32], e_data[nrcv][ln2 * 32 +: 32]);
							nerr = nerr + 1;
						end else if (e_lanes[nrcv][ln2] && FUNCS) begin
							bound(e_op[nrcv], e_x[nrcv][ln2 * 32 +: 32], l_data[ln2 * 32 +: 32]);
						end
				end
				nrcv = nrcv + 1;
			end
		end
	end
endmodule

module ad_su_xu_tb;
	reg clk = 0;
	reg rst_n = 0;
	always #5 clk = ~clk;
	wire donef, done8, done4;
	wire [31:0] errf, err8, err4, chkf, chk8, chk4;

	ad_su_xu_tbh #(.NPHYS(8), .GRP_W(2), .SEED(5), .FUNCS(1)) hf (
		.clk(clk), .rst_n(rst_n), .done(donef), .nerr(errf), .nchk(chkf));
	ad_su_xu_tbh #(.NPHYS(8), .GRP_W(2), .SEED(11)) h8 (
		.clk(clk), .rst_n(rst_n), .done(done8), .nerr(err8), .nchk(chk8));
	ad_su_xu_tbh #(.NPHYS(4), .GRP_W(3), .SEED(23)) h4 (
		.clk(clk), .rst_n(rst_n), .done(done4), .nerr(err4), .nchk(chk4));

	initial begin
		repeat (4) @(posedge clk);
		rst_n = 1;
		wait (donef && done8 && done4);
		$display("ad_su_xu_tb: funcs %0d beats (%0d errors); beats NPHYS 8 %0d, NPHYS 4 %0d (%0d errors)",
		    chkf, errf, chk8, chk4, err8 + err4);
		if (errf == 0 && chkf > 0)
			$display("PASS ad_su_xu.funcs");
		else
			$display("FAIL ad_su_xu.funcs");
		if (err8 == 0 && err4 == 0 && chk8 > 0 && chk4 > 0)
			$display("PASS ad_su_xu.beats");
		else
			$display("FAIL ad_su_xu.beats");
		if (errf + err8 + err4 == 0)
			$display("PASS ad_su_xu");
		$finish;
	end

	initial begin
		#400000000;
		$display("FAIL ad_su_xu timeout");
		$finish;
	end
endmodule
