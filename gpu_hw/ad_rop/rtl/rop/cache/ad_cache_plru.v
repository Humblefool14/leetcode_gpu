// ad_cache_plru -- 4-way tree pseudo-LRU (leaf of ad_rop_cache).  No arithmetic operators.
// State bits (per set): s[0] root: 0 -> victim in ways {0,1}, 1 -> victim in ways {2,3};
// s[1]: 0 -> way 0, 1 -> way 1; s[2]: 0 -> way 2, 1 -> way 3.
// victim = the way the bits point at; touching way w points the bits on w's path away from w.
module ad_cache_plru (
    input  wire [2:0] state,      // current tree bits of the set
    input  wire       touch,      // update with an access to touch_way
    input  wire [1:0] touch_way,
    output wire [2:0] next_state,
    output wire [1:0] victim      // victim of the current state
);
    assign victim = state[0] ? {1'b1, state[2]} : {1'b0, state[1]};

    // on an access to w: root points to the other half, the pair bit to the sibling
    wire [2:0] upd;
    assign upd[0] = ~touch_way[1];
    assign upd[1] = touch_way[1] ? state[1] : ~touch_way[0];
    assign upd[2] = touch_way[1] ? ~touch_way[0] : state[2];
`ifdef MUT_PLRU
    assign next_state = touch ? {upd[2:1], ~upd[0]} : state;   // mutation: root points at w
`else
    assign next_state = touch ? upd : state;
`endif
endmodule
