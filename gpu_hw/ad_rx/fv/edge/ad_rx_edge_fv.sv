// FPV harness: ad_rx_edge.  The register file is a free input (any window
// coordinates); bounded latency, bbox within RT and scissor, empty => zeroed,
// facing of lines and points are in the module.
module ad_rx_edge_fv (input logic clk, input logic rst_n, input logic start, input logic [3:0] mode,
  input logic [31:0] smin, input logic [31:0] smax, input logic [31:0] rts, input logic [2:0] cull,
  input logic vprect, input logic [31:0] r_rd);
  logic [6:0] r_ra, r_wa; logic r_we, done, front, empty; logic [31:0] r_wd; logic [287:0] edges; logic [63:0] bbox;
  ad_rx_edge u (.*);
  logic f_init = 1'b1;
  always @(posedge clk) f_init <= 1'b0;
  always @(*) begin
    if (f_init) assume (!rst_n);
    assume (smin[15] == 0 && smin[31] == 0 && smax[15] == 0 && smax[31] == 0 && rts[15] == 0 && rts[31] == 0);
  end
  // configuration is stable while a call runs (setup holds its state)
  logic run;
  always @(posedge clk) if (!rst_n) run <= 0; else if (start) run <= 1; else if (done) run <= 0;
  always @(posedge clk) if (!f_init && rst_n && run) assume (smin == $past(smin) && smax == $past(smax) && rts == $past(rts) && cull == $past(cull));
endmodule
