// ad_vf_stguard -- holds back STATE writes that the CP may send while a draw runs.
// ad_vf_asm reads PROVOKING (RX STATE 0x05D) and ad_vf_fetch reads ATTR_LIMIT[k] (0x1D0 + k) live
// during a draw, but the CP holds SET_REG only for the VF ranges 0x020-0x04F and 0x1C0-0x1CF while
// the VF is busy (ad_vf.md section 10).  A write to one of these 17 indices that arrives while the
// draw runs (busy_core), or while an older write to the same index is still held, is kept in a
// one-entry-per-index buffer (a newer value overwrites); the held writes are replayed to the
// children one per cycle once the draw is over, in a cycle without a CP write.  hold = something is
// held (ad_vf adds it to busy so the CP waits before the next DRAW).  Every other write passes through
// in the same cycle, unchanged.
`include "ad_vf_state.vh"
module ad_vf_stguard (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        st_we,
    input  wire [8:0]  st_idx,
    input  wire [31:0] st_wdata,
    input  wire        busy_core,
    output wire        o_we,
    output wire [8:0]  o_idx,
    output wire [31:0] o_wdata,
    output wire        hold
);
    // slot 0..15: ATTR_LIMIT[k]; slot 16: PROVOKING
    wire        g_lim  = (st_idx >= `AD_S_ATTR_LIMIT(0)) && (st_idx <= `AD_S_ATTR_LIMIT(15));
    wire        g_prov = (st_idx == `AD_S_PROVOKING);
    wire [4:0]  slot   = g_prov ? 5'd16 : {1'b0, st_idx[3:0]};
    reg  [16:0] pend;
    reg  [31:0] pdata [0:16];
    wire        guarded = g_lim || g_prov;
`ifdef MUT_NO_STGUARD
    wire        keep    = 1'b0;                       // mutation: pass every write through
`else
    wire        keep    = st_we && guarded && (busy_core || pend[slot]);
`endif

    // replay: lowest held slot
    reg  [4:0]  rs;
    integer i;
    always @(*) begin
        rs = 5'd0;
        for (i = 16; i >= 0; i = i - 1) if (pend[i]) rs = i[4:0];
    end
    wire        replay = !busy_core && !st_we && (|pend);
    wire [8:0]  rs_idx = (rs == 5'd16) ? `AD_S_PROVOKING : (`AD_S_ATTR_LIMIT(0) + {5'd0, rs[3:0]});

    always @(posedge clk) begin
        if (!rst_n) pend <= 17'd0;
        else begin
            if (replay) pend[rs] <= 1'b0;
            if (keep) begin pend[slot] <= 1'b1; pdata[slot] <= st_wdata; end
        end
    end

    assign o_we    = (st_we && !keep) || replay;
    assign o_idx   = replay ? rs_idx : st_idx;
    assign o_wdata = replay ? pdata[rs] : st_wdata;
    assign hold    = |pend;
endmodule
