/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * ad_su_fp_leaf_tb: the fp leaves (ad_su_ffma_p, ad_su_rint, ad_su_i2f,
 * ad_su_f2i through ad_su_rint, ad_su_fadd) against the vectors of
 * tools/gen_fpu_vectors.py (every expected value from tools/gsi1fp.py),
 * 200,000 per leaf.  Prints PASS ad_su_fp_leaf.<leaf> per leaf, then
 * PASS ad_su_fp_leaf.
 */

`timescale 1ns/1ps

module ad_su_fp_leaf_tb;

	localparam N = 200000;

	reg [135:0] v_ffma [0:N-1];
	reg [75:0]  v_rint [0:N-1];
	reg [71:0]  v_i2f  [0:N-1];
	reg [71:0]  v_f2i  [0:N-1];
	reg [95:0]  v_fadd [0:N-1];

	/* ffma */
	reg  [31:0] fa, fb, fc;
	reg  [2:0]  frm;
	reg         fnoc;
	wire [47:0] fpm = {fa[30:23] != 8'd0, fa[22:0]} * {fb[30:23] != 8'd0, fb[22:0]};
	wire [31:0] fy;
	ad_su_ffma_p u_ffma (.a(fa), .b(fb), .c(fc), .rm(frm), .noc(fnoc), .pm(fpm), .y(fy));

	/* rint, and f2i through a second rint */
	reg  [31:0] rx;
	reg  [2:0]  rrm;
	wire        rneg, rbig;
	wire [31:0] rmag;
	ad_su_rint u_rint (.x(rx), .rm(rrm), .neg(rneg), .mag(rmag), .big(rbig));

	reg  [31:0] cx;
	reg  [2:0]  crm;
	reg         cuns;
	wire        cneg, cbig;
	wire [31:0] cmag, cy;
	ad_su_rint u_rint2 (.x(cx), .rm(crm), .neg(cneg), .mag(cmag), .big(cbig));
	ad_su_f2i u_f2i (.neg(cneg), .mag(cmag), .big(cbig),
		.nan(cx[30:23] == 8'hFF && cx[22:0] != 23'd0), .uns(cuns), .y(cy));

	/* i2f */
	reg  [31:0] ia;
	reg         iuns;
	reg  [2:0]  irm;
	wire [31:0] iy;
	ad_su_i2f u_i2f (.a(ia), .uns(iuns), .rm(irm), .y(iy));

	/* fadd */
	reg  [31:0] aa, ab;
	wire [31:0] ay;
	ad_su_fadd u_fadd (.a(aa), .b(ab), .y(ay));

	integer i, n, err, tot;

	initial begin
		tot = 0;
		$readmemh("sim/vec/fpu_ffma.hex", v_ffma);
		$readmemh("sim/vec/fpu_rint.hex", v_rint);
		$readmemh("sim/vec/fpu_i2f.hex", v_i2f);
		$readmemh("sim/vec/fpu_f2i.hex", v_f2i);
		$readmemh("sim/vec/fpu_fadd.hex", v_fadd);

		err = 0; n = 0;
		for (i = 0; i < N && !$isunknown(v_ffma[i]); i = i + 1) begin
			{frm, fnoc, fa, fb, fc} = {v_ffma[i][134:132], v_ffma[i][128], v_ffma[i][127:32]};
			#1;
			n = n + 1;
			if (fy !== v_ffma[i][31:0]) begin
				err = err + 1;
				if (err <= 10)
					$display("ffma mismatch rm %0d noc %0d a %h b %h c %h: got %h exp %h",
						frm, fnoc, fa, fb, fc, fy, v_ffma[i][31:0]);
			end
		end
		report("ffma_p", n, err);

		err = 0; n = 0;
		for (i = 0; i < N && !$isunknown(v_rint[i]); i = i + 1) begin
			rrm = v_rint[i][74:72];
			rx = v_rint[i][71:40];
			#1;
			n = n + 1;
			if (rneg !== v_rint[i][36] || rbig !== v_rint[i][32] ||
			    (!rbig && rmag !== v_rint[i][31:0])) begin
				err = err + 1;
				if (err <= 10)
					$display("rint mismatch rm %0d x %h: got %b %b %h exp %h", rrm, rx,
						rneg, rbig, rmag, v_rint[i][39:0]);
			end
		end
		report("rint", n, err);

		err = 0; n = 0;
		for (i = 0; i < N && !$isunknown(v_i2f[i]); i = i + 1) begin
			iuns = v_i2f[i][68];
			irm = v_i2f[i][66:64];
			ia = v_i2f[i][63:32];
			#1;
			n = n + 1;
			if (iy !== v_i2f[i][31:0]) begin
				err = err + 1;
				if (err <= 10)
					$display("i2f mismatch uns %0d rm %0d a %h: got %h exp %h", iuns, irm,
						ia, iy, v_i2f[i][31:0]);
			end
		end
		report("i2f", n, err);

		err = 0; n = 0;
		for (i = 0; i < N && !$isunknown(v_f2i[i]); i = i + 1) begin
			cuns = v_f2i[i][68];
			crm = v_f2i[i][66:64];
			cx = v_f2i[i][63:32];
			#1;
			n = n + 1;
			if (cy !== v_f2i[i][31:0]) begin
				err = err + 1;
				if (err <= 10)
					$display("f2i mismatch uns %0d rm %0d x %h: got %h exp %h", cuns, crm,
						cx, cy, v_f2i[i][31:0]);
			end
		end
		report("f2i", n, err);

		err = 0; n = 0;
		for (i = 0; i < N && !$isunknown(v_fadd[i]); i = i + 1) begin
			{aa, ab} = v_fadd[i][95:32];
			#1;
			n = n + 1;
			if (ay !== v_fadd[i][31:0]) begin
				err = err + 1;
				if (err <= 10)
					$display("fadd mismatch a %h b %h: got %h exp %h", aa, ab, ay,
						v_fadd[i][31:0]);
			end
		end
		report("fadd", n, err);

		if (tot == 0)
			$display("PASS ad_su_fp_leaf");
		else
			$display("FAIL ad_su_fp_leaf (%0d errors)", tot);
		$finish;
	end

	task report(input [8*8-1:0] name, input integer cnt, input integer e);
		begin
			tot = tot + e + (cnt == 0);
			if (e == 0 && cnt > 0)
				$display("PASS ad_su_fp_leaf.%0s (%0d vectors)", name, cnt);
			else
				$display("FAIL ad_su_fp_leaf.%0s (%0d of %0d vectors wrong)", name, e, cnt);
		end
	endtask

endmodule
