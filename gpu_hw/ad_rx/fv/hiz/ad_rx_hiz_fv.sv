// FPV harness: ad_rx_hiz, shrunk to 2 x 2 tiles and 2 generation bits so BMC
// reaches the generation wrap and the scrub.  The reject-soundness property
// (against a shadow pixel) is in the module.
module ad_rx_hiz_fv (input logic clk, input logic rst_n, input logic en,
  input logic [2:0] func, input logic clear,
  input logic q_valid, input logic [15:0] q_tx, input logic [15:0] q_ty,
  input logic [15:0] q_zmin, input logic [15:0] q_zmax,
  input logic u_valid, input logic [15:0] u_x, input logic [15:0] u_y, input logic [15:0] u_z);
  logic r_valid, r_reject, busy;
  ad_rx_hiz #(.AW(2), .TXW(1), .GW(2)) u (.clk, .rst_n, .i_en(en), .i_func(func), .i_clear(clear),
    .q_valid, .q_tx, .q_ty, .q_zmin, .q_zmax, .r_valid, .r_reject, .u_valid, .u_x, .u_y, .u_z, .busy);
  logic f_init = 1'b1;
  always @(posedge clk) f_init <= 1'b0;
  always @(*) if (f_init) assume (!rst_n);
  // the ROP only writes a depth that passes the family's test against the
  // pixel's current value (LESS family: never larger; GREATER: never smaller)
  // -- not needed for soundness here: the module keeps max/min of all writes.
  // a reject is possible: cover it
  always @(posedge clk) if (!f_init && rst_n) cover (r_reject);
endmodule
