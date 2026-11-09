// fv_ad_div_rstep: the restoring step at full width (32 bits).  With the
// invariant r < d (d != 0): {r, bin} == q * d + r_n and r_n < d, so by
// induction over the 32 steps of ad_div_lane the unsigned core gives
// q * b + r == a and r < b for every 32-bit a and b != 0.  With d = 0:
// q = 1 and r_n = the low W bits of {r, bin} (divide by zero shifts a in).
module fv_ad_div_rstep;
    (* anyconst *) reg [31:0] r;
    (* anyconst *) reg [31:0] d;
    (* anyconst *) reg bin;
    wire [31:0] r_n;
    wire q;
    ad_div_rstep #(.W(32)) dut (.r(r), .bin(bin), .d(d), .r_n(r_n), .q(q));
    wire [32:0] t = {r, bin};
    always @(*) begin
        if (d != 0) begin
            assume (r < d);
            assert ({32'd0, t} == (q ? {33'd0, d} : 66'd0) + {34'd0, r_n});
            assert (r_n < d);
        end else begin
            assert (q && r_n == t[31:0]);
        end
    end
endmodule
