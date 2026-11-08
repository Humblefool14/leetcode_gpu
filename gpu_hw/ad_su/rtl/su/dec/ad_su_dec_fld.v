/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * ad_su_dec_fld: the opcode-independent fields of a 64-bit GSI1
 * instruction (spec/gpu/su/ad_su_dec.md §4): the table's select fields and
 * the 7-bit operand numbers, low 5 bits from word0's RISC-V positions, high
 * 2 bits from word1 [1:0] (rd), [3:2] (rs1), [5:4] (rs2), [7:6] (rs3, low
 * bits word0[31:27]); the modifiers w1[14:8], half select w1[16:15] and sub
 * w1[21:17].  Combinational.
 */

module ad_su_dec_fld (
	input  wire [63:0] instr,
	output wire [6:0]  opc,
	output wire [2:0]  f3,
	output wire [6:0]  f7,
	output wire [4:0]  rs2f,
	output wire [1:0]  fmt2,
	output wire [11:0] imm12,
	output wire [6:0]  rd,
	output wire [6:0]  rs1,
	output wire [6:0]  rs2,
	output wire [6:0]  rs3,
	output wire [6:0]  mods,
	output wire [1:0]  hsel,
	output wire [4:0]  sub
);

wire [31:0] w0 = instr[31:0];
/* verilator lint_off UNUSEDSIGNAL */
wire [31:0] w1 = instr[63:32];
/* verilator lint_on UNUSEDSIGNAL */

assign opc = w0[6:0];
assign f3 = w0[14:12];
assign f7 = w0[31:25];
assign rs2f = w0[24:20];
assign fmt2 = w0[26:25];
assign imm12 = w0[31:20];
assign rd = {w1[1:0], w0[11:7]};
assign rs1 = {w1[3:2], w0[19:15]};
assign rs2 = {w1[5:4], w0[24:20]};
assign rs3 = {w1[7:6], w0[31:27]};
assign mods = w1[14:8];
assign hsel = w1[16:15];
assign sub = w1[21:17];

endmodule
