/*
 * fv_ad_su_hcmp: ad_su_hcmp on (a, b) and (b, a), all four ops.  Ordered:
 * trichotomy (exactly one of a<b, a==b, b<a), le = lt | eq, antisymmetry
 * (a<=b and b<=a -> a==b), eq symmetric, ne = !eq.  Unordered (a NaN): eq, lt,
 * le false, ne true.  Outputs are 0 or 0xFFFF.  Combinational.
 */
module fv_ad_su_hcmp (input wire clk);
	(* anyconst *) reg [15:0] a, b;
	wire [15:0] eq, lt, le, ne, eq2, lt2, le2, ne2;
	ad_su_hcmp c0 (.a(a), .b(b), .op(2'd0), .y(eq));
	ad_su_hcmp c1 (.a(a), .b(b), .op(2'd1), .y(lt));
	ad_su_hcmp c2 (.a(a), .b(b), .op(2'd2), .y(le));
	ad_su_hcmp c3 (.a(a), .b(b), .op(2'd3), .y(ne));
	ad_su_hcmp d0 (.a(b), .b(a), .op(2'd0), .y(eq2));
	ad_su_hcmp d1 (.a(b), .b(a), .op(2'd1), .y(lt2));
	ad_su_hcmp d2 (.a(b), .b(a), .op(2'd2), .y(le2));
	ad_su_hcmp d3 (.a(b), .b(a), .op(2'd3), .y(ne2));
	wire un = ((a[14:10] == 5'd31) && (a[9:0] != 10'd0)) || ((b[14:10] == 5'd31) && (b[9:0] != 10'd0));
	always @(*) begin
		assert (eq == 16'd0 || eq == 16'hFFFF);
		assert (lt == 16'd0 || lt == 16'hFFFF);
		assert (le == 16'd0 || le == 16'hFFFF);
		assert (ne == 16'd0 || ne == 16'hFFFF);
		if (un) begin
			assert (!eq[0] && !lt[0] && !le[0] && ne[0]);
			assert (!eq2[0] && !lt2[0] && !le2[0] && ne2[0]);
		end else begin
			assert ((lt[0] + eq[0] + lt2[0]) == 2'd1);
			assert (le[0] == (lt[0] | eq[0]));
			assert (!(le[0] && le2[0]) || eq[0]);
			assert (eq[0] == eq2[0]);
			assert (ne[0] == !eq[0]);
			assert (ne2[0] == !eq2[0]);
		end
		/* Zeros and denormals equal each other. */
		if (a[14:10] == 5'd0 && b[14:10] == 5'd0)
			assert (eq[0]);
	end
endmodule
