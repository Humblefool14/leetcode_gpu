// ad_rop_f2u8 -- fp32 to unorm8, u = RNE(clamp01(f) * 255)  (spec ad_rop_f2u8.md).
// NaN, f <= 0 (-0 included), denormals and f < 2^-10 give 0; f >= 1 and +inf give 255.
module ad_rop_f2u8 (
    input  wire [31:0] f,
    output wire [7:0]  u
);
    wire       s = f[31];
    wire [7:0] e = f[30:23];
    wire [22:0] fr = f[22:0];
    wire       is_nan = (e == 8'hFF) && (fr != 0);
    wire       ge1    = (e >= 8'd127);           // includes +inf
    wire       tiny  = (e <  8'd117);           // below 2^-10 (and denormals, zero)

    wire [23:0] m  = {1'b1, fr};
    wire [31:0] p  = {m, 8'd0} - {8'd0, m};     // m * 255
    wire [3:0]  sh = 8'd126 - e;                // 0..9 when 117 <= e <= 126
    wire [41:0] t  = {p, 10'd0} >> sh;
    wire [7:0]  ip = t[41:34];
    wire        rb = t[33];
    wire        st = |t[32:0];
    wire        up = rb & (st | ip[0]);
    wire [8:0]  r  = {1'b0, ip} + {8'd0, up};   // never exceeds 255 for f < 1

    assign u = (is_nan | s | tiny) ? 8'd0 :
               ge1                  ? 8'd255 :
                                      r[7:0];
endmodule
