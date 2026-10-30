// FPV harness: ad_rx_bary, fp results abstracted: pass latency bounded
// (< 50 cycles, also with special-case divisions ending early), o_done one cycle.
module ad_rx_bary_fv (input logic clk, input logic rst_n, input logic start, input logic dz,
  input logic [383:0] pl, input logic [15:0] qx, input logic [15:0] qy, input logic [15:0] bx0,
  input logic [15:0] by0, input logic [11:0] osel);
  logic busy, done; logic [127:0] b0, b1, b2, z, ds;
  ad_rx_bary u (.clk, .rst_n, .i_start(start), .i_dz(dz), .i_pl(pl), .i_qx(qx), .i_qy(qy), .i_bx0(bx0),
    .i_by0(by0), .i_osel(osel), .busy, .o_done(done), .o_b0(b0), .o_b1(b1), .o_b2(b2), .o_z(z), .o_ds(ds));
  logic f_init = 1'b1;
  always @(posedge clk) f_init <= 1'b0;
  always @(*) if (f_init) assume (!rst_n);
  always @(posedge clk) if (!f_init && rst_n && done) assert (!$past(done));
endmodule
