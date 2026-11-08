// ad_hazard_prienc -- lowest-index set-bit priority encoder (leaf of ad_rop_hazard).
// any = |req; idx = index of the lowest set bit of req (0 when none).
module ad_hazard_prienc #(
    parameter N   = 16,
    parameter IDX_W = 4
) (
    input  wire [N-1:0]     req,
    output reg              any,
    output reg  [IDX_W-1:0] idx
);
    integer i;
    always @(*) begin
        any = 1'b0;
        idx = {IDX_W{1'b0}};
        // scan from the top so that the lowest set bit wins
        for (i = N-1; i >= 0; i = i - 1)
            if (req[i]) begin
                any = 1'b1;
                idx = i[IDX_W-1:0];
            end
    end
endmodule
