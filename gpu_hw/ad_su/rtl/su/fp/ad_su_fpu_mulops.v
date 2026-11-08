/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * ad_su_fpu_mulops: the two 33-bit signed operands of one lane's
 * multiplier in ad_su_fpu ($signed(ma) * $signed(mb), the low 64 bits are
 * ad_su_fpu_op's pr): for the float operations the significands
 * {e != 0, m} (b replaced by 1.0 for fadd, fsub and fract), for
 * mul/mulh/mulhsu/mulhu a and b sign- or zero-extended.  Combinational.
 * Spec: spec/gpu/su/ad_su_fpu.md section 10.
 */

module ad_su_fpu_mulops (
	input  wire [4:0]  o,	/* AD_FPU_* */
	input  wire [31:0] ia,
	input  wire [31:0] ib,
	output reg  [32:0] ma,
	output reg  [32:0] mb
);

`include "ad_su_uop.vh"

	wire [7:0] op = {3'd0, o};

	always @(*) begin
		ma = {9'd0, ia[30:23] != 8'd0, ia[22:0]};
		mb = {9'd0, ib[30:23] != 8'd0, ib[22:0]};
		case (op)
		AD_FPU_FADD, AD_FPU_FSUB, AD_FPU_FRACT:
			mb = {9'd0, 24'h800000};
		AD_FPU_MUL, AD_FPU_MULH: begin
			ma = {ia[31], ia};
			mb = {ib[31], ib};
		end
		AD_FPU_MULHSU: begin
			ma = {ia[31], ia};
			mb = {1'b0, ib};
		end
		AD_FPU_MULHU: begin
			ma = {1'b0, ia};
			mb = {1'b0, ib};
		end
		default: ;
		endcase
	end

endmodule
