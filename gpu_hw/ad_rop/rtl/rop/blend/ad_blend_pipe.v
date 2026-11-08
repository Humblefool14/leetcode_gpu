// ad_blend_pipe -- the 3-stage unorm8 blend datapath of ad_rop_blend (spec ad_rop_blend.md §4, §6).
// The beat's selected state (from ad_blend_state) is captured with the beat at in_valid.
//   stage 1 (into r1): f2u8 of src/src1, unpack of dst
//   stage 2 (into r2): factors and the 8x8 products
//   stage 3 (into r3): div255 + VkBlendOp, logic op, pack, write/lane mask merge
// out_valid is in_valid delayed by exactly 3 cycles; one beat per cycle, no stall.
// NLANE (1..4, default 4) builds the datapath for lanes 0..NLANE-1 only; the other lanes
// return b_dst (formal tractability; ad_rop_blend always uses 4).
`include "ad_rop_state.vh"
module ad_blend_pipe #(
    parameter NLANE = 4
) (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         in_valid,
    input  wire [511:0] src,
    input  wire [511:0] src1,
    input  wire         has_src1,
    input  wire [127:0] dst,
    input  wire [3:0]   mask,
    input  wire [26:0]  blend,
    input  wire [7:0]   fmt,
    input  wire [3:0]   wmask,
    input  wire         lop_en,
    input  wire [3:0]   lop_op,
    input  wire [31:0]  kconst,
    input  wire         dual,
    output wire         out_valid,
    output wire [127:0] pix
);
    // ---------------- valid pipeline (reset) ----------------
    reg v1, v2, v3;
    always @(posedge clk) begin
        if (!rst_n) begin v1 <= 1'b0; v2 <= 1'b0; v3 <= 1'b0; end
        else begin v1 <= in_valid; v2 <= v1; v3 <= v2; end
    end
    assign out_valid = v3;

    // ---------------- per-beat state (datapath, qualified by v*) ----------------
    reg [26:0]  bl1;  reg [7:0] fmt1, fmt2; reg [3:0] wm1, wm2;
    reg         lo1, lo2; reg [3:0] lop1, lop2; reg [31:0] k1; reg du1;
    reg [3:0]   m1, m2;  reg [127:0] dst1, dst2;
    reg         ben2; reg [2:0] cop2, aop2;
    always @(posedge clk) begin
        bl1 <= blend; fmt1 <= fmt; wm1 <= wmask; lo1 <= lop_en; lop1 <= lop_op;
        k1 <= kconst; du1 <= dual; m1 <= mask; dst1 <= dst;
        fmt2 <= fmt1; wm2 <= wm1; lo2 <= lo1; lop2 <= lop1; m2 <= m1; dst2 <= dst1;
        ben2 <= bl1[0]; cop2 <= bl1[11:9]; aop2 <= bl1[22:20];
    end

    // factor selects of the beat in stage 2 ({MSB, 4 bits} only with ROP_CTRL[7])
    wire [4:0] f_sc = {du1 & bl1[23], bl1[4:1]};
    wire [4:0] f_dc = {du1 & bl1[24], bl1[8:5]};
    wire [4:0] f_sa = {du1 & bl1[25], bl1[15:12]};
    wire [4:0] f_da = {du1 & bl1[26], bl1[19:16]};

    reg [127:0] pix3;
    assign pix = pix3;

    genvar l, c;
    generate
        for (l = 0; l < 4; l = l + 1) begin : g_lane
            if (l < NLANE) begin : g_dp
                // ---- stage 1: convert, unpack ----
                wire [31:0] s_w, s1_w, d_w;     // RGBA8 {A,B,G,R}
                for (c = 0; c < 4; c = c + 1) begin : g_cv
                    wire [7:0] u0, u1;
                    ad_rop_f2u8 u_s  (.f(src [128*l + 32*c +: 32]), .u(u0));
                    ad_rop_f2u8 u_s1 (.f(src1[128*l + 32*c +: 32]), .u(u1));
                    assign s_w [8*c +: 8] = u0;
                    assign s1_w[8*c +: 8] = has_src1 ? u1 : 8'd0;
                end
                wire unp_ok;
                ad_blend_unpack8 u_unp (.lane(dst[32*l +: 32]), .fmt(fmt),
                    .r(d_w[7:0]), .g(d_w[15:8]), .b(d_w[23:16]), .a(d_w[31:24]), .ok(unp_ok));

                reg [31:0] s_r1, s1_r1, d_r1;
                always @(posedge clk) begin
                    s_r1 <= s_w; s1_r1 <= s1_w; d_r1 <= d_w;
                end

                // ---- stage 2: factors, products ----
                wire [31:0] fs_w, fd_w;
                for (c = 0; c < 4; c = c + 1) begin : g_f
                    localparam ISA = (c == 3) ? 1 : 0;
                    ad_blend_factor8 u_fs (.sel(ISA ? f_sa : f_sc), .dual(du1), .is_alpha(ISA[0]),
                        .s_c(s_r1[8*c +: 8]),  .s_a(s_r1[31:24]),
                        .d_c(d_r1[8*c +: 8]),  .d_a(d_r1[31:24]),
                        .k_c(k1[8*c +: 8]),    .k_a(k1[31:24]),
                        .s1_c(s1_r1[8*c +: 8]), .s1_a(s1_r1[31:24]),
                        .f(fs_w[8*c +: 8]));
                    ad_blend_factor8 u_fd (.sel(ISA ? f_da : f_dc), .dual(du1), .is_alpha(ISA[0]),
                        .s_c(s_r1[8*c +: 8]),  .s_a(s_r1[31:24]),
                        .d_c(d_r1[8*c +: 8]),  .d_a(d_r1[31:24]),
                        .k_c(k1[8*c +: 8]),    .k_a(k1[31:24]),
                        .s1_c(s1_r1[8*c +: 8]), .s1_a(s1_r1[31:24]),
                        .f(fd_w[8*c +: 8]));
                end

                reg [31:0] s_r2, d_r2;
                reg [63:0] ps_r2, pd_r2;
                integer i;
                always @(posedge clk) begin
                    s_r2 <= s_r1; d_r2 <= d_r1;
                    for (i = 0; i < 4; i = i + 1) begin
                        ps_r2[16*i +: 16] <= s_r1[8*i +: 8] * fs_w[8*i +: 8];
                        pd_r2[16*i +: 16] <= d_r1[8*i +: 8] * fd_w[8*i +: 8];
                    end
                end

                // ---- stage 3: op, pack, logic op, merge ----
                wire [31:0] bo_w;
                for (c = 0; c < 4; c = c + 1) begin : g_op
                    ad_blend_op8 u_op (.ps(ps_r2[16*c +: 16]), .pd(pd_r2[16*c +: 16]),
                        .s(s_r2[8*c +: 8]), .d(d_r2[8*c +: 8]),
                        .op((c == 3) ? aop2 : cop2), .y(bo_w[8*c +: 8]));
                end
                // logic op packs the source alone; blend disabled -> the source
                wire [31:0] v_w = (lo2 | ~ben2) ? s_r2 : bo_w;
                wire [31:0] pk, keep, lg;
                ad_blend_pack8 u_pack (.r(v_w[7:0]), .g(v_w[15:8]), .b(v_w[23:16]), .a(v_w[31:24]),
                    .fmt(fmt2), .wm(wm2), .bits(pk), .keep(keep));
                ad_blend_logicop u_lop (.s(pk), .d(dst2[32*l +: 32]), .op(lop2), .y(lg));
                wire [31:0] res  = lo2 ? lg : pk;
                wire [31:0] kp   = keep | {32{~m2[l]}};
                always @(posedge clk)
                    pix3[32*l +: 32] <= (kp & dst2[32*l +: 32]) | (~kp & res);
            end else begin : g_bypass
                always @(posedge clk)
                    pix3[32*l +: 32] <= dst2[32*l +: 32];
            end
        end
    endgenerate
endmodule
