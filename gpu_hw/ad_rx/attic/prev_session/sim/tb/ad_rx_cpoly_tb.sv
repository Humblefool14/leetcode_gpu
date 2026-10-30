// ad_rx_cpoly against sim/clipref.py (vectors: sim/gen_cpoly_vec.py)
`timescale 1ns/1ps
module ad_rx_cpoly_tb;
  localparam int N  = 400;
  localparam int LW = 16548;
  logic [LW-1:0] vec [N];

  logic clk = 0, rst_n = 0;
  logic [127:0] vp;
  logic ld_we = 0, ld_line = 0, cmd_valid = 0, cmd_ready, cmd_first = 0, done;
  logic [3:0] ld_idx, ld_n, n_out, rd_idx;
  logic [223:0] ld_data, rd_data;
  logic [2:0] cmd_plane;
  ad_rx_cpoly dut (.*);
  always #5 clk = ~clk;

  int err, k, ns, nv, cases_cut;
  logic [LW-1:0] v;
  logic [3:0] pl, ne;
  initial begin
    $readmemh("sim/vec/cpoly.hex", vec);
    err = 0; cases_cut = 0;
    repeat (3) @(posedge clk); rst_n = 1;
    for (int i = 0; i < N; i++) begin
      v = vec[i];
      k = LW;
      k -= 128; vp = v[k +: 128];
      k -= 4; ld_line = v[k];
      k -= 4; ns = v[k +: 4];
      k -= 4; nv = v[k +: 4];
      for (int j = 0; j < 3; j++) begin
        k -= 224;
        @(posedge clk);
        ld_we <= (j < nv); ld_idx <= j; ld_data <= v[k +: 224];
      end
      @(posedge clk); ld_we <= 0;
      for (int s = 0; s < ns; s++) begin
        k -= 4; pl = v[k +: 4];
        k -= 4; ne = v[k +: 4];
        @(posedge clk);
        cmd_valid <= 1; cmd_plane <= pl[2:0]; cmd_first <= (s == 0); ld_n <= nv;
        @(posedge clk);
        while (!cmd_ready) @(posedge clk);
        cmd_valid <= 0;
        while (!done) @(posedge clk);
        if (n_out !== ne) begin
          err++; if (err < 8) $display("[%0d] plane %0d n_out %0d exp %0d", i, pl, n_out, ne);
        end
        for (int q = 0; q < 10; q++) begin
          k -= 224;
          if (q < ne) begin
            rd_idx <= q; @(posedge clk); @(posedge clk);
            if (rd_data !== v[k +: 224]) begin
              err++; if (err < 8) $display("[%0d] plane %0d vtx %0d\n got %h\n exp %h", i, pl, q, rd_data, v[k +: 224]);
            end
          end
        end
        if (ne != nv) cases_cut++;
      end
    end
    if (err == 0) $display("PASS ad_rx_cpoly (%0d primitives, %0d plane cuts that changed the polygon)", N, cases_cut);
    else $display("FAIL ad_rx_cpoly %0d", err);
    $finish;
  end
endmodule
