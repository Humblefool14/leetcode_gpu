// Bit-exact check of ad_rx_fadd / ad_rx_fmul / ad_rx_fdiv against tools/fpref.py.
`timescale 1ns/1ps
module ad_rx_fp_tb;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  logic [31:0] a, b, r_add, r_mul, r_div;
  logic sub, start, busy, done;
  ad_rx_fadd u_add (.i_a(a), .i_b(b), .i_sub(sub), .o_r(r_add));
  ad_rx_fmul u_mul (.i_a(a), .i_b(b), .o_r(r_mul));
  ad_rx_fdiv u_div (.clk, .rst_n, .i_start(start), .i_a(a), .i_b(b), .busy, .o_done(done), .o_r(r_div));

  integer fd, n, errs, cnt;
  logic [3:0] op; logic [31:0] va, vb, ve, got;
  initial begin
    errs = 0; cnt = 0; start = 0; sub = 0; a = 0; b = 0;
    repeat (2) @(posedge clk); rst_n = 1;
    fd = $fopen("fp_vec.txt", "r");
    while (!$feof(fd)) begin
      n = $fscanf(fd, "%h %h %h %h\n", op, va, vb, ve);
      if (n == 4) begin
        a = va; b = vb; sub = (op == 1);
        if (op == 3) begin
          @(negedge clk) start = 1; @(negedge clk) start = 0;
          while (!done) @(negedge clk);
          got = r_div;
        end else begin
          #1 got = (op == 2) ? r_mul : r_add;
        end
        cnt = cnt + 1;
        if (got !== ve) begin
          errs = errs + 1;
          if (errs < 10) $display("MISMATCH op %0d a %h b %h exp %h got %h", op, va, vb, ve, got);
        end
      end
    end
    if (errs == 0) $display("PASS ad_rx_fp (%0d vectors)", cnt);
    else $display("FAIL ad_rx_fp: %0d / %0d", errs, cnt);
    $finish;
  end
endmodule
