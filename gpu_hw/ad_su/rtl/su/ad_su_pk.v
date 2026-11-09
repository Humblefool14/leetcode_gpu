/*
 * Amaterrace GPU
 * SPDX-License-Identifier: Zlib
 */

/*
 * ad_su_pk: the 16-bit packed unit (spec/gpu/su/ad_su_pk.md).  Takes the
 * groups of unit AD_UNIT_PK; per lane two ad_su_pk_half (low and high half:
 * packh's conversion and the per-half operation) and one ad_su_h2f (unpackh),
 * combinational, then SHORT_LAT pipeline stages to the short result.
 * Results equal tools/gsi1fp.pk(op, a, b, c, rm, hsel, sub, sat) bit for bit.
 *
 * PACKED 0: packh, unpackh and swaph only (the other operations give 0).
 * PK_SHARED (with PACKED): the fp16 float operations (fadd2..fmax2, fcmp*2)
 * are ad_su_fpu's: this unit does not take them (no result) and drops x_ready
 * for the cycle after one went by while it was ready.
 *
 * `define AD_SU_PK_STUB (formal timing harness only) replaces the lane datapath
 * by a ^ b.
 */
module ad_su_pk #(
	parameter NPHYS = 8,
	/* verilator lint_off UNUSEDPARAM */
	parameter NWARPS = 4,
	/* verilator lint_on UNUSEDPARAM */
	parameter WARP_W = 2,
	parameter GRP_W = 2,
	parameter SBE_W = 2,
	parameter UOP_W = 108,
	parameter PACKED = 0,
	parameter SHORT_LAT = 6,
	parameter PK_SHARED = 0
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

	/* verilator lint_off UNUSEDSIGNAL */
	wire unused = x_last ^ (^x_sbe) ^ (^x_pc) ^ (^x_info) ^ (^x_mask[2*NPHYS-1:NPHYS]) ^ (^x_uop);
	/* verilator lint_on UNUSEDSIGNAL */

	wire mine = x_uop[AD_UOP_UNIT +: 4] == AD_UNIT_PK;
	wire [3:0] op = x_uop[AD_UOP_OP +: 4];
	wire [2:0] rm = x_uop[AD_UOP_RM +: 3];
	wire [1:0] hsel = x_uop[AD_UOP_HSEL +: 2];
	wire hi_sub = x_uop[AD_UOP_SUB +: 5] != 5'd0;
	wire sat = x_uop[AD_UOP_MOD + 6];
	wire wrd = x_uop[AD_UOP_WRD];

	wire op_pk = (op == AD_PK_PACKH[3:0]);
	wire op_up = (op == AD_PK_UNPACKH[3:0]);
	wire op_sw = (op == AD_PK_SWAPH[3:0]);
	wire fop = (op <= AD_PK_FMAX2[3:0]) || (op >= AD_PK_FCMPLT2[3:0] && op <= AD_PK_FCMPNE2[3:0]);
	wire shared_f = (PACKED != 0) && (PK_SHARED != 0) && fop;

	/* PK_SHARED: x_ready is 0 in the cycle after a float group went by. */
	reg blk;
	assign x_ready = !blk;
	always @(posedge clk) begin
		if (!rst_n)
			blk <= 1'b0;
		else
			blk <= x_valid && mine && x_ready && shared_f;
	end
	wire take = x_valid && mine && x_ready && !shared_f;

	/* The lanes (combinational). */
	wire [NPHYS*32-1:0] res;
	genvar l;
	generate
		for (l = 0; l < NPHYS; l = l + 1) begin : g_lane
			wire [31:0] a = x_a[l*32 +: 32];
			wire [31:0] b = x_b[l*32 +: 32];
			wire [31:0] c = x_c[l*32 +: 32];
`ifdef AD_SU_PK_STUB
			/* verilator lint_off UNUSEDSIGNAL */
			wire [31:0] cu = c;
			/* verilator lint_on UNUSEDSIGNAL */
			assign res[l*32 +: 32] = a ^ b;
`else
			wire [31:0] bs = (hsel == 2'd3) ? {b[15:0], b[31:16]} : b;
			wire [15:0] lo, hi;
			wire [31:0] up;
			ad_su_pk_half #(.ARITH(PACKED), .FP(PK_SHARED == 0)) u_lo (
				.o(op), .ha(a[15:0]), .hb(bs[15:0]), .hc(c[15:0]), .r(rm), .sat(sat),
				.xw(a), .y(lo));
			ad_su_pk_half #(.ARITH(PACKED), .FP(PK_SHARED == 0)) u_hi (
				.o(op), .ha(a[31:16]), .hb(bs[31:16]), .hc(c[31:16]), .r(rm), .sat(sat),
				.xw(b), .y(hi));
			ad_su_h2f u_h2f (.h(hi_sub ? a[31:16] : a[15:0]), .f(up));
			reg [31:0] r;
			always @(*) begin
				if (op_pk)
					r = {hi, lo};
				else if (op_up)
					r = up;
				else if (op_sw)
					r = {a[15:0], a[31:16]};
				else if (PACKED == 0)
					r = 32'd0;
				else if (hsel == 2'd1)
					r = {a[31:16], lo};
`ifdef MUT_PK_HSEL
				else if (hsel == 2'd2)
					r = {hi, a[31:16]};
`else
				else if (hsel == 2'd2)
					r = {hi, a[15:0]};
`endif
				else
					r = {hi, lo};
			end
			assign res[l*32 +: 32] = r;
`endif
		end
	endgenerate

	/* SHORT_LAT stages. */
	reg [SHORT_LAT-1:0] pv;
	reg [WARP_W-1:0] pw [0:SHORT_LAT-1];
	reg [GRP_W-1:0] pg [0:SHORT_LAT-1];
	reg [6:0] prd [0:SHORT_LAT-1];
	reg [NPHYS-1:0] pl [0:SHORT_LAT-1];
	reg [NPHYS*32-1:0] pd [0:SHORT_LAT-1];
	integer k;
	/* verilator lint_off UNUSEDSIGNAL */
	wire [SHORT_LAT:0] pvn = {pv, take && wrd};
	/* verilator lint_on UNUSEDSIGNAL */
	always @(posedge clk) begin
		if (!rst_n)
			pv <= {SHORT_LAT{1'b0}};
		else
			pv <= pvn[SHORT_LAT-1:0];
	end
	always @(posedge clk) begin
		pw[0] <= x_warp;
		pg[0] <= x_grp;
		prd[0] <= x_uop[AD_UOP_RD +: 7];
		pl[0] <= x_mask[NPHYS-1:0];
		pd[0] <= res;
		for (k = 1; k < SHORT_LAT; k = k + 1) begin
			pw[k] <= pw[k-1];
			pg[k] <= pg[k-1];
			prd[k] <= prd[k-1];
			pl[k] <= pl[k-1];
			pd[k] <= pd[k-1];
		end
	end
	assign s_valid = pv[SHORT_LAT-1];
	assign s_warp = pw[SHORT_LAT-1];
	assign s_grp = pg[SHORT_LAT-1];
	assign s_rd = prd[SHORT_LAT-1];
	assign s_data = pd[SHORT_LAT-1];
	assign s_lanes = pl[SHORT_LAT-1];
endmodule
