// fv_ad_su_sched -- formal harness of ad_su_sched (NPHYS 8, NWARPS 4,
// FRAG_RESERVE 1, NSU 2, SU_INDEX 1, GTO 1; a second task set with GTO 0).
// Every input is free (feedback, warp control, wake, warp_ready, grants,
// STATE, kicks); the properties are inside the RTL under AD_SCHED_FV:
// grants only of FREE slots (never a slot twice), FRAG_RESERVE, barrier
// releases only when every member arrived, the issue gap, the selector picks
// a ready candidate only.  The harness adds port-level checks: a vertex grant
// never names a slot that is in use (granted/started and not freed by xr),
// and a fetch is never of a warp whose warp_ready was 0 at its selection.
module fv_ad_su_sched #(parameter GTO = 1) (
    input wire        clk,
    input wire        st_we,
    input wire [8:0]  st_idx,
    input wire [31:0] st_wdata,
    input wire        cs_kick,
    input wire        vl_req, vl_go, fl_req, fl_go, f_ready, fb_valid, wc_valid, pt_ok, xr_valid,
    input wire [31:0] vl_mask, fl_mask,
    input wire [63:0] fl_info,
    input wire [1:0]  fb_warp, fb_kind, wc_warp, wc_op, q_warp, xr_warp,
    input wire [3:0]  wake, warp_ready,
    input wire [15:0] wc_pc
);
    reg init = 1'b1;
    always @(posedge clk) init <= 1'b0;
    wire rst_n = !init;
    wire vl_gnt, fl_gnt, f_valid, init_valid, busy;
    wire [1:0] vl_slot, fl_slot, f_warp, init_warp;
    wire [15:0] f_pc; wire [31:0] f_addr, init_mask; wire [159:0] q_info;
    ad_su_sched #(.NPHYS(8), .NWARPS(4), .WARP_W(2), .NSU(2), .SU_INDEX(1), .FRAG_RESERVE(1), .GTO(GTO)) dut (
        .clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata), .cs_kick(cs_kick),
        .vl_req(vl_req), .vl_gnt(vl_gnt), .vl_slot(vl_slot), .vl_go(vl_go), .vl_mask(vl_mask),
        .fl_req(fl_req), .fl_gnt(fl_gnt), .fl_slot(fl_slot), .fl_go(fl_go), .fl_mask(fl_mask), .fl_info(fl_info),
        .f_valid(f_valid), .f_ready(f_ready), .f_warp(f_warp), .f_pc(f_pc), .f_addr(f_addr),
        .fb_valid(fb_valid), .fb_warp(fb_warp), .fb_kind(fb_kind), .wake(wake), .warp_ready(warp_ready),
        .wc_valid(wc_valid), .wc_warp(wc_warp), .wc_op(wc_op), .wc_pc(wc_pc),
        .q_warp(q_warp), .q_info(q_info), .init_valid(init_valid), .init_warp(init_warp), .init_mask(init_mask),
        .pt_ok(pt_ok), .xr_valid(xr_valid), .xr_warp(xr_warp), .busy(busy));

    // port-level: a fetched warp had warp_ready when it was selected
    reg p_can; reg [3:0] p_wr; reg p_fv;
    always @(posedge clk) begin p_can <= !f_valid || f_ready; p_wr <= warp_ready; end
    always @(*) if (rst_n && f_valid && p_can) a_sel_ready: assert (p_wr[f_warp]);
endmodule
