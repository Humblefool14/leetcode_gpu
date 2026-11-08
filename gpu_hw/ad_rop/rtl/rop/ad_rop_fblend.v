// ad_rop_fblend -- fp32 blend path of the render output (spec/gpu/rop/ad_rop_fblend.md).
// Five-stage streaming pipeline, one beat (4 lanes) per cycle:
//   S1 unpack dst (ad_fblend_unpack), clamp src/const for fixed-point formats (ad_fblend_clamp)
//   S2 factors Fs, Fd per channel (ad_fblend_factor)
//   S3 products P = s*Fs, Q = d*Fd (ad_fp_mul)
//   S4 blend op (ad_fblend_combine)
//   S5 encode, write mask, pack (ad_fblend_pack) into the output registers
// An accepted beat (i_valid && i_ready) appears on o_valid exactly 5 cycles later
// when o_ready stays high.  stall = o_valid && !o_ready freezes every stage;
// i_ready = !stall.
module ad_rop_fblend (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         i_valid,
    output wire         i_ready,
    input  wire [3:0]   i_lanes,
    input  wire [511:0] i_src,
    input  wire [255:0] i_dst,
    input  wire [7:0]   i_fmt,
    input  wire [22:0]  i_blend,
    input  wire [127:0] i_const,
    input  wire [3:0]   i_wm,
    output reg          o_valid,
    input  wire         o_ready,
    output reg  [255:0] o_raw,
    output reg  [255:0] o_keep
);
    wire stall = o_valid && !o_ready;
    wire en    = !stall;
    assign i_ready = en;

    // ------------------------------------------------------------ S1: unpack, clamp
    wire [511:0] u_d;
    wire [3:0]   u_fixed;
    wire [511:0] c_s;
    wire [127:0] c_c;
    genvar k, c;
    generate
        for (k = 0; k < 4; k = k + 1) begin : g_s1
            ad_fblend_unpack u_unp (.raw(i_dst[64*k +: 64]), .fmt(i_fmt), .d(u_d[128*k +: 128]),
                                    .fixed(u_fixed[k]), .supported());
            for (c = 0; c < 4; c = c + 1) begin : g_c
                ad_fblend_clamp u_cl (.en(u_fixed[0]), .x(i_src[128*k + 32*c +: 32]),
                                      .y(c_s[128*k + 32*c +: 32]));
            end
        end
        for (c = 0; c < 4; c = c + 1) begin : g_cc
            ad_fblend_clamp u_clc (.en(u_fixed[0]), .x(i_const[32*c +: 32]), .y(c_c[32*c +: 32]));
        end
    endgenerate

    reg         s1_v;
    reg [3:0]   s1_lanes, s1_wm;
    reg [7:0]   s1_fmt;
    reg [22:0]  s1_blend;
    reg [511:0] s1_s, s1_d;
    reg [127:0] s1_c;
    always @(posedge clk) begin
        if (!rst_n) s1_v <= 1'b0;
        else if (en) s1_v <= i_valid;
        if (en) begin
            s1_lanes <= i_lanes; s1_wm <= i_wm; s1_fmt <= i_fmt; s1_blend <= i_blend;
            s1_s <= c_s; s1_d <= u_d; s1_c <= c_c;
        end
    end

    // ------------------------------------------------------------ S2: factors
    wire [511:0] f_s, f_d;
    generate
        for (k = 0; k < 4; k = k + 1) begin : g_s2
            for (c = 0; c < 4; c = c + 1) begin : g_c
                localparam [0:0] AL = (c == 3);
                ad_fblend_factor u_fs (
                    .sel(AL ? s1_blend[15:12] : s1_blend[4:1]), .is_alpha(AL),
                    .s(s1_s[128*k + 32*c +: 32]), .sa(s1_s[128*k + 96 +: 32]),
                    .d(s1_d[128*k + 32*c +: 32]), .da(s1_d[128*k + 96 +: 32]),
                    .c(s1_c[32*c +: 32]),         .ca(s1_c[96 +: 32]),
                    .f(f_s[128*k + 32*c +: 32]));
                ad_fblend_factor u_fd (
                    .sel(AL ? s1_blend[19:16] : s1_blend[8:5]), .is_alpha(AL),
                    .s(s1_s[128*k + 32*c +: 32]), .sa(s1_s[128*k + 96 +: 32]),
                    .d(s1_d[128*k + 32*c +: 32]), .da(s1_d[128*k + 96 +: 32]),
                    .c(s1_c[32*c +: 32]),         .ca(s1_c[96 +: 32]),
                    .f(f_d[128*k + 32*c +: 32]));
            end
        end
    endgenerate

    reg         s2_v;
    reg [3:0]   s2_lanes, s2_wm;
    reg [7:0]   s2_fmt;
    reg [22:0]  s2_blend;
    reg [511:0] s2_s, s2_d, s2_fs, s2_fd;
    always @(posedge clk) begin
        if (!rst_n) s2_v <= 1'b0;
        else if (en) s2_v <= s1_v;
        if (en) begin
            s2_lanes <= s1_lanes; s2_wm <= s1_wm; s2_fmt <= s1_fmt; s2_blend <= s1_blend;
            s2_s <= s1_s; s2_d <= s1_d; s2_fs <= f_s; s2_fd <= f_d;
        end
    end

    // ------------------------------------------------------------ S3: products
    wire [511:0] m_p, m_q;
    generate
        for (k = 0; k < 16; k = k + 1) begin : g_s3
            ad_fp_mul u_p (.a(s2_s[32*k +: 32]), .b(s2_fs[32*k +: 32]), .y(m_p[32*k +: 32]));
            ad_fp_mul u_q (.a(s2_d[32*k +: 32]), .b(s2_fd[32*k +: 32]), .y(m_q[32*k +: 32]));
        end
    endgenerate

    reg         s3_v;
    reg [3:0]   s3_lanes, s3_wm;
    reg [7:0]   s3_fmt;
    reg [22:0]  s3_blend;
    reg [511:0] s3_s, s3_d, s3_p, s3_q;
    always @(posedge clk) begin
        if (!rst_n) s3_v <= 1'b0;
        else if (en) s3_v <= s2_v;
        if (en) begin
            s3_lanes <= s2_lanes; s3_wm <= s2_wm; s3_fmt <= s2_fmt; s3_blend <= s2_blend;
            s3_s <= s2_s; s3_d <= s2_d; s3_p <= m_p; s3_q <= m_q;
        end
    end

    // ------------------------------------------------------------ S4: blend op
    wire [511:0] b_r;
    generate
        for (k = 0; k < 16; k = k + 1) begin : g_s4
            localparam [0:0] AL = ((k % 4) == 3);
            ad_fblend_combine u_cb (.en(s3_blend[0]), .op(AL ? s3_blend[22:20] : s3_blend[11:9]),
                                    .s(s3_s[32*k +: 32]), .d(s3_d[32*k +: 32]),
                                    .p(s3_p[32*k +: 32]), .q(s3_q[32*k +: 32]), .y(b_r[32*k +: 32]));
        end
    endgenerate

    reg         s4_v;
    reg [3:0]   s4_lanes, s4_wm;
    reg [7:0]   s4_fmt;
    reg [511:0] s4_r;
    always @(posedge clk) begin
        if (!rst_n) s4_v <= 1'b0;
        else if (en) s4_v <= s3_v;
        if (en) begin
            s4_lanes <= s3_lanes; s4_wm <= s3_wm; s4_fmt <= s3_fmt; s4_r <= b_r;
        end
    end

    // ------------------------------------------------------------ S5: encode, pack, output
    wire [255:0] p_raw, p_keep;
    generate
        for (k = 0; k < 4; k = k + 1) begin : g_s5
            ad_fblend_pack u_pk (.r(s4_r[128*k +: 128]), .fmt(s4_fmt), .wm(s4_wm), .active(s4_lanes[k]),
                                 .raw(p_raw[64*k +: 64]), .keep(p_keep[64*k +: 64]));
        end
    endgenerate

`ifdef MUT_STALL
    wire en5 = 1'b1;           // mutation: the output stage ignores back-pressure
`else
    wire en5 = en;
`endif
    always @(posedge clk) begin
        if (!rst_n) o_valid <= 1'b0;
        else if (en5) o_valid <= s4_v;
        if (en5) begin
            o_raw <= p_raw; o_keep <= p_keep;
        end
    end
endmodule
