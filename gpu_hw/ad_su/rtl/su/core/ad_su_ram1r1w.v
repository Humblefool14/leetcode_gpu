// ad_su_ram1r1w -- simple dual-port RAM, one write port and one registered read port
// (leaf of ad_su_rf: one per lane and copy).  rq holds while re is 0; a read of the
// word written in the same cycle returns the old word.  No reset of the contents.
module ad_su_ram1r1w #(
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
    (* ram_style = "block" *) reg [DW-1:0] mem [0:DEPTH-1];
    always @(posedge clk) begin
        if (we) mem[wa] <= wd;
        if (re) rq <= mem[ra];
    end
endmodule
