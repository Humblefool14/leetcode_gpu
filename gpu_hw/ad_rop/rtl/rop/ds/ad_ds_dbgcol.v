// ad_ds_dbgcol -- DEBUG_COLOR (RGBA8, R in [7:0]) to the 512-bit quad colour:
// each channel through ad_unorm2f #(8), the same RGBA for all four lanes
// (lane l at [128 l +: 128], R G B A at +0 +32 +64 +96).  Combinational.
module ad_ds_dbgcol (
    input  wire [31:0]  rgba8,
    output wire [511:0] color
);
    wire [127:0] lane;
    genvar c;
    generate
        for (c = 0; c < 4; c = c + 1) begin : g_ch
            ad_unorm2f #(.N(8)) u_c (.x(rgba8[8*c +: 8]), .f(lane[32*c +: 32]));
        end
    endgenerate
    assign color = {4{lane}};
endmodule
