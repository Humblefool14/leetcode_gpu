/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * ad_su_dec_imm: the immediate builder of ad_su_dec.  fmt 1 I, 2 S, 3 B:
 * sext(imm12) + (sext(w1[31:22]) << 12) (the B offset is an instruction
 * count: {w0[31], w0[7], w0[30:25], w0[11:8]}, not shifted); 4 U:
 * {w0[31:12], w1[13:2]} (lui/movi); 0 (R/R4 forms): the texel offsets
 * {w1[13:10], w1[29:26], w1[25:22]} (dw, dv, du) of a texture instruction
 * (tex = 1), else 0.  Combinational.
 */

module ad_su_dec_imm (
	input  wire [63:0] instr,
	input  wire [2:0]  fmt,
	input  wire        tex,
	output reg  [31:0] imm
);

/* verilator lint_off UNUSEDSIGNAL */
wire [31:0] w0 = instr[31:0];
wire [31:0] w1 = instr[63:32];
/* verilator lint_on UNUSEDSIGNAL */

wire [11:0] lo_i = w0[31:20];
wire [11:0] lo_s = {w0[31:25], w0[11:7]};
wire [11:0] lo_b = {w0[31], w0[7], w0[30:25], w0[11:8]};
wire [31:0] hi = {{10{w1[31]}}, w1[31:22], 12'd0};

always @(*) begin
	case (fmt)
	3'd1: imm = {{20{lo_i[11]}}, lo_i} + hi;
	3'd2: imm = {{20{lo_s[11]}}, lo_s} + hi;
	3'd3: imm = {{20{lo_b[11]}}, lo_b} + hi;
	3'd4: imm = {w0[31:12], w1[13:2]};
	default: imm = tex ? {20'd0, w1[13:10], w1[29:26], w1[25:22]} : 32'd0;
	endcase
end

endmodule
