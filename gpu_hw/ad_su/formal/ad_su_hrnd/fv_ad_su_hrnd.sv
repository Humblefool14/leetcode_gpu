/*
 * fv_ad_su_hrnd: ad_su_hrnd.  For any normalised input (m[12] = 1), any e, any
 * rm: never a denormal, never a NaN; exact inputs (round = sticky = 0) with
 * 1 <= e <= 30 give {s, e, f}; RTZ never increases the magnitude (an in-range e
 * gives the truncation); a result of exponent 31 is +-inf.  Combinational.
 */
module fv_ad_su_hrnd (input wire clk);
	(* anyconst *) reg s;
	(* anyconst *) reg signed [9:0] e;
	(* anyconst *) reg [12:0] m;
	(* anyconst *) reg [2:0] r;
	wire [15:0] y;
	ad_su_hrnd dut (.s(s), .e(e), .m(m), .r(r), .y(y));
	always @(*) begin
		assume (m[12]);
		assert (y[14:10] != 5'd0 || y[9:0] == 10'd0);
		assert (y[14:10] != 5'd31 || y[9:0] == 10'd0);
		assert (y[15] == s);
		if (m[1:0] == 2'd0 && e >= 10'sd1 && e <= 10'sd30)
			assert (y == {s, e[4:0], m[11:2]});
		if (r == 3'd1 && e >= 10'sd1 && e <= 10'sd30)
			assert (y == {s, e[4:0], m[11:2]});
		if (r == 3'd1)
			assert (y[14:10] != 5'd31);
	end
endmodule
