/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * ad_su_div_tb: ad_su_div against tools/gsi1fp.py div() (vectors of
 * tools/gen_div_vectors.py in sim/vec/div_ops.hex), on NPHYS 8 and 4 at
 * once.  Each block of 32 vectors is one instruction (its groups one after
 * the other, x held until x_ready); EXEC full, empty, one lane, all but one
 * or random, X on the operands of the lanes outside EXEC; idle cycles and
 * other units' groups on the bus; random l_ready.  Checked per beat: data
 * of the EXEC lanes, l_lanes, l_warp/grp/rd/wr/last/sbe/cls, the order, the
 * payload held while l_ready is 0, the 34-cycle lane time, and x_ready 0
 * while a group is in the unit.
 *
 *   PASS ad_su_div.ops
 *   PASS ad_su_div
 */
`timescale 1ns/1ps

module ad_su_div_tbh #(
	parameter NPHYS = 8,
	parameter GRP_W = 2,
	parameter SEED = 1
) (
	input wire clk,
	input wire rst_n,
	output reg done,
	output reg [31:0] nerr,
	output reg [31:0] nchk
);
`include "ad_su_uop.vh"
	localparam G = 32 / NPHYS;
	localparam NV = 6144;
	localparam NI = NV / 32;
	localparam MAXB = NI * G;

	reg [99:0] vec [0:NV-1];

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

	ad_su_div #(.NPHYS(NPHYS), .GRP_W(GRP_W)) dut (
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
	reg [31:0] e_cyc [0:MAXB-1];	/* minimum cycles from take to beat */
	integer nexp, nrcv, ntake;
	integer rs;
	integer cyc;
	integer take_cyc [0:MAXB-1];

	task fail_msg(input [8*48-1:0] what, input integer b);
		begin
			if (nerr < 20)
				$display("FAIL ad_su_div.ops NPHYS %0d beat %0d: %0s", NPHYS, b, what);
			nerr = nerr + 1;
		end
	endtask

	integer it, g, ln, k, n1, idle;
	reg [31:0] ex;
	reg [3:0] op;
	reg [99:0] v;
	reg [6:0] rd;
	reg wrd;
	reg [1:0] warp;
	reg [2:0] sbe;

	initial begin
		$readmemh("sim/vec/div_ops.hex", vec);
		rs = SEED;
		done = 0; nerr = 0; nchk = 0;
		nexp = 0; nrcv = 0; ntake = 0;
		x_valid = 0; x_warp = 0; x_grp = 0; x_last = 0; x_sbe = 0; x_uop = 0;
		x_a = 0; x_b = 0; x_mask = 0;
		@(posedge rst_n);
		for (it = 0; it < NI; it = it + 1) begin
			/* EXEC of the instruction */
			k = $urandom(rs) % 8;
			case (k)
			0: ex = 32'h0;
			1: ex = 32'h1 << ($urandom(rs) % 32);
			2: ex = ~(32'h1 << ($urandom(rs) % 32));
			3, 4: ex = $urandom(rs);
			default: ex = 32'hFFFFFFFF;
			endcase
			op = vec[it * 32][99:96];
			rd = $urandom(rs) % 64;
			wrd = ($urandom(rs) % 8) != 0;
			warp = $urandom(rs);
			sbe = $urandom(rs) % 8;
			for (g = 0; g < G; g = g + 1) begin
				@(negedge clk);
				/* idle cycles or other units' groups first */
				idle = $urandom(rs) % 4;
				while (idle > 0) begin
					x_valid = $urandom(rs) % 2;
					x_uop = {$urandom(rs), $urandom(rs), $urandom(rs), $urandom(rs)};
					if (x_uop[3:0] == AD_UNIT_DIV)
						x_uop[3:0] = AD_UNIT_ALU;
					x_mask = {2 * NPHYS{1'b1}};
					@(negedge clk);
					idle = idle - 1;
				end
				x_uop = 108'd0;
				x_uop[AD_UOP_UNIT +: 4] = AD_UNIT_DIV;
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
						x_a[ln * 32 +: 32] = v[95:64];
						x_b[ln * 32 +: 32] = v[63:32];
						e_data[nexp][ln * 32 +: 32] = v[31:0];
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
				e_cyc[nexp] = 34 * n1;
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
			l_ready <= ($urandom(rs) % 4) != 0;
			p_valid <= l_valid;
			p_ready <= l_ready;
			p_data <= l_data;
			p_lanes <= l_lanes;
			p_rd <= l_rd;
			p_last <= l_last;
			if (p_valid && !p_ready && (!l_valid || l_data !== p_data ||
			    l_lanes !== p_lanes || l_rd !== p_rd || l_last !== p_last))
				fail_msg("beat changed while l_ready 0", nrcv);
			if (x_valid && x_ready && x_uop[3:0] == AD_UNIT_DIV) begin
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
					if (cyc - take_cyc[nrcv] < e_cyc[nrcv] ||
					    cyc - take_cyc[nrcv] > e_cyc[nrcv] + NPHYS + 3)
						fail_msg("lane time not 34 cycles per EXEC lane", nrcv);
					for (ln2 = 0; ln2 < NPHYS; ln2 = ln2 + 1)
						if (e_lanes[nrcv][ln2] &&
						    l_data[ln2 * 32 +: 32] !== e_data[nrcv][ln2 * 32 +: 32]) begin
							if (nerr < 20)
								$display("FAIL ad_su_div.ops NPHYS %0d beat %0d lane %0d: got %08x want %08x",
								    NPHYS, nrcv, ln2, l_data[ln2 * 32 +: 32],
								    e_data[nrcv][ln2 * 32 +: 32]);
							nerr = nerr + 1;
						end
				end
				nrcv = nrcv + 1;
			end
		end
	end
endmodule

module ad_su_div_tb;
	reg clk = 0;
	reg rst_n = 0;
	always #5 clk = ~clk;
	wire done8, done4;
	wire [31:0] err8, err4, chk8, chk4;

	ad_su_div_tbh #(.NPHYS(8), .GRP_W(2), .SEED(11)) h8 (
		.clk(clk), .rst_n(rst_n), .done(done8), .nerr(err8), .nchk(chk8));
	ad_su_div_tbh #(.NPHYS(4), .GRP_W(3), .SEED(23)) h4 (
		.clk(clk), .rst_n(rst_n), .done(done4), .nerr(err4), .nchk(chk4));

	initial begin
		repeat (4) @(posedge clk);
		rst_n = 1;
		wait (done8 && done4);
		$display("ad_su_div_tb: NPHYS 8 %0d beats, NPHYS 4 %0d beats, %0d errors",
		    chk8, chk4, err8 + err4);
		if (err8 == 0 && err4 == 0 && chk8 > 0 && chk4 > 0) begin
			$display("PASS ad_su_div.ops");
			$display("PASS ad_su_div");
		end else begin
			$display("FAIL ad_su_div.ops");
		end
		$finish;
	end

	initial begin
		#200000000;
		$display("FAIL ad_su_div timeout");
		$finish;
	end
endmodule
