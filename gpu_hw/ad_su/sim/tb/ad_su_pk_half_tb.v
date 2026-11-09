/*
 * Amaterrace GPU
 * SPDX-License-Identifier: Zlib
 */

/*
 * ad_su_pk_half_tb: ad_su_pk_half (ARITH 1 FP 1, ARITH 1 FP 0, ARITH 0) and its
 * leaves (ad_su_h2f, ad_su_hsat, ad_su_hcmp, ad_su_hminmax; ad_su_hrnd through
 * the half) against tools/gsi1fp.py (vectors of tools/gen_pk_vectors.py):
 *   .fma   every fadd2/fsub2/fmul2/ffma2 vector of sim/vec/pk_half.hex (every
 *          addend alignment, cancellations, sparse mantissas, specials, all rm, sat)
 *   .other the other operations and packh of pk_half.hex; ad_su_h2f and ad_su_hsat
 *          on all 65536 fp16; ad_su_hcmp (4 ops) and ad_su_hminmax (min, max) on
 *          every special pair and 1,000,000 random pairs (sim/vec/pk_pair.hex).
 */
`timescale 1ns/1ps
module ad_su_pk_half_tb;
`include "ad_su_uop.vh"
	localparam NHALF = 280000;
	localparam NPAIR = 1000729;

	reg [107:0] vh [0:NHALF-1];
	reg [63:0] vf [0:65535];
	reg [67:0] vp [0:NPAIR-1];

	reg [3:0] o;
	reg [15:0] ha, hb, hc;
	reg [2:0] r;
	reg sat;
	reg [31:0] xw;
	wire [15:0] y11, y10, y0;
	ad_su_pk_half #(.ARITH(1), .FP(1)) u11 (.o(o), .ha(ha), .hb(hb), .hc(hc), .r(r), .sat(sat), .xw(xw), .y(y11));
	ad_su_pk_half #(.ARITH(1), .FP(0)) u10 (.o(o), .ha(ha), .hb(hb), .hc(hc), .r(r), .sat(sat), .xw(xw), .y(y10));
	ad_su_pk_half #(.ARITH(0), .FP(1)) u0 (.o(o), .ha(ha), .hb(hb), .hc(hc), .r(r), .sat(sat), .xw(xw), .y(y0));

	reg [15:0] la, lb;
	wire [31:0] f2;
	wire [15:0] ys, yeq, ylt, yle, yne, ymin, ymax;
	ad_su_h2f uh (.h(la), .f(f2));
	ad_su_hsat us (.x(la), .y(ys));
	ad_su_hcmp uc0 (.a(la), .b(lb), .op(2'd0), .y(yeq));
	ad_su_hcmp uc1 (.a(la), .b(lb), .op(2'd1), .y(ylt));
	ad_su_hcmp uc2 (.a(la), .b(lb), .op(2'd2), .y(yle));
	ad_su_hcmp uc3 (.a(la), .b(lb), .op(2'd3), .y(yne));
	ad_su_hminmax um0 (.a(la), .b(lb), .mx(1'b0), .y(ymin));
	ad_su_hminmax um1 (.a(la), .b(lb), .mx(1'b1), .y(ymax));

	integer i, err, nf, no, bad;
	reg [15:0] e11, e10, e0;
	reg isf, isfma;

	task check_half;
		begin
			o = vh[i][107:104];
			r = vh[i][102:100];
			sat = vh[i][96];
			ha = vh[i][95:80];
			hb = vh[i][79:64];
			hc = vh[i][63:48];
			xw = vh[i][47:16];
			e11 = vh[i][15:0];
			#1;
			isf = (o <= 4'd5) || (o >= 4'd9 && o <= 4'd12);
			e10 = isf ? 16'd0 : e11;
			e0 = (o == AD_PK_PACKH[3:0]) ? e11 : 16'd0;
			if (y11 !== e11 || y10 !== e10 || y0 !== e0) begin
				err = err + 1;
				if (err < 10)
					$display("FAIL ad_su_pk_half vec %0d o %0d r %0d sat %0d a %h b %h c %h xw %h: got %h %h %h exp %h %h %h",
						i, o, r, sat, ha, hb, hc, xw, y11, y10, y0, e11, e10, e0);
			end
		end
	endtask

	initial begin
		$readmemh("sim/vec/pk_half.hex", vh);
		$readmemh("sim/vec/pk_h2f.hex", vf);
		$readmemh("sim/vec/pk_pair.hex", vp);
		/* .fma */
		err = 0;
		nf = 0;
		for (i = 0; i < NHALF; i = i + 1) begin
			isfma = (vh[i][107:104] <= 4'd3);
			if (isfma) begin
				check_half;
				nf = nf + 1;
			end
		end
		bad = 0;
		if (err == 0 && nf >= 200000)
			$display("PASS ad_su_pk_half.fma");
		else
			begin $display("FAIL ad_su_pk_half.fma (%0d errors in %0d vectors)", err, nf); bad = 1; end
		/* .other */
		err = 0;
		no = 0;
		for (i = 0; i < NHALF; i = i + 1) begin
			isfma = (vh[i][107:104] <= 4'd3);
			if (!isfma) begin
				check_half;
				no = no + 1;
			end
		end
		for (i = 0; i < 65536; i = i + 1) begin
			la = vf[i][63:48];
			lb = 16'd0;
			#1;
			if (f2 !== vf[i][47:16] || ys !== vf[i][15:0]) begin
				err = err + 1;
				if (err < 10)
					$display("FAIL ad_su_pk_half h2f/hsat %h: got %h %h exp %h %h", la, f2, ys,
						vf[i][47:16], vf[i][15:0]);
			end
		end
		for (i = 0; i < NPAIR; i = i + 1) begin
			la = vp[i][67:52];
			lb = vp[i][51:36];
			#1;
			if (yeq !== {16{vp[i][32]}} || ylt !== {16{vp[i][33]}} || yle !== {16{vp[i][34]}} ||
			    yne !== {16{vp[i][35]}} || ymin !== vp[i][31:16] || ymax !== vp[i][15:0]) begin
				err = err + 1;
				if (err < 10)
					$display("FAIL ad_su_pk_half cmp/minmax %h %h: got %b%b%b%b %h %h exp %h %h %h",
						la, lb, yne[0], yle[0], ylt[0], yeq[0], ymin, ymax, vp[i][35:32],
						vp[i][31:16], vp[i][15:0]);
			end
		end
		if (err == 0)
			$display("PASS ad_su_pk_half.other");
		else
			begin $display("FAIL ad_su_pk_half.other (%0d errors)", err); bad = 1; end
		$display("ad_su_pk_half_tb: %0d fma, %0d other half vectors, 65536 h2f/hsat, %0d pairs", nf, no, NPAIR);
		if (!bad)
			$display("PASS ad_su_pk_half");
		$finish;
	end
endmodule
