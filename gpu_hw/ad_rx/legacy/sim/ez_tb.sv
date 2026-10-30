// Directed checks for early_z_unit (16 x 16 screen, 8 x 8 tiles, LESS):
//  T1 two fragments of one pixel back to back: z 100 then z 200 -> the 2nd must fail
//  T2 one pixel of a tile written (z 10); query the tile with z_lo 20 -> must NOT reject
//  T3 all 64 pixels of a tile written (z 10); query with z_lo 20 -> reject
module ez_tb;
  logic clk = 0, rst_n = 0; always #5 clk = ~clk;
  logic clear = 0, cd, stall, rv = 0, tq = 0, rej, ev, ew, csr_v = 0, csr_we = 0, rdy, irq;
  logic [15:0] rx = 0, ry = 0, rz = 0, tx = 0, ty = 0, tlo = 0, thi = 0, ex, ey, ez, ewd;
  logic [7:0] ca = 0, ea; logic [31:0] cwd = 0, crd;
  early_z_unit #(.SCREEN_WIDTH(16), .SCREEN_HEIGHT(16)) dut (.clk, .rst_n, .clear_zbuffer(clear), .clear_done(cd),
    .pipeline_stall(stall), .raster_valid(rv), .raster_x(rx), .raster_y(ry), .raster_z(rz),
    .tile_query_valid(tq), .tile_x(tx), .tile_y(ty), .tile_z_lo(tlo), .tile_z_hi(thi), .tile_reject(rej),
    .ez_valid(ev), .ez_x(ex), .ez_y(ey), .ez_z(ez), .ez_z_write(ew), .ez_z_addr(ea), .ez_z_wdata(ewd),
    .shader_stall(1'b0), .csr_valid(csr_v), .csr_we(csr_we), .csr_addr(ca), .csr_wdata(cwd), .csr_rdata(crd),
    .csr_ready(rdy), .irq_o(irq));
  integer passes = 0, t1 = 0, errs = 0;
  always @(posedge clk) if (ev && ex == 3 && ey == 3) passes = passes + 1;
  task frag(input [15:0] x, y, z); @(negedge clk) begin rv = 1; rx = x; ry = y; rz = z; end endtask
  initial begin
    repeat (3) @(posedge clk); rst_n = 1;
    repeat (300) @(posedge clk);               // fixed version: the reset scrub (256 entries)
    @(negedge clk) clear = 1; @(negedge clk) clear = 0;
    while (stall) @(negedge clk);
    // T1
    frag(3, 3, 100); frag(3, 3, 200); @(negedge clk) rv = 0; repeat (6) @(negedge clk);
    if (passes != 1) begin errs++; $display("T1 FAIL: %0d of 2 fragments passed (expected 1)", passes); end
    else $display("T1 pass");
    // T2: tile (1, 1) gets one pixel at z 10
    frag(9, 9, 10); @(negedge clk) rv = 0; repeat (6) @(negedge clk);
    @(negedge clk) begin tq = 1; tx = 1; ty = 1; tlo = 20; thi = 30; end
    #1 if (rej) begin errs++; $display("T2 FAIL: tile rejected with 63 pixels at the clear depth"); end else $display("T2 pass");
    @(negedge clk) tq = 0;
    // T3: the whole tile (0, 1) at z 10
    for (int y = 8; y < 16; y++) for (int x = 0; x < 8; x++) frag(x, y, 10);
    @(negedge clk) rv = 0; repeat (6) @(negedge clk);
    @(negedge clk) begin tq = 1; tx = 0; ty = 1; tlo = 20; thi = 30; end
    #1 if (!rej) begin errs++; $display("T3 FAIL: full tile at z 10 did not reject z_lo 20"); end else $display("T3 pass");
    @(negedge clk) tq = 0;
    $display("%s early_z_unit: %0d failing", errs ? "FAIL" : "PASS", errs);
    $finish;
  end
endmodule
