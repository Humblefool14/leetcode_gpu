// ad_vf_vc_penc -- priority encoder, combinational: idx = position of the lowest set bit of req,
// any = |req (idx = 0 when req = 0).  Used for the hit slot (at most one bit set) and for the
// lowest unused entry.
module ad_vf_vc_penc #(
    parameter N   = 32,
    parameter IDX_W = 5
) (
    input  wire [N-1:0]     req,
    output reg  [IDX_W-1:0] idx,
    output wire             any
);
    integer b;
    always @(*) begin
        idx = {IDX_W{1'b0}};
        for (b = N - 1; b >= 0; b = b - 1)
            if (req[b]) idx = b;
    end
    assign any = |req;
endmodule
