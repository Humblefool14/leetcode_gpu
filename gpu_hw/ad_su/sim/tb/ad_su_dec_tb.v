/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * ad_su_dec_tb: six ad_su_dec instances (the configurations of
 * tools/gen_dec_vectors.py CFG: NREGS/PACKED/SUBGROUP/HAS_SA/MS4) decode
 * the vectors of sim/vec/dec_(name).hex (tools/gsi1asm.py decode() as the
 * reference) through the registered d_ / u_ handshake with random d_valid
 * and u_ready; every uop, warp and pc is compared in order and u_* must hold
 * while u_valid && !u_ready.
 * Regenerate the vectors: python3 -I tools/gen_dec_vectors.py
 */

`timescale 1ns/1ps

module ad_su_dec_tb;

`include "ad_su_uop.vh"

localparam W = AD_UOP_W;
localparam NC = 6;
localparam MAXV = 49152;

reg clk = 0;
reg rst_n = 0;
always #5 clk = ~clk;

reg d_valid = 0;
reg [1:0] d_warp = 0;
reg [15:0] d_pc = 0;
reg [63:0] d_instr = 0;
reg u_ready = 0;
wire [NC-1:0] d_ready, u_valid;
wire [1:0] u_warp [0:NC-1];
wire [15:0] u_pc [0:NC-1];
wire [W-1:0] u_uop [0:NC-1];

