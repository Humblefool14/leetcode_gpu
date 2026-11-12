// ad_popcount -- number of ones of a W-bit word (common library), combinational.
// OW = clog2(W + 1) bits.  Replaces ad_gfx_popc32 (ad_su: W = 32, port m -> in, n -> count).
module ad_popcount #(
    parameter W  = 32,
    parameter OW = $clog2(W + 1)
) (
    input  wire [W-1:0]  in,
    output reg  [OW-1:0] count
);
    integer i;
    always @(*) begin
        count = {OW{1'b0}};
        for (i = 0; i < W; i = i + 1)
`ifdef MUT_POPC_SKIP0
            if (i != 0) count = count + in[i];          // mutation: bit 0 not counted
`else
            count = count + in[i];
`endif
    end
endmodule
