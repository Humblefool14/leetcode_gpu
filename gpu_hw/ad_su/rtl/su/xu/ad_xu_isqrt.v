/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * ad_xu_isqrt: floor(sqrt(n)) bit by bit (restoring, two bits of n per
 * cycle, RW cycles), and the remainder n - root^2 (0: exact).  start loads
 * n, done is 1 for one cycle RW + 1 cycles later.
 */
module ad_xu_isqrt #(
	parameter RW = 30
) (
	input wire clk,
	input wire rst_n,
	input wire start,
	input wire [2*RW-1:0] n,
	output wire busy,
	output reg done,
	output reg [RW-1:0] root,
	output reg [RW+1:0] rem
);
	localparam CW = $clog2(RW + 1);

	reg run;
	reg [CW-1:0] cnt;
	reg [2*RW-1:0] nsh;

	/* rem < 2 root + 1 <= 2^(RW+1): after the shift < 2^(RW+3) */
	wire [RW+3:0] t = {rem, nsh[2*RW-1:2*RW-2]};
`ifdef MUT_XU_ISQRT
	wire [RW+3:0] trial = {2'b00, root, 2'b11};
`else
	wire [RW+3:0] trial = {2'b00, root, 2'b01};
`endif
	wire ge = (t >= trial);
	wire [RW+3:0] tn = ge ? (t - trial) : t;

	assign busy = run;

	always @(posedge clk) begin
		if (!rst_n) begin
			run <= 1'b0;
			cnt <= {CW{1'b0}};
			nsh <= {2*RW{1'b0}};
			root <= {RW{1'b0}};
			rem <= {(RW+2){1'b0}};
			done <= 1'b0;
		end else begin
			done <= 1'b0;
			if (!run) begin
				if (start) begin
					nsh <= n;
					root <= {RW{1'b0}};
					rem <= {(RW+2){1'b0}};
					cnt <= RW[CW-1:0];
					run <= 1'b1;
				end
			end else begin
				nsh <= {nsh[2*RW-3:0], 2'b00};
				root <= {root[RW-2:0], ge};
				rem <= tn[RW+1:0];
				cnt <= cnt - 1'b1;
				if (cnt == {{(CW-1){1'b0}}, 1'b1}) begin
					run <= 1'b0;
					done <= 1'b1;
				end
			end
		end
	end
endmodule
