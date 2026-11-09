// fv_ad_vf_stguard: for one symbolic guarded index G (anyconst), the value the children last saw
// for G must equal the CP's last write to G whenever the guard holds nothing, and must not change
// while busy_core is high.  Unguarded writes pass through in the same cycle.  hold == something held.
`include "ad_vf_state.vh"
module fv_ad_vf_stguard (
    input wire clk,
    input wire        st_we,
    input wire [8:0]  st_idx,
    input wire [31:0] st_wdata,
    input wire        busy_core
);
    reg init = 1'b1;
    always @(posedge clk) init <= 1'b0;
    wire rst_n = !init;
    (* anyconst *) reg [4:0] gsel;
    wire [8:0] G = (gsel >= 5'd16) ? `AD_S_PROVOKING : (`AD_S_ATTR_LIMIT(0) + {5'd0, gsel[3:0]});
    always @(*) if (init) assume (!st_we);

    wire o_we, hold; wire [8:0] o_idx; wire [31:0] o_wdata;
    ad_vf_stguard dut (.clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata),
        .busy_core(busy_core), .o_we(o_we), .o_idx(o_idx), .o_wdata(o_wdata), .hold(hold));

    reg [31:0] cp_val, ch_val;      // last CP write to G; last value the children saw for G
    reg        cp_seen, ch_seen;
    reg        p_busy;
    reg [31:0] p_ch;
    always @(posedge clk) begin
        if (!rst_n) begin cp_seen <= 0; ch_seen <= 0; end
        else begin
            if (st_we && st_idx == G) begin cp_val <= st_wdata; cp_seen <= 1'b1; end
            if (o_we && o_idx == G) begin ch_val <= o_wdata; ch_seen <= 1'b1; end
        end
        p_busy <= busy_core && rst_n; p_ch <= ch_val;
    end
    wire g_lim = (st_idx >= `AD_S_ATTR_LIMIT(0)) && (st_idx <= `AD_S_ATTR_LIMIT(15));
    wire guarded = g_lim || (st_idx == `AD_S_PROVOKING);
    always @(*) if (rst_n) begin
        if (!hold) assert (cp_seen == ch_seen && (!cp_seen || cp_val == ch_val));
        if (busy_core) assert (!(o_we && (o_idx == G) && !(st_we && st_idx == G && !guarded)));
        if (st_we && !guarded) assert (o_we && o_idx == st_idx && o_wdata == st_wdata);
        if (o_we && !(st_we && o_idx == st_idx && o_wdata == st_wdata)) assert (!busy_core && !st_we);
    end
endmodule
