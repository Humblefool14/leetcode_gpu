// ad_su -- one shader unit (spec ad_su.md): wiring only.
//   sched -> fetch <-> icache -> dec -> sb -> opd -> x_* bus -> 12 units -> wb -> rf
//   MC clients: d_* = D$ (lsu + dcache), i_* = I$ + constant bank (ad_amb_mux: icache 0, cbank 1).
//   Integration notes (architecture document): ALU/FPU forwarding taps fw4/fw5 drive opd's
//   fwd_alu_*/fwd_fpu_*; the RF write port drives fwd_wb_*; the meshlet export stream has no
//   port on ad_su in its spec, so it is exposed as mesh_* outputs (mesh_ready an input).
module ad_su #(
    parameter NPHYS        = 8,
    parameter NWARPS       = 4,
    parameter WARP_W       = 2,
    parameter GRP_W        = (NPHYS >= 32) ? 1 : $clog2(32 / NPHYS),   // log2(32/NPHYS), 1 for NPHYS 32
    parameter NREGS        = 32,
    parameter SB_ENTRIES   = 4,
    parameter SBE_W        = 2,
    parameter UOP_W        = 108,
    parameter SHORT_LAT    = 6,
    parameter NSU          = 1,
    parameter SU_INDEX     = 0,
    parameter FRAG_RESERVE = 1,
    parameter PACKED       = 0,
    parameter SUBGROUP     = 0,
    parameter HAS_SA       = 0,
    parameter MS4          = 0,
    parameter LDS_BYTES    = 4096,
    parameter PT_ENTRIES   = 64,
    parameter VARY_WORDS   = 16,
    parameter ADDR_W       = 32,
    parameter LINE_BYTES   = 32,
    parameter LINE_SHIFT   = 5
) (
    input  wire clk, input wire rst_n,
    // STATE and CP
    input  wire st_we, input wire [8:0] st_idx, input wire [31:0] st_wdata,
    input  wire cs_kick, input wire lc_kick, input wire [3:0] inv,
    input  wire scrub, output wire scrub_busy,
    // vertex warps (VF)
    input  wire vl_req, output wire vl_gnt, output wire [WARP_W-1:0] vl_slot, output wire [7:0] vl_ptbase,
    input  wire vl_we, input wire [5:0] vl_reg, input wire [4:0] vl_lane, input wire [31:0] vl_data,
    input  wire vl_go, input wire [31:0] vl_mask,
    // fragment warps (RX)
    input  wire fl_req, output wire fl_gnt, output wire [WARP_W-1:0] fl_slot,
    input  wire fl_we, input wire [5:0] fl_reg, input wire [4:0] fl_lane, input wire [31:0] fl_data,
    input  wire fl_pw_we, input wire [11:0] fl_pw_addr, input wire [31:0] fl_pw_data,
    input  wire fl_go, input wire [31:0] fl_mask, input wire [63:0] fl_info,
    // PT read (RX)
    input  wire pt_rd, input wire [7:0] pt_idx, input wire [6:0] pt_word, output wire [31:0] pt_rdata,
    input  wire pt_free, input wire [7:0] pt_free_idx, output wire [7:0] pt_done,
    // TU
    output wire tx_valid, input wire tx_ready, output wire [7:0] tx_op, output wire [3:0] tx_slot,
    output wire tx_vs, output wire [3:0] tx_mask, output wire [639:0] tx_coord, output wire [11:0] tx_off,
    output wire [15:0] tx_tag, output wire tx_last,
    input  wire tr_valid, output wire tr_ready, input wire [15:0] tr_tag, input wire [511:0] tr_data,
    input  wire tr_last,
    // ROP
    output wire ex_valid, input wire ex_ready, output wire [15:0] ex_seq, output wire [31:0] ex_xy,
    output wire [3:0] ex_mask, output wire [511:0] ex_color, output wire [127:0] ex_depth,
    output wire ex_last, output wire [153:0] ex_aux, input wire [15:0] ex_next,
    // meshlet export (rasterizer setup)
    output wire mesh_valid, input wire mesh_ready, output wire [701:0] mesh_tri, output wire mesh_last,
    output wire [15:0] mesh_id,
    // AMB client: D$
    output wire d_req_valid, input wire d_req_ready, output wire d_req_write,
    output wire [ADDR_W-LINE_SHIFT-1:0] d_req_line, output wire [LINE_BYTES-1:0] d_req_be,
    output wire [LINE_BYTES*8-1:0] d_req_wdata, output wire [7:0] d_req_tag,
    input  wire d_rsp_valid, input wire d_rsp_write, input wire [7:0] d_rsp_tag,
    input  wire [LINE_BYTES*8-1:0] d_rsp_rdata, input wire d_rsp_error,
    // AMB client: I$ + constants
    output wire i_req_valid, input wire i_req_ready, output wire i_req_write,
    output wire [ADDR_W-LINE_SHIFT-1:0] i_req_line, output wire [LINE_BYTES-1:0] i_req_be,
    output wire [LINE_BYTES*8-1:0] i_req_wdata, output wire [7:0] i_req_tag,
    input  wire i_rsp_valid, input wire i_rsp_write, input wire [7:0] i_rsp_tag,
    input  wire [LINE_BYTES*8-1:0] i_rsp_rdata, input wire i_rsp_error,
    // atomics
    output wire at_valid, input wire at_ready, output wire [3:0] at_op, output wire [29:0] at_addr,
    output wire [31:0] at_a, output wire [31:0] at_b, input wire at_rsp_valid, input wire [31:0] at_old,
    input  wire at_error,
    // systolic array (reserved)
    output wire sa_push_valid, input wire sa_push_ready, output wire [NPHYS*32-1:0] sa_push_data,
    input  wire sa_pop_valid, output wire sa_pop_ready, input wire [NPHYS*32-1:0] sa_pop_data,
    output wire sa_ctl_valid, output wire [31:0] sa_ctl_data,
    input  wire [31:0] sa_qstat, input wire [31:0] sa_stat, input wire [31:0] sa_qtag,
    // status
    output wire busy, output wire fault, output wire [31:0] fault_addr
);
    `include "ad_su_uop.vh"
    localparam LW  = ADDR_W - LINE_SHIFT;
    localparam NPW = NPHYS * 32;
    localparam LDS_AW = $clog2(LDS_BYTES / 4);

    // ---------------- front end ----------------
    wire f_valid, f_ready; wire [WARP_W-1:0] f_warp; wire [15:0] f_pc; wire [31:0] f_addr;
    wire fb_valid; wire [WARP_W-1:0] fb_warp; wire [1:0] fb_kind; wire [NWARPS-1:0] wake, warp_ready;
    wire wc_valid; wire [WARP_W-1:0] wc_warp; wire [1:0] wc_op; wire [15:0] wc_pc;
    wire [WARP_W-1:0] q_warp; wire [159:0] q_info; wire [31:0] q_exec, q_killed;
    wire init_valid; wire [WARP_W-1:0] init_warp; wire [31:0] init_mask;
    wire pt_ok; wire xr_valid; wire [WARP_W-1:0] xr_warp; wire sched_busy;

    ad_su_sched #(.NPHYS(NPHYS), .NWARPS(NWARPS), .WARP_W(WARP_W), .NSU(NSU), .SU_INDEX(SU_INDEX),
                  .FRAG_RESERVE(FRAG_RESERVE)) u_sched (
        .clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata), .cs_kick(cs_kick),
        .vl_req(vl_req), .vl_gnt(vl_gnt), .vl_slot(vl_slot), .vl_go(vl_go), .vl_mask(vl_mask),
        .fl_req(fl_req), .fl_gnt(fl_gnt), .fl_slot(fl_slot), .fl_go(fl_go), .fl_mask(fl_mask), .fl_info(fl_info),
        .f_valid(f_valid), .f_ready(f_ready), .f_warp(f_warp), .f_pc(f_pc), .f_addr(f_addr),
        .fb_valid(fb_valid), .fb_warp(fb_warp), .fb_kind(fb_kind), .wake(wake), .warp_ready(warp_ready),
        .wc_valid(wc_valid), .wc_warp(wc_warp), .wc_op(wc_op), .wc_pc(wc_pc),
        .q_warp(q_warp), .q_info(q_info), .init_valid(init_valid), .init_warp(init_warp), .init_mask(init_mask),
        .pt_ok(pt_ok), .xr_valid(xr_valid), .xr_warp(xr_warp), .busy(sched_busy));

    wire ic_req, ic_ready, ic_rvalid; wire [31:0] ic_addr; wire [63:0] ic_rdata;
    wire d_valid, d_ready; wire [WARP_W-1:0] d_warp; wire [15:0] d_pc; wire [63:0] d_instr;
    ad_su_fetch #(.WARP_W(WARP_W)) u_fetch (
        .clk(clk), .rst_n(rst_n), .f_valid(f_valid), .f_ready(f_ready), .f_warp(f_warp), .f_pc(f_pc),
        .f_addr(f_addr), .ic_req(ic_req), .ic_ready(ic_ready), .ic_addr(ic_addr), .ic_rvalid(ic_rvalid),
        .ic_rdata(ic_rdata), .d_valid(d_valid), .d_ready(d_ready), .d_warp(d_warp), .d_pc(d_pc), .d_instr(d_instr));

    // I$ and constant bank share one AMB client through the mux
    wire ic_rq_v, ic_rq_r, ic_rq_w, cb_rq_v, cb_rq_r, cb_rq_w;
    wire [LW-1:0] ic_rq_l, cb_rq_l; wire [LINE_BYTES-1:0] ic_rq_be, cb_rq_be;
    wire [LINE_BYTES*8-1:0] ic_rq_d, cb_rq_d; wire [7:0] ic_rq_t, cb_rq_t;
    wire [1:0] im_rsp_v; wire im_rsp_w, im_rsp_e; wire [7:0] im_rsp_t; wire [LINE_BYTES*8-1:0] im_rsp_d;

    ad_su_icache #(.ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT)) u_icache (
        .clk(clk), .rst_n(rst_n), .ic_req(ic_req), .ic_ready(ic_ready), .ic_addr(ic_addr),
        .ic_rvalid(ic_rvalid), .ic_rdata(ic_rdata), .inv(inv[3]),
        .req_valid(ic_rq_v), .req_ready(ic_rq_r), .req_write(ic_rq_w), .req_line(ic_rq_l), .req_be(ic_rq_be),
        .req_wdata(ic_rq_d), .req_tag(ic_rq_t), .rsp_valid(im_rsp_v[0]), .rsp_write(im_rsp_w),
        .rsp_tag(im_rsp_t), .rsp_rdata(im_rsp_d), .rsp_error(im_rsp_e));

    wire u_valid, u_ready; wire [WARP_W-1:0] u_warp; wire [15:0] u_pc; wire [UOP_W-1:0] u_uop;
    ad_su_dec #(.WARP_W(WARP_W), .UOP_W(UOP_W), .NREGS(NREGS), .PACKED(PACKED), .SUBGROUP(SUBGROUP),
                .HAS_SA(HAS_SA), .MS4(MS4)) u_dec (
        .clk(clk), .rst_n(rst_n), .d_valid(d_valid), .d_ready(d_ready), .d_warp(d_warp), .d_pc(d_pc),
        .d_instr(d_instr), .u_valid(u_valid), .u_ready(u_ready), .u_warp(u_warp), .u_pc(u_pc), .u_uop(u_uop));

    // ---------------- issue ----------------
    wire i_valid, i_ready; wire [WARP_W-1:0] i_warp; wire [15:0] i_pc; wire [UOP_W-1:0] i_uop; wire [SBE_W:0] i_sbe;
    wire rel_valid; wire [WARP_W-1:0] rel_warp; wire [SBE_W:0] rel_sbe; wire [2:0] rel_cls;
    wire wb_stall, rq_empty, rq_full, sb_busy; wire [15:0] fault_pc;
    wire x_valid, x_last; wire [WARP_W-1:0] x_warp; wire [GRP_W-1:0] x_grp; wire [SBE_W:0] x_sbe;
    wire [15:0] x_pc; wire [UOP_W-1:0] x_uop; wire [NPW-1:0] x_a, x_b, x_c; wire [2*NPHYS-1:0] x_mask;
    wire [31:0] x_info; wire [15:0] unit_ready;
    wire rq_push_w; wire [NPW-1:0] rq_push_d;
    wire [3:0] x_unit = x_uop[AD_UOP_UNIT +: 4];
    wire x_end = x_valid && x_last && unit_ready[x_unit];

    ad_su_sb #(.NWARPS(NWARPS), .WARP_W(WARP_W), .SB_ENTRIES(SB_ENTRIES), .SBE_W(SBE_W), .UOP_W(UOP_W),
               .NPHYS(NPHYS), .SHORT_LAT(SHORT_LAT)) u_sb (
        .clk(clk), .rst_n(rst_n), .u_valid(u_valid), .u_ready(u_ready), .u_warp(u_warp), .u_pc(u_pc), .u_uop(u_uop),
        .i_valid(i_valid), .i_ready(i_ready), .i_warp(i_warp), .i_pc(i_pc), .i_uop(i_uop), .i_sbe(i_sbe),
        .fb_valid(fb_valid), .fb_warp(fb_warp), .fb_kind(fb_kind), .wake(wake), .warp_ready(warp_ready),
        .rel_valid(rel_valid), .rel_warp(rel_warp), .rel_sbe(rel_sbe), .rel_cls(rel_cls),
        .wb_stall(wb_stall), .rq_empty(rq_empty), .rq_full(rq_full), .x_end(x_end),
        .busy(sb_busy), .fault(fault), .fault_pc(fault_pc));
    assign fault_addr = {16'd0, fault_pc};

    // ---------------- operands ----------------
    wire r_en; wire [WARP_W-1:0] r_warp; wire [GRP_W-1:0] r_grp; wire [5:0] r_reg1, r_reg2;
    wire [NPW-1:0] r_data1, r_data2;
    wire cr_en; wire [14:0] cr_idx; wire [95:0] cr_data;
    wire rq_pop; wire [NPW-1:0] rq_pdata;
    wire w_en; wire [WARP_W-1:0] w_warp; wire [GRP_W-1:0] w_grp; wire [5:0] w_reg; wire [NPW-1:0] w_data;
    wire [NPHYS-1:0] w_lanes;
    // forwarding taps of the ALU and FPU
    wire a4v, a5v, f4v, f5v; wire [WARP_W-1:0] a4w, a5w, f4w, f5w; wire [GRP_W-1:0] a4g, a5g, f4g, f5g;
    wire [6:0] a4r, a5r, f4r, f5r; wire [NPW-1:0] a4d, a5d, f4d, f5d; wire [NPHYS-1:0] a4l, a5l, f4l, f5l;

    ad_su_opd #(.NPHYS(NPHYS), .WARP_W(WARP_W), .GRP_W(GRP_W), .SBE_W(SBE_W), .UOP_W(UOP_W),
                .WARP_BASE(SU_INDEX * NWARPS)) u_opd (
        .clk(clk), .rst_n(rst_n), .i_valid(i_valid), .i_ready(i_ready), .i_warp(i_warp), .i_pc(i_pc),
        .i_uop(i_uop), .i_sbe(i_sbe),
        .r_en(r_en), .r_warp(r_warp), .r_grp(r_grp), .r_reg1(r_reg1), .r_reg2(r_reg2),
        .r_data1(r_data1), .r_data2(r_data2), .cr_en(cr_en), .cr_idx(cr_idx), .cr_data(cr_data),
        .q_warp(q_warp), .q_info(q_info), .q_exec(q_exec), .q_killed(q_killed),
        .rq_pop(rq_pop), .rq_data(rq_pdata),
        .x_valid(x_valid), .x_warp(x_warp), .x_grp(x_grp), .x_last(x_last), .x_sbe(x_sbe), .x_pc(x_pc),
        .x_uop(x_uop), .x_a(x_a), .x_b(x_b), .x_c(x_c), .x_mask(x_mask), .x_info(x_info), .unit_ready(unit_ready),
        .fwd_alu_ex4_valid(a4v), .fwd_alu_ex4_warp(a4w), .fwd_alu_ex4_grp(a4g), .fwd_alu_ex4_rd(a4r),
        .fwd_alu_ex4_data(a4d), .fwd_alu_ex4_lanes(a4l),
        .fwd_alu_ex5_valid(a5v), .fwd_alu_ex5_warp(a5w), .fwd_alu_ex5_grp(a5g), .fwd_alu_ex5_rd(a5r),
        .fwd_alu_ex5_data(a5d), .fwd_alu_ex5_lanes(a5l),
        .fwd_fpu_ex4_valid(f4v), .fwd_fpu_ex4_warp(f4w), .fwd_fpu_ex4_grp(f4g), .fwd_fpu_ex4_rd(f4r),
        .fwd_fpu_ex4_data(f4d), .fwd_fpu_ex4_lanes(f4l),
        .fwd_fpu_ex5_valid(f5v), .fwd_fpu_ex5_warp(f5w), .fwd_fpu_ex5_grp(f5g), .fwd_fpu_ex5_rd(f5r),
        .fwd_fpu_ex5_data(f5d), .fwd_fpu_ex5_lanes(f5l),
        .fwd_wb_valid(w_en), .fwd_wb_warp(w_warp), .fwd_wb_grp(w_grp), .fwd_wb_rd({1'b0, w_reg}),
        .fwd_wb_data(w_data), .fwd_wb_lanes(w_lanes));

    wire rf_scrub_busy;
    ad_su_rf #(.NPHYS(NPHYS), .NWARPS(NWARPS), .WARP_W(WARP_W), .GRP_W(GRP_W), .NREGS(NREGS)) u_rf (
        .clk(clk), .rst_n(rst_n), .w_en(w_en), .w_warp(w_warp), .w_grp(w_grp), .w_reg(w_reg), .w_data(w_data),
        .w_lanes(w_lanes), .r_en(r_en), .r_warp(r_warp), .r_grp(r_grp), .r_reg1(r_reg1), .r_reg2(r_reg2),
        .r_data1(r_data1), .r_data2(r_data2), .scrub(scrub), .scrub_busy(rf_scrub_busy));

    // ---------------- execution units ----------------
    // short results: 0 alu, 1 fpu, 2 pk, 3 lane, 4 lda, 5 exec
    wire [5:0] s_v; wire [6*WARP_W-1:0] s_w; wire [6*GRP_W-1:0] s_g; wire [6*7-1:0] s_r;
    wire [6*NPW-1:0] s_d; wire [6*NPHYS-1:0] s_l;
    // long results: 0 lsu, 1 lds, 2 cbank, 3 tex, 4 xu, 5 div
    wire [5:0] l_v, l_rdy, l_wr, l_last; wire [6*WARP_W-1:0] l_w; wire [6*GRP_W-1:0] l_g; wire [6*7-1:0] l_r;
    wire [6*NPW-1:0] l_d; wire [6*NPHYS-1:0] l_l; wire [6*(SBE_W+1)-1:0] l_s; wire [6*3-1:0] l_c;

`define AD_XBUS .clk(clk), .rst_n(rst_n), .x_valid(x_valid), .x_warp(x_warp), .x_grp(x_grp), .x_last(x_last), \
    .x_sbe(x_sbe), .x_pc(x_pc), .x_uop(x_uop), .x_a(x_a), .x_b(x_b), .x_c(x_c), .x_mask(x_mask), .x_info(x_info)
