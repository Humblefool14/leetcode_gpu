// ============================================================================
// ad_rx -- the rasterizer: state, clip, setup, scan (coarse, cov, Hi-Z),
// frag (bary), order.
//
// Wiring plus: the PT read mux (frag first; clip waits on pt_busy), the OR of
// the two sequence-number requests (scan's direct triangles, frag's warps;
// never in the same cycle, asserted), and busy (STATUS.RX_BUSY).
//
// Fixes vs atg_rx: prim_vtx is 26 bits (kind in [25:24], as atg_rx_clip
// already required); ad_rx_state decodes STATE once; the Hi-Z clear and the
// ROP's depth-write snoop are ports (atg had no path to update a Hi-Z).
// ============================================================================
module ad_rx #(
  parameter int HAS_SU = ad_rx_pkg::HAS_SU_,
  parameter int ENMSAA = ad_rx_pkg::EN_MSAA,
  parameter int ENEZHZ = ad_rx_pkg::EN_EZHZ
) (
  input  logic                               clk,
  input  logic                               rst_n,
  // STATE broadcast
  input  logic                               st_we,
  input  logic [ad_rx_pkg::ST_IDXW-1:0]      st_idx,
  input  logic [ad_rx_pkg::ST_DATW-1:0]      st_wdata,
  input  logic                               raw_kick,
  output logic                               busy,
  // primitives
  input  logic                               prim_valid,
  output logic                               prim_ready,
  input  logic [ad_rx_pkg::PRM_VTW-1:0]      prim_vtx,
  input  logic [2:0]                         prim_free,
  input  logic                               prim_last,
  // PT of SU 0
  output logic                               pt_rd,
  output logic [ad_rx_pkg::PT_IDXW-1:0]      pt_idx,
  output logic [ad_rx_pkg::PT_WRDW-1:0]      pt_word,
  input  logic [31:0]                        pt_rdata,
  output logic                               pt_free,
  output logic [ad_rx_pkg::PT_IDXW-1:0]      pt_free_idx,
  // fragment warps
  output logic                               fl_req,
  input  logic                               fl_gnt,
  output logic                               fl_we,
  output logic [ad_rx_pkg::FL_REGW-1:0]      fl_reg,
  output logic [ad_rx_pkg::LANE_IW-1:0]      fl_lane,
  output logic [31:0]                        fl_data,
  output logic                               fl_pw_we,
  output logic [ad_rx_pkg::FL_ADRW-1:0]      fl_pw_addr,
  output logic [31:0]                        fl_pw_data,
  output logic                               fl_go,
  output logic [ad_rx_pkg::LANE_NB-1:0]      fl_mask,
  output logic [ad_rx_pkg::FL_INFW-1:0]      fl_info,
  // direct quads
  output logic                               dx_valid,
  input  logic                               dx_ready,
  output logic [ad_rx_pkg::SEQ_WID-1:0]      dx_seq,
  output logic [ad_rx_pkg::QXY_WID-1:0]      dx_xy,
  output logic [3:0]                         dx_mask,
  output logic [4*32-1:0]                    dx_depth,
  output logic                               dx_last,
  // sequence numbers to the ROP
  output logic                               ord_valid,
  output logic [ad_rx_pkg::SEQ_WID-1:0]      ord_seq,
  // Hi-Z (new)
  input  logic                               hz_clear,
  input  logic                               hz_upd,
  input  logic [ad_rx_pkg::CRD_WID-1:0]      hz_ux,
  input  logic [ad_rx_pkg::CRD_WID-1:0]      hz_uy,
  input  logic [ad_rx_pkg::HZ_DEPW-1:0]      hz_uz
);
  // ---------------------------------------------------------------- state
  logic [6*32-1:0] vp;   logic [31:0] scmin, scmax, rmode, lwdth, psize, rtsiz;
  logic [2:0] cull;      logic [1:0] dclmp;  logic [6:0] varyc; logic [4:0] msctl;
  logic [3:0] skill, dfunc; logic [3*32-1:0] dbias; logic [9*32-1:0] rawv;
  ad_rx_state u_state (.clk, .rst_n, .st_we, .st_idx, .st_wdata, .o_vp(vp), .o_scmin(scmin),
                       .o_scmax(scmax), .o_cull(cull), .o_dclmp(dclmp), .o_rmode(rmode),
                       .o_varyc(varyc), .o_msctl(msctl), .o_skill(skill), .o_dbias(dbias),
                       .o_lwdth(lwdth), .o_psize(psize), .o_dfunc(dfunc), .o_rtsiz(rtsiz),
                       .o_rawv(rawv));

  // ---------------------------------------------------------------- clip
  logic c_pt_rd, f_pt_rd, f_pt_busy;
  logic [ad_rx_pkg::PT_IDXW-1:0] c_pt_idx, f_pt_idx;
  logic [ad_rx_pkg::PT_WRDW-1:0] c_pt_word, f_pt_word;
  logic cl_valid, cl_ready, cl_last, c_busy;
  logic [ad_rx_pkg::CLT_WID-1:0] cl_tri;
  ad_rx_clip u_clip (.clk, .rst_n, .i_vp(vp[0 +: 128]), .i_dclmp(dclmp), .i_discard(rmode[6]),
                     .i_rawv(rawv), .raw_kick, .prim_valid, .prim_ready, .prim_vtx, .prim_free,
                     .prim_last, .pt_rd(c_pt_rd), .pt_idx(c_pt_idx), .pt_word(c_pt_word),
                     .pt_rdata, .pt_busy(f_pt_busy), .cl_valid, .cl_ready, .cl_tri, .cl_last,
                     .busy(c_busy));

  // ---------------------------------------------------------------- setup
  logic sp_valid, sp_ready, sp_last, s_busy;
  logic [ad_rx_pkg::SPT_WID-1:0] sp_tri;
  ad_rx_setup u_setup (.clk, .rst_n, .i_vp(vp), .i_scmin(scmin), .i_scmax(scmax), .i_cull(cull),
                       .i_rmode(rmode), .i_dbias(dbias), .i_lwdth(lwdth), .i_psize(psize),
                       .i_rtsiz(rtsiz), .cl_valid, .cl_ready, .cl_tri, .cl_last,
                       .sp_valid, .sp_ready, .sp_tri, .sp_last, .busy(s_busy));

  // ---------------------------------------------------------------- scan
  logic fq_valid, fq_ready, fq_end, f_busy, sc_busy, sc_sq, fr_sq;
  logic [ad_rx_pkg::QXY_WID-1:0] fq_xy;
  logic [ad_rx_pkg::MS_COVW-1:0] fq_scov;
  logic [3:0] fq_ccov;
  logic [ad_rx_pkg::SEQ_WID-1:0] sq_seq;
  ad_rx_scan #(.HAS_SU(HAS_SU), .ENMSAA(ENMSAA), .ENEZHZ(ENEZHZ)) u_scan (
    .clk, .rst_n, .i_msctl(msctl), .i_skill(skill), .i_dfunc(dfunc),
    .sp_valid, .sp_ready, .sp_tri, .sp_last, .pt_free, .pt_free_idx,
    .fq_valid, .fq_ready, .fq_xy, .fq_scov, .fq_ccov, .fq_end, .f_busy,
    .dx_valid, .dx_ready, .dx_seq, .dx_xy, .dx_mask, .dx_depth, .dx_last,
    .sq_req(sc_sq), .sq_seq, .hz_clear, .hz_upd, .hz_ux, .hz_uy, .hz_uz, .busy(sc_busy));

  // ---------------------------------------------------------------- frag
  generate
    if (HAS_SU != 0) begin : g_frag
      ad_rx_frag u_frag (.clk, .rst_n, .i_varyc(varyc), .i_msctl(msctl), .i_dclmp(dclmp),
                         .t_load(sp_valid && sp_ready), .t_tri(sp_tri),
                         .fq_valid, .fq_ready, .fq_xy, .fq_scov, .fq_ccov, .fq_end, .busy(f_busy),
                         .pt_rd(f_pt_rd), .pt_idx(f_pt_idx), .pt_word(f_pt_word), .pt_rdata,
                         .pt_busy(f_pt_busy), .fl_req, .fl_gnt, .fl_we, .fl_reg, .fl_lane, .fl_data,
                         .fl_pw_we, .fl_pw_addr, .fl_pw_data, .fl_go, .fl_mask, .fl_info,
                         .sq_req(fr_sq), .sq_seq);
    end else begin : g_nofrag
      assign fq_ready = 1'b1; assign f_busy = 1'b0; assign f_pt_rd = 1'b0; assign f_pt_busy = 1'b0;
      assign f_pt_idx = '0; assign f_pt_word = '0; assign fr_sq = 1'b0;
      assign fl_req = 1'b0; assign fl_we = 1'b0; assign fl_reg = '0; assign fl_lane = '0;
      assign fl_data = '0; assign fl_pw_we = 1'b0; assign fl_pw_addr = '0; assign fl_pw_data = '0;
      assign fl_go = 1'b0; assign fl_mask = '0; assign fl_info = '0;
    end
  endgenerate

  // ---------------------------------------------------------------- PT mux: frag first
  assign pt_rd   = f_pt_busy ? f_pt_rd   : c_pt_rd;
  assign pt_idx  = f_pt_busy ? f_pt_idx  : c_pt_idx;
  assign pt_word = f_pt_busy ? f_pt_word : c_pt_word;

  // ---------------------------------------------------------------- order
  ad_rx_order u_order (.clk, .rst_n, .sq_req(sc_sq | fr_sq), .sq_seq, .ord_valid, .ord_seq);

  assign busy = c_busy || s_busy || sc_busy || f_busy || cl_valid || sp_valid;

`ifdef FORMAL
  logic f_vld = 1'b0;
  always @(posedge clk) if (!rst_n) f_vld <= 1'b1;
  always @(posedge clk) if (f_vld && rst_n) begin
    assert (!(sc_sq && fr_sq));                    // never both in one cycle
    if (pt_rd) assert (f_pt_busy ? f_pt_rd : !f_pt_busy);
    if (fl_go) assert (fl_mask != 0);
  end
`endif
endmodule
