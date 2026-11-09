/*
 * fv_ad_su_hminmax: ad_su_hminmax on (a, b) and (b, a).  The result is one of
 * the flushed operands (0x7E00 when both are NaN; the other one when one is);
 * in the total order with -0 < +0: min <= both, max >= both, min <= max;
 * min and max are commutative.  Combinational.
 */
module fv_ad_su_hminmax (input wire clk);
	(* anyconst *) reg [15:0] a, b;
	wire [15:0] mn, mx, mn2, mx2;
	ad_su_hminmax m0 (.a(a), .b(b), .mx(1'b0), .y(mn));
	ad_su_hminmax m1 (.a(a), .b(b), .mx(1'b1), .y(mx));
	ad_su_hminmax m2 (.a(b), .b(a), .mx(1'b0), .y(mn2));
	ad_su_hminmax m3 (.a(b), .b(a), .mx(1'b1), .y(mx2));
	wire na = (a[14:10] == 5'd31) && (a[9:0] != 10'd0);
	wire nb = (b[14:10] == 5'd31) && (b[9:0] != 10'd0);
	wire [15:0] fa = (a[14:10] == 5'd0) ? {a[15], 15'd0} : a;
	wire [15:0] fb = (b[14:10] == 5'd0) ? {b[15], 15'd0} : b;
	/* Order key: negatives below -0 below +0 below positives. */
	function [15:0] key(input [15:0] x);
		key = x[15] ? (16'h7FFF - {1'b0, x[14:0]}) : (16'h8000 + {1'b0, x[14:0]});
	endfunction
	always @(*) begin
		assert (mn == mn2);
		assert (mx == mx2);
		if (na && nb) begin
			assert (mn == 16'h7E00 && mx == 16'h7E00);
		end else if (na) begin
			assert (mn == fb && mx == fb);
		end else if (nb) begin
			assert (mn == fa && mx == fa);
		end else begin
			assert (mn == fa || mn == fb);
			assert (mx == fa || mx == fb);
			assert (key(mn) <= key(fa) && key(mn) <= key(fb));
			assert (key(mx) >= key(fa) && key(mx) >= key(fb));
			assert (key(mn) <= key(mx));
		end
	end
endmodule
