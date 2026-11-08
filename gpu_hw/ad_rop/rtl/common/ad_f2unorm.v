// ad_f2unorm -- fp32 to N-bit UNORM: u = RNE(clamp01(f) * (2^N - 1)), 1 <= N <= 24.
// NaN, negatives and -0 give 0; f >= 1 and +inf give 2^N - 1; denormals give 0.
module ad_f2unorm #(parameter N = 16) (
    input  wire [31:0]  f,
    output wire [N-1:0] u
);
    localparam [N:0] MAXV = {1'b0, {N{1'b1}}};
    wire [7:0]  e  = f[30:23];
    wire        is_nan = (e == 8'hFF) && (f[22:0] != 0);
    wire        ge1    = (e >= 8'd127);
    wire [23:0] m  = {1'b1, f[22:0]};
    // p = m * (2^N - 1) = (m << N) - m, N+24 bits
    wire [N+23:0] p = ({{N{1'b0}}, m} << N) - {{N{1'b0}}, m};
    // value = p * 2^(e-150); shift right by sh = 150 - e (>= 24 for f < 1)
    wire [8:0]  sh = 9'd150 - {1'b0, e};
    wire        tiny = (sh > (N + 25));           // value < 1/4 : rounds to 0
    // keep: integer part, round bit, sticky
    wire [2*N+49:0] w  = {p, {(N+26){1'b0}}} >> (tiny ? 9'd0 : sh);
    wire [N-1:0] ip = w[2*N+25:N+26];
    wire        rb = w[N+25];
    wire        st = |w[N+24:0];
    wire        up = rb & (st | ip[0]);
    wire [N:0]  r  = {1'b0, ip} + {{N{1'b0}}, up};
    assign u = (is_nan | f[31] | (e == 8'd0)) ? {N{1'b0}} :
               ge1  ? {N{1'b1}} :
               tiny ? {N{1'b0}} : r[N-1:0];
endmodule
