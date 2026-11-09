// fv_ad_vf_fmt_unorm -- ad_vf_fmt_unorm #(N) against a multiply-check reference (no repeated-pattern
// reasoning): for 0 < c < D = 2^N - 1 the result must be a positive normal fp32 q * 2^-k
// (q = 1.mantissa as a 24-bit integer) with (2q - 1) * D < c * 2^(k+1) < (2q + 1) * D, i.e. q is
// c * 2^k / D rounded to nearest (no ties: D is odd).  This bracket fixes q and k uniquely, so it is
// exactly the correctly rounded (RNE) value; c = 0 -> +0, c = D -> 1.0.  Input: anyconst c (all codes).
module fv_ad_vf_fmt_unorm #(
    parameter N = 8
) (
    input wire clk
);
    (* anyconst *) reg [N-1:0] c;
    wire [31:0] f;
    ad_vf_fmt_unorm #(.N(N)) dut (.c(c), .f(f));

    localparam [63:0] D = (64'd1 << N) - 64'd1;
    wire [7:0]  e  = f[30:23];
    wire [63:0] q  = {40'd0, 1'b1, f[22:0]};
    wire [7:0]  k  = 8'd150 - e;
    wire [63:0] cc = {{(64-N){1'b0}}, c};
    wire [63:0] lo = (2 * q - 64'd1) * D;
    wire [63:0] hi = (2 * q + 64'd1) * D;
    wire [63:0] md = cc << (k + 8'd1);

    always @(*) begin
        if (cc == 64'd0) a_zero: assert (f == 32'h0000_0000);
        else if (cc == D) a_one: assert (f == 32'h3F80_0000);
        else begin
            a_sign:  assert (f[31] == 1'b0);
            a_range: assert (e <= 8'd126 && e >= 8'd127 - N);     // c/D in [2^-N, 1)
            a_rne:   assert (lo < md && md < hi);
        end
    end
endmodule
