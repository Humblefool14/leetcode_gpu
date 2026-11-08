// ad_rop_fblend handshake / pipeline properties (datapath reduced, see fv_stubs.v):
//  a_ready   i_ready == !(o_valid && !o_ready)
//  a_hold    while o_valid && !o_ready, next cycle o_valid stays 1 and o_raw/o_keep are unchanged
//  a_tag     every emitted beat carries the tag of the next expected beat
//            (tag = 4-bit count of accepted beats, injected in i_src[3:0] of lane 0):
//            no beat lost, duplicated or reordered
//  a_outst   0 <= accepted - emitted <= 5, and o_valid implies at least one outstanding beat
//  a_lat     after 5 cycles of o_ready = 1, o_valid == (a beat was accepted exactly 5 cycles ago)
module fv_ad_rop_fblend (
    input wire         clk,
    input wire         rst_n,
    input wire         i_valid,
    input wire [3:0]   i_lanes,
    input wire [511:0] i_src,
    input wire [255:0] i_dst,
    input wire [7:0]   i_fmt,
    input wire [22:0]  i_blend,
    input wire [127:0] i_const,
    input wire [3:0]   i_wm,
    input wire         o_ready
);
    wire         i_ready, o_valid;
    wire [255:0] o_raw, o_keep;
    ad_rop_fblend dut (
        .clk(clk), .rst_n(rst_n), .i_valid(i_valid), .i_ready(i_ready), .i_lanes(i_lanes),
        .i_src(i_src), .i_dst(i_dst), .i_fmt(i_fmt), .i_blend(i_blend), .i_const(i_const),
        .i_wm(i_wm), .o_valid(o_valid), .o_ready(o_ready), .o_raw(o_raw), .o_keep(o_keep));

    reg init = 1'b1;
    always @(posedge clk) init <= 1'b0;
    always @(*) if (init) assume (!rst_n);

    wire acc = i_valid && i_ready;
    wire emt = o_valid && o_ready;
    reg [3:0] acc_cnt, emt_cnt;
    reg [4:0] hist;          // hist[j] = a beat was accepted j+1 cycles ago
    reg [2:0] rdy_run;       // consecutive past cycles (out of reset) with o_ready = 1, saturating
    reg       p_stall, p_rst;
    reg [255:0] p_raw, p_keep;
    always @(posedge clk) begin
        if (!rst_n) begin
            acc_cnt <= 0; emt_cnt <= 0; hist <= 0; rdy_run <= 0;
        end else begin
            acc_cnt <= acc_cnt + acc;
            emt_cnt <= emt_cnt + emt;
            hist    <= {hist[3:0], acc};
            rdy_run <= !o_ready ? 3'd0 : (rdy_run == 3'd7 ? 3'd7 : rdy_run + 3'd1);
        end
        p_stall <= o_valid && !o_ready;
        p_rst   <= rst_n;
        p_raw   <= o_raw;
        p_keep  <= o_keep;
    end
    wire [3:0] outst = acc_cnt - emt_cnt;

    always @(*) begin
        if (rst_n && i_valid) assume (i_src[3:0] == acc_cnt);
        if (!init && rst_n) begin
            a_ready: assert (i_ready == !(o_valid && !o_ready));
            a_outst: assert (outst <= 4'd5);
            if (o_valid) a_nonempty: assert (outst != 4'd0);
            if (o_valid) a_tag: assert (o_raw[3:0] == emt_cnt);
            if (rdy_run >= 3'd5) a_lat: assert (o_valid == hist[4]);
        end
    end
    always @(posedge clk) begin
        if (!init && p_rst && rst_n && p_stall)
            a_hold: assert (o_valid && o_raw == p_raw && o_keep == p_keep);
    end
    always @(*) if (!init && rst_n) begin
        c_stall: cover (p_stall && o_valid && hist[4]);
        c_full:  cover (outst == 4'd5);
    end
endmodule
