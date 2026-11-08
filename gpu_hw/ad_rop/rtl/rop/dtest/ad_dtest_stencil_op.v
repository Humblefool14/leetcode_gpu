// ad_dtest_stencil_op -- VkStencilOp on an 8-bit stencil value.  Combinational.
// 0 KEEP, 1 ZERO, 2 REPLACE (reference), 3 INCREMENT_AND_CLAMP, 4 DECREMENT_AND_CLAMP,
// 5 INVERT, 6 INCREMENT_AND_WRAP, 7 DECREMENT_AND_WRAP.
// MUT_STENCIL_WRAP: the wrap ops behave as the clamp ops (deliberate error for the TB).
module ad_dtest_stencil_op (
    input  wire [2:0] op,
    input  wire [7:0] s,      // stored stencil s_a
    input  wire [7:0] sref,   // reference
    output reg  [7:0] n       // new stencil
);
    wire [7:0] inc_c = (s == 8'hFF) ? 8'hFF : s + 8'd1;
    wire [7:0] dec_c = (s == 8'h00) ? 8'h00 : s - 8'd1;
    always @(*) begin
        case (op)
            3'd0: n = s;
            3'd1: n = 8'h00;
            3'd2: n = sref;
            3'd3: n = inc_c;
            3'd4: n = dec_c;
            3'd5: n = ~s;
`ifdef MUT_STENCIL_WRAP
            3'd6: n = inc_c;
            default: n = dec_c;
`else
            3'd6: n = s + 8'd1;
            default: n = s - 8'd1;
`endif
        endcase
    end
endmodule
