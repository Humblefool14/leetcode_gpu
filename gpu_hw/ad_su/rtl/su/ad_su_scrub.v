// ad_su_scrub -- the address counter of a memory's scrub (spec/gpu/su/ad_su_scrub.md).
// start (one cycle) sets on for DEPTH cycles with a = 0 .. DEPTH-1; a start while
// on begins again; rst_n stops it.  The memory writes 0 at a while on.
module ad_su_scrub #(
    parameter DEPTH = 16,
    parameter AW    = (DEPTH > 2) ? $clog2(DEPTH) : 1
) (
    input  wire          clk,
    input  wire          rst_n,
    input  wire          start,
    output reg           on,
    output reg  [AW-1:0] a
);
    localparam [31:0] LASTW = DEPTH - 1;
    localparam [AW-1:0] LAST = LASTW[AW-1:0];
    always @(posedge clk) begin
        if (!rst_n) begin
            on <= 1'b0;
            a  <= {AW{1'b0}};
        end else if (start) begin
            on <= 1'b1;
            a  <= {AW{1'b0}};
        end else if (on) begin
`ifdef MUT_SCRUB_SHORT
            if (a == LAST - 1'b1) on <= 1'b0;
`else
            if (a == LAST) on <= 1'b0;
`endif
            a <= a + 1'b1;
        end
    end
endmodule
