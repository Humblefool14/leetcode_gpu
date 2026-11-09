/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * ad_su_fpu: the fp32 unit of the SU, NPHYS lanes (fadd .. fract, the
 * integer mul*).  Short unit: a group taken in cycle t (x_valid, unit
 * AD_UNIT_FPU, x_ready = 1) gives s_* in cycle t + SHORT_LAT when the uop
 * writes rd.  Per lane: ad_su_fpu_mulops, a 33 x 33 signed multiplier and
 * ad_su_fpu_op, combinational before the first of SHORT_LAT pipeline
 * stages.  The forwarding taps fw4_* / fw5_* are the stages that become
 * s_* 2 and 1 cycles later, valid only when rd is a register (rd < 63).
 * Spec: spec/gpu/su/ad_su_fpu.md.
 */

module ad_su_fpu #(
	parameter NPHYS = 8,
	parameter NWARPS = 4,
	parameter WARP_W = 2,
	parameter GRP_W = 2,
	parameter SBE_W = 2,
	parameter UOP_W = 108,
	parameter SHORT_LAT = 6
) (
	input  wire                  clk,
	input  wire                  rst_n,
	input  wire                  x_valid,
	input  wire [WARP_W-1:0]     x_warp,
	input  wire [GRP_W-1:0]      x_grp,
	input  wire                  x_last,
	input  wire [SBE_W:0]        x_sbe,
	input  wire [15:0]           x_pc,
	input  wire [UOP_W-1:0]      x_uop,
	input  wire [NPHYS*32-1:0]   x_a,
	input  wire [NPHYS*32-1:0]   x_b,
	input  wire [NPHYS*32-1:0]   x_c,
	input  wire [2*NPHYS-1:0]    x_mask,
	input  wire [31:0]           x_info,
	output wire                  x_ready,
	output wire                  s_valid,
	output wire [WARP_W-1:0]     s_warp,
	output wire [GRP_W-1:0]      s_grp,
	output wire [6:0]            s_rd,
	output wire [NPHYS*32-1:0]   s_data,
	output wire [NPHYS-1:0]      s_lanes,
	/* Forwarding taps for ad_su_opd (s_* 2 and 1 cycles later). */
	output wire                  fw4_valid,
	output wire [WARP_W-1:0]     fw4_warp,
	output wire [GRP_W-1:0]      fw4_grp,
	output wire [6:0]            fw4_rd,
	output wire [NPHYS*32-1:0]   fw4_data,
	output wire [NPHYS-1:0]      fw4_lanes,
	output wire                  fw5_valid,
	output wire [WARP_W-1:0]     fw5_warp,
	output wire [GRP_W-1:0]      fw5_grp,
	output wire [6:0]            fw5_rd,
	output wire [NPHYS*32-1:0]   fw5_data,
	output wire [NPHYS-1:0]      fw5_lanes
);

`include "ad_su_uop.vh"

	/* Unused bus fields (the unit needs none of them). */
	wire unused_ok = &{1'b0, x_last, x_sbe, x_pc, x_info, x_mask[2*NPHYS-1:NPHYS]};

	assign x_ready = 1'b1;

	wire       take = x_valid && x_uop[AD_UOP_UNIT +: 4] == AD_UNIT_FPU;
	wire [4:0] o = x_uop[AD_UOP_OP +: 5];
	wire [2:0] rm = x_uop[AD_UOP_RM +: 3];
	wire       sat = x_uop[AD_UOP_MOD + 6];

	/* Lane datapath (combinational). */
	wire [NPHYS*32-1:0] res;
	genvar l;
	generate
		for (l = 0; l < NPHYS; l = l + 1) begin : g_lane
			wire [31:0] la = x_a[l*32 +: 32];
			wire [31:0] lb = x_b[l*32 +: 32];
			wire [31:0] lc = x_c[l*32 +: 32];
`ifdef AD_SU_FPU_STUB
			/* Formal: the datapath replaced by a cheap function. */
			assign res[l*32 +: 32] = la ^ {lb[30:0], lb[31]} ^ lc ^ {27'd0, o};
`else
			wire [32:0] ma, mb;
			ad_su_fpu_mulops u_mulops (.o(o), .ia(la), .ib(lb), .ma(ma), .mb(mb));
			wire signed [65:0] prod = $signed(ma) * $signed(mb);
			ad_su_fpu_op u_op (
				.o(o), .ia(la), .ib(lb), .ic(lc), .irm(rm), .ist(sat),
				.pr(prod[63:0]), .res(res[l*32 +: 32])
			);
`endif
		end
	endgenerate

	/* SHORT_LAT stages; stage k holds the result k cycles after the take. */
	wire                 sv [0:SHORT_LAT];
	wire [WARP_W-1:0]    sw [0:SHORT_LAT];
	wire [GRP_W-1:0]     sg [0:SHORT_LAT];
	wire [6:0]           sr [0:SHORT_LAT];
	wire [NPHYS*32-1:0]  sd [0:SHORT_LAT];
	wire [NPHYS-1:0]     sl [0:SHORT_LAT];
	assign sv[0] = take && x_uop[AD_UOP_WRD];
	assign sw[0] = x_warp;
	assign sg[0] = x_grp;
	assign sr[0] = x_uop[AD_UOP_RD +: 7];
	assign sd[0] = res;
	assign sl[0] = x_mask[NPHYS-1:0];
	genvar k;
	generate
		for (k = 1; k <= SHORT_LAT; k = k + 1) begin : g_st
			reg                v;
			reg [WARP_W-1:0]   w;
			reg [GRP_W-1:0]    g;
			reg [6:0]          r;
			reg [NPHYS*32-1:0] d;
			reg [NPHYS-1:0]    ln;
			always @(posedge clk) begin
				if (!rst_n)
					v <= 1'b0;
				else
					v <= sv[k-1];
				/* Datapath: qualified by v. */
				w <= sw[k-1];
				g <= sg[k-1];
				r <= sr[k-1];
				d <= sd[k-1];
				ln <= sl[k-1];
			end
			assign sv[k] = v;
			assign sw[k] = w;
			assign sg[k] = g;
			assign sr[k] = r;
			assign sd[k] = d;
			assign sl[k] = ln;
		end
	endgenerate

`ifdef MUT_FPU_LAT
	localparam SO = SHORT_LAT - 1;
`else
	localparam SO = SHORT_LAT;
`endif
	localparam S4 = SHORT_LAT - 2;
	localparam S5 = SHORT_LAT - 1;
	assign s_valid = sv[SO];
	assign s_warp = sw[SO];
	assign s_grp = sg[SO];
	assign s_rd = sr[SO];
	assign s_data = sd[SO];
	assign s_lanes = sl[SO];

	assign fw4_valid = sv[S4] && sr[S4] < 7'd63;
	assign fw4_warp = sw[S4];
	assign fw4_grp = sg[S4];
	assign fw4_rd = sr[S4];
	assign fw4_data = sd[S4];
	assign fw4_lanes = sl[S4];
	assign fw5_valid = sv[S5] && sr[S5] < 7'd63;
	assign fw5_warp = sw[S5];
	assign fw5_grp = sg[S5];
	assign fw5_rd = sr[S5];
	assign fw5_data = sd[S5];
	assign fw5_lanes = sl[S5];

endmodule
