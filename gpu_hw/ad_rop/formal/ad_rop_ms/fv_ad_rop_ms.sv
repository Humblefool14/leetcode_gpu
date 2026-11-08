// ad_rop_ms control properties (ad_fp_add blackboxed: fv_fp_add_stub.v).
// Harness shadow of each accepted beat: its reference sample mask (own
// alpha-to-coverage leaves + an independent mask expression), the quad's
// sample/lane limit, its beat bits, and whether a non-dropped beat is pending.
//  - o_* hold while o_valid && !o_ready
//  - an output only for a pending beat; nothing is taken while one is pending
//  - o_smask == the reference, != 0, a subset of i_aux smask & the lane bits
//  - one sample mode never sets a bit other than 4 l
//  - o_beat, o_xy, o_dbg are the accepted beat's
`include "ad_rop_state.vh"
module fv_ad_rop_ms (
    input wire         clk,
    input wire         st_we,
    input wire [8:0]   st_idx,
    input wire [31:0]  st_wdata,
    input wire         i_valid,
    input wire [31:0]  i_xy,
    input wire [3:0]   i_mask,
    input wire [511:0] i_color,
    input wire [127:0] i_depth,
    input wire         i_dbg,
    input wire [153:0] i_aux,
    input wire         o_ready
);
    reg init = 1'b1;
    always @(posedge clk) init <= 1'b0;
    wire rst_n = !init;

    wire i_ready, o_valid, o_dbg, o_front, busy;
    wire [31:0] o_xy; wire [15:0] o_smask; wire [511:0] o_color, o_sdepth; wire [3:0] o_beat;
    ad_rop_ms dut (.clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata),
        .i_valid(i_valid), .i_ready(i_ready), .i_xy(i_xy), .i_mask(i_mask), .i_color(i_color),
        .i_depth(i_depth), .i_dbg(i_dbg), .i_aux(i_aux), .o_valid(o_valid), .o_ready(o_ready),
        .o_xy(o_xy), .o_smask(o_smask), .o_color(o_color), .o_sdepth(o_sdepth), .o_dbg(o_dbg),
        .o_front(o_front), .o_beat(o_beat), .busy(busy));

    // STATE comes while the module is idle (spec §4, the CP's rule)
    always @(*) if (busy) assume (!st_we);

    // ---- harness mirror of MS_CTRL ----
    reg h_four, h_a2c;
    always @(posedge clk)
        if (!rst_n) begin h_four <= 1'b0; h_a2c <= 1'b0; end
        else if (st_we && st_idx == `AD_S_MS_CTRL) begin
            h_four <= (st_wdata[3:0] == 4'd2); h_a2c <= st_wdata[8];
        end

    // ---- reference mask of a first beat ----
    wire [15:0] am; wire [3:0] ah;
    genvar g;
    generate for (g = 0; g < 4; g = g + 1) begin : g_a
        ad_ms_a2c ua (.alpha(i_color[128*g + 96 +: 32]), .mask(am[4*g +: 4]), .half(ah[g]));
    end endgenerate
    wire        ua2c = h_a2c && !i_dbg;
    wire [15:0] lb   = {{4{i_mask[3]}}, {4{i_mask[2]}}, {4{i_mask[1]}}, {4{i_mask[0]}}};
    wire [15:0] lim  = i_aux[15:0] & lb;
    wire [15:0] h1   = {3'd0, ah[3], 3'd0, ah[2], 3'd0, ah[1], 3'd0, ah[0]};
    wire [15:0] ref_m = h_four ? (lim & (ua2c ? am : 16'hFFFF))
                               : (lim & 16'h1111 & (ua2c ? h1 : 16'hFFFF));

    // ---- shadow of the accepted beat ----
    reg        h_pend, h_drop, h_fq;
    reg [15:0] h_ref, h_lim;
    reg [3:0]  h_beat;
    reg [31:0] h_xy;
    reg        h_dbg;
    wire take = i_valid && i_ready;
    wire first = i_aux[150];
    always @(posedge clk) begin
        if (!rst_n) begin
            h_pend <= 1'b0; h_drop <= 1'b1;
        end else begin
            if (o_valid && o_ready) h_pend <= 1'b0;
            if (take) begin
                if (first) begin
                    h_drop <= (ref_m == 16'd0);
                    h_ref <= ref_m; h_lim <= lim; h_fq <= h_four;
                end
                if (first ? (ref_m != 16'd0) : !h_drop) begin
                    h_pend <= 1'b1;
                    h_beat <= {i_aux[153:152], i_aux[149], i_aux[150]};
                    h_xy <= i_xy; h_dbg <= i_dbg;
                end
            end
        end
    end

    // ---- properties ----
    reg past_ok = 1'b0;
    reg p_valid, p_ready;
    reg [31:0] p_xy; reg [15:0] p_smask; reg [511:0] p_color, p_sdepth; reg p_dbg, p_front; reg [3:0] p_beat;
    always @(posedge clk) begin
        past_ok <= rst_n;
        p_valid <= o_valid; p_ready <= o_ready;
        p_xy <= o_xy; p_smask <= o_smask; p_color <= o_color; p_sdepth <= o_sdepth;
        p_dbg <= o_dbg; p_front <= o_front; p_beat <= o_beat;
    end
    always @(posedge clk) if (rst_n && past_ok && p_valid && !p_ready) begin
        a_hold_v: assert (o_valid);
        a_hold_d: assert (o_xy == p_xy && o_smask == p_smask && o_color == p_color &&
                          o_sdepth == p_sdepth && o_dbg == p_dbg && o_front == p_front && o_beat == p_beat);
    end
    always @(*) if (rst_n) begin
        if (o_valid) begin
            a_pend:  assert (h_pend);
            a_ref:   assert (o_smask == h_ref);
            a_nz:    assert (o_smask != 16'd0);
            a_sub:   assert ((o_smask & ~h_lim) == 16'd0);
            if (!h_fq) a_one: assert ((o_smask & 16'hEEEE) == 16'd0);
            a_beat:  assert (o_beat == h_beat);
            a_xy:    assert (o_xy == h_xy && o_dbg == h_dbg);
        end
        if (h_pend) a_one_at_a_time: assert (!i_ready);
    end
    // reachability
    always @(posedge clk) if (rst_n) begin
        c_four:  cover (o_valid && o_ready && h_fq && o_smask == 16'hFFFF);
        c_later: cover (o_valid && !o_beat[0]);
    end
endmodule
