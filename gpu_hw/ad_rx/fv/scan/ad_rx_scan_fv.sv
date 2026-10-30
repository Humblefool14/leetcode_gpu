// FPV harness: ad_rx_scan (+ coarse, cov) at reduced widths (CW 8, AW 6,
// EW 18, FR 2) and without its Hi-Z child (proven on its own, fv/hiz).
// In the module: a quad leaves only with a sample and inside the bbox, the
// sample mask applied, one sample when not 4x, one path per triangle, frees
// only while frag is idle, fq_ / dx_ held while not taken.
module ad_rx_scan_fv (input logic clk, input logic rst_n, input logic [4:0] msctl, input logic [3:0] skill,
  input logic [3:0] dfunc, input logic sp_valid, input logic [831:0] sp_tri, input logic sp_last,
  input logic fq_ready, input logic f_busy, input logic dx_ready, input logic [15:0] sq_seq,
  input logic hz_clear, input logic hz_upd, input logic [15:0] hz_ux, input logic [15:0] hz_uy, input logic [15:0] hz_uz);
  logic sp_ready, pt_free, fq_valid, fq_end, dx_valid, dx_last, sq_req, busy;
  logic [7:0] pt_free_idx; logic [31:0] fq_xy, dx_xy; logic [15:0] fq_scov, dx_seq; logic [3:0] fq_ccov, dx_mask;
  logic [127:0] dx_depth;
  ad_rx_scan #(.ENEZHZ(0), .CW(8), .AW(6), .EW(18), .FR(2)) u (.clk, .rst_n, .i_msctl(msctl), .i_skill(skill),
    .i_dfunc(dfunc), .sp_valid, .sp_ready, .sp_tri, .sp_last, .pt_free, .pt_free_idx, .fq_valid, .fq_ready,
    .fq_xy, .fq_scov, .fq_ccov, .fq_end, .f_busy, .dx_valid, .dx_ready, .dx_seq, .dx_xy, .dx_mask, .dx_depth,
    .dx_last, .sq_req, .sq_seq, .hz_clear, .hz_upd, .hz_ux, .hz_uy, .hz_uz, .busy);
  logic f_init = 1'b1;
  always @(posedge clk) f_init <= 1'b0;
  always @(*) begin
    if (f_init) assume (!rst_n);
    for (int e = 0; e < 3; e++)                                   // |E| < 2^14 (reduced guard band)
      assume (sp_tri[30*e + 12 + 14 +: 4] == 4'h0 || sp_tri[30*e + 12 + 14 +: 4] == 4'hF);
    assume (sp_tri[288 + 7] == 0 && sp_tri[296 + 7] == 0 && sp_tri[304 + 7] == 0 && sp_tri[312 + 7] == 0);
  end
  // MS_CTRL / SAMPLE_KILL stable while a triangle is in flight (CP contract)
  always @(posedge clk) if (!f_init && rst_n && busy) assume (msctl == $past(msctl) && skill == $past(skill));
endmodule
