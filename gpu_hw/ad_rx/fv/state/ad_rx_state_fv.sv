// FPV harness: ad_rx_state (decode properties are in the module).
module ad_rx_state_fv (input logic clk, input logic rst_n, input logic st_we,
                       input logic [8:0] st_idx, input logic [31:0] st_wdata);
  logic [191:0] vp; logic [31:0] scmin, scmax, rmode, lwdth, psize, rtsiz; logic [2:0] cull;
  logic [1:0] dclmp; logic [6:0] varyc; logic [4:0] msctl; logic [3:0] skill, dfunc;
  logic [95:0] dbias; logic [287:0] rawv;
  ad_rx_state u (.clk, .rst_n, .st_we, .st_idx, .st_wdata, .o_vp(vp), .o_scmin(scmin), .o_scmax(scmax),
    .o_cull(cull), .o_dclmp(dclmp), .o_rmode(rmode), .o_varyc(varyc), .o_msctl(msctl), .o_skill(skill),
    .o_dbias(dbias), .o_lwdth(lwdth), .o_psize(psize), .o_dfunc(dfunc), .o_rtsiz(rtsiz), .o_rawv(rawv));
  logic f_init = 1'b1;
  always @(posedge clk) f_init <= 1'b0;
  always @(*) if (f_init) assume (!rst_n);
endmodule
