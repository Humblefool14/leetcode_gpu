// FPV harness: ad_rx_coarse at reduced widths (CW 8, AW 6, EW 18, FR 2): the
// skip / trivial soundness (any pixel centre of the tile, any sample delta
// within lowm), screen alignment and the tile hold are in the module; their
// structure does not depend on the widths, so the reduced instance is a proof
// of the same logic.  Inputs stay inside the reduced guard band.
module ad_rx_coarse_fv (input logic clk, input logic rst_n,
  input logic tri_valid, input logic [31:0] bbox, input logic [89:0] edges,
  input logic [53:0] lowm, input logic tile_ready);
  logic tri_ready, tile_valid, tile_trivial, walk_done, busy;
  logic [7:0] tile_x, tile_y; logic [53:0] tile_e;
  ad_rx_coarse #(.CW(8), .AW(6), .EW(18), .FR(2)) u (.*);
  logic f_init = 1'b1;
  always @(posedge clk) f_init <= 1'b0;
  always @(*) begin
    if (f_init) assume (!rst_n);
    for (int e = 0; e < 3; e++) begin
      assume (lowm[18*e + 12 +: 6] == 0);                          // reach < 2^12
      assume (edges[30*e + 12 + 14 +: 4] == 4'h0 || edges[30*e + 12 + 14 +: 4] == 4'hF);   // |E| < 2^14
    end
    assume (bbox[7] == 0 && bbox[15] == 0 && bbox[23] == 0 && bbox[31] == 0);           // < 128 px
  end
  // (the walk's termination is covered by simulation: tools/rx_ref.py, sim/ad_rx_tb.sv)
endmodule
