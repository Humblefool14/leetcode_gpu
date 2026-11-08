// ad_hazard_cam -- parallel tag compare (leaf of ad_rop_hazard).
// match[i] = en[i] && tags[i] == key.  tags is the flattened entry array, entry i in
// tags[i*TAG_W +: TAG_W].
module ad_hazard_cam #(
    parameter N     = 16,
    parameter TAG_W = 32
) (
    input  wire [N*TAG_W-1:0] tags,
    input  wire [N-1:0]       en,
    input  wire [TAG_W-1:0]   key,
    output wire [N-1:0]       match
);
    genvar g;
    generate for (g = 0; g < N; g = g + 1) begin : g_cmp
        assign match[g] = en[g] && (tags[g*TAG_W +: TAG_W] == key);
    end endgenerate
endmodule
