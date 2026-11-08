// ad_fblend_f2h -- fp32 to fp16, round to nearest even.  fp16 subnormals are
// produced, overflow gives +-inf, NaN gives 0x7E00, the sign of zero is kept.
// fp32 denormal inputs are below 2^-126 and give a signed zero.  Combinational.
module ad_fblend_f2h (
    input  wire [31:0] f,
    output wire [15:0] h
);
    wire        s  = f[31];
    wire [7:0]  e  = f[30:23];
    wire [22:0] fr = f[22:0];
    wire [23:0] m  = {1'b1, fr};
    wire        is_nan = (e == 8'hFF) && (fr != 23'd0);
    wire        is_inf = (e == 8'hFF) && (fr == 23'd0);
    // normal range (e >= 113, i.e. >= 2^-14): {he, frac10} + round, carry may
    // reach the exponent; any result >= 0x7C00 is infinity
    wire        big  = (e >= 8'd143);                  // >= 2^16: inf even before rounding
    wire [4:0]  he   = e[4:0] - 5'd16;                 // e - 112 (mod 32) for 113 <= e <= 142 (5 bits)
    wire        g_n  = fr[12];
    wire        st_n = |fr[11:0];
    wire        up_n = g_n & (st_n | fr[13]);
    wire [15:0] v_n  = {1'b0, he, fr[22:13]} + {15'd0, up_n};
    wire [14:0] r_n  = (big || v_n[15] || (v_n[14:0] >= 15'h7C00)) ? 15'h7C00 : v_n[14:0];
    // subnormal range (e <= 112): q = m >> sh, sh = 126 - e in 14..24; e < 101 -> 0
    wire        zero_s = (e < 8'd101);
    wire [4:0]  sh   = 5'd14 + (5'd16 - e[4:0]);       // valid for 101 <= e <= 112
    wire [47:0] w    = {m, 24'd0} >> sh;
    wire [10:0] q    = w[34:24];                        // at most 10 significant bits
    wire        g_s  = w[23];
    wire        st_s = |w[22:0];
    wire        up_s = g_s & (st_s | q[0]);
    wire [10:0] r_s  = zero_s ? 11'd0 : (q + {10'd0, up_s});  // 1024 = min normal, encodes correctly
    assign h = is_nan          ? 16'h7E00 :
               is_inf          ? {s, 15'h7C00} :
               (e == 8'd0)     ? {s, 15'd0} :
               (e >= 8'd113)   ? {s, r_n} :
                                 {s, 4'd0, r_s};
endmodule
