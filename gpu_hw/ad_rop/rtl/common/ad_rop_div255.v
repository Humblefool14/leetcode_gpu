// ad_rop_div255 -- q = round(x / 255) for 0 <= x <= 65025 (spec ad_rop_div255.md).
// One 17-bit add: q = (x + {x[15], ~x[15], x[14:8]} + x[7]) >> 8.
module ad_rop_div255 (
    input  wire [17:0] x,
    output wire [8:0]  q
);
    wire [16:0] a = {1'b0, x[15:0]};
    wire [16:0] b = {8'd0, x[15], ~x[15], x[14:8]};
    wire [16:0] s = a + b + {16'd0, x[7]};
    assign q = s[16:8];
endmodule
