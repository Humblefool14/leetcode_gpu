/*
 * fv_ad_su_pk: ad_su_pk.  Free inputs every cycle (module ports), reset in the
 * first cycle.  Two harness variants (defines):
 *
 * TIMING (tasks bmc, prove; built with AD_SU_PK_STUB: the lane datapath is
 *   a ^ b): NPHYS 4, SHORT_LAT 6, two units PACKED 1 with PK_SHARED 0 and 1 on
 *   the same inputs.  A shadow pipeline of exactly SHORT_LAT stages: s_valid
 *   exactly SHORT_LAT cycles after a taken group with WRD, never otherwise, with
 *   that group's warp, grp, rd, EXEC lanes and data; PK_SHARED 0: x_ready always
 *   1; PK_SHARED 1: the float ops are not taken and x_ready is 0 exactly in the
 *   cycle after one went by while ready.
 *
 * HSEL (tasks bmc_hsel, prove_hsel; the real datapath, NPHYS 4 (every lane),
 *   PACKED 1): for every taken group other than packh/unpackh/swaph, hsel 1
 *   gives rs1's high half and hsel 2 rs1's low half in the result.
 */
module fv_ad_su_pk #(
	parameter NPHYS = 4,
	parameter L = 6
) (
	input wire clk,
	input wire rst_n,
	input wire x_valid,
	input wire [1:0] x_warp,
	input wire [1:0] x_grp,
	input wire x_last,
	input wire [2:0] x_sbe,
	input wire [15:0] x_pc,
	input wire [107:0] x_uop,
	input wire [NPHYS*32-1:0] x_a,
	input wire [NPHYS*32-1:0] x_b,
	input wire [NPHYS*32-1:0] x_c,
	input wire [2*NPHYS-1:0] x_mask,
	input wire [31:0] x_info
);
`include "ad_su_uop.vh"
	reg init = 1'b1;
	always @(posedge clk)
		init <= 1'b0;
	always @(*)
		if (init)
			assume (!rst_n);

	wire mine = x_uop[AD_UOP_UNIT +: 4] == AD_UNIT_PK;
	wire [3:0] op = x_uop[AD_UOP_OP +: 4];
	wire fop = (op <= 4'd5) || (op >= 4'd9 && op <= 4'd12);
	wire wrd = x_uop[AD_UOP_WRD];
	wire [1:0] hsel = x_uop[AD_UOP_HSEL +: 2];

`define FV_PK_DUT(NAME, SH, RDY, SV, SW, SG, SR, SD, SL) \
	wire RDY, SV; \
	wire [1:0] SW, SG; \
	wire [6:0] SR; \
	wire [NPHYS*32-1:0] SD; \
	wire [NPHYS-1:0] SL; \
	ad_su_pk #(.NPHYS(NPHYS), .GRP_W(2), .PACKED(1), .PK_SHARED(SH), .SHORT_LAT(L)) NAME ( \
		.clk(clk), .rst_n(rst_n), .x_valid(x_valid), .x_warp(x_warp), .x_grp(x_grp), \
		.x_last(x_last), .x_sbe(x_sbe), .x_pc(x_pc), .x_uop(x_uop), .x_a(x_a), .x_b(x_b), \
		.x_c(x_c), .x_mask(x_mask), .x_info(x_info), .x_ready(RDY), .s_valid(SV), \
		.s_warp(SW), .s_grp(SG), .s_rd(SR), .s_data(SD), .s_lanes(SL));

`ifdef TIMING
	`FV_PK_DUT(d0, 0, rdy0, sv0, sw0, sg0, sr0, sd0, sl0)
	`FV_PK_DUT(d1, 1, rdy1, sv1, sw1, sg1, sr1, sd1, sl1)

	reg mblk;
	always @(posedge clk)
		mblk <= rst_n && x_valid && mine && !mblk && fop;
	wire t0 = x_valid && mine && wrd;
	wire t1 = x_valid && mine && wrd && !mblk && !fop;
	wire [NPHYS*32-1:0] dstub = x_a ^ x_b;

	reg [L-1:0] v0, v1;
	reg [10+NPHYS:0] tg [0:L-1];
	reg [NPHYS*32-1:0] dd [0:L-1];
	integer k;
	always @(posedge clk) begin
		v0 <= rst_n ? {v0[L-2:0], t0} : {L{1'b0}};
		v1 <= rst_n ? {v1[L-2:0], t1} : {L{1'b0}};
		tg[0] <= {x_warp, x_grp, x_uop[AD_UOP_RD +: 7], x_mask[NPHYS-1:0]};
		dd[0] <= dstub;
		for (k = 1; k < L; k = k + 1) begin
			tg[k] <= tg[k-1];
			dd[k] <= dd[k-1];
		end
	end
	always @(*) begin
		if (!init) begin
			assert (rdy0 == 1'b1);
			assert (rdy1 == !mblk);
			assert (sv0 == v0[L-1]);
			assert (sv1 == v1[L-1]);
			if (sv0)
				assert ({sw0, sg0, sr0, sl0} == tg[L-1] && sd0 == dd[L-1]);
			if (sv1)
				assert ({sw1, sg1, sr1, sl1} == tg[L-1] && sd1 == dd[L-1]);
		end
	end
`endif

`ifdef HSEL
	`FV_PK_DUT(d0, 0, rdy0, sv0, sw0, sg0, sr0, sd0, sl0)
	wire kept = x_valid && mine && wrd && !(op >= 4'd13);
	reg [L-1:0] v;
	reg [1:0] hs [0:L-1];
	reg [NPHYS*32-1:0] ra [0:L-1];
	integer n;
	integer k;
	always @(posedge clk) begin
		v <= rst_n ? {v[L-2:0], kept} : {L{1'b0}};
		hs[0] <= hsel;
		ra[0] <= x_a;
		for (k = 1; k < L; k = k + 1) begin
			hs[k] <= hs[k-1];
			ra[k] <= ra[k-1];
		end
	end
	always @(*) begin
		if (!init) begin
			assert (rdy0 == 1'b1);
			if (v[L-1]) begin
				assert (sv0);
				for (n = 0; n < NPHYS; n = n + 1) begin
					if (hs[L-1] == 2'd1)
						assert (sd0[n*32+16 +: 16] == ra[L-1][n*32+16 +: 16]);
					if (hs[L-1] == 2'd2)
						assert (sd0[n*32 +: 16] == ra[L-1][n*32 +: 16]);
				end
			end
		end
	end
`endif
endmodule
