// Round trip: f2unorm(unorm2f(x)) == x for every 16-bit and 24-bit x, and the
// conversion is strictly monotonic (x < y  ->  f(x) < f(y) as bit patterns).
module fv_ad_unorm2f;
    (* anyconst *) reg [15:0] x;
    (* anyconst *) reg [15:0] y;
    (* anyconst *) reg [23:0] z;
    wire [31:0] fx, fy, fz; wire [15:0] bx; wire [23:0] bz;
    ad_unorm2f #(.N(16)) u_x (.x(x), .f(fx));
    ad_unorm2f #(.N(16)) u_y (.x(y), .f(fy));
    ad_f2unorm #(.N(16)) b_x (.f(fx), .u(bx));
    ad_unorm2f #(.N(24)) u_z (.x(z), .f(fz));
    ad_f2unorm #(.N(24)) b_z (.f(fz), .u(bz));
    always @(*) begin
        a_rt16: assert (bx == x);
        a_rt24: assert (bz == z);
        if (x < y) a_mono: assert (fx < fy);
        a_le1:  assert (fx <= 32'h3F80_0000);
    end
endmodule
