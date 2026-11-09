// ad_vf_fmt_h2f -- fp16 -> fp32 exactly, combinational.  Denormals become normal fp32,
// infinities are kept, any NaN becomes 0x7FC00000, zeros keep their sign.
// Reference: tools/fmtmodel.py h2f().
module ad_vf_fmt_h2f (
    input  wire [15:0] h,
    output reg  [31:0] f
);
    wire       s = h[15];
    wire [4:0] e = h[14:10];
    wire [9:0] m = h[9:0];

    // denormal: leading one of m at p (0..9) -> exponent p + 103, fraction m << (10 - p)
    reg [3:0] p;
    integer b;
    always @(*) begin
        p = 4'd0;
        for (b = 0; b < 10; b = b + 1)
            if (m[b]) p = b;
    end
    wire [19:0] mn = {10'd0, m} << (4'd10 - p);   // the leading one lands at bit 10

    always @(*) begin
        if (e == 5'd31)
            f = (m != 10'd0) ? 32'h7FC0_0000 : {s, 8'hFF, 23'd0};
        else if (e == 5'd0)
            f = (m == 10'd0) ? {s, 31'd0} : {s, 8'd103 + {4'd0, p}, mn[9:0], 13'd0};
        else
            f = {s, {3'd0, e} + 8'd112, m, 13'd0};
    end
endmodule
