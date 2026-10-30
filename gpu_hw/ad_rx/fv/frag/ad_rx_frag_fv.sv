// FPV harness: ad_rx_frag (+ bary), fp abstracted.  EXEC covers the coverage,
// PT reads only while pt_busy, primitive-table words within VARYING_COUNT,
// register writes within the warp, one sequence number per warp (in the
// module); here: no quad is lost -- quads taken = 4 x lanes started (counted
// per warp) and the warp is never empty.
module ad_rx_frag_fv (input logic clk, input logic rst_n, input logic [6:0] varyc, input logic [4:0] msctl,
  input logic [1:0] dclmp, input logic t_load, input logic [831:0] t_tri, input logic fq_valid,
  input logic [31:0] fq_xy, input logic [15:0] fq_scov, input logic [3:0] fq_ccov, input logic fq_end,
  input logic [31:0] pt_rdata, input logic fl_gnt, input logic [15:0] sq_seq);
  logic fq_ready, busy, pt_rd, pt_busy, fl_req, fl_we, fl_pw_we, fl_go, sq_req; logic [7:0] pt_idx;
  logic [6:0] pt_word; logic [5:0] fl_reg; logic [4:0] fl_lane; logic [31:0] fl_data, fl_pw_data, fl_mask;
  logic [11:0] fl_pw_addr; logic [63:0] fl_info;
  ad_rx_frag u (.clk, .rst_n, .i_varyc(varyc), .i_msctl(msctl), .i_dclmp(dclmp), .t_load, .t_tri, .fq_valid,
    .fq_ready, .fq_xy, .fq_scov, .fq_ccov, .fq_end, .busy, .pt_rd, .pt_idx, .pt_word, .pt_rdata, .pt_busy,
    .fl_req, .fl_gnt, .fl_we, .fl_reg, .fl_lane, .fl_data, .fl_pw_we, .fl_pw_addr, .fl_pw_data, .fl_go,
    .fl_mask, .fl_info, .sq_req, .sq_seq);
  logic f_init = 1'b1;
  always @(posedge clk) f_init <= 1'b0;
  logic [3:0] taken;
  always @(posedge clk) if (!rst_n || fl_go) taken <= 0; else if (fq_valid && fq_ready && !fq_end) taken <= taken + 1;
  always @(*) begin
    if (f_init) assume (!rst_n);
    assume (varyc <= 7'd4);                                        // short copies (BMC depth)
    if (fq_valid && !fq_end) assume (fq_scov != 0);                // scan's guarantee
    if (fl_gnt) assume (fl_req);
  end
  always @(posedge clk) if (!f_init && rst_n && busy) assume (msctl == $past(msctl) && varyc == $past(varyc));
  always @(posedge clk) if (!f_init && rst_n && fl_go) begin
    assert (fl_mask == (32'hFFFF_FFFF >> (32 - 4 * taken)));       // every quad taken is in EXEC
    assert (taken != 0);
  end
endmodule
