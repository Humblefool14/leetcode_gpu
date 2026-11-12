// ad_ram_tdp -- word RAM with two ports (common library; block RAM template;
// was ad_mem_tdpram of ad_su).
// Port A: read or write, read-first, rdata registered when en (held otherwise).
// Port B: read only, rdata registered when en.  No reset (pure datapath).
module ad_ram_tdp #(
    parameter DEPTH = 1024,
    parameter AW    = 10,
    parameter DW    = 32
) (
    input  wire          clk,
    input  wire          a_en,
    input  wire          a_we,
    input  wire [AW-1:0] a_addr,
    input  wire [DW-1:0] a_wdata,
    output reg  [DW-1:0] a_rdata,
    input  wire          b_en,
    input  wire [AW-1:0] b_addr,
    output reg  [DW-1:0] b_rdata
);
    reg [DW-1:0] mem [0:DEPTH-1];
    always @(posedge clk) begin
        if (a_en) begin
`ifdef MUT_RAM_TDP_WFIRST
            a_rdata <= a_we ? a_wdata : mem[a_addr];     // mutation: write-first
`else
            a_rdata <= mem[a_addr];
`endif
            if (a_we) mem[a_addr] <= a_wdata;
        end
    end
    always @(posedge clk) begin
        if (b_en) b_rdata <= mem[b_addr];
    end
endmodule
