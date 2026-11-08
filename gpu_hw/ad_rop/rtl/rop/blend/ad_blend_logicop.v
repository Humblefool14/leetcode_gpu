// ad_blend_logicop -- the 16 VkLogicOps, bitwise on a 32-bit word (spec ad_rop_blend.md §4).
module ad_blend_logicop (
    input  wire [31:0] s,
    input  wire [31:0] d,
    input  wire [3:0]  op,
    output reg  [31:0] y
);
    always @(*) begin
        case (op)
            4'd0:  y = 32'd0;          // CLEAR
            4'd1:  y = s & d;          // AND
            4'd2:  y = s & ~d;         // AND_REVERSE
            4'd3:  y = s;              // COPY
            4'd4:  y = ~s & d;         // AND_INVERTED
            4'd5:  y = d;              // NO_OP
            4'd6:  y = s ^ d;          // XOR
            4'd7:  y = s | d;          // OR
            4'd8:  y = ~(s | d);       // NOR
            4'd9:  y = ~(s ^ d);       // EQUIV
            4'd10: y = ~d;             // INVERT
            4'd11: y = s | ~d;         // OR_REVERSE
            4'd12: y = ~s;             // COPY_INVERTED
            4'd13: y = ~s | d;         // OR_INVERTED
            4'd14: y = ~(s & d);       // NAND
            default: y = 32'hFFFFFFFF; // SET
        endcase
    end
endmodule
