/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * ad_su_i2f: int32 (uns = 0) or uint32 (uns = 1) to fp32, rounded under
 * rm (fcvt.s.w / fcvt.s.wu, tools/gsi1fp.py fcvt_sw); 0 gives +0.
 * Combinational.  Spec: spec/gpu/su/ad_su_i2f.md.
 */

module ad_su_i2f (
	input  wire [31:0] a,
	input  wire        uns,
	input  wire [2:0]  rm,	/* 0 RNE, 1 RTZ, 2 RDN, 3 RUP, 4 RMM, 5-7 RNE */
	output wire [31:0] y
);

	wire        s = !uns & a[31];
	wire [31:0] mag = s ? 32'd0 - a : a;
	wire [2:0]  rmd = rm > 3'd4 ? 3'd0 : rm;

	reg [4:0] lz;
	integer i;
	always @(*) begin
		lz = 5'd0;
		for (i = 0; i < 32; i = i + 1)
			if (mag[i])
				lz = 5'd31 - i[4:0];
	end
	wire [31:0] nm = mag << lz;
	wire [23:0] mt = nm[31:8];
	wire        g = nm[7];
	wire        st = nm[6:0] != 7'd0;

	reg up;
	always @(*) begin
		case (rmd)
		3'd0: up = g & (st | mt[0]);
		3'd1: up = 1'b0;
		3'd2: up = s & (g | st);
		3'd3: up = !s & (g | st);
		default: up = g;
		endcase
	end
	wire [24:0] mr = {1'b0, mt} + {24'd0, up};
	/* Leading bit at 31 - lz: biased exponent 158 - lz (+1 on carry). */
	wire [7:0]  be = 8'd158 - {3'd0, lz} + {7'd0, mr[24]};
	wire [22:0] mf = mr[24] ? 23'd0 : mr[22:0];

	assign y = mag == 32'd0 ? 32'd0 : {s, be, mf};

endmodule
