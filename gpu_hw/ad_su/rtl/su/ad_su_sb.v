// ad_su_sb -- the issue stage with the per-warp scoreboard (spec ad_su_sb.md,
// design §3.1.1).  One decoded instruction (u_*) is checked per cycle and is
// either consumed without issue (nop, a satisfied wait, ILL), replayed
// (feedback 2: the scheduler fetches it again after a wake), issued to
// ad_su_opd (i_*, with a scoreboard entry for a long writer), or held
// (u_ready 0: wb_stall, the short-result interlock, the in-order list full,
// i_ready 0).  Release before allocate: this cycle's release (rel_*) is
// applied before the entries and counters are checked or allocated.
//
// Replay when (after this cycle's release):
//   - a GPR source (rs1, rs2, rs3, rs1+1 for PAIR, rs3+1 for a TEX uop with
//     sub[4] and op bit 2) or the destination range overlaps a valid entry of
//     the warp (ad_ctl_sb_ovl);
//   - a long instruction (class m, t, x) whose counter is 63, or that writes
//     (NDST > 0) and finds no free entry;
//   - wait (CTL op 0) with cm > imm[3:0], ct > imm[7:4] or cx > imm[11:8]
//     (a satisfied wait is consumed: feedback 0, no issue);
//   - fence (LSU op FENCE) with cm != 0; end (EXEC op 13) with a counter != 0;
//   - an rq source with rq_empty, rd 63 with rq_full.
// Feedback (fb_valid = u_valid && u_ready): 0 issued/consumed, 1 issued and
// wait for warp control (EXEC branches 0-5, end, bar) or ILL, 2 replay.
// wake[w]: a release for warp w this cycle (an entry or a counter freed).
// warp_ready[w] = warp w has no valid scoreboard entry (no long destination
// pending), from the registers.  ad_su_sched selects only such warps, so the
// only replays left are the counter waits (wait, fence, end), a long
// instruction at a counter of 63, and rq.
// fault/fault_pc: registered one-cycle pulse for each ILL uop consumed.
module ad_su_sb #(
    parameter NWARPS     = 4,
    parameter WARP_W     = 2,
    parameter SB_ENTRIES = 4,
    parameter SBE_W      = 2,
    parameter UOP_W      = 108,
    parameter NPHYS      = 8,
    parameter SHORT_LAT  = 6
) (
    input  wire              clk,
    input  wire              rst_n,
    input  wire              u_valid,
    output wire              u_ready,
    input  wire [WARP_W-1:0] u_warp,
    input  wire [15:0]       u_pc,
    input  wire [UOP_W-1:0]  u_uop,
    output wire              i_valid,
    input  wire              i_ready,
    output wire [WARP_W-1:0] i_warp,
    output wire [15:0]       i_pc,
    output wire [UOP_W-1:0]  i_uop,
    output wire [SBE_W:0]    i_sbe,
    output wire              fb_valid,
    output wire [WARP_W-1:0] fb_warp,
    output wire [1:0]        fb_kind,
    output wire [NWARPS-1:0] wake,
    output wire [NWARPS-1:0] warp_ready,
    input  wire              rel_valid,
    input  wire [WARP_W-1:0] rel_warp,
    input  wire [SBE_W:0]    rel_sbe,
    input  wire [2:0]        rel_cls,
    input  wire              wb_stall,
    input  wire              rq_empty,
    input  wire              rq_full,
    input  wire              x_end,
    output wire              busy,
    output reg               fault,
    output reg  [15:0]       fault_pc
);
    `include "ad_su_uop.vh"
    localparam NE = SB_ENTRIES;
    localparam [SBE_W:0] NONE = {(SBE_W+1){1'b1}};

    // ---- state: entries and counters per warp
    reg [NE-1:0]   ev [0:NWARPS-1];
    reg [NE*6-1:0] eb [0:NWARPS-1];
    reg [NE-1:0]   e4 [0:NWARPS-1];
    reg [NE*3-1:0] ec [0:NWARPS-1];
    reg [5:0]      cm [0:NWARPS-1];
    reg [5:0]      ct [0:NWARPS-1];
    reg [5:0]      cx [0:NWARPS-1];

    // ---- the uop's fields
    wire [3:0] unit = u_uop[AD_UOP_UNIT +: 4];
    wire [7:0] op   = u_uop[AD_UOP_OP +: 8];
    wire [6:0] rd   = u_uop[AD_UOP_RD +: 7];
    wire [6:0] rs1  = u_uop[AD_UOP_RS1 +: 7];
    wire [6:0] rs2  = u_uop[AD_UOP_RS2 +: 7];
    wire [6:0] rs3  = u_uop[AD_UOP_RS3 +: 7];
    wire [2:0] cls  = u_uop[AD_UOP_CLS +: 3];
    wire [2:0] ndst = u_uop[AD_UOP_NDST +: 3];
    wire [4:0] sub  = u_uop[AD_UOP_SUB +: 5];
    wire [11:0] lim = u_uop[AD_UOP_IMM +: 12];
    wire use1 = u_uop[AD_UOP_USE1], use2 = u_uop[AD_UOP_USE2], use3 = u_uop[AD_UOP_USE3];
    wire wrd  = u_uop[AD_UOP_WRD], pair = u_uop[AD_UOP_PAIR], ill = u_uop[AD_UOP_ILL];
`ifdef MUT_SB_NO_SRC5
    wire src5 = 1'b0;                                // mutation: rs3+1 not checked
