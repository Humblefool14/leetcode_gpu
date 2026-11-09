// ad_mem_tdpram -- word RAM with two ports (block RAM template).
// Port A: read or write, read-first, rdata registered when en (held otherwise).
// Port B: read only, rdata registered when en.  No reset (pure datapath).
module ad_mem_tdpram #(
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
            a_rdata <= mem[a_addr];
            if (a_we) mem[a_addr] <= a_wdata;
        end
    end
    always @(posedge clk) begin
        if (b_en) b_rdata <= mem[b_addr];
    end
endmodule
