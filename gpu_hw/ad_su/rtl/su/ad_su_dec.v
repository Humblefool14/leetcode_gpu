/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * ad_su_dec: decodes a 64-bit GSI1 instruction into the SU micro-op
 * (spec/gpu/su/ad_su_dec.md; the encoding of docs/GSI1_ISA.md, the table of
 * tools/gsi1asm.py).  One pipeline register: d_ready = !u_valid || u_ready;
 * u_* is the decode of the instruction taken one cycle before, held until
 * u_ready.  The combinational decode is ad_su_dec_core.
 */

module ad_su_dec #(
	parameter WARP_W = 2,
	parameter UOP_W = 108,
	parameter NREGS = 32,
	parameter PACKED = 0,
	parameter SUBGROUP = 0,
	parameter HAS_SA = 0,
	parameter MS4 = 0
) (
	input  wire              clk,
	input  wire              rst_n,
	input  wire              d_valid,
	output wire              d_ready,
	input  wire [WARP_W-1:0] d_warp,
	input  wire [15:0]       d_pc,
	input  wire [63:0]       d_instr,
	output reg               u_valid,
	input  wire              u_ready,
	output reg  [WARP_W-1:0] u_warp,
	output reg  [15:0]       u_pc,
	output reg  [UOP_W-1:0]  u_uop
);

wire [UOP_W-1:0] uop;

ad_su_dec_core #(
	.UOP_W(UOP_W), .NREGS(NREGS), .PACKED(PACKED), .SUBGROUP(SUBGROUP), .HAS_SA(HAS_SA),
	.MS4(MS4)
) u_core (
	.instr(d_instr), .uop(uop)
);

assign d_ready = !u_valid || u_ready;

always @(posedge clk) begin
	if (!rst_n) begin
		u_valid <= 1'b0;
	end else if (d_ready) begin
		u_valid <= d_valid;
	end
end

/* Datapath: loaded on every taken instruction (qualified by u_valid). */
always @(posedge clk) begin
`ifdef MUT_DEC_HOLD
	if (d_valid) begin	/* mutation: overwrites a held uop */
`else
	if (d_valid && d_ready) begin
`endif
		u_warp <= d_warp;
		u_pc <= d_pc;
		u_uop <= uop;
	end
end

endmodule
