// ============================================================================
// atg_mmu_ram -- simple dual-port RAM, synchronous read (read-first)
// ----------------------------------------------------------------------------
// One write port, one read port, one clock.  Maps to FPGA block RAM / a
// 1R1W SRAM macro.  Contents are not reset: the L2 keeps its valid bits in
// flops, so stale RAM contents are never used.
// ============================================================================
`include "atg_mmu_pkg.vh"
module atg_mmu_ram #(
    parameter DW  = 48,
    parameter AW  = `AMU_L2X,
    parameter DEP = `AMU_L2S
) (
    input  wire          clk,
    input  wire          we,
    input  wire [AW-1:0] wa,
    input  wire [DW-1:0] wd,
    input  wire [AW-1:0] ra,
    output reg  [DW-1:0] rd
`ifdef FORMAL
   ,output wire [DEP*DW-1:0] f_mem      // formal-only view of the array
`endif
);
    reg [DW-1:0] mem [0:DEP-1];
    always @(posedge clk) begin
        if (we) mem[wa] <= wd;
        rd <= mem[ra];
    end
`ifdef FORMAL
    genvar fg;
    generate for (fg = 0; fg < DEP; fg = fg + 1) begin : g_fm
        assign f_mem[fg*DW +: DW] = mem[fg];
    end endgenerate
`endif
endmodule
