// rasterizer_core (fixed): every fragment of 300 random triangles is logged;
// tools/rc_check.py compares with an exact pixel-centre / top-left model.
module rc_tb;
  logic clk = 0, rst_n = 0, start = 0, busy, done, fv;
  logic signed [15:0] c [6];
  logic [15:0] fx, fy; logic signed [35:0] e0, e1, e2;
  rasterizer_core #(.SCREEN_W(64), .SCREEN_H(48)) dut (.clk, .rst_n, .start, .busy, .done,
    .v0_x(c[0]), .v0_y(c[1]), .v1_x(c[2]), .v1_y(c[3]), .v2_x(c[4]), .v2_y(c[5]),
    .frag_valid(fv), .frag_x(fx), .frag_y(fy), .frag_e0(e0), .frag_e1(e1), .frag_e2(e2));
  always #5 clk = ~clk;
  integer fo, fi, n;
  initial begin
    fi = $fopen("rc_in.txt", "r"); fo = $fopen("rc_out.txt", "w");
    repeat (2) @(posedge clk); rst_n = 1;
    while (!$feof(fi)) begin
      n = $fscanf(fi, "%d %d %d %d %d %d\n", c[0], c[1], c[2], c[3], c[4], c[5]);
      $fwrite(fo, "T\n");
      @(negedge clk) start = 1; @(negedge clk) start = 0;
      while (!done) @(negedge clk);
      @(negedge clk);
    end
    $fclose(fo); $finish;
  end
  always @(posedge clk) if (fv) $fwrite(fo, "F %0d %0d\n", fx, fy);
endmodule
