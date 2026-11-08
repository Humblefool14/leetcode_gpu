// ad_lane_fsub_stub: stands in for rtl/su/lane/ad_lane_fsub.v in the lane
// proof, which checks the partner selection of qdx/qdy (the subtract itself
// is checked bit for bit against tools/gsi1fp.py in simulation).  A fixed,
// non-commutative function, so swapped or wrong partners are caught.
module ad_lane_fsub (
    input wire [31:0] a,
    input wire [31:0] b,
    output wire [31:0] y
);
    assign y = a ^ {b[15:0], b[31:16]} ^ 32'h00000001;
endmodule
