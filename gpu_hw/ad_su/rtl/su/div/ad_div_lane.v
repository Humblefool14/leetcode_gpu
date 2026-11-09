/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * ad_div_lane: one lane's RISC-V divide in W + 2 cycles after start
 * (the start cycle loads the magnitudes, W restoring steps, the sign fix
 * registers res; done is 1 for one cycle W + 2 cycles after start).  start is taken only when !busy.
 */
module ad_div_lane #(
	parameter W = 32
) (
	input wire clk,
	input wire rst_n,
	input wire start,
	input wire [1:0] op,
	input wire [W-1:0] a,
	input wire [W-1:0] b,
	output wire busy,
	output reg done,
	output reg [W-1:0] res
);
	localparam CW = $clog2(W + 1);

	/* phase 0 idle (load on start), 2 divide, 3 sign fix */
	reg [1:0] ph;
	reg [CW-1:0] cnt;
	reg [1:0] op_r;
	reg [W-1:0] a_r, b_r;
	reg [W-1:0] dvd;		/* dividend bits still to shift in, quotient bits shift in below */
	reg [W-1:0] rem;
	reg [W-1:0] ud;

	wire [W-1:0] ua, ub, sres;
	wire [W-1:0] r_n;
	wire qb;

	/* The operands of the sign leaf: the inputs in the load cycle, then
	 * the registered ones for the sign fix. */
	wire ld = (ph == 2'd0);
	wire [1:0] s_op = ld ? op : op_r;
	wire [W-1:0] s_a = ld ? a : a_r;
	wire [W-1:0] s_b = ld ? b : b_r;

	ad_div_sign #(.W(W)) u_sign (
		.op(s_op), .a(s_a), .b(s_b), .ua(ua), .ub(ub),
		.uq(dvd), .ur(rem), .res(sres)
	);

	ad_div_rstep #(.W(W)) u_step (
		.r(rem), .bin(dvd[W-1]), .d(ud), .r_n(r_n), .q(qb)
	);

	assign busy = (ph != 2'd0);

	always @(posedge clk) begin
		if (!rst_n) begin
			ph <= 2'd0;
			cnt <= {CW{1'b0}};
			done <= 1'b0;
			op_r <= 2'd0;
			a_r <= {W{1'b0}};
			b_r <= {W{1'b0}};
			dvd <= {W{1'b0}};
			rem <= {W{1'b0}};
			ud <= {W{1'b0}};
			res <= {W{1'b0}};
		end else begin
			done <= 1'b0;
			case (ph)
			2'd0: if (start) begin
				op_r <= op;
				a_r <= a;
				b_r <= b;
				dvd <= ua;
				ud <= ub;
				rem <= {W{1'b0}};
				cnt <= W[CW-1:0];
				ph <= 2'd2;
			end
			2'd2: begin
				rem <= r_n;
				dvd <= {dvd[W-2:0], qb};
				cnt <= cnt - 1'b1;
				if (cnt == {{(CW-1){1'b0}}, 1'b1})
					ph <= 2'd3;
			end
			default: begin
				res <= sres;
				done <= 1'b1;
				ph <= 2'd0;
			end
			endcase
		end
	end
`ifdef FORMAL
	/* Helper invariants for the proofs (formal/ad_div_lane): with D, B the
	 * magnitudes of the latched operands and cnt the steps still to do,
	 * the partial remainder and the quotient bits so far satisfy
	 * rem + q * B == D >> cnt and rem < B (B != 0), the dividend bits still
	 * to shift in are the low cnt bits of D; and the result is the RISC-V
	 * one for the latched operands. */
	wire [W-1:0] f_ua = (~op_r[0] & a_r[W-1]) ? (~a_r + 1'b1) : a_r;
	wire [W-1:0] f_ub = (~op_r[0] & b_r[W-1]) ? (~b_r + 1'b1) : b_r;
	wire [CW-1:0] f_cnt = (ph == 2'd3) ? {CW{1'b0}} : cnt;
	wire [W-1:0] f_lom = ~({W{1'b1}} << f_cnt);
	wire [W-1:0] f_qm = ~({W{1'b1}} << (W - f_cnt));
	wire [W-1:0] f_q = dvd & f_qm;
	wire [W-1:0] f_hi = f_ua >> f_cnt;
	reg [W-1:0] f_ref;
	always @(*) begin
		if (b_r == {W{1'b0}})
			f_ref = op_r[1] ? a_r : {W{1'b1}};
		else if (!op_r[0] && a_r == {1'b1, {(W-1){1'b0}}} && b_r == {W{1'b1}})
			f_ref = op_r[1] ? {W{1'b0}} : a_r;
		else case (op_r)
			2'd0: f_ref = $signed(a_r) / $signed(b_r);
			2'd1: f_ref = a_r / b_r;
			2'd2: f_ref = $signed(a_r) % $signed(b_r);
			default: f_ref = a_r % b_r;
		endcase
		if (rst_n) begin
			assert (ph != 2'd1);
			if (ph == 2'd2)
				assert (cnt != {CW{1'b0}} && cnt <= W);
			if (ph == 2'd2 || ph == 2'd3) begin
				assert (ud == f_ub);
				assert ((dvd >> (W - f_cnt)) == (f_ua & f_lom) || f_cnt == {CW{1'b0}});
				if (ud != {W{1'b0}}) begin
					assert (rem < ud);
					assert ({{W{1'b0}}, rem} + {{W{1'b0}}, f_q} * {{W{1'b0}}, ud} == {{W{1'b0}}, f_hi});
				end else begin
					assert (f_q == f_qm && rem == f_hi);
				end
			end
		end
	end
	reg f_past = 1'b0;
	always @(posedge clk) begin
		f_past <= rst_n;
		if (f_past && rst_n && done)
			assert (res == f_ref);
	end
`endif
endmodule
