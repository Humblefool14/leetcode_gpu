// ad_ram_1r1w -- simple dual-port RAM (common library): one write port and one
// registered read port.  rq holds while re is 0; a read of the word written in
// the same cycle returns the old word.  No reset of the contents.
// Replaces ad_su_ram1r1w (ad_su).
module ad_ram_1r1w #(
    parameter DW    = 32,
    parameter AW    = 5,
    parameter DEPTH = 1 << AW
) (
    input  wire          clk,
    input  wire          we,
    input  wire [AW-1:0] wa,
    input  wire [DW-1:0] wd,
    input  wire          re,
    input  wire [AW-1:0] ra,
    output reg  [DW-1:0] rq
);
    reg [DW-1:0] mem [0:DEPTH-1];
    always @(posedge clk) begin
        if (we) mem[wa] <= wd;
`ifdef MUT_RAM_WFIRST
        if (re) rq <= (we && wa == ra) ? wd : mem[ra];   // mutation: write-first
`else
        if (re) rq <= mem[ra];
`endif
    end
endmodule
