// ad_rx_edge against sim/edgeref.py (vectors: sim/gen_edge_vec.py)
`timescale 1ns/1ps
module ad_rx_edge_tb;
  localparam int N = 3000;
  localparam int LW = 1060;
  logic [LW-1:0] vec [N];

  logic clk = 0, rst_n = 0, start = 0;
  logic [23:0] lhw, phs; logic [3:0] mode; logic [31:0] smin, smax, rts; logic [2:0] cull; logic vprect;
  logic [6:0] r_ra, r_wa; logic [31:0] r_rd, r_wd; logic r_we, done, front, empty;
  logic [287:0] edges; logic [63:0] bbox;
  logic [31:0] regs [128];
  logic [31:0] wr [7];

  ad_rx_edge dut (.*);
  always #5 clk = ~clk;
  always_ff @(posedge clk) r_rd <= regs[r_ra];
  always_ff @(posedge clk) if (r_we) wr[r_wa - 7'd40] <= r_wd;

  int err, k, cyc;
  logic [LW-1:0] v;
  initial begin
    $readmemh("sim/vec/edge.hex", vec);
    err = 0;
    repeat (3) @(posedge clk);
    rst_n = 1;
    for (int i = 0; i < N; i++) begin
      v = vec[i];
      k = LW;
      k -= 24; lhw    = v[k +: 24];
      k -= 24; phs    = v[k +: 24];
      k -= 4;  mode   = v[k +: 4];
      k -= 32; smin   = v[k +: 32];
      k -= 32; smax   = v[k +: 32];
      k -= 32; rts    = v[k +: 32];
      k -= 4;  cull   = v[k +: 3];
      k -= 4;  vprect = v[k];
      k -= 32; regs[31] = v[k +: 32];  k -= 32; regs[32] = v[k +: 32];
      k -= 32; regs[34] = v[k +: 32];  k -= 32; regs[35] = v[k +: 32];
      k -= 32; regs[37] = v[k +: 32];  k -= 32; regs[38] = v[k +: 32];
      k -= 32; regs[76] = v[k +: 32];  k -= 32; regs[77] = v[k +: 32];
      k -= 32; regs[78] = v[k +: 32];  k -= 32; regs[79] = v[k +: 32];
      @(posedge clk); start <= 1;
      @(posedge clk); start <= 0;
      cyc = 1;
      while (!done) begin @(posedge clk); cyc++; end
      k -= 288;
      if (edges !== v[k +: 288]) begin err++; if (err < 6) $display("[%0d] mode %h edges\n got %h\n exp %h", i, mode, edges, v[k +: 288]); end
      k -= 64;
      if (bbox !== v[k +: 64]) begin err++; if (err < 6) $display("[%0d] bbox %h exp %h", i, bbox, v[k +: 64]); end
      k -= 4; if (front !== v[k]) begin err++; if (err < 6) $display("[%0d] front", i); end
      k -= 4; if (empty !== v[k]) begin err++; if (err < 6) $display("[%0d] empty %b exp %b", i, empty, v[k]); end
      for (int w = 0; w < 7; w++) begin
        k -= 32;
        if (wr[w] !== v[k +: 32]) begin err++; if (err < 6) $display("[%0d] reg %0d = %h exp %h", i, 40 + w, wr[w], v[k +: 32]); end
      end
    end
    if (err == 0) $display("PASS ad_rx_edge (%0d primitives, %0d cycles each)", N, cyc);
    else $display("FAIL ad_rx_edge %0d", err);
    $finish;
  end
endmodule
