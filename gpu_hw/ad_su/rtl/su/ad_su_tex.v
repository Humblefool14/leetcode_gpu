// ad_su_tex -- the SU side of texturing, send half (spec ad_su_tex.md); the return half is
// ad_su_tex_ret.  A group of a texture instruction is taken in IDLE (or DREF for the second
// pass of a .c/.3 form) while ad_su_tex_ret has room for its record; its quads with EXEC lanes
// go to the TU one per cycle in increasing order (SEND, an empty quad also takes a cycle).
// .c (OP[2]) and .3 (SUB[4]) forms come twice (ad_su_opd): the first pass is kept (DREF), the
// second (OP[7]) brings rs1+2 on x_a and rs1+3 on x_c and carries the record.
// tx_coord lane l = {third, Dref, x_b, x_c, x_a} of the first pass (word 0 at the bottom).
// The uop's SAMP_SLOT [107:104] is not used: the TU port has no field for it (tx_slot is
// SUB[3:0], the TU derives the sampler from the texture slot), see spec §10.
module ad_su_tex #(
    parameter NPHYS = 8,
    parameter NWARPS = 4,
    parameter WARP_W = 2,
    parameter GRP_W = 2,
    parameter SBE_W = 2,
    parameter UOP_W = 108
) (
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire                 x_valid,
    input  wire [WARP_W-1:0]    x_warp,
    input  wire [GRP_W-1:0]     x_grp,
    input  wire                 x_last,
    input  wire [SBE_W:0]       x_sbe,
    input  wire [15:0]          x_pc,
    input  wire [UOP_W-1:0]     x_uop,
    input  wire [NPHYS*32-1:0]  x_a,
    input  wire [NPHYS*32-1:0]  x_b,
    input  wire [NPHYS*32-1:0]  x_c,
    input  wire [2*NPHYS-1:0]   x_mask,
    input  wire [31:0]          x_info,
    output wire                 x_ready,
    output wire                 l_valid,
    input  wire                 l_ready,
    output wire [WARP_W-1:0]    l_warp,
    output wire [GRP_W-1:0]     l_grp,
    output wire [6:0]           l_rd,
    output wire [NPHYS*32-1:0]  l_data,
    output wire [NPHYS-1:0]     l_lanes,
    output wire                 l_wr,
    output wire                 l_last,
    output wire [SBE_W:0]       l_sbe,
    output wire [2:0]           l_cls,
    output wire                 tx_valid,
    input  wire                 tx_ready,
    output wire [7:0]           tx_op,
    output wire [3:0]           tx_slot,
    output wire                 tx_vs,
    output wire [3:0]           tx_mask,
    output wire [639:0]         tx_coord,
    output wire [11:0]          tx_off,
    output wire [15:0]          tx_tag,
    output wire                 tx_last,
    input  wire                 tr_valid,
    output wire                 tr_ready,
    input  wire [15:0]          tr_tag,
    input  wire [511:0]         tr_data,
    input  wire                 tr_last
);
`include "ad_su_uop.vh"
    localparam NQ = NPHYS / 4;
    localparam QW = (NQ > 1) ? $clog2(NQ) : 1;
    localparam S_IDLE = 2'd0, S_DREF = 2'd1, S_SEND = 2'd2;
    reg [1:0] state;

    wire [7:0] op = x_uop[AD_UOP_OP +: 8];
    wire [4:0] sub = x_uop[AD_UOP_SUB +: 5];
    wire cform = op[AD_TEX_CFORM];
    wire three = sub[4];
    wire pass2 = op[AD_TEX_PASS2];
    wire rq_ready;
    assign x_ready = (state == S_IDLE || state == S_DREF) && rq_ready;
    wire take = x_valid && x_uop[AD_UOP_UNIT +: 4] == AD_UNIT_TEX && x_ready;
    wire first = take && (cform || three) && !pass2;    // kept in DREF
    wire rec = take && !first;                          // the record goes now

    // the first pass's operands
    reg [NPHYS*32-1:0] a1, b1, c1;
    // the group being sent
    reg [WARP_W-1:0] g_warp;
    reg [GRP_W-1:0] g_grp;
    reg [6:0] g_rd;
    reg [6:0] g_op;
    reg [3:0] g_slot;
    reg g_vs, g_last;
    reg g_cf, g_th;                     // words 3 (Dref) and 4 (third) are present
    reg [11:0] g_off;
    reg [NPHYS-1:0] g_exec;
    reg [NPHYS*160-1:0] g_coord;
    reg [QW-1:0] q;

    wire [NPHYS-1:0] exec = x_mask[NPHYS-1:0];
    reg [NQ-1:0] qmask;
    integer i;
    always @(*) begin
        for (i = 0; i < NQ; i = i + 1) qmask[i] = exec[4*i +: 4] != 4'd0;
    end
    // lane l's five words: the first pass's x_a, x_c, x_b (in DREF), Dref, the third coordinate
    wire [NPHYS*160-1:0] coord;
    wire dref = (state == S_DREF);
    genvar gl;
    generate
        for (gl = 0; gl < NPHYS; gl = gl + 1) begin : cl
            wire [31:0] w0 = dref ? a1[32*gl +: 32] : x_a[32*gl +: 32];
            wire [31:0] w1 = dref ? c1[32*gl +: 32] : x_c[32*gl +: 32];
            wire [31:0] w2 = dref ? b1[32*gl +: 32] : x_b[32*gl +: 32];
            // words 3 and 4 are kept as read; tx_coord zeroes them unless the form has them
`ifdef MUT_TEX_DREF
            wire [31:0] w3 = x_a[32*gl +: 32];
