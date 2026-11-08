// fv_ad_cache_plru -- tree-PLRU leaf against a table reference; the victim after an access
// is never the way just accessed (MRU); no touch keeps the state.
module fv_ad_cache_plru;
    (* anyconst *) reg [2:0] s;
    (* anyconst *) reg [1:0] w;
    (* anyconst *) reg       t;
    wire [2:0] ns; wire [1:0] v;
    ad_cache_plru dut (.state(s), .touch(t), .touch_way(w), .next_state(ns), .victim(v));
    // second instance: victim of the updated state
    wire [2:0] ns2; wire [1:0] v2;
    ad_cache_plru dut2 (.state(ns), .touch(1'b0), .touch_way(2'd0), .next_state(ns2), .victim(v2));

    reg [1:0] ref_v; reg [2:0] ref_ns;
    always @(*) begin
        // victim table, indexed by {s2, s1, s0}
        case (s)
            3'b000: ref_v = 2'd0; 3'b001: ref_v = 2'd2; 3'b010: ref_v = 2'd1; 3'b011: ref_v = 2'd2;
            3'b100: ref_v = 2'd0; 3'b101: ref_v = 2'd3; 3'b110: ref_v = 2'd1; default: ref_v = 2'd3;
        endcase
        // update table: way 0 -> s0=1,s1=1; way 1 -> s0=1,s1=0; way 2 -> s0=0,s2=1; way 3 -> s0=0,s2=0
        case (w)
            2'd0: ref_ns = {s[2], 1'b1, 1'b1};
            2'd1: ref_ns = {s[2], 1'b0, 1'b1};
            2'd2: ref_ns = {1'b1, s[1], 1'b0};
            default: ref_ns = {1'b0, s[1], 1'b0};
        endcase
        if (!t) ref_ns = s;
        a_victim: assert (v == ref_v);
        a_next:   assert (ns == ref_ns);
        if (t) a_not_mru: assert (v2 != w);
        a_hold:   assert (ns2 == ns);
    end
endmodule
