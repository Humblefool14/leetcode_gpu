// ad_cache_tagmatch -- parallel tag compare of one set (leaf of ad_rop_cache).
// hit = some valid way holds key; way = the lowest such way (ways hold distinct tags,
// so at most one matches).
module ad_cache_tagmatch #(
    parameter WAYS  = 4,
    parameter TAG_W = 21,
    parameter WW    = 2           // $clog2(WAYS)
) (
    input  wire [WAYS*TAG_W-1:0] tags,     // way w in tags[w*TAG_W +: TAG_W]
    input  wire [WAYS-1:0]       valid,
    input  wire [TAG_W-1:0]      key,
    output reg                   hit,
    output reg  [WW-1:0]         way
);
    integer w;
    always @(*) begin
        hit = 1'b0;
        way = {WW{1'b0}};
        for (w = WAYS-1; w >= 0; w = w - 1)
            if (valid[w] && tags[w*TAG_W +: TAG_W] == key) begin
                hit = 1'b1;
                way = w[WW-1:0];
            end
    end
endmodule
