// ad_fp_cmp -- fp32 ordering of a against b: lt, eq, un (unordered: a NaN).
// -0 equals +0; denormals are ordered by value (no flush).  Combinational.
module ad_fp_cmp (
    input  wire [31:0] a,
    input  wire [31:0] b,
    output wire        lt,
    output wire        eq,
    output wire        un
);
    wire na = (a[30:23] == 8'hFF) && (a[22:0] != 0);
    wire nb = (b[30:23] == 8'hFF) && (b[22:0] != 0);
    // order key: monotonic unsigned image of the value, both zeros -> 0x80000000
    wire [31:0] ka = (a[30:0] == 0) ? 32'h8000_0000 : (a[31] ? ~a : {1'b1, a[30:0]});
    wire [31:0] kb = (b[30:0] == 0) ? 32'h8000_0000 : (b[31] ? ~b : {1'b1, b[30:0]});
    assign un = na | nb;
    assign lt = !un && (ka <  kb);
    assign eq = !un && (ka == kb);
endmodule
