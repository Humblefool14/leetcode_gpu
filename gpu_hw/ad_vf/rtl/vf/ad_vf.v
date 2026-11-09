// ad_vf: the vertex fetcher (spec/gpu/vf/ad_vf.md).  Wiring only:
//   draw_kick -> ad_vf_index -(iv)-> ad_vf_asm -(vb)-> ad_vf_fetch -(af)-> ad_vf_conv -(vl_we..)-> SU
//   ad_vf_asm also talks to the SU's slot allocator (vl_req/gnt/ptbase/go/mask) and the RX (prim_*).
//   ad_vf_index (requester 0) and ad_vf_fetch (requester 1) share the AMB port through ad_amb_mux.
// busy = any child busy (ad_vf_conv has no busy port: it is idle once conv_done has pulsed, and
// ad_vf_asm stays busy until the warp's conv_done and primitives are out), or a STATE write held by
// ad_vf_stguard.
// Two contract fixes (2026-11-09, found by review):
//  * ad_vf_stguard holds PROVOKING / ATTR_LIMIT writes that arrive during a draw (the CP does not
//    hold those indices while the VF is busy), so a draw always uses the values it was kicked with.
//  * After an index-buffer rsp_error the walk stops without iv_last and ad_vf_asm would stay busy
//    forever.  The VF then reports busy only while reads are in flight (index DRAIN, fetch), so the
//    CP sees when it is safe to reset the VF (no stale response can reach the next draw).  The flag
//    clears only with rst_n.
module ad_vf #(
    parameter ADDR_W     = 32,
    parameter LINE_BYTES = 32,
    parameter LINE_SHIFT = 5
) (
    input  wire                         clk,
    input  wire                         rst_n,
    // STATE broadcast
    input  wire                         st_we,
    input  wire [8:0]                   st_idx,
    input  wire [31:0]                  st_wdata,
    input  wire                         draw_kick,
    output wire                         busy,
    // vertex warps to the SU
    output wire                         vl_req,
    input  wire                         vl_gnt,
    input  wire [7:0]                   vl_ptbase,
    output wire                         vl_go,
    output wire [31:0]                  vl_mask,
    output wire                         vl_we,
    output wire [5:0]                   vl_reg,
    output wire [4:0]                   vl_lane,
    output wire [31:0]                  vl_data,
    // primitives to the RX
    output wire                         prim_valid,
    input  wire                         prim_ready,
    output wire [25:0]                  prim_vtx,
    output wire [2:0]                   prim_free,
    output wire                         prim_last,
    // AMB client port
    output wire                         req_valid,
    input  wire                         req_ready,
    output wire                         req_write,
    output wire [ADDR_W-LINE_SHIFT-1:0] req_line,
    output wire [LINE_BYTES-1:0]        req_be,
    output wire [LINE_BYTES*8-1:0]      req_wdata,
    output wire [7:0]                   req_tag,
    input  wire                         rsp_valid,
    input  wire                         rsp_write,
    input  wire [7:0]                   rsp_tag,
    input  wire [LINE_BYTES*8-1:0]      rsp_rdata,
    input  wire                         rsp_error
`ifdef AD_FV_TOP
    ,output wire                        fv_idx_err      // formal only: an index fault was seen
`endif
);
    localparam LW = ADDR_W - LINE_SHIFT;

    // index stream
    wire        iv_valid, iv_ready, iv_restart, iv_last;
    wire [31:0] iv_index, iv_inst;
    // warp vertices
    wire        vb_valid, vb_ready, vb_last;
    wire [31:0] vb_index, vb_inst;
    wire [4:0]  vb_lane;
    // attributes
    wire        af_valid, af_ready, af_oob, af_last;
    wire [3:0]  af_attr;
    wire [4:0]  af_lane;
    wire [127:0] af_raw;
    wire        conv_done;
    wire        idx_busy, asm_busy, fet_busy;
    // STATE broadcast as the children see it
    wire        g_we, st_hold;
    wire [8:0]  g_idx;
    wire [31:0] g_wdata;
    reg         idx_err;

    // AMB clients
    wire [1:0]            c_req_valid, c_req_ready, c_req_write, c_rsp_valid;
    wire [2*LW-1:0]       c_req_line;
    wire [2*LINE_BYTES-1:0]   c_req_be;
    wire [2*LINE_BYTES*8-1:0] c_req_wdata;
    wire [15:0]           c_req_tag;
    wire                  c_rsp_write, c_rsp_error;
    wire [7:0]            c_rsp_tag;
    wire [LINE_BYTES*8-1:0] c_rsp_rdata;

    ad_vf_index #(.ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT)) u_index (
        .clk(clk), .rst_n(rst_n), .st_we(g_we), .st_idx(g_idx), .st_wdata(g_wdata),
        .kick(draw_kick), .busy(idx_busy),
        .iv_valid(iv_valid), .iv_ready(iv_ready), .iv_index(iv_index), .iv_inst(iv_inst),
        .iv_restart(iv_restart), .iv_last(iv_last),
        .req_valid(c_req_valid[0]), .req_ready(c_req_ready[0]), .req_write(c_req_write[0]),
        .req_line(c_req_line[0 +: LW]), .req_be(c_req_be[0 +: LINE_BYTES]),
        .req_wdata(c_req_wdata[0 +: LINE_BYTES*8]), .req_tag(c_req_tag[0 +: 8]),
        .rsp_valid(c_rsp_valid[0]), .rsp_write(c_rsp_write), .rsp_tag(c_rsp_tag),
        .rsp_rdata(c_rsp_rdata), .rsp_error(c_rsp_error));

    ad_vf_asm u_asm (
        .clk(clk), .rst_n(rst_n), .st_we(g_we), .st_idx(g_idx), .st_wdata(g_wdata),
        .iv_valid(iv_valid), .iv_ready(iv_ready), .iv_index(iv_index), .iv_inst(iv_inst),
        .iv_restart(iv_restart), .iv_last(iv_last),
        .vb_valid(vb_valid), .vb_ready(vb_ready), .vb_index(vb_index), .vb_inst(vb_inst),
        .vb_lane(vb_lane), .vb_last(vb_last), .conv_done(conv_done),
        .vl_req(vl_req), .vl_gnt(vl_gnt), .vl_ptbase(vl_ptbase), .vl_go(vl_go), .vl_mask(vl_mask),
        .prim_valid(prim_valid), .prim_ready(prim_ready), .prim_vtx(prim_vtx),
        .prim_free(prim_free), .prim_last(prim_last), .busy(asm_busy));

    ad_vf_fetch #(.ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT)) u_fetch (
        .clk(clk), .rst_n(rst_n), .st_we(g_we), .st_idx(g_idx), .st_wdata(g_wdata),
        .vb_valid(vb_valid), .vb_ready(vb_ready), .vb_index(vb_index), .vb_inst(vb_inst),
        .vb_lane(vb_lane), .vb_last(vb_last),
        .af_valid(af_valid), .af_ready(af_ready), .af_attr(af_attr), .af_lane(af_lane),
        .af_raw(af_raw), .af_oob(af_oob), .af_last(af_last), .busy(fet_busy),
        .req_valid(c_req_valid[1]), .req_ready(c_req_ready[1]), .req_write(c_req_write[1]),
        .req_line(c_req_line[LW +: LW]), .req_be(c_req_be[LINE_BYTES +: LINE_BYTES]),
        .req_wdata(c_req_wdata[LINE_BYTES*8 +: LINE_BYTES*8]), .req_tag(c_req_tag[8 +: 8]),
        .rsp_valid(c_rsp_valid[1]), .rsp_write(c_rsp_write), .rsp_tag(c_rsp_tag),
        .rsp_rdata(c_rsp_rdata), .rsp_error(c_rsp_error));

    ad_vf_conv u_conv (
        .clk(clk), .rst_n(rst_n), .st_we(g_we), .st_idx(g_idx), .st_wdata(g_wdata),
        .af_valid(af_valid), .af_ready(af_ready), .af_attr(af_attr), .af_lane(af_lane),
        .af_raw(af_raw), .af_oob(af_oob), .af_last(af_last),
        .vl_we(vl_we), .vl_reg(vl_reg), .vl_lane(vl_lane), .vl_data(vl_data),
        .conv_done(conv_done));

    ad_amb_mux #(.ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT), .N(2)) u_mux (
        .clk(clk), .rst_n(rst_n),
        .c_req_valid(c_req_valid), .c_req_ready(c_req_ready), .c_req_write(c_req_write),
        .c_req_line(c_req_line), .c_req_be(c_req_be), .c_req_wdata(c_req_wdata), .c_req_tag(c_req_tag),
        .c_rsp_valid(c_rsp_valid), .c_rsp_write(c_rsp_write), .c_rsp_tag(c_rsp_tag),
        .c_rsp_rdata(c_rsp_rdata), .c_rsp_error(c_rsp_error),
        .m_req_valid(req_valid), .m_req_ready(req_ready), .m_req_write(req_write),
        .m_req_line(req_line), .m_req_be(req_be), .m_req_wdata(req_wdata), .m_req_tag(req_tag),
        .m_rsp_valid(rsp_valid), .m_rsp_write(rsp_write), .m_rsp_tag(rsp_tag),
        .m_rsp_rdata(rsp_rdata), .m_rsp_error(rsp_error));

    ad_vf_stguard u_stguard (
        .clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata),
        .busy_core(idx_busy | asm_busy | fet_busy),
        .o_we(g_we), .o_idx(g_idx), .o_wdata(g_wdata), .hold(st_hold));

    always @(posedge clk)
        if (!rst_n) idx_err <= 1'b0;
`ifndef MUT_NO_ERRBUSY
        else if (c_rsp_valid[0] && c_rsp_error) idx_err <= 1'b1;
`endif

`ifdef AD_FV_TOP
    assign fv_idx_err = idx_err;
`endif
    assign busy = idx_err ? (idx_busy | fet_busy) : (idx_busy | asm_busy | fet_busy | st_hold);
endmodule
