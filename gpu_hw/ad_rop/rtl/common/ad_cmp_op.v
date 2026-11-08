// ad_cmp_op -- VkCompareOp evaluated on the flags of "new OP reference".
// 0 NEVER, 1 LESS, 2 EQUAL, 3 LESS_OR_EQUAL, 4 GREATER, 5 NOT_EQUAL,
// 6 GREATER_OR_EQUAL, 7 ALWAYS.  Unordered (NaN): only NOT_EQUAL and ALWAYS pass.
module ad_cmp_op (
    input  wire [2:0] op,
    input  wire       lt,
    input  wire       eq,
    input  wire       un,
    output reg        pass
);
    wire gt = !lt && !eq && !un;
    always @(*) begin
        case (op)
            3'd0: pass = 1'b0;
            3'd1: pass = lt;
            3'd2: pass = eq;
            3'd3: pass = lt | eq;
            3'd4: pass = gt;
            3'd5: pass = !eq;
            3'd6: pass = gt | eq;
            default: pass = 1'b1;
        endcase
    end
endmodule
