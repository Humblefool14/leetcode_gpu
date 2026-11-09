// ad_su_alu_lane -- one lane of the integer ALU (combinational leaf of ad_su_alu).
// Semantics of tools/gsi1model.py alu(): op = AD_ALU_* (5 bits); b is already
// the immediate for the I forms (the parent's mux); compares give all ones or 0.
module ad_su_alu_lane (
    input  wire [4:0]  op,
    input  wire [31:0] a,
    input  wire [31:0] b,
    input  wire [31:0] c,
    input  wire [31:0] imm,
    output reg  [31:0] r
);
`include "ad_su_uop.vh"
    wire        lt_s = $signed(a) < $signed(b);
    wire        lt_u = a < b;
    wire [4:0]  sh = b[4:0];
    always @(*) begin
        case (op)
        AD_ALU_ADD:  r = a + b;
        AD_ALU_SUB:  r = a - b;
        AD_ALU_SLL:  r = a << sh;
        AD_ALU_SLT:  r = {32{lt_s}};
        AD_ALU_SLTU: r = {32{lt_u}};
        AD_ALU_XOR:  r = a ^ b;
        AD_ALU_SRL:  r = a >> sh;
        AD_ALU_SRA:  r = $unsigned($signed(a) >>> sh);
        AD_ALU_OR:   r = a | b;
        AD_ALU_AND:  r = a & b;
        AD_ALU_MIN:  r = lt_s ? a : b;
        AD_ALU_MAX:  r = lt_s ? b : a;
        AD_ALU_MINU: r = lt_u ? a : b;
        AD_ALU_MAXU: r = lt_u ? b : a;
        AD_ALU_ANDN: r = a & ~b;
        AD_ALU_ORN:  r = a | ~b;
        AD_ALU_XNOR: r = ~(a ^ b);
        AD_ALU_SEL:  r = (a & b) | (~a & c);
        AD_ALU_MOVI: r = imm;
        default:     r = 32'd0;
        endcase
    end
endmodule
