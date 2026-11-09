/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * ad_su_f2i: fcvt.w.s / fcvt.wu.s (tools/gsi1fp.py fcvt_ws) from the
 * rounded integer of ad_su_rint: saturating as RISC-V (NaN as +inf,
 * negatives to 0 for wu).  Combinational.  Spec: spec/gpu/su/ad_su_f2i.md.
 */

module ad_su_f2i (
	input  wire        neg,	/* ad_su_rint: sign of x */
	input  wire [31:0] mag,	/* ad_su_rint: |rint(x)| */
	input  wire        big,	/* ad_su_rint: |x| >= 2^32, inf or NaN */
	input  wire        nan,	/* x is a NaN */
	input  wire        uns,	/* fcvt.wu.s */
	output reg  [31:0] y
);

	always @(*) begin
		if (nan || (big && !neg))
			y = uns ? 32'hFFFFFFFF : 32'h7FFFFFFF;
		else if (uns)
			y = neg ? 32'd0 : mag;
		else if (big)
			y = 32'h80000000;
		else if (!neg)
			y = mag[31] ? 32'h7FFFFFFF : mag;
		else
			y = mag > 32'h80000000 ? 32'h80000000 : 32'd0 - mag;
	end

endmodule
