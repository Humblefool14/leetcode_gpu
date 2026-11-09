// ad_vf_fmt_snorm -- SNORMn -> fp32: max(c / (2^(N-1) - 1), -1.0), correctly rounded (RNE).
// c is the N-bit two's complement field.  The magnitude goes through ad_vf_fmt_unorm #(N-1);
// -2^(N-1) and -(2^(N-1) - 1) give -1.0; 0 gives +0.  Reference: tools/fmtmodel.py snorm().
module ad_vf_fmt_snorm #(
    parameter N = 8
) (
    input  wire [N-1:0] c,
    output wire [31:0]  f
);
    wire         neg = c[N-1];
    wire [N-1:0] mag = neg ? (~c + 1'b1) : c;           // -2^(N-1) -> 100..0
    wire         sat = neg && (mag[N-1] || (&mag[N-2:0]));
    wire [31:0]  u;
    ad_vf_fmt_unorm #(.N(N-1)) u_un (.c(mag[N-2:0]), .f(u));
    assign f = sat ? 32'hBF80_0000 : {neg, u[30:0]};
endmodule
