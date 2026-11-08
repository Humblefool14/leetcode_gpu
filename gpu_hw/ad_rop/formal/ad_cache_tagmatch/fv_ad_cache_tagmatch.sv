// fv_ad_cache_tagmatch -- hit iff some valid way holds the key; way is a matching way, the lowest.
module fv_ad_cache_tagmatch;
    localparam TW = 6;
    (* anyconst *) reg [4*TW-1:0] tags;
    (* anyconst *) reg [3:0] valid;
    (* anyconst *) reg [TW-1:0] key;
    wire hit; wire [1:0] way;
    ad_cache_tagmatch #(.WAYS(4), .TAG_W(TW), .WW(2)) dut (.tags(tags), .valid(valid), .key(key), .hit(hit), .way(way));
    wire [3:0] m;
    genvar g;
    generate for (g = 0; g < 4; g = g + 1) begin : g_m
        assign m[g] = valid[g] && tags[g*TW +: TW] == key;
    end endgenerate
    always @(*) begin
        a_hit: assert (hit == (|m));
        if (hit) begin
            a_way: assert (m[way]);
            a_low: assert ((m & ((4'd1 << way) - 4'd1)) == 4'd0);
        end
    end
endmodule
