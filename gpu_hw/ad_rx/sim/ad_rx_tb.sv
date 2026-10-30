// End-to-end test of ad_rx (HAS_SU = 0: every primitive on the direct path).
// Primitives from rx_prims.txt go in one at a time; every dx quad is logged
// to rx_out.txt; tools/rx_ref.py check compares with the reference.
`timescale 1ns/1ps
module ad_rx_tb;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  logic st_we = 0; logic [8:0] st_idx = 0; logic [31:0] st_wdata = 0;
  logic prim_valid = 0, prim_ready, prim_last = 0; logic [25:0] prim_vtx = 0; logic [2:0] prim_free = 0;
  logic pt_rd, pt_free; logic [7:0] pt_idx, pt_free_idx; logic [6:0] pt_word; logic [31:0] pt_rdata;
  logic dx_valid, dx_last, busy, ord_valid; logic [15:0] dx_seq, ord_seq; logic [31:0] dx_xy;
  logic [3:0] dx_mask; logic [127:0] dx_depth;
  logic fl_req, fl_we, fl_pw_we, fl_go; logic [5:0] fl_reg; logic [4:0] fl_lane; logic [31:0] fl_data, fl_pw_data, fl_mask;
  logic [11:0] fl_pw_addr; logic [63:0] fl_info;

  ad_rx #(.HAS_SU(0)) dut (.clk, .rst_n, .st_we, .st_idx, .st_wdata, .raw_kick(1'b0), .busy,
    .prim_valid, .prim_ready, .prim_vtx, .prim_free, .prim_last,
    .pt_rd, .pt_idx, .pt_word, .pt_rdata, .pt_free, .pt_free_idx,
    .fl_req, .fl_gnt(1'b0), .fl_we, .fl_reg, .fl_lane, .fl_data, .fl_pw_we, .fl_pw_addr, .fl_pw_data,
    .fl_go, .fl_mask, .fl_info, .dx_valid, .dx_ready(1'b1), .dx_seq, .dx_xy, .dx_mask, .dx_depth, .dx_last,
    .ord_valid, .ord_seq, .hz_clear(1'b0), .hz_upd(1'b0), .hz_ux(16'd0), .hz_uy(16'd0), .hz_uz(16'd0));

  // PT model: entries 0-2 hold the current primitive's vertices
  logic [31:0] pt [3][4];
  always_ff @(posedge clk) pt_rdata <= pt[pt_idx][pt_word[1:0]];

  task automatic st(input logic [8:0] i, input logic [31:0] d);
    @(negedge clk) begin st_we = 1; st_idx = i; st_wdata = d; end
    @(negedge clk) st_we = 0;
  endtask

  integer fi, fo, n, kind, np, nfree;
  logic [31:0] w [12];
  initial begin
    repeat (3) @(posedge clk); rst_n = 1;
    st(9'h065, 0);                                            // VIEWPORT_IDX 0
    st(9'h050, 32'h4200_0000); st(9'h051, 32'h41C0_0000);     // xs 32, ys 24
    st(9'h052, 32'h4200_0000); st(9'h053, 32'h41C0_0000);     // xo 32, yo 24
    st(9'h054, 32'h3F80_0000); st(9'h055, 32'h0000_0000);     // zs 1, zo 0
    st(9'h073, {16'd48, 16'd64});                             // RT 64 x 48
    fi = $fopen("rx_prims.txt", "r"); fo = $fopen("rx_out.txt", "w");
    np = 0; nfree = 0;
    while (!$feof(fi)) begin
      n = $fscanf(fi, "%d %h %h %h %h %h %h %h %h %h %h %h %h\n", kind,
                  w[0], w[1], w[2], w[3], w[4], w[5], w[6], w[7], w[8], w[9], w[10], w[11]);
      if (n == 13) begin
        for (int v = 0; v < 3; v++) for (int c = 0; c < 4; c++) pt[v][c] = w[4*v + c];
        $fwrite(fo, "P %0d\n", np);
        @(negedge clk) begin prim_valid = 1; prim_vtx = {kind[1:0], 8'd2, 8'd1, 8'd0}; prim_free = 3'b111; end
        while (!prim_ready) @(negedge clk);
        @(negedge clk) prim_valid = 0;
        repeat (2) @(negedge clk);
        while (busy) @(negedge clk);
        np = np + 1;
      end
    end
    $fclose(fo);
    $display("DONE %0d primitives, %0d PT frees", np, nfree);
    $finish;
  end
  always @(posedge clk) begin
    if (dx_valid && dx_mask != 0) $fwrite(fo, "Q %0d %0d %h %h %h %h %h\n", dx_xy[15:0], dx_xy[31:16], dx_mask,
                                          dx_depth[31:0], dx_depth[63:32], dx_depth[95:64], dx_depth[127:96]);
    if (pt_free) nfree = nfree + 1;
  end
  initial begin #50_000_000; $display("TIMEOUT"); $finish; end
endmodule