`else
    wire src5 = unit == AD_UNIT_TEX && sub[4] && op[AD_TEX_CFORM] && use3;
`endif

    wire is_long  = cls == AD_CLS_M || cls == AD_CLS_T || cls == AD_CLS_X;
    wire is_short = cls == AD_CLS_A || cls == AD_CLS_F;
    wire is_nop   = unit == AD_UNIT_NONE;
    wire is_wait  = unit == AD_UNIT_CTL && op == AD_CTL_WAIT;
    wire is_fence = unit == AD_UNIT_LSU && op == AD_LSU_FENCE;
    wire is_end   = unit == AD_UNIT_EXEC && op == AD_EXEC_END;
    wire is_wc    = unit == AD_UNIT_EXEC && (op <= AD_EXEC_BEXZ || op == AD_EXEC_END || op == AD_EXEC_BAR);
    wire dst_gpr  = wrd && rd < 7'd63;
    wire takes_e  = is_long && ndst != 3'd0;

    // ---- this cycle's release, applied first
    wire [NE-1:0] relm = (rel_valid && rel_warp == u_warp && rel_sbe < NE) ?
                         ({{(NE-1){1'b0}}, 1'b1} << rel_sbe[SBE_W-1:0]) : {NE{1'b0}};
    wire [NE-1:0] evw  = ev[u_warp] & ~relm;
    wire rel_w  = rel_valid && rel_warp == u_warp;
    wire [5:0] cmw = cm[u_warp] - ((rel_w && rel_cls == AD_CLS_M && cm[u_warp] != 0) ? 6'd1 : 6'd0);
    wire [5:0] ctw = ct[u_warp] - ((rel_w && rel_cls == AD_CLS_T && ct[u_warp] != 0) ? 6'd1 : 6'd0);
    wire [5:0] cxw = cx[u_warp] - ((rel_w && rel_cls == AD_CLS_X && cx[u_warp] != 0) ? 6'd1 : 6'd0);
    wire [5:0] cclass = (cls == AD_CLS_M) ? cmw : (cls == AD_CLS_T) ? ctw : cxw;

    // ---- operand ranges
    wire [4:0]  suse = {src5, pair, use3, use2, use1};
    wire [39:0] srcs = {{1'b0, rs3} + 8'd1, {1'b0, rs1} + 8'd1, {1'b0, rs3}, {1'b0, rs2}, {1'b0, rs1}};
    wire src_hit, dst_hit;
    ad_ctl_sb_ovl #(.NE(NE)) u_ovl (
        .src_use(suse), .src(srcs), .dst_use(dst_gpr), .dst(rd[5:0]), .dst_w4(ndst == 3'd4),
        .e_valid(evw), .e_base(eb[u_warp]), .e_w4(e4[u_warp]), .src_hit(src_hit), .dst_hit(dst_hit));

    // free entry
    reg [SBE_W:0] fe;
    integer k;
    always @(*) begin
        fe = NONE;
        for (k = NE - 1; k >= 0; k = k - 1) if (!evw[k]) fe = k;
    end

    // ---- short-result interlock
    wire hold_rd, hold_wr, sil_full, sil_idle;
    wire do_issue;
    ad_ctl_sb_sil #(.WARP_W(WARP_W), .NPHYS(NPHYS), .SHORT_LAT(SHORT_LAT)) u_sil (
        .clk(clk), .rst_n(rst_n),
        .push(do_issue), .push_warp(u_warp), .push_sw(is_short && dst_gpr), .push_rd(rd[5:0]),
        .x_end(x_end),
        .q_warp(u_warp), .q_use(suse), .q_src(srcs), .q_dst_use(is_long && dst_gpr),
        .q_dst(rd[5:0]), .q_dst_w4(ndst == 3'd4),
        .hold_rd(hold_rd), .hold_wr(hold_wr), .full(sil_full), .idle(sil_idle));

    // ---- decision
    wire wait_ok = cmw <= {2'b00, lim[3:0]} && ctw <= {2'b00, lim[7:4]} && cxw <= {2'b00, lim[11:8]};
    wire replay = !ill && !is_nop && (
                  (is_wait && !wait_ok) ||
                  (!is_wait && (src_hit || dst_hit)) ||
                  (is_long && cclass == 6'd63) ||
                  (takes_e && fe == NONE) ||
                  (is_fence && cmw != 6'd0) ||
                  (is_end && (cmw != 6'd0 || ctw != 6'd0 || cxw != 6'd0)) ||
                  (u_uop[AD_UOP_RQS] && rq_empty) || (u_uop[AD_UOP_RQD] && rq_full));
    wire consume = ill || is_nop || (is_wait && wait_ok);
    wire want    = u_valid && !consume && !replay;           // would issue
    wire hold    = wb_stall || hold_rd || hold_wr || sil_full;
    assign i_valid  = want && !hold;
    assign do_issue = i_valid && i_ready;
    assign u_ready  = consume || replay || (!hold && i_ready);
    assign i_warp   = u_warp;
    assign i_pc     = u_pc;
    assign i_uop    = u_uop;
    assign i_sbe    = takes_e ? fe : NONE;

    assign fb_valid = u_valid && u_ready;
    assign fb_warp  = u_warp;
    assign fb_kind  = (!consume && replay) ? 2'd2 : (ill || (!consume && is_wc)) ? 2'd1 : 2'd0;

    // ---- wake, warp_ready, busy
    genvar g;
    generate for (g = 0; g < NWARPS; g = g + 1) begin : g_w
        assign wake[g]       = rel_valid && rel_warp == g;
        assign warp_ready[g] = ~|ev[g];
    end endgenerate
    reg any;
    integer w;
    always @(*) begin
        any = 1'b0;
        for (w = 0; w < NWARPS; w = w + 1)
            if (|ev[w] || cm[w] != 0 || ct[w] != 0 || cx[w] != 0) any = 1'b1;
    end
    assign busy = any;

    // ---- update
    wire alloc = do_issue && takes_e;
    wire inc   = do_issue && is_long;
    always @(posedge clk) begin
        if (!rst_n) begin
            for (w = 0; w < NWARPS; w = w + 1) begin
                ev[w] <= {NE{1'b0}}; cm[w] <= 6'd0; ct[w] <= 6'd0; cx[w] <= 6'd0;
            end
            fault    <= 1'b0;
            fault_pc <= 16'd0;
        end else begin
            fault <= u_valid && ill;
            if (u_valid && ill) fault_pc <= u_pc;
            if (rel_valid) begin
                if (rel_sbe < NE) ev[rel_warp][rel_sbe[SBE_W-1:0]] <= 1'b0;
                if (rel_cls == AD_CLS_M && cm[rel_warp] != 0) cm[rel_warp] <= cm[rel_warp] - 1'b1;
                if (rel_cls == AD_CLS_T && ct[rel_warp] != 0) ct[rel_warp] <= ct[rel_warp] - 1'b1;
                if (rel_cls == AD_CLS_X && cx[rel_warp] != 0) cx[rel_warp] <= cx[rel_warp] - 1'b1;
            end
            if (alloc) begin
                ev[u_warp][fe[SBE_W-1:0]] <= 1'b1;
                eb[u_warp][6*fe[SBE_W-1:0] +: 6] <= rd[5:0];
                e4[u_warp][fe[SBE_W-1:0]] <= ndst == 3'd4;
                ec[u_warp][3*fe[SBE_W-1:0] +: 3] <= cls;
            end
            if (inc) begin
                if (cls == AD_CLS_M) cm[u_warp] <= cmw + 1'b1;
                if (cls == AD_CLS_T) ct[u_warp] <= ctw + 1'b1;
                if (cls == AD_CLS_X) cx[u_warp] <= cxw + 1'b1;
            end
        end
    end


`ifdef AD_SB_FV
    // ---- formal properties (formal/ad_su_sb; enabled by AD_SB_FV only).
    // A shadow of the entries and counters is built from the ports only
    // (i_* issues with i_sbe, rel_*); the environment is constrained by it
    // (a release names a class with outstanding instructions and a valid
    // shadow entry of that class, or none when the class has instructions
    // without an entry; x_end only for an issued instruction not yet ended;
    // long writers keep rd + width within the GPRs).  Asserted: an issued
    // uop never reads or writes a GPR inside a pending long destination
    // (shadow, after this cycle's release); an allocation names a free shadow
    // entry; counters never underflow or overflow; and, as helper
    // invariants for the proof, the registers equal the shadow.
    reg            fs_ev [0:NWARPS-1][0:NE-1];
    reg [5:0]      fs_eb [0:NWARPS-1][0:NE-1];
    reg            fs_e4 [0:NWARPS-1][0:NE-1];
    reg [2:0]      fs_ec [0:NWARPS-1][0:NE-1];
    reg [6:0]      fs_cnt [0:NWARPS-1][0:2];
    reg [6:0]      fs_nent [0:NWARPS-1][0:2];
    reg [7:0]      fs_infl;
    function [1:0] fs_ci(input [2:0] c);
        fs_ci = (c == AD_CLS_M) ? 2'd0 : (c == AD_CLS_T) ? 2'd1 : 2'd2;
    endfunction
    wire fs_iss = i_valid && i_ready;
    wire [2:0] fs_icls = i_uop[AD_UOP_CLS +: 3];
    wire [2:0] fs_ind  = i_uop[AD_UOP_NDST +: 3];
    wire fs_ilong = fs_icls == AD_CLS_M || fs_icls == AD_CLS_T || fs_icls == AD_CLS_X;
    integer fw, fe2, fc;
    always @(posedge clk) begin
        if (!rst_n) begin
            for (fw = 0; fw < NWARPS; fw = fw + 1) begin
                for (fe2 = 0; fe2 < NE; fe2 = fe2 + 1) fs_ev[fw][fe2] <= 1'b0;
                for (fc = 0; fc < 3; fc = fc + 1) begin fs_cnt[fw][fc] <= 0; fs_nent[fw][fc] <= 0; end
            end
            fs_infl <= 0;
        end else begin
            fs_infl <= fs_infl + fs_iss - x_end;
            for (fw = 0; fw < NWARPS; fw = fw + 1)
                for (fc = 0; fc < 3; fc = fc + 1) begin
                    fs_cnt[fw][fc] <= fs_cnt[fw][fc]
                        + ((fs_iss && fs_ilong && i_warp == fw && fs_ci(fs_icls) == fc) ? 7'd1 : 7'd0)
                        - ((rel_valid && rel_warp == fw && fs_ci(rel_cls) == fc) ? 7'd1 : 7'd0);
                    fs_nent[fw][fc] <= fs_nent[fw][fc]
                        + ((fs_iss && fs_ilong && fs_ind != 0 && i_warp == fw && fs_ci(fs_icls) == fc) ? 7'd1 : 7'd0)
                        - ((rel_valid && rel_sbe != NONE && rel_warp == fw && fs_ci(rel_cls) == fc) ? 7'd1 : 7'd0);
                end
            if (rel_valid && rel_sbe != NONE) fs_ev[rel_warp][rel_sbe[SBE_W-1:0]] <= 1'b0;
            if (fs_iss && fs_ilong && fs_ind != 0) begin
                fs_ev[i_warp][i_sbe[SBE_W-1:0]] <= 1'b1;
                fs_eb[i_warp][i_sbe[SBE_W-1:0]] <= i_uop[AD_UOP_RD +: 6];
                fs_e4[i_warp][i_sbe[SBE_W-1:0]] <= fs_ind == 3'd4;
                fs_ec[i_warp][i_sbe[SBE_W-1:0]] <= fs_icls;
            end
        end
    end
    // reference interval check of the uop being issued
    reg [7:0] fs_s [0:4];
    reg [4:0] fs_su;
    reg       fs_bad_src, fs_bad_dst, fs_live;
    reg [7:0] fs_lo, fs_hi, fs_dlo, fs_dhi;
    integer fk;
    always @(*) begin
        fs_s[0] = rs1; fs_s[1] = rs2; fs_s[2] = rs3; fs_s[3] = rs1 + 8'd1; fs_s[4] = rs3 + 8'd1;
        fs_su = {unit == AD_UNIT_TEX && sub[4] && op[AD_TEX_CFORM] && use3, pair, use3, use2, use1};
        fs_dlo = rd; fs_dhi = fs_dlo + ((ndst == 3'd4) ? 8'd4 : 8'd1);
        fs_bad_src = 1'b0; fs_bad_dst = 1'b0;
        for (fe2 = 0; fe2 < NE; fe2 = fe2 + 1) begin
            fs_live = fs_ev[u_warp][fe2] && !(rel_valid && rel_warp == u_warp && rel_sbe == fe2);
            fs_lo = fs_eb[u_warp][fe2]; fs_hi = fs_lo + (fs_e4[u_warp][fe2] ? 8'd4 : 8'd1);
            if (fs_live) begin
                for (fk = 0; fk < 5; fk = fk + 1)
                    if (fs_su[fk] && fs_s[fk] < 63 && fs_s[fk] >= fs_lo && fs_s[fk] < fs_hi) fs_bad_src = 1'b1;
                if (wrd && rd < 63 && fs_dlo < fs_hi && fs_lo < fs_dhi) fs_bad_dst = 1'b1;
            end
        end
    end
    always @(*) if (rst_n) begin
        // environment
        if (u_valid && is_long && ndst != 0) assume (wrd && (ndst == 3'd4 ? rd < 7'd60 : rd < 7'd63));
        if (u_valid) assume (ndst == 0 || ndst == 1 || ndst == 4);
        if (rel_valid) begin
            assume (rel_cls == AD_CLS_M || rel_cls == AD_CLS_T || rel_cls == AD_CLS_X);
            assume (fs_cnt[rel_warp][fs_ci(rel_cls)] != 0);
            if (rel_sbe == NONE) assume (fs_cnt[rel_warp][fs_ci(rel_cls)] > fs_nent[rel_warp][fs_ci(rel_cls)]);
            else assume (rel_sbe < NE && fs_ev[rel_warp][rel_sbe[SBE_W-1:0]] && fs_ec[rel_warp][rel_sbe[SBE_W-1:0]] == rel_cls);
        end
        if (x_end) assume (fs_infl != 0);
        // properties
        if (fs_iss) begin
            a_no_raw: assert (!fs_bad_src);
            a_no_waw: assert (!fs_bad_dst);
            if (takes_e) a_alloc_new: assert (fe != NONE && !(fs_ev[u_warp][fe[SBE_W-1:0]] &&
                                             !(rel_valid && rel_warp == u_warp && rel_sbe == fe)));
            a_no_ill: assert (!ill);
        end
        if (rel_valid && rel_cls == AD_CLS_M) a_cm_under: assert (cm[rel_warp] != 0);
        if (rel_valid && rel_cls == AD_CLS_T) a_ct_under: assert (ct[rel_warp] != 0);
        if (rel_valid && rel_cls == AD_CLS_X) a_cx_under: assert (cx[rel_warp] != 0);
        if (inc) a_over: assert (cclass != 6'd63);
    end
    // helper invariants: the registers equal the shadow
    always @(*) if (rst_n) begin
        for (fw = 0; fw < NWARPS; fw = fw + 1) begin
            assert (cm[fw] == fs_cnt[fw][0] && ct[fw] == fs_cnt[fw][1] && cx[fw] == fs_cnt[fw][2]);
            assert (fs_cnt[fw][0] <= 63 && fs_cnt[fw][1] <= 63 && fs_cnt[fw][2] <= 63);
            for (fc = 0; fc < 3; fc = fc + 1) assert (fs_nent[fw][fc] <= fs_cnt[fw][fc]);
            for (fe2 = 0; fe2 < NE; fe2 = fe2 + 1) begin
                assert (ev[fw][fe2] == fs_ev[fw][fe2]);
                if (fs_ev[fw][fe2]) assert (eb[fw][6*fe2 +: 6] == fs_eb[fw][fe2] && e4[fw][fe2] == fs_e4[fw][fe2] &&
                                            (fs_ec[fw][fe2] == AD_CLS_M || fs_ec[fw][fe2] == AD_CLS_T || fs_ec[fw][fe2] == AD_CLS_X) &&
                                            fs_eb[fw][fe2] + (fs_e4[fw][fe2] ? 3 : 0) < 63);
            end
        end
    end
`endif

    /* verilator lint_off UNUSEDSIGNAL */
    wire unused = &{1'b0, sil_idle, u_uop};
    /* verilator lint_on UNUSEDSIGNAL */
endmodule
