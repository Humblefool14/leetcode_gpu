// ad_vf_fmt_unorm -- UNORMn -> fp32, correctly rounded (round to nearest even), combinational.
//
// c / (2^N - 1) in binary is the N-bit pattern c repeated forever (0.ccccc...).  The 24-bit
// significand is that stream read from c's leading one, the round bit is the next stream bit,
// and the sticky bit is 1 for every c other than 0 and 2^N - 1 (the expansion never ends), so
// an RNE tie never happens and the result is rounded up exactly when the round bit is 1.  The
// rounded significand cannot overflow: any N consecutive stream bits hold every bit of c, one
// of which is 0, so 25 ones in a row are impossible for N <= 24.  No divider.
// Reference: tools/fmtmodel.py unorm().  Supported N: 2..16 (used for 2, 8, 10, 16).
module ad_vf_fmt_unorm #(
    parameter N = 8
) (
    input  wire [N-1:0] c,
    output wire [31:0]  f
);
    localparam K = (24 + N) / N + 1;          // copies of c: K*N >= N + 24 + 1
    localparam W = K * N;

    // leading one position L; s = N-1-L is the normalising shift
    reg [4:0] s;
    integer b;
    always @(*) begin
        s = 5'd0;
        for (b = 0; b < N; b = b + 1)
            if (c[b]) s = N - 1 - b;            // last (highest) set bit wins
    end

    wire [W-1:0] pat = {K{c}};
    wire [W-1:0] sh  = pat << s;
    wire [23:0]  q   = sh[W-1 -: 24];         // significand from the leading one
    wire         rb  = sh[W-25];              // round bit (sticky is always 1)
`ifdef MUT_CONV_RND
    wire [23:0]  qr  = q;                     // mutation: truncate
`else
    wire [23:0]  qr  = q + {23'd0, rb};
`endif
    wire [7:0]   e   = 8'd126 - {3'd0, s};

    assign f = (c == {N{1'b0}}) ? 32'h0000_0000 :
               (c == {N{1'b1}}) ? 32'h3F80_0000 : {1'b0, e, qr[22:0]};
endmodule
