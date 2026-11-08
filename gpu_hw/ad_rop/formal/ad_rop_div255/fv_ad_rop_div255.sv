// q = round(x/255): q*255 <= x + 127 < (q+1)*255 for every x <= 65025.
module fv_ad_rop_div255;
    (* anyconst *) reg [17:0] x;
    wire [8:0] q;
    ad_rop_div255 dut (.x(x), .q(q));
    wire [19:0] lo = q * 255;
    wire [19:0] t  = x + 127;
    always @(*) begin
        assume (x <= 18'd65025);
        a_lo: assert (lo <= t);
        a_hi: assert (t < lo + 255);
        a_rng: assert (q <= 9'd255);
    end
endmodule
