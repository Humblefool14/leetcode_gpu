// Formal-only blackbox of ad_fp_add: an unconstrained result every cycle
// (the depth arithmetic is irrelevant to the control properties).
module ad_fp_add (
    input  wire [31:0] a,
    input  wire [31:0] b,
    input  wire        sub,
    output wire [31:0] y
);
    (* anyseq *) reg [31:0] r;
    assign y = r;
endmodule
