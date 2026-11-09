// ad_vf_vc_match -- CAM compare of the vertex cache, combinational: match[e] = valid[e] && tag[e] == key.
module ad_vf_vc_match #(
    parameter NENTRIES = 32,
    parameter KEY_W    = 32
) (
    input  wire [NENTRIES-1:0]       valid,
    input  wire [NENTRIES*KEY_W-1:0] tags,      // entry e in [KEY_W*e +: KEY_W]
    input  wire [KEY_W-1:0]          key,
    output wire [NENTRIES-1:0]       match
);
    genvar e;
    generate for (e = 0; e < NENTRIES; e = e + 1) begin : g_m
        assign match[e] = valid[e] && (tags[KEY_W*e +: KEY_W] == key);
    end endgenerate
endmodule
