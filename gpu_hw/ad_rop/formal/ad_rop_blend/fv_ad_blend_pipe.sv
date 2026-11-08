// fv_ad_blend_pipe -- ad_blend_pipe alone with free selected-state inputs (the state module is
// proven in formal/ad_blend_state), NLANE lanes of datapath (FV_NLANE, default 1); the same
// properties as fv_ad_rop_blend (datapath ones on lanes < NLANE).  Purely feed-forward, so
// k-induction closes once its depth exceeds the pipeline's.
`include "ad_rop_state.vh"
`ifndef FV_NLANE
`define FV_NLANE 1
`endif
module fv_ad_blend_pipe (
    input wire         clk,
    input wire         rst_n,
    input wire         b_valid,
    input wire [511:0] b_src,
    input wire [511:0] b_src1,
    input wire         b_has_src1,
    input wire [127:0] b_dst,
    input wire [3:0]   b_mask,
    input wire [26:0]  c_blend,
    input wire [7:0]   c_fmt,
    input wire [3:0]   c_wm,
    input wire         c_lo,
    input wire [3:0]   c_lop,
    input wire [31:0]  c_k,
    input wire         c_dual
);
    localparam NL = `FV_NLANE;
    reg init = 1'b1;
    always @(posedge clk) init <= 1'b0;
    always @(*) if (init) assume (!rst_n);
    wire b_rvalid; wire [127:0] b_pix;
    ad_blend_pipe #(.NLANE(NL)) dut (.clk(clk), .rst_n(rst_n), .in_valid(b_valid), .src(b_src),
        .src1(b_src1), .has_src1(b_has_src1), .dst(b_dst), .mask(b_mask), .blend(c_blend),
        .fmt(c_fmt), .wmask(c_wm), .lop_en(c_lo), .lop_op(c_lop), .kconst(c_k), .dual(c_dual),
        .out_valid(b_rvalid), .pix(b_pix));
`include "fv_props.vh"
endmodule
