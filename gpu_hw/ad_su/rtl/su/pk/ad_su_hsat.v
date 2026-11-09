/*
 * Amaterrace GPU
 * SPDX-License-Identifier: Zlib
 */

/*
 * ad_su_hsat: clamp an fp16 to [0, 1] (spec/gpu/su/ad_su_hsat.md, gsi1fp.sat(F16)).
 * NaN, negatives and -0 give +0; a positive value above 1.0 (+inf included)
 * gives 1.0 (0x3C00); others pass unchanged.  Combinational.
 */
module ad_su_hsat (
	input wire [15:0] x,
	output wire [15:0] y
);
	wire nan = (x[14:10] == 5'd31) && (x[9:0] != 10'd0);
`ifdef MUT_HSAT_NEG
	assign y = nan ? 16'd0 : (x > 16'h3C00 && !x[15]) ? 16'h3C00 : x;
`else
	assign y = (nan || x[15]) ? 16'd0 : (x > 16'h3C00) ? 16'h3C00 : x;
`endif
endmodule
