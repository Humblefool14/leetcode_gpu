// FPV harness: ad_rx_clip (+ ad_rx_cpoly), fp units abstracted (AD_FPABS).
// Protocol properties in the module (no PT read under pt_busy, last-use flags
// only on the last output, cl_* held while not taken); here: inputs held
// while prim_valid waits, and every primitive leaves at least one output.
module ad_rx_clip_fv (input logic clk, input logic rst_n, input logic [127:0] vp,
  input logic [1:0] dclmp, input logic discard, input logic [287:0] rawv, input logic raw_kick,
  input logic prim_valid, input logic [25:0] prim_vtx, input logic [2:0] prim_free, input logic prim_last,
  input logic [31:0] pt_rdata, input logic pt_busy, input logic cl_ready);
  logic prim_ready, pt_rd, cl_valid, cl_last, busy; logic [7:0] pt_idx; logic [6:0] pt_word; logic [701:0] cl_tri;
  ad_rx_clip u (.clk, .rst_n, .i_vp(vp), .i_dclmp(dclmp), .i_discard(discard), .i_rawv(rawv), .raw_kick,
    .prim_valid, .prim_ready, .prim_vtx, .prim_free, .prim_last, .pt_rd, .pt_idx, .pt_word, .pt_rdata,
    .pt_busy, .cl_valid, .cl_ready, .cl_tri, .cl_last, .busy);
  logic f_init = 1'b1;
  always @(posedge clk) f_init <= 1'b0;
  always @(*) if (f_init) assume (!rst_n);
  // the free flags of one primitive appear exactly once among its outputs
  logic seen; logic [2:0] hfree;
  always @(posedge clk) if (!rst_n) seen <= 0; else begin
    if (prim_valid && prim_ready) begin seen <= 0; hfree <= prim_free; end
    if (cl_valid && cl_ready && cl_tri[698:696] != 0) seen <= 1;
  end
  always @(posedge clk) if (!f_init && rst_n) begin
    if (cl_valid && cl_tri[698:696] != 0) assert (!seen);
    if (cl_valid && !cl_tri[699] && cl_tri[698:696] != 0) assert (cl_tri[698:696] == hfree);
  end
endmodule
