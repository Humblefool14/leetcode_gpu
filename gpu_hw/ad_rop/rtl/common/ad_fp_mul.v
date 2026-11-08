// ad_fp_mul -- fp32 multiply, round to nearest even, denormals flushed
// (inputs; a result below 2^-126 before rounding is flushed to a signed zero).
// NaN results are 0x7FC00000; 0 x inf is NaN.  Combinational.
module ad_fp_mul (
    input  wire [31:0] a,
    input  wire [31:0] b,
    output wire [31:0] y
);
    wire        s  = a[31] ^ b[31];
    wire [7:0]  ea = a[30:23];
    wire [7:0]  eb = b[30:23];
    wire        za = (ea == 8'd0);
    wire        zb = (eb == 8'd0);
    wire        ia = (ea == 8'hFF) && (a[22:0] == 0);
    wire        ib = (eb == 8'hFF) && (b[22:0] == 0);
    wire        na = (ea == 8'hFF) && (a[22:0] != 0);
    wire        nb = (eb == 8'hFF) && (b[22:0] != 0);

    wire [47:0] p  = {1'b1, a[22:0]} * {1'b1, b[22:0]};
    wire        hi = p[47];
    // 24-bit mantissa + guard + sticky
    wire [23:0] m  = hi ? p[47:24] : p[46:23];
    wire        g  = hi ? p[23]    : p[22];
    wire        st = hi ? (|p[22:0]) : (|p[21:0]);
    wire signed [10:0] e0 = $signed({3'b0, ea}) + $signed({3'b0, eb}) - 11'sd127 + (hi ? 11'sd1 : 11'sd0);
    wire        up = g & (st | m[0]);
    wire [24:0] mr = {1'b0, m} + {24'd0, up};
    wire        mo = mr[24];
    wire signed [10:0] ef = e0 + (mo ? 11'sd1 : 11'sd0);
    wire [22:0] frac = mo ? mr[23:1] : mr[22:0];

    wire res_nan = na | nb | (ia & zb) | (ib & za);
    wire res_inf = ia | ib;
    wire res_zero = za | zb;

    assign y = res_nan           ? 32'h7FC0_0000 :
               res_inf           ? {s, 8'hFF, 23'd0} :
               res_zero          ? {s, 31'd0} :
               (e0 <= 11'sd0)    ? {s, 31'd0} :          // flush before rounding
               (ef >= 11'sd255)  ? {s, 8'hFF, 23'd0} :
                                   {s, ef[7:0], frac};
endmodule
