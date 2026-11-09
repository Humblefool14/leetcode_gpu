// fv_ad_core_alu_lane -- every ALU op of ad_su_alu_lane against a reference
// expression written from tools/gsi1model.py alu() (independent of the RTL).
module fv_ad_core_alu_lane (input wire clk);
    (* anyconst *) reg [4:0]  op;
    (* anyconst *) reg [31:0] a, b, c, imm;
    wire [31:0] r;
    ad_su_alu_lane dut (.op(op), .a(a), .b(b), .c(c), .imm(imm), .r(r));
    wire signed [32:0] sa = {a[31], a}, sb = {b[31], b};
    reg [31:0] e;
    always @(*) begin
        case (op)
        0: e = a + b;  1: e = a + ~b + 1;  2: e = a << b[4:0];
        3: e = (sa < sb) ? 32'hFFFFFFFF : 32'h0;   4: e = ({1'b0, a} < {1'b0, b}) ? 32'hFFFFFFFF : 32'h0;
        5: e = a ^ b;  6: e = a >> b[4:0];  7: e = ({{32{a[31]}}, a} >> b[4:0]);
        8: e = a | b;  9: e = a & b;
        10: e = (sa < sb) ? a : b;  11: e = (sa < sb) ? b : a;
        12: e = (a < b) ? a : b;    13: e = (a < b) ? b : a;
        14: e = a & ~b; 15: e = a | ~b; 16: e = ~a ^ b; 17: e = (a & b) | (~a & c);
        18: e = imm;   default: e = 32'h0;
        endcase
        assert (r == e);
    end
endmodule
