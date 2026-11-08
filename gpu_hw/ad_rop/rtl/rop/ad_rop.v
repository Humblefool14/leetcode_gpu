// ad_rop -- the ROP / buffer writer (spec ad_rop.md): wiring only.
//   ad_rop_order -> ad_rop_ms -> ad_rop_ds -> ad_rop_wb (+ad_rop_wpix/fblend) <-> ad_rop_blend
//   ad_rop_occ counts the first beats leaving ad_rop_ds; ad_amb_mux: ds = requester 0, wb = 1.
`include "ad_rop_state.vh"
module ad_rop #(
    parameter ADDR_W     = 32,
    parameter LINE_BYTES = 32,
    parameter LINE_SHIFT = 5,
    parameter STENCIL    = 1
) (
    input  wire                          clk,
    input  wire                          rst_n,
    // STATE broadcast
    input  wire                          st_we,
    input  wire [8:0]                    st_idx,
    input  wire [31:0]                   st_wdata,
    output wire                          busy,
    // fragment output of SU 0
    input  wire                          ex_valid,
    output wire                          ex_ready,
    input  wire [15:0]                   ex_seq,
    input  wire [31:0]                   ex_xy,
    input  wire [3:0]                    ex_mask,
    input  wire [511:0]                  ex_color,
    input  wire [127:0]                  ex_depth,
    input  wire                          ex_last,
    input  wire [153:0]                  ex_aux,
    output wire [15:0]                   ex_next,
    // direct fragments (DEBUG_COLOR)
    input  wire                          dx_valid,
    output wire                          dx_ready,
    input  wire [15:0]                   dx_seq,
    input  wire [31:0]                   dx_xy,
    input  wire [3:0]                    dx_mask,
    input  wire [127:0]                  dx_depth,
    input  wire                          dx_last,
    // issued sequence numbers
    input  wire                          ord_valid,
    input  wire [15:0]                   ord_seq,
    // occlusion
    output wire [39:0]                   occ_count,
    input  wire                          occ_clear,
    // AMB client port
    output wire                          req_valid,
    input  wire                          req_ready,
    output wire                          req_write,
    output wire [ADDR_W-LINE_SHIFT-1:0]  req_line,
    output wire [LINE_BYTES-1:0]         req_be,
    output wire [LINE_BYTES*8-1:0]       req_wdata,
    output wire [7:0]                    req_tag,
    input  wire                          rsp_valid,
    input  wire                          rsp_write,
    input  wire [7:0]                    rsp_tag,
    input  wire [LINE_BYTES*8-1:0]       rsp_rdata,
    input  wire                          rsp_error
);
    localparam LW = ADDR_W - LINE_SHIFT;

    // ---------------- order -> ms ----------------
    wire         or_valid, or_ready, or_dbg, or_busy;
    wire [31:0]  or_xy;
    wire [3:0]   or_mask;
    wire [511:0] or_color;
    wire [127:0] or_depth;
    wire [153:0] or_aux;

    ad_rop_order u_order (
        .clk(clk), .rst_n(rst_n),
        .ex_valid(ex_valid), .ex_ready(ex_ready), .ex_seq(ex_seq), .ex_xy(ex_xy), .ex_mask(ex_mask),
        .ex_color(ex_color), .ex_depth(ex_depth), .ex_last(ex_last), .ex_aux(ex_aux), .ex_next(ex_next),
        .dx_valid(dx_valid), .dx_ready(dx_ready), .dx_seq(dx_seq), .dx_xy(dx_xy), .dx_mask(dx_mask),
        .dx_depth(dx_depth), .dx_last(dx_last),
        .ord_valid(ord_valid), .ord_seq(ord_seq),
        .o_valid(or_valid), .o_ready(or_ready), .o_xy(or_xy), .o_mask(or_mask), .o_color(or_color),
        .o_depth(or_depth), .o_dbg(or_dbg), .o_aux(or_aux), .busy(or_busy)
    );

    // ---------------- ms -> ds ----------------
    wire         ms_valid, ms_ready, ms_dbg, ms_front, ms_busy;
    wire [31:0]  ms_xy;
    wire [15:0]  ms_smask;
    wire [511:0] ms_color, ms_sdepth;
    wire [3:0]   ms_beat;

    ad_rop_ms u_ms (
        .clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata),
        .i_valid(or_valid), .i_ready(or_ready), .i_xy(or_xy), .i_mask(or_mask), .i_color(or_color),
        .i_depth(or_depth), .i_dbg(or_dbg), .i_aux(or_aux),
        .o_valid(ms_valid), .o_ready(ms_ready), .o_xy(ms_xy), .o_smask(ms_smask), .o_color(ms_color),
        .o_sdepth(ms_sdepth), .o_dbg(ms_dbg), .o_front(ms_front), .o_beat(ms_beat), .busy(ms_busy)
    );

    // ---------------- ds -> wb, occ ----------------
    wire         ds_valid, ds_ready, ds_busy;
    wire [31:0]  ds_xy;
    wire [15:0]  ds_smask;
    wire [511:0] ds_color;
    wire [3:0]   ds_beat;
    wire          ds_req_valid, ds_req_ready, ds_req_write, ds_rsp_valid, ds_rsp_write, ds_rsp_error;
    wire [LW-1:0] ds_req_line;
    wire [LINE_BYTES-1:0]   ds_req_be;
    wire [LINE_BYTES*8-1:0] ds_req_wdata, ds_rsp_rdata;
    wire [7:0]    ds_req_tag, ds_rsp_tag;

    ad_rop_ds #(.ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT), .STENCIL(STENCIL)) u_ds (
        .clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata),
        .q_valid(ms_valid), .q_ready(ms_ready), .q_xy(ms_xy), .q_smask(ms_smask), .q_color(ms_color),
        .q_sdepth(ms_sdepth), .q_dbg(ms_dbg), .q_front(ms_front), .q_beat(ms_beat),
        .d_valid(ds_valid), .d_ready(ds_ready), .d_xy(ds_xy), .d_smask(ds_smask), .d_color(ds_color),
        .d_beat(ds_beat), .busy(ds_busy),
        .req_valid(ds_req_valid), .req_ready(ds_req_ready), .req_write(ds_req_write), .req_line(ds_req_line),
        .req_be(ds_req_be), .req_wdata(ds_req_wdata), .req_tag(ds_req_tag),
        .rsp_valid(ds_rsp_valid), .rsp_write(ds_rsp_write), .rsp_tag(ds_rsp_tag), .rsp_rdata(ds_rsp_rdata),
        .rsp_error(ds_rsp_error)
    );

    // occlusion: the first beat of each quad, its passing samples
    wire [4:0] ds_pop;
    assign ds_pop = ds_smask[0]  + ds_smask[1]  + ds_smask[2]  + ds_smask[3]
                  + ds_smask[4]  + ds_smask[5]  + ds_smask[6]  + ds_smask[7]
                  + ds_smask[8]  + ds_smask[9]  + ds_smask[10] + ds_smask[11]
                  + ds_smask[12] + ds_smask[13] + ds_smask[14] + ds_smask[15];
`ifdef MUT_OCC_BEAT
    wire occ_inc = ds_valid && ds_ready;                 // mutation: every beat counted
