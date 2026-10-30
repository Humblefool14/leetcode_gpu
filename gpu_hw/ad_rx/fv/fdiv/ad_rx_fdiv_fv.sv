// FPV harness: ad_rx_fdiv.  The protocol, latency and value properties
// (x / 1 = x, x / x = 1) are in the module (FORMAL); here only the reset.
module ad_rx_fdiv_fv (input logic clk, input logic rst_n, input logic start,
                      input logic [31:0] a, input logic [31:0] b);
  logic busy, done; logic [31:0] r;
  ad_rx_fdiv u (.clk, .rst_n, .i_start(start), .i_a(a), .i_b(b), .busy, .o_done(done), .o_r(r));
  logic f_init = 1'b1;
  always @(posedge clk) f_init <= 1'b0;
  always @(*) if (f_init) assume (!rst_n);
endmodule
