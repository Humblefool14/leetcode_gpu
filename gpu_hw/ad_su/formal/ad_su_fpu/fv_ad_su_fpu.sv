// fv_ad_su_fpu: the pipeline of ad_su_fpu with the lane datapath stubbed
// (AD_SU_FPU_STUB: res = a ^ rotl(b, 1) ^ c ^ op), NPHYS 4, SHORT_LAT 6.
// A shadow pipeline records every take (x_valid, unit FPU; x_ready = 1):
//  - x_ready is 1;
//  - s_valid exactly SHORT_LAT cycles after a take of a uop with WRD, and
//    never otherwise (other units' groups, idle cycles, WRD = 0, reset);
//  - s_warp/grp/rd/lanes/data are the take's (lanes = EXEC = x_mask[3:0]);
//  - fw4_* / fw5_* equal what s_* shows 2 / 1 cycles later, fw*_valid only
//    when rd < 63 (checked against the shadow and, by past registers,
//    against s_* itself).
module fv_ad_su_fpu (
    input wire          clk,
    input wire          rst_n,
    input wire          x_valid,
    input wire [1:0]    x_warp,
    input wire [2:0]    x_grp,
    input wire          x_last,
    input wire [2:0]    x_sbe,
    input wire [15:0]   x_pc,
    input wire [107:0]  x_uop,
    input wire [127:0]  x_a,
    input wire [127:0]  x_b,
    input wire [127:0]  x_c,
    input wire [7:0]    x_mask,
    input wire [31:0]   x_info
);
`include "ad_su_uop.vh"
    localparam N = 4, SL = 6;

    reg init = 1'b1;
    always @(posedge clk) init <= 1'b0;
    always @(*) if (init) assume (!rst_n);

    wire         x_ready, s_valid, f4v, f5v;
    wire [1:0]   s_warp, f4w, f5w;
    wire [2:0]   s_grp, f4g, f5g;
    wire [6:0]   s_rd, f4r, f5r;
    wire [127:0] s_data, f4d, f5d;
    wire [3:0]   s_lanes, f4l, f5l;
    ad_su_fpu #(.NPHYS(N), .GRP_W(3), .SHORT_LAT(SL)) dut (
        .clk(clk), .rst_n(rst_n), .x_valid(x_valid), .x_warp(x_warp), .x_grp(x_grp),
        .x_last(x_last), .x_sbe(x_sbe), .x_pc(x_pc), .x_uop(x_uop), .x_a(x_a), .x_b(x_b),
        .x_c(x_c), .x_mask(x_mask), .x_info(x_info), .x_ready(x_ready),
        .s_valid(s_valid), .s_warp(s_warp), .s_grp(s_grp), .s_rd(s_rd), .s_data(s_data),
        .s_lanes(s_lanes),
        .fw4_valid(f4v), .fw4_warp(f4w), .fw4_grp(f4g), .fw4_rd(f4r), .fw4_data(f4d),
        .fw4_lanes(f4l), .fw5_valid(f5v), .fw5_warp(f5w), .fw5_grp(f5g), .fw5_rd(f5r),
        .fw5_data(f5d), .fw5_lanes(f5l));

    // Shadow: stage k = the take of k cycles ago.
    wire take = x_valid && x_uop[AD_UOP_UNIT +: 4] == AD_UNIT_FPU && x_ready;
    wire [4:0] o = x_uop[AD_UOP_OP +: 5];
    reg [127:0] exp_d;
    integer l;
    always @(*)
        for (l = 0; l < N; l = l + 1)
            exp_d[l*32 +: 32] = x_a[l*32 +: 32] ^ {x_b[l*32 +: 31], x_b[l*32 + 31]} ^
                                x_c[l*32 +: 32] ^ {27'd0, o};
    reg          hv [1:SL];
    reg [1:0]    hw [1:SL];
    reg [2:0]    hg [1:SL];
    reg [6:0]    hr [1:SL];
    reg [127:0]  hd [1:SL];
    reg [3:0]    hl [1:SL];
    integer k;
    always @(posedge clk) begin
        hv[1] <= rst_n && take && x_uop[AD_UOP_WRD];
        hw[1] <= x_warp; hg[1] <= x_grp; hr[1] <= x_uop[AD_UOP_RD +: 7];
        hd[1] <= exp_d; hl[1] <= x_mask[3:0];
        for (k = 2; k <= SL; k = k + 1) begin
            hv[k] <= rst_n && hv[k-1];
            hw[k] <= hw[k-1]; hg[k] <= hg[k-1]; hr[k] <= hr[k-1];
            hd[k] <= hd[k-1]; hl[k] <= hl[k-1];
        end
        if (init)
            for (k = 1; k <= SL; k = k + 1)
                hv[k] <= 1'b0;
    end

    // Past values of fw4/fw5 for the direct "s_* 2/1 cycles later" check.
    reg p1_f5v, p1_f4v, p2_f4v;
    reg [1:0] p1_f5w, p2_f4w, p1_f4w;
    reg [2:0] p1_f5g, p2_f4g, p1_f4g;
    reg [6:0] p1_f5r, p2_f4r, p1_f4r;
    reg [127:0] p1_f5d, p2_f4d, p1_f4d;
    reg [3:0] p1_f5l, p2_f4l, p1_f4l;
    reg [1:0] npast = 0;
    reg rst_seen1 = 0, rst_seen2 = 0;
    always @(posedge clk) begin
        p1_f5v <= f5v; p1_f5w <= f5w; p1_f5g <= f5g; p1_f5r <= f5r; p1_f5d <= f5d; p1_f5l <= f5l;
        p1_f4v <= f4v; p1_f4w <= f4w; p1_f4g <= f4g; p1_f4r <= f4r; p1_f4d <= f4d; p1_f4l <= f4l;
        p2_f4v <= p1_f4v; p2_f4w <= p1_f4w; p2_f4g <= p1_f4g; p2_f4r <= p1_f4r; p2_f4d <= p1_f4d;
        p2_f4l <= p1_f4l;
        if (npast != 2'd3) npast <= npast + 2'd1;
        rst_seen1 <= !rst_n;
        rst_seen2 <= rst_seen1;
    end

    always @(*) begin
        if (!init) begin
            assert (x_ready);
            assert (s_valid == hv[SL]);
            if (hv[SL]) begin
                assert (s_warp == hw[SL]);
                assert (s_grp == hg[SL]);
                assert (s_rd == hr[SL]);
                assert (s_data == hd[SL]);
                assert (s_lanes == hl[SL]);
            end
            assert (f4v == (hv[SL-2] && hr[SL-2] < 7'd63));
            if (f4v) begin
                assert (f4w == hw[SL-2] && f4g == hg[SL-2] && f4r == hr[SL-2] &&
                        f4d == hd[SL-2] && f4l == hl[SL-2]);
            end
            assert (f5v == (hv[SL-1] && hr[SL-1] < 7'd63));
            if (f5v) begin
                assert (f5w == hw[SL-1] && f5g == hg[SL-1] && f5r == hr[SL-1] &&
                        f5d == hd[SL-1] && f5l == hl[SL-1]);
            end
        end
        // fw5 one cycle ago / fw4 two cycles ago is what s_* shows now
        // (no reset in between).
        if (npast >= 2'd1 && rst_n && !rst_seen1 && p1_f5v)
            assert (s_valid && s_warp == p1_f5w && s_grp == p1_f5g && s_rd == p1_f5r &&
                    s_data == p1_f5d && s_lanes == p1_f5l);
        if (npast >= 2'd2 && rst_n && !rst_seen1 && !rst_seen2 && p2_f4v)
            assert (s_valid && s_warp == p2_f4w && s_grp == p2_f4g && s_rd == p2_f4r &&
                    s_data == p2_f4d && s_lanes == p2_f4l);
        if (!init && s_valid && s_rd < 7'd63 && npast >= 2'd2 && !rst_seen1 && !rst_seen2)
            assert (p1_f5v && p2_f4v);
        // Back-to-back results with forwarding taps busy.
        if (!init)
            cover (s_valid && f4v && f5v && s_rd != f5r);
    end
endmodule