`else
    wire occ_inc = ds_valid && ds_ready && ds_beat[0];
`endif
    ad_rop_occ u_occ (
        .clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata),
        .inc_valid(occ_inc), .inc_n(ds_pop), .clear(occ_clear), .count(occ_count)
    );

    // ---------------- wb <-> blend ----------------
    wire         b_valid, b_rvalid, wb_busy;
    wire [511:0] b_src;
    wire [127:0] b_dst, b_pix;
    wire [3:0]   b_mask;
    wire [1:0]   b_rt;
    wire          wb_req_valid, wb_req_ready, wb_req_write, wb_rsp_valid, wb_rsp_write, wb_rsp_error;
    wire [LW-1:0] wb_req_line;
    wire [LINE_BYTES-1:0]   wb_req_be;
    wire [LINE_BYTES*8-1:0] wb_req_wdata, wb_rsp_rdata;
    wire [7:0]    wb_req_tag, wb_rsp_tag;

    ad_rop_wb #(.ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT)) u_wb (
        .clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata),
        .d_valid(ds_valid), .d_ready(ds_ready), .d_xy(ds_xy), .d_smask(ds_smask), .d_color(ds_color),
        .d_rt(ds_beat[3:2]), .d_nocol(ds_beat[1]),
        .b_valid(b_valid), .b_src(b_src), .b_dst(b_dst), .b_mask(b_mask), .b_rt(b_rt),
        .b_rvalid(b_rvalid), .b_pix(b_pix), .busy(wb_busy),
        .req_valid(wb_req_valid), .req_ready(wb_req_ready), .req_write(wb_req_write), .req_line(wb_req_line),
        .req_be(wb_req_be), .req_wdata(wb_req_wdata), .req_tag(wb_req_tag),
        .rsp_valid(wb_rsp_valid), .rsp_write(wb_rsp_write), .rsp_tag(wb_rsp_tag), .rsp_rdata(wb_rsp_rdata),
        .rsp_error(wb_rsp_error)
    );

    // Dual-source colour has no source upstream yet (ex_* carries one colour per
    // beat): tied off here, see the architecture document.
    ad_rop_blend #(.LAT(3)) u_blend (
        .clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata),
        .b_valid(b_valid), .b_src(b_src), .b_src1(512'd0), .b_has_src1(1'b0), .b_dst(b_dst),
        .b_mask(b_mask), .b_rt(b_rt), .b_rvalid(b_rvalid), .b_pix(b_pix)
    );

    // ---------------- memory port ----------------
    wire                    c_rsp_write, c_rsp_error;
    wire [7:0]              c_rsp_tag;
    wire [LINE_BYTES*8-1:0] c_rsp_rdata;
    ad_amb_mux #(.N(2), .ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT)) u_mux (
        .clk(clk), .rst_n(rst_n),
        .c_req_valid({wb_req_valid, ds_req_valid}), .c_req_ready({wb_req_ready, ds_req_ready}),
        .c_req_write({wb_req_write, ds_req_write}), .c_req_line({wb_req_line, ds_req_line}),
        .c_req_be({wb_req_be, ds_req_be}), .c_req_wdata({wb_req_wdata, ds_req_wdata}),
        .c_req_tag({wb_req_tag, ds_req_tag}),
        .c_rsp_valid({wb_rsp_valid, ds_rsp_valid}), .c_rsp_write(c_rsp_write), .c_rsp_tag(c_rsp_tag),
        .c_rsp_rdata(c_rsp_rdata), .c_rsp_error(c_rsp_error),
        .m_req_valid(req_valid), .m_req_ready(req_ready), .m_req_write(req_write), .m_req_line(req_line),
        .m_req_be(req_be), .m_req_wdata(req_wdata), .m_req_tag(req_tag),
        .m_rsp_valid(rsp_valid), .m_rsp_write(rsp_write), .m_rsp_tag(rsp_tag), .m_rsp_rdata(rsp_rdata),
        .m_rsp_error(rsp_error)
    );
    assign ds_rsp_write = c_rsp_write;  assign wb_rsp_write = c_rsp_write;
    assign ds_rsp_error = c_rsp_error;  assign wb_rsp_error = c_rsp_error;
    assign ds_rsp_tag   = c_rsp_tag;    assign wb_rsp_tag   = c_rsp_tag;
    assign ds_rsp_rdata = c_rsp_rdata;  assign wb_rsp_rdata = c_rsp_rdata;

    assign busy = or_busy | ms_busy | ds_busy | wb_busy;
endmodule
