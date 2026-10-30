// Reference-model testbench of the ad_rx arithmetic units.
// Vectors: sim/gen_fp_vec.py (exact-rational model sim/fpref.py).
`timescale 1ns/1ps
module ad_rx_fp_tb;
  localparam int N = 20000;

  logic [31:0] a, b, r_add, r_mul;
  logic        sub;
  ad_rx_fadd u_add (.a(a), .b(b), .sub(sub), .r(r_add));
  ad_rx_fmul u_mul (.a(a), .b(b), .r(r_mul));

  logic [31:0] cx;
  logic [23:0] q;
  logic [49:0] v50;  logic [31:0] f50;
  logic [20:0] v21;  logic [31:0] f21;
  logic [16:0] v17;  logic [31:0] f17;
  ad_rx_f2fix u_fx (.f(cx), .q(q));
  ad_rx_i2f #(.W(50), .F(0)) u_i50 (.v(v50), .f(f50));
  ad_rx_i2f #(.W(21), .F(3)) u_i21 (.v(v21), .f(f21));
  ad_rx_i2f #(.W(17), .F(0)) u_i17 (.v(v17), .f(f17));

  logic clk = 0, rst_n = 0, st = 0, busy, dn;
  logic [31:0] da, db, dr;
  ad_rx_fdiv u_div (.clk(clk), .rst_n(rst_n), .i_start(st), .i_a(da), .i_b(db),
                    .busy(busy), .o_done(dn), .o_r(dr));
  always #5 clk = ~clk;

  logic [99:0]  va [N];
  logic [95:0]  vm [N];
  logic [95:0]  vd [N/4];
  logic [247:0] vc [N];
  int err;

  initial begin
    $readmemh("sim/vec/fp_add.hex", va);
    $readmemh("sim/vec/fp_mul.hex", vm);
    $readmemh("sim/vec/fp_div.hex", vd);
    $readmemh("sim/vec/fp_cvt.hex", vc);

    err = 0;
    for (int i = 0; i < N; i++) begin
      {a, b} = va[i][99:36]; sub = va[i][32];
      #1;
      if (r_add !== va[i][31:0]) begin
        err++; if (err < 10) $display("fadd %h %s %h = %h exp %h", a, sub ? "-" : "+", b, r_add, va[i][31:0]);
      end
    end
    if (err == 0) $display("PASS ad_rx_fadd (%0d vectors)", N); else $display("FAIL ad_rx_fadd %0d", err);

    err = 0;
    for (int i = 0; i < N; i++) begin
      {a, b} = vm[i][95:32];
      #1;
      if (r_mul !== vm[i][31:0]) begin
        err++; if (err < 10) $display("fmul %h * %h = %h exp %h", a, b, r_mul, vm[i][31:0]);
      end
    end
    if (err == 0) $display("PASS ad_rx_fmul (%0d vectors)", N); else $display("FAIL ad_rx_fmul %0d", err);

    err = 0;
    for (int i = 0; i < N; i++) begin
      cx  = vc[i][247:216];
      v50 = vc[i][189:140];
      v21 = vc[i][104:84];
      v17 = vc[i][48:32];
      #1;
      if (q !== vc[i][215:192])   begin err++; if (err < 10) $display("f2fix %h = %h exp %h", cx, q, vc[i][215:192]); end
      if (f50 !== vc[i][139:108]) begin err++; if (err < 10) $display("i2f50 %h = %h exp %h", v50, f50, vc[i][139:108]); end
      if (f21 !== vc[i][83:52])  begin err++; if (err < 10) $display("i2f21 %h = %h exp %h", v21, f21, vc[i][83:52]); end
      if (f17 !== vc[i][31:0])   begin err++; if (err < 10) $display("i2f17 %h = %h exp %h", v17, f17, vc[i][31:0]); end
    end
    if (err == 0) $display("PASS ad_rx_cvt (f2fix, i2f x3, %0d vectors)", N); else $display("FAIL ad_rx_cvt %0d", err);

    err = 0;
    repeat (3) @(posedge clk);
    rst_n = 1;
    for (int i = 0; i < N/4; i++) begin
      @(posedge clk);
      {da, db} = vd[i][95:32];
      st = 1;
      @(posedge clk);
      st = 0;
      while (!dn) @(posedge clk);
      if (dr !== vd[i][31:0]) begin
        err++; if (err < 10) $display("fdiv %h / %h = %h exp %h", da, db, dr, vd[i][31:0]);
      end
    end
    if (err == 0) $display("PASS ad_rx_fdiv (%0d vectors)", N/4); else $display("FAIL ad_rx_fdiv %0d", err);
    $finish;
  end
endmodule
