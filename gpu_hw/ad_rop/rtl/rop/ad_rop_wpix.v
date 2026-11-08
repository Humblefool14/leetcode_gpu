// ad_rop_wpix -- the pixels of ad_rop_wb (spec/gpu/rop/ad_rop_wpix.md): the colour
// attachments' STATE, the place of each pixel of a beat in the lines, the choice of
// the blend path and the new pixel bytes.  Combinational from the inputs to o_*,
// except the STATE registers and the ad_rop_fblend instance (path 1).
// Leaves: ad_fmt_info (format table), ad_wpix_place (places), ad_wpix_old (old pixels),
// ad_fmt_pack (path 2, one a slot), ad_unorm2f #(8) (BLEND_CONST bytes / 255).
`include "ad_rop_state.vh"
module ad_rop_wpix #(
    parameter LINE_BYTES = 32,
    parameter LINE_SHIFT = 5
) (
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire                    st_we,
    input  wire [8:0]              st_idx,
    input  wire [31:0]             st_wdata,
    input  wire [31:0]             i_xy,
    input  wire [1:0]              i_rt,
    input  wire [15:0]             i_smask,
    input  wire [511:0]            i_color,
    input  wire                    i_r,
    input  wire [1:0]              i_j,
    input  wire [1:0]              i_g,
    input  wire [LINE_BYTES*8-1:0] i_line0,
    input  wire [LINE_BYTES*8-1:0] i_line1,
    input  wire [LINE_SHIFT-1:0]   i_off0,
    input  wire [LINE_SHIFT-1:0]   i_off1,
    input  wire [127:0]            b_pix,
    input  wire                    f_go,
    output wire                    f_done,
    input  wire                    f_take,
    output wire [31:0]             o_addr,
    output wire [1:0]              o_nl,
    output wire [1:0]              o_np,
    output wire                    o_multi,
    output wire                    o_drop,
    output wire                    o_read,
    output wire [1:0]              o_path,
    output wire                    o_lw,
    output wire [3:0]              o_mask,
    output wire [511:0]            o_bsrc,
    output wire [127:0]            o_bdst,
    output reg  [511:0]            o_res,
    output wire [3:0]              o_ent,
    output wire [4*LINE_SHIFT-1:0] o_soff,
    output wire [4:0]              o_ps
);
    localparam LS = LINE_SHIFT;

    // ------------------------------------------------------------------ STATE
    reg [31:0] s_base [0:3];
    reg [31:0] s_stride [0:3];
    reg [31:0] s_blend [0:3];
    reg [31:0] s_fcon [0:3];       // BLEND_CONST_R..A
    reg [31:0] s_rtfmt, s_bcon, s_wm, s_fmts;
    reg        s_fconst, s_logic;     // ROP_CTRL[1], ROP_CTRL[2]
    reg [31:0] s_lop;                 // LOGIC_OP (byte k: [0] enable of RT k)
    reg [3:0]  s_ms;
    integer q;
    always @(posedge clk) begin
        if (!rst_n) begin
            for (q = 0; q < 4; q = q + 1) begin
                s_base[q] <= 32'd0; s_stride[q] <= 32'd0; s_blend[q] <= 32'd0; s_fcon[q] <= 32'd0;
            end
            s_rtfmt <= 32'd0; s_bcon <= 32'd0; s_wm <= 32'd0; s_fmts <= 32'd0;
            s_fconst <= 1'b0; s_logic <= 1'b0; s_lop <= 32'd0; s_ms <= 4'd0;
        end else if (st_we) begin
            case (st_idx)
                `AD_S_RT_BASE:       s_base[0]   <= st_wdata;
                `AD_S_RT_STRIDE:     s_stride[0] <= st_wdata;
                `AD_S_RT1_BASE:      s_base[1]   <= st_wdata;
                `AD_S_RT1_STRIDE:    s_stride[1] <= st_wdata;
                `AD_S_RT2_BASE:      s_base[2]   <= st_wdata;
                `AD_S_RT2_STRIDE:    s_stride[2] <= st_wdata;
                `AD_S_RT3_BASE:      s_base[3]   <= st_wdata;
                `AD_S_RT3_STRIDE:    s_stride[3] <= st_wdata;
                `AD_S_RT_FORMAT:     s_rtfmt     <= st_wdata;
                `AD_S_BLEND:         s_blend[0]  <= st_wdata;
                `AD_S_BLEND1:        s_blend[1]  <= st_wdata;
                `AD_S_BLEND2:        s_blend[2]  <= st_wdata;
                `AD_S_BLEND3:        s_blend[3]  <= st_wdata;
                `AD_S_BLEND_CONST:   s_bcon      <= st_wdata;
                `AD_S_BLEND_CONST_R: s_fcon[0]   <= st_wdata;
                `AD_S_BLEND_CONST_G: s_fcon[1]   <= st_wdata;
                `AD_S_BLEND_CONST_B: s_fcon[2]   <= st_wdata;
                `AD_S_BLEND_CONST_A: s_fcon[3]   <= st_wdata;
                `AD_S_WRITE_MASK:    s_wm        <= st_wdata;
                `AD_S_RT_FORMATS:    s_fmts      <= st_wdata;
                `AD_S_ROP_CTRL:      begin s_fconst <= st_wdata[`AD_ROPC_FCONST]; s_logic <= st_wdata[`AD_ROPC_LOGIC]; end
                `AD_S_LOGIC_OP:      s_lop       <= st_wdata;
                `AD_S_MS_CTRL:       s_ms        <= st_wdata[3:0];
                default: ;
            endcase
        end
    end

    // ------------------------------------------------------- the attachment
    wire [7:0] fbyte = s_fmts[8*i_rt +: 8];
    reg  [7:0] fmt;
    always @(*) begin
        fmt = fbyte;
        if (i_rt == 2'd0 && fbyte == 8'd0)
            case (s_rtfmt)
                32'd0:        fmt = `AD_VK_BGRA8;
                32'd1:        fmt = `AD_VK_RGBA8;
                32'd2, 32'd3: fmt = `AD_VK_R5G6B5;
                default:      fmt = 8'd0;
            endcase
    end
    wire [3:0]  wm    = s_wm[4*i_rt +: 4];
    wire [31:0] blend = s_blend[i_rt];
    wire        sup, blendable;
    wire [2:0]  lps;
    wire [3:0]  chm;
    ad_fmt_info u_info (.i_fmt(fmt), .o_sup(sup), .o_ps(o_ps), .o_lps(lps), .o_path(o_path),
                        .o_chm(chm), .o_blendable(blendable));
    assign o_drop = !sup || ((chm & wm) == 4'd0);
    // a logic op (path 0, ad_rop_blend) combines the source with the stored pixel,
    // so the old pixels are needed whenever it is enabled for this attachment
    wire        lop_en = (s_logic | s_lop[8*i_rt]) && (o_path == 2'd0);
    assign o_read = (blend[0] && blendable) || lop_en || ((chm & ~wm) != 4'd0);

    // ------------------------------------------------------------ places
    wire [7:0] lane;
    ad_wpix_place #(.LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT)) u_place (
        .i_base(s_base[i_rt]), .i_stride(s_stride[i_rt]), .i_xy(i_xy), .i_smask(i_smask),
        .i_lps(lps), .i_s4(s_ms == 4'd2), .i_r(i_r), .i_j(i_j), .i_g(i_g),
        .i_off0(i_off0), .i_off1(i_off1),
        .o_addr(o_addr), .o_nl(o_nl), .o_np(o_np), .o_multi(o_multi), .o_lw(o_lw),
        .o_mask(o_mask), .o_ent(o_ent), .o_soff(o_soff), .o_lane(lane));

    wire [511:0] old;
    ad_wpix_old #(.LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT)) u_old (
        .i_line0(i_line0), .i_line1(i_line1), .i_ent(o_ent), .i_soff(o_soff), .i_lps(lps), .o_old(old));

    // slots' sources and 32-bit destinations
    genvar k;
    generate for (k = 0; k < 4; k = k + 1) begin : g_src
        assign o_bsrc[128*k +: 128] = i_color[128*lane[2*k +: 2] +: 128];
        assign o_bdst[32*k +: 32]   = old[128*k +: 32];
    end endgenerate

    // ------------------------------------------------- path 1: ad_rop_fblend
    wire [127:0] fconst;
    wire [31:0]  uc0, uc1, uc2, uc3;
    ad_unorm2f #(.N(8)) u_c0 (.x(s_bcon[7:0]),   .f(uc0));
    ad_unorm2f #(.N(8)) u_c1 (.x(s_bcon[15:8]),  .f(uc1));
    ad_unorm2f #(.N(8)) u_c2 (.x(s_bcon[23:16]), .f(uc2));
    ad_unorm2f #(.N(8)) u_c3 (.x(s_bcon[31:24]), .f(uc3));
    assign fconst = s_fconst ? {s_fcon[3], s_fcon[2], s_fcon[1], s_fcon[0]} : {uc3, uc2, uc1, uc0};

    wire [255:0] fdst = {old[384 +: 64], old[256 +: 64], old[128 +: 64], old[0 +: 64]};
    wire [255:0] fraw, fkeep;
    wire         f_iready;
    ad_rop_fblend u_fblend (
        .clk(clk), .rst_n(rst_n), .i_valid(f_go), .i_ready(f_iready), .i_lanes(o_mask),
        .i_src(o_bsrc), .i_dst(fdst), .i_fmt(fmt), .i_blend(blend[22:0]), .i_const(fconst),
        .i_wm(wm), .o_valid(f_done), .o_ready(f_take), .o_raw(fraw), .o_keep(fkeep));

    // ------------------------------------------------------ path 2: packing
    wire [511:0] praw, pkeep;
    generate for (k = 0; k < 4; k = k + 1) begin : g_pack
        ad_fmt_pack u_pack (.i_src(o_bsrc[128*k +: 128]), .i_fmt(fmt), .i_wm(wm),
                            .o_raw(praw[128*k +: 128]), .o_keep(pkeep[128*k +: 128]));
    end endgenerate

    // ------------------------------------------------------ the new pixels
    integer m;
    always @(*) begin
        for (m = 0; m < 4; m = m + 1) begin
            case (o_path)
                2'd0: o_res[128*m +: 128] = {96'd0, b_pix[32*m +: 32]};
                2'd1: o_res[128*m +: 128] = {64'd0, (fraw[64*m +: 64] & ~fkeep[64*m +: 64]) |
                                                    (old[128*m +: 64] & fkeep[64*m +: 64])};
`ifdef MUT_WPIX_KEEP
                2'd2: o_res[128*m +: 128] = praw[128*m +: 128] & ~pkeep[128*m +: 128];   // mutation
`else
                2'd2: o_res[128*m +: 128] = (praw[128*m +: 128] & ~pkeep[128*m +: 128]) |
                                            (old[128*m +: 128] & pkeep[128*m +: 128]);
`endif
                default: o_res[128*m +: 128] = 128'd0;
            endcase
        end
    end
endmodule
