// fv_ad_vf_vc_match -- ad_vf_vc_match (NENTRIES 32, KEY_W 32): match[e] == valid[e] && tags[e] == key
// for every entry, written as a per-entry XOR reduction.  Combinational, inputs anyconst.
module fv_ad_vf_vc_match (input wire clk);
    localparam NE = 32;
    (* anyconst *) reg [NE-1:0] valid;
    (* anyconst *) reg [NE*32-1:0] tags;
    (* anyconst *) reg [31:0] key;
    wire [NE-1:0] match;
    ad_vf_vc_match #(.NENTRIES(NE), .KEY_W(32)) dut (.valid(valid), .tags(tags), .key(key), .match(match));
    genvar e;
    generate for (e = 0; e < NE; e = e + 1) begin : g_e
        always @(*) assert (match[e] == (valid[e] && ~|(tags[32*e +: 32] ^ key)));
    end endgenerate
endmodule