`define DEC(I, NR, PK, SG, SA, M4) \
	ad_su_dec #(.WARP_W(2), .UOP_W(W), .NREGS(NR), .PACKED(PK), .SUBGROUP(SG), .HAS_SA(SA), \
		.MS4(M4)) u_dec``I ( \
		.clk(clk), .rst_n(rst_n), .d_valid(d_valid), .d_ready(d_ready[I]), .d_warp(d_warp), \
		.d_pc(d_pc), .d_instr(d_instr), .u_valid(u_valid[I]), .u_ready(u_ready), \
		.u_warp(u_warp[I]), .u_pc(u_pc[I]), .u_uop(u_uop[I]));

`DEC(0, 32, 0, 0, 0, 0)
`DEC(1, 64, 1, 1, 1, 1)
`DEC(2, 32, 1, 0, 0, 1)
`DEC(3, 64, 0, 1, 0, 0)
`DEC(4, 32, 0, 1, 1, 0)
`DEC(5, 48, 1, 1, 0, 1)

localparam [NC-1:0] MS4V = 6'b100110;

reg [64+2*W-1:0] vt [0:MAXV-1];
reg [64+NC*W-1:0] vc [0:MAXV-1];
reg [63:0] vi [0:MAXV-1];
reg [W-1:0] ve [0:MAXV-1][0:NC-1];
reg [NC-1:0] vm [0:MAXV-1];		/* configurations compared */
integer nv, errs, nill, i, c, cc;

/* Loads a file: 2-uop lines (dec_table.hex: decoders 0 and 1) or 6-uop lines. */
task load;
	input [8*64-1:0] path;
	input two;
	integer k;
	begin
		for (k = 0; k < MAXV; k = k + 1) begin
			vt[k] = {(64+2*W){1'bx}};
			vc[k] = {(64+NC*W){1'bx}};
		end
		if (two) $readmemh(path, vt); else $readmemh(path, vc);
		nv = 0;
		while (nv < MAXV && (two ? vt[nv][0] !== 1'bx : vc[nv][0] !== 1'bx))
			nv = nv + 1;
		if (nv == MAXV || nv == 0) begin
			$display("FAIL ad_su_dec: %0s: %0d vectors (MAXV %0d)", path, nv, MAXV);
			errs = errs + 1;
		end
		for (k = 0; k < nv; k = k + 1) begin
			if (two) begin
				vi[k] = vt[k][2*W +: 64];
				ve[k][0] = vt[k][W +: W];
				ve[k][1] = vt[k][0 +: W];
				vm[k] = 6'b000011;
			end else begin
				vi[k] = vc[k][NC*W +: 64];
				for (c = 0; c < NC; c = c + 1)
					ve[k][c] = vc[k][(NC-1-c)*W +: W];
				vm[k] = {NC{1'b1}};
			end
		end
	end
endtask

/* Streams vectors 0..nv-1 through the decoders, random valid/ready.  The
 * driver changes inputs at the negative edge; the checker samples at the
 * positive edge. */
integer sent, got, cyc, cur;
reg [W-1:0] held [0:NC-1];
reg stalled = 0, run = 0;
task stream;
	input [31:0] pv, pr;	/* percent valid, percent ready */
	begin
		sent = 0; got = 0; cyc = 0; cur = -1; run = 1;
		while (got < nv && cyc < 40 * nv + 100) begin
			@(negedge clk);
			cyc = cyc + 1;
			if (!(d_valid && cur == sent)) begin
				cur = sent;
				d_valid = (sent < nv) && ($urandom % 100 < pv);
				d_instr = vi[sent];
				d_warp = sent[1:0];
				d_pc = sent[15:0];
			end
			u_ready = ($urandom % 100 < pr);
		end
		@(negedge clk);
		d_valid = 0;
		run = 0;
		if (got != nv) begin
			$display("FAIL ad_su_dec: %0d of %0d decoded", got, nv);
			errs = errs + 1;
		end
	end
endtask

always @(posedge clk) if (run) begin
	if (d_valid && d_ready[0])
		sent = sent + 1;
	for (cc = 0; cc < NC; cc = cc + 1) begin
		if (u_valid[cc] !== u_valid[0] || d_ready[cc] !== d_ready[0]) begin
			if (errs < 10) $display("FAIL ad_su_dec: handshake differs, dec%0d", cc);
			errs = errs + 1;
		end
		if (stalled && u_uop[cc] !== held[cc]) begin
			if (errs < 10) $display("FAIL ad_su_dec: dec%0d u_uop not held", cc);
			errs = errs + 1;
		end
		held[cc] = u_uop[cc];
	end
	stalled = u_valid[0] && !u_ready;
	if (u_valid[0] && u_ready) begin
		for (cc = 0; cc < NC; cc = cc + 1) begin
			if (u_warp[cc] !== got[1:0] || u_pc[cc] !== got[15:0] ||
			    (vm[got][cc] && u_uop[cc] !== ve[got][cc])) begin
				if (errs < 10)
					$display("FAIL ad_su_dec: vector %0d instr %016x dec%0d uop %027x want %027x",
						 got, vi[got], cc, u_uop[cc], ve[got][cc]);
				errs = errs + 1;
			end
			if (vm[got][cc] && u_uop[cc][AD_UOP_ILL]) nill = nill + 1;
		end
		got = got + 1;
	end
end

initial begin
	errs = 0;
	repeat (3) @(posedge clk);
	rst_n = 1;

	/* table: every row (gsi1asm --dec-table) on decoders 0/1, then all six */
	load("sim/vec/dec_table.hex", 1);
	stream(80, 80);
	load("sim/vec/dec_cfg.hex", 0);
	stream(60, 50);
	load("sim/vec/dec_sweep.hex", 0);
	stream(100, 100);
	if (errs == 0) $display("PASS ad_su_dec.table");

	/* operands: 7-bit operand numbers, immediates, random word1 */
	load("sim/vec/dec_opd.hex", 0);
	stream(100, 100);
	if (errs == 0) $display("PASS ad_su_dec.operands");

	/* fault: illegal encodings */
	nill = 0;
	load("sim/vec/dec_fault.hex", 0);
	stream(70, 70);
	if (nill < nv * NC / 2) begin
		$display("FAIL ad_su_dec.fault: only %0d ILL of %0d", nill, nv * NC);
		errs = errs + 1;
	end
	if (errs == 0) $display("PASS ad_su_dec.fault");

	/* texszs: texsz.s faults without MS4, TEX op 0x4B without rs1 with it */
	load("sim/vec/dec_texszs.hex", 0);
	for (i = 0; i < nv; i = i + 1)
		for (c = 0; c < NC; c = c + 1)
			if (!ve[i][c][AD_UOP_ILL] && (!MS4V[c] || ve[i][c][AD_UOP_UNIT +: 4] != AD_UNIT_TEX ||
			    ve[i][c][AD_UOP_OP +: 8] != 8'h4B || ve[i][c][AD_UOP_USE1])) begin
				$display("FAIL ad_su_dec.texszs: vector %0d dec%0d", i, c);
				errs = errs + 1;
			end else if (MS4V[c] && i < 10 && ve[i][c][AD_UOP_ILL] && vi[i][33:32] == 0 &&
				     vi[i][11] == 0 && vi[i][53] == 0) begin
				$display("FAIL ad_su_dec.texszs: vector %0d dec%0d faults with MS4", i, c);
				errs = errs + 1;
			end
	stream(90, 90);
	if (errs == 0) $display("PASS ad_su_dec.texszs");

	if (errs == 0) $display("PASS ad_su_dec");
	else $display("FAIL ad_su_dec: %0d errors", errs);
	$finish;
end

endmodule
