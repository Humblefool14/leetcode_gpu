// FPV harness: ad_rx_cpoly (control path; fp units are cut-points under
// AD_FPABS, so every inside/outside pattern of the distances is explored).
module ad_rx_cpoly_fv (input logic clk, input logic rst_n, input logic [127:0] vp,
  input logic ld_we, input logic [3:0] ld_idx, input logic [223:0] ld_data,
  input logic [3:0] ld_n, input logic ld_line, input logic cmd_valid,
  input logic [2:0] cmd_plane, input logic cmd_first, input logic [3:0] rd_idx);
  logic cmd_ready, done; logic [3:0] n_out; logic [223:0] rd_data;
  ad_rx_cpoly u (.*);
  logic f_init = 1'b1, f_first = 1'b1;
  always @(posedge clk) begin
    f_init <= 1'b0;
    if (!rst_n) f_first <= 1'b1; else if (cmd_valid && cmd_ready) f_first <= 1'b0;
  end
  always @(*) begin
    if (f_init) assume (!rst_n);
    assume (ld_line ? (ld_n == 4'd2) : (ld_n == 4'd3));
    if (f_first && cmd_valid) assume (cmd_first);
    assume (cmd_plane <= 3'd6);
    assume (ld_idx < 4'd10);
  end
  // a cut finishes: done within 60 cycles for a line (one crossing at most)
  logic [6:0] age; logic run, hline;
  always @(posedge clk) if (!rst_n) begin run <= 0; age <= 0; hline <= 0; end
    else if (cmd_valid && cmd_ready) begin run <= 1; age <= 0; if (cmd_first) hline <= ld_line; end
    else if (done) run <= 0; else if (run) age <= age + 1;
  // a line: 2 vertices, at most one crossing (2 x 5 distance steps + one intersection)
  always @(posedge clk) if (!f_init && rst_n && run && hline) assert (age < 7'd58);
  always @(posedge clk) if (!f_init && rst_n && done && hline) assert (n_out <= 4'd2);
endmodule
