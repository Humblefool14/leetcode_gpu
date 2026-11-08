// ad_blend_op8 -- VkBlendOp of one channel from the two products (spec ad_rop_blend.md §4).
// ts = div255(ps), td = div255(pd) (ps, pd <= 65025: 8x8-bit products).
// ADD min(255, ts+td); SUBTRACT max(0, ts-td); REVERSE_SUBTRACT max(0, td-ts);
// MIN min(s, d); MAX max(s, d) (factors ignored); ops 5..7 = ADD.
`include "ad_rop_state.vh"
module ad_blend_op8 (
    input  wire [15:0] ps,
    input  wire [15:0] pd,
    input  wire [7:0]  s,
    input  wire [7:0]  d,
    input  wire [2:0]  op,
    output reg  [7:0]  y
);
    wire [8:0] ts, td;
    ad_rop_div255 u_ts (.x({2'b00, ps}), .q(ts));
    ad_rop_div255 u_td (.x({2'b00, pd}), .q(td));
    wire [9:0] sum  = {1'b0, ts} + {1'b0, td};
    wire [7:0] dsub = ts[7:0] - td[7:0];   // ts, td <= 255
    wire [7:0] rsub = td[7:0] - ts[7:0];
    always @(*) begin
        case (op)
            `AD_BO_SUB:  y = (ts > td) ? dsub : 8'd0;
            `AD_BO_RSUB: y = (td > ts) ? rsub : 8'd0;
            `AD_BO_MIN:  y = (s < d) ? s : d;
            `AD_BO_MAX:  y = (s > d) ? s : d;
            default:     y = (sum > 10'd255) ? 8'hFF : sum[7:0];
        endcase
    end
endmodule
