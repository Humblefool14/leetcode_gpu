// ad_su_pipe -- the unified short execution pipeline (spec/gpu/su/ad_su_pipe.md):
// ad_su_alu and ad_su_fpu side by side on the execution bus, their short results
// merged into one s_* port, and the clock enable `en` freezing the pipeline.
//
// The arithmetic stages are the children's (each lane combinational before the
// first of SHORT_LAT stages).  The freeze: a group is taken only while en (x_ready
// = en and the unit's x_ready); a token line of SHORT_LAT stages, advancing only
// while en, marks where each taken result-writing group is in "en time"; the
// children's results (which advance every clock) wait in a FIFO (ad_su_fifo, depth
// >= SHORT_LAT + 1) until their token reaches the last stage.  s_* is the FIFO head
// (or, with an empty FIFO, the child's result of this cycle) while the last token
// stage is valid: exactly SHORT_LAT en-cycles after the group, and held (s_valid
// stays 1, the same data) while en is 0.  With en always 1, s_* is exactly
// SHORT_LAT cycles after x_valid, one group a cycle.
// ad_su (the SU top) instantiates ad_su_alu and ad_su_fpu directly (their fw4_/fw5_
// taps feed ad_su_opd); ad_su_pipe is the alternative packaging with a pipeline
// hold and no forwarding taps.  PACKED / PK_SHARED are accepted and unused (the
// packed unit ad_su_pk stays a separate short unit).
module ad_su_pipe #(
    parameter NPHYS     = 8,
    parameter NWARPS    = 4,
    parameter WARP_W    = 2,
    parameter GRP_W     = 2,
    parameter SBE_W     = 2,
    parameter UOP_W     = 108,
    parameter SHORT_LAT = 6,
    parameter PACKED    = 0,
    parameter PK_SHARED = 0
) (
    input  wire                  clk,
    input  wire                  rst_n,
    input  wire                  en,
    input  wire                  x_valid,
    input  wire [WARP_W-1:0]     x_warp,
    input  wire [GRP_W-1:0]      x_grp,
    input  wire                  x_last,
    input  wire [SBE_W:0]        x_sbe,
    input  wire [15:0]           x_pc,
    input  wire [UOP_W-1:0]      x_uop,
    input  wire [NPHYS*32-1:0]   x_a,
    input  wire [NPHYS*32-1:0]   x_b,
    input  wire [NPHYS*32-1:0]   x_c,
    input  wire [2*NPHYS-1:0]    x_mask,
    input  wire [31:0]           x_info,
    output wire                  x_ready,
    output wire                  s_valid,
    output wire [WARP_W-1:0]     s_warp,
    output wire [GRP_W-1:0]      s_grp,
    output wire [6:0]            s_rd,
    output wire [NPHYS*32-1:0]   s_data,
    output wire [NPHYS-1:0]      s_lanes
);
`include "ad_su_uop.vh"
    localparam L  = SHORT_LAT;
    localparam FD = (L < 4) ? 4 : (L < 8) ? 8 : (L < 16) ? 16 : 32;
    localparam RW = WARP_W + GRP_W + 7 + NPHYS*32 + NPHYS;

    wire [3:0] unit = x_uop[AD_UOP_UNIT +: 4];
    wire       a_rdy, f_rdy;
    assign x_ready = en && (unit == AD_UNIT_ALU ? a_rdy : unit == AD_UNIT_FPU ? f_rdy : 1'b1);
    wire       xv = x_valid && x_ready;

    // children (fw taps unused here)
    wire a_v, f_v; wire [WARP_W-1:0] a_w, f_w; wire [GRP_W-1:0] a_g, f_g; wire [6:0] a_r, f_r;
    wire [NPHYS*32-1:0] a_d, f_d; wire [NPHYS-1:0] a_l, f_l;
    /* verilator lint_off PINCONNECTEMPTY */
    ad_su_alu #(.NPHYS(NPHYS), .NWARPS(NWARPS), .WARP_W(WARP_W), .GRP_W(GRP_W), .SBE_W(SBE_W),
                .UOP_W(UOP_W), .SHORT_LAT(SHORT_LAT)) alu (
        .clk(clk), .rst_n(rst_n), .x_valid(xv), .x_warp(x_warp), .x_grp(x_grp), .x_last(x_last),
        .x_sbe(x_sbe), .x_pc(x_pc), .x_uop(x_uop), .x_a(x_a), .x_b(x_b), .x_c(x_c), .x_mask(x_mask),
        .x_info(x_info), .x_ready(a_rdy), .s_valid(a_v), .s_warp(a_w), .s_grp(a_g), .s_rd(a_r),
        .s_data(a_d), .s_lanes(a_l),
        .fw4_valid(), .fw4_warp(), .fw4_grp(), .fw4_rd(), .fw4_data(), .fw4_lanes(),
        .fw5_valid(), .fw5_warp(), .fw5_grp(), .fw5_rd(), .fw5_data(), .fw5_lanes());
    ad_su_fpu #(.NPHYS(NPHYS), .NWARPS(NWARPS), .WARP_W(WARP_W), .GRP_W(GRP_W), .SBE_W(SBE_W),
                .UOP_W(UOP_W), .SHORT_LAT(SHORT_LAT)) fpu (
        .clk(clk), .rst_n(rst_n), .x_valid(xv), .x_warp(x_warp), .x_grp(x_grp), .x_last(x_last),
        .x_sbe(x_sbe), .x_pc(x_pc), .x_uop(x_uop), .x_a(x_a), .x_b(x_b), .x_c(x_c), .x_mask(x_mask),
        .x_info(x_info), .x_ready(f_rdy), .s_valid(f_v), .s_warp(f_w), .s_grp(f_g), .s_rd(f_r),
        .s_data(f_d), .s_lanes(f_l),
        .fw4_valid(), .fw4_warp(), .fw4_grp(), .fw4_rd(), .fw4_data(), .fw4_lanes(),
        .fw5_valid(), .fw5_warp(), .fw5_grp(), .fw5_rd(), .fw5_data(), .fw5_lanes());
    /* verilator lint_on PINCONNECTEMPTY */

    // merged raw result (one group a cycle: never both)
    wire          rv = a_v || f_v;
    wire [RW-1:0] rr = (a_v ? {a_w, a_g, a_r, a_d, a_l} : {RW{1'b0}}) |
                       (f_v ? {f_w, f_g, f_r, f_d, f_l} : {RW{1'b0}});

    // token line in en time
    reg  [L-1:0] tok;
    wire         tin = xv && (unit == AD_UNIT_ALU || unit == AD_UNIT_FPU) && x_uop[AD_UOP_WRD];
    always @(posedge clk) begin
        if (!rst_n)  tok <= {L{1'b0}};
`ifdef MUT_PIPE_FREEZE
        else         tok <= {tok[L-2:0], tin};       // mutation: ignores en
`else
        else if (en) tok <= {tok[L-2:0], tin};
`endif
    end
    wire tl = tok[L-1];

    // result FIFO
    wire [RW-1:0] head;
    wire          fe, ff;
    wire [$clog2(FD):0] fc;
    wire          byp  = fe && tl && en;         // this cycle's raw result leaves at once
    ad_fifo #(.W(RW), .DEPTH(FD)) q (
        .clk(clk), .rst_n(rst_n), .push(rv && !byp), .din(rr), .pop(en && tl && !fe),
        .dout(head), .empty(fe), .full(ff), .count(fc));
    assign s_valid = tl;
    assign {s_warp, s_grp, s_rd, s_data, s_lanes} = fe ? rr : head;
`ifndef SYNTHESIS
    always @(posedge clk) if (rst_n && rv && !byp && ff) $display("ERROR ad_su_pipe: result FIFO full (%m)");
`endif
    wire unused = &{1'b0, fc, PACKED[0], PK_SHARED[0]};
endmodule
