/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * ad_su_ffma_p: fp32 fused multiply-add y = round(a * b + c) with one
 * rounding under rm, given the product of the significands (pm, from the
 * parent's multiplier).  Denormals are flushed on input; a result whose
 * exponent after rounding is below the normal range is a zero of its sign;
 * overflow follows rm; NaN results are 0x7FC00000.  noc: there is no
 * addend (fmul: the sign of a zero product survives every rm).
 * Exactly tools/gsi1fp.py fma(F32, a, b, c, rm, noc).  Combinational.
 * Spec: spec/gpu/su/ad_su_ffma_p.md.
 */

module ad_su_ffma_p (
	input  wire [31:0] a,
	input  wire [31:0] b,
	input  wire [31:0] c,
	input  wire [2:0]  rm,	/* 0 RNE, 1 RTZ, 2 RDN, 3 RUP, 4 RMM, 5-7 RNE */
	input  wire        noc,	/* no addend (c ignored) */
	input  wire [47:0] pm,	/* {ea != 0, a[22:0]} * {eb != 0, b[22:0]} */
	output reg  [31:0] y
);

	localparam [31:0] QNAN = 32'h7FC00000;

	/* Operand fields (flushed). */
	wire       sa = a[31], sb = b[31], sc = c[31];
	wire [7:0] ea = a[30:23], eb = b[30:23], ec = c[30:23];
	wire       za = ea == 8'd0, zb = eb == 8'd0;
	wire       zc = ec == 8'd0 | noc;
	wire       ia = ea == 8'hFF && a[22:0] == 23'd0;
	wire       ib = eb == 8'hFF && b[22:0] == 23'd0;
	wire       ic = ec == 8'hFF && c[22:0] == 23'd0 && !noc;
	wire       na = ea == 8'hFF && a[22:0] != 23'd0;
	wire       nb = eb == 8'hFF && b[22:0] != 23'd0;
	wire       nc = ec == 8'hFF && c[22:0] != 23'd0 && !noc;
	wire       sp = sa ^ sb;
	wire [2:0] rmd = rm > 3'd4 ? 3'd0 : rm;
	wire       rdn = rmd == 3'd2;

	/*
	 * The window W[75:0]: the product at W[48:1], the addend (24 bits) at
	 * W[74:51] shifted right by sh; bits shifted below W[0] are ORed into
	 * W[0].  d = (addend LSB exponent) - (product LSB exponent)
	 * = ec - ea - eb + 150, sh = 50 - d.  When sh < 0 the product is less
	 * than a quarter of the addend's ulp: the addend stays at W[74:51] and
	 * the product at W[48:1] only decides the rounding direction, which is
	 * the same (two bits of gap).  W[1]'s exponent is then ec - 200,
	 * otherwise ea + eb - 300.
	 */
	wire signed [11:0] sh_raw = $signed({4'd0, ea}) + $signed({4'd0, eb}) - $signed({4'd0, ec}) - 12'sd100;
	wire       cbase = !zc && sh_raw < 12'sd0;
	wire [6:0] sh = zc ? 7'd76 : (sh_raw < 12'sd0 ? 7'd0 : (sh_raw > 12'sd76 ? 7'd76 : sh_raw[6:0]));
	wire [23:0] mc = zc ? 24'd0 : {1'b1, c[22:0]};
	wire [151:0] cext = {1'b0, mc, 51'd0, 76'd0} >> sh;
	wire        cst = cext[75:0] != 76'd0;
	wire [75:0] cw = cext[151:76] | {75'd0, cst};
	wire [75:0] pw = {27'd0, pm, 1'b0};

	wire        esub = sp ^ sc;
	wire [76:0] dif = {1'b0, pw} - {1'b0, cw};
	wire        cbig = dif[76];
	wire [75:0] msum = pw + cw;
	wire [75:0] mag = !esub ? msum : (cbig ? cw - pw : dif[75:0]);
	wire        rs = !esub ? sp : (cbig ? sc : sp);

	/* Leading-one position and normalization. */
	reg [6:0] lz;
	integer i;
	always @(*) begin
		lz = 7'd76;
		for (i = 0; i < 76; i = i + 1)
			if (mag[i])
				lz = 7'd75 - i[6:0];
	end
	wire [75:0] nm = mag << lz;
	wire [23:0] mt = nm[75:52];
	wire        g = nm[51];
	wire        st = nm[50:0] != 51'd0;

	reg up;
	always @(*) begin
		case (rmd)
		3'd0: up = g & (st | mt[0]);
		3'd1: up = 1'b0;
		3'd2: up = rs & (g | st);
		3'd3: up = !rs & (g | st);
		default: up = g;
		endcase
	end
	wire [24:0] mr = {1'b0, mt} + {24'd0, up};
	wire        cy = mr[24];
	/* Biased exponent of the leading bit (see the window comment). */
	wire signed [11:0] be0 = cbase ? $signed({4'd0, ec}) - $signed({5'd0, lz}) + 12'sd1 :
		$signed({4'd0, ea}) + $signed({4'd0, eb}) - $signed({5'd0, lz}) - 12'sd99;
	wire signed [11:0] be = be0 + (cy ? 12'sd1 : 12'sd0);
	wire [22:0] mf = cy ? 23'd0 : mr[22:0];

	wire ovmax = rmd == 3'd1 || (rmd == 3'd2 && !rs) || (rmd == 3'd3 && rs);

	always @(*) begin
		if (na || nb || nc || (ia && zb) || (ib && za))
			y = QNAN;
		else if (ia || ib)
			y = (ic && sc != sp) ? QNAN : {sp, 8'hFF, 23'd0};
		else if (ic)
			y = c;
		else if (za || zb) begin
			if (noc)
				y = {sp, 31'd0};
			else if (zc)
				y = {rdn ? (sp | sc) : (sp & sc), 31'd0};
			else
				y = c;
		end else if (mag == 76'd0)
			y = {rdn, 31'd0};
		else if (be >= 12'sd255)
			y = ovmax ? {rs, 8'hFE, 23'h7FFFFF} : {rs, 8'hFF, 23'd0};
`ifdef MUT_FFMA_DENORM
		else if (be <= 12'sd0)
			y = {rs, 8'd0, mf};
`else
		else if (be <= 12'sd0)
			y = {rs, 31'd0};
`endif
		else
			y = {rs, be[7:0], mf};
	end

endmodule
