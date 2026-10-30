// FPV harness: ad_rx top (all children, fp abstracted): the two sequence
// requests never collide, the PT mux gives frag priority, no warp is empty
// (in the module); plus: busy is low only when nothing is in flight.
module ad_rx_fv (input logic clk, input logic rst_n, input logic st_we, input logic [8:0] st_idx,
  input logic [31:0] st_wdata, input logic raw_kick, input logic prim_valid, input logic [25:0] prim_vtx,
  input logic [2:0] prim_free, input logic prim_last, input logic [31:0] pt_rdata, input logic fl_gnt,
  input logic dx_ready, input logic hz_clear, input logic hz_upd, input logic [15:0] hz_ux,
  input logic [15:0] hz_uy, input logic [15:0] hz_uz);
  logic busy, prim_ready, pt_rd, pt_free, fl_req, fl_we, fl_pw_we, fl_go, dx_valid, dx_last, ord_valid;
  logic [7:0] pt_idx, pt_free_idx; logic [6:0] pt_word; logic [5:0] fl_reg; logic [4:0] fl_lane;
  logic [31:0] fl_data, fl_pw_data, fl_mask, dx_xy; logic [11:0] fl_pw_addr; logic [63:0] fl_info;
  logic [15:0] dx_seq, ord_seq; logic [3:0] dx_mask; logic [127:0] dx_depth;
  ad_rx u (.*);
  logic f_init = 1'b1;
  always @(posedge clk) f_init <= 1'b0;
  always @(*) begin
    if (f_init) assume (!rst_n);
    if (fl_gnt) assume (fl_req);
    if (busy) assume (!st_we);                                     // CP contract: STATE only while idle
  end
  always @(posedge clk) if (!f_init && rst_n && !busy) assert (!dx_valid && !fl_req);
endmodule
