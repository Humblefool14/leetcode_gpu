// ad_ram_sp_be -- single-port synchronous RAM with byte write enables (common library;
// was ad_cache_ram of ad_rop).
// Inferable as block RAM (write-enable per byte, registered read).  A read (re) loads
// rdata at the clock edge; rdata holds its value while re is low.  re and a write are
// never used in the same cycle by the parent (read-during-write undefined).
module ad_ram_sp_be #(
    parameter DEPTH  = 128,
    parameter AW     = 7,
    parameter NBYTES = 64
) (
    input  wire                clk,
    input  wire [AW-1:0]       addr,
    input  wire                re,
    input  wire [NBYTES-1:0]   we,
    input  wire [NBYTES*8-1:0] wdata,
    output reg  [NBYTES*8-1:0] rdata
`ifdef AD_FV_RAM
    ,output wire [DEPTH*NBYTES*8-1:0] fv_mem       // formal-only observation port
`endif
);
    reg [NBYTES*8-1:0] mem [0:DEPTH-1];
    integer b;
    always @(posedge clk) begin
        for (b = 0; b < NBYTES; b = b + 1)
`ifdef MUT_RAM_BE_ALL
            if (|we) mem[addr][8*b +: 8] <= wdata[8*b +: 8];   // mutation: byte enables ignored
`else
            if (we[b]) mem[addr][8*b +: 8] <= wdata[8*b +: 8];
`endif
        if (re) rdata <= mem[addr];
    end
`ifdef AD_FV_RAM
    genvar g;
    generate for (g = 0; g < DEPTH; g = g + 1) begin : g_fv
        assign fv_mem[g*NBYTES*8 +: NBYTES*8] = mem[g];
    end endgenerate
`endif
endmodule
