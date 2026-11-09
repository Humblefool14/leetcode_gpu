// fv_ad_vf_fmt_snorm -- ad_vf_fmt_snorm #(N) against a multiply-check reference:
// v = signed c, D = 2^(N-1) - 1.  v <= -D -> -1.0; v == 0 -> +0; v == D -> 1.0; otherwise
// sign(v) and |v| / D correctly rounded: (2q - 1) * D < |v| * 2^(k+1) < (2q + 1) * D for the
// result q * 2^-k (q = 1.mantissa).  Input: anyconst c (all codes).
module fv_ad_vf_fmt_snorm #(
    parameter N = 8
) (
    input wire clk
);
    (* anyconst *) reg [N-1:0] c;
    wire [31:0] f;
    ad_vf_fmt_snorm #(.N(N)) dut (.c(c), .f(f));

    localparam [63:0] D = (64'd1 << (N - 1)) - 64'd1;
    wire        neg = c[N-1];
    wire [63:0] mg  = neg ? ((64'd1 << N) - {{(64-N){1'b0}}, c}) : {{(64-N){1'b0}}, c};   // |v|
    wire [7:0]  e  = f[30:23];
    wire [63:0] q  = {40'd0, 1'b1, f[22:0]};
    wire [7:0]  k  = 8'd150 - e;
    wire [63:0] lo = (2 * q - 64'd1) * D;
    wire [63:0] hi = (2 * q + 64'd1) * D;
    wire [63:0] md = mg << (k + 8'd1);

    always @(*) begin
        if (neg && mg >= D)  a_m1:   assert (f == 32'hBF80_0000);
        else if (mg == 64'd0) a_zero: assert (f == 32'h0000_0000);
        else if (mg == D)     a_one:  assert (f == 32'h3F80_0000);
        else begin
            a_sign:  assert (f[31] == neg);
            a_range: assert (e <= 8'd126 && e >= 8'd128 - N);
            a_rne:   assert (lo < md && md < hi);
        end
    end
endmodule
