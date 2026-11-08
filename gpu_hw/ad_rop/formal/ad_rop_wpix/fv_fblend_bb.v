// ad_rop_fblend black box for the ad_rop_wpix / ad_rop_wb formal harnesses: same ports,
// outputs tied off (no property here depends on path 1's datapath).
module ad_rop_fblend (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         i_valid,
    output wire         i_ready,
    input  wire [3:0]   i_lanes,
    input  wire [511:0] i_src,
    input  wire [255:0] i_dst,
    input  wire [7:0]   i_fmt,
    input  wire [22:0]  i_blend,
    input  wire [127:0] i_const,
    input  wire [3:0]   i_wm,
    output wire         o_valid,
    input  wire         o_ready,
    output wire [255:0] o_raw,
    output wire [255:0] o_keep
);
    assign i_ready = 1'b1;
    assign o_valid = 1'b0;
    assign o_raw   = 256'd0;
    assign o_keep  = {256{1'b1}};
endmodule
