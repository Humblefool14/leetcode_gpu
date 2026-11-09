/*
 * fv_ad_su_pk_half: ad_su_pk_half (ARITH 1, FP 1).  Combinational (anyconst).
 *   P_ID   (define P_ID)   ffma2 x * 1.0 + (-0) under RNE == x for every non-NaN x
 *                          (after the flush: a denormal x gives the zero of its sign)
 *   P_COMM (define P_COMM) fmul2/ffma2: a * b + c == b * a + c, every rm and sat
 *   P_DEN  (define P_DEN)  the float operations and packh never give a denormal,
 *                          for any operands, rm and sat
 * The .sby runs each property as its own task pair (bmc_*, prove_*); bmc/prove
 * run all three.
 */
module fv_ad_su_pk_half (input wire clk);
	(* anyconst *) reg [15:0] a, b, c;
	(* anyconst *) reg [2:0] r;
	(* anyconst *) reg [3:0] o;
	(* anyconst *) reg st;
	(* anyconst *) reg [31:0] xw;

`ifdef P_ID
	wire [15:0] yid;
	ad_su_pk_half #(.ARITH(1), .FP(1)) u_id (.o(4'd3), .ha(a), .hb(16'h3C00), .hc(16'h8000),
		.r(3'd0), .sat(1'b0), .xw(32'd0), .y(yid));
	wire nan_a = (a[14:10] == 5'd31) && (a[9:0] != 10'd0);
	wire [15:0] fa = (a[14:10] == 5'd0) ? {a[15], 15'd0} : a;
	always @(*)
		if (!nan_a)
			assert (yid == fa);
`endif

`ifdef P_COMM
	wire [15:0] y1, y2;
	wire [3:0] oc = o[0] ? 4'd3 : 4'd2;	/* ffma2 or fmul2 */
	ad_su_pk_half #(.ARITH(1), .FP(1)) u_c1 (.o(oc), .ha(a), .hb(b), .hc(c), .r(r), .sat(st),
		.xw(32'd0), .y(y1));
	ad_su_pk_half #(.ARITH(1), .FP(1)) u_c2 (.o(oc), .ha(b), .hb(a), .hc(c), .r(r), .sat(st),
		.xw(32'd0), .y(y2));
	always @(*)
		assert (y1 == y2);
`endif

`ifdef P_DEN
	wire [15:0] yd;
	ad_su_pk_half #(.ARITH(1), .FP(1)) u_d (.o(o), .ha(a), .hb(b), .hc(c), .r(r), .sat(st),
		.xw(xw), .y(yd));
	always @(*)
		if (o <= 4'd5 || o == 4'd13)
			assert (yd[14:10] != 5'd0 || yd[9:0] == 10'd0);
`endif
endmodule
