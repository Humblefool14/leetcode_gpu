// ad_rop_blend -- unorm8 blend pipeline of the ROP (spec spec/gpu/rop/ad_rop_blend.md).
// b_rvalid / b_pix exactly LAT (default 3) cycles after b_valid; one beat every cycle, no stall.
// ad_blend_state holds the STATE words and selects the attachment b_rt; ad_blend_pipe is the
// 3-stage datapath (the beat's state travels with it).  LAT > 3 adds output delay registers;
// LAT < 3 is not supported (behaves as 3).
`include "ad_rop_state.vh"
module ad_rop_blend #(
    parameter LAT = 3
) (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         st_we,
    input  wire [8:0]   st_idx,
    input  wire [31:0]  st_wdata,
    input  wire         b_valid,
    input  wire [511:0] b_src,
    input  wire [511:0] b_src1,
    input  wire         b_has_src1,
    input  wire [127:0] b_dst,
    input  wire [3:0]   b_mask,
    input  wire [1:0]   b_rt,
    output wire         b_rvalid,
    output wire [127:0] b_pix
);
    wire [26:0] s_blend; wire [7:0] s_fmt; wire [3:0] s_wm, s_lop;
    wire        s_lo, s_dual; wire [31:0] s_k;

    ad_blend_state u_state (
        .clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata),
        .rt(b_rt), .blend(s_blend), .fmt(s_fmt), .wmask(s_wm), .lop_en(s_lo), .lop_op(s_lop),
        .kconst(s_k), .dual(s_dual));

    wire         p_valid;
    wire [127:0] p_pix;
    ad_blend_pipe #(.NLANE(4)) u_pipe (
        .clk(clk), .rst_n(rst_n), .in_valid(b_valid), .src(b_src), .src1(b_src1),
        .has_src1(b_has_src1), .dst(b_dst), .mask(b_mask),
        .blend(s_blend), .fmt(s_fmt), .wmask(s_wm), .lop_en(s_lo), .lop_op(s_lop),
        .kconst(s_k), .dual(s_dual), .out_valid(p_valid), .pix(p_pix));

    generate
        if (LAT > 3) begin : g_dly
            reg [LAT-4:0]  vd;
            reg [127:0]    pd [0:LAT-4];
            integer j;
            always @(posedge clk) begin
                if (!rst_n) vd <= {(LAT-3){1'b0}};
                else        vd <= (vd << 1) | {{(LAT-4){1'b0}}, p_valid};
            end
            always @(posedge clk) begin
                pd[0] <= p_pix;
                for (j = 1; j <= LAT - 4; j = j + 1) pd[j] <= pd[j-1];
            end
            assign b_rvalid = vd[LAT-4];
            assign b_pix    = pd[LAT-4];
        end else begin : g_nodly
            assign b_rvalid = p_valid;
            assign b_pix    = p_pix;
        end
    endgenerate
endmodule
