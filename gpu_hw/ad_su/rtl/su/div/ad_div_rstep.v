/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * ad_div_rstep: one step of a restoring division (combinational).
 * t = {r, bin}; when t >= d the quotient bit is 1 and the new partial
 * remainder is t - d, else t.  With r < d the new remainder is < d.
 * With d = 0 every bit is 1 and the remainder shifts the dividend in
 * (RISC-V divu/remu by zero falls out of this).
 */
module ad_div_rstep #(
	parameter W = 32
) (
	input wire [W-1:0] r,
	input wire bin,
	input wire [W-1:0] d,
	output wire [W-1:0] r_n,
	output wire q
);
	wire [W:0] t = {r, bin};
	wire [W+1:0] df = {1'b0, t} - {2'b00, d};

	assign q = ~df[W+1];
	assign r_n = q ? df[W-1:0] : t[W-1:0];
endmodule
