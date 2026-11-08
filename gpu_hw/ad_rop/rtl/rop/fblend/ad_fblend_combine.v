// ad_fblend_combine -- VkBlendOp on one channel: 0 ADD P+Q, 1 SUBTRACT P-Q,
// 2 REVERSE_SUBTRACT Q-P, 3 MIN min(s,d), 4 MAX max(s,d) (factors ignored,
// ad_fblend_minmax), 5-7 ADD.  en = 0 (blending off): y = s.  Combinational.
module ad_fblend_combine (
    input  wire        en,
    input  wire [2:0]  op,
    input  wire [31:0] s,
    input  wire [31:0] d,
    input  wire [31:0] p,
    input  wire [31:0] q,
    output wire [31:0] y
);
    wire        rev = (op == 3'd2);
    wire [31:0] sum, mm;
    ad_fp_add        u_add (.a(rev ? q : p), .b(rev ? p : q), .sub(op == 3'd1 || op == 3'd2), .y(sum));
    ad_fblend_minmax u_mm  (.a(s), .b(d), .is_max(op == 3'd4), .y(mm));
    assign y = !en                          ? s :
               (op == 3'd3 || op == 3'd4)   ? mm : sum;
endmodule
