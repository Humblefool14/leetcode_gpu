/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * ad_xu_divider: restoring division of (r0 << steps) by d, one quotient bit
 * per cycle (ad_div_rstep, no dividend bits shifted in: the XU's dividends
 * are 2^50 and 2^57).  start loads (r0 < d), then steps cycles, then done is
 * 1 for one cycle with q (steps bits) and the remainder r: q * d + r ==
 * r0 << steps, r < d.  rcp: r0 2^22, steps 28; rsq: r0 2^28, steps 29.
 */
module ad_xu_divider #(
	parameter DW = 30,
	parameter QW = 32,
	parameter CW = 6
) (
	input wire clk,
	input wire rst_n,
	input wire start,
	input wire [DW-1:0] r0,
	input wire [DW-1:0] d,
	input wire [CW-1:0] steps,
	output wire busy,
	output reg done,
	output reg [QW-1:0] q,
	output reg [DW-1:0] r
);
	reg run;
	reg [CW-1:0] cnt;
	reg [DW-1:0] dv;
	wire [DW-1:0] r_n;
	wire qb;

	ad_div_rstep #(.W(DW)) u_step (.r(r), .bin(1'b0), .d(dv), .r_n(r_n), .q(qb));

	assign busy = run;

	always @(posedge clk) begin
		if (!rst_n) begin
			run <= 1'b0;
			cnt <= {CW{1'b0}};
			dv <= {DW{1'b0}};
			q <= {QW{1'b0}};
			r <= {DW{1'b0}};
			done <= 1'b0;
		end else begin
			done <= 1'b0;
			if (!run) begin
				if (start) begin
					r <= r0;
					dv <= d;
					q <= {QW{1'b0}};
					cnt <= steps;
					run <= 1'b1;
				end
			end else begin
				r <= r_n;
				q <= {q[QW-2:0], qb};
				cnt <= cnt - 1'b1;
				if (cnt == {{(CW-1){1'b0}}, 1'b1}) begin
					run <= 1'b0;
					done <= 1'b1;
				end
			end
		end
	end
endmodule
