// ad_lsu_wbe -- store lanes to a line's byte enables and write data
// (spec ad_su_lsu.md §4).  Combinational.  Each lane in `lanes` writes its
// whole word at byte address bits [LINE_SHIFT-1:2]; lanes are applied in
// order, so the higher lane wins on the same word.
module ad_lsu_wbe #(
    parameter NPHYS      = 8,
    parameter ADDR_W     = 32,
    parameter LINE_BYTES = 32,
    parameter LINE_SHIFT = 5
) (
    input  wire [NPHYS-1:0]           lanes,
    input  wire [NPHYS*ADDR_W-1:0]    addr,
    input  wire [NPHYS*32-1:0]        data,
    output reg  [LINE_BYTES-1:0]      be,
    output reg  [LINE_BYTES*8-1:0]    wdata
);
    localparam OW = LINE_SHIFT - 2;
    integer i;
    reg [OW-1:0] off;
    always @(*) begin
        be    = {LINE_BYTES{1'b0}};
        wdata = {(LINE_BYTES*8){1'b0}};
        for (i = 0; i < NPHYS; i = i + 1) begin
            off = addr[i*ADDR_W+2 +: OW];
            if (lanes[i]) begin
                be[off*4 +: 4]     = 4'hF;
                wdata[off*32 +: 32] = data[i*32 +: 32];
            end
        end
    end
endmodule
