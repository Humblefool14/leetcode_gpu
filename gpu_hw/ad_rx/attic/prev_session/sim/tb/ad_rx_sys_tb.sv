// ad_rx system testbench: STATE, a PT memory, primitives in; warps out.
// Vectors and checker: sim/sys_test.py.
`timescale 1ns/1ps
module ad_rx_sys_tb;
  localparam int NP = 64;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  logic st_we = 0; logic [8:0] st_idx; logic [31:0] st_wdata;
  logic raw_kick = 0, busy;
  logic prim_valid = 0, prim_ready; logic [25:0] prim_vtx; logic [2:0] prim_free; logic prim_last;
  logic pt_rd; logic [7:0] pt_idx; logic [6:0] pt_word; logic [31:0] pt_rdata;
  logic pt_free; logic [7:0] pt_free_idx;
  logic fl_req, fl_gnt = 0, fl_we, fl_pw_we, fl_go; logic [5:0] fl_reg; logic [4:0] fl_lane;
  logic [31:0] fl_data, fl_pw_data, fl_mask; logic [11:0] fl_pw_addr; logic [63:0] fl_info;
  logic dx_valid, dx_ready = 1, dx_last; logic [15:0] dx_seq; logic [31:0] dx_xy;
  logic [3:0] dx_mask; logic [127:0] dx_depth;
  logic ord_valid; logic [15:0] ord_seq;

  ad_rx #(.HZ_AW(8)) dut (.*, .hz_clr(1'b0), .hz_clrz(16'hFFFF), .hz_uwe(1'b0), .hz_uaddr(8'd0), .hz_uz(16'd0));

  logic [31:0] pt [256*8];
  always_ff @(posedge clk) pt_rdata <= pt[{pt_idx, pt_word[2:0]}];

  // SU model: grant two cycles after a request; keep the warp's registers
  logic [31:0] regs [32][10];
  logic [31:0] tri_id;
  int fd, nwarps, nfr;
  logic [1:0] gcnt;
  always_ff @(posedge clk) begin
    fl_gnt <= 1'b0;
    if (fl_req && !fl_gnt) begin gcnt <= gcnt + 1; if (gcnt == 2'd2) begin fl_gnt <= 1'b1; gcnt <= 0; end end
    if (fl_we) regs[fl_lane][fl_reg] <= fl_data;
    if (fl_pw_we && fl_pw_addr == 12'h000) tri_id <= fl_pw_data;
    if (fl_go) begin
      nwarps++;
      for (int l = 0; l < 32; l++)
        if (fl_info[l]) begin
          nfr++;
          $fdisplay(fd, "F %h %h %h %h %h %h %h %h", tri_id, regs[l][4], regs[l][5], regs[l][6],
                    regs[l][0], regs[l][1], regs[l][2], regs[l][3]);
        end
    end
    if (pt_free) $fdisplay(fd, "P %h", pt_free_idx);
  end

  logic [43:0] stv [32];
  logic [25:0] pv  [NP];
  logic [35:0] pr  [NP];
  int idle;
  initial begin
    gcnt = 0; nwarps = 0; nfr = 0;
    for (int i = 0; i < 32; i++) stv[i] = '1;
    for (int i = 0; i < NP; i++) pr[i] = '1;
    $readmemh("sim/vec/sys_state.hex", stv);
    $readmemh("sim/vec/sys_pt.hex", pt);
    $readmemh("sim/vec/sys_prims.hex", pr);
    fd = $fopen("build/sys_frags.txt", "w");
    repeat (4) @(posedge clk); rst_n = 1;
    for (int i = 0; i < 32; i++) if (stv[i] != '1) begin
      @(posedge clk); st_we <= 1; st_idx <= stv[i][40:32]; st_wdata <= stv[i][31:0];
    end
    @(posedge clk); st_we <= 0;
    for (int i = 0; i < NP; i++) begin
      if (pr[i] == '1) break;
      @(posedge clk);
      prim_valid <= 1;
      prim_vtx   <= {pr[i][33:32], pr[i][31:8]};
      prim_free  <= pr[i][6:4];
      prim_last  <= pr[i][0];
      @(posedge clk);
      while (!prim_ready) @(posedge clk);
      prim_valid <= 0;
    end
    idle = 0;
    while (idle < 200) begin @(posedge clk); idle = busy ? 0 : idle + 1; end
    $fclose(fd);
    $display("SIM ad_rx_sys: %0d warps, %0d fragments", nwarps, nfr);
    $finish;
  end
endmodule