`else
            wire [31:0] w3 = three ? x_c[32*gl +: 32] : x_a[32*gl +: 32];
`endif
            wire [31:0] w4 = x_a[32*gl +: 32];
            assign coord[160*gl +: 160] = {w4, w3, w2, w1, w0};
        end
    endgenerate

    // the send
    wire [3:0] qexec = g_exec[4*q +: 4];
    assign tx_valid = (state == S_SEND) && qexec != 4'd0;
`ifdef MUT_TEX_HOLD
    wire adv = (state == S_SEND);               // mutation: a request dropped without tx_ready
`else
    wire adv = (state == S_SEND) && (!tx_valid || tx_ready);
`endif
    localparam [31:0] QL32 = NQ - 1, NQ32 = NQ;
    localparam [QW-1:0] QLAST = QL32[QW-1:0];
    localparam [7:0] NQ8 = NQ32[7:0];
    wire lastq = (q == QLAST);
    reg later;                                          // a later quad has EXEC lanes
    integer j;
    always @(*) begin
        later = 1'b0;
        for (j = 0; j < NQ; j = j + 1)
            if (j > q && g_exec[4*j +: 4] != 4'd0) later = 1'b1;
    end
    assign tx_op = {1'b0, g_op};
    assign tx_slot = g_slot;
    assign tx_vs = g_vs;
    assign tx_mask = qexec;
    reg [639:0] txc;
    integer ln, qq;
    always @(*) begin
        txc = 640'd0;
        for (qq = 0; qq < NQ; qq = qq + 1)
            if (q == qq) txc = g_coord[640*qq +: 640];
        for (ln = 0; ln < 4; ln = ln + 1) begin
            if (!g_cf) txc[160*ln + 96 +: 32] = 32'd0;
            if (!g_th) txc[160*ln + 128 +: 32] = 32'd0;
        end
    end
    assign tx_coord = txc;
    assign tx_off = g_off;
    wire [7:0] qnum = {{(8-GRP_W){1'b0}}, g_grp} * NQ8 + {{(8-QW){1'b0}}, q};
    wire [7:0] wz = {{(8-WARP_W){1'b0}}, g_warp};
    assign tx_tag = {3'b000, wz[2:0], qnum[2:0], g_rd};
    assign tx_last = g_last && !later;

    always @(posedge clk) begin
        if (!rst_n) begin
            state <= S_IDLE;
            q <= {QW{1'b0}};
        end else begin
            case (state)
            S_IDLE, S_DREF:
                if (first) state <= S_DREF;
                else if (rec) begin
                    q <= {QW{1'b0}};
                    state <= (qmask != 0) ? S_SEND : S_IDLE;
                end
            default:
                if (adv) begin
                    if (lastq) state <= S_IDLE;
                    else q <= q + 1'b1;
                end
            endcase
        end
    end
    always @(posedge clk) begin
        if (first) begin
            a1 <= x_a;
            b1 <= x_b;
            c1 <= x_c;
        end
        if (rec) begin
            g_warp <= x_warp;
            g_grp <= x_grp;
            g_rd <= x_uop[AD_UOP_RD +: 7];
            g_op <= op[6:0];
            g_slot <= sub[3:0];
            g_vs <= x_info[17:16] == 2'd0;
            g_last <= x_last;
            g_off <= x_uop[AD_UOP_IMM +: 12];
            g_exec <= exec;
            g_coord <= coord;
            g_cf <= dref && cform;
            g_th <= dref && three;
        end
    end

    ad_su_tex_ret #(.NPHYS(NPHYS), .WARP_W(WARP_W), .GRP_W(GRP_W), .SBE_W(SBE_W)) ret (
        .clk(clk), .rst_n(rst_n), .rq_valid(rec), .rq_ready(rq_ready), .rq_warp(x_warp),
        .rq_grp(x_grp), .rq_rd(x_uop[AD_UOP_RD +: 7]), .rq_sbe(x_sbe), .rq_last(x_last),
        .rq_sz(op[1:0] == 2'd3), .rq_qmask(qmask), .rq_lanes(exec), .tr_valid(tr_valid),
        .tr_ready(tr_ready), .tr_data(tr_data), .l_valid(l_valid), .l_ready(l_ready),
        .l_warp(l_warp), .l_grp(l_grp), .l_rd(l_rd), .l_data(l_data), .l_lanes(l_lanes),
        .l_wr(l_wr), .l_last(l_last), .l_sbe(l_sbe), .l_cls(l_cls));

    wire unused = &{1'b0, x_pc, tr_tag, tr_last, x_mask, x_uop, x_info, qnum, wz};
endmodule
