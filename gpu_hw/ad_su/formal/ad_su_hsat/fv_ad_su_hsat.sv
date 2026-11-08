/*
 * fv_ad_su_hsat: ad_su_hsat.  y is +0 or a positive value <= 1.0 (never NaN or
 * negative); NaN and the sign bit give +0; 0 <= x <= 1.0 passes unchanged;
 * a positive x above 1.0 gives 1.0.  Combinational.
 */
module fv_ad_su_hsat (input wire clk);
	(* anyconst *) reg [15:0] x;
	wire [15:0] y;
	ad_su_hsat dut (.x(x), .y(y));
	wire nan = (x[14:10] == 5'd31) && (x[9:0] != 10'd0);
	always @(*) begin
		assert (y[15] == 1'b0 && y <= 16'h3C00);
		if (nan || x[15])
			assert (y == 16'd0);
		else if (x <= 16'h3C00)
			assert (y == x);
		else
			assert (y == 16'h3C00);
	end
endmodule
