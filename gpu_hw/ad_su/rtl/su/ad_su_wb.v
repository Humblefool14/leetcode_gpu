// ad_su_wb -- write-back arbitration (spec/gpu/su/ad_su_wb.md): one RF write port
// shared by the short results (one per cycle at most, never delayed), the VF/RX
// input lane words (a FIFO per source, no back-pressure, source 0 first) and the
// long units' beats (round-robin, ad_su_rr_pick).  Priority short > input > long; a
// long beat without data (l_wr 0) is taken in any cycle.  rd 63 pushes to rq
// instead of the RF.  The taken long beat with l_last gives rel_*.  wb_stall: an
// input word waits, or a long beat with data has waited 4 cycles or more.
// The w_* / rq_* / rel_* / l_ready outputs are combinational (same cycle).
/* verilator lint_off UNUSEDSIGNAL */
module ad_su_wb #(
    parameter NPHYS     = 8,
    parameter WARP_W    = 2,
    parameter GRP_W     = 2,
    parameter SBE_W     = 2,
    parameter NS        = 6,
    parameter NL        = 6,
    parameter SHORT_LAT = 6,
    parameter FDEPTH    = 0,     // 0: the spec's input FIFO depth; formal harnesses reduce it
    parameter LW        = 32     // bits per lane word; only formal harnesses reduce it
) (
    input  wire                      clk,
    input  wire                      rst_n,
    input  wire [NS-1:0]             s_valid,
    input  wire [NS*WARP_W-1:0]      s_warp,
    input  wire [NS*GRP_W-1:0]       s_grp,
    input  wire [NS*7-1:0]           s_rd,
    input  wire [NS*NPHYS*LW-1:0]    s_data,
    input  wire [NS*NPHYS-1:0]       s_lanes,
    input  wire [NL-1:0]             l_valid,
    output wire [NL-1:0]             l_ready,
    input  wire [NL*WARP_W-1:0]      l_warp,
    input  wire [NL*GRP_W-1:0]       l_grp,
    input  wire [NL*7-1:0]           l_rd,
    input  wire [NL*NPHYS*LW-1:0]    l_data,
    input  wire [NL*NPHYS-1:0]       l_lanes,
    input  wire [NL-1:0]             l_wr,
    input  wire [NL-1:0]             l_last,
    input  wire [NL*(SBE_W+1)-1:0]   l_sbe,
    input  wire [NL*3-1:0]           l_cls,
    input  wire [1:0]                in_we,
    input  wire [2*WARP_W-1:0]       in_warp,
    input  wire [11:0]               in_reg,
    input  wire [9:0]                in_lane,
    input  wire [63:0]               in_data,
    output reg                       w_en,
    output reg  [WARP_W-1:0]         w_warp,
    output reg  [GRP_W-1:0]          w_grp,
    output reg  [5:0]                w_reg,
    output reg  [NPHYS*LW-1:0]       w_data,
    output reg  [NPHYS-1:0]          w_lanes,
    output wire                      rel_valid,
    output wire [WARP_W-1:0]         rel_warp,
    output wire [SBE_W:0]            rel_sbe,
    output wire [2:0]                rel_cls,
    output reg                       rq_push,
    output reg  [NPHYS*LW-1:0]       rq_data,
    output wire                      wb_stall
);
    localparam G    = 32 / NPHYS;
    localparam LB   = $clog2(NPHYS);                 // lane-in-group bits
    localparam FMIN = 2 * (SHORT_LAT + 2 * G + 2);   // spec §4
    localparam FD   = (FDEPTH != 0) ? FDEPTH :
                      (FMIN <= 16) ? 16 : (FMIN <= 32) ? 32 : (FMIN <= 64) ? 64 : 128;
    localparam FAW  = $clog2(FD);
    localparam IW   = WARP_W + 6 + 5 + LW;
    localparam PW   = (NL > 1) ? $clog2(NL) : 1;
    localparam [4:0] LMASK = NPHYS - 1;

    // ---------------- short results (at most one valid) ----------------
    reg               sv;
    reg [WARP_W-1:0]  sw;
    reg [GRP_W-1:0]   sg;
    reg [6:0]         sr;
    reg [NPHYS*LW-1:0] sd;
    reg [NPHYS-1:0]   sl;
    integer i;
    always @(*) begin
        sv = 1'b0; sw = 0; sg = 0; sr = 0; sd = 0; sl = 0;
        for (i = 0; i < NS; i = i + 1)
            if (s_valid[i]) begin
                sv = 1'b1;
                sw = sw | s_warp[WARP_W*i +: WARP_W];
                sg = sg | s_grp[GRP_W*i +: GRP_W];
                sr = sr | s_rd[7*i +: 7];
                sd = sd | s_data[NPHYS*LW*i +: NPHYS*LW];
                sl = sl | s_lanes[NPHYS*i +: NPHYS];
            end
    end

    // ---------------- input writes: a FIFO per source ----------------
    wire [IW-1:0] f0_out, f1_out;
    wire          f0_empty, f1_empty, f0_full, f1_full;
    wire [FAW:0]  f0_cnt, f1_cnt;
    wire          in_take = !sv && (!f0_empty || !f1_empty);
    wire          pop0 = in_take && !f0_empty;
    wire          pop1 = in_take && f0_empty;
    ad_fifo #(.W(IW), .DEPTH(FD)) fi0 (
        .clk(clk), .rst_n(rst_n), .push(in_we[0]),
        .din({in_warp[0 +: WARP_W], in_reg[0 +: 6], in_lane[0 +: 5], in_data[0 +: LW]}),
        .pop(pop0), .dout(f0_out), .empty(f0_empty), .full(f0_full), .count(f0_cnt));
    ad_fifo #(.W(IW), .DEPTH(FD)) fi1 (
        .clk(clk), .rst_n(rst_n), .push(in_we[1]),
        .din({in_warp[WARP_W +: WARP_W], in_reg[6 +: 6], in_lane[5 +: 5], in_data[32 +: LW]}),
        .pop(pop1), .dout(f1_out), .empty(f1_empty), .full(f1_full), .count(f1_cnt));
    wire [IW-1:0]     iw  = pop0 ? f0_out : f1_out;
    wire [WARP_W-1:0] i_warp = iw[IW-1 -: WARP_W];
    wire [5:0]        i_reg  = iw[LW+5 +: 6];
    wire [4:0]        i_lane = iw[LW +: 5];
    wire [LW-1:0]     i_data = iw[LW-1:0];
    wire [4:0]        i_grp5 = i_lane >> LB;
