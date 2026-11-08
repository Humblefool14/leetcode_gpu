/*
 * fv_ad_su_h2f: ad_su_h2f.  Round trip: packh's fp32 -> fp16 conversion
 * (ad_su_pk_half ARITH 0, o = packh) of h2f(h) is h for every non-NaN fp16 after
 * the flush (denormals become the zero of their sign); a NaN gives 0x7FC00000;
 * the result is never an fp32 denormal.  Combinational (anyconst input).
 */
module fv_ad_su_h2f (input wire clk);
	(* anyconst *) reg [15:0] h;
	wire [31:0] f;
	wire [15:0] y;
	ad_su_h2f dut (.h(h), .f(f));
	ad_su_pk_half #(.ARITH(0), .FP(1)) f2h (.o(4'd13), .ha(16'd0), .hb(16'd0), .hc(16'd0),
		.r(3'd0), .sat(1'b0), .xw(f), .y(y));
	wire nan = (h[14:10] == 5'd31) && (h[9:0] != 10'd0);
	wire [15:0] hf = (h[14:10] == 5'd0) ? {h[15], 15'd0} : h;
	always @(*) begin
		if (!nan)
			assert (y == hf);
		else
			assert (f == 32'h7FC00000);
		assert (f[30:23] != 8'd0 || f[22:0] == 23'd0);
	end
endmodule
