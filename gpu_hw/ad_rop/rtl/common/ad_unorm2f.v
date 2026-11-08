// ad_unorm2f -- N-bit UNORM to fp32, f = RNE(x / (2^N - 1)), 2 <= N <= 24.
// x / (2^N - 1) = 0.xxxx xxxx ... (the N bits of x repeated), so the mantissa is
// the repeating pattern after the leading one, rounded with an always-nonzero
// sticky (the expansion never terminates for 0 < x < 2^N - 1).
module ad_unorm2f #(parameter N = 24) (
    input  wire [N-1:0] x,
    output wire [31:0]  f
);
    localparam R = (25 + 2*N + N - 1) / N;      // repetitions so the pattern covers 26 bits after any shift
    wire [N*R-1:0] rep = {R{x}};
    reg  [4:0] lz;                              // leading zeros of x (x != 0)
    integer i;
    always @(*) begin
        lz = 5'd0;
        for (i = 0; i < N; i = i + 1)
            if (x[i]) lz = N - 1 - i[4:0];
    end
    wire [N*R-1:0] sh = rep << lz;              // leading one at the top
    wire [23:0] m  = sh[N*R-1 -: 24];
    wire        g  = sh[N*R-25];
    wire        up = g;                         // sticky is always 1 here (non-terminating), never a tie
    wire [24:0] mr = {1'b0, m} + {24'd0, up};
    wire        mo = mr[24];
    wire [7:0]  e  = 8'd126 - {3'd0, lz} + (mo ? 8'd1 : 8'd0);
    wire [22:0] fr = mo ? mr[23:1] : mr[22:0];
    assign f = (x == 0)          ? 32'd0 :
               (x == {N{1'b1}})  ? 32'h3F80_0000 :
                                   {1'b0, e, fr};
endmodule
