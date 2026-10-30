// FPV harness: ad_rx_setup (+ edge), fp units abstracted (AD_FPABS): the
// micro-program never leaves the ROM, last-use flags only on the final output,
// outputs held while not taken (in the module).
module ad_rx_setup_fv (input logic clk, input logic rst_n, input logic [191:0] vp, input logic [31:0] scmin,
  input logic [31:0] scmax, input logic [2:0] cull, input logic [31:0] rmode, input logic [95:0] dbias,
  input logic [31:0] lwdth, input logic [31:0] psize, input logic [31:0] rtsiz,
  input logic cl_valid, input logic [701:0] cl_tri, input logic cl_last, input logic sp_ready);
  logic cl_ready, sp_valid, sp_last, busy; logic [831:0] sp_tri;
  ad_rx_setup u (.clk, .rst_n, .i_vp(vp), .i_scmin(scmin), .i_scmax(scmax), .i_cull(cull), .i_rmode(rmode),
    .i_dbias(dbias), .i_lwdth(lwdth), .i_psize(psize), .i_rtsiz(rtsiz), .cl_valid, .cl_ready, .cl_tri, .cl_last,
    .sp_valid, .sp_ready, .sp_tri, .sp_last, .busy);
  logic f_init = 1'b1;
  always @(posedge clk) f_init <= 1'b0;
  always @(*) if (f_init) assume (!rst_n);
endmodule
