// ad_lsu_scatter -- line data to lane words (spec ad_su_lsu.md §4).
// Combinational.  Lane i in `lanes` gets the word of the line at its byte
// address bits [LINE_SHIFT-1:2] (bits 1:0 ignored); 0 when `error`; lanes not
// in `lanes` give 0.
module ad_lsu_scatter #(
    parameter NPHYS      = 8,
    parameter ADDR_W     = 32,
    parameter LINE_BYTES = 32,
    parameter LINE_SHIFT = 5
) (
    input  wire [LINE_BYTES*8-1:0]    rdata,
    input  wire                       error,
    input  wire [NPHYS*ADDR_W-1:0]    addr,
    input  wire [NPHYS-1:0]           lanes,
    output reg  [NPHYS*32-1:0]        words
);
    localparam OW  = LINE_SHIFT - 2;
    localparam WPL = LINE_BYTES / 4;
    integer i, w;
    reg [OW-1:0] off;
    always @(*) begin
        words = {(NPHYS*32){1'b0}};
        for (i = 0; i < NPHYS; i = i + 1) begin
            off = addr[i*ADDR_W+2 +: OW];
            for (w = 0; w < WPL; w = w + 1)
                if (lanes[i] && !error && {{(32-OW){1'b0}}, off} == w) words[i*32 +: 32] = rdata[w*32 +: 32];
        end
    end
endmodule