`ifndef SYNTHESIS
    always @(posedge clk) if (rst_n) begin
        if (in_we[0] && f0_full) $display("ERROR ad_su_wb: VF input FIFO full, write lost (%m t=%0t)", $time);
        if (in_we[1] && f1_full) $display("ERROR ad_su_wb: RX input FIFO full, write lost (%m t=%0t)", $time);
    end
`endif

    // ---------------- long beats ----------------
    wire          port_busy = sv || in_take;
`ifdef MUT_WB_LONG
    wire [NL-1:0] elig = l_valid;                       // mutation: ignores the port
`else
    wire [NL-1:0] elig = port_busy ? (l_valid & ~l_wr) : l_valid;
`endif
    reg  [PW-1:0] ptr;
    wire [NL-1:0] gnt;
    wire [PW-1:0] gi;
    wire          lt;
    rr_pick #(.N(NL)) rr (.req(elig), .ptr(ptr), .grant_onehot(gnt), .grant_index(gi), .grant_valid(lt));
    assign l_ready = gnt;
    // the granted beat's fields (AND-OR over the one-hot grant)
    reg               g_wr, g_last;
    reg [WARP_W-1:0]  g_warp;
    reg [GRP_W-1:0]   g_grp;
    reg [6:0]         g_rd;
    reg [NPHYS*LW-1:0] g_data;
    reg [NPHYS-1:0]   g_lanes;
    reg [SBE_W:0]     g_sbe;
    reg [2:0]         g_cls;
    always @(*) begin
        g_wr = 1'b0; g_last = 1'b0; g_warp = 0; g_grp = 0; g_rd = 0; g_data = 0; g_lanes = 0; g_sbe = 0; g_cls = 0;
        for (i = 0; i < NL; i = i + 1)
            if (gnt[i]) begin
                g_wr    = g_wr    | l_wr[i];
                g_last  = g_last  | l_last[i];
                g_warp  = g_warp  | l_warp[WARP_W*i +: WARP_W];
                g_grp   = g_grp   | l_grp[GRP_W*i +: GRP_W];
                g_rd    = g_rd    | l_rd[7*i +: 7];
                g_data  = g_data  | l_data[NPHYS*LW*i +: NPHYS*LW];
                g_lanes = g_lanes | l_lanes[NPHYS*i +: NPHYS];
                g_sbe   = g_sbe   | l_sbe[(SBE_W+1)*i +: SBE_W+1];
                g_cls   = g_cls   | l_cls[3*i +: 3];
            end
    end
    wire          l_wr_t   = lt && g_wr;
    wire [6:0]    l_rd_t   = g_rd;
    assign rel_valid = lt && g_last;
    assign rel_warp  = g_warp;
    assign rel_sbe   = g_sbe;
    assign rel_cls   = g_cls;

    // wait counter of a long beat with data that is not taken
    reg  [2:0] wcnt;
    wire       l_wait = |(l_valid & l_wr) && !l_wr_t;
    always @(posedge clk) begin
        if (!rst_n) begin
            ptr  <= {PW{1'b0}};
            wcnt <= 3'd0;
        end else begin
            if (lt) ptr <= (gi == NL - 1) ? {PW{1'b0}} : gi + 1'b1;   // gi < NL when lt
            if (!l_wait) wcnt <= 3'd0;
            else if (wcnt != 3'd7) wcnt <= wcnt + 1'b1;
        end
    end
    assign wb_stall = !f0_empty || !f1_empty || wcnt >= 3'd4;

    // ---------------- the port ----------------
    always @(*) begin
        w_en = 1'b0; w_warp = sw; w_grp = sg; w_reg = sr[5:0]; w_data = sd; w_lanes = sl;
        rq_push = 1'b0; rq_data = sd;
        if (sv) begin
            if (sr == 7'd63) rq_push = 1'b1;
            else             w_en = 1'b1;
        end else if (in_take) begin
            w_en    = i_reg != 6'd63;
            w_warp  = i_warp;
            w_grp   = i_grp5[GRP_W-1:0];
            w_reg   = i_reg;
            w_data  = {NPHYS{i_data}};
            w_lanes = {{(NPHYS-1){1'b0}}, 1'b1} << (i_lane & LMASK);
        end else if (l_wr_t) begin
            w_warp  = g_warp;
            w_grp   = g_grp;
            w_reg   = l_rd_t[5:0];
            w_data  = g_data;
            w_lanes = g_lanes;
            rq_data = w_data;
            if (l_rd_t == 7'd63) rq_push = 1'b1;
            else                 w_en = 1'b1;
        end
    end
endmodule