`define AD_SRES(k) .s_valid(s_v[k]), .s_warp(s_w[k*WARP_W +: WARP_W]), .s_grp(s_g[k*GRP_W +: GRP_W]), \
    .s_rd(s_r[k*7 +: 7]), .s_data(s_d[k*NPW +: NPW]), .s_lanes(s_l[k*NPHYS +: NPHYS])
`define AD_LRES(k) .l_valid(l_v[k]), .l_ready(l_rdy[k]), .l_warp(l_w[k*WARP_W +: WARP_W]), \
    .l_grp(l_g[k*GRP_W +: GRP_W]), .l_rd(l_r[k*7 +: 7]), .l_data(l_d[k*NPW +: NPW]), \
    .l_lanes(l_l[k*NPHYS +: NPHYS]), .l_wr(l_wr[k]), .l_last(l_last[k]), .l_sbe(l_s[k*(SBE_W+1) +: SBE_W+1]), \
    .l_cls(l_c[k*3 +: 3])
`define AD_UP .NPHYS(NPHYS), .NWARPS(NWARPS), .WARP_W(WARP_W), .GRP_W(GRP_W), .SBE_W(SBE_W), .UOP_W(UOP_W)

    wire rdy_alu, rdy_fpu, rdy_pk, rdy_lane, rdy_lda, rdy_exec, rdy_lsu, rdy_lds, rdy_cb, rdy_tex, rdy_xu,
         rdy_div, rdy_exp;
    ad_su_alu #(`AD_UP, .SHORT_LAT(SHORT_LAT)) u_alu (`AD_XBUS, .x_ready(rdy_alu), `AD_SRES(0),
        .fw4_valid(a4v), .fw4_warp(a4w), .fw4_grp(a4g), .fw4_rd(a4r), .fw4_data(a4d), .fw4_lanes(a4l),
        .fw5_valid(a5v), .fw5_warp(a5w), .fw5_grp(a5g), .fw5_rd(a5r), .fw5_data(a5d), .fw5_lanes(a5l));
    ad_su_fpu #(`AD_UP, .SHORT_LAT(SHORT_LAT)) u_fpu (`AD_XBUS, .x_ready(rdy_fpu), `AD_SRES(1),
        .fw4_valid(f4v), .fw4_warp(f4w), .fw4_grp(f4g), .fw4_rd(f4r), .fw4_data(f4d), .fw4_lanes(f4l),
        .fw5_valid(f5v), .fw5_warp(f5w), .fw5_grp(f5g), .fw5_rd(f5r), .fw5_data(f5d), .fw5_lanes(f5l));
    ad_su_pk #(`AD_UP, .PACKED(PACKED), .SHORT_LAT(SHORT_LAT)) u_pk (`AD_XBUS, .x_ready(rdy_pk), `AD_SRES(2));
    ad_su_lane #(`AD_UP, .SUBGROUP(SUBGROUP), .SHORT_LAT(SHORT_LAT)) u_lane (`AD_XBUS, .x_ready(rdy_lane), `AD_SRES(3));
    wire lda_scrub_busy;
    ad_su_lda #(`AD_UP, .VARY_WORDS(VARY_WORDS), .SHORT_LAT(SHORT_LAT)) u_lda (`AD_XBUS, .x_ready(rdy_lda),
        `AD_SRES(4), .pw_we(fl_pw_we), .pw_warp(fl_slot), .pw_addr(fl_pw_addr), .pw_data(fl_pw_data),
        .scrub(scrub), .scrub_busy(lda_scrub_busy));
    ad_su_exec #(`AD_UP, .SHORT_LAT(SHORT_LAT)) u_exec (`AD_XBUS, .x_ready(rdy_exec), `AD_SRES(5),
        .wc_valid(wc_valid), .wc_warp(wc_warp), .wc_op(wc_op), .wc_pc(wc_pc),
        .q_warp(q_warp), .q_exec(q_exec), .q_killed(q_killed),
        .init_valid(init_valid), .init_warp(init_warp), .init_mask(init_mask));

    // global memory: lsu -> dcache -> d_* port
    wire dc_v, dc_r, dc_w, dcr_v, dcr_w, dcr_e, dc_inv; wire [LW-1:0] dc_l; wire [LINE_BYTES-1:0] dc_be;
    wire [LINE_BYTES*8-1:0] dc_d, dcr_d; wire [7:0] dc_t, dcr_t;
    ad_su_lsu #(`AD_UP, .ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT)) u_lsu (
        `AD_XBUS, .x_ready(rdy_lsu), `AD_LRES(0),
        .dc_req_valid(dc_v), .dc_req_ready(dc_r), .dc_req_write(dc_w), .dc_req_line(dc_l), .dc_req_be(dc_be),
        .dc_req_wdata(dc_d), .dc_req_tag(dc_t), .dc_rsp_valid(dcr_v), .dc_rsp_write(dcr_w), .dc_rsp_tag(dcr_t),
        .dc_rsp_rdata(dcr_d), .dc_rsp_error(dcr_e),
        .at_valid(at_valid), .at_ready(at_ready), .at_op(at_op), .at_addr(at_addr), .at_a(at_a), .at_b(at_b),
        .at_rsp_valid(at_rsp_valid), .at_old(at_old), .at_error(at_error), .dc_inv(dc_inv));
    ad_su_dcache #(.ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT)) u_dcache (
        .clk(clk), .rst_n(rst_n), .inv(inv[0] | dc_inv),
        .u_req_valid(dc_v), .u_req_ready(dc_r), .u_req_write(dc_w), .u_req_line(dc_l), .u_req_be(dc_be),
        .u_req_wdata(dc_d), .u_req_tag(dc_t), .u_rsp_valid(dcr_v), .u_rsp_write(dcr_w), .u_rsp_tag(dcr_t),
        .u_rsp_rdata(dcr_d), .u_rsp_error(dcr_e),
        .m_req_valid(d_req_valid), .m_req_ready(d_req_ready), .m_req_write(d_req_write), .m_req_line(d_req_line),
        .m_req_be(d_req_be), .m_req_wdata(d_req_wdata), .m_req_tag(d_req_tag), .m_rsp_valid(d_rsp_valid),
        .m_rsp_write(d_rsp_write), .m_rsp_tag(d_rsp_tag), .m_rsp_rdata(d_rsp_rdata), .m_rsp_error(d_rsp_error));

    wire mesh_rd_en; wire [LDS_AW-1:0] mesh_rd_addr; wire [31:0] mesh_rd_data; wire lds_scrub_busy;
    ad_su_lds #(`AD_UP, .LDS_BYTES(LDS_BYTES)) u_lds (`AD_XBUS, .x_ready(rdy_lds), `AD_LRES(1),
        .scrub(scrub), .scrub_busy(lds_scrub_busy), .mesh_rd_en(mesh_rd_en), .mesh_rd_addr(mesh_rd_addr),
        .mesh_rd_data(mesh_rd_data));

    wire cb_busy, cb_scrub_busy;
    ad_su_cbank #(`AD_UP, .ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT)) u_cbank (
        `AD_XBUS, .x_ready(rdy_cb), `AD_LRES(2), .cr_en(cr_en), .cr_idx(cr_idx), .cr_data(cr_data),
        .st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata), .lc_kick(lc_kick), .inv(inv[2]), .busy(cb_busy),
        .scrub(scrub), .scrub_busy(cb_scrub_busy),
        .req_valid(cb_rq_v), .req_ready(cb_rq_r), .req_write(cb_rq_w), .req_line(cb_rq_l), .req_be(cb_rq_be),
        .req_wdata(cb_rq_d), .req_tag(cb_rq_t), .rsp_valid(im_rsp_v[1]), .rsp_write(im_rsp_w),
        .rsp_tag(im_rsp_t), .rsp_rdata(im_rsp_d), .rsp_error(im_rsp_e));

    ad_amb_mux #(.N(2), .ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT)) u_imux (
        .clk(clk), .rst_n(rst_n),
        .c_req_valid({cb_rq_v, ic_rq_v}), .c_req_ready({cb_rq_r, ic_rq_r}), .c_req_write({cb_rq_w, ic_rq_w}),
        .c_req_line({cb_rq_l, ic_rq_l}), .c_req_be({cb_rq_be, ic_rq_be}), .c_req_wdata({cb_rq_d, ic_rq_d}),
        .c_req_tag({cb_rq_t, ic_rq_t}), .c_rsp_valid(im_rsp_v), .c_rsp_write(im_rsp_w), .c_rsp_tag(im_rsp_t),
        .c_rsp_rdata(im_rsp_d), .c_rsp_error(im_rsp_e),
        .m_req_valid(i_req_valid), .m_req_ready(i_req_ready), .m_req_write(i_req_write), .m_req_line(i_req_line),
        .m_req_be(i_req_be), .m_req_wdata(i_req_wdata), .m_req_tag(i_req_tag), .m_rsp_valid(i_rsp_valid),
        .m_rsp_write(i_rsp_write), .m_rsp_tag(i_rsp_tag), .m_rsp_rdata(i_rsp_rdata), .m_rsp_error(i_rsp_error));

    ad_su_tex #(`AD_UP) u_tex (`AD_XBUS, .x_ready(rdy_tex), `AD_LRES(3),
        .tx_valid(tx_valid), .tx_ready(tx_ready), .tx_op(tx_op), .tx_slot(tx_slot), .tx_vs(tx_vs),
        .tx_mask(tx_mask), .tx_coord(tx_coord), .tx_off(tx_off), .tx_tag(tx_tag), .tx_last(tx_last),
        .tr_valid(tr_valid), .tr_ready(tr_ready), .tr_tag(tr_tag), .tr_data(tr_data), .tr_last(tr_last));
    ad_su_xu  #(`AD_UP) u_xu  (`AD_XBUS, .x_ready(rdy_xu),  `AD_LRES(4));
    ad_su_div #(`AD_UP) u_div (`AD_XBUS, .x_ready(rdy_div), `AD_LRES(5));

    // graphics outputs
    wire wc_end = wc_valid && (wc_op == 2'd1);
    wire exp_scrub_busy, pt_scrub_busy, mesh_busy;
    ad_su_exp #(`AD_UP, .LDS_AW(LDS_AW)) u_exp (`AD_XBUS, .x_ready(rdy_exp),
        .ex_valid(ex_valid), .ex_ready(ex_ready), .ex_seq(ex_seq), .ex_xy(ex_xy), .ex_mask(ex_mask),
        .ex_color(ex_color), .ex_depth(ex_depth), .ex_last(ex_last), .ex_next(ex_next),
        .fl_we(fl_we), .fl_slot(fl_slot), .fl_reg(fl_reg), .fl_lane(fl_lane), .fl_data(fl_data), .fl_go(fl_go),
        .fl_info(fl_info), .fl_pw_we(fl_pw_we), .fl_pw_addr(fl_pw_addr), .fl_pw_data(fl_pw_data),
        .ex_aux(ex_aux), .xr_valid(xr_valid), .xr_warp(xr_warp), .wc_end(wc_end), .wc_warp(wc_warp),
        .mesh_valid(mesh_valid), .mesh_ready(mesh_ready), .mesh_tri(mesh_tri), .mesh_last(mesh_last),
        .mesh_id(mesh_id), .mesh_busy(mesh_busy), .mesh_lds_rd_en(mesh_rd_en), .mesh_lds_rd_addr(mesh_rd_addr),
        .mesh_lds_rd_data(mesh_rd_data), .scrub(scrub), .scrub_busy(exp_scrub_busy));
    ad_su_pt #(.NPHYS(NPHYS), .NWARPS(NWARPS), .WARP_W(WARP_W), .GRP_W(GRP_W), .UOP_W(UOP_W),
               .PT_ENTRIES(PT_ENTRIES), .VARY_WORDS(VARY_WORDS)) u_pt (
        .clk(clk), .rst_n(rst_n), .x_valid(x_valid), .x_warp(x_warp), .x_grp(x_grp), .x_uop(x_uop), .x_b(x_b),
        .x_mask(x_mask), .x_info(x_info), .pt_rd(pt_rd), .pt_idx(pt_idx), .pt_word(pt_word), .pt_rdata(pt_rdata),
        .pt_free(pt_free), .pt_free_idx(pt_free_idx), .pt_ok(pt_ok), .pt_take(vl_gnt), .pt_warp(vl_slot),
        .pt_base(vl_ptbase), .vl_go(vl_go), .vl_mask(vl_mask), .pt_done(pt_done), .wc_end(wc_end),
        .wc_warp(wc_warp), .scrub(scrub), .scrub_busy(pt_scrub_busy));

    // reserved rq / SA port
    ad_su_rq #(.NPHYS(NPHYS), .UOP_W(UOP_W), .HAS_SA(HAS_SA)) u_rq (
        .clk(clk), .rst_n(rst_n), .pop(rq_pop), .pop_data(rq_pdata), .push(rq_push_w), .push_data(rq_push_d),
        .empty(rq_empty), .full(rq_full), .ctl_valid(x_valid && x_unit == AD_UNIT_RQ), .ctl_data(x_a[31:0]),
        .sa_push_valid(sa_push_valid), .sa_push_ready(sa_push_ready), .sa_push_data(sa_push_data),
        .sa_pop_valid(sa_pop_valid), .sa_pop_ready(sa_pop_ready), .sa_pop_data(sa_pop_data),
        .sa_ctl_valid(sa_ctl_valid), .sa_ctl_data(sa_ctl_data), .sa_qstat(sa_qstat), .sa_stat(sa_stat),
        .sa_qtag(sa_qtag));

    // unit readiness, indexed by AD_UNIT_*
    assign unit_ready = {1'b1 /*RQ*/, 1'b1 /*CTL*/, rdy_exec, rdy_lane, rdy_lda, rdy_exp, rdy_tex, rdy_cb,
                         rdy_lds, rdy_lsu, rdy_div, rdy_xu, rdy_pk, rdy_fpu, rdy_alu, 1'b1 /*NONE*/};

    // ---------------- write-back ----------------
    ad_su_wb #(.NPHYS(NPHYS), .WARP_W(WARP_W), .GRP_W(GRP_W), .SBE_W(SBE_W), .NS(6), .NL(6),
               .SHORT_LAT(SHORT_LAT)) u_wb (
        .clk(clk), .rst_n(rst_n), .s_valid(s_v), .s_warp(s_w), .s_grp(s_g), .s_rd(s_r), .s_data(s_d),
        .s_lanes(s_l), .l_valid(l_v), .l_ready(l_rdy), .l_warp(l_w), .l_grp(l_g), .l_rd(l_r), .l_data(l_d),
        .l_lanes(l_l), .l_wr(l_wr), .l_last(l_last), .l_sbe(l_s), .l_cls(l_c),
        .in_we({fl_we, vl_we}), .in_warp({fl_slot, vl_slot}), .in_reg({fl_reg, vl_reg}),
        .in_lane({fl_lane, vl_lane}), .in_data({fl_data, vl_data}),
        .w_en(w_en), .w_warp(w_warp), .w_grp(w_grp), .w_reg(w_reg), .w_data(w_data), .w_lanes(w_lanes),
        .rel_valid(rel_valid), .rel_warp(rel_warp), .rel_sbe(rel_sbe), .rel_cls(rel_cls),
        .rq_push(rq_push_w), .rq_data(rq_push_d), .wb_stall(wb_stall));

    assign scrub_busy = rf_scrub_busy | lda_scrub_busy | lds_scrub_busy | cb_scrub_busy | exp_scrub_busy | pt_scrub_busy;
    assign busy = sched_busy | sb_busy | cb_busy | mesh_busy;

`undef AD_XBUS
`undef AD_SRES
`undef AD_LRES
`undef AD_UP
endmodule
