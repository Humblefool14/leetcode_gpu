// ad_su_tex_ret -- the return half of ad_su_tex (spec ad_su_tex_ret.md): a 4-entry FIFO of the
// sent groups' records (ad_gfx_fifo) and, for the oldest, the gathering of its returned quads
// (one per set bit of rq_qmask, in order) into rd..rd+3 beats (texsz: rd only), l_last on the
// last beat of a record with rq_last.  HEAD -(record)-> GATHER (quad q) -> BEAT (beat c) -> HEAD;
// a record without sent quads goes HEAD -> BEAT.
module ad_su_tex_ret #(
    parameter NPHYS = 8,
    parameter WARP_W = 2,
    parameter GRP_W = 2,
    parameter SBE_W = 2
) (
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire                 rq_valid,
    output wire                 rq_ready,
    input  wire [WARP_W-1:0]    rq_warp,
    input  wire [GRP_W-1:0]     rq_grp,
    input  wire [6:0]           rq_rd,
    input  wire [SBE_W:0]       rq_sbe,
    input  wire                 rq_last,
    input  wire                 rq_sz,
    input  wire [NPHYS/4-1:0]   rq_qmask,
    input  wire [NPHYS-1:0]     rq_lanes,
    input  wire                 tr_valid,
    output wire                 tr_ready,
    input  wire [511:0]         tr_data,
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
    output wire [2:0]           l_cls
);
`include "ad_su_uop.vh"
    localparam NQ = NPHYS / 4;
    localparam QW = (NQ > 1) ? $clog2(NQ) : 1;
    localparam RW = WARP_W + GRP_W + 7 + SBE_W + 1 + 1 + 1 + NQ + NPHYS;
    localparam S_HEAD = 2'd0, S_GATHER = 2'd1, S_BEAT = 2'd2;

    wire full, empty;
    wire [RW-1:0] hq;
    reg [1:0] state;
    wire pop = (state == S_HEAD) && !empty;
    ad_fifo #(.W(RW), .DEPTH(4)) fifo (.clk(clk), .rst_n(rst_n), .push(rq_valid),
        .din({rq_warp, rq_grp, rq_rd, rq_sbe, rq_last, rq_sz, rq_qmask, rq_lanes}),
        .pop(pop), .dout(hq), .full(full), .empty(empty));
    assign rq_ready = !full;

    reg [WARP_W-1:0] r_warp;
    reg [GRP_W-1:0] r_grp;
    reg [6:0] r_rd;
    reg [SBE_W:0] r_sbe;
    reg r_last, r_sz;
    reg [NQ-1:0] r_qmask;
    reg [NPHYS-1:0] r_lanes;
    reg [QW-1:0] q;
    reg [1:0] c;
    reg [NPHYS*128-1:0] buf_d;

    wire [NQ-1:0] h_qmask = hq[NPHYS +: NQ];
    wire qsent = r_qmask[q];
    assign tr_ready = (state == S_GATHER) && qsent;
    localparam [31:0] QL32 = NQ - 1;
    localparam [QW-1:0] QLAST = QL32[QW-1:0];
    wire lastq = (q == QLAST);
    wire lastc = r_sz ? 1'b1 : (c == 2'd3);

    assign l_valid = (state == S_BEAT);
    assign l_warp = r_warp;
    assign l_grp = r_grp;
    assign l_rd = r_rd + {5'd0, c};
    assign l_lanes = r_lanes;
    assign l_wr = 1'b1;
`ifdef MUT_TEXRET_LAST
    assign l_last = r_last;
`else
    assign l_last = r_last && lastc;
`endif
    assign l_sbe = r_sbe;
    assign l_cls = AD_CLS_T;
    reg [NPHYS*32-1:0] ld;
    integer i;
    always @(*) begin
        for (i = 0; i < NPHYS; i = i + 1) ld[32*i +: 32] = buf_d[128*i + 32*c +: 32];
    end
    assign l_data = ld;

    always @(posedge clk) begin
        if (!rst_n) begin
            state <= S_HEAD;
            q <= {QW{1'b0}};
            c <= 2'd0;
        end else begin
            case (state)
            S_HEAD:
                if (!empty) begin
                    {r_warp, r_grp, r_rd, r_sbe, r_last, r_sz, r_qmask, r_lanes} <= hq;
                    q <= {QW{1'b0}};
                    c <= 2'd0;
                    state <= (h_qmask != 0) ? S_GATHER : S_BEAT;
                end
            S_GATHER:
                if (!qsent || tr_valid) begin
                    if (lastq) state <= S_BEAT;
                    else q <= q + 1'b1;
                end
            default:
                if (l_ready) begin
                    if (lastc) state <= S_HEAD;
                    else c <= c + 2'd1;
                end
            endcase
        end
    end
    always @(posedge clk) begin
        if (state == S_GATHER && qsent && tr_valid) buf_d[512*q +: 512] <= tr_data;
    end
endmodule
