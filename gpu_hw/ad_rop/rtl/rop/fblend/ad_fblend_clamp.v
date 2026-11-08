// ad_fblend_clamp -- clamp an fp32 value to [0, 1] when en (fixed-point target):
// NaN and negatives (-0 included) -> +0, values above 1.0 (+inf included) -> 1.0,
// otherwise unchanged (positive denormals pass).  en = 0: y = x.  Combinational.
module ad_fblend_clamp (
    input  wire        en,
    input  wire [31:0] x,
    output wire [31:0] y
);
    wire is_nan = (x[30:23] == 8'hFF) && (x[22:0] != 23'd0);
    assign y = !en                  ? x :
               (is_nan || x[31])    ? 32'h0000_0000 :
               (x > 32'h3F80_0000)  ? 32'h3F80_0000 : x;
endmodule
